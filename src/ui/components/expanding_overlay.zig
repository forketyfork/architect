const std = @import("std");
const geom = @import("../../geom.zig");
const easing = @import("../../anim/easing.zig");
const dpi = @import("../../dpi.zig");

pub const ExpandingOverlay = struct {
    state: State = .Closed,
    start_time: i64 = 0,
    start_size: c_int,
    target_size: c_int,
    slot: usize,
    layout_x: ?c_int = null,
    margin: c_int,
    small_size: c_int,
    large_size: c_int,
    duration_ms: i64,
    content_height: c_int = 0,

    pub const State = enum {
        Closed,
        Expanding,
        Open,
        Collapsing,

        /// True from the moment the overlay starts opening. An overlay owns
        /// the keyboard and shows its content for the whole expand animation,
        /// not just once it completes — gating on `.Open` alone drops
        /// everything the user types during the expand into the terminal.
        pub fn isOpenOrOpening(self: State) bool {
            return self == .Open or self == .Expanding;
        }
    };

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

    pub fn setContentHeight(self: *ExpandingOverlay, height: c_int) void {
        self.content_height = height;
    }

    /// Sets the left edge of the collapsed pill. Expanded rectangles keep the
    /// same right edge, so the panel grows to the left from this position.
    pub fn setLayoutX(self: *ExpandingOverlay, x: c_int) void {
        self.layout_x = x;
    }

    pub fn startExpanding(self: *ExpandingOverlay, now: i64) void {
        self.state = .Expanding;
        self.start_time = now;
        self.start_size = self.small_size;
        self.target_size = self.large_size;
    }

    /// Collapsing an overlay that is still expanding starts from the size it
    /// currently has, so an interrupted expand reverses instead of snapping to
    /// full size first.
    pub fn startCollapsing(self: *ExpandingOverlay, now: i64) void {
        const from = if (self.state == .Expanding) self.unscaledSize(now) else self.large_size;
        self.state = .Collapsing;
        self.start_time = now;
        self.start_size = from;
        self.target_size = self.small_size;
    }

    pub fn isAnimating(self: *const ExpandingOverlay) bool {
        return self.state == .Expanding or self.state == .Collapsing;
    }

    pub fn isComplete(self: *const ExpandingOverlay, now: i64) bool {
        const elapsed = now - self.start_time;
        return elapsed >= self.duration_ms;
    }

    fn unscaledSize(self: *const ExpandingOverlay, now: i64) c_int {
        const elapsed = now - self.start_time;
        const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms)));
        const eased = easing.easeInOutCubic(progress);
        const size_diff = self.target_size - self.start_size;
        return self.start_size + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(size_diff)) * eased));
    }

    pub fn currentSize(self: *const ExpandingOverlay, now: i64, ui_scale: f32) c_int {
        return dpi.scale(self.unscaledSize(now), ui_scale);
    }

    /// Returns the overlay rectangle for rendering.
    /// Note: content_height is expected to be already scaled by the caller.
    pub fn rect(self: *const ExpandingOverlay, now: i64, window_width: c_int, window_height: c_int, ui_scale: f32) geom.Rect {
        _ = window_height;
        const margin = dpi.scale(self.margin, ui_scale);
        const size = self.currentSize(now, ui_scale);
        const small = dpi.scale(self.small_size, ui_scale);
        const large = dpi.scale(self.large_size, ui_scale);
        const spacing = dpi.scale(self.small_size + self.margin, ui_scale);
        const x = if (self.layout_x) |collapsed_x|
            collapsed_x - (size - small)
        else
            window_width - margin - size - @as(c_int, @intCast(self.slot)) * spacing;
        const y = margin;

        const height = blk: {
            if (self.content_height == 0) {
                break :blk size;
            }

            // content_height is already scaled by the overlay component
            const target_height = self.content_height;

            switch (self.state) {
                .Closed => break :blk small,
                .Open => break :blk target_height,
                .Expanding, .Collapsing => {
                    const progress = @as(f32, @floatFromInt(size - small)) / @as(f32, @floatFromInt(large - small));
                    const height_diff = target_height - small;
                    break :blk small + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(height_diff)) * progress));
                },
            }
        };

        return geom.Rect{ .x = x, .y = y, .w = size, .h = height };
    }
};

// --- Tests ---

test "isOpenOrOpening covers the whole expand animation" {
    try std.testing.expect(ExpandingOverlay.State.Open.isOpenOrOpening());
    try std.testing.expect(ExpandingOverlay.State.Expanding.isOpenOrOpening());
    try std.testing.expect(!ExpandingOverlay.State.Closed.isOpenOrOpening());
    try std.testing.expect(!ExpandingOverlay.State.Collapsing.isOpenOrOpening());
}

test "collapsing an interrupted expand reverses from the current size" {
    var overlay = ExpandingOverlay.init(0, 20, 40, 400, 200);
    overlay.startExpanding(0);

    const mid = overlay.currentSize(100, 1.0);
    try std.testing.expect(mid > 40 and mid < 400);

    overlay.startCollapsing(100);
    // No jump to full size at the moment the direction flips.
    try std.testing.expectEqual(mid, overlay.currentSize(100, 1.0));
    try std.testing.expectEqual(@as(c_int, 40), overlay.currentSize(300, 1.0));
}

test "collapsing from the open state starts at full size" {
    var overlay = ExpandingOverlay.init(0, 20, 40, 400, 200);
    overlay.state = .Open;

    overlay.startCollapsing(1000);
    try std.testing.expectEqual(@as(c_int, 400), overlay.currentSize(1000, 1.0));
    try std.testing.expectEqual(@as(c_int, 40), overlay.currentSize(1200, 1.0));
}

test "layout position keeps the expanded overlay right edge anchored" {
    var overlay = ExpandingOverlay.init(0, 20, 40, 400, 200);
    overlay.setLayoutX(600);
    overlay.startExpanding(0);

    const rect = overlay.rect(100, 800, 800, 1.0);
    try std.testing.expectEqual(@as(c_int, 420), rect.x);
    try std.testing.expectEqual(@as(c_int, 640), rect.x + rect.w);
}
