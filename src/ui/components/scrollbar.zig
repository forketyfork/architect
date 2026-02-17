const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const easing = @import("../../anim/easing.zig");
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

pub const idle_hide_delay_ms: i64 = 1500;
pub const fade_in_duration_ms: i64 = 130;
pub const fade_out_duration_ms: i64 = 220;

const track_width: c_int = 10;
const edge_margin: c_int = 4;
const track_margin_y: c_int = 4;
const min_thumb_height: c_int = 22;

pub const Metrics = struct {
    total: f32,
    offset: f32,
    viewport: f32,

    pub fn init(total: f32, offset: f32, viewport: f32) Metrics {
        const safe_total = @max(0.0, total);
        const safe_viewport = @max(0.0, viewport);
        const max_offset = @max(0.0, safe_total - safe_viewport);
        return .{
            .total = safe_total,
            .offset = std.math.clamp(offset, 0.0, max_offset),
            .viewport = safe_viewport,
        };
    }

    pub fn maxOffset(self: Metrics) f32 {
        return @max(0.0, self.total - self.viewport);
    }

    pub fn isScrollable(self: Metrics) bool {
        return self.total > self.viewport and self.viewport > 0.0;
    }

    pub fn normalizedOffset(self: Metrics) f32 {
        const max_offset = self.maxOffset();
        if (max_offset <= 0.0) return 0.0;
        return std.math.clamp(self.offset / max_offset, 0.0, 1.0);
    }

    pub fn offsetForRatio(self: Metrics, ratio: f32) f32 {
        return std.math.clamp(ratio, 0.0, 1.0) * self.maxOffset();
    }
};

pub const Layout = struct {
    track_rect: geom.Rect,
    thumb_rect: geom.Rect,
    thumb_travel: c_int,
};

pub const HitTarget = enum {
    none,
    track,
    thumb,
};

pub const State = struct {
    alpha: f32 = 0.0,
    phase: Phase = .hidden,
    phase_start_ms: i64 = 0,
    phase_start_alpha: f32 = 0.0,
    idle_deadline_ms: i64 = 0,
    hovered: bool = false,
    dragging: bool = false,
    drag_grab_offset_px: f32 = 0.0,
    first_frame: FirstFrameGuard = .{},

    const Phase = enum {
        hidden,
        fading_in,
        visible,
        fading_out,
    };

    pub fn hideNow(self: *State) void {
        self.alpha = 0.0;
        self.phase = .hidden;
        self.phase_start_ms = 0;
        self.phase_start_alpha = 0.0;
        self.idle_deadline_ms = 0;
        self.hovered = false;
        self.dragging = false;
        self.drag_grab_offset_px = 0.0;
        self.first_frame.markDrawn();
    }

    pub fn noteActivity(self: *State, now_ms: i64) void {
        self.idle_deadline_ms = now_ms + idle_hide_delay_ms;
        if (self.phase == .hidden or self.phase == .fading_out) {
            self.startFadeIn(now_ms);
        }
    }

    pub fn setHovered(self: *State, hovered: bool, now_ms: i64) void {
        if (hovered == self.hovered) return;
        self.hovered = hovered;
        if (hovered) {
            self.noteActivity(now_ms);
        }
    }

    pub fn beginDrag(self: *State, layout: Layout, mouse_y: c_int, now_ms: i64) void {
        self.dragging = true;
        self.drag_grab_offset_px = @as(f32, @floatFromInt(mouse_y - layout.thumb_rect.y));
        self.noteActivity(now_ms);
    }

    pub fn endDrag(self: *State, now_ms: i64) void {
        if (!self.dragging) return;
        self.dragging = false;
        self.noteActivity(now_ms);
    }

    pub fn update(self: *State, now_ms: i64) void {
        if (self.dragging or self.hovered) {
            self.idle_deadline_ms = now_ms + idle_hide_delay_ms;
            if (self.phase == .hidden or self.phase == .fading_out) {
                self.startFadeIn(now_ms);
            }
        } else if (self.phase == .visible and now_ms >= self.idle_deadline_ms and self.alpha > 0.0) {
            self.startFadeOut(now_ms);
        }

        switch (self.phase) {
            .hidden => {
                self.alpha = 0.0;
            },
            .visible => {
                self.alpha = 1.0;
            },
            .fading_in => {
                const t = normalizedTime(now_ms - self.phase_start_ms, fade_in_duration_ms);
                const eased = easing.easeOutCubic(t);
                self.alpha = self.phase_start_alpha + (1.0 - self.phase_start_alpha) * eased;
                if (t >= 1.0) {
                    self.phase = .visible;
                    self.alpha = 1.0;
                }
            },
            .fading_out => {
                const t = normalizedTime(now_ms - self.phase_start_ms, fade_out_duration_ms);
                const eased = easing.easeInOutCubic(t);
                self.alpha = self.phase_start_alpha * (1.0 - eased);
                if (t >= 1.0) {
                    self.phase = .hidden;
                    self.alpha = 0.0;
                }
            },
        }
    }

    pub fn wantsFrame(self: *const State, now_ms: i64) bool {
        if (self.first_frame.wantsFrame()) return true;
        if (self.phase == .fading_in or self.phase == .fading_out) return true;
        return self.phase == .visible and !self.hovered and !self.dragging and now_ms < self.idle_deadline_ms;
    }

    pub fn markDrawn(self: *State) void {
        self.first_frame.markDrawn();
    }

    fn startFadeIn(self: *State, now_ms: i64) void {
        self.phase = .fading_in;
        self.phase_start_ms = now_ms;
        self.phase_start_alpha = self.alpha;
        self.first_frame.markTransition();
    }

    fn startFadeOut(self: *State, now_ms: i64) void {
        self.phase = .fading_out;
        self.phase_start_ms = now_ms;
        self.phase_start_alpha = self.alpha;
        self.first_frame.markTransition();
    }
};

pub fn reservedWidth(ui_scale: f32) c_int {
    return dpi.scale(track_width, ui_scale) + dpi.scale(edge_margin * 2, ui_scale);
}

pub fn computeLayout(bounds: geom.Rect, ui_scale: f32, metrics: Metrics) ?Layout {
    if (!metrics.isScrollable()) return null;
    if (bounds.w <= 0 or bounds.h <= 0) return null;

    const scaled_w = dpi.scale(track_width, ui_scale);
    const scaled_edge_margin = dpi.scale(edge_margin, ui_scale);
    const scaled_y_margin = dpi.scale(track_margin_y, ui_scale);

    const track_h = bounds.h - scaled_y_margin * 2;
    if (track_h <= 0) return null;

    const track_rect = geom.Rect{
        .x = bounds.x + bounds.w - scaled_w - scaled_edge_margin,
        .y = bounds.y + scaled_y_margin,
        .w = scaled_w,
        .h = track_h,
    };

    if (track_rect.w <= 0 or track_rect.h <= 0) return null;

    const thumb_ratio = std.math.clamp(metrics.viewport / metrics.total, 0.0, 1.0);
    const proportional_h = @as(c_int, @intFromFloat(@as(f32, @floatFromInt(track_rect.h)) * thumb_ratio));
    const min_thumb_h = @min(track_rect.h, dpi.scale(min_thumb_height, ui_scale));
    const thumb_h = std.math.clamp(proportional_h, min_thumb_h, track_rect.h);
    const thumb_travel = @max(0, track_rect.h - thumb_h);
    const thumb_y_offset: c_int = if (thumb_travel > 0)
        @intFromFloat(@as(f32, @floatFromInt(thumb_travel)) * metrics.normalizedOffset())
    else
        0;

    const inset = @max(1, dpi.scale(1, ui_scale));
    const thumb_rect = geom.Rect{
        .x = track_rect.x + inset,
        .y = track_rect.y + thumb_y_offset,
        .w = @max(2, track_rect.w - inset * 2),
        .h = thumb_h,
    };

    return .{
        .track_rect = track_rect,
        .thumb_rect = thumb_rect,
        .thumb_travel = thumb_travel,
    };
}

pub fn hitTest(layout: Layout, x: c_int, y: c_int) HitTarget {
    if (geom.containsPoint(layout.thumb_rect, x, y)) return .thumb;
    if (geom.containsPoint(layout.track_rect, x, y)) return .track;
    return .none;
}

pub fn offsetForDrag(state: *const State, layout: Layout, metrics: Metrics, mouse_y: c_int) f32 {
    const thumb_top = @as(f32, @floatFromInt(mouse_y)) - state.drag_grab_offset_px;
    return offsetForThumbTop(layout, metrics, thumb_top);
}

pub fn offsetForTrackClick(layout: Layout, metrics: Metrics, mouse_y: c_int) f32 {
    const thumb_half_h = @as(f32, @floatFromInt(layout.thumb_rect.h)) / 2.0;
    const thumb_top = @as(f32, @floatFromInt(mouse_y)) - thumb_half_h;
    return offsetForThumbTop(layout, metrics, thumb_top);
}

fn offsetForThumbTop(layout: Layout, metrics: Metrics, thumb_top: f32) f32 {
    if (layout.thumb_travel <= 0) return 0.0;
    const top = @as(f32, @floatFromInt(layout.track_rect.y));
    const travel = @as(f32, @floatFromInt(layout.thumb_travel));
    const ratio = std.math.clamp((thumb_top - top) / travel, 0.0, 1.0);
    return metrics.offsetForRatio(ratio);
}

pub fn render(
    renderer: *c.SDL_Renderer,
    layout: Layout,
    accent: c.SDL_Color,
    state: *State,
) void {
    if (state.alpha <= 0.001) return;

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const track_radius = @max(1, @divFloor(layout.track_rect.w, 2));
    const inner_track = insetRect(layout.track_rect, 1);
    const thumb_radius = @max(1, @divFloor(layout.thumb_rect.w, 2));

    const track_shadow = c.SDL_Color{
        .r = 18,
        .g = 22,
        .b = 28,
        .a = alphaScaled(110, state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, track_shadow.r, track_shadow.g, track_shadow.b, track_shadow.a);
    primitives.fillRoundedRect(renderer, layout.track_rect, track_radius);

    const groove = c.SDL_Color{
        .r = 232,
        .g = 238,
        .b = 245,
        .a = alphaScaled(44, state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, groove.r, groove.g, groove.b, groove.a);
    primitives.fillRoundedRect(renderer, inner_track, @max(1, track_radius - 1));

    const edge = c.SDL_Color{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = alphaScaled(65, state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, edge.r, edge.g, edge.b, edge.a);
    primitives.drawRoundedBorder(renderer, inner_track, @max(1, track_radius - 1));

    const hover_boost: i32 = if (state.dragging) 35 else if (state.hovered) 18 else 0;
    const thumb = c.SDL_Color{
        .r = lightenChannel(accent.r, 22),
        .g = lightenChannel(accent.g, 20),
        .b = lightenChannel(accent.b, 18),
        .a = alphaScaled(@intCast(std.math.clamp(148 + hover_boost, 0, 255)), state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, thumb.r, thumb.g, thumb.b, thumb.a);
    primitives.fillRoundedRect(renderer, layout.thumb_rect, thumb_radius);

    const gloss_rect = geom.Rect{
        .x = layout.thumb_rect.x + 1,
        .y = layout.thumb_rect.y + 1,
        .w = @max(1, layout.thumb_rect.w - 2),
        .h = @max(1, @divFloor(layout.thumb_rect.h, 2)),
    };
    const gloss = c.SDL_Color{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = alphaScaled(70, state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, gloss.r, gloss.g, gloss.b, gloss.a);
    primitives.fillRoundedRect(renderer, gloss_rect, @max(1, @divFloor(gloss_rect.w, 2)));

    const thumb_border = c.SDL_Color{
        .r = darkenChannel(accent.r, 28),
        .g = darkenChannel(accent.g, 26),
        .b = darkenChannel(accent.b, 22),
        .a = alphaScaled(150, state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, thumb_border.r, thumb_border.g, thumb_border.b, thumb_border.a);
    primitives.drawRoundedBorder(renderer, layout.thumb_rect, thumb_radius);
}

fn insetRect(rect: geom.Rect, amount: c_int) geom.Rect {
    return .{
        .x = rect.x + amount,
        .y = rect.y + amount,
        .w = @max(1, rect.w - amount * 2),
        .h = @max(1, rect.h - amount * 2),
    };
}

fn normalizedTime(elapsed_ms: i64, duration_ms: i64) f32 {
    if (duration_ms <= 0) return 1.0;
    if (elapsed_ms <= 0) return 0.0;
    return std.math.clamp(
        @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(duration_ms)),
        0.0,
        1.0,
    );
}

fn alphaScaled(alpha: u8, scale: f32) u8 {
    return @intFromFloat(@as(f32, @floatFromInt(alpha)) * std.math.clamp(scale, 0.0, 1.0));
}

fn lightenChannel(value: u8, amount: u8) u8 {
    return @intCast(@min(@as(u16, value) + amount, 255));
}

fn darkenChannel(value: u8, amount: u8) u8 {
    return @intCast(@max(@as(i32, value) - amount, 0));
}

test "computeLayout keeps thumb proportional and clamped" {
    const bounds = geom.Rect{ .x = 0, .y = 0, .w = 200, .h = 300 };
    const metrics = Metrics.init(100.0, 40.0, 20.0);
    const layout = computeLayout(bounds, 1.0, metrics) orelse return error.TestExpectedNonNull;

    try std.testing.expect(layout.thumb_rect.h >= min_thumb_height);
    try std.testing.expect(layout.thumb_rect.h < layout.track_rect.h);
    try std.testing.expect(layout.thumb_rect.y > layout.track_rect.y);
    try std.testing.expect(layout.thumb_rect.y < layout.track_rect.y + layout.track_rect.h - layout.thumb_rect.h);
}

test "offset mapping handles track clicks and drag limits" {
    const bounds = geom.Rect{ .x = 0, .y = 0, .w = 240, .h = 420 };
    const metrics = Metrics.init(200.0, 0.0, 40.0);
    const layout = computeLayout(bounds, 1.0, metrics) orelse return error.TestExpectedNonNull;

    const top_offset = offsetForTrackClick(layout, metrics, layout.track_rect.y);
    const bottom_offset = offsetForTrackClick(layout, metrics, layout.track_rect.y + layout.track_rect.h);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), top_offset, 0.001);
    try std.testing.expectApproxEqAbs(metrics.maxOffset(), bottom_offset, 0.001);
}

test "state fades in, waits, and fades out with auto-hide timing" {
    var state: State = .{};
    const t0: i64 = 100;

    state.noteActivity(t0);
    try std.testing.expect(state.wantsFrame(t0));

    state.update(t0 + fade_in_duration_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), state.alpha, 0.001);
    try std.testing.expect(state.wantsFrame(t0 + fade_in_duration_ms));

    const before_hide = t0 + idle_hide_delay_ms - 1;
    state.update(before_hide);
    try std.testing.expect(state.alpha > 0.9);
    try std.testing.expect(state.wantsFrame(before_hide));

    const fade_start = t0 + idle_hide_delay_ms + 1;
    state.update(fade_start);
    try std.testing.expect(state.phase == .fading_out);

    const hidden_at = fade_start + fade_out_duration_ms + 1;
    state.update(hidden_at);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), state.alpha, 0.001);
    try std.testing.expect(!state.wantsFrame(hidden_at));
}
