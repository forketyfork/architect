// SDL_ttf-backed font helper with glyph caching so terminals can render text
// efficiently at varying scales.
const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.font);

const GlyphKey = struct {
    hash: u64,
    color: u32,
    fallback: bool,
    len: u8,
};

const WHITE: c.SDL_Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

pub const Font = struct {
    font: *c.TTF_Font,
    fallback_font: ?*c.TTF_Font,
    renderer: *c.SDL_Renderer,
    glyph_cache: std.AutoHashMap(GlyphKey, *c.SDL_Texture),
    allocator: std.mem.Allocator,
    cell_width: c_int,
    cell_height: c_int,

    pub const InitError = error{
        FontLoadFailed,
    } || std.mem.Allocator.Error;

    pub fn init(
        allocator: std.mem.Allocator,
        renderer: *c.SDL_Renderer,
        font_path: [*:0]const u8,
        fallback_path: ?[*:0]const u8,
        size: c_int,
    ) InitError!Font {
        const font = c.TTF_OpenFont(font_path, @floatFromInt(size)) orelse {
            log.err("TTF_OpenFont failed: {s}", .{c.SDL_GetError()});
            return error.FontLoadFailed;
        };

        const fallback_font = fallback_path orelse blk: {
            log.debug("No fallback font configured", .{});
            break :blk null;
        };
        const opened_fallback = if (fallback_font) |path| blk: {
            break :blk c.TTF_OpenFont(path, @floatFromInt(size));
        } else null;
        if (fallback_font != null and opened_fallback == null) {
            log.warn("Failed to open fallback font: {s}", .{c.SDL_GetError()});
        }

        var cell_width: c_int = 0;
        var cell_height: c_int = 0;
        if (!c.TTF_GetStringSize(font, "M", 1, &cell_width, &cell_height)) {
            log.err("TTF_GetStringSize failed: {s}", .{c.SDL_GetError()});
            c.TTF_CloseFont(font);
            if (opened_fallback) |ff| c.TTF_CloseFont(ff);
            return error.FontLoadFailed;
        }

        log.debug("Font cell dimensions: {d}x{d}", .{ cell_width, cell_height });

        return Font{
            .font = font,
            .fallback_font = opened_fallback,
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
        if (self.fallback_font) |f| {
            c.TTF_CloseFont(f);
        }
    }

    pub const RenderGlyphError = error{
        GlyphRenderFailed,
        TextureCreationFailed,
        InvalidCodepoint,
        BufferTooSmall,
    } || std.mem.Allocator.Error;

    pub fn renderGlyph(self: *Font, codepoint: u21, x: c_int, y: c_int, target_width: c_int, target_height: c_int, fg_color: c.SDL_Color) RenderGlyphError!void {
        var buf = [_]u21{codepoint};
        return self.renderCluster(&buf, x, y, target_width, target_height, fg_color);
    }

    pub fn renderCluster(
        self: *Font,
        codepoints: []const u21,
        x: c_int,
        y: c_int,
        target_width: c_int,
        target_height: c_int,
        fg_color: c.SDL_Color,
    ) RenderGlyphError!void {
        if (codepoints.len == 0) return;
        if (codepoints.len == 1 and codepoints[0] == 0) return;

        var utf8_buf: [128]u8 = undefined;
        var utf8_len: usize = 0;
        for (codepoints) |cp| {
            var local: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(cp, &local) catch return error.InvalidCodepoint;
            if (utf8_len + encoded_len > utf8_buf.len) {
                return error.BufferTooSmall;
            }
            @memcpy(utf8_buf[utf8_len .. utf8_len + encoded_len], local[0..encoded_len]);
            utf8_len += encoded_len;
        }
        const utf8_slice = utf8_buf[0..utf8_len];

        const use_fallback = self.shouldUseFallback(codepoints);
        const texture = self.getGlyphTexture(utf8_slice, fg_color, use_fallback) catch |err| {
            if (err == error.GlyphRenderFailed) return;
            return err;
        };

        var tex_w: f32 = 0;
        var tex_h: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &tex_w, &tex_h);
        if (tex_w == 0 or tex_h == 0) return;

        const avail_w: f32 = @floatFromInt(target_width);
        const avail_h: f32 = @floatFromInt(target_height);
        const scale = if (avail_w / tex_w < avail_h / tex_h)
            avail_w / tex_w
        else
            avail_h / tex_h;
        const dest_w = tex_w * scale;
        const dest_h = tex_h * scale;

        const base_x: f32 = @floatFromInt(x);
        const base_y: f32 = @floatFromInt(y);
        const dest_rect = c.SDL_FRect{
            .x = base_x + (avail_w - dest_w) * 0.5,
            .y = base_y + (avail_h - dest_h) * 0.5,
            .w = dest_w,
            .h = dest_h,
        };

        _ = c.SDL_RenderTexture(self.renderer, texture, null, &dest_rect);
    }

    fn getGlyphTexture(self: *Font, utf8: []const u8, fg_color: c.SDL_Color, use_fallback: bool) RenderGlyphError!*c.SDL_Texture {
        const key = GlyphKey{
            .hash = std.hash.Wyhash.hash(0, utf8),
            .color = packColor(if (use_fallback) WHITE else fg_color),
            .fallback = use_fallback,
            .len = @intCast(utf8.len),
        };

        if (self.glyph_cache.get(key)) |texture| {
            return texture;
        }

        const render_font = if (use_fallback) self.fallback_font orelse self.font else self.font;
        const render_color = if (use_fallback) WHITE else fg_color;

        const surface = c.TTF_RenderText_Blended(render_font, @ptrCast(utf8.ptr), @intCast(utf8.len), render_color) orelse {
            log.debug("TTF_RenderText_Blended failed: {s}", .{c.SDL_GetError()});
            return error.GlyphRenderFailed;
        };
        defer c.SDL_DestroySurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse {
            log.err("SDL_CreateTextureFromSurface failed: {s}", .{c.SDL_GetError()});
            return error.TextureCreationFailed;
        };

        _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_LINEAR);

        try self.glyph_cache.put(key, texture);
        return texture;
    }

    fn packColor(color: c.SDL_Color) u32 {
        return (@as(u32, color.r)) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24);
    }

    fn shouldUseFallback(self: *Font, codepoints: []const u21) bool {
        if (self.fallback_font == null) return false;
        for (codepoints) |cp| {
            if (c.TTF_FontHasGlyph(self.font, @intCast(cp))) continue;
            // First glyph missing in primary but present in fallback → enable fallback for the whole cluster.
            if (c.TTF_FontHasGlyph(self.fallback_font.?, @intCast(cp))) return true;
        }
        return false;
    }
};
