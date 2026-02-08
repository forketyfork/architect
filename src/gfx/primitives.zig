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
