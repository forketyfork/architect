const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const easing = @import("../../anim/easing.zig");
const dpi = @import("../scale.zig");

pub const ExpandingOverlay = struct {
    state: State = .Closed,
    start_time: i64 = 0,
    start_size: c_int,
    target_size: c_int,
    slot: usize,
    margin: c_int,
    small_size: c_int,
    large_size: c_int,
    duration_ms: i64,

    pub const State = enum { Closed, Expanding, Open, Collapsing };

    pub fn init(slot: usize, margin: c_int, small: c_int, large: c_int, duration_ms: i64) ExpandingOverlay {
        return .{
            .slot = slot,
            .margin = margin,
            .small_size = small,
            .large_size = large,
            .duration_ms = duration_ms,
            .start_size = small,
            .target_size = small,
        };
    }

    pub fn startExpanding(self: *ExpandingOverlay, now: i64) void {
        self.state = .Expanding;
        self.start_time = now;
        self.start_size = self.small_size;
        self.target_size = self.large_size;
    }

    pub fn startCollapsing(self: *ExpandingOverlay, now: i64) void {
        self.state = .Collapsing;
        self.start_time = now;
        self.start_size = self.large_size;
        self.target_size = self.small_size;
    }

    pub fn isAnimating(self: *const ExpandingOverlay) bool {
        return self.state == .Expanding or self.state == .Collapsing;
    }

    pub fn isComplete(self: *const ExpandingOverlay, now: i64) bool {
        const elapsed = now - self.start_time;
        return elapsed >= self.duration_ms;
    }

    pub fn currentSize(self: *const ExpandingOverlay, now: i64, ui_scale: f32) c_int {
        const elapsed = now - self.start_time;
        const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms)));
        const eased = easing.easeInOutCubic(progress);
        const size_diff = self.target_size - self.start_size;
        const unscaled = self.start_size + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(size_diff)) * eased));
        return dpi.scale(unscaled, ui_scale);
    }

    pub fn rect(self: *const ExpandingOverlay, now: i64, window_width: c_int, window_height: c_int, ui_scale: f32) geom.Rect {
        _ = window_height;
        const margin = dpi.scale(self.margin, ui_scale);
        const size = self.currentSize(now, ui_scale);
        const spacing = dpi.scale(self.small_size + self.margin, ui_scale);
        const x = window_width - margin - size - @as(c_int, @intCast(self.slot)) * spacing;
        const y = margin;
        return geom.Rect{ .x = x, .y = y, .w = size, .h = size };
    }
};
