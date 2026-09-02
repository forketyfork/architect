const std = @import("std");

/// Helper to guarantee a component gets a frame immediately after a state
/// transition, even when the main loop is throttling idle rendering.
///
/// The owning component MUST call `markDrawn()` at the start of its `render`
/// (or per-frame) hook, before any visibility early return. The frame loop
/// renders every registered component on each presented frame, so a guard
/// armed while a component becomes hidden can only be cleared on that path.
pub const FirstFrameGuard = struct {
    pending: bool = false,

    pub fn markTransition(self: *FirstFrameGuard) void {
        self.pending = true;
    }

    pub fn markDrawn(self: *FirstFrameGuard) void {
        self.pending = false;
    }

    pub fn wantsFrame(self: *const FirstFrameGuard) bool {
        return self.pending;
    }
};

test "markDrawn clears an armed guard and is idempotent" {
    var guard: FirstFrameGuard = .{};

    try std.testing.expect(!guard.wantsFrame());
    guard.markTransition();
    try std.testing.expect(guard.wantsFrame());

    guard.markDrawn();
    try std.testing.expect(!guard.wantsFrame());
    guard.markDrawn();
    try std.testing.expect(!guard.wantsFrame());
}
