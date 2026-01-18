// Computed: Derived reactive values that auto-update when dependencies change.
//
// A Computed wraps a function that derives a value from signals or other
// computeds. It automatically tracks which reactive values are accessed
// during computation and re-evaluates only when those dependencies change.
//
// Usage:
//   var first_name = Signal([]const u8).init(allocator, "John");
//   var last_name = Signal([]const u8).init(allocator, "Doe");
//
//   var full_name = try Computed([]const u8).init(allocator, struct {
//       fn compute() []const u8 {
//           return first_name.get() ++ " " ++ last_name.get();
//       }
//   }.compute, .{});
//
// The computed will automatically re-evaluate when first_name or last_name changes.

const std = @import("std");
const tracker = @import("tracker.zig");
const signal_mod = @import("signal.zig");

/// Lazily-evaluated derived value with automatic dependency tracking.
pub fn Computed(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        compute_fn: *const fn (*Self) T,
        cached_value: ?T = null,
        is_dirty: bool = true,
        node_id: tracker.NodeId,
        dependencies: []tracker.NodeId = &[_]tracker.NodeId{},
        subscribers: std.ArrayList(tracker.Subscription) = .{},
        /// User context passed to compute function
        context: ?*anyopaque = null,

        /// Initialize a computed with a derivation function.
        pub fn init(
            allocator: std.mem.Allocator,
            compute_fn: *const fn (*Self) T,
            context: ?*anyopaque,
        ) Self {
            return .{
                .allocator = allocator,
                .compute_fn = compute_fn,
                .node_id = signal_mod.Signal(T).init(allocator, undefined).node_id,
                .context = context,
            };
        }

        /// Clean up resources.
        pub fn deinit(self: *Self) void {
            if (self.dependencies.len > 0) {
                self.allocator.free(self.dependencies);
            }
            self.subscribers.deinit(self.allocator);
        }

        /// Get the computed value, recomputing if necessary.
        pub fn get(self: *Self) T {
            tracker.recordAccess(self.node_id);

            if (self.is_dirty or self.cached_value == null) {
                self.recompute();
            }

            return self.cached_value.?;
        }

        /// Get without tracking (for debugging/logging).
        pub fn peek(self: *Self) ?T {
            return self.cached_value;
        }

        /// Force recomputation on next access.
        pub fn invalidate(self: *Self) void {
            self.is_dirty = true;
        }

        /// Subscribe to changes.
        pub fn subscribe(self: *Self, callback: tracker.SubscriberFn, ctx: ?*anyopaque) !void {
            try self.subscribers.append(self.allocator, .{
                .callback = callback,
                .ctx = ctx,
            });
        }

        /// Get the unique node ID.
        pub fn getId(self: *const Self) tracker.NodeId {
            return self.node_id;
        }

        fn recompute(self: *Self) void {
            // Free old dependencies
            if (self.dependencies.len > 0) {
                self.allocator.free(self.dependencies);
            }

            // Track new dependencies
            var tracking_ctx = tracker.TrackingContext.init(self.allocator);
            defer tracking_ctx.deinit();

            _ = tracker.beginTracking(&tracking_ctx);
            const new_value = self.compute_fn(self);
            tracker.endTracking(null);

            // Store dependencies
            self.dependencies = tracking_ctx.consumeDependencies();

            // Check if value changed
            const changed = if (self.cached_value) |old| !std.meta.eql(old, new_value) else true;

            self.cached_value = new_value;
            self.is_dirty = false;

            if (changed) {
                self.notifySubscribers();
            }
        }

        fn notifySubscribers(self: *Self) void {
            for (self.subscribers.items) |sub| {
                tracker.notify(sub.callback, sub.ctx);
            }
        }

        /// Mark as dirty when a dependency changes.
        pub fn markDirty(self: *Self) void {
            if (!self.is_dirty) {
                self.is_dirty = true;
                // Propagate to subscribers
                self.notifySubscribers();
            }
        }
    };
}

/// Convenience wrapper for creating computeds with captured state.
pub fn ComputedWithContext(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        inner: Computed(T),
        ctx: Context,

        pub fn init(
            allocator: std.mem.Allocator,
            compute_fn: *const fn (*Context) T,
            ctx: Context,
        ) Self {
            const wrapper = struct {
                fn compute(computed: *Computed(T)) T {
                    const context: *Context = @ptrCast(@alignCast(computed.context));
                    return compute_fn(context);
                }
            };

            var result = Self{
                .ctx = ctx,
                .inner = Computed(T).init(allocator, wrapper.compute, null),
            };
            result.inner.context = &result.ctx;
            return result;
        }

        pub fn get(self: *Self) T {
            return self.inner.get();
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }
    };
}

test "Computed basic derivation" {
    var base = signal_mod.Signal(i32).init(std.testing.allocator, 10);
    defer base.deinit();

    const ComputeFn = struct {
        var signal_ptr: *signal_mod.Signal(i32) = undefined;

        fn compute(_: *Computed(i32)) i32 {
            return signal_ptr.get() * 2;
        }
    };
    ComputeFn.signal_ptr = &base;

    var doubled = Computed(i32).init(std.testing.allocator, ComputeFn.compute, null);
    defer doubled.deinit();

    try std.testing.expectEqual(@as(i32, 20), doubled.get());

    base.set(21);
    doubled.invalidate();
    try std.testing.expectEqual(@as(i32, 42), doubled.get());
}

test "Computed tracks dependencies" {
    var a = signal_mod.Signal(i32).init(std.testing.allocator, 1);
    defer a.deinit();

    var b = signal_mod.Signal(i32).init(std.testing.allocator, 2);
    defer b.deinit();

    const ComputeFn = struct {
        var a_ptr: *signal_mod.Signal(i32) = undefined;
        var b_ptr: *signal_mod.Signal(i32) = undefined;

        fn compute(_: *Computed(i32)) i32 {
            return a_ptr.get() + b_ptr.get();
        }
    };
    ComputeFn.a_ptr = &a;
    ComputeFn.b_ptr = &b;

    var sum = Computed(i32).init(std.testing.allocator, ComputeFn.compute, null);
    defer sum.deinit();

    try std.testing.expectEqual(@as(i32, 3), sum.get());
    try std.testing.expectEqual(@as(usize, 2), sum.dependencies.len);
}
