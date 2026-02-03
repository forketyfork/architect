const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.open);

const OpenError = error{
    SpawnFailed,
    OutOfMemory,
};

const argv_len: comptime_int = switch (builtin.os.tag) {
    .linux, .freebsd => 2,
    .windows => 3,
    .macos => 2,
    else => @compileError("unsupported platform for openUrl"),
};

const ThreadContext = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    argv: [argv_len][]const u8,

    fn deinit(self: *ThreadContext) void {
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }
};

pub fn openUrl(_: std.mem.Allocator, url: []const u8) OpenError!void {
    // Use c_allocator because it's thread-safe and the context is freed on a worker thread.
    const thread_allocator = std.heap.c_allocator;

    const ctx = thread_allocator.create(ThreadContext) catch return error.OutOfMemory;
    errdefer thread_allocator.destroy(ctx);

    ctx.allocator = thread_allocator;
    ctx.url = thread_allocator.dupe(u8, url) catch {
        thread_allocator.destroy(ctx);
        return error.OutOfMemory;
    };
    errdefer thread_allocator.free(ctx.url);

    ctx.argv = switch (builtin.os.tag) {
        .linux, .freebsd => .{ "xdg-open", ctx.url },
        .windows => .{ "rundll32", "url.dll,FileProtocolHandler", ctx.url },
        .macos => .{ "open", ctx.url },
        else => comptime unreachable,
    };

    const thread = std.Thread.spawn(.{}, openUrlThread, .{ctx}) catch |err| {
        ctx.deinit();
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SpawnFailed,
        };
    };
    thread.detach();
}

fn openUrlThread(ctx: *ThreadContext) void {
    defer ctx.deinit();

    var child = std.process.Child.init(&ctx.argv, ctx.allocator);
    _ = child.spawnAndWait() catch |err| {
        log.warn("failed to open URL '{s}': {}", .{ ctx.url, err });
        return;
    };
}
