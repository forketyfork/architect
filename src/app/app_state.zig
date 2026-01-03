const std = @import("std");
const c = @import("../c.zig");

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
    PreCollapse,
    CancelPreCollapse,
};

pub const Rect = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub const AnimationState = struct {
    mode: ViewMode,
    focused_session: usize,
    previous_session: usize,
    start_time: i64,
    start_rect: Rect,
    target_rect: Rect,
    escape_press_time: ?i64,

    pub fn easeInOutCubic(t: f32) f32 {
        if (t < 0.5) {
            return 4 * t * t * t;
        } else {
            const p = 2 * t - 2;
            return 1 + p * p * p / 2;
        }
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

pub const ToastNotification = struct {
    message: [256]u8 = undefined,
    message_len: usize = 0,
    start_time: i64 = 0,
    active: bool = false,

    pub fn show(self: *ToastNotification, message: []const u8, current_time: i64) void {
        const len = @min(message.len, self.message.len - 1);
        @memcpy(self.message[0..len], message[0..len]);
        self.message[len] = 0;
        self.message_len = len;
        self.start_time = current_time;
        self.active = true;
    }

    pub fn isVisible(self: *const ToastNotification, current_time: i64) bool {
        if (!self.active) return false;
        const elapsed = current_time - self.start_time;
        return elapsed < NOTIFICATION_DURATION_MS;
    }

    pub fn getAlpha(self: *const ToastNotification, current_time: i64) u8 {
        if (!self.isVisible(current_time)) return 0;
        const elapsed = current_time - self.start_time;
        if (elapsed < NOTIFICATION_FADE_START_MS) {
            return 255;
        }
        const fade_progress = @as(f32, @floatFromInt(elapsed - NOTIFICATION_FADE_START_MS)) /
            @as(f32, @floatFromInt(NOTIFICATION_DURATION_MS - NOTIFICATION_FADE_START_MS));
        const eased_progress = fade_progress * fade_progress * (3.0 - 2.0 * fade_progress);
        const alpha = 255.0 * (1.0 - eased_progress);
        return @intFromFloat(@max(0, @min(255, alpha)));
    }
};

pub const NOTIFICATION_DURATION_MS: i64 = 2500;
pub const NOTIFICATION_FADE_START_MS: i64 = 1500;
pub const PRECOLLAPSE_PAUSE_MS: i64 = 200;
pub const PRECOLLAPSE_DURATION_MS: i64 = 500;
pub const PRECOLLAPSE_SCALE: f32 = 0.99;

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
