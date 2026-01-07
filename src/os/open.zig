const std = @import("std");
const builtin = @import("builtin");

const OpenError = error{
    SpawnFailed,
    OutOfMemory,
};

pub fn openUrl(allocator: std.mem.Allocator, url: []const u8) OpenError!void {
    const child = switch (builtin.os.tag) {
        .linux, .freebsd => std.process.Child.init(&.{ "xdg-open", url }, allocator),
        .windows => std.process.Child.init(&.{ "rundll32", "url.dll,FileProtocolHandler", url }, allocator),
        .macos => std.process.Child.init(&.{ "open", url }, allocator),
        else => return error.SpawnFailed,
    };

    const thread = std.Thread.spawn(.{}, openUrlThread, .{ allocator, child }) catch return error.SpawnFailed;
    thread.detach();
}

fn openUrlThread(allocator: std.mem.Allocator, child: std.process.Child) void {
    _ = allocator;
    var process = child;
    _ = process.spawnAndWait() catch {
        return;
    };
}
