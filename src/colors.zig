const std = @import("std");
const c = @import("c.zig");

/// Standard 16 ANSI colors (8 normal + 8 bright) using One Dark theme.
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
/// - 0-15: Standard ANSI colors
/// - 16-231: 6x6x6 color cube
/// - 232-255: Grayscale ramp
pub fn get256Color(idx: u8) c.SDL_Color {
    if (idx < 16) {
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
