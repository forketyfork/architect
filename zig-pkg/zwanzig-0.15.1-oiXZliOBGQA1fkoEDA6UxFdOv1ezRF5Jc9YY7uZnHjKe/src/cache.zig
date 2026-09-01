const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const BuildMetadata = @import("build_metadata.zig").BuildMetadata;

const CacheError = error{
    CacheCorrupted,
    VersionMismatch,
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    InvalidCacheEntry,
};

const cache_version: u32 = 2;
const cache_dir_name = ".zwanzig-cache";

pub const CacheKey = struct {
    file_hash: [32]u8,
    target_hash: [32]u8,
    version_hash: [32]u8,
    config_hash: [32]u8,

    pub fn init(
        file_content: []const u8,
        target: ?*const BuildMetadata,
        tool_version: []const u8,
        type_info_available: bool,
        enabled_rules: []const []const u8,
    ) CacheKey {
        var key: CacheKey = undefined;
        std.crypto.hash.sha2.Sha256.hash(file_content, &key.file_hash, .{});

        if (target) |t| {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            const arch_name = @tagName(t.target.arch);
            hasher.update(arch_name);
            const os_name = @tagName(t.target.os);
            hasher.update(os_name);
            if (t.target.abi) |abi| {
                hasher.update(abi);
            }
            hasher.final(&key.target_hash);
        } else {
            @memset(&key.target_hash, 0);
        }

        var version_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        version_hasher.update(tool_version);
        version_hasher.update("\x00");
        version_hasher.update(builtin.zig_version_string);
        version_hasher.final(&key.version_hash);

        var config_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        config_hasher.update(&[_]u8{if (type_info_available) 1 else 0});
        for (enabled_rules) |rule_name| {
            config_hasher.update(rule_name);
            config_hasher.update("\x00");
        }
        config_hasher.final(&key.config_hash);

        return key;
    }

    pub fn eql(self: CacheKey, other: CacheKey) bool {
        return std.mem.eql(u8, &self.file_hash, &other.file_hash) and
            std.mem.eql(u8, &self.target_hash, &other.target_hash) and
            std.mem.eql(u8, &self.version_hash, &other.version_hash) and
            std.mem.eql(u8, &self.config_hash, &other.config_hash);
    }
};

const CacheEntry = struct {
    version: u32,
    key: CacheKey,
    timestamp: i64,
    data_len: u32,

    const header_len = 144;

    pub fn init(key: CacheKey, data_len: u32, timestamp: i64) CacheEntry {
        return CacheEntry{
            .version = cache_version,
            .key = key,
            .timestamp = timestamp,
            .data_len = data_len,
        };
    }

    pub fn encode(self: CacheEntry) [header_len]u8 {
        var buf: [header_len]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], self.version, .little);
        @memcpy(buf[4..36], &self.key.file_hash);
        @memcpy(buf[36..68], &self.key.target_hash);
        @memcpy(buf[68..100], &self.key.version_hash);
        @memcpy(buf[100..132], &self.key.config_hash);
        std.mem.writeInt(i64, buf[132..140], self.timestamp, .little);
        std.mem.writeInt(u32, buf[140..144], self.data_len, .little);
        // Returning the header by value copies the local array to the caller.
        // zwanzig-disable-next-line: stack-escape-engine
        return buf;
    }

    pub fn decode(buf: *const [header_len]u8) !CacheEntry {
        const version = std.mem.readInt(u32, buf[0..4], .little);
        if (version != cache_version) {
            return CacheError.VersionMismatch;
        }

        var entry: CacheEntry = undefined;
        entry.version = version;
        @memcpy(&entry.key.file_hash, buf[4..36]);
        @memcpy(&entry.key.target_hash, buf[36..68]);
        @memcpy(&entry.key.version_hash, buf[68..100]);
        @memcpy(&entry.key.config_hash, buf[100..132]);
        entry.timestamp = std.mem.readInt(i64, buf[132..140], .little);
        entry.data_len = std.mem.readInt(u32, buf[140..144], .little);

        return entry;
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io_context: *compat.Context,
    cache_dir: ?[]u8,
    mutex: compat.Mutex = compat.initMutex(),

    pub fn init(allocator: std.mem.Allocator, io_context: *compat.Context) !Cache {
        return initAt(allocator, io_context, cache_dir_name);
    }

    pub fn initAt(allocator: std.mem.Allocator, io_context: *compat.Context, cache_dir_path: []const u8) !Cache {
        compat.makePath(io_context, cache_dir_path) catch |err| {
            switch (err) {
                error.AccessDenied => return Cache{
                    .allocator = allocator,
                    .io_context = io_context,
                    .cache_dir = null,
                },
                else => return err,
            }
        };

        return Cache{
            .allocator = allocator,
            .io_context = io_context,
            .cache_dir = try allocator.dupe(u8, cache_dir_path),
        };
    }

    pub fn deinit(self: *Cache) void {
        if (self.cache_dir) |dir| {
            self.allocator.free(dir);
        }
    }

    pub fn getCachePath(key: CacheKey, buf: []u8) ![]const u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&key.file_hash);
        hasher.update(&key.target_hash);
        hasher.update(&key.version_hash);
        hasher.update(&key.config_hash);
        var combined_hash: [32]u8 = undefined;
        hasher.final(&combined_hash);

        var offset: usize = 0;
        for (combined_hash) |byte| {
            const written = try std.fmt.bufPrint(buf[offset..], "{x:0>2}", .{byte});
            offset += written.len;
        }
        const ext = try std.fmt.bufPrint(buf[offset..], ".cache", .{});
        offset += ext.len;
        return buf[0..offset];
    }

    pub fn get(self: *Cache, key: CacheKey) !?[]u8 {
        if (self.cache_dir == null) {
            return null;
        }

        try compat.lockMutex(&self.mutex, self.io_context);
        defer compat.unlockMutex(&self.mutex, self.io_context);

        var path_buf: [256]u8 = undefined;
        const cache_path = try Cache.getCachePath(key, &path_buf);
        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ self.cache_dir.?, cache_path });

        const contents = compat.readFileAlloc(self.io_context, self.allocator, full_path, 10 * 1024 * 1024) catch |err| {
            return switch (err) {
                error.FileNotFound => null,
                error.AccessDenied => CacheError.AccessDenied,
                else => err,
            };
        };
        defer self.allocator.free(contents.ptr[0 .. contents.len + 1]);

        if (contents.len < CacheEntry.header_len) return null;
        const header: *const [CacheEntry.header_len]u8 = @ptrCast(contents.ptr);
        const entry = CacheEntry.decode(header) catch |err| {
            return switch (err) {
                error.VersionMismatch, error.CacheCorrupted => null,
                else => err,
            };
        };

        if (!entry.key.eql(key)) {
            // Key mismatch indicates corruption; treat as cache miss
            return null;
        }

        const data_start = CacheEntry.header_len;
        const data_end = std.math.add(usize, data_start, entry.data_len) catch return null;
        if (data_end > contents.len) return null;

        const data = try self.allocator.alloc(u8, entry.data_len);
        @memcpy(data, contents[data_start..data_end]);

        return data;
    }

    pub fn put(self: *Cache, key: CacheKey, data: []const u8) !void {
        if (self.cache_dir == null) {
            return;
        }

        try compat.lockMutex(&self.mutex, self.io_context);
        defer compat.unlockMutex(&self.mutex, self.io_context);

        var path_buf: [256]u8 = undefined;
        const cache_path = try Cache.getCachePath(key, &path_buf);
        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ self.cache_dir.?, cache_path });

        const entry = CacheEntry.init(key, @intCast(data.len), compat.timestamp(self.io_context));
        const header = entry.encode();
        const contents = try self.allocator.alloc(u8, header.len + data.len);
        defer self.allocator.free(contents);
        @memcpy(contents[0..header.len], &header);
        @memcpy(contents[header.len..], data);
        try compat.writeFile(self.io_context, full_path, contents);
    }

    pub fn invalidate(self: *Cache, key: CacheKey) !void {
        if (self.cache_dir == null) {
            return;
        }

        try compat.lockMutex(&self.mutex, self.io_context);
        defer compat.unlockMutex(&self.mutex, self.io_context);

        var path_buf: [256]u8 = undefined;
        const cache_path = try Cache.getCachePath(key, &path_buf);

        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ self.cache_dir.?, cache_path });

        compat.deleteFile(self.io_context, full_path) catch |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        };
    }

    pub fn clear(self: *Cache) !void {
        if (self.cache_dir == null) {
            return;
        }

        try compat.lockMutex(&self.mutex, self.io_context);
        defer compat.unlockMutex(&self.mutex, self.io_context);

        var files_to_delete: std.ArrayList([]const u8) = .empty;
        defer {
            for (files_to_delete.items) |name| {
                self.allocator.free(name);
            }
            files_to_delete.deinit(self.allocator);
        }

        var directory = try compat.openDir(self.io_context, self.cache_dir.?, true);
        defer compat.closeDir(self.io_context, &directory);

        while (try compat.nextDir(self.io_context, &directory)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".cache")) {
                const name_copy = try self.allocator.dupe(u8, entry.name);
                try files_to_delete.append(self.allocator, name_copy);
            }
        }

        for (files_to_delete.items) |name| {
            var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ self.cache_dir.?, name });
            try compat.deleteFile(self.io_context, full_path);
        }
    }
};

test "CacheKey: init and cache path" {
    const target = BuildMetadata{
        .target = .{
            .arch = .x86_64,
            .os = .linux,
            .abi = "gnu",
        },
        .optimize_mode = null,
        .root_source_file = null,
    };

    const rules = [_][]const u8{ "rule1", "rule2" };
    const key = CacheKey.init("test content", &target, "1.0.0", false, &rules);

    var buf: [256]u8 = undefined;
    const path = try Cache.getCachePath(key, &buf);

    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, ".cache"));
    try std.testing.expectEqual(@as(usize, 70), path.len);
}

test "CacheKey: eql" {
    const rules = [_][]const u8{"rule1"};
    const key1 = CacheKey.init("test", null, "1.0.0", false, &rules);
    const key2 = CacheKey.init("test", null, "1.0.0", false, &rules);
    const key3 = CacheKey.init("different", null, "1.0.0", false, &rules);

    try std.testing.expect(key1.eql(key2));
    try std.testing.expect(!key1.eql(key3));
}

test "CacheKey: version changes invalidate" {
    const rules = [_][]const u8{"rule1"};
    const key1 = CacheKey.init("test", null, "1.0.0", false, &rules);
    const key2 = CacheKey.init("test", null, "1.0.1", false, &rules);

    try std.testing.expect(!key1.eql(key2));
}

test "CacheKey version hash includes the embedded Zig frontend version" {
    const rules = [_][]const u8{};
    const key = CacheKey.init("test", null, "1.0.0", false, &rules);

    // Regression guard: if version_hash were derived from the tool version
    // alone, two binaries embedding different Zig frontends would share
    // incompatible typed-analysis cache entries.
    var expected_version_hash: [32]u8 = undefined;
    var version_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    version_hasher.update("1.0.0");
    version_hasher.update("\x00");
    version_hasher.update(builtin.zig_version_string);
    version_hasher.final(&expected_version_hash);
    try std.testing.expectEqual(expected_version_hash, key.version_hash);
}

test "CacheKey: config changes invalidate" {
    const rules1 = [_][]const u8{"rule1"};
    const rules2 = [_][]const u8{ "rule1", "rule2" };
    const key1 = CacheKey.init("test", null, "1.0.0", false, &rules1);
    const key2 = CacheKey.init("test", null, "1.0.0", false, &rules2);

    try std.testing.expect(!key1.eql(key2));
}

test "CacheKey: deterministic across runs" {
    const rules = [_][]const u8{ "rule1", "rule2" };
    const key1 = CacheKey.init("test content", null, "1.0.0", false, &rules);
    const key2 = CacheKey.init("test content", null, "1.0.0", false, &rules);

    try std.testing.expect(key1.eql(key2));
    try std.testing.expect(std.mem.eql(u8, &key1.file_hash, &key2.file_hash));
    try std.testing.expect(std.mem.eql(u8, &key1.version_hash, &key2.version_hash));
    try std.testing.expect(std.mem.eql(u8, &key1.config_hash, &key2.config_hash));
}

test "CacheEntry: write and read" {
    const rules = [_][]const u8{"rule1"};
    const key = CacheKey.init("test", null, "1.0.0", false, &rules);
    const entry = CacheEntry.init(key, 42, 123);
    const encoded = entry.encode();
    const read_entry = try CacheEntry.decode(&encoded);

    try std.testing.expectEqual(entry.version, read_entry.version);
    try std.testing.expectEqual(entry.data_len, read_entry.data_len);
    try std.testing.expect(entry.key.eql(read_entry.key));
    try std.testing.expectEqual(entry.timestamp, read_entry.timestamp);
}

test "Cache: put and get" {
    const allocator = std.testing.allocator;

    var io_context = try compat.Context.init(allocator, 1);
    defer io_context.deinit();
    var temp_dir = compat.TestDir.init();
    defer temp_dir.cleanup();

    var cache = try Cache.initAt(allocator, &io_context, temp_dir.path());
    defer cache.deinit();

    const rules = [_][]const u8{"rule1"};
    const key = CacheKey.init("test content", null, "1.0.0", false, &rules);
    const data = "cached data";

    try cache.put(key, data);

    const retrieved = try cache.get(key);
    if (retrieved) |r| {
        defer allocator.free(r);
        try std.testing.expectEqualStrings(data, r);
    } else {
        return error.CacheMiss;
    }
}

test "Cache: get non-existent key returns null" {
    const allocator = std.testing.allocator;

    var io_context = try compat.Context.init(allocator, 1);
    defer io_context.deinit();
    var cache = Cache{
        .allocator = allocator,
        .io_context = &io_context,
        .cache_dir = null,
    };
    defer cache.deinit();

    const rules = [_][]const u8{"rule1"};
    const key = CacheKey.init("non-existent", null, "1.0.0", false, &rules);
    const result = try cache.get(key);

    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "Cache: invalidate removes entry" {
    const allocator = std.testing.allocator;

    var io_context = try compat.Context.init(allocator, 1);
    defer io_context.deinit();
    var temp_dir = compat.TestDir.init();
    defer temp_dir.cleanup();

    var cache = try Cache.initAt(allocator, &io_context, temp_dir.path());
    defer cache.deinit();

    const rules = [_][]const u8{"rule1"};
    const key = CacheKey.init("test", null, "1.0.0", false, &rules);
    try cache.put(key, "data");

    try cache.invalidate(key);

    const result = try cache.get(key);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "Cache: clear removes all entries" {
    const allocator = std.testing.allocator;

    var io_context = try compat.Context.init(allocator, 1);
    defer io_context.deinit();
    var temp_dir = compat.TestDir.init();
    defer temp_dir.cleanup();

    var cache = try Cache.initAt(allocator, &io_context, temp_dir.path());
    defer cache.deinit();

    const rules = [_][]const u8{"rule1"};
    const key1 = CacheKey.init("test1", null, "1.0.0", false, &rules);
    const key2 = CacheKey.init("test2", null, "1.0.0", false, &rules);

    try cache.put(key1, "data1");
    try cache.put(key2, "data2");

    try cache.clear();

    const result1 = try cache.get(key1);
    const result2 = try cache.get(key2);

    try std.testing.expectEqual(@as(?[]u8, null), result1);
    try std.testing.expectEqual(@as(?[]u8, null), result2);
}

test "Cache: handles access denied gracefully" {
    const allocator = std.testing.allocator;

    var io_context = try compat.Context.init(allocator, 1);
    defer io_context.deinit();
    var cache = Cache{
        .allocator = allocator,
        .io_context = &io_context,
        .cache_dir = null,
    };
    defer cache.deinit();

    const rules = [_][]const u8{"rule1"};
    const key = CacheKey.init("test", null, "1.0.0", false, &rules);

    try cache.put(key, "data");

    const result = try cache.get(key);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}
