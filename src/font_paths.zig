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

        const selected_family = if (font_family) |ff| if (ff.len > 0) ff else DEFAULT_FONT_FAMILY else DEFAULT_FONT_FAMILY;

        if (findSystemFont(allocator, selected_family, "Regular")) |regular_path| {
            paths.regular = regular_path;
        } else |_| {
            if (font_family) |requested| {
                log.warn("Font family '{s}' not found, falling back to {s}", .{ requested, DEFAULT_FONT_FAMILY });
            }
            paths.regular = try findSystemFont(allocator, DEFAULT_FONT_FAMILY, "Regular");
        }

        const regular_is_ttc = std.mem.endsWith(u8, paths.regular, ".ttc");

        if (findSystemFont(allocator, selected_family, "Bold")) |bold_path| {
            paths.bold = bold_path;
        } else |_| {
            if (regular_is_ttc) {
                log.info("Using TTC file for Bold variant: {s}", .{paths.regular});
                paths.bold = try allocator.dupeZ(u8, paths.regular);
            } else if (font_family != null and !std.mem.eql(u8, selected_family, DEFAULT_FONT_FAMILY)) {
                paths.bold = findSystemFont(allocator, DEFAULT_FONT_FAMILY, "Bold") catch try allocator.dupeZ(u8, paths.regular);
            } else {
                paths.bold = try allocator.dupeZ(u8, paths.regular);
            }
        }

        if (findSystemFont(allocator, selected_family, "Italic")) |italic_path| {
            paths.italic = italic_path;
        } else |_| {
            if (regular_is_ttc) {
                log.info("Using TTC file for Italic variant: {s}", .{paths.regular});
                paths.italic = try allocator.dupeZ(u8, paths.regular);
            } else if (font_family != null and !std.mem.eql(u8, selected_family, DEFAULT_FONT_FAMILY)) {
                paths.italic = findSystemFont(allocator, DEFAULT_FONT_FAMILY, "Italic") catch try allocator.dupeZ(u8, paths.regular);
            } else {
                paths.italic = try allocator.dupeZ(u8, paths.regular);
            }
        }

        if (findSystemFont(allocator, selected_family, "BoldItalic")) |bold_italic_path| {
            paths.bold_italic = bold_italic_path;
        } else |_| {
            if (regular_is_ttc) {
                log.info("Using TTC file for BoldItalic variant: {s}", .{paths.regular});
                paths.bold_italic = try allocator.dupeZ(u8, paths.regular);
            } else if (font_family != null and !std.mem.eql(u8, selected_family, DEFAULT_FONT_FAMILY)) {
                paths.bold_italic = findSystemFont(allocator, DEFAULT_FONT_FAMILY, "BoldItalic") catch try allocator.dupeZ(u8, paths.regular);
            } else {
                paths.bold_italic = try allocator.dupeZ(u8, paths.regular);
            }
        }

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

const DEFAULT_FONT_FAMILY = "SFNSMono";

fn findSystemFont(allocator: std.mem.Allocator, font_family: []const u8, style: []const u8) ![:0]const u8 {
    const search_dirs = [_][]const u8{
        "/System/Library/Fonts",
        "/Library/Fonts",
    };

    const home = std.posix.getenv("HOME");
    const style_suffix = style;

    for (search_dirs) |dir| {
        if (searchFontInDirectory(allocator, dir, font_family, style_suffix)) |path| {
            return path;
        } else |_| {}
    }

    if (home) |h| {
        const user_fonts_dir = try std.fmt.allocPrint(allocator, "{s}/Library/Fonts", .{h});
        defer allocator.free(user_fonts_dir);

        if (searchFontInDirectory(allocator, user_fonts_dir, font_family, style_suffix)) |path| {
            return path;
        } else |_| {}
    }

    log.err("Font not found: {s} {s}", .{ font_family, style });
    return error.FontNotFound;
}

fn searchFontInDirectory(allocator: std.mem.Allocator, dir_path: []const u8, font_family: []const u8, style_suffix: []const u8) ![:0]const u8 {
    const extensions = [_][]const u8{ "otf", "ttf", "ttc" };

    for (extensions) |ext| {
        const font_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.{s}", .{ dir_path, font_family, style_suffix, ext });
        defer allocator.free(font_path);

        std.fs.accessAbsolute(font_path, .{}) catch continue;
        log.info("Found font: {s}", .{font_path});
        return allocator.dupeZ(u8, font_path);
    }

    for (extensions) |ext| {
        const font_path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}.{s}", .{ dir_path, font_family, style_suffix, ext });
        defer allocator.free(font_path);

        std.fs.accessAbsolute(font_path, .{}) catch continue;
        log.info("Found font: {s}", .{font_path});
        return allocator.dupeZ(u8, font_path);
    }

    if (std.mem.eql(u8, style_suffix, "Regular")) {
        for (extensions) |ext| {
            const font_path = try std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ dir_path, font_family, ext });
            defer allocator.free(font_path);

            std.fs.accessAbsolute(font_path, .{}) catch continue;
            log.info("Found font: {s}", .{font_path});
            return allocator.dupeZ(u8, font_path);
        }
    }

    const ttc_path = try std.fmt.allocPrint(allocator, "{s}/{s}.ttc", .{ dir_path, font_family });
    defer allocator.free(ttc_path);
    if (std.fs.accessAbsolute(ttc_path, .{})) {
        log.info("Found TTC file containing {s} variant: {s}", .{ style_suffix, ttc_path });
        return allocator.dupeZ(u8, ttc_path);
    } else |_| {}

    log.info("Recursively searching {s} for {s} {s}", .{ dir_path, font_family, style_suffix });

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        log.warn("Could not open directory {s}: {}", .{ dir_path, err });
        return error.FontNotFound;
    };
    defer dir.close();

    var walker = dir.walk(allocator) catch |err| {
        log.warn("Could not walk directory {s}: {}", .{ dir_path, err });
        return error.FontNotFound;
    };
    defer walker.deinit();

    while (walker.next()) |maybe_entry| {
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;

        const basename = entry.basename;
        const has_valid_ext = blk: {
            for (extensions) |ext| {
                if (std.mem.endsWith(u8, basename, ext)) break :blk true;
            }
            break :blk false;
        };
        if (!has_valid_ext) continue;

        const matches = blk: {
            const pattern1 = try std.fmt.allocPrint(allocator, "{s}-{s}.", .{ font_family, style_suffix });
            defer allocator.free(pattern1);
            if (std.mem.indexOf(u8, basename, pattern1)) |_| break :blk true;

            const pattern2 = try std.fmt.allocPrint(allocator, "{s}{s}.", .{ font_family, style_suffix });
            defer allocator.free(pattern2);
            if (std.mem.indexOf(u8, basename, pattern2)) |_| break :blk true;

            if (std.mem.eql(u8, style_suffix, "Regular")) {
                const pattern3 = try std.fmt.allocPrint(allocator, "{s}.", .{font_family});
                defer allocator.free(pattern3);
                if (std.mem.indexOf(u8, basename, pattern3)) |_| {
                    const has_style_marker = std.mem.indexOf(u8, basename, "-") orelse std.mem.indexOf(u8, basename, "Bold") orelse std.mem.indexOf(u8, basename, "Italic") orelse std.mem.indexOf(u8, basename, "Light") orelse std.mem.indexOf(u8, basename, "Medium");
                    if (has_style_marker == null) break :blk true;
                }
            }

            break :blk false;
        };

        if (matches) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
            defer allocator.free(full_path);
            log.info("Found font via recursive search: {s}", .{full_path});
            return allocator.dupeZ(u8, full_path);
        }

        if (std.mem.endsWith(u8, basename, ".ttc")) {
            const ttc_name_end = basename.len - 4;
            if (std.mem.eql(u8, basename[0..ttc_name_end], font_family)) {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
                defer allocator.free(full_path);
                log.info("Found TTC file via recursive search containing {s} variant: {s}", .{ style_suffix, full_path });
                return allocator.dupeZ(u8, full_path);
            }
        }
    } else |err| {
        log.warn("Error during directory walk: {}", .{err});
    }

    return error.FontNotFound;
}
