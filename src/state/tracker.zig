// Dependency tracker for reactive state management.
//
// The tracker maintains a global context that records which signals are
// accessed during a computation. This enables automatic dependency tracking
// similar to MobX's transparent reactivity model.
//
// Thread-local storage holds the current tracking context, allowing nested
// computations to properly track their own dependencies.

const std = @import("std");

/// Opaque handle identifying a reactive node (signal, computed, or effect).
pub const NodeId = u64;

/// Subscriber callback type. Called when a dependency changes.
pub const SubscriberFn = *const fn (ctx: ?*anyopaque) void;

/// Represents a subscription to a signal.
pub const Subscription = struct {
    callback: SubscriberFn,
    ctx: ?*anyopaque,
};

/// Global tracking context for automatic dependency collection.
/// When non-null, signal accesses are recorded as dependencies.
var current_tracker: ?*TrackingContext = null;

/// Batch depth counter. When > 0, notifications are deferred.
var batch_depth: u32 = 0;

/// Pending notifications accumulated during batching.
var pending_notifications: std.ArrayList(PendingNotification) = .{};
var pending_allocator: ?std.mem.Allocator = null;

const PendingNotification = struct {
    callback: SubscriberFn,
    ctx: ?*anyopaque,
};

/// Context for tracking dependencies during a computation.
pub const TrackingContext = struct {
    allocator: std.mem.Allocator,
    dependencies: std.ArrayList(NodeId) = .{},
    parent: ?*TrackingContext = null,

    pub fn init(allocator: std.mem.Allocator) TrackingContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TrackingContext) void {
        self.dependencies.deinit(self.allocator);
    }

    /// Record a dependency on the given node.
    pub fn track(self: *TrackingContext, node_id: NodeId) void {
        // Avoid duplicate tracking
        for (self.dependencies.items) |id| {
            if (id == node_id) return;
        }
        self.dependencies.append(self.allocator, node_id) catch {};
    }

    /// Get collected dependencies and clear the list.
    pub fn consumeDependencies(self: *TrackingContext) []NodeId {
        const deps = self.dependencies.toOwnedSlice(self.allocator) catch &[_]NodeId{};
        return deps;
    }
};

/// Begin tracking dependencies. Returns the previous context for restoration.
pub fn beginTracking(ctx: *TrackingContext) ?*TrackingContext {
    const parent = current_tracker;
    ctx.parent = parent;
    current_tracker = ctx;
    return parent;
}

/// End tracking and restore the previous context.
pub fn endTracking(previous: ?*TrackingContext) void {
    current_tracker = previous;
}

/// Record access to a node. Called by signals when their value is read.
pub fn recordAccess(node_id: NodeId) void {
    if (current_tracker) |ctx| {
        ctx.track(node_id);
    }
}

/// Check if we're currently tracking dependencies.
pub fn isTracking() bool {
    return current_tracker != null;
}

/// Begin a batch update. Notifications are deferred until the batch ends.
pub fn beginBatch(allocator: std.mem.Allocator) void {
    if (batch_depth == 0) {
        pending_allocator = allocator;
    }
    batch_depth += 1;
}

/// End a batch update. If this is the outermost batch, flush pending notifications.
pub fn endBatch() void {
    if (batch_depth == 0) return;
    batch_depth -= 1;

    if (batch_depth == 0) {
        // Flush all pending notifications
        const items = pending_notifications.items;
        for (items) |notification| {
            notification.callback(notification.ctx);
        }
        if (pending_allocator) |alloc| {
            pending_notifications.deinit(alloc);
            pending_notifications = .{};
        }
        pending_allocator = null;
    }
}

/// Check if we're inside a batch.
pub fn isBatching() bool {
    return batch_depth > 0;
}

/// Queue a notification for later (if batching) or execute immediately.
pub fn notify(callback: SubscriberFn, ctx: ?*anyopaque) void {
    if (batch_depth > 0) {
        if (pending_allocator) |alloc| {
            pending_notifications.append(alloc, .{
                .callback = callback,
                .ctx = ctx,
            }) catch {};
        }
    } else {
        callback(ctx);
    }
}

/// Execute a function with dependency tracking disabled.
pub fn untracked(comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
    const saved = current_tracker;
    current_tracker = null;
    defer current_tracker = saved;
    return @call(.auto, func, args);
}

test "TrackingContext basic tracking" {
    var ctx = TrackingContext.init(std.testing.allocator);
    defer ctx.deinit();

    _ = beginTracking(&ctx);
    defer endTracking(null);

    recordAccess(1);
    recordAccess(2);
    recordAccess(1); // duplicate

    const deps = ctx.consumeDependencies();
    defer std.testing.allocator.free(deps);

    try std.testing.expectEqual(@as(usize, 2), deps.len);
    try std.testing.expectEqual(@as(NodeId, 1), deps[0]);
    try std.testing.expectEqual(@as(NodeId, 2), deps[1]);
}

test "batch notifications" {
    var call_count: u32 = 0;
    const callback = struct {
        fn cb(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.cb;

    beginBatch(std.testing.allocator);
    notify(callback, &call_count);
    notify(callback, &call_count);
    try std.testing.expectEqual(@as(u32, 0), call_count);

    endBatch();
    try std.testing.expectEqual(@as(u32, 2), call_count);
}
