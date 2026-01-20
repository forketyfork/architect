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

    const centers = [_]struct { x: f32, y: f32, sx: f32, sy: f32 }{
        .{ .x = fx + frad, .y = fy + frad, .sx = -1.0, .sy = -1.0 },
        .{ .x = fx + fw - frad - 1.0, .y = fy + frad, .sx = 1.0, .sy = -1.0 },
        .{ .x = fx + frad, .y = fy + fh - frad - 1.0, .sx = -1.0, .sy = 1.0 },
        .{ .x = fx + fw - frad - 1.0, .y = fy + fh - frad - 1.0, .sx = 1.0, .sy = 1.0 },
    };

    for (centers) |cinfo| {
        var i: i32 = 0;
        while (i <= radius) : (i += 1) {
            const x = @as(f32, @floatFromInt(i));
            const y_sq = frad * frad - x * x;
            if (y_sq >= 0) {
                const y = @sqrt(y_sq);
                _ = c.SDL_RenderPoint(renderer, cinfo.x + cinfo.sx * x, cinfo.y + cinfo.sy * y);
                if (i > 0 and i < radius) {
                    _ = c.SDL_RenderPoint(renderer, cinfo.x + cinfo.sx * y, cinfo.y + cinfo.sy * x);
                }
            }
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
    const frad = @as(f32, @floatFromInt(radius));

    const center_rect = c.SDL_FRect{
        .x = fx + frad,
        .y = fy,
        .w = fw - 2.0 * frad,
        .h = fh,
    };
    _ = c.SDL_RenderFillRect(renderer, &center_rect);

    const left_rect = c.SDL_FRect{
        .x = fx,
        .y = fy + frad,
        .w = frad,
        .h = fh - 2.0 * frad,
    };
    _ = c.SDL_RenderFillRect(renderer, &left_rect);

    const right_rect = c.SDL_FRect{
        .x = fx + fw - frad,
        .y = fy + frad,
        .w = frad,
        .h = fh - 2.0 * frad,
    };
    _ = c.SDL_RenderFillRect(renderer, &right_rect);

    const corners = [_]struct { cx: f32, cy: f32 }{
        .{ .cx = fx + frad, .cy = fy + frad },
        .{ .cx = fx + fw - frad - 1.0, .cy = fy + frad },
        .{ .cx = fx + frad, .cy = fy + fh - frad - 1.0 },
        .{ .cx = fx + fw - frad - 1.0, .cy = fy + fh - frad - 1.0 },
    };

    for (corners) |corner| {
        var y: c_int = 0;
        while (y < radius) : (y += 1) {
            const fy_offset = @as(f32, @floatFromInt(y));
            const dist_sq = frad * frad - fy_offset * fy_offset;
            if (dist_sq > 0) {
                const dx = @sqrt(dist_sq);
                _ = c.SDL_RenderLine(renderer, corner.cx - dx, corner.cy - fy_offset, corner.cx + dx, corner.cy - fy_offset);
                if (y > 0) {
                    _ = c.SDL_RenderLine(renderer, corner.cx - dx, corner.cy + fy_offset, corner.cx + dx, corner.cy + fy_offset);
                }
            }
        }
    }
}
