const std = @import("std");
const posix = std.posix;
const posix_util = @import("posix_util.zig");
const log = std.log.scoped(.wake_pipe);

/// Backoff used by every thread loop after a `poll` failure so a persistent
/// error cannot turn into a busy spin.
pub const poll_error_backoff_ns: u64 = 10 * std.time.ns_per_ms;

pub const InitError = posix_util.PipeError || posix_util.FcntlError;

/// Non-blocking self-pipe. A thread blocked in `poll` on `pollfd()` wakes up
/// when another thread calls `signal()`. The pipe never holds more than its
/// kernel buffer: a signal that finds the buffer full is already observable,
/// so `WouldBlock` on write is not an error.
pub const WakePipe = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    pub fn init() InitError!WakePipe {
        var fds: [2]posix.fd_t = undefined;
        try posix_util.pipe(&fds);
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }
        try setNonBlocking(fds[0]);
        try setNonBlocking(fds[1]);
        try setCloseOnExec(fds[0]);
        try setCloseOnExec(fds[1]);
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: *WakePipe) void {
        _ = std.c.close(self.read_fd);
        _ = std.c.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;
    }

    pub fn signal(self: *const WakePipe) void {
        const byte = [_]u8{0};
        _ = posix_util.write(self.write_fd, &byte) catch |err| switch (err) {
            error.WouldBlock => {},
            else => log.warn("failed to signal wake pipe: {}", .{err}),
        };
    }

    pub fn drain(self: *const WakePipe) void {
        var buf: [256]u8 = undefined;
        while (true) {
            const n = posix.read(self.read_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    log.warn("failed to drain wake pipe: {}", .{err});
                    return;
                },
            };
            if (n < buf.len) return;
        }
    }

    pub fn pollfd(self: *const WakePipe) posix.pollfd {
        return .{ .fd = self.read_fd, .events = posix.POLL.IN, .revents = 0 };
    }
};

fn setNonBlocking(fd: posix.fd_t) posix_util.FcntlError!void {
    const flags = try posix_util.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix_util.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}

fn setCloseOnExec(fd: posix.fd_t) posix_util.FcntlError!void {
    const flags = try posix_util.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix_util.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
}

test "signal makes the read end readable and drain clears it" {
    var pipe = try WakePipe.init();
    defer pipe.deinit();

    try std.testing.expect(try posix_util.fcntl(pipe.read_fd, posix.F.GETFD, 0) & posix.FD_CLOEXEC != 0);
    try std.testing.expect(try posix_util.fcntl(pipe.write_fd, posix.F.GETFD, 0) & posix.FD_CLOEXEC != 0);

    var fds = [_]posix.pollfd{pipe.pollfd()};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));

    pipe.signal();
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&fds, 0));
    try std.testing.expect(fds[0].revents & posix.POLL.IN != 0);

    pipe.drain();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));
}

test "repeated signals coalesce into one drain" {
    var pipe = try WakePipe.init();
    defer pipe.deinit();

    var i: usize = 0;
    while (i < 100_000) : (i += 1) pipe.signal();

    pipe.drain();
    var fds = [_]posix.pollfd{pipe.pollfd()};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));
}
