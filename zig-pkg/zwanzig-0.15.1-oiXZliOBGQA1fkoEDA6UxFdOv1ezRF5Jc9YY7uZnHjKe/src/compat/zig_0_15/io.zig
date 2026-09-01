const std = @import("std");

pub const Context = struct {
    // Keep this non-zero-sized: callers pass the context by pointer to both
    // version-specific implementations.
    marker: u8 = 0,

    pub fn init(_: std.mem.Allocator, _: usize) !Context {
        return .{};
    }

    pub fn deinit(_: *Context) void {}
};

var default_context: Context = .{};

pub fn defaultContext() *Context {
    return &default_context;
}

pub const TaskFn = *const fn (usize, *anyopaque) void;

const PendingTask = struct {
    function: TaskFn,
    index: usize,
    context: *anyopaque,
    wait_group: *std.Thread.WaitGroup,
};

fn runTask(task: PendingTask) void {
    defer task.wait_group.finish();
    task.function(task.index, task.context);
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    pool: *std.Thread.Pool,
    wait_group: std.Thread.WaitGroup,

    pub fn init(_: *Context, allocator: std.mem.Allocator, thread_count: usize) !Executor {
        const pool = try allocator.create(std.Thread.Pool);
        errdefer allocator.destroy(pool);
        try pool.init(.{
            .allocator = allocator,
            .n_jobs = @intCast(thread_count),
            .track_ids = true,
        });
        return .{
            .allocator = allocator,
            .pool = pool,
            .wait_group = .{},
        };
    }

    pub fn deinit(self: *Executor) void {
        self.pool.deinit();
        self.allocator.destroy(self.pool);
    }

    pub fn spawn(self: *Executor, function: TaskFn, index: usize, context: *anyopaque) !void {
        self.wait_group.start();
        self.pool.spawn(runTask, .{PendingTask{
            .function = function,
            .index = index,
            .context = context,
            .wait_group = &self.wait_group,
        }}) catch |err| {
            self.wait_group.finish();
            return err;
        };
    }

    pub fn wait(self: *Executor) !void {
        self.pool.waitAndWork(&self.wait_group);
    }
};

pub const Mutex = std.Thread.Mutex;

pub fn initMutex() Mutex {
    return .{};
}

pub fn lockMutex(mutex: *Mutex, _: *Context) !void {
    mutex.lock();
}

pub fn unlockMutex(mutex: *Mutex, _: *Context) void {
    mutex.unlock();
}

pub const EntryKind = enum {
    file,
    directory,
    other,
};

pub const DirectoryEntry = struct {
    name: []const u8,
    kind: EntryKind,
};

pub const Directory = struct {
    dir: std.fs.Dir,
    iterator: ?std.fs.Dir.Iterator = null,
};

pub fn openDir(_: *Context, path: []const u8, iterate: bool) !Directory {
    return .{
        .dir = try std.fs.cwd().openDir(path, .{ .iterate = iterate }),
    };
}

pub fn closeDir(_: *Context, directory: *Directory) void {
    directory.dir.close();
}

pub fn nextDir(_: *Context, directory: *Directory) !?DirectoryEntry {
    if (directory.iterator == null) {
        directory.iterator = directory.dir.iterate();
    }
    const entry = try directory.iterator.?.next() orelse return null;
    return .{
        .name = entry.name,
        .kind = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            else => .other,
        },
    };
}

pub fn readFileAlloc(
    _: *Context,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![:0]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return file.readToEndAllocOptions(
        allocator,
        max_size,
        null,
        std.mem.Alignment.of(u8),
        0,
    );
}

pub fn writeFile(_: *Context, path: []const u8, data: []const u8) !void {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{})
    else
        try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

pub fn makePath(_: *Context, path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

pub fn deleteFile(_: *Context, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.deleteFileAbsolute(path);
    }
    return std.fs.cwd().deleteFile(path);
}

pub fn deleteTree(_: *Context, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.deleteTreeAbsolute(path);
    }
    return std.fs.cwd().deleteTree(path);
}

pub fn stat(_: *Context, path: []const u8) !EntryKind {
    const result = try std.fs.cwd().statFile(path);
    return switch (result.kind) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

pub const OutputWriter = struct {
    file: std.fs.File,
    file_writer: std.fs.File.Writer,
    buffer: [4096]u8,

    pub fn init(self: *OutputWriter, _: *Context, stderr: bool) void {
        self.file = if (stderr) std.fs.File.stderr() else std.fs.File.stdout();
        self.file_writer = self.file.writer(&self.buffer);
    }

    pub fn writer(self: *OutputWriter) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    pub fn flush(self: *OutputWriter) std.Io.Writer.Error!void {
        try self.file_writer.interface.flush();
    }

    pub fn deinit(self: *OutputWriter) void {
        _ = self;
    }
};

pub const TestDir = struct {
    inner: std.testing.TmpDir,
    path_buffer: [std.fs.max_path_bytes]u8,
    path_len: usize,

    pub fn init() TestDir {
        var inner = std.testing.tmpDir(.{});
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_path = inner.dir.realpath(".", &path_buffer) catch @panic("failed to resolve test directory");
        return .{
            .inner = inner,
            .path_buffer = path_buffer,
            .path_len = resolved_path.len,
        };
    }

    pub fn path(self: *const TestDir) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    pub fn writeFile(self: *TestDir, name: []const u8, data: []const u8) !void {
        try self.inner.dir.writeFile(.{ .sub_path = name, .data = data });
    }

    pub fn cleanup(self: *TestDir) void {
        self.inner.cleanup();
    }
};

pub fn timestamp(_: *Context) i64 {
    return std.time.timestamp();
}
