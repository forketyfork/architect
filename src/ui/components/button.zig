const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const dpi = @import("../../dpi.zig");

pub const ButtonVariant = enum {
    default,
    primary,
    danger,
};

pub fn renderButton(
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    rect: c.SDL_FRect,
    label: []const u8,
    variant: ButtonVariant,
    theme: *const @import("../../colors.zig").Theme,
    ui_scale: f32,
) void {
    const rect_int = geom.Rect{
        .x = @intFromFloat(rect.x),
        .y = @intFromFloat(rect.y),
        .w = @intFromFloat(rect.w),
        .h = @intFromFloat(rect.h),
    };

    const radius = dpi.scale(8, ui_scale);
    const fill_radius = @max(1, radius - 1);

    switch (variant) {
        .default => {
            const sel = theme.selection;
            _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 255);
            primitives.fillRoundedRect(renderer, rect_int, fill_radius);
            const acc = theme.accent;
            _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 255);
            primitives.drawRoundedBorder(renderer, rect_int, radius);
        },
        .primary => {
            const acc = theme.accent;
            _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 255);
            primitives.fillRoundedRect(renderer, rect_int, fill_radius);
            const dark_blue = theme.palette[4];
            _ = c.SDL_SetRenderDrawColor(renderer, dark_blue.r, dark_blue.g, dark_blue.b, 255);
            primitives.drawRoundedBorder(renderer, rect_int, radius);
        },
        .danger => {
            const red = theme.palette[1];
            _ = c.SDL_SetRenderDrawColor(renderer, red.r, red.g, red.b, 255);
            primitives.fillRoundedRect(renderer, rect_int, fill_radius);
            const bright_red = theme.palette[9];
            _ = c.SDL_SetRenderDrawColor(renderer, bright_red.r, bright_red.g, bright_red.b, 255);
            primitives.drawRoundedBorder(renderer, rect_int, radius);
        },
    }

    const text_color = switch (variant) {
        .default => theme.accent,
        .primary => theme.background,
        .danger => theme.foreground,
    };
    const tex = makeTextTexture(renderer, font, label, text_color) catch return;
    defer c.SDL_DestroyTexture(tex.tex);

    const text_x = rect.x + (rect.w - @as(f32, @floatFromInt(tex.w))) / 2.0;
    const text_y = rect.y + (rect.h - @as(f32, @floatFromInt(tex.h))) / 2.0;
    _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
        .x = text_x,
        .y = text_y,
        .w = @floatFromInt(tex.w),
        .h = @floatFromInt(tex.h),
    });
}

const TextTex = struct {
    tex: *c.SDL_Texture,
    w: c_int,
    h: c_int,
};

fn makeTextTexture(
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    text: []const u8,
    color: c.SDL_Color,
) !TextTex {
    var buf: [256]u8 = undefined;
    if (text.len >= buf.len) return error.TextTooLong;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), text.len, color) orelse return error.SurfaceFailed;
    defer c.SDL_DestroySurface(surface);
    const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(tex, &w, &h);
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    return TextTex{
        .tex = tex,
        .w = @intFromFloat(w),
        .h = @intFromFloat(h),
    };
}
