const std = @import("std");
const c = @import("../c.zig");
const geom = @import("../geom.zig");

/// Animated "busy" shimmer: dims a rectangle and sweeps a soft diagonal light
/// band across it. Shared by the quit-teardown overlay and the resize-settle
/// hold so both read as the same visual language.
pub const Options = struct {
    /// Alpha of the dimming layer drawn under the band.
    base_alpha: u8,
    /// Peak alpha of the sweeping band.
    band_alpha: u8,
    /// Duration of one full sweep across the rect.
    cycle_ms: i64 = 1400,
    /// Band width as a fraction of the rect width.
    width_divisor: c_int = 12,
    min_width: c_int = 30,
    gradient_steps: usize = 4,
    /// Horizontal drift of the band per vertical pixel (negative leans left).
    slope: f32 = -0.42,
};

const SweepGeometry = struct {
    center_x: f32,
    center_y: f32,
    half_core_w: f32,
    half_total_w: f32,
};

fn halfBandWidth(rect: geom.Rect, opts: Options) f32 {
    const band_w: c_int = @max(@divFloor(rect.w, opts.width_divisor), opts.min_width);
    return @as(f32, @floatFromInt(band_w)) * 0.5;
}

/// Overscan for the cyclic wait shimmer: a generous off-rect stretch so the
/// band reads as a periodic sparkle with a pause between passes.
fn waitMargin(rect: geom.Rect, opts: Options) f32 {
    return @as(f32, @floatFromInt(@max(rect.w, rect.h))) + halfBandWidth(rect, opts);
}

/// Minimal overscan for the one-shot reveal: just enough that the band's
/// glow is fully off-rect at progress 0 and 1 on every row (assumes a
/// non-positive slope, where the extremes sit at the top-left and
/// bottom-right corners). Anything larger is dead time in the animation.
fn revealMargin(rect: geom.Rect, opts: Options) f32 {
    return halfBandWidth(rect, opts) / (1.0 - @min(opts.slope, 0.0));
}

/// Position of the diagonal band for a sweep progress in [0, 1] with the
/// given off-rect overscan margin. Progress 0 leaves the whole rect
/// un-swept and progress 1 leaves it fully swept.
fn sweepGeometry(rect: geom.Rect, progress: f32, margin: f32, opts: Options) SweepGeometry {
    const half_total_w = halfBandWidth(rect, opts);
    return .{
        .center_x = -margin + progress * (@as(f32, @floatFromInt(rect.w)) + margin * 2.0),
        .center_y = -margin + progress * (@as(f32, @floatFromInt(rect.h)) + margin * 2.0),
        .half_core_w = half_total_w * 0.38,
        .half_total_w = half_total_w,
    };
}

/// Horizontal position of the sweep front for a row (local coordinates).
fn sweepFrontX(geometry: SweepGeometry, y_local: f32, opts: Options) f32 {
    return geometry.center_x + opts.slope * (y_local - geometry.center_y);
}

fn drawBand(renderer: *c.SDL_Renderer, rect: geom.Rect, geometry: SweepGeometry, opts: Options) void {
    const rows: usize = @intCast(rect.h);
    for (0..rows) |row| {
        const y_local: c_int = @intCast(row);
        const center = sweepFrontX(geometry, @floatFromInt(y_local), opts);
        drawBandRow(renderer, rect, y_local, center, geometry.half_core_w, geometry.half_total_w, opts);
    }
}

pub fn draw(renderer: *c.SDL_Renderer, rect: geom.Rect, now_ms: i64, opts: Options) void {
    if (rect.w <= 0 or rect.h <= 0) return;

    const cycle_ms = @max(opts.cycle_ms, 1);
    const phase_ms = @mod(now_ms, cycle_ms);
    const progress = @as(f32, @floatFromInt(phase_ms)) / @as(f32, @floatFromInt(cycle_ms));

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 85, 85, 85, opts.base_alpha);
    const dim_rect = c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = c.SDL_RenderFillRect(renderer, &dim_rect);

    drawBand(renderer, rect, sweepGeometry(rect, progress, waitMargin(rect, opts), opts), opts);
}

/// Height of the horizontal strips approximating the diagonal front in
/// `drawSweepReveal`. At slope ~0.4 a 4px strip staircases by under 2px,
/// which the glow band riding the front fully hides.
const sweep_strip_h: c_int = 4;

/// One-shot sweep that reveals whatever is already rendered underneath:
/// ahead of the moving diagonal front the pre-transition `old` texture is
/// drawn (proportionally sliced, so differently-sized content stretches the
/// same way the settle hold stretched it), behind the front the underlying
/// content shows through, and the shimmer band rides the front itself.
///
/// The reveal travels with the minimal overscan but at the SAME pixel speed
/// as the cyclic wait shimmer (whose long off-rect stretch would otherwise
/// turn into dead time here): the caller's progress spans the wait
/// shimmer's travel distance, and the reveal finishes as soon as its own,
/// much shorter distance is covered.
pub fn drawSweepReveal(
    renderer: *c.SDL_Renderer,
    rect: geom.Rect,
    old: *c.SDL_Texture,
    old_w: f32,
    old_h: f32,
    progress: f32,
    opts: Options,
) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    if (old_w <= 0 or old_h <= 0) return;

    const margin = revealMargin(rect, opts);
    const travel = @as(f32, @floatFromInt(rect.w)) + margin * 2.0;
    const wait_travel = @as(f32, @floatFromInt(rect.w)) + waitMargin(rect, opts) * 2.0;
    const t = std.math.clamp(progress * wait_travel / travel, 0.0, 1.0);
    const geometry = sweepGeometry(rect, t, margin, opts);
    const rect_w_f = @as(f32, @floatFromInt(rect.w));
    const rect_h_f = @as(f32, @floatFromInt(rect.h));

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    var y: c_int = 0;
    while (y < rect.h) : (y += sweep_strip_h) {
        const strip_h = @min(sweep_strip_h, rect.h - y);
        const strip_center_y = @as(f32, @floatFromInt(y)) + @as(f32, @floatFromInt(strip_h)) * 0.5;
        const front = sweepFrontX(geometry, strip_center_y, opts);

        const left_f = std.math.clamp(front, 0.0, rect_w_f);
        if (left_f >= rect_w_f) continue;

        const src = c.SDL_FRect{
            .x = left_f / rect_w_f * old_w,
            .y = @as(f32, @floatFromInt(y)) / rect_h_f * old_h,
            .w = (rect_w_f - left_f) / rect_w_f * old_w,
            .h = @as(f32, @floatFromInt(strip_h)) / rect_h_f * old_h,
        };
        const dst = c.SDL_FRect{
            .x = @as(f32, @floatFromInt(rect.x)) + left_f,
            .y = @floatFromInt(rect.y + y),
            .w = rect_w_f - left_f,
            .h = @floatFromInt(strip_h),
        };
        _ = c.SDL_RenderTexture(renderer, old, &src, &dst);
    }

    drawBand(renderer, rect, geometry, opts);
}

test "sweep front covers the whole rect at progress 0 and none at progress 1" {
    const opts = Options{ .base_alpha = 0, .band_alpha = 0 };
    const rect = geom.Rect{ .x = 0, .y = 0, .w = 1000, .h = 500 };

    // Both margin variants must keep the band's glow fully off-rect at the
    // start and end of a sweep, for every row.
    const margins = [_]f32{ waitMargin(rect, opts), revealMargin(rect, opts) };
    for (margins) |margin| {
        const start = sweepGeometry(rect, 0.0, margin, opts);
        const done = sweepGeometry(rect, 1.0, margin, opts);
        var y: f32 = 0;
        while (y <= 500) : (y += 100) {
            try std.testing.expect(sweepFrontX(start, y, opts) + start.half_total_w <= 0);
            try std.testing.expect(sweepFrontX(done, y, opts) - done.half_total_w >= 1000);
        }
    }
}

test "reveal margin is a small fraction of the wait margin" {
    const opts = Options{ .base_alpha = 0, .band_alpha = 0 };
    const rect = geom.Rect{ .x = 0, .y = 0, .w = 1000, .h = 500 };
    // The wait shimmer overscans by a full window dimension; the reveal only
    // needs to hide the band's glow, so its dead travel stays negligible.
    try std.testing.expect(revealMargin(rect, opts) < halfBandWidth(rect, opts));
    try std.testing.expect(revealMargin(rect, opts) * 10 < waitMargin(rect, opts));
}

fn drawBandRow(
    renderer: *c.SDL_Renderer,
    rect: geom.Rect,
    y_local: c_int,
    center: f32,
    half_core_w: f32,
    half_total_w: f32,
    opts: Options,
) void {
    drawSpan(renderer, rect, y_local, center - half_core_w, center + half_core_w, opts.band_alpha);

    const fade_width = half_total_w - half_core_w;
    if (fade_width <= 0) return;

    const steps_f = @as(f32, @floatFromInt(opts.gradient_steps));
    for (0..opts.gradient_steps) |step| {
        const t0 = @as(f32, @floatFromInt(step)) / steps_f;
        const t1 = @as(f32, @floatFromInt(step + 1)) / steps_f;
        const inner = half_core_w + fade_width * t0;
        const outer = half_core_w + fade_width * t1;
        const alpha_f = @as(f32, @floatFromInt(opts.band_alpha)) * (1.0 - t0) * (1.0 - t0);
        const alpha: u8 = @intFromFloat(@max(0.0, @min(alpha_f, 255.0)));
        if (alpha == 0) continue;

        drawSpan(renderer, rect, y_local, center - outer, center - inner, alpha);
        drawSpan(renderer, rect, y_local, center + inner, center + outer, alpha);
    }
}

fn drawSpan(renderer: *c.SDL_Renderer, rect: geom.Rect, y_local: c_int, left_f: f32, right_f: f32, alpha: u8) void {
    if (alpha == 0 or rect.w <= 0) return;

    var left: c_int = @intFromFloat(@floor(left_f));
    var right: c_int = @intFromFloat(@ceil(right_f));
    if (right <= 0 or left >= rect.w) return;

    left = std.math.clamp(left, 0, rect.w);
    right = std.math.clamp(right, 0, rect.w);
    const span_w = right - left;
    if (span_w <= 0) return;

    _ = c.SDL_SetRenderDrawColor(renderer, 170, 170, 170, alpha);
    const span_rect = c.SDL_FRect{
        .x = @floatFromInt(rect.x + left),
        .y = @floatFromInt(rect.y + y_local),
        .w = @floatFromInt(span_w),
        .h = 1,
    };
    _ = c.SDL_RenderFillRect(renderer, &span_rect);
}
