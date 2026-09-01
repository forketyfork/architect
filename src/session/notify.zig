const std = @import("std");
const posix = std.posix;
const clock = @import("../clock.zig");
const env = @import("../env.zig");
const app_state = @import("../app/app_state.zig");
const atomic = std.atomic;
const posix_util = @import("../posix_util.zig");

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

pub const StartNotifyThreadError = std.Thread.SpawnError;

pub fn startNotifyThread(
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
    stop: *atomic.Value(bool),
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

            while (!ctx.stop.load(.seq_cst)) {
                const connection = server.accept(ctx.io) catch |err| switch (err) {
                    error.WouldBlock => {
                        clock.sleepNanos(ctx.io, std.time.ns_per_ms * 10);
                        continue;
                    },
                    else => {
                        log.debug("accept error: {}", .{err});
                        continue;
                    },
                };
                defer connection.close(ctx.io);
                const conn_fd = connection.socket.handle;

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

                var tmp: [512]u8 = undefined;
                while (true) {
                    const n = posix.read(conn_fd, &tmp) catch |err| switch (err) {
                        error.WouldBlock, error.ConnectionResetByPeer => break,
                        else => {
                            log.debug("read error on notify connection: {}", .{err});
                            break;
                        },
                    };
                    if (n == 0) break;
                    if (buffer.items.len + n > 1024) break;
                    buffer.appendSlice(ctx.allocator, tmp[0..n]) catch |err| {
                        log.debug("failed to append to notify buffer: {}", .{err});
                        break;
                    };
                }

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
