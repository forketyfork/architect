const std = @import("std");
const c = @import("c.zig");
const config_mod = @import("config.zig");

/// Active theme colors, initialized from config
pub const Theme = struct {
    /// Terminal background
    background: c.SDL_Color,
    /// Terminal foreground (default text color)
    foreground: c.SDL_Color,
    /// Selection highlight
    selection: c.SDL_Color,
    /// Accent color (UI elements, focus indicators)
    accent: c.SDL_Color,
    /// 16 ANSI palette colors
    palette: [16]c.SDL_Color,

    /// Create a theme from the config's theme section
    pub fn fromConfig(theme_config: config_mod.ThemeConfig) Theme {
        var palette: [16]c.SDL_Color = undefined;
        for (0..16) |i| {
            const color = theme_config.getPaletteColor(@intCast(i));
            palette[i] = .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
        }

        const bg = theme_config.getBackground();
        const fg = theme_config.getForeground();
        const sel = theme_config.getSelection();
        const acc = theme_config.getAccent();

        return .{
            .background = .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 255 },
            .foreground = .{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 },
            .selection = .{ .r = sel.r, .g = sel.g, .b = sel.b, .a = 255 },
            .accent = .{ .r = acc.r, .g = acc.g, .b = acc.b, .a = 255 },
            .palette = palette,
        };
    }

    /// Create a default theme (One Dark)
    pub fn default() Theme {
        return fromConfig(.{});
    }

    /// Get a palette color by index (0-15)
    pub fn getPaletteColor(self: Theme, idx: u8) c.SDL_Color {
        if (idx < 16) {
            return self.palette[idx];
        }
        // Fallback for out-of-range (shouldn't happen for 0-15)
        return self.palette[0];
    }
};

/// Standard 16 ANSI colors (8 normal + 8 bright) using One Dark theme.
/// This is kept for backwards compatibility with code that uses the static array.
pub const ansi_colors = [_]c.SDL_Color{
    // Normal
    .{ .r = 14, .g = 17, .b = 22, .a = 255 }, // Black
    .{ .r = 224, .g = 108, .b = 117, .a = 255 }, // Red
    .{ .r = 152, .g = 195, .b = 121, .a = 255 }, // Green
    .{ .r = 209, .g = 154, .b = 102, .a = 255 }, // Yellow
    .{ .r = 97, .g = 175, .b = 239, .a = 255 }, // Blue
    .{ .r = 198, .g = 120, .b = 221, .a = 255 }, // Magenta
    .{ .r = 86, .g = 182, .b = 194, .a = 255 }, // Cyan
    .{ .r = 171, .g = 178, .b = 191, .a = 255 }, // White
    // Bright
    .{ .r = 92, .g = 99, .b = 112, .a = 255 }, // BrightBlack
    .{ .r = 224, .g = 108, .b = 117, .a = 255 }, // BrightRed
    .{ .r = 152, .g = 195, .b = 121, .a = 255 }, // BrightGreen
    .{ .r = 229, .g = 192, .b = 123, .a = 255 }, // BrightYellow
    .{ .r = 97, .g = 175, .b = 239, .a = 255 }, // BrightBlue
    .{ .r = 198, .g = 120, .b = 221, .a = 255 }, // BrightMagenta
    .{ .r = 86, .g = 182, .b = 194, .a = 255 }, // BrightCyan
    .{ .r = 205, .g = 214, .b = 224, .a = 255 }, // BrightWhite
};

/// Returns the SDL color for a 256-color palette index.
/// - 0-15: Standard ANSI colors (from provided theme or default)
/// - 16-231: 6x6x6 color cube
/// - 232-255: Grayscale ramp
pub fn get256Color(idx: u8) c.SDL_Color {
    return get256ColorWithTheme(idx, null);
}

/// Returns the SDL color for a 256-color palette index, using theme colors for 0-15.
pub fn get256ColorWithTheme(idx: u8, theme: ?*const Theme) c.SDL_Color {
    if (idx < 16) {
        if (theme) |t| {
            return t.palette[idx];
        }
        return ansi_colors[idx];
    } else if (idx < 232) {
        const color_idx = idx - 16;
        const r = (color_idx / 36) * 51;
        const g = ((color_idx % 36) / 6) * 51;
        const b = (color_idx % 6) * 51;
        return .{ .r = @intCast(r), .g = @intCast(g), .b = @intCast(b), .a = 255 };
    } else {
        const gray = 8 + (idx - 232) * 10;
        return .{ .r = @intCast(gray), .g = @intCast(gray), .b = @intCast(gray), .a = 255 };
    }
}

pub fn colorsEqual(a: c.SDL_Color, b: c.SDL_Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "get256Color - basic ANSI colors" {
    const black = get256Color(0);
    try std.testing.expectEqual(@as(u8, 14), black.r);
    try std.testing.expectEqual(@as(u8, 17), black.g);
    try std.testing.expectEqual(@as(u8, 22), black.b);

    const white = get256Color(15);
    try std.testing.expectEqual(@as(u8, 205), white.r);
    try std.testing.expectEqual(@as(u8, 214), white.g);
    try std.testing.expectEqual(@as(u8, 224), white.b);
}

test "get256Color - grayscale" {
    const gray = get256Color(232);
    try std.testing.expectEqual(gray.r, gray.g);
    try std.testing.expectEqual(gray.g, gray.b);
}

test "colorsEqual" {
    const red = c.SDL_Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const also_red = c.SDL_Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const blue = c.SDL_Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const transparent_red = c.SDL_Color{ .r = 255, .g = 0, .b = 0, .a = 128 };

    try std.testing.expect(colorsEqual(red, also_red));
    try std.testing.expect(!colorsEqual(red, blue));
    try std.testing.expect(!colorsEqual(red, transparent_red));
}

test "Theme.default" {
    const theme = Theme.default();

    // Background should be One Dark background
    try std.testing.expectEqual(@as(u8, 14), theme.background.r);
    try std.testing.expectEqual(@as(u8, 17), theme.background.g);
    try std.testing.expectEqual(@as(u8, 22), theme.background.b);

    // Foreground should be One Dark bright white
    try std.testing.expectEqual(@as(u8, 205), theme.foreground.r);
    try std.testing.expectEqual(@as(u8, 214), theme.foreground.g);
    try std.testing.expectEqual(@as(u8, 224), theme.foreground.b);

    // Palette[1] should be red
    try std.testing.expectEqual(@as(u8, 224), theme.palette[1].r);
    try std.testing.expectEqual(@as(u8, 108), theme.palette[1].g);
    try std.testing.expectEqual(@as(u8, 117), theme.palette[1].b);
}

test "Theme.fromConfig with custom colors" {
    const theme_config = config_mod.ThemeConfig{
        .background = "#FF0000",
        .foreground = "#00FF00",
    };
    const theme = Theme.fromConfig(theme_config);

    // Custom background
    try std.testing.expectEqual(@as(u8, 255), theme.background.r);
    try std.testing.expectEqual(@as(u8, 0), theme.background.g);
    try std.testing.expectEqual(@as(u8, 0), theme.background.b);

    // Custom foreground
    try std.testing.expectEqual(@as(u8, 0), theme.foreground.r);
    try std.testing.expectEqual(@as(u8, 255), theme.foreground.g);
    try std.testing.expectEqual(@as(u8, 0), theme.foreground.b);

    // Palette should still be default (not overridden)
    try std.testing.expectEqual(@as(u8, 224), theme.palette[1].r);
}

test "get256ColorWithTheme" {
    var custom_palette: [16]c.SDL_Color = undefined;
    for (0..16) |i| {
        custom_palette[i] = .{ .r = @intCast(i * 16), .g = @intCast(i * 16), .b = @intCast(i * 16), .a = 255 };
    }

    const theme = Theme{
        .background = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .foreground = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .selection = .{ .r = 50, .g = 50, .b = 50, .a = 255 },
        .accent = .{ .r = 100, .g = 100, .b = 255, .a = 255 },
        .palette = custom_palette,
    };

    // Index 5 should use custom palette
    const color5 = get256ColorWithTheme(5, &theme);
    try std.testing.expectEqual(@as(u8, 80), color5.r); // 5 * 16

    // Index 16+ should still use the cube (not affected by theme)
    const color16 = get256ColorWithTheme(16, &theme);
    try std.testing.expectEqual(@as(u8, 0), color16.r);
    try std.testing.expectEqual(@as(u8, 0), color16.g);
    try std.testing.expectEqual(@as(u8, 0), color16.b);
}
