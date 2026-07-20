const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const dpi = @import("../../dpi.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");

/// Cached texture for a small static text badge (e.g. the "⌘O" hint shown on
/// collapsed overlays). Rasterizing the text and destroying the texture every
/// frame forces SDL's Metal backend to flush its command queue on each
/// destroy, which can block on drawable acquisition for hundreds of
/// milliseconds while the app is rendering continuously.
pub const GlyphBadge = struct {
    text: [:0]const u8,
    texture: ?*c.SDL_Texture = null,
    w: f32 = 0,
    h: f32 = 0,
    font_size: c_int = 0,
    font_generation: u64 = 0,
    fg: c.SDL_Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },

    pub fn deinit(self: *GlyphBadge) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
    }

    /// Renders the badge centered in `rect`, rebuilding the cached texture
    /// only when the font size, font generation, or theme color changes.
    pub fn render(
        self: *GlyphBadge,
        renderer: *c.SDL_Renderer,
        rect: geom.Rect,
        ui_scale: f32,
        assets: *types.UiAssets,
        theme: *const colors.Theme,
    ) void {
        const cache = assets.font_cache orelse return;
        const font_size = dpi.scale(@max(12, @min(20, @divFloor(rect.h, 2))), ui_scale);
        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };

        const stale = self.texture == null or
            self.font_size != font_size or
            self.font_generation != cache.generation or
            !colors.colorsEqual(self.fg, fg_color);
        if (stale) {
            self.deinit();

            const fonts = cache.get(font_size) catch return;
            const surface = c.TTF_RenderText_Blended(fonts.regular, self.text.ptr, @intCast(self.text.len), fg_color) orelse return;
            defer c.SDL_DestroySurface(surface);

            const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
            _ = c.SDL_GetTextureSize(texture, &self.w, &self.h);
            self.texture = texture;
            self.font_size = font_size;
            self.font_generation = cache.generation;
            self.fg = fg_color;
        }

        const texture = self.texture orelse return;
        const text_x = rect.x + @divFloor(rect.w - @as(c_int, @intFromFloat(self.w)), 2);
        const text_y = rect.y + @divFloor(rect.h - @as(c_int, @intFromFloat(self.h)), 2);
        _ = c.SDL_RenderTexture(renderer, texture, null, &c.SDL_FRect{
            .x = @floatFromInt(text_x),
            .y = @floatFromInt(text_y),
            .w = self.w,
            .h = self.h,
        });
    }
};
