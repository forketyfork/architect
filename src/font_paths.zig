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
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoExeDir;

        var paths: FontPaths = undefined;
        paths.allocator = allocator;

        const candidates = [_][]const u8{
            "../share/architect/fonts",
            "../../share/architect/fonts",
            "assets/fonts",
        };

        var font_dir_path: ?[]const u8 = null;
        for (candidates) |candidate| {
            const test_path = try std.fs.path.join(allocator, &.{ exe_dir, candidate });
            defer allocator.free(test_path);

            const real_path = std.fs.realpathAlloc(allocator, test_path) catch continue;
            defer allocator.free(real_path);

            std.fs.accessAbsolute(real_path, .{}) catch continue;
            font_dir_path = try allocator.dupe(u8, real_path);
            break;
        }

        if (font_dir_path) |dir| {
            defer allocator.free(dir);

            const selected_family = pickFontFamily(allocator, dir, font_family) catch |err| {
                log.err("Failed to resolve font family: {}", .{err});
                return error.FontsNotFound;
            };

            paths.regular = try fontPath(allocator, dir, selected_family, "Regular");
            paths.bold = try fontPath(allocator, dir, selected_family, "Bold");
            paths.italic = try fontPath(allocator, dir, selected_family, "Italic");
            paths.bold_italic = try fontPath(allocator, dir, selected_family, "BoldItalic");
        } else {
            log.err("fonts not found in any candidate location", .{});
            return error.FontsNotFound;
        }

        if (builtin.os.tag == .macos) {
            paths.symbol_fallback = try allocator.dupeZ(u8, "/System/Library/Fonts/Supplemental/Arial Unicode.ttf");
            paths.emoji_fallback = try allocator.dupeZ(u8, "/System/Library/Fonts/Apple Color Emoji.ttc");
        } else {
            paths.symbol_fallback = null;
            paths.emoji_fallback = null;
        }

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

const DEFAULT_FONT_FAMILY = "VictorMonoNerdFont";

fn pickFontFamily(allocator: std.mem.Allocator, dir: []const u8, font_family: ?[]const u8) ![]const u8 {
    const selected_family = font_family orelse DEFAULT_FONT_FAMILY;
    const regular_path = try fontPath(allocator, dir, selected_family, "Regular");
    defer allocator.free(regular_path);

    std.fs.accessAbsolute(regular_path, .{}) catch |err| {
        if (font_family == null or std.mem.eql(u8, selected_family, DEFAULT_FONT_FAMILY)) {
            return err;
        }
        log.warn("Font family '{s}' not found, falling back to {s}", .{ selected_family, DEFAULT_FONT_FAMILY });
        return DEFAULT_FONT_FAMILY;
    };

    return selected_family;
}

fn fontPath(allocator: std.mem.Allocator, dir: []const u8, font_family: []const u8, style: []const u8) ![:0]const u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}-{s}.ttf", .{ font_family, style });
    defer allocator.free(filename);
    return std.fs.path.joinZ(allocator, &.{ dir, filename });
}
