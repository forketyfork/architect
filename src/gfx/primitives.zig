const std = @import("std");
const c = @import("../c.zig");
const geom = @import("../geom.zig");

const Rect = geom.Rect;

pub fn drawRoundedBorder(renderer: *c.SDL_Renderer, rect: Rect, radius: c_int) void {
    const fx = @as(f32, @floatFromInt(rect.x));
    const fy = @as(f32, @floatFromInt(rect.y));
    const fw = @as(f32, @floatFromInt(rect.w));
    const fh = @as(f32, @floatFromInt(rect.h));
    const clamped = @min(radius, @divFloor(@min(rect.w, rect.h), 2));
    const frad = @as(f32, @floatFromInt(clamped));

    // Straight edges
    _ = c.SDL_RenderLine(renderer, fx + frad, fy, fx + fw - frad - 1.0, fy);
    _ = c.SDL_RenderLine(renderer, fx + frad, fy + fh - 1.0, fx + fw - frad - 1.0, fy + fh - 1.0);
    _ = c.SDL_RenderLine(renderer, fx, fy + frad, fx, fy + fh - frad - 1.0);
    _ = c.SDL_RenderLine(renderer, fx + fw - 1.0, fy + frad, fx + fw - 1.0, fy + fh - frad - 1.0);

    // Corner arcs using angle stepping with connected line segments
    const corners = [_]struct { cx: f32, cy: f32, sx: f32, sy: f32 }{
        .{ .cx = fx + frad, .cy = fy + frad, .sx = -1.0, .sy = -1.0 },
        .{ .cx = fx + fw - frad - 1.0, .cy = fy + frad, .sx = 1.0, .sy = -1.0 },
        .{ .cx = fx + frad, .cy = fy + fh - frad - 1.0, .sx = -1.0, .sy = 1.0 },
        .{ .cx = fx + fw - frad - 1.0, .cy = fy + fh - frad - 1.0, .sx = 1.0, .sy = 1.0 },
    };

    const steps: u32 = @max(8, @as(u32, @intCast(clamped)) * 4);
    const half_pi = std.math.pi / 2.0;

    for (corners) |corner| {
        var prev_x: f32 = corner.cx;
        var prev_y: f32 = corner.cy + corner.sy * frad;
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)) * half_pi;
            const px = corner.cx + corner.sx * frad * @sin(angle);
            const py = corner.cy + corner.sy * frad * @cos(angle);
            _ = c.SDL_RenderLine(renderer, prev_x, prev_y, px, py);
            prev_x = px;
            prev_y = py;
        }
    }
}

/// Draw a filled border of the given thickness and corner radius by scanline-filling the
/// donut region between the outer rounded rect and the inner rounded rect (inset by
/// `thickness`). This produces smooth, uniformly-thick corners without concentric-arc
/// artefacts.
pub fn drawThickBorder(renderer: *c.SDL_Renderer, rect: Rect, thickness: c_int, radius: c_int, color: c.SDL_Color) void {
    if (rect.w <= 0 or rect.h <= 0 or thickness <= 0) return;
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);

    const clamped_r = @min(radius, @divFloor(@min(rect.w, rect.h), 2));
    const inner = Rect{
        .x = rect.x + thickness,
        .y = rect.y + thickness,
        .w = rect.w - thickness * 2,
        .h = rect.h - thickness * 2,
    };
    const inner_r: c_int = if (inner.w > 0 and inner.h > 0)
        @min(@max(0, clamped_r - thickness), @divFloor(@min(inner.w, inner.h), 2))
    else
        0;

    var y: c_int = rect.y;
    while (y < rect.y + rect.h) : (y += 1) {
        const outer_span = roundedRectXSpan(rect, clamped_r, y) orelse continue;
        const fy = @as(f32, @floatFromInt(y));

        const in_inner_rows = inner.w > 0 and inner.h > 0 and y >= inner.y and y < inner.y + inner.h;
        if (in_inner_rows) {
            if (roundedRectXSpan(inner, inner_r, y)) |inner_span| {
                if (inner_span.left > outer_span.left) {
                    _ = c.SDL_RenderLine(renderer, outer_span.left, fy, inner_span.left - 1.0, fy);
                }
                if (outer_span.right > inner_span.right) {
                    _ = c.SDL_RenderLine(renderer, inner_span.right + 1.0, fy, outer_span.right, fy);
                }
                continue;
            }
        }
        _ = c.SDL_RenderLine(renderer, outer_span.left, fy, outer_span.right, fy);
    }
}

const XSpan = struct { left: f32, right: f32 };

fn roundedRectXSpan(rect: Rect, radius: c_int, y: c_int) ?XSpan {
    if (y < rect.y or y >= rect.y + rect.h) return null;
    if (rect.w <= 0 or rect.h <= 0) return null;

    const fx = @as(f32, @floatFromInt(rect.x));
    const fw = @as(f32, @floatFromInt(rect.w));
    const rel_y = y - rect.y;

    if (radius <= 0 or (rel_y >= radius and rel_y < rect.h - radius)) {
        return .{ .left = fx, .right = fx + fw - 1.0 };
    }

    const frad = @as(f32, @floatFromInt(radius));
    const frel = @as(f32, @floatFromInt(rel_y));
    const dy: f32 = if (rel_y < radius)
        frad - frel - 0.5
    else
        frel - (@as(f32, @floatFromInt(rect.h)) - frad) + 0.5;

    const dx_sq = frad * frad - dy * dy;
    if (dx_sq <= 0) return null;
    const dx = @sqrt(dx_sq);
    return .{ .left = fx + frad - dx, .right = fx + fw - frad + dx - 1.0 };
}

pub fn fillRoundedRect(renderer: *c.SDL_Renderer, rect: Rect, radius: c_int) void {
    if (radius <= 0) {
        const frect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &frect);
        return;
    }

    const fx = @as(f32, @floatFromInt(rect.x));
    const fy = @as(f32, @floatFromInt(rect.y));
    const fw = @as(f32, @floatFromInt(rect.w));
    const fh = @as(f32, @floatFromInt(rect.h));
    const clamped = @min(radius, @divFloor(@min(rect.w, rect.h), 2));
    const frad = @as(f32, @floatFromInt(clamped));

    // Middle section (full width, between rounded corners) — drawn once, no overdraw
    if (fh > 2.0 * frad) {
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = fx,
            .y = fy + frad,
            .w = fw,
            .h = fh - 2.0 * frad,
        });
    }

    // Top rounded section: one scanline per row, inset by arc
    var y: c_int = 0;
    while (y < clamped) : (y += 1) {
        const dy = frad - @as(f32, @floatFromInt(y)) - 0.5;
        const dx_sq = frad * frad - dy * dy;
        if (dx_sq > 0) {
            const dx = @sqrt(dx_sq);
            _ = c.SDL_RenderLine(renderer, fx + frad - dx, fy + @as(f32, @floatFromInt(y)), fx + fw - frad + dx, fy + @as(f32, @floatFromInt(y)));
        }
    }

    // Bottom rounded section: one scanline per row, inset by arc
    const bottom_start: c_int = @max(clamped, rect.h - clamped);
    var by: c_int = bottom_start;
    while (by < rect.h) : (by += 1) {
        const dy = @as(f32, @floatFromInt(by)) - (fh - frad) + 0.5;
        const dx_sq = frad * frad - dy * dy;
        if (dx_sq > 0) {
            const dx = @sqrt(dx_sq);
            _ = c.SDL_RenderLine(renderer, fx + frad - dx, fy + @as(f32, @floatFromInt(by)), fx + fw - frad + dx, fy + @as(f32, @floatFromInt(by)));
        }
    }
}

pub fn fillCircle(renderer: *c.SDL_Renderer, cx: f32, cy: f32, radius: f32) void {
    const r_int: c_int = @intFromFloat(radius);
    var dy: c_int = -r_int;
    while (dy <= r_int) : (dy += 1) {
        const dy_f: f32 = @floatFromInt(dy);
        const dx_sq = radius * radius - dy_f * dy_f;
        if (dx_sq > 0) {
            const dx = @sqrt(dx_sq);
            _ = c.SDL_RenderLine(renderer, cx - dx, cy + dy_f, cx + dx, cy + dy_f);
        }
    }
}

pub fn renderBezierArrow(
    renderer: *c.SDL_Renderer,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    color: c.SDL_Color,
    time_seconds: f32,
) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const dy = y2 - y1;
    const dx = x2 - x1;
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist < 1.0) return;

    // Control point offset: curve bows to the left of the line direction
    const cp_offset = @min(dist * 0.4, 120.0);

    // Cubic bezier control points — curve bows leftward
    const cp1x = x1 - cp_offset;
    const cp1y = y1 + dy * 0.33;
    const cp2x = x2 - cp_offset;
    const cp2y = y1 + dy * 0.67;

    const num_segments: usize = @max(20, @as(usize, @intFromFloat(dist / 4.0)));
    const flow_speed: f32 = 1.5;
    const flow_offset = time_seconds * flow_speed;

    const diffusion_layers: usize = 5;
    var layer: usize = 0;
    while (layer < diffusion_layers) : (layer += 1) {
        const layer_f: f32 = @floatFromInt(layer);
        const center: f32 = @as(f32, @floatFromInt(diffusion_layers - 1)) / 2.0;
        const layer_offset = (layer_f - center) * 0.8;
        const dist_from_center = @abs(layer_f - center);
        const layer_alpha_mult = 1.0 - (dist_from_center / (center + 1.0));

        var prev_x: f32 = x1;
        var prev_y: f32 = y1;

        for (1..num_segments + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_segments));
            const inv_t = 1.0 - t;

            // Cubic bezier evaluation
            const bx = inv_t * inv_t * inv_t * x1 + 3.0 * inv_t * inv_t * t * cp1x + 3.0 * inv_t * t * t * cp2x + t * t * t * x2;
            const by = inv_t * inv_t * inv_t * y1 + 3.0 * inv_t * inv_t * t * cp1y + 3.0 * inv_t * t * t * cp2y + t * t * t * y2;

            // Perpendicular offset for layer spread
            const seg_dx = bx - prev_x;
            const seg_dy = by - prev_y;
            const seg_len = @sqrt(seg_dx * seg_dx + seg_dy * seg_dy);
            const nx = if (seg_len > 0.01) -seg_dy / seg_len else 0.0;
            const ny = if (seg_len > 0.01) seg_dx / seg_len else 0.0;

            const px = bx + nx * layer_offset;
            const py = by + ny * layer_offset;

            // Shimmering alpha
            const wave = @sin((t * 8.0 - flow_offset) * std.math.pi);
            const wave2 = @sin((t * 13.0 + flow_offset * 1.3) * std.math.pi) * 0.5;
            const combined = (wave + wave2) / 1.5;
            const base_alpha: f32 = 120.0;
            const alpha_var: f32 = 60.0;
            const segment_alpha = (base_alpha + combined * alpha_var) * layer_alpha_mult * 0.6;
            const final_alpha: u8 = @intFromFloat(@max(0, @min(255.0, segment_alpha)));

            _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, final_alpha);
            _ = c.SDL_RenderLine(renderer, prev_x + nx * layer_offset, prev_y + ny * layer_offset, px, py);

            prev_x = bx;
            prev_y = by;
        }
    }

    // Filled triangle arrowhead at the end
    const arrow_t = 1.0 - 2.0 / @as(f32, @floatFromInt(num_segments));
    const inv_at = 1.0 - arrow_t;
    const tail_x = inv_at * inv_at * inv_at * x1 + 3.0 * inv_at * inv_at * arrow_t * cp1x + 3.0 * inv_at * arrow_t * arrow_t * cp2x + arrow_t * arrow_t * arrow_t * x2;
    const tail_y = inv_at * inv_at * inv_at * y1 + 3.0 * inv_at * inv_at * arrow_t * cp1y + 3.0 * inv_at * arrow_t * arrow_t * cp2y + arrow_t * arrow_t * arrow_t * y2;

    const arrow_dx = x2 - tail_x;
    const arrow_dy = y2 - tail_y;
    const arrow_len = @sqrt(arrow_dx * arrow_dx + arrow_dy * arrow_dy);
    if (arrow_len < 0.1) return;

    const adx = arrow_dx / arrow_len;
    const ady = arrow_dy / arrow_len;
    const arrow_size: f32 = 12.0;
    const arrow_half_w: f32 = arrow_size * 0.45;

    // Animated alpha matching the line shimmer at t=1.0
    const wave = @sin((1.0 * 8.0 - flow_offset) * std.math.pi);
    const wave2 = @sin((1.0 * 13.0 + flow_offset * 1.3) * std.math.pi) * 0.5;
    const combined = (wave + wave2) / 1.5;
    const arrow_alpha: u8 = @intFromFloat(@max(0, @min(255.0, (120.0 + combined * 60.0) * 0.8)));

    const tip_x = x2;
    const tip_y = y2;
    const left_x = x2 - adx * arrow_size + ady * arrow_half_w;
    const left_y = y2 - ady * arrow_size - adx * arrow_half_w;
    const right_x = x2 - adx * arrow_size - ady * arrow_half_w;
    const right_y = y2 - ady * arrow_size + adx * arrow_half_w;

    const verts = [3]c.SDL_Vertex{
        .{ .position = .{ .x = tip_x, .y = tip_y }, .color = .{ .r = @as(f32, @floatFromInt(color.r)) / 255.0, .g = @as(f32, @floatFromInt(color.g)) / 255.0, .b = @as(f32, @floatFromInt(color.b)) / 255.0, .a = @as(f32, @floatFromInt(arrow_alpha)) / 255.0 } },
        .{ .position = .{ .x = left_x, .y = left_y }, .color = .{ .r = @as(f32, @floatFromInt(color.r)) / 255.0, .g = @as(f32, @floatFromInt(color.g)) / 255.0, .b = @as(f32, @floatFromInt(color.b)) / 255.0, .a = @as(f32, @floatFromInt(arrow_alpha)) / 255.0 } },
        .{ .position = .{ .x = right_x, .y = right_y }, .color = .{ .r = @as(f32, @floatFromInt(color.r)) / 255.0, .g = @as(f32, @floatFromInt(color.g)) / 255.0, .b = @as(f32, @floatFromInt(color.b)) / 255.0, .a = @as(f32, @floatFromInt(arrow_alpha)) / 255.0 } },
    };
    const indices = [3]c_int{ 0, 1, 2 };
    _ = c.SDL_RenderGeometry(renderer, null, &verts, 3, &indices, 3);
}
