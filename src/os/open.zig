const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.open);

const OpenError = error{
    SpawnFailed,
    OutOfMemory,
};

const ThreadContext = struct {
    allocator: std.mem.Allocator,
    argv: [][]u8,

    fn deinit(self: *ThreadContext) void {
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.allocator.destroy(self);
    }
};

/// Spawn an opener (`open` / `xdg-open` / ...) on a detached thread so the UI
/// never blocks. Every argument is duped into the thread-safe c_allocator, so
/// the caller may free its own strings as soon as this returns.
fn spawnDetached(argv: []const []const u8) OpenError!void {
    const a = std.heap.c_allocator;

    const ctx = a.create(ThreadContext) catch return error.OutOfMemory;
    errdefer a.destroy(ctx);
    ctx.allocator = a;

    const owned = a.alloc([]u8, argv.len) catch return error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |s| a.free(s);
        a.free(owned);
    }
    for (argv, 0..) |arg, i| {
        owned[i] = a.dupe(u8, arg) catch return error.OutOfMemory;
        filled = i + 1;
    }
    ctx.argv = owned;

    const thread = std.Thread.spawn(.{}, openThread, .{ctx}) catch |err| {
        ctx.deinit();
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SpawnFailed,
        };
    };
    thread.detach();
}

fn openThread(ctx: *ThreadContext) void {
    defer ctx.deinit();

    var child = std.process.Child.init(ctx.argv, ctx.allocator);
    _ = child.spawnAndWait() catch |err| {
        log.warn("failed to spawn opener: {}", .{err});
        return;
    };
}

/// Open a web URL (or any target) with the platform's default handler.
pub fn openUrl(_: std.mem.Allocator, url: []const u8) OpenError!void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux, .freebsd => &.{ "xdg-open", url },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        .macos => &.{ "open", url },
        else => @compileError("unsupported platform for openUrl"),
    };
    return spawnDetached(argv);
}

/// Open a clicked link target. On macOS: a local file path (absolute) opens in
/// VS Code, EXCEPT `.html`/`.htm`, which open with the default handler (the
/// user's browser). Web URLs and everything else fall back to the default
/// handler. Other platforms always use the default handler.
pub fn openTarget(allocator: std.mem.Allocator, target: []const u8) OpenError!void {
    if (builtin.os.tag == .macos and target.len > 0 and target[0] == '/') {
        const ext = std.fs.path.extension(target);
        const is_html = std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm");
        if (is_html) {
            return spawnDetached(&.{ "open", target });
        }
        return spawnDetached(&.{ "open", "-a", "Visual Studio Code", target });
    }
    return openUrl(allocator, target);
}
