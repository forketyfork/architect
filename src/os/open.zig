const std = @import("std");
const builtin = @import("builtin");
const proc = @import("../proc.zig");

const log = std.log.scoped(.open);

const OpenError = error{
    SpawnFailed,
    OutOfMemory,
};

const max_in_flight: usize = 4;

const ThreadContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    done: *std.atomic.Value(bool),
    owned_url: ?[]u8,
    argv: []const []const u8,

    fn deinit(self: *ThreadContext) void {
        self.allocator.free(self.argv);
        if (self.owned_url) |url| self.allocator.free(url);
        self.allocator.destroy(self);
    }
};

const Slot = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sequence: u64 = 0,
};

pub const Opener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    slots: [max_in_flight]Slot = [_]Slot{.{}} ** max_in_flight,
    next_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Opener {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn open(self: *Opener, url: []const u8) OpenError!void {
        const owned_url = self.allocator.dupe(u8, url) catch return error.OutOfMemory;
        return switch (builtin.os.tag) {
            .linux, .freebsd => self.spawnCommand(&.{ "xdg-open", owned_url }, owned_url),
            .windows => self.spawnCommand(&.{ "rundll32", "url.dll,FileProtocolHandler", owned_url }, owned_url),
            .macos => self.spawnCommand(&.{ "open", owned_url }, owned_url),
            else => comptime unreachable,
        };
    }

    pub fn deinit(self: *Opener) void {
        for (&self.slots) |*slot| self.joinSlot(slot);
    }

    fn spawnCommand(self: *Opener, argv: []const []const u8, owned_url: ?[]u8) OpenError!void {
        self.reapFinished();
        const slot = self.freeSlot() orelse blk: {
            self.joinOldest();
            break :blk self.freeSlot() orelse unreachable;
        };

        const ctx = self.allocator.create(ThreadContext) catch {
            if (owned_url) |url| self.allocator.free(url);
            return error.OutOfMemory;
        };
        const argv_copy = self.allocator.dupe([]const u8, argv) catch {
            self.allocator.destroy(ctx);
            if (owned_url) |url| self.allocator.free(url);
            return error.OutOfMemory;
        };
        ctx.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .done = &slot.done,
            .owned_url = owned_url,
            .argv = argv_copy,
        };
        errdefer ctx.deinit();

        slot.done.store(false, .seq_cst);
        slot.thread = std.Thread.spawn(.{}, openUrlThread, .{ctx}) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SpawnFailed,
            };
        };
        slot.sequence = self.next_sequence;
        self.next_sequence +%= 1;
    }

    fn reapFinished(self: *Opener) void {
        for (&self.slots) |*slot| {
            if (slot.thread != null and slot.done.load(.seq_cst)) self.joinSlot(slot);
        }
    }

    fn freeSlot(self: *Opener) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.thread == null) return slot;
        }
        return null;
    }

    fn joinOldest(self: *Opener) void {
        var oldest = &self.slots[0];
        for (1..self.slots.len) |idx| {
            const slot = &self.slots[idx];
            if (slot.sequence < oldest.sequence) oldest = slot;
        }
        self.joinSlot(oldest);
    }

    fn joinSlot(_: *Opener, slot: *Slot) void {
        const thread = slot.thread orelse return;
        thread.join();
        slot.thread = null;
    }

    fn inFlightCount(self: *const Opener) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.thread != null) count += 1;
        }
        return count;
    }
};

fn openUrlThread(ctx: *ThreadContext) void {
    defer ctx.deinit();
    defer ctx.done.store(true, .seq_cst);

    _ = proc.spawnDetached(ctx.io, ctx.argv) catch |err| {
        if (ctx.owned_url) |url| {
            log.warn("failed to open URL '{s}': {}", .{ url, err });
        } else {
            log.warn("failed to open URL: {}", .{err});
        }
        return;
    };
}

test "Opener deinit joins a spawned command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var opener = Opener.init(std.testing.allocator, std.testing.io);
    defer opener.deinit();

    try opener.spawnCommand(&.{ "/bin/sh", "-c", "exit 0" }, null);
    opener.deinit();
    try std.testing.expectEqual(@as(usize, 0), opener.inFlightCount());
}
