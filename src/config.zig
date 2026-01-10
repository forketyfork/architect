const std = @import("std");
const fs = std.fs;
const toml = @import("toml");

/// RGB color represented as a hex string (e.g., "#E06C75")
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const default_background: Color = .{ .r = 14, .g = 17, .b = 22 }; // #0E1116
    pub const default_foreground: Color = .{ .r = 205, .g = 214, .b = 224 }; // #CDD6E0
    pub const default_accent: Color = .{ .r = 97, .g = 175, .b = 239 }; // #61AFEF
    pub const default_selection: Color = .{ .r = 27, .g = 34, .b = 48 }; // #1B2230

    /// Parse a hex color string like "#RRGGBB" or "RRGGBB"
    pub fn fromHex(hex: []const u8) ?Color {
        const start: usize = if (hex.len > 0 and hex[0] == '#') 1 else 0;
        const hex_digits = hex[start..];

        if (hex_digits.len != 6) return null;

        const r = std.fmt.parseInt(u8, hex_digits[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex_digits[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex_digits[4..6], 16) catch return null;

        return .{ .r = r, .g = g, .b = b };
    }

    /// Convert to hex string (allocates)
    pub fn toHex(self: Color, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b });
    }
};

/// Font configuration section
pub const FontConfig = struct {
    size: i32 = 14,
    family: ?[]const u8 = null,
    family_owned: bool = false,

    pub fn deinit(self: *FontConfig, allocator: std.mem.Allocator) void {
        if (self.family_owned) {
            if (self.family) |value| {
                allocator.free(value);
            }
        }
        self.family = null;
        self.family_owned = false;
    }
};

/// Window configuration section
pub const WindowConfig = struct {
    width: i32 = 1280,
    height: i32 = 720,
    x: i32 = -1,
    y: i32 = -1,
};

/// Theme/color configuration section
pub const ThemeConfig = struct {
    /// Terminal background color
    background: ?[]const u8 = null,
    /// Terminal foreground (text) color
    foreground: ?[]const u8 = null,
    /// Selection highlight background
    selection: ?[]const u8 = null,
    /// Accent color for UI elements
    accent: ?[]const u8 = null,

    /// 16 ANSI palette colors (8 normal + 8 bright)
    /// Order: black, red, green, yellow, blue, magenta, cyan, white,
    ///        bright_black, bright_red, bright_green, bright_yellow,
    ///        bright_blue, bright_magenta, bright_cyan, bright_white
    palette: ?[16][]const u8 = null,

    /// Get background color, falling back to default
    pub fn getBackground(self: ThemeConfig) Color {
        if (self.background) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_background;
    }

    /// Get foreground color, falling back to default
    pub fn getForeground(self: ThemeConfig) Color {
        if (self.foreground) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_foreground;
    }

    /// Get selection color, falling back to default
    pub fn getSelection(self: ThemeConfig) Color {
        if (self.selection) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_selection;
    }

    /// Get accent color, falling back to default
    pub fn getAccent(self: ThemeConfig) Color {
        if (self.accent) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_accent;
    }

    /// Get a palette color by index (0-15), falling back to default One Dark colors
    pub fn getPaletteColor(self: ThemeConfig, idx: u4) Color {
        if (self.palette) |p| {
            if (Color.fromHex(p[idx])) |c| return c;
        }
        return default_palette[idx];
    }
};

/// Default One Dark palette colors
pub const default_palette = [16]Color{
    // Normal (0-7)
    .{ .r = 14, .g = 17, .b = 22 }, // Black
    .{ .r = 224, .g = 108, .b = 117 }, // Red
    .{ .r = 152, .g = 195, .b = 121 }, // Green
    .{ .r = 209, .g = 154, .b = 102 }, // Yellow
    .{ .r = 97, .g = 175, .b = 239 }, // Blue
    .{ .r = 198, .g = 120, .b = 221 }, // Magenta
    .{ .r = 86, .g = 182, .b = 194 }, // Cyan
    .{ .r = 171, .g = 178, .b = 191 }, // White
    // Bright (8-15)
    .{ .r = 92, .g = 99, .b = 112 }, // BrightBlack
    .{ .r = 224, .g = 108, .b = 117 }, // BrightRed
    .{ .r = 152, .g = 195, .b = 121 }, // BrightGreen
    .{ .r = 229, .g = 192, .b = 123 }, // BrightYellow
    .{ .r = 97, .g = 175, .b = 239 }, // BrightBlue
    .{ .r = 198, .g = 120, .b = 221 }, // BrightMagenta
    .{ .r = 86, .g = 182, .b = 194 }, // BrightCyan
    .{ .r = 205, .g = 214, .b = 224 }, // BrightWhite
};

/// Main configuration structure with sections
pub const Config = struct {
    font: FontConfig = .{},
    window: WindowConfig = .{},
    theme: ThemeConfig = .{},

    // Legacy flat fields for backwards compatibility during migration
    font_size: ?i32 = null,
    font_family: ?[]const u8 = null,
    font_family_owned: bool = false,
    window_width: ?i32 = null,
    window_height: ?i32 = null,
    window_x: ?i32 = null,
    window_y: ?i32 = null,

    pub fn load(allocator: std.mem.Allocator) LoadError!Config {
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        return loadTomlConfig(allocator, config_path);
    }

    pub fn save(self: Config, allocator: std.mem.Allocator) SaveError!void {
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        const config_dir = fs.path.dirname(config_path) orelse return error.InvalidPath;
        fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try toml.serialize(allocator, self, &writer);

        const file = try fs.createFileAbsolute(config_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(writer.buffered());
    }

    fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "config.toml" });
    }

    fn loadTomlConfig(allocator: std.mem.Allocator, config_path: []const u8) LoadError!Config {
        const file = fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ConfigNotFound,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();

        var result = parser.parseString(content) catch |err| {
            std.log.err("Failed to parse TOML config `{s}`: {any}", .{ config_path, err });
            return error.InvalidConfig;
        };
        defer result.deinit();

        var config = result.value;

        // Migrate legacy flat fields to sectioned format
        config.migrateFromLegacy();

        return config;
    }

    /// Migrate legacy flat config fields to the new sectioned format
    fn migrateFromLegacy(self: *Config) void {
        // Migrate font settings
        if (self.font_size) |size| {
            self.font.size = size;
            self.font_size = null;
        }
        if (self.font_family) |family| {
            self.font.family = family;
            self.font.family_owned = self.font_family_owned;
            self.font_family = null;
            self.font_family_owned = false;
        }

        // Migrate window settings
        if (self.window_width) |w| {
            self.window.width = w;
            self.window_width = null;
        }
        if (self.window_height) |h| {
            self.window.height = h;
            self.window_height = null;
        }
        if (self.window_x) |x| {
            self.window.x = x;
            self.window_x = null;
        }
        if (self.window_y) |y| {
            self.window.y = y;
            self.window_y = null;
        }
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.font.deinit(allocator);
        // Handle legacy fields if present
        if (self.font_family_owned) {
            if (self.font_family) |value| {
                allocator.free(value);
            }
        }
        self.font_family = null;
        self.font_family_owned = false;
    }

    /// Get effective font size (from section or default)
    pub fn getFontSize(self: Config) i32 {
        return self.font.size;
    }

    /// Get effective font family (from section or default)
    pub fn getFontFamily(self: Config) []const u8 {
        return self.font.family orelse DEFAULT_FONT_FAMILY;
    }
};

pub const DEFAULT_FONT_FAMILY = "SFNSMono";

pub const LoadError = error{
    ConfigNotFound,
    InvalidConfig,
    HomeNotFound,
    InvalidPath,
    OutOfMemory,
} || fs.File.OpenError || fs.File.ReadError;

pub const SaveError = error{
    HomeNotFound,
    InvalidPath,
    InvalidConfig,
    OutOfMemory,
    WriteFailed,
} || fs.File.OpenError || fs.File.WriteError || fs.Dir.MakeError;

// Tests

test "Color.fromHex - valid hex colors" {
    const white = Color.fromHex("#FFFFFF").?;
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);

    const red = Color.fromHex("E06C75").?;
    try std.testing.expectEqual(@as(u8, 224), red.r);
    try std.testing.expectEqual(@as(u8, 108), red.g);
    try std.testing.expectEqual(@as(u8, 117), red.b);

    const one_dark_bg = Color.fromHex("#0E1116").?;
    try std.testing.expectEqual(@as(u8, 14), one_dark_bg.r);
    try std.testing.expectEqual(@as(u8, 17), one_dark_bg.g);
    try std.testing.expectEqual(@as(u8, 22), one_dark_bg.b);
}

test "Color.fromHex - invalid hex colors" {
    try std.testing.expect(Color.fromHex("") == null);
    try std.testing.expect(Color.fromHex("#FFF") == null);
    try std.testing.expect(Color.fromHex("GGGGGG") == null);
    try std.testing.expect(Color.fromHex("#12345") == null);
}

test "ThemeConfig - default colors" {
    const theme = ThemeConfig{};

    const bg = theme.getBackground();
    try std.testing.expectEqual(@as(u8, 14), bg.r);
    try std.testing.expectEqual(@as(u8, 17), bg.g);
    try std.testing.expectEqual(@as(u8, 22), bg.b);

    const fg = theme.getForeground();
    try std.testing.expectEqual(@as(u8, 205), fg.r);
    try std.testing.expectEqual(@as(u8, 214), fg.g);
    try std.testing.expectEqual(@as(u8, 224), fg.b);
}

test "ThemeConfig - custom colors" {
    const theme = ThemeConfig{
        .background = "#FF0000",
        .foreground = "#00FF00",
    };

    const bg = theme.getBackground();
    try std.testing.expectEqual(@as(u8, 255), bg.r);
    try std.testing.expectEqual(@as(u8, 0), bg.g);
    try std.testing.expectEqual(@as(u8, 0), bg.b);

    const fg = theme.getForeground();
    try std.testing.expectEqual(@as(u8, 0), fg.r);
    try std.testing.expectEqual(@as(u8, 255), fg.g);
    try std.testing.expectEqual(@as(u8, 0), fg.b);
}

test "Config - decode sectioned toml" {
    const allocator = std.testing.allocator;

    const content =
        \\[font]
        \\size = 16
        \\family = "VictorMonoNerdFont"
        \\
        \\[window]
        \\width = 1920
        \\height = 1080
        \\x = 100
        \\y = 100
        \\
        \\[theme]
        \\background = "#1E1E2E"
        \\foreground = "#CDD6F4"
        \\
    ;

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(content);
    defer result.deinit();

    const config = result.value;

    try std.testing.expectEqual(@as(i32, 16), config.font.size);
    try std.testing.expect(config.font.family != null);
    try std.testing.expectEqualStrings("VictorMonoNerdFont", config.font.family.?);
    try std.testing.expectEqual(@as(i32, 1920), config.window.width);
    try std.testing.expectEqual(@as(i32, 1080), config.window.height);
    try std.testing.expectEqual(@as(i32, 100), config.window.x);
    try std.testing.expectEqual(@as(i32, 100), config.window.y);
    try std.testing.expect(config.theme.background != null);
    try std.testing.expectEqualStrings("#1E1E2E", config.theme.background.?);
}

test "Config - decode legacy flat toml with migration" {
    const allocator = std.testing.allocator;

    const content =
        \\font_size = 16
        \\font_family = "VictorMonoNerdFont"
        \\window_width = 1920
        \\window_height = 1080
        \\window_x = 100
        \\window_y = 100
        \\
    ;

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(content);
    defer result.deinit();

    var config = result.value;
    config.migrateFromLegacy();

    try std.testing.expectEqual(@as(i32, 16), config.font.size);
    try std.testing.expect(config.font.family != null);
    try std.testing.expectEqualStrings("VictorMonoNerdFont", config.font.family.?);
    try std.testing.expectEqual(@as(i32, 1920), config.window.width);
    try std.testing.expectEqual(@as(i32, 1080), config.window.height);
    try std.testing.expectEqual(@as(i32, 100), config.window.x);
    try std.testing.expectEqual(@as(i32, 100), config.window.y);
}
