const std = @import("std");
const c = @import("c.zig");
const assets = @import("assets");

const log = std.log.scoped(.font_cache);

pub const FontSet = struct {
    regular: *c.TTF_Font,
    bold: ?*c.TTF_Font,
    italic: ?*c.TTF_Font,
    bold_italic: ?*c.TTF_Font,
    symbol_embedded: ?*c.TTF_Font,
    symbol: ?*c.TTF_Font,
    symbol_secondary: ?*c.TTF_Font,
    emoji: ?*c.TTF_Font,

    pub fn close(self: FontSet) void {
        if (self.bold) |font| c.TTF_CloseFont(font);
        if (self.italic) |font| c.TTF_CloseFont(font);
        if (self.bold_italic) |font| c.TTF_CloseFont(font);
        if (self.symbol_embedded) |font| c.TTF_CloseFont(font);
        if (self.symbol) |font| c.TTF_CloseFont(font);
        if (self.symbol_secondary) |font| c.TTF_CloseFont(font);
        if (self.emoji) |font| c.TTF_CloseFont(font);
        c.TTF_CloseFont(self.regular);
    }
};

pub const FontCache = struct {
    allocator: std.mem.Allocator,
    attach_fallbacks: bool = false,
    regular_path: ?[:0]const u8 = null,
    bold_path: ?[:0]const u8 = null,
    italic_path: ?[:0]const u8 = null,
    bold_italic_path: ?[:0]const u8 = null,
    symbol_path: ?[:0]const u8 = null,
    symbol_secondary_path: ?[:0]const u8 = null,
    emoji_path: ?[:0]const u8 = null,
    generation: u64 = 0,
    fonts: std.AutoHashMap(c_int, FontSet),
    pub const Error = error{FontUnavailable} || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator) FontCache {
        return .{
            .allocator = allocator,
            .fonts = std.AutoHashMap(c_int, FontSet).init(allocator),
        };
    }

    pub fn initWithFallbacks(allocator: std.mem.Allocator, attach_fallbacks: bool) FontCache {
        var cache = init(allocator);
        cache.attach_fallbacks = attach_fallbacks;
        return cache;
    }

    pub fn deinit(self: *FontCache) void {
        self.releaseFonts();
        self.fonts.deinit();
    }

    pub fn setPaths(
        self: *FontCache,
        regular_path: ?[:0]const u8,
        bold_path: ?[:0]const u8,
        italic_path: ?[:0]const u8,
        bold_italic_path: ?[:0]const u8,
        symbol_path: ?[:0]const u8,
        symbol_secondary_path: ?[:0]const u8,
        emoji_path: ?[:0]const u8,
    ) void {
        if (pathsEqual(self.regular_path, regular_path) and
            pathsEqual(self.bold_path, bold_path) and
            pathsEqual(self.italic_path, italic_path) and
            pathsEqual(self.bold_italic_path, bold_italic_path) and
            pathsEqual(self.symbol_path, symbol_path) and
            pathsEqual(self.symbol_secondary_path, symbol_secondary_path) and
            pathsEqual(self.emoji_path, emoji_path))
        {
            return;
        }

        self.regular_path = regular_path;
        self.bold_path = bold_path;
        self.italic_path = italic_path;
        self.bold_italic_path = bold_italic_path;
        self.symbol_path = symbol_path;
        self.symbol_secondary_path = symbol_secondary_path;
        self.emoji_path = emoji_path;
        self.reset();
    }

    pub fn reset(self: *FontCache) void {
        self.releaseFonts();
        self.fonts.deinit();
        self.fonts = std.AutoHashMap(c_int, FontSet).init(self.allocator);
        self.generation +%= 1;
    }

    pub fn get(self: *FontCache, size: c_int) Error!*FontSet {
        const regular_path = self.regular_path orelse return error.FontUnavailable;
        if (self.fonts.getPtr(size)) |existing| return existing;

        const regular = try openRequiredFont(regular_path, size, "regular");
        errdefer c.TTF_CloseFont(regular);

        const bold = openOptionalFont(self.bold_path, size, "bold");
        errdefer if (bold) |font| c.TTF_CloseFont(font);

        const italic = openOptionalFont(self.italic_path, size, "italic");
        errdefer if (italic) |font| c.TTF_CloseFont(font);

        const bold_italic = openOptionalFont(self.bold_italic_path, size, "bold-italic");
        errdefer if (bold_italic) |font| c.TTF_CloseFont(font);

        const symbol_embedded = openEmbeddedFont(assets.symbols_nerd_font, size, "Symbols Nerd Font");
        errdefer if (symbol_embedded) |font| c.TTF_CloseFont(font);

        const symbol = openOptionalFont(self.symbol_path, size, "symbol fallback");
        errdefer if (symbol) |font| c.TTF_CloseFont(font);

        const symbol_secondary = openOptionalFont(self.symbol_secondary_path, size, "symbol fallback (secondary)");
        errdefer if (symbol_secondary) |font| c.TTF_CloseFont(font);

        const emoji = openOptionalFont(self.emoji_path, size, "emoji fallback");
        errdefer if (emoji) |font| c.TTF_CloseFont(font);

        if (self.attach_fallbacks) {
            attachFallback(regular, symbol_embedded, "Symbols Nerd Font");
            attachFallback(regular, symbol, "symbol");
            attachFallback(regular, symbol_secondary, "symbol (secondary)");
            attachFallback(regular, emoji, "emoji");
        }

        const fonts = FontSet{
            .regular = regular,
            .bold = bold,
            .italic = italic,
            .bold_italic = bold_italic,
            .symbol_embedded = symbol_embedded,
            .symbol = symbol,
            .symbol_secondary = symbol_secondary,
            .emoji = emoji,
        };
        errdefer fonts.close();

        const gop = try self.fonts.getOrPut(size);
        gop.value_ptr.* = fonts;
        return gop.value_ptr;
    }

    fn releaseFonts(self: *FontCache) void {
        var it = self.fonts.valueIterator();
        while (it.next()) |font| {
            font.*.close();
        }
    }

    fn openRequiredFont(path: [:0]const u8, size: c_int, label: []const u8) error{FontUnavailable}!*c.TTF_Font {
        const font = c.TTF_OpenFont(path.ptr, @floatFromInt(size)) orelse {
            log.err("Failed to open {s} font: {s}", .{ label, c.SDL_GetError() });
            return error.FontUnavailable;
        };
        _ = c.TTF_SetFontDirection(font, c.TTF_DIRECTION_LTR);
        return font;
    }

    fn openOptionalFont(path_opt: ?[:0]const u8, size: c_int, label: []const u8) ?*c.TTF_Font {
        const path = path_opt orelse return null;
        const font = c.TTF_OpenFont(path.ptr, @floatFromInt(size));
        if (font == null) {
            log.warn("Failed to open {s} font: {s}", .{ label, c.SDL_GetError() });
            return null;
        }
        _ = c.TTF_SetFontDirection(font.?, c.TTF_DIRECTION_LTR);
        return font;
    }

    fn openEmbeddedFont(data: []const u8, size: c_int, label: []const u8) ?*c.TTF_Font {
        const stream = c.SDL_IOFromConstMem(data.ptr, data.len) orelse {
            log.warn("Failed to open {s} font stream: {s}", .{ label, c.SDL_GetError() });
            return null;
        };
        const font = c.TTF_OpenFontIO(stream, true, @floatFromInt(size));
        if (font == null) {
            log.warn("Failed to open {s} font: {s}", .{ label, c.SDL_GetError() });
            _ = c.SDL_CloseIO(stream);
            return null;
        }
        _ = c.TTF_SetFontDirection(font.?, c.TTF_DIRECTION_LTR);
        return font;
    }

    fn attachFallback(main_font: *c.TTF_Font, fallback: ?*c.TTF_Font, label: []const u8) void {
        const fallback_font = fallback orelse return;
        if (!c.TTF_AddFallbackFont(main_font, fallback_font)) {
            log.warn("Failed to attach {s} fallback: {s}", .{ label, c.SDL_GetError() });
        }
    }

    fn pathsEqual(a: ?[:0]const u8, b: ?[:0]const u8) bool {
        if (a == null) return b == null;
        if (b == null) return false;
        return std.mem.eql(u8, std.mem.sliceTo(a.?, 0), std.mem.sliceTo(b.?, 0));
    }
};
