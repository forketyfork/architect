const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const dpi = @import("../../dpi.zig");
const colors = @import("../../colors.zig");

const log = std.log.scoped(.ui_button);

pub const ButtonVariant = enum {
    default,
    primary,
    danger,
};

/// A button label texture that survives until the next frame.
///
/// SDL's Metal renderer may queue texture draws, so destroying a label after
/// rendering it in the same frame can make the label disappear or force a
/// synchronous command-buffer flush. The cache is invalidated by the font,
/// label, or color changing.
pub const ButtonTexture = struct {
    tex: ?*c.SDL_Texture = null,
    w: c_int = 0,
    h: c_int = 0,
    font: ?*c.TTF_Font = null,
    label: []const u8 = &.{},
    color: c.SDL_Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },

    pub fn deinit(self: *ButtonTexture) void {
        if (self.tex) |tex| c.SDL_DestroyTexture(tex);
        self.* = .{};
    }

    pub fn ensure(
        self: *ButtonTexture,
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        label: []const u8,
        color: c.SDL_Color,
    ) !void {
        if (self.tex != null and self.font == font and std.mem.eql(u8, self.label, label) and colorsEqual(self.color, color)) {
            return;
        }

        const next = try makeTextTexture(renderer, font, label, color);
        if (self.tex) |old| c.SDL_DestroyTexture(old);
        self.* = .{
            .tex = next.tex,
            .w = next.w,
            .h = next.h,
            .font = font,
            .label = label,
            .color = color,
        };
    }
};

pub fn renderButton(
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    rect: c.SDL_FRect,
    label: []const u8,
    variant: ButtonVariant,
    theme: *const @import("../../colors.zig").Theme,
    ui_scale: f32,
    texture: *ButtonTexture,
    hovered: bool,
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

    if (hovered) {
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 25);
        primitives.fillRoundedRect(renderer, rect_int, fill_radius);
    }

    const text_color = labelColor(variant, theme);
    texture.ensure(renderer, font, label, text_color) catch |err| {
        log.warn("failed to cache {s} button label: {}", .{ label, err });
        return;
    };
    const tex = texture.tex orelse return;

    const text_x = rect.x + (rect.w - @as(f32, @floatFromInt(texture.w))) / 2.0;
    const text_y = rect.y + (rect.h - @as(f32, @floatFromInt(texture.h))) / 2.0;
    _ = c.SDL_RenderTexture(renderer, tex, null, &c.SDL_FRect{
        .x = text_x,
        .y = text_y,
        .w = @floatFromInt(texture.w),
        .h = @floatFromInt(texture.h),
    });
}

pub fn labelColor(variant: ButtonVariant, theme: *const colors.Theme) c.SDL_Color {
    return switch (variant) {
        .default => theme.foreground,
        .primary => theme.background,
        .danger => theme.foreground,
    };
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

fn colorsEqual(a: c.SDL_Color, b: c.SDL_Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "button label colors contrast with their fills" {
    const palette_color = c.SDL_Color{ .r = 30, .g = 40, .b = 50, .a = 255 };
    const theme = colors.Theme{
        .background = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
        .foreground = .{ .r = 220, .g = 221, .b = 222, .a = 255 },
        .selection = .{ .r = 10, .g = 11, .b = 12, .a = 255 },
        .accent = .{ .r = 90, .g = 160, .b = 230, .a = 255 },
        .palette = [_]c.SDL_Color{palette_color} ** 16,
    };

    try std.testing.expectEqual(theme.foreground, labelColor(.default, &theme));
    try std.testing.expectEqual(theme.background, labelColor(.primary, &theme));
    try std.testing.expectEqual(theme.foreground, labelColor(.danger, &theme));
}
