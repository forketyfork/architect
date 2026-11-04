const std = @import("std");
const posix = std.posix;
const clock = @import("../clock.zig");
const env = @import("../env.zig");
const app_state = @import("../app/app_state.zig");
const atomic = std.atomic;
const posix_util = @import("../posix_util.zig");
const wake_pipe = @import("../wake_pipe.zig");

const log = std.log.scoped(.notify);

pub const Notification = union(enum) {
    status: StatusNotification,
    story: StoryNotification,
};

pub const StatusNotification = struct {
    session: usize,
    state: app_state.SessionStatus,
};

pub const StoryNotification = struct {
    session: usize,
    /// Heap-allocated path; caller must free after processing.
    path: []const u8,
};

pub const NotificationQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Notification) = .empty,

    pub fn deinit(self: *NotificationQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn push(self: *NotificationQueue, allocator: std.mem.Allocator, io: std.Io, item: Notification) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.items.append(allocator, item);
    }

    pub fn drainAll(self: *NotificationQueue, io: std.Io) std.ArrayList(Notification) {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const items = self.items;
        self.items = .empty;
        return items;
    }
};

pub const GetNotifySocketPathError = std.mem.Allocator.Error;

pub fn getNotifySocketPath(allocator: std.mem.Allocator) GetNotifySocketPathError![:0]u8 {
    const base = env.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.c.getpid();
    const socket_name = try std.fmt.allocPrint(allocator, "architect_notify_{d}.sock", .{pid});
    defer allocator.free(socket_name);
    return try std.fs.path.joinZ(allocator, &[_][]const u8{ base, socket_name });
}

const NotifyContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
    stop: *atomic.Value(bool),
    wake: *const wake_pipe.WakePipe,
    runtime_wake: ?RuntimeWake,
};

pub const RuntimeWake = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,

    pub fn notify(self: RuntimeWake) void {
        self.callback(self.context);
    }
};

fn notificationSessionId(note: Notification) usize {
    return switch (note) {
        .status => |s| s.session,
        .story => |s| s.session,
    };
}

fn releaseNotification(allocator: std.mem.Allocator, note: Notification) void {
    switch (note) {
        .story => |s| allocator.free(s.path),
        .status => {},
    }
}

fn enqueueNotification(
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *NotificationQueue,
    runtime_wake: ?RuntimeWake,
    note: Notification,
) void {
    queue.push(allocator, io, note) catch |err| {
        log.warn("failed to queue notification for session {d}: {}", .{ notificationSessionId(note), err });
        releaseNotification(allocator, note);
        return;
    };

    if (runtime_wake) |waker| {
        waker.notify();
    }
}

const notify_read_timeout_ms: i64 = 1000;
const max_notification_bytes: usize = 1024;

/// Reads one notification line from a freshly accepted connection. `accept`
/// can return before the client has written anything, so an empty
/// non-blocking read means "not yet", not "end of message": wait for data
/// until a newline, EOF, or the timeout.
fn readNotificationBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    conn_fd: posix.fd_t,
    buffer: *std.ArrayList(u8),
) void {
    const deadline_ms = clock.nowMillis(io) + notify_read_timeout_ms;
    var tmp: [512]u8 = undefined;
    while (true) {
        const n = posix.read(conn_fd, &tmp) catch |err| switch (err) {
            error.WouldBlock => {
                const remaining_ms = deadline_ms - clock.nowMillis(io);
                if (remaining_ms <= 0) {
                    log.debug("notify connection sent no complete message before the timeout", .{});
                    return;
                }
                var fds = [_]posix.pollfd{.{ .fd = conn_fd, .events = posix.POLL.IN, .revents = 0 }};
                _ = posix.poll(&fds, @intCast(remaining_ms)) catch |poll_err| {
                    log.debug("poll error on notify connection: {}", .{poll_err});
                    return;
                };
                continue;
            },
            error.ConnectionResetByPeer => return,
            else => {
                log.debug("read error on notify connection: {}", .{err});
                return;
            },
        };
        if (n == 0) return;
        if (buffer.items.len + n > max_notification_bytes) return;
        buffer.appendSlice(allocator, tmp[0..n]) catch |err| {
            log.debug("failed to append to notify buffer: {}", .{err});
            return;
        };
        if (std.mem.indexOfScalar(u8, tmp[0..n], '\n') != null) return;
    }
}

pub const StartNotifyThreadError = std.Thread.SpawnError;

pub fn startNotifyThread(
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
    stop: *atomic.Value(bool),
    wake: *const wake_pipe.WakePipe,
    runtime_wake: ?RuntimeWake,
) StartNotifyThreadError!std.Thread {
    _ = std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to unlink notify socket: {}", .{err}),
    };

    const handler = struct {
        fn parseNotification(bytes: []const u8, persistent_alloc: std.mem.Allocator) ?Notification {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const alloc = arena.allocator();
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) return null;
            const obj = root.object;

            const session_val = obj.get("session") orelse return null;
            if (session_val != .integer) return null;
            if (session_val.integer < 0) return null;
            const session_idx: usize = @intCast(session_val.integer);

            // Check for "type" field to distinguish notification kinds
            const type_val = obj.get("type");
            if (type_val) |tv| {
                if (tv == .string and std.mem.eql(u8, tv.string, "story")) {
                    const path_val = obj.get("path") orelse return null;
                    if (path_val != .string) return null;
                    // Allocate path with persistent allocator so it survives arena cleanup
                    const path_dupe = persistent_alloc.dupe(u8, path_val.string) catch |err| {
                        log.err("failed to duplicate story path for session {d}: {}", .{ session_idx, err });
                        return null;
                    };
                    return Notification{ .story = .{
                        .session = session_idx,
                        .path = path_dupe,
                    } };
                }
            }

            // Default: status notification
            const state_val = obj.get("state") orelse return null;
            if (state_val != .string) return null;
            const state_str = state_val.string;
            const state = if (std.mem.eql(u8, state_str, "start"))
                app_state.SessionStatus.running
            else if (std.mem.eql(u8, state_str, "ready"))
                app_state.SessionStatus.idle
            else if (std.mem.eql(u8, state_str, "awaiting_approval"))
                app_state.SessionStatus.awaiting_approval
            else if (std.mem.eql(u8, state_str, "done"))
                app_state.SessionStatus.done
            else
                return null;

            return Notification{ .status = .{
                .session = session_idx,
                .state = state,
            } };
        }

        fn run(ctx: NotifyContext) !void {
            const address = try std.Io.net.UnixAddress.init(ctx.socket_path);
            var server = try address.listen(ctx.io, .{ .kernel_backlog = 16 });
            defer server.deinit(ctx.io);
            const fd = server.socket.handle;
            const sock_path = std.mem.sliceTo(ctx.socket_path, 0);
            std.Io.Dir.cwd().setFilePermissions(ctx.io, sock_path, .fromMode(0o600), .{}) catch |err| {
                log.warn("failed to chmod notify socket: {}", .{err});
            };

            // Make accept non-blocking so the loop can observe stop requests.
            const flags = posix_util.fcntl(fd, posix.F.GETFL, 0) catch |err| blk: {
                log.warn("failed to get socket flags: {}", .{err});
                break :blk null;
            };
            if (flags) |f| {
                var o_flags: posix.O = @bitCast(@as(u32, @intCast(f)));
                o_flags.NONBLOCK = true;
                if (posix_util.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
                    log.warn("failed to set socket non-blocking: {}", .{err});
                }
            }

            var fds = [_]posix.pollfd{
                .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
                ctx.wake.pollfd(),
            };
            while (!ctx.stop.load(.seq_cst)) {
                fds[0].revents = 0;
                fds[1].revents = 0;
                _ = posix.poll(&fds, -1) catch |err| {
                    log.warn("notify poll failed: {}", .{err});
                    clock.sleepNanos(ctx.io, wake_pipe.poll_error_backoff_ns);
                    continue;
                };
                if (fds[1].revents != 0) ctx.wake.drain();
                if (fds[0].revents == 0) continue;

                const conn_fd = posix_util.accept(fd) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => {
                        log.debug("accept error: {}", .{err});
                        continue;
                    },
                };
                defer _ = std.c.close(conn_fd);

                const conn_flags = posix_util.fcntl(conn_fd, posix.F.GETFL, 0) catch |err| blk: {
                    log.debug("failed to get connection flags: {}", .{err});
                    break :blk null;
                };
                if (conn_flags) |f| {
                    var o_flags: posix.O = @bitCast(@as(u32, @intCast(f)));
                    o_flags.NONBLOCK = true;
                    if (posix_util.fcntl(conn_fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
                        log.warn("failed to set connection non-blocking: {}", .{err});
                    }
                }

                var buffer: std.ArrayList(u8) = .empty;
                defer buffer.deinit(ctx.allocator);

                readNotificationBytes(ctx.allocator, ctx.io, conn_fd, &buffer);

                if (buffer.items.len == 0) continue;

                if (parseNotification(buffer.items, ctx.allocator)) |note| {
                    enqueueNotification(ctx.allocator, ctx.io, ctx.queue, ctx.runtime_wake, note);
                }
            }
        }
    };

    const ctx = NotifyContext{
        .allocator = allocator,
        .io = io,
        .socket_path = socket_path,
        .queue = queue,
        .stop = stop,
        .wake = wake,
        .runtime_wake = runtime_wake,
    };
    return try std.Thread.spawn(.{}, handler.run, .{ctx});
}

test "NotificationQueue - push and drain" {
    const allocator = std.testing.allocator;
    var queue = NotificationQueue{};
    defer queue.deinit(allocator);

    try queue.push(allocator, std.testing.io, .{ .status = .{ .session = 0, .state = .running } });
    try queue.push(allocator, std.testing.io, .{ .status = .{ .session = 1, .state = .awaiting_approval } });
    try queue.push(allocator, std.testing.io, .{ .status = .{ .session = 2, .state = .done } });

    var items = queue.drainAll(std.testing.io);
    defer items.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqual(Notification{ .status = .{ .session = 0, .state = .running } }, items.items[0]);
    try std.testing.expectEqual(Notification{ .status = .{ .session = 1, .state = .awaiting_approval } }, items.items[1]);
    try std.testing.expectEqual(Notification{ .status = .{ .session = 2, .state = .done } }, items.items[2]);
}

test "enqueueNotification wakes after queueing" {
    const allocator = std.testing.allocator;

    var queue = NotificationQueue{};
    defer queue.deinit(allocator);

    const TestWake = struct {
        fn onWake(context: ?*anyopaque) void {
            const counter = @as(*usize, @ptrCast(@alignCast(context orelse return)));
            counter.* += 1;
        }
    };

    var wake_count: usize = 0;
    const wake = RuntimeWake{
        .context = &wake_count,
        .callback = TestWake.onWake,
    };

    enqueueNotification(
        allocator,
        std.testing.io,
        &queue,
        wake,
        .{ .status = .{ .session = 7, .state = .done } },
    );

    var items = queue.drainAll(std.testing.io);
    defer items.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), wake_count);
    try std.testing.expectEqual(@as(usize, 1), items.items.len);
    try std.testing.expectEqual(Notification{ .status = .{ .session = 7, .state = .done } }, items.items[0]);
}

test "enqueueNotification skips wake when queueing fails" {
    var buffer: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var queue = NotificationQueue{};
    defer queue.deinit(allocator);

    const TestWake = struct {
        fn onWake(context: ?*anyopaque) void {
            const counter = @as(*usize, @ptrCast(@alignCast(context orelse return)));
            counter.* += 1;
        }
    };

    var wake_count: usize = 0;
    const wake = RuntimeWake{
        .context = &wake_count,
        .callback = TestWake.onWake,
    };

    while (true) {
        queue.push(allocator, std.testing.io, .{ .status = .{ .session = 1, .state = .running } }) catch break;
    }

    enqueueNotification(
        allocator,
        std.testing.io,
        &queue,
        wake,
        .{ .status = .{ .session = 7, .state = .done } },
    );

    var items = queue.drainAll(std.testing.io);
    defer items.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), wake_count);
}

test "notify thread stops promptly when signaled while blocked in poll" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    std.Io.Dir.cwd().createDirPath(io, ".tmp") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var queue = NotificationQueue{};
    defer queue.deinit(allocator);
    var stop = std.atomic.Value(bool).init(false);
    var wake = try wake_pipe.WakePipe.init();
    defer wake.deinit();

    var sock_path_buf: [128]u8 = undefined;
    const sock_path = try std.fmt.bufPrintSentinel(&sock_path_buf, ".tmp/notify_stop_{d}.sock", .{std.c.getpid()}, 0);
    defer std.Io.Dir.cwd().deleteFile(io, sock_path) catch |err| std.debug.print("cleanup failed: {}\n", .{err});

    const thread = try startNotifyThread(allocator, io, sock_path, &queue, &stop, &wake, null);

    const started = clock.nowNanos(io);
    stop.store(true, .seq_cst);
    wake.signal();
    thread.join();
    const elapsed_ns = clock.nowNanos(io) - started;
    // With the old 10 ms sleep loop this was bounded by the sleep; with poll it
    // must return as soon as the pipe byte lands. 200 ms is generous headroom.
    try std.testing.expect(elapsed_ns < 200 * std.time.ns_per_ms);
}

/// Sends `payload` to a fresh notify listener after `delay_ms` and returns the
/// first notification it queued, or null when none arrived.
fn notificationFromSocket(name: []const u8, payload: []const u8, delay_ms: u64) !?Notification {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    std.Io.Dir.cwd().createDirPath(io, ".tmp") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var queue = NotificationQueue{};
    defer queue.deinit(allocator);
    var stop = std.atomic.Value(bool).init(false);
    var wake = try wake_pipe.WakePipe.init();
    defer wake.deinit();

    var sock_path_buf: [128]u8 = undefined;
    const sock_path = try std.fmt.bufPrintSentinel(&sock_path_buf, ".tmp/notify_{s}_{d}.sock", .{ name, std.c.getpid() }, 0);
    defer std.Io.Dir.cwd().deleteFile(io, sock_path) catch |err| std.debug.print("cleanup failed: {}\n", .{err});

    const thread = try startNotifyThread(allocator, io, sock_path, &queue, &stop, &wake, null);
    defer {
        stop.store(true, .seq_cst);
        wake.signal();
        thread.join();
    }

    const address = try std.Io.net.UnixAddress.init(sock_path);
    const deadline = clock.nowMillis(io) + 5000;
    const stream = while (true) {
        break address.connect(io) catch |err| {
            if (clock.nowMillis(io) >= deadline) return err;
            clock.sleepNanos(io, 5 * std.time.ns_per_ms);
            continue;
        };
    };
    clock.sleepNanos(io, delay_ms * std.time.ns_per_ms);
    const file: std.Io.File = .{ .handle = stream.socket.handle, .flags = .{ .nonblocking = false } };
    try file.writeStreamingAll(io, payload);
    _ = std.c.close(stream.socket.handle);

    while (clock.nowMillis(io) < deadline) {
        var items = queue.drainAll(io);
        defer items.deinit(allocator);
        if (items.items.len > 0) return items.items[0];
        clock.sleepNanos(io, 5 * std.time.ns_per_ms);
    }
    return null;
}

test "notify listener waits for a client that writes after connecting" {
    // The delay lets the listener accept and attempt its first read before any
    // byte is available, which is exactly when hook clients raced it.
    const received = try notificationFromSocket("late", "{\"session\":3,\"state\":\"done\"}\n", 100);
    try std.testing.expectEqual(@as(?Notification, .{ .status = .{ .session = 3, .state = .done } }), received);
}

test "notify listener maps the ready state to idle" {
    const received = try notificationFromSocket("ready", "{\"session\":4,\"state\":\"ready\"}\n", 0);
    try std.testing.expectEqual(@as(?Notification, .{ .status = .{ .session = 4, .state = .idle } }), received);
}
