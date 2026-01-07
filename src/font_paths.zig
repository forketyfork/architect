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

    pub fn init(allocator: std.mem.Allocator) !FontPaths {
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

            paths.regular = try std.fs.path.joinZ(allocator, &.{ dir, "VictorMonoNerdFont-Regular.ttf" });
            paths.bold = try std.fs.path.joinZ(allocator, &.{ dir, "VictorMonoNerdFont-Bold.ttf" });
            paths.italic = try std.fs.path.joinZ(allocator, &.{ dir, "VictorMonoNerdFont-Italic.ttf" });
            paths.bold_italic = try std.fs.path.joinZ(allocator, &.{ dir, "VictorMonoNerdFont-BoldItalic.ttf" });
        } else {
            log.err("fonts not found in any candidate location", .{});
            return error.FontsNotFound;
        }

        if (builtin.os.tag == .macos) {
            paths.symbol_fallback = try allocator.dupeZ(u8, "/System/Library/Fonts/SFNSMono.ttf");
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
