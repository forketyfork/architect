// Store: Higher-level state container for organizing related reactive state.
//
// A Store groups related signals, computeds, and actions together, similar
// to MobX stores or Vuex modules. This provides better organization for
// complex state and enables features like snapshots and time-travel debugging.
//
// Usage:
//   const CounterStore = Store(struct {
//       count: Signal(i32),
//       doubled: Computed(i32),
//
//       pub fn increment(self: *@This()) void {
//           self.count.set(self.count.get() + 1);
//       }
//   });
//
//   var store = CounterStore.init(allocator);
//   store.state.increment();

const std = @import("std");
const tracker = @import("tracker.zig");
const signal_mod = @import("signal.zig");

/// Action decorator: wraps a mutation in a batch for efficient updates.
pub fn action(
    allocator: std.mem.Allocator,
    comptime func: anytype,
) @TypeOf(func) {
    const Args = std.meta.ArgsTuple(@TypeOf(func));

    return struct {
        fn wrapped(args: Args) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
            tracker.beginBatch(allocator);
            defer tracker.endBatch();
            return @call(.auto, func, args);
        }
    }.wrapped;
}

/// Run a block of code as an action (batched updates).
pub fn runInAction(allocator: std.mem.Allocator, func: *const fn () void) void {
    tracker.beginBatch(allocator);
    defer tracker.endBatch();
    func();
}

/// Run a block with context as an action.
pub fn runInActionWithContext(
    allocator: std.mem.Allocator,
    comptime Context: type,
    func: *const fn (*Context) void,
    ctx: *Context,
) void {
    tracker.beginBatch(allocator);
    defer tracker.endBatch();
    func(ctx);
}

/// Transaction: accumulates changes and applies them atomically.
pub const Transaction = struct {
    allocator: std.mem.Allocator,
    started: bool = false,
    pending_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Transaction {
        return .{ .allocator = allocator };
    }

    pub fn begin(self: *Transaction) void {
        if (!self.started) {
            self.pending_len = tracker.pendingCount();
            tracker.beginBatch(self.allocator);
            self.started = true;
        }
    }

    pub fn commit(self: *Transaction) void {
        if (self.started) {
            tracker.endBatch();
            self.started = false;
        }
    }

    pub fn rollback(self: *Transaction) void {
        if (self.started) {
            tracker.rollbackBatch(self.pending_len);
            self.started = false;
        }
    }
};

/// Observable collection: array with reactive length and item access.
pub fn ObservableArray(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        items: std.ArrayList(T),
        length_signal: signal_mod.Signal(usize),
        node_id: tracker.NodeId,
        subscribers: std.ArrayList(tracker.Subscription),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .items = std.ArrayList(T).init(allocator),
                .length_signal = signal_mod.Signal(usize).init(allocator, 0),
                .node_id = signal_mod.generateNodeId(),
                .subscribers = std.ArrayList(tracker.Subscription).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
            self.length_signal.deinit();
            self.subscribers.deinit(self.allocator);
        }

        pub fn len(self: *Self) usize {
            return self.length_signal.get();
        }

        pub fn get(self: *Self, index: usize) ?T {
            tracker.recordAccess(self.node_id);
            if (index >= self.items.items.len) return null;
            return self.items.items[index];
        }

        pub fn set(self: *Self, index: usize, value: T) void {
            if (index < self.items.items.len) {
                self.items.items[index] = value;
                self.notifySubscribers();
            }
        }

        pub fn push(self: *Self, value: T) !void {
            try self.items.append(self.allocator, value);
            self.length_signal.set(self.items.items.len);
            self.notifySubscribers();
        }

        pub fn pop(self: *Self) ?T {
            if (self.items.items.len == 0) return null;
            const value = self.items.pop();
            self.length_signal.set(self.items.items.len);
            self.notifySubscribers();
            return value;
        }

        pub fn clear(self: *Self) void {
            self.items.clearRetainingCapacity();
            self.length_signal.set(0);
            self.notifySubscribers();
        }

        pub fn slice(self: *Self) []const T {
            tracker.recordAccess(self.node_id);
            return self.items.items;
        }

        pub fn subscribe(self: *Self, callback: tracker.SubscriberFn, ctx: ?*anyopaque) !void {
            try self.subscribers.append(self.allocator, .{
                .callback = callback,
                .ctx = ctx,
            });
        }

        fn notifySubscribers(self: *Self) void {
            for (self.subscribers.items) |sub| {
                tracker.notify(sub.callback, sub.ctx);
            }
            tracker.notifyObservers(self.node_id);
        }
    };
}

/// Observable map: key-value store with reactive access.
pub fn ObservableMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        map: std.AutoHashMap(K, V),
        size_signal: signal_mod.Signal(usize),
        node_id: tracker.NodeId,
        subscribers: std.ArrayList(tracker.Subscription),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .map = std.AutoHashMap(K, V).init(allocator),
                .size_signal = signal_mod.Signal(usize).init(allocator, 0),
                .node_id = signal_mod.generateNodeId(),
                .subscribers = std.ArrayList(tracker.Subscription).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
            self.size_signal.deinit();
            self.subscribers.deinit(self.allocator);
        }

        pub fn size(self: *Self) usize {
            return self.size_signal.get();
        }

        pub fn get(self: *Self, key: K) ?V {
            tracker.recordAccess(self.node_id);
            return self.map.get(key);
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            const had_key = self.map.contains(key);
            try self.map.put(key, value);
            if (!had_key) {
                self.size_signal.set(self.map.count());
            }
            self.notifySubscribers();
        }

        pub fn remove(self: *Self, key: K) ?V {
            const removed = self.map.fetchRemove(key);
            if (removed) |kv| {
                self.size_signal.set(self.map.count());
                self.notifySubscribers();
                return kv.value;
            }
            return null;
        }

        pub fn contains(self: *Self, key: K) bool {
            tracker.recordAccess(self.node_id);
            return self.map.contains(key);
        }

        pub fn subscribe(self: *Self, callback: tracker.SubscriberFn, ctx: ?*anyopaque) !void {
            try self.subscribers.append(self.allocator, .{
                .callback = callback,
                .ctx = ctx,
            });
        }

        fn notifySubscribers(self: *Self) void {
            for (self.subscribers.items) |sub| {
                tracker.notify(sub.callback, sub.ctx);
            }
            tracker.notifyObservers(self.node_id);
        }
    };
}

test "ObservableArray basic operations" {
    var arr = ObservableArray(i32).init(std.testing.allocator);
    defer arr.deinit();

    try arr.push(1);
    try arr.push(2);
    try arr.push(3);

    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expectEqual(@as(?i32, 2), arr.get(1));

    _ = arr.pop();
    try std.testing.expectEqual(@as(usize, 2), arr.len());
}

test "ObservableMap basic operations" {
    var map = ObservableMap(u32, []const u8).init(std.testing.allocator);
    defer map.deinit();

    try map.put(1, "one");
    try map.put(2, "two");

    try std.testing.expectEqual(@as(usize, 2), map.size());
    try std.testing.expectEqualStrings("one", map.get(1).?);

    _ = map.remove(1);
    try std.testing.expectEqual(@as(usize, 1), map.size());
    try std.testing.expect(map.get(1) == null);
}

test "Transaction batches updates" {
    var notification_count: u32 = 0;
    const callback = struct {
        fn cb(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.cb;

    var sig = signal_mod.Signal(i32).init(std.testing.allocator, 0);
    defer sig.deinit();

    try sig.subscribe(callback, &notification_count);

    var tx = Transaction.init(std.testing.allocator);
    tx.begin();

    sig.set(1);
    sig.set(2);
    sig.set(3);

    // No notifications yet
    try std.testing.expectEqual(@as(u32, 0), notification_count);

    tx.commit();

    // All notifications fired
    try std.testing.expectEqual(@as(u32, 3), notification_count);
}

test "Transaction rollback discards notifications" {
    tracker.initRegistry(std.testing.allocator);
    defer tracker.deinitRegistry();

    var notification_count: u32 = 0;
    const callback = struct {
        fn cb(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.cb;

    var sig = signal_mod.Signal(i32).init(std.testing.allocator, 0);
    defer sig.deinit();

    try sig.subscribe(callback, &notification_count);

    var tx = Transaction.init(std.testing.allocator);
    tx.begin();
    sig.set(1);

    tx.rollback();

    try std.testing.expectEqual(@as(u32, 0), notification_count);
}
