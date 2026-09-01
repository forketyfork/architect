const std = @import("std");

pub const Context = struct {
    threaded: ?std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !Context {
        return .{
            .threaded = .init(allocator, .{
                .async_limit = .limited(thread_count),
                .concurrent_limit = .limited(thread_count),
            }),
        };
    }

    pub fn deinit(self: *Context) void {
        if (self.threaded) |*threaded| threaded.deinit();
    }

    pub fn io(self: *Context) std.Io {
        return self.threaded.?.io();
    }
};

var default_context: Context = .{
    .threaded = .init_single_threaded,
};

pub fn defaultContext() *Context {
    return &default_context;
}

pub const TaskFn = *const fn (usize, *anyopaque) void;

const PendingTask = struct {
    function: TaskFn,
    index: usize,
    context: *anyopaque,
};

fn runTask(task: PendingTask) void {
    task.function(task.index, task.context);
}

pub const Executor = struct {
    context: *Context,
    group: std.Io.Group = .init,

    pub fn init(context: *Context, _: std.mem.Allocator, _: usize) !Executor {
        return .{ .context = context };
    }

    pub fn deinit(self: *Executor) void {
        _ = self;
    }

    pub fn spawn(self: *Executor, function: TaskFn, index: usize, context: *anyopaque) !void {
        self.group.async(self.context.io(), runTask, .{PendingTask{
            .function = function,
            .index = index,
            .context = context,
        }});
    }

    pub fn wait(self: *Executor) !void {
        try self.group.await(self.context.io());
    }
};

pub const Mutex = std.Io.Mutex;

pub fn initMutex() Mutex {
    return .init;
}

pub fn lockMutex(mutex: *Mutex, context: *Context) !void {
    try mutex.lock(context.io());
}

pub fn unlockMutex(mutex: *Mutex, context: *Context) void {
    mutex.unlock(context.io());
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
    dir: std.Io.Dir,
    iterator: ?std.Io.Dir.Iterator = null,
};

pub fn openDir(context: *Context, path: []const u8, iterate: bool) !Directory {
    const dir = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openDirAbsolute(context.io(), path, .{ .iterate = iterate })
    else
        try std.Io.Dir.cwd().openDir(context.io(), path, .{ .iterate = iterate });
    return .{
        .dir = dir,
    };
}

pub fn closeDir(context: *Context, directory: *Directory) void {
    directory.dir.close(context.io());
}

pub fn nextDir(context: *Context, directory: *Directory) !?DirectoryEntry {
    if (directory.iterator == null) {
        directory.iterator = directory.dir.iterate();
    }
    const entry = try directory.iterator.?.next(context.io()) orelse return null;
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
    context: *Context,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![:0]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.Io.Dir.openFileAbsolute(context.io(), path, .{});
        defer file.close(context.io());
        var reader = file.reader(context.io(), &.{});
        return reader.interface.allocRemainingAlignedSentinel(
            allocator,
            std.Io.Limit.limited(max_size),
            .of(u8),
            0,
            // The reader exposes the underlying failure through `reader.err`.
            // zwanzig-disable-next-line: swallowed-error
        ) catch |err| switch (err) {
            error.ReadFailed => reader.err.?,
            error.OutOfMemory, error.StreamTooLong => |e| e,
        };
    }

    return std.Io.Dir.cwd().readFileAllocOptions(
        context.io(),
        path,
        allocator,
        std.Io.Limit.limited(max_size),
        .of(u8),
        0,
    );
}

pub fn writeFile(context: *Context, path: []const u8, data: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(context.io(), path, .{})
    else
        try std.Io.Dir.cwd().createFile(context.io(), path, .{});
    defer file.close(context.io());
    try file.writeStreamingAll(context.io(), data);
}

pub fn makePath(context: *Context, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(context.io(), path);
}

pub fn deleteFile(context: *Context, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.deleteFileAbsolute(context.io(), path);
    }
    return std.Io.Dir.cwd().deleteFile(context.io(), path);
}

pub fn deleteTree(context: *Context, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().deleteTree(context.io(), path);
    }
    return std.Io.Dir.cwd().deleteTree(context.io(), path);
}

pub fn stat(context: *Context, path: []const u8) !EntryKind {
    const result = try std.Io.Dir.cwd().statFile(context.io(), path, .{});
    return switch (result.kind) {
        .file => .file,
        .directory => .directory,
        else => .other,
    };
}

pub const OutputWriter = struct {
    context: *Context,
    file: std.Io.File,
    file_writer: std.Io.File.Writer,
    buffer: [4096]u8,

    pub fn init(self: *OutputWriter, context: *Context, stderr: bool) void {
        self.context = context;
        self.file = if (stderr) std.Io.File.stderr() else std.Io.File.stdout();
        self.file_writer = self.file.writer(context.io(), &self.buffer);
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
        const path_len = inner.dir.realPath(std.testing.io, &path_buffer) catch @panic("failed to resolve test directory");
        return .{
            .inner = inner,
            .path_buffer = path_buffer,
            .path_len = path_len,
        };
    }

    pub fn path(self: *const TestDir) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    pub fn writeFile(self: *TestDir, name: []const u8, data: []const u8) !void {
        try self.inner.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    }

    pub fn cleanup(self: *TestDir) void {
        self.inner.cleanup();
    }
};

pub fn timestamp(context: *Context) i64 {
    return std.Io.Clock.real.now(context.io()).toSeconds();
}
