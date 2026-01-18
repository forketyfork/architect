// Effect: Side effects that run automatically when dependencies change.
//
// An Effect wraps a function that performs side effects (rendering, logging,
// network calls, etc.) and automatically re-runs when any tracked reactive
// values change.
//
// Usage:
//   var count = Signal(i32).init(allocator, 0);
//
//   var logger = try Effect.init(allocator, struct {
//       fn run() void {
//           std.debug.print("Count is now: {}\n", .{count.get()});
//       }
//   }.run);
//   defer logger.deinit();
//
// The effect runs immediately and then again whenever count changes.

const std = @import("std");
const tracker = @import("tracker.zig");

/// Side effect that re-runs when tracked dependencies change.
pub const Effect = struct {
    allocator: std.mem.Allocator,
    effect_fn: *const fn (?*anyopaque) void,
    context: ?*anyopaque,
    dependencies: []tracker.NodeId = &[_]tracker.NodeId{},
    is_disposed: bool = false,
    is_scheduled: bool = false,

    /// Initialize and immediately run the effect.
    pub fn init(
        allocator: std.mem.Allocator,
        effect_fn: *const fn (?*anyopaque) void,
        context: ?*anyopaque,
    ) !Effect {
        var self = Effect{
            .allocator = allocator,
            .effect_fn = effect_fn,
            .context = context,
        };

        // Run immediately to collect initial dependencies
        self.run();

        return self;
    }

    /// Clean up the effect and stop reacting.
    pub fn deinit(self: *Effect) void {
        self.is_disposed = true;
        if (self.dependencies.len > 0) {
            self.allocator.free(self.dependencies);
            self.dependencies = &[_]tracker.NodeId{};
        }
    }

    /// Manually trigger the effect to re-run.
    pub fn run(self: *Effect) void {
        if (self.is_disposed) return;

        // Free old dependencies
        if (self.dependencies.len > 0) {
            self.allocator.free(self.dependencies);
        }

        // Track new dependencies
        var tracking_ctx = tracker.TrackingContext.init(self.allocator);
        defer tracking_ctx.deinit();

        _ = tracker.beginTracking(&tracking_ctx);
        self.effect_fn(self.context);
        tracker.endTracking(null);

        // Store dependencies
        self.dependencies = tracking_ctx.consumeDependencies();
        self.is_scheduled = false;
    }

    /// Schedule the effect to run (called when dependencies change).
    pub fn schedule(self: *Effect) void {
        if (self.is_disposed or self.is_scheduled) return;
        self.is_scheduled = true;

        // In a real implementation, this would be queued for the next tick.
        // For now, run immediately.
        self.run();
    }

    /// Check if this effect depends on a given node.
    pub fn dependsOn(self: *const Effect, node_id: tracker.NodeId) bool {
        for (self.dependencies) |dep| {
            if (dep == node_id) return true;
        }
        return false;
    }
};

/// Creates an effect with a type-safe context.
pub fn EffectWithContext(comptime Context: type) type {
    return struct {
        const Self = @This();

        inner: Effect,
        ctx: Context,

        pub fn init(
            allocator: std.mem.Allocator,
            effect_fn: *const fn (*Context) void,
            ctx: Context,
        ) !Self {
            const wrapper = struct {
                fn run(context: ?*anyopaque) void {
                    const typed_ctx: *Context = @ptrCast(@alignCast(context));
                    effect_fn(typed_ctx);
                }
            };

            var result: Self = .{
                .ctx = ctx,
                .inner = undefined,
            };
            result.inner = try Effect.init(allocator, wrapper.run, &result.ctx);
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn run(self: *Self) void {
            self.inner.run();
        }
    };
}

/// Autorun: convenience wrapper that creates and manages an effect.
pub fn autorun(
    allocator: std.mem.Allocator,
    effect_fn: *const fn (?*anyopaque) void,
    context: ?*anyopaque,
) !*Effect {
    const effect = try allocator.create(Effect);
    effect.* = try Effect.init(allocator, effect_fn, context);
    return effect;
}

/// Reaction: runs a side effect when a specific expression changes.
pub const Reaction = struct {
    allocator: std.mem.Allocator,
    data_fn: *const fn (?*anyopaque) ?*anyopaque,
    effect_fn: *const fn (?*anyopaque, ?*anyopaque) void,
    context: ?*anyopaque,
    last_data: ?*anyopaque = null,
    inner_effect: ?Effect = null,
    is_disposed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        data_fn: *const fn (?*anyopaque) ?*anyopaque,
        effect_fn: *const fn (?*anyopaque, ?*anyopaque) void,
        context: ?*anyopaque,
    ) Reaction {
        return .{
            .allocator = allocator,
            .data_fn = data_fn,
            .effect_fn = effect_fn,
            .context = context,
        };
    }

    pub fn start(self: *Reaction) !void {
        const wrapper = struct {
            fn run(ctx: ?*anyopaque) void {
                const reaction: *Reaction = @ptrCast(@alignCast(ctx));
                const new_data = reaction.data_fn(reaction.context);

                // Check if data changed (pointer comparison for simplicity)
                if (new_data != reaction.last_data) {
                    reaction.effect_fn(new_data, reaction.context);
                    reaction.last_data = new_data;
                }
            }
        };

        self.inner_effect = try Effect.init(self.allocator, wrapper.run, self);
    }

    pub fn deinit(self: *Reaction) void {
        self.is_disposed = true;
        if (self.inner_effect) |*effect| {
            effect.deinit();
        }
    }
};

test "Effect runs immediately" {
    var run_count: u32 = 0;
    const effect_fn = struct {
        fn run(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.run;

    var effect = try Effect.init(std.testing.allocator, effect_fn, &run_count);
    defer effect.deinit();

    try std.testing.expectEqual(@as(u32, 1), run_count);
}

test "Effect can be manually re-run" {
    var run_count: u32 = 0;
    const effect_fn = struct {
        fn run(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.run;

    var effect = try Effect.init(std.testing.allocator, effect_fn, &run_count);
    defer effect.deinit();

    effect.run();
    effect.run();

    try std.testing.expectEqual(@as(u32, 3), run_count);
}

test "Effect stops after dispose" {
    var run_count: u32 = 0;
    const effect_fn = struct {
        fn run(ctx: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    }.run;

    var effect = try Effect.init(std.testing.allocator, effect_fn, &run_count);

    effect.deinit();
    effect.run(); // Should not run

    try std.testing.expectEqual(@as(u32, 1), run_count);
}
