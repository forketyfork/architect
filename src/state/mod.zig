// State Management Module
//
// A MobX-inspired reactive state engine for Zig applications.
// Provides automatic dependency tracking, computed values, and
// side effects for building reactive UIs.
//
// Core Concepts:
//
// - Signal: Observable state that notifies on change
// - Computed: Derived values that auto-update when dependencies change
// - Effect: Side effects that run when dependencies change
// - Batch/Transaction: Group updates to minimize re-renders
//
// Example:
//
//   const state = @import("state/mod.zig");
//
//   var count = state.Signal(i32).init(allocator, 0);
//   defer count.deinit();
//
//   // Computed values auto-track dependencies
//   var doubled = state.Computed(i32).init(allocator, struct {
//       fn compute(_: *state.Computed(i32)) i32 {
//           return count.get() * 2;
//       }
//   }.compute, null);
//   defer doubled.deinit();
//
//   // Effects run when dependencies change
//   var logger = try state.Effect.init(allocator, struct {
//       fn run(_: ?*anyopaque) void {
//           std.debug.print("Count: {}\n", .{count.get()});
//       }
//   }.run, null);
//   defer logger.deinit();
//
//   // Batch multiple updates
//   state.tracker.beginBatch(allocator);
//   count.set(1);
//   count.set(2);
//   count.set(3);
//   state.tracker.endBatch();  // Effects run once here

const std = @import("std");
pub const tracker = @import("tracker.zig");
pub const signal = @import("signal.zig");
pub const computed = @import("computed.zig");
pub const effect = @import("effect.zig");
pub const store = @import("store.zig");

// Re-export commonly used types
pub const Signal = signal.Signal;
pub const Computed = computed.Computed;
pub const ComputedWithContext = computed.ComputedWithContext;
pub const Effect = effect.Effect;
pub const EffectWithContext = effect.EffectWithContext;
pub const Reaction = effect.Reaction;
pub const Transaction = store.Transaction;
pub const ObservableArray = store.ObservableArray;
pub const ObservableMap = store.ObservableMap;

// Re-export utility functions
pub const runInAction = store.runInAction;
pub const runInActionWithContext = store.runInActionWithContext;
pub const autorun = effect.autorun;

// Re-export tracker utilities
pub const beginBatch = tracker.beginBatch;
pub const endBatch = tracker.endBatch;
pub const untracked = tracker.untracked;
pub const isTracking = tracker.isTracking;

/// Initialize the reactive system. Call once at startup with a long-lived allocator.
pub fn init(allocator: std.mem.Allocator) void {
    tracker.initRegistry(allocator);
}

/// Clean up global reactive state. Call on shutdown if init() was called.
pub fn deinit() void {
    tracker.deinitRegistry();
}

test {
    @import("std").testing.refAllDecls(@This());
}
