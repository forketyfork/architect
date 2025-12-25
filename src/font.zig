const std = @import("std");
const c = @import("c.zig");

pub const Font = struct {
    font: *c.TTF_Font,
    renderer: *c.SDL_Renderer,
    glyph_cache: std.AutoHashMap(u21, *c.SDL_Texture),
    allocator: std.mem.Allocator,
    cell_width: c_int,
    cell_height: c_int,

    pub fn init(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, font_path: [*:0]const u8, size: c_int) !Font {
        const font = c.TTF_OpenFont(font_path, size) orelse {
            std.debug.print("TTF_OpenFont Error: {s}\n", .{c.TTF_GetError()});
            return error.FontLoadFailed;
        };

        var cell_width: c_int = 0;
        var cell_height: c_int = 0;
        _ = c.TTF_SizeText(font, "M", &cell_width, &cell_height);

        return Font{
            .font = font,
            .renderer = renderer,
            .glyph_cache = std.AutoHashMap(u21, *c.SDL_Texture).init(allocator),
            .allocator = allocator,
            .cell_width = cell_width,
            .cell_height = cell_height,
        };
    }

    pub fn deinit(self: *Font) void {
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |texture| {
            c.SDL_DestroyTexture(texture.*);
        }
        self.glyph_cache.deinit();
        c.TTF_CloseFont(self.font);
    }

    pub fn renderGlyph(self: *Font, codepoint: u21, x: c_int, y: c_int, target_width: c_int, target_height: c_int, fg_color: c.SDL_Color) !void {
        if (codepoint == 0 or codepoint == ' ') return;

        const texture = try self.getGlyphTexture(codepoint, fg_color);

        var tex_width: c_int = 0;
        var tex_height: c_int = 0;
        _ = c.SDL_QueryTexture(texture, null, null, &tex_width, &tex_height);

        const dest_rect = c.SDL_Rect{
            .x = x,
            .y = y,
            .w = target_width,
            .h = target_height,
        };

        _ = c.SDL_RenderCopy(self.renderer, texture, null, &dest_rect);
    }

    fn getGlyphTexture(self: *Font, codepoint: u21, fg_color: c.SDL_Color) !*c.SDL_Texture {
        if (self.glyph_cache.get(codepoint)) |texture| {
            return texture;
        }

        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return error.InvalidCodepoint;

        var text_buf: [5]u8 = undefined;
        @memcpy(text_buf[0..len], utf8_buf[0..len]);
        text_buf[len] = 0;

        const surface = c.TTF_RenderText_Blended(self.font, @ptrCast(&text_buf), fg_color) orelse {
            std.debug.print("TTF_RenderText_Blended Error for codepoint {d}: {s}\n", .{ codepoint, c.TTF_GetError() });
            return error.GlyphRenderFailed;
        };
        defer c.SDL_FreeSurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse {
            std.debug.print("SDL_CreateTextureFromSurface Error: {s}\n", .{c.SDL_GetError()});
            return error.TextureCreationFailed;
        };

        _ = c.SDL_SetTextureScaleMode(texture, c.SDL_ScaleModeLinear);

        try self.glyph_cache.put(codepoint, texture);
        return texture;
    }
};
