const std = @import("std");
const posix = std.posix;
const app_state = @import("../app/app_state.zig");
const atomic = std.atomic;

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
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(Notification) = .{},

    pub fn deinit(self: *NotificationQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn push(self: *NotificationQueue, allocator: std.mem.Allocator, item: Notification) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, item);
    }

    pub fn drainAll(self: *NotificationQueue) std.ArrayListUnmanaged(Notification) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const items = self.items;
        self.items = .{};
        return items;
    }
};

pub const GetNotifySocketPathError = std.mem.Allocator.Error;

pub fn getNotifySocketPath(allocator: std.mem.Allocator) GetNotifySocketPathError![:0]u8 {
    const base = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.c.getpid();
    const socket_name = try std.fmt.allocPrint(allocator, "architect_notify_{d}.sock", .{pid});
    defer allocator.free(socket_name);
    return try std.fs.path.joinZ(allocator, &[_][]const u8{ base, socket_name });
}

const NotifyContext = struct {
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
    stop: *atomic.Value(bool),
};

pub const StartNotifyThreadError = std.Thread.SpawnError;

pub fn startNotifyThread(
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
    stop: *atomic.Value(bool),
) StartNotifyThreadError!std.Thread {
    _ = std.posix.unlink(socket_path) catch |err| switch (err) {
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
            const addr = try std.net.Address.initUnix(ctx.socket_path);
            const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            defer posix.close(fd);

            try posix.bind(fd, &addr.any, addr.getOsSockLen());
            try posix.listen(fd, 16);
            const sock_path = std.mem.sliceTo(ctx.socket_path, 0);
            std.posix.fchmodat(posix.AT.FDCWD, sock_path, 0o600, 0) catch |err| {
                log.warn("failed to chmod notify socket: {}", .{err});
            };

            // Make accept non-blocking so the loop can observe stop requests.
            const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| blk: {
                log.warn("failed to get socket flags: {}", .{err});
                break :blk null;
            };
            if (flags) |f| {
                var o_flags: posix.O = @bitCast(@as(u32, @intCast(f)));
                o_flags.NONBLOCK = true;
                if (posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
                    log.warn("failed to set socket non-blocking: {}", .{err});
                }
            }

            while (!ctx.stop.load(.seq_cst)) {
                const conn_fd = posix.accept(fd, null, null, 0) catch |err| switch (err) {
                    error.WouldBlock => {
                        std.Thread.sleep(std.time.ns_per_ms * 10);
                        continue;
                    },
                    else => {
                        log.debug("accept error: {}", .{err});
                        continue;
                    },
                };
                defer posix.close(conn_fd);

                const conn_flags = posix.fcntl(conn_fd, posix.F.GETFL, 0) catch |err| blk: {
                    log.debug("failed to get connection flags: {}", .{err});
                    break :blk null;
                };
                if (conn_flags) |f| {
                    var o_flags: posix.O = @bitCast(@as(u32, @intCast(f)));
                    o_flags.NONBLOCK = true;
                    if (posix.fcntl(conn_fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
                        log.warn("failed to set connection non-blocking: {}", .{err});
                    }
                }

                var buffer = std.ArrayList(u8){};
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
                    ctx.queue.push(ctx.allocator, note) catch |err| {
                        const session_id = switch (note) {
                            .status => |s| s.session,
                            .story => |s| s.session,
                        };
                        log.warn("failed to queue notification for session {d}: {}", .{ session_id, err });
                        // Free heap-allocated data on failure
                        switch (note) {
                            .story => |s| ctx.allocator.free(s.path),
                            .status => {},
                        }
                    };
                }
            }
        }
    };

    const ctx = NotifyContext{ .allocator = allocator, .socket_path = socket_path, .queue = queue, .stop = stop };
    return try std.Thread.spawn(.{}, handler.run, .{ctx});
}

test "NotificationQueue - push and drain" {
    const allocator = std.testing.allocator;
    var queue = NotificationQueue{};
    defer queue.deinit(allocator);

    try queue.push(allocator, .{ .status = .{ .session = 0, .state = .running } });
    try queue.push(allocator, .{ .status = .{ .session = 1, .state = .awaiting_approval } });
    try queue.push(allocator, .{ .status = .{ .session = 2, .state = .done } });

    var items = queue.drainAll();
    defer items.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqual(Notification{ .status = .{ .session = 0, .state = .running } }, items.items[0]);
    try std.testing.expectEqual(Notification{ .status = .{ .session = 1, .state = .awaiting_approval } }, items.items[1]);
    try std.testing.expectEqual(Notification{ .status = .{ .session = 2, .state = .done } }, items.items[2]);
}
