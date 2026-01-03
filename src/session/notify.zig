const std = @import("std");
const posix = std.posix;
const app_state = @import("../app/app_state.zig");

pub const Notification = struct {
    session: usize,
    state: app_state.SessionStatus,
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
};

pub const StartNotifyThreadError = std.Thread.SpawnError;

pub fn startNotifyThread(
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
) StartNotifyThreadError!std.Thread {
    _ = std.posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };

    const handler = struct {
        fn parseNotification(bytes: []const u8) ?Notification {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const alloc = arena.allocator();
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) return null;
            const obj = root.object;

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

            const session_val = obj.get("session") orelse return null;
            if (session_val != .integer) return null;
            if (session_val.integer < 0) return null;

            return Notification{
                .session = @intCast(session_val.integer),
                .state = state,
            };
        }

        fn run(ctx: NotifyContext) !void {
            const addr = try std.net.Address.initUnix(ctx.socket_path);
            const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            defer posix.close(fd);

            try posix.bind(fd, &addr.any, addr.getOsSockLen());
            try posix.listen(fd, 16);
            const sock_path = std.mem.sliceTo(ctx.socket_path, 0);
            _ = std.posix.fchmodat(posix.AT.FDCWD, sock_path, 0o600, 0) catch {};

            while (true) {
                const conn_fd = posix.accept(fd, null, null, 0) catch continue;
                defer posix.close(conn_fd);

                var buffer = std.ArrayList(u8){};
                defer buffer.deinit(ctx.allocator);

                var tmp: [512]u8 = undefined;
                while (true) {
                    const n = posix.read(conn_fd, &tmp) catch |err| switch (err) {
                        error.WouldBlock, error.ConnectionResetByPeer => break,
                        else => break,
                    };
                    if (n == 0) break;
                    if (buffer.items.len + n > 1024) break;
                    buffer.appendSlice(ctx.allocator, tmp[0..n]) catch break;
                }

                if (buffer.items.len == 0) continue;

                if (parseNotification(buffer.items)) |note| {
                    ctx.queue.push(ctx.allocator, note) catch {};
                }
            }
        }
    };

    const ctx = NotifyContext{ .allocator = allocator, .socket_path = socket_path, .queue = queue };
    return try std.Thread.spawn(.{}, handler.run, .{ctx});
}

test "NotificationQueue - push and drain" {
    const allocator = std.testing.allocator;
    var queue = NotificationQueue{};
    defer queue.deinit(allocator);

    try queue.push(allocator, .{ .session = 0, .state = .running });
    try queue.push(allocator, .{ .session = 1, .state = .awaiting_approval });
    try queue.push(allocator, .{ .session = 2, .state = .done });

    var items = queue.drainAll();
    defer items.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqual(@as(usize, 0), items.items[0].session);
    try std.testing.expectEqual(app_state.SessionStatus.running, items.items[0].state);
    try std.testing.expectEqual(@as(usize, 1), items.items[1].session);
    try std.testing.expectEqual(app_state.SessionStatus.awaiting_approval, items.items[1].state);
    try std.testing.expectEqual(@as(usize, 2), items.items[2].session);
    try std.testing.expectEqual(app_state.SessionStatus.done, items.items[2].state);
}
