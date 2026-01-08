const std = @import("std");
const builtin = @import("builtin");

const OpenError = error{
    SpawnFailed,
    OutOfMemory,
};

pub fn openUrl(allocator: std.mem.Allocator, url: []const u8) OpenError!void {
    // Allocate with a thread-safe allocator because the buffer is freed on a worker thread.
    const thread_allocator = std.heap.c_allocator;
    const owned_url = try thread_allocator.dupe(u8, url);

    const child = switch (builtin.os.tag) {
        .linux, .freebsd => std.process.Child.init(&.{ "xdg-open", owned_url }, allocator),
        .windows => std.process.Child.init(&.{ "rundll32", "url.dll,FileProtocolHandler", owned_url }, allocator),
        .macos => std.process.Child.init(&.{ "open", owned_url }, allocator),
        else => {
            thread_allocator.free(owned_url);
            return error.SpawnFailed;
        },
    };

    const thread = std.Thread.spawn(.{}, openUrlThread, .{ thread_allocator, child, owned_url }) catch |err| {
        thread_allocator.free(owned_url);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SpawnFailed,
        };
    };
    thread.detach();
}

fn openUrlThread(thread_allocator: std.mem.Allocator, child: std.process.Child, owned_url: []u8) void {
    var process = child;
    _ = process.spawnAndWait() catch {
        thread_allocator.free(owned_url);
        return;
    };
    thread_allocator.free(owned_url);
}
