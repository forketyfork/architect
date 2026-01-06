const std = @import("std");
const geom = @import("../geom.zig");
const easing = @import("../anim/easing.zig");

pub const ANIMATION_DURATION_MS: i64 = 300;

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
};

pub const HelpButtonState = enum {
    Closed,
    Expanding,
    Open,
    Collapsing,
};

pub const Rect = geom.Rect;

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
        const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, ANIMATION_DURATION_MS));
        return interpolateRect(self.start_rect, self.target_rect, progress);
    }

    pub fn isComplete(self: *const AnimationState, current_time: i64) bool {
        const elapsed = current_time - self.start_time;
        return elapsed >= ANIMATION_DURATION_MS;
    }
};

pub const ESC_HOLD_TOTAL_MS: i64 = 700;
pub const ESC_ARC_COUNT: usize = 5;
pub const ESC_ARC_SEGMENT_MS: i64 = ESC_HOLD_TOTAL_MS / ESC_ARC_COUNT;

pub const HELP_BUTTON_SIZE_SMALL: c_int = 40;
pub const HELP_BUTTON_SIZE_LARGE: c_int = 400;
pub const HELP_BUTTON_MARGIN: c_int = 20;
pub const HELP_BUTTON_ANIMATION_DURATION_MS: i64 = 200;

pub const HelpButtonAnimation = struct {
    state: HelpButtonState = .Closed,
    start_time: i64 = 0,
    start_size: c_int = HELP_BUTTON_SIZE_SMALL,
    target_size: c_int = HELP_BUTTON_SIZE_SMALL,

    pub fn startExpanding(self: *HelpButtonAnimation, current_time: i64) void {
        self.state = .Expanding;
        self.start_time = current_time;
        self.start_size = HELP_BUTTON_SIZE_SMALL;
        self.target_size = HELP_BUTTON_SIZE_LARGE;
    }

    pub fn startCollapsing(self: *HelpButtonAnimation, current_time: i64) void {
        self.state = .Collapsing;
        self.start_time = current_time;
        self.start_size = HELP_BUTTON_SIZE_LARGE;
        self.target_size = HELP_BUTTON_SIZE_SMALL;
    }

    pub fn getCurrentSize(self: *const HelpButtonAnimation, current_time: i64) c_int {
        const elapsed = current_time - self.start_time;
        const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, HELP_BUTTON_ANIMATION_DURATION_MS));
        const eased = AnimationState.easeInOutCubic(progress);
        const size_diff = self.target_size - self.start_size;
        return self.start_size + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(size_diff)) * eased));
    }

    pub fn isAnimating(self: *const HelpButtonAnimation) bool {
        return self.state == .Expanding or self.state == .Collapsing;
    }

    pub fn isComplete(self: *const HelpButtonAnimation, current_time: i64) bool {
        const elapsed = current_time - self.start_time;
        return elapsed >= HELP_BUTTON_ANIMATION_DURATION_MS;
    }

    pub fn getRect(self: *const HelpButtonAnimation, current_time: i64, window_width: c_int, window_height: c_int) Rect {
        _ = window_height;
        const size = self.getCurrentSize(current_time);
        const x = window_width - HELP_BUTTON_MARGIN - size;
        const y = HELP_BUTTON_MARGIN;
        return Rect{ .x = x, .y = y, .w = size, .h = size };
    }
};

pub const ESC_INDICATOR_MARGIN: c_int = 40;
pub const ESC_INDICATOR_RADIUS: c_int = 30;

pub const EscapeIndicator = struct {
    active: bool = false,
    start_time: i64 = 0,
    consumed: bool = false,

    pub fn start(self: *EscapeIndicator, current_time: i64) void {
        self.active = true;
        self.start_time = current_time;
        self.consumed = false;
    }

    pub fn stop(self: *EscapeIndicator) void {
        self.active = false;
        self.consumed = false;
    }

    pub fn consume(self: *EscapeIndicator) void {
        self.consumed = true;
    }

    pub fn getCompletedArcs(self: *const EscapeIndicator, current_time: i64) usize {
        if (!self.active) return 0;
        const elapsed = current_time - self.start_time;
        if (elapsed < 0) return 0;
        return @min(ESC_ARC_COUNT, @as(usize, @intCast(@divFloor(elapsed, ESC_ARC_SEGMENT_MS))));
    }

    pub fn isComplete(self: *const EscapeIndicator, current_time: i64) bool {
        if (!self.active) return false;
        const elapsed = current_time - self.start_time;
        if (elapsed < 0) return false;
        return elapsed >= ESC_HOLD_TOTAL_MS;
    }
};

test "AnimationState.easeInOutCubic" {
    try std.testing.expectEqual(@as(f32, 0.0), AnimationState.easeInOutCubic(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), AnimationState.easeInOutCubic(1.0));

    const mid = AnimationState.easeInOutCubic(0.5);
    try std.testing.expect(mid > 0.4 and mid < 0.6);
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
