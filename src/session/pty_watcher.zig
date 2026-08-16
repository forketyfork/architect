const std = @import("std");
const posix = std.posix;
const atomic = std.atomic;
const grid_layout = @import("../app/grid_layout.zig");

const log = std.log.scoped(.pty_watcher);

const poll_timeout_ms: i32 = 100;
const busy_wake_backoff_ns: u64 = 2 * std.time.ns_per_ms;
const poll_error_backoff_ns: u64 = 10 * std.time.ns_per_ms;

/// Wake-worthy poll conditions: readable data, and the terminal states that
/// still need one final drain (hang-up, error, invalid fd). The main thread's
/// per-frame fd-set refresh drops fds once their session goes away, so this
/// watcher does not need to distinguish them itself.
const wake_worthy_events: i16 = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;

fn isWakeWorthy(revents: i16) bool {
    return (revents & wake_worthy_events) != 0;
}

pub const RuntimeWake = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,

    pub fn notify(self: RuntimeWake) void {
        self.callback(self.context);
    }
};

/// Mutex-guarded set of PTY master fds the watcher thread polls. Owned by the
/// caller (the runtime) and refreshed once per frame via `updateFds`; the
/// watcher thread copies the list under the mutex at the top of each poll
/// iteration so it never observes a torn read.
pub const PtyWatcher = struct {
    mutex: std.Thread.Mutex = .{},
    fds: [grid_layout.max_terminals]posix.fd_t = undefined,
    fd_count: usize = 0,

    pub fn updateFds(self: *PtyWatcher, fds: []const posix.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(fds.len, grid_layout.max_terminals);
        @memcpy(self.fds[0..count], fds[0..count]);
        self.fd_count = count;
    }

    fn snapshotPollfds(self: *PtyWatcher, out: *[grid_layout.max_terminals]posix.pollfd) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.fds[0..self.fd_count], 0..) |fd, i| {
            out[i] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
        }
        return self.fd_count;
    }
};

const WatcherContext = struct {
    watcher: *PtyWatcher,
    stop: *atomic.Value(bool),
    wake_pending: *atomic.Value(bool),
    runtime_wake: ?RuntimeWake,
};

pub const StartError = std.Thread.SpawnError;

/// Starts the PTY-readability watcher thread. Mirrors `notify.startNotifyThread`'s
/// shape: the caller owns `watcher`/`stop`/`wake_pending` and joins the returned
/// thread after setting `stop`.
pub fn start(
    watcher: *PtyWatcher,
    stop: *atomic.Value(bool),
    wake_pending: *atomic.Value(bool),
    runtime_wake: ?RuntimeWake,
) StartError!std.Thread {
    const ctx = WatcherContext{
        .watcher = watcher,
        .stop = stop,
        .wake_pending = wake_pending,
        .runtime_wake = runtime_wake,
    };
    return try std.Thread.spawn(.{}, run, .{ctx});
}

fn run(ctx: WatcherContext) void {
    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;

    while (!ctx.stop.load(.seq_cst)) {
        // A wake was pushed but the main thread has not drained it yet.
        // Avoid spinning and re-pushing wakes while data sits unread.
        if (ctx.wake_pending.load(.seq_cst)) {
            std.Thread.sleep(busy_wake_backoff_ns);
            continue;
        }

        const count = ctx.watcher.snapshotPollfds(&pollfds);
        if (count == 0) {
            std.Thread.sleep(@as(u64, @intCast(poll_timeout_ms)) * std.time.ns_per_ms);
            continue;
        }

        const ready = posix.poll(pollfds[0..count], poll_timeout_ms) catch |err| {
            log.debug("poll failed: {}", .{err});
            std.Thread.sleep(poll_error_backoff_ns);
            continue;
        };
        if (ready == 0) continue;

        var should_wake = false;
        for (pollfds[0..count]) |pfd| {
            if (isWakeWorthy(pfd.revents)) {
                should_wake = true;
                break;
            }
        }

        if (should_wake) {
            ctx.wake_pending.store(true, .seq_cst);
            if (ctx.runtime_wake) |waker| waker.notify();
        }
    }
}

test "isWakeWorthy fires for readable, hangup, error, and invalid fds" {
    try std.testing.expect(isWakeWorthy(posix.POLL.IN));
    try std.testing.expect(isWakeWorthy(posix.POLL.HUP));
    try std.testing.expect(isWakeWorthy(posix.POLL.ERR));
    try std.testing.expect(isWakeWorthy(posix.POLL.NVAL));
    try std.testing.expect(!isWakeWorthy(posix.POLL.OUT));
    try std.testing.expect(!isWakeWorthy(0));
}

test "PtyWatcher.updateFds copies up to the capacity and snapshotPollfds reflects it" {
    var watcher = PtyWatcher{};

    watcher.updateFds(&[_]posix.fd_t{ 3, 4, 5 });

    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;
    const count = watcher.snapshotPollfds(&pollfds);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(posix.fd_t, 3), pollfds[0].fd);
    try std.testing.expectEqual(@as(posix.fd_t, 4), pollfds[1].fd);
    try std.testing.expectEqual(@as(posix.fd_t, 5), pollfds[2].fd);
    try std.testing.expectEqual(@as(i16, posix.POLL.IN), pollfds[0].events);
}

test "PtyWatcher.updateFds replaces the previous set, shrinking fd_count" {
    var watcher = PtyWatcher{};
    watcher.updateFds(&[_]posix.fd_t{ 1, 2, 3, 4 });

    watcher.updateFds(&[_]posix.fd_t{7});

    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;
    const count = watcher.snapshotPollfds(&pollfds);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(posix.fd_t, 7), pollfds[0].fd);
}

test "PtyWatcher.updateFds truncates to the fixed capacity without allocating" {
    var watcher = PtyWatcher{};
    var many: [grid_layout.max_terminals + 5]posix.fd_t = undefined;
    for (&many, 0..) |*fd, i| fd.* = @intCast(i);

    watcher.updateFds(&many);

    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;
    const count = watcher.snapshotPollfds(&pollfds);
    try std.testing.expectEqual(@as(usize, grid_layout.max_terminals), count);
}
