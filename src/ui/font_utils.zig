const c = @import("../c.zig");

pub const FontWithFallbacks = struct {
    main: *c.TTF_Font,
    symbol: ?*c.TTF_Font = null,
    emoji: ?*c.TTF_Font = null,

    pub fn close(self: FontWithFallbacks) void {
        if (self.symbol) |s| c.TTF_CloseFont(s);
        if (self.emoji) |e| c.TTF_CloseFont(e);
        c.TTF_CloseFont(self.main);
    }
};

pub fn openFontWithFallbacks(
    font_path: [:0]const u8,
    symbol_path: ?[:0]const u8,
    emoji_path: ?[:0]const u8,
    size: c_int,
) error{FontUnavailable}!FontWithFallbacks {
    const main = c.TTF_OpenFont(font_path.ptr, @floatFromInt(size)) orelse return error.FontUnavailable;
    errdefer c.TTF_CloseFont(main);

    var symbol: ?*c.TTF_Font = null;
    if (symbol_path) |path| {
        symbol = c.TTF_OpenFont(path.ptr, @floatFromInt(size));
        if (symbol) |s| {
            if (!c.TTF_AddFallbackFont(main, s)) {
                c.TTF_CloseFont(s);
                symbol = null;
            }
        }
    }

    var emoji: ?*c.TTF_Font = null;
    if (emoji_path) |path| {
        emoji = c.TTF_OpenFont(path.ptr, @floatFromInt(size));
        if (emoji) |e| {
            if (!c.TTF_AddFallbackFont(main, e)) {
                c.TTF_CloseFont(e);
                emoji = null;
            }
        }
    }

    return FontWithFallbacks{
        .main = main,
        .symbol = symbol,
        .emoji = emoji,
    };
}
