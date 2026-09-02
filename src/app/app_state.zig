const std = @import("std");
const geom = @import("../geom.zig");
const easing = @import("../anim/easing.zig");

pub const animation_duration_ms: i64 = 300;

pub const SessionStatus = enum {
    idle,
    running,
    awaiting_approval,
    done,
};

pub const ViewMode = enum {
    Grid,
    Expanding,
    Full,
    Collapsing,
    PanningLeft,
    PanningRight,
    PanningUp,
    PanningDown,
    GridResizing, // Grid is reflowing or changing dimensions (adding/removing cells)
};

pub const Rect = geom.Rect;

/// True when a session at `idx` contributes visible pixels in the given
/// view mode. Sessions that are not visible must not trigger renders:
/// in Full view, background sessions keep producing output (their
/// `render_epoch` advances) but are never presented, so counting them
/// would keep the app rendering and presenting full-window frames at the
/// maximum rate for content nobody sees.
pub fn sessionVisibleInMode(mode: ViewMode, idx: usize, focused: usize, previous: usize) bool {
    return switch (mode) {
        .Grid, .GridResizing, .Expanding, .Collapsing => true,
        .Full => idx == focused,
        .PanningLeft, .PanningRight, .PanningUp, .PanningDown => idx == focused or idx == previous,
    };
}

pub const AnimationState = struct {
    mode: ViewMode,
    focused_session: usize,
    previous_session: usize,
    start_time: i64,
    start_rect: Rect,
    target_rect: Rect,

    pub fn easeInOutCubic(t: f32) f32 {
        return easing.easeInOutCubic(t);
    }

    pub fn interpolateRect(start: Rect, target: Rect, progress: f32) Rect {
        const eased = easeInOutCubic(progress);
        return Rect{
            .x = start.x + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.x - start.x)) * eased)),
            .y = start.y + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.y - start.y)) * eased)),
            .w = start.w + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.w - start.w)) * eased)),
            .h = start.h + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.h - start.h)) * eased)),
        };
    }

    pub fn getCurrentRect(self: *const AnimationState, current_time: i64) Rect {
        const elapsed = current_time - self.start_time;
        const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, animation_duration_ms));
        return interpolateRect(self.start_rect, self.target_rect, progress);
    }

    pub fn isComplete(self: *const AnimationState, current_time: i64) bool {
        const elapsed = current_time - self.start_time;
        return elapsed >= animation_duration_ms;
    }
};

test "AnimationState.easeInOutCubic" {
    try std.testing.expectEqual(@as(f32, 0.0), AnimationState.easeInOutCubic(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), AnimationState.easeInOutCubic(1.0));

    const mid = AnimationState.easeInOutCubic(0.5);
    try std.testing.expect(mid > 0.4 and mid < 0.6);
}

test "sessionVisibleInMode gates background sessions per view mode" {
    try std.testing.expect(sessionVisibleInMode(.Grid, 3, 0, 0));
    try std.testing.expect(sessionVisibleInMode(.GridResizing, 3, 0, 0));
    try std.testing.expect(sessionVisibleInMode(.Expanding, 3, 0, 0));
    try std.testing.expect(sessionVisibleInMode(.Collapsing, 3, 0, 0));
    try std.testing.expect(sessionVisibleInMode(.Full, 2, 2, 0));
    try std.testing.expect(!sessionVisibleInMode(.Full, 3, 2, 0));
    try std.testing.expect(sessionVisibleInMode(.PanningLeft, 2, 2, 5));
    try std.testing.expect(sessionVisibleInMode(.PanningLeft, 5, 2, 5));
    try std.testing.expect(!sessionVisibleInMode(.PanningLeft, 3, 2, 5));
}

test "AnimationState.interpolateRect" {
    const start = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const target = Rect{ .x = 100, .y = 100, .w = 200, .h = 200 };

    const at_start = AnimationState.interpolateRect(start, target, 0.0);
    try std.testing.expectEqual(start.x, at_start.x);
    try std.testing.expectEqual(start.y, at_start.y);
    try std.testing.expectEqual(start.w, at_start.w);
    try std.testing.expectEqual(start.h, at_start.h);

    const at_end = AnimationState.interpolateRect(start, target, 1.0);
    try std.testing.expectEqual(target.x, at_end.x);
    try std.testing.expectEqual(target.y, at_end.y);
    try std.testing.expectEqual(target.w, at_end.w);
    try std.testing.expectEqual(target.h, at_end.h);

    const at_mid = AnimationState.interpolateRect(start, target, 0.5);
    try std.testing.expect(at_mid.x > start.x and at_mid.x < target.x);
    try std.testing.expect(at_mid.y > start.y and at_mid.y < target.y);
}
