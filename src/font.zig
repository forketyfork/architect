const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.font);

const GlyphKey = struct {
    codepoint: u32,
    color: u32,
};

pub const Font = struct {
    font: *c.TTF_Font,
    renderer: *c.SDL_Renderer,
    glyph_cache: std.AutoHashMap(GlyphKey, *c.SDL_Texture),
    allocator: std.mem.Allocator,
    cell_width: c_int,
    cell_height: c_int,

    pub const InitError = error{
        FontLoadFailed,
    } || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, font_path: [*:0]const u8, size: c_int) InitError!Font {
        const font = c.TTF_OpenFont(font_path, size) orelse {
            log.err("TTF_OpenFont failed: {s}", .{c.TTF_GetError()});
            return error.FontLoadFailed;
        };

        var cell_width: c_int = 0;
        var cell_height: c_int = 0;
        _ = c.TTF_SizeText(font, "M", &cell_width, &cell_height);

        return Font{
            .font = font,
            .renderer = renderer,
            .glyph_cache = std.AutoHashMap(GlyphKey, *c.SDL_Texture).init(allocator),
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

    pub const RenderGlyphError = error{
        GlyphRenderFailed,
        TextureCreationFailed,
        InvalidCodepoint,
    } || std.mem.Allocator.Error;

    pub fn renderGlyph(self: *Font, codepoint: u21, x: c_int, y: c_int, target_width: c_int, target_height: c_int, fg_color: c.SDL_Color) RenderGlyphError!void {
        if (codepoint == 0 or codepoint == ' ') return;

        const texture = self.getGlyphTexture(codepoint, fg_color) catch |err| {
            if (err == error.GlyphRenderFailed) {
                return;
            }
            return err;
        };

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

    fn getGlyphTexture(self: *Font, codepoint: u21, fg_color: c.SDL_Color) RenderGlyphError!*c.SDL_Texture {
        const key = GlyphKey{
            .codepoint = @intCast(codepoint),
            .color = packColor(fg_color),
        };

        if (self.glyph_cache.get(key)) |texture| {
            return texture;
        }

        const surface = if (codepoint < 0x10000) blk: {
            break :blk c.TTF_RenderGlyph_Blended(self.font, @intCast(codepoint), fg_color) orelse {
                log.debug("TTF_RenderGlyph_Blended failed for U+{X:0>4}: {s}", .{ codepoint, c.TTF_GetError() });
                return error.GlyphRenderFailed;
            };
        } else blk: {
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return error.InvalidCodepoint;

            var text_buf: [5]u8 = undefined;
            @memcpy(text_buf[0..len], utf8_buf[0..len]);
            text_buf[len] = 0;

            break :blk c.TTF_RenderText_Blended(self.font, @ptrCast(&text_buf), fg_color) orelse {
                log.debug("TTF_RenderText_Blended failed for U+{X:0>4}: {s}", .{ codepoint, c.TTF_GetError() });
                return error.GlyphRenderFailed;
            };
        };
        defer c.SDL_FreeSurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse {
            log.err("SDL_CreateTextureFromSurface failed: {s}", .{c.SDL_GetError()});
            return error.TextureCreationFailed;
        };

        _ = c.SDL_SetTextureScaleMode(texture, c.SDL_ScaleModeLinear);

        try self.glyph_cache.put(key, texture);
        return texture;
    }

    fn packColor(color: c.SDL_Color) u32 {
        return (@as(u32, color.r)) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24);
    }
};
