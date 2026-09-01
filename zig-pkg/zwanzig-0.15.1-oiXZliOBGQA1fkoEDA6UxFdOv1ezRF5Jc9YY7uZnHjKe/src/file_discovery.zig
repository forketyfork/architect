const std = @import("std");
const compat = @import("compat.zig");
const log = std.log.scoped(.file_discovery);

pub const FileDiscoveryError = error{
    OutOfMemory,
    AccessDenied,
    InvalidUtf8,
    NotDir,
    FileNotFound,
};

const ignored_dirs = [_][]const u8{
    "zig-cache",
    "zig-out",
    ".zigmod",
    ".gyro",
};

pub fn discoverFiles(
    io_context: *compat.Context,
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) FileDiscoveryError![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit(allocator);
    }

    if (paths.len == 0) {
        log.debug("discover: walking current directory", .{});
        try walkDirectory(io_context, allocator, &files, ".");
    } else {
        for (paths) |path| {
            log.debug("discover: input path {s}", .{path});
            const stat = compat.stat(io_context, path) catch |err| switch (err) {
                error.FileNotFound => return FileDiscoveryError.FileNotFound,
                error.AccessDenied => return FileDiscoveryError.AccessDenied,
                error.NotDir => return FileDiscoveryError.NotDir,
                else => return FileDiscoveryError.AccessDenied,
            };

            if (stat == .directory) {
                log.debug("discover: walking directory {s}", .{path});
                try walkDirectory(io_context, allocator, &files, path);
            } else if (isZigFile(path)) {
                log.debug("discover: adding file {s}", .{path});
                const owned = try allocator.dupe(u8, path);
                try files.append(allocator, owned);
            }
        }
    }

    return files.toOwnedSlice(allocator);
}

fn walkDirectory(
    io_context: *compat.Context,
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]const u8),
    base_path: []const u8,
) FileDiscoveryError!void {
    try walkDirectoryRecursive(io_context, allocator, files, base_path, null);
}

fn walkDirectoryRecursive(
    io_context: *compat.Context,
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]const u8),
    base_path: []const u8,
    relative_path: ?[]const u8,
) FileDiscoveryError!void {
    const open_path = if (relative_path) |rel|
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, rel }) catch return FileDiscoveryError.OutOfMemory
    else
        null;
    defer if (open_path) |p| allocator.free(p);

    const dir_to_open = open_path orelse base_path;
    log.debug("walk: open dir {s}", .{dir_to_open});

    var dir = compat.openDir(io_context, dir_to_open, true) catch |err| switch (err) {
        error.AccessDenied => return FileDiscoveryError.AccessDenied,
        error.FileNotFound => return FileDiscoveryError.FileNotFound,
        error.NotDir => return FileDiscoveryError.NotDir,
        else => return FileDiscoveryError.AccessDenied,
    };
    defer compat.closeDir(io_context, &dir);

    while (true) {
        const entry = compat.nextDir(io_context, &dir) catch return FileDiscoveryError.AccessDenied;
        if (entry) |e| {
            if (e.kind == .directory) {
                if (shouldIgnoreDir(e.name)) {
                    log.debug("walk: skip dir {s}", .{e.name});
                    continue;
                }
                const new_relative = if (relative_path) |rel|
                    std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, e.name }) catch return FileDiscoveryError.OutOfMemory
                else
                    allocator.dupe(u8, e.name) catch return FileDiscoveryError.OutOfMemory;
                defer allocator.free(new_relative);

                log.debug("walk: enter dir {s}", .{new_relative});
                try walkDirectoryRecursive(io_context, allocator, files, base_path, new_relative);
            } else if (e.kind == .file and isZigFile(e.name)) {
                const full_path = if (relative_path) |rel|
                    std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base_path, rel, e.name }) catch return FileDiscoveryError.OutOfMemory
                else
                    std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, e.name }) catch return FileDiscoveryError.OutOfMemory;

                if (std.mem.eql(u8, base_path, ".")) {
                    allocator.free(full_path);
                    const simple_path = if (relative_path) |rel|
                        std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, e.name }) catch return FileDiscoveryError.OutOfMemory
                    else
                        allocator.dupe(u8, e.name) catch return FileDiscoveryError.OutOfMemory;
                    log.debug("walk: found file {s}", .{simple_path});
                    files.append(allocator, simple_path) catch {
                        allocator.free(simple_path);
                        return FileDiscoveryError.OutOfMemory;
                    };
                } else {
                    log.debug("walk: found file {s}", .{full_path});
                    files.append(allocator, full_path) catch {
                        allocator.free(full_path);
                        return FileDiscoveryError.OutOfMemory;
                    };
                }
            }
        } else {
            break;
        }
    }
}

fn shouldIgnoreDir(name: []const u8) bool {
    for (ignored_dirs) |ignored| {
        if (std.mem.eql(u8, name, ignored)) {
            return true;
        }
    }
    return false;
}

fn isZigFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig");
}

pub fn freeDiscoveredFiles(allocator: std.mem.Allocator, files: []const []const u8) void {
    for (files) |file| {
        allocator.free(file);
    }
    allocator.free(files);
}

test "isZigFile" {
    try std.testing.expect(isZigFile("main.zig"));
    try std.testing.expect(isZigFile("path/to/file.zig"));
    try std.testing.expect(!isZigFile("main.c"));
    try std.testing.expect(!isZigFile("main.zig.bak"));
    try std.testing.expect(!isZigFile(""));
}

test "shouldIgnoreDir" {
    try std.testing.expect(shouldIgnoreDir("zig-cache"));
    try std.testing.expect(shouldIgnoreDir("zig-out"));
    try std.testing.expect(shouldIgnoreDir(".zigmod"));
    try std.testing.expect(shouldIgnoreDir(".gyro"));
    try std.testing.expect(!shouldIgnoreDir("src"));
    try std.testing.expect(!shouldIgnoreDir("zig-cache-extra"));
    try std.testing.expect(!shouldIgnoreDir("notzig-cache"));
}

test "discoverFiles: explicit files" {
    const allocator = std.testing.allocator;
    const io_context = compat.defaultContext();

    const paths = [_][]const u8{"src/main.zig"};
    const files = try discoverFiles(io_context, allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("src/main.zig", files[0]);
}

test "discoverFiles: walks directory" {
    const allocator = std.testing.allocator;
    const io_context = compat.defaultContext();

    const paths = [_][]const u8{"src"};
    const files = try discoverFiles(io_context, allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    try std.testing.expect(files.len > 0);

    var found_main = false;
    for (files) |f| {
        if (std.mem.endsWith(u8, f, "main.zig")) {
            found_main = true;
            break;
        }
    }
    try std.testing.expect(found_main);
}

test "discoverFiles: empty paths walks current directory" {
    const allocator = std.testing.allocator;
    const io_context = compat.defaultContext();

    const paths = [_][]const u8{};
    const files = try discoverFiles(io_context, allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    try std.testing.expect(files.len > 0);
}

test "discoverFiles: non-zig files filtered" {
    const allocator = std.testing.allocator;
    const io_context = compat.defaultContext();

    const paths = [_][]const u8{"."};
    const files = try discoverFiles(io_context, allocator, &paths);
    defer freeDiscoveredFiles(allocator, files);

    for (files) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f, ".zig"));
    }
}
