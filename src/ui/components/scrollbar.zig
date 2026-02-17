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

const track_width: c_int = 12;
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
    const groove_track = insetRect(layout.track_rect, 2);
    const thumb_radius = @max(1, @divFloor(layout.thumb_rect.w, 2));
    const thumb_glow_rect = outsetRect(layout.thumb_rect, 1);
    const inner_thumb = insetRect(layout.thumb_rect, 1);

    const track_outer_top = c.SDL_Color{
        .r = 54,
        .g = 62,
        .b = 72,
        .a = alphaScaled(125, state.alpha),
    };
    const track_outer_bottom = c.SDL_Color{
        .r = 34,
        .g = 41,
        .b = 52,
        .a = alphaScaled(145, state.alpha),
    };
    fillRoundedVerticalGradient(renderer, layout.track_rect, track_radius, track_outer_top, track_outer_bottom);

    const track_inner_top = c.SDL_Color{
        .r = 244,
        .g = 247,
        .b = 251,
        .a = alphaScaled(102, state.alpha),
    };
    const track_inner_bottom = c.SDL_Color{
        .r = 212,
        .g = 220,
        .b = 230,
        .a = alphaScaled(122, state.alpha),
    };
    fillRoundedVerticalGradient(renderer, inner_track, @max(1, track_radius - 1), track_inner_top, track_inner_bottom);

    const groove_top = c.SDL_Color{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = alphaScaled(42, state.alpha),
    };
    const groove_bottom = c.SDL_Color{
        .r = 221,
        .g = 227,
        .b = 236,
        .a = alphaScaled(52, state.alpha),
    };
    fillRoundedVerticalGradient(renderer, groove_track, @max(1, track_radius - 2), groove_top, groove_bottom);

    const edge = c.SDL_Color{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = alphaScaled(68, state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, edge.r, edge.g, edge.b, edge.a);
    primitives.drawRoundedBorder(renderer, inner_track, @max(1, track_radius - 1));

    const hover_boost: i32 = if (state.dragging) 34 else if (state.hovered) 16 else 0;

    const glow_top = c.SDL_Color{
        .r = darkenChannel(accent.r, 36),
        .g = darkenChannel(accent.g, 30),
        .b = darkenChannel(accent.b, 22),
        .a = alphaScaled(@intCast(std.math.clamp(135 + hover_boost, 0, 255)), state.alpha),
    };
    const glow_bottom = c.SDL_Color{
        .r = darkenChannel(accent.r, 22),
        .g = darkenChannel(accent.g, 18),
        .b = darkenChannel(accent.b, 12),
        .a = alphaScaled(@intCast(std.math.clamp(118 + hover_boost, 0, 255)), state.alpha),
    };
    fillRoundedVerticalGradient(renderer, thumb_glow_rect, thumb_radius + 1, glow_top, glow_bottom);

    const thumb_top = c.SDL_Color{
        .r = lightenChannel(accent.r, 122),
        .g = lightenChannel(accent.g, 114),
        .b = lightenChannel(accent.b, 106),
        .a = alphaScaled(@intCast(std.math.clamp(202 + hover_boost, 0, 255)), state.alpha),
    };
    const thumb_bottom = c.SDL_Color{
        .r = lightenChannel(accent.r, 56),
        .g = lightenChannel(accent.g, 48),
        .b = lightenChannel(accent.b, 44),
        .a = alphaScaled(@intCast(std.math.clamp(214 + hover_boost, 0, 255)), state.alpha),
    };
    fillRoundedVerticalGradient(renderer, layout.thumb_rect, thumb_radius, thumb_top, thumb_bottom);

    if (inner_thumb.w > 2 and inner_thumb.h > 4) {
        const inner_top = c.SDL_Color{
            .r = lightenChannel(accent.r, 136),
            .g = lightenChannel(accent.g, 128),
            .b = lightenChannel(accent.b, 120),
            .a = alphaScaled(@intCast(std.math.clamp(88 + hover_boost, 0, 255)), state.alpha),
        };
        const inner_bottom = c.SDL_Color{
            .r = lightenChannel(accent.r, 72),
            .g = lightenChannel(accent.g, 64),
            .b = lightenChannel(accent.b, 56),
            .a = alphaScaled(@intCast(std.math.clamp(108 + hover_boost, 0, 255)), state.alpha),
        };
        fillRoundedVerticalGradient(renderer, inner_thumb, @max(1, thumb_radius - 1), inner_top, inner_bottom);
    }

    const sheen_w = @max(2, @divFloor(layout.thumb_rect.w, 3));
    const sheen_rect = geom.Rect{
        .x = layout.thumb_rect.x + @max(1, @divFloor(layout.thumb_rect.w, 6)),
        .y = layout.thumb_rect.y + 2,
        .w = sheen_w,
        .h = @max(1, layout.thumb_rect.h - 4),
    };
    const sheen_top = c.SDL_Color{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = alphaScaled(@intCast(std.math.clamp(130 + hover_boost, 0, 255)), state.alpha),
    };
    const sheen_bottom = c.SDL_Color{
        .r = 212,
        .g = 240,
        .b = 255,
        .a = alphaScaled(@intCast(std.math.clamp(20 + @divFloor(hover_boost, 2), 0, 255)), state.alpha),
    };
    fillRoundedVerticalGradient(renderer, sheen_rect, @max(1, @divFloor(sheen_rect.w, 2)), sheen_top, sheen_bottom);

    const core_glare = geom.Rect{
        .x = sheen_rect.x + @max(0, @divFloor(sheen_rect.w - 2, 2)),
        .y = sheen_rect.y + 1,
        .w = @max(1, @min(2, sheen_rect.w)),
        .h = @max(1, sheen_rect.h - 2),
    };
    const glare = c.SDL_Color{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = alphaScaled(@intCast(std.math.clamp(116 + hover_boost, 0, 255)), state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, glare.r, glare.g, glare.b, glare.a);
    primitives.fillRoundedRect(renderer, core_glare, @max(1, @divFloor(core_glare.w, 2)));

    const outer_border = c.SDL_Color{
        .r = darkenChannel(accent.r, 38),
        .g = darkenChannel(accent.g, 32),
        .b = darkenChannel(accent.b, 24),
        .a = alphaScaled(@intCast(std.math.clamp(172 + @divFloor(hover_boost, 2), 0, 255)), state.alpha),
    };
    _ = c.SDL_SetRenderDrawColor(renderer, outer_border.r, outer_border.g, outer_border.b, outer_border.a);
    primitives.drawRoundedBorder(renderer, layout.thumb_rect, thumb_radius);

    if (inner_thumb.w > 2 and inner_thumb.h > 2) {
        const inner_border = c.SDL_Color{
            .r = 255,
            .g = 255,
            .b = 255,
            .a = alphaScaled(74, state.alpha),
        };
        _ = c.SDL_SetRenderDrawColor(renderer, inner_border.r, inner_border.g, inner_border.b, inner_border.a);
        primitives.drawRoundedBorder(renderer, inner_thumb, @max(1, thumb_radius - 1));
    }
}

fn insetRect(rect: geom.Rect, amount: c_int) geom.Rect {
    return .{
        .x = rect.x + amount,
        .y = rect.y + amount,
        .w = @max(1, rect.w - amount * 2),
        .h = @max(1, rect.h - amount * 2),
    };
}

fn outsetRect(rect: geom.Rect, amount: c_int) geom.Rect {
    return .{
        .x = rect.x - amount,
        .y = rect.y - amount,
        .w = rect.w + amount * 2,
        .h = rect.h + amount * 2,
    };
}

fn fillRoundedVerticalGradient(
    renderer: *c.SDL_Renderer,
    rect: geom.Rect,
    radius: c_int,
    top: c.SDL_Color,
    bottom: c.SDL_Color,
) void {
    if (rect.w <= 0 or rect.h <= 0) return;

    const clamped_radius = std.math.clamp(radius, 0, @divFloor(@min(rect.w, rect.h), 2));
    const fx = @as(f32, @floatFromInt(rect.x));
    const fy = @as(f32, @floatFromInt(rect.y));
    const frad = @as(f32, @floatFromInt(clamped_radius));
    const row_count: f32 = @floatFromInt(@max(1, rect.h - 1));

    var y: c_int = 0;
    while (y < rect.h) : (y += 1) {
        const t = @as(f32, @floatFromInt(y)) / row_count;
        const row_color = lerpColor(top, bottom, t);
        _ = c.SDL_SetRenderDrawColor(renderer, row_color.r, row_color.g, row_color.b, row_color.a);

        const inset = roundedInsetForRow(y, rect.h, clamped_radius, frad);
        const left = fx + inset;
        const right = fx + @as(f32, @floatFromInt(rect.w)) - inset - 1.0;
        if (right < left) continue;

        _ = c.SDL_RenderLine(
            renderer,
            left,
            fy + @as(f32, @floatFromInt(y)),
            right,
            fy + @as(f32, @floatFromInt(y)),
        );
    }
}

fn roundedInsetForRow(y: c_int, h: c_int, radius: c_int, frad: f32) f32 {
    if (radius <= 0) return 0.0;
    if (y < radius) {
        const dy = frad - @as(f32, @floatFromInt(y)) - 0.5;
        const dx_sq = frad * frad - dy * dy;
        if (dx_sq <= 0.0) return frad;
        return frad - @sqrt(dx_sq);
    }

    const bottom_start = h - radius;
    if (y >= bottom_start) {
        const dy = @as(f32, @floatFromInt(y)) - (@as(f32, @floatFromInt(h)) - frad) + 0.5;
        const dx_sq = frad * frad - dy * dy;
        if (dx_sq <= 0.0) return frad;
        return frad - @sqrt(dx_sq);
    }

    return 0.0;
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

fn lerpColor(a: c.SDL_Color, b: c.SDL_Color, t: f32) c.SDL_Color {
    return .{
        .r = lerpChannel(a.r, b.r, t),
        .g = lerpChannel(a.g, b.g, t),
        .b = lerpChannel(a.b, b.b, t),
        .a = lerpChannel(a.a, b.a, t),
    };
}

fn lerpChannel(a: u8, b: u8, t: f32) u8 {
    const clamped_t = std.math.clamp(t, 0.0, 1.0);
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(af + (bf - af) * clamped_t);
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
