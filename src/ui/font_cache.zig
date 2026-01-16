const std = @import("std");
const font_utils = @import("font_utils.zig");

pub const FontCache = struct {
    allocator: std.mem.Allocator,
    font_path: ?[:0]const u8 = null,
    symbol_fallback_path: ?[:0]const u8 = null,
    emoji_fallback_path: ?[:0]const u8 = null,
    generation: u64 = 0,
    fonts: std.AutoHashMap(c_int, font_utils.FontWithFallbacks),

    pub fn init(allocator: std.mem.Allocator) FontCache {
        return .{
            .allocator = allocator,
            .fonts = std.AutoHashMap(c_int, font_utils.FontWithFallbacks).init(allocator),
        };
    }

    pub fn deinit(self: *FontCache) void {
        self.releaseFonts();
        self.fonts.deinit();
    }

    pub fn setPaths(self: *FontCache, font_path: ?[:0]const u8, symbol_path: ?[:0]const u8, emoji_path: ?[:0]const u8) void {
        if (pathsEqual(self.font_path, font_path) and
            pathsEqual(self.symbol_fallback_path, symbol_path) and
            pathsEqual(self.emoji_fallback_path, emoji_path))
        {
            return;
        }
        self.font_path = font_path;
        self.symbol_fallback_path = symbol_path;
        self.emoji_fallback_path = emoji_path;
        self.reset();
    }

    pub fn reset(self: *FontCache) void {
        self.releaseFonts();
        self.fonts.deinit();
        self.fonts = std.AutoHashMap(c_int, font_utils.FontWithFallbacks).init(self.allocator);
        self.generation +%= 1;
    }

    pub fn get(self: *FontCache, size: c_int) ?*font_utils.FontWithFallbacks {
        const font_path = self.font_path orelse return null;
        if (self.fonts.getPtr(size)) |existing| return existing;

        const fonts = font_utils.openFontWithFallbacks(font_path, self.symbol_fallback_path, self.emoji_fallback_path, size) catch return null;
        self.fonts.put(size, fonts) catch {
            fonts.close();
            return null;
        };
        return self.fonts.getPtr(size);
    }

    fn releaseFonts(self: *FontCache) void {
        var it = self.fonts.valueIterator();
        while (it.next()) |font| {
            font.*.close();
        }
    }

    fn pathsEqual(a: ?[:0]const u8, b: ?[:0]const u8) bool {
        if (a == null) return b == null;
        if (b == null) return false;
        return std.mem.eql(u8, std.mem.sliceTo(a.?, 0), std.mem.sliceTo(b.?, 0));
    }
};
