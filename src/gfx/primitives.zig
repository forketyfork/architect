const std = @import("std");
const c = @import("../c.zig");
const geom = @import("../geom.zig");

const Rect = geom.Rect;

pub fn drawRoundedBorder(renderer: *c.SDL_Renderer, rect: Rect, radius: c_int) void {
    const fx = @as(f32, @floatFromInt(rect.x));
    const fy = @as(f32, @floatFromInt(rect.y));
    const fw = @as(f32, @floatFromInt(rect.w));
    const fh = @as(f32, @floatFromInt(rect.h));
    const frad = @as(f32, @floatFromInt(radius));

    _ = c.SDL_RenderLine(renderer, fx + frad, fy, fx + fw - frad - 1.0, fy);
    _ = c.SDL_RenderLine(renderer, fx + frad, fy + fh - 1.0, fx + fw - frad - 1.0, fy + fh - 1.0);
    _ = c.SDL_RenderLine(renderer, fx, fy + frad, fx, fy + fh - frad - 1.0);
    _ = c.SDL_RenderLine(renderer, fx + fw - 1.0, fy + frad, fx + fw - 1.0, fy + fh - frad - 1.0);

    var angle: f32 = 0.0;
    const step: f32 = std.math.pi / 64.0;
    while (angle <= std.math.pi / 2.0) : (angle += step) {
        const rx = frad * std.math.cos(angle);
        const ry = frad * std.math.sin(angle);

        const centers = [_]struct { x: f32, y: f32, sx: f32, sy: f32 }{
            .{ .x = fx + frad, .y = fy + frad, .sx = -1.0, .sy = -1.0 },
            .{ .x = fx + fw - frad - 1.0, .y = fy + frad, .sx = 1.0, .sy = -1.0 },
            .{ .x = fx + frad, .y = fy + fh - frad - 1.0, .sx = -1.0, .sy = 1.0 },
            .{ .x = fx + fw - frad - 1.0, .y = fy + fh - frad - 1.0, .sx = 1.0, .sy = 1.0 },
        };

        for (centers) |cinfo| {
            _ = c.SDL_RenderPoint(renderer, cinfo.x + cinfo.sx * rx, cinfo.y + cinfo.sy * ry);
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
