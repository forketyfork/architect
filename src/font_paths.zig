const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.font_paths);

pub const FontPaths = struct {
    regular: [:0]const u8,
    bold: [:0]const u8,
    italic: [:0]const u8,
    bold_italic: [:0]const u8,
    symbol_fallback: ?[:0]const u8,
    emoji_fallback: ?[:0]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, font_family: ?[]const u8) !FontPaths {
        if (builtin.os.tag != .macos) {
            log.err("Only macOS is supported", .{});
            return error.UnsupportedPlatform;
        }

        var paths: FontPaths = undefined;
        paths.allocator = allocator;

        const selected_family = font_family orelse DEFAULT_FONT_FAMILY;

        paths.regular = try findSystemFont(allocator, selected_family, "Regular");
        paths.bold = try findSystemFont(allocator, selected_family, "Bold");
        paths.italic = try findSystemFont(allocator, selected_family, "Italic");
        paths.bold_italic = try findSystemFont(allocator, selected_family, "BoldItalic");

        paths.symbol_fallback = try allocator.dupeZ(u8, "/System/Library/Fonts/Supplemental/Arial Unicode.ttf");
        paths.emoji_fallback = try allocator.dupeZ(u8, "/System/Library/Fonts/Apple Color Emoji.ttc");

        return paths;
    }

    pub fn deinit(self: *FontPaths) void {
        self.allocator.free(self.regular);
        self.allocator.free(self.bold);
        self.allocator.free(self.italic);
        self.allocator.free(self.bold_italic);
        if (self.symbol_fallback) |fallback| {
            self.allocator.free(fallback);
        }
        if (self.emoji_fallback) |fallback| {
            self.allocator.free(fallback);
        }
    }
};

const DEFAULT_FONT_FAMILY = "SFMono";

fn findSystemFont(allocator: std.mem.Allocator, font_family: []const u8, style: []const u8) ![:0]const u8 {
    const search_dirs = [_][]const u8{
        "/System/Library/Fonts",
        "/Library/Fonts",
    };

    const home = std.posix.getenv("HOME");
    const extensions = [_][]const u8{ "otf", "ttf", "ttc" };

    for (search_dirs) |dir| {
        for (extensions) |ext| {
            const font_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.{s}", .{ dir, font_family, style, ext });
            defer allocator.free(font_path);

            std.fs.accessAbsolute(font_path, .{}) catch continue;
            return allocator.dupeZ(u8, font_path);
        }
    }

    if (home) |h| {
        const user_fonts_dir = try std.fmt.allocPrint(allocator, "{s}/Library/Fonts", .{h});
        defer allocator.free(user_fonts_dir);

        for (extensions) |ext| {
            const font_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.{s}", .{ user_fonts_dir, font_family, style, ext });
            defer allocator.free(font_path);

            std.fs.accessAbsolute(font_path, .{}) catch continue;
            return allocator.dupeZ(u8, font_path);
        }
    }

    log.err("Font not found: {s}-{s}", .{ font_family, style });
    return error.FontNotFound;
}
