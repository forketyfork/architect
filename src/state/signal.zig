// Signal: The core observable primitive for reactive state management.
//
// A Signal holds a value and notifies subscribers when it changes.
// Reading a signal's value automatically registers it as a dependency
// when inside a tracking context.
//
// Usage:
//   var count = Signal(i32).init(allocator, 0);
//   defer count.deinit();
//
//   const value = count.get();  // Tracks dependency if in reactive context
//   count.set(42);              // Notifies all subscribers

const std = @import("std");
const tracker = @import("tracker.zig");

var next_node_id: tracker.NodeId = 1;

fn generateNodeId() tracker.NodeId {
    const id = next_node_id;
    next_node_id += 1;
    return id;
}

/// Observable state container that notifies subscribers on change.
pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        value: T,
        node_id: tracker.NodeId,
        subscribers: std.ArrayList(tracker.Subscription) = .{},

        /// Initialize a signal with an initial value.
        pub fn init(allocator: std.mem.Allocator, initial_value: T) Self {
            return .{
                .allocator = allocator,
                .value = initial_value,
                .node_id = generateNodeId(),
            };
        }

        /// Clean up resources.
        pub fn deinit(self: *Self) void {
            self.subscribers.deinit(self.allocator);
        }

        /// Get the current value. Registers as a dependency if tracking.
        pub fn get(self: *const Self) T {
            tracker.recordAccess(self.node_id);
            return self.value;
        }

        /// Get the current value without tracking (for use in effects/reactions).
        pub fn peek(self: *const Self) T {
            return self.value;
        }

        /// Set a new value and notify subscribers if changed.
        pub fn set(self: *Self, new_value: T) void {
            if (comptime canCompareEquality(T)) {
                if (std.meta.eql(self.value, new_value)) return;
            }
            self.value = new_value;
            self.notifySubscribers();
        }

        /// Update the value using a function, useful for complex types.
        pub fn update(self: *Self, updater: *const fn (T) T) void {
            const new_value = updater(self.value);
            self.set(new_value);
        }

        /// Subscribe to changes. Returns an id for unsubscription.
        pub fn subscribe(self: *Self, callback: tracker.SubscriberFn, ctx: ?*anyopaque) !void {
            try self.subscribers.append(self.allocator, .{
                .callback = callback,
                .ctx = ctx,
            });
        }

        /// Unsubscribe from changes.
        pub fn unsubscribe(self: *Self, callback: tracker.SubscriberFn, ctx: ?*anyopaque) void {
            var i: usize = 0;
            while (i < self.subscribers.items.len) {
                const sub = self.subscribers.items[i];
                if (sub.callback == callback and sub.ctx == ctx) {
                    _ = self.subscribers.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        /// Get the unique node ID for this signal.
        pub fn getId(self: *const Self) tracker.NodeId {
            return self.node_id;
        }

        fn notifySubscribers(self: *Self) void {
            for (self.subscribers.items) |sub| {
                tracker.notify(sub.callback, sub.ctx);
            }
        }

        fn canCompareEquality(comptime U: type) bool {
            return switch (@typeInfo(U)) {
                .pointer, .optional, .@"enum", .int, .float, .bool => true,
                .@"struct" => @hasDecl(U, "eql") or !@hasDecl(U, "format"),
                else => false,
            };
        }
    };
}

/// Create a signal from an existing value (convenience function).
pub fn signal(allocator: std.mem.Allocator, value: anytype) Signal(@TypeOf(value)) {
    return Signal(@TypeOf(value)).init(allocator, value);
}

test "Signal basic get/set" {
    var sig = Signal(i32).init(std.testing.allocator, 10);
    defer sig.deinit();

    try std.testing.expectEqual(@as(i32, 10), sig.get());

    sig.set(42);
    try std.testing.expectEqual(@as(i32, 42), sig.get());
}

test "Signal subscription notification" {
    var sig = Signal(i32).init(std.testing.allocator, 0);
    defer sig.deinit();

    var notification_count: u32 = 0;
    const callback = struct {
        fn cb(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.cb;

    try sig.subscribe(callback, &notification_count);

    sig.set(1);
    try std.testing.expectEqual(@as(u32, 1), notification_count);

    sig.set(1); // Same value, should not notify
    try std.testing.expectEqual(@as(u32, 1), notification_count);

    sig.set(2);
    try std.testing.expectEqual(@as(u32, 2), notification_count);
}

test "Signal dependency tracking" {
    var sig = Signal(i32).init(std.testing.allocator, 100);
    defer sig.deinit();

    var ctx = tracker.TrackingContext.init(std.testing.allocator);
    defer ctx.deinit();

    _ = tracker.beginTracking(&ctx);
    _ = sig.get();
    tracker.endTracking(null);

    const deps = ctx.consumeDependencies();
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqual(sig.getId(), deps[0]);
}

test "Signal peek does not track" {
    var sig = Signal(i32).init(std.testing.allocator, 100);
    defer sig.deinit();

    var ctx = tracker.TrackingContext.init(std.testing.allocator);
    defer ctx.deinit();

    _ = tracker.beginTracking(&ctx);
    _ = sig.peek();
    tracker.endTracking(null);

    const deps = ctx.consumeDependencies();
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 0), deps.len);
}
