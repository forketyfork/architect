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

pub fn drawThickBorder(renderer: *c.SDL_Renderer, rect: Rect, thickness: c_int, color: c.SDL_Color) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    const radius: c_int = 12;
    var i: c_int = 0;
    while (i < thickness) : (i += 1) {
        const r = Rect{
            .x = rect.x + i,
            .y = rect.y + i,
            .w = rect.w - i * 2,
            .h = rect.h - i * 2,
        };
        drawRoundedBorder(renderer, r, radius);
    }
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

    // Arrowhead at the end
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
    const arrow_size: f32 = 8.0;

    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 180);
    _ = c.SDL_RenderLine(
        renderer,
        x2,
        y2,
        x2 - adx * arrow_size + ady * arrow_size * 0.5,
        y2 - ady * arrow_size - adx * arrow_size * 0.5,
    );
    _ = c.SDL_RenderLine(
        renderer,
        x2,
        y2,
        x2 - adx * arrow_size - ady * arrow_size * 0.5,
        y2 - ady * arrow_size + adx * arrow_size * 0.5,
    );
}
