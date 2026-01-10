const std = @import("std");
const fs = std.fs;
const toml = @import("toml");

pub const MIN_GRID_SIZE: i32 = 1;
pub const MAX_GRID_SIZE: i32 = 12;
pub const DEFAULT_GRID_ROWS: i32 = 3;
pub const DEFAULT_GRID_COLS: i32 = 3;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const default_background: Color = .{ .r = 14, .g = 17, .b = 22 };
    pub const default_foreground: Color = .{ .r = 205, .g = 214, .b = 224 };
    pub const default_accent: Color = .{ .r = 97, .g = 175, .b = 239 };
    pub const default_selection: Color = .{ .r = 27, .g = 34, .b = 48 };

    pub fn fromHex(hex: []const u8) ?Color {
        const start: usize = if (hex.len > 0 and hex[0] == '#') 1 else 0;
        const hex_digits = hex[start..];

        if (hex_digits.len != 6) return null;

        const r = std.fmt.parseInt(u8, hex_digits[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex_digits[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex_digits[4..6], 16) catch return null;

        return .{ .r = r, .g = g, .b = b };
    }

    pub fn toHex(self: Color, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b });
    }
};

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

pub const WindowConfig = struct {
    width: i32 = 1280,
    height: i32 = 720,
    x: i32 = -1,
    y: i32 = -1,
};

pub const PaletteConfig = struct {
    black: ?[]const u8 = null,
    red: ?[]const u8 = null,
    green: ?[]const u8 = null,
    yellow: ?[]const u8 = null,
    blue: ?[]const u8 = null,
    magenta: ?[]const u8 = null,
    cyan: ?[]const u8 = null,
    white: ?[]const u8 = null,
    bright_black: ?[]const u8 = null,
    bright_red: ?[]const u8 = null,
    bright_green: ?[]const u8 = null,
    bright_yellow: ?[]const u8 = null,
    bright_blue: ?[]const u8 = null,
    bright_magenta: ?[]const u8 = null,
    bright_cyan: ?[]const u8 = null,
    bright_white: ?[]const u8 = null,

    pub fn getColor(self: PaletteConfig, idx: u4) Color {
        const hex: ?[]const u8 = switch (idx) {
            0 => self.black,
            1 => self.red,
            2 => self.green,
            3 => self.yellow,
            4 => self.blue,
            5 => self.magenta,
            6 => self.cyan,
            7 => self.white,
            8 => self.bright_black,
            9 => self.bright_red,
            10 => self.bright_green,
            11 => self.bright_yellow,
            12 => self.bright_blue,
            13 => self.bright_magenta,
            14 => self.bright_cyan,
            15 => self.bright_white,
        };
        if (hex) |h| {
            if (Color.fromHex(h)) |c| return c;
        }
        return default_palette[idx];
    }
};

pub const ThemeConfig = struct {
    background: ?[]const u8 = null,
    foreground: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    accent: ?[]const u8 = null,
    palette: PaletteConfig = .{},

    pub fn getBackground(self: ThemeConfig) Color {
        if (self.background) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_background;
    }

    pub fn getForeground(self: ThemeConfig) Color {
        if (self.foreground) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_foreground;
    }

    pub fn getSelection(self: ThemeConfig) Color {
        if (self.selection) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_selection;
    }

    pub fn getAccent(self: ThemeConfig) Color {
        if (self.accent) |hex| {
            if (Color.fromHex(hex)) |c| return c;
        }
        return Color.default_accent;
    }

    pub fn getPaletteColor(self: ThemeConfig, idx: u4) Color {
        return self.palette.getColor(idx);
    }
};

pub const default_palette = [16]Color{
    .{ .r = 14, .g = 17, .b = 22 },
    .{ .r = 224, .g = 108, .b = 117 },
    .{ .r = 152, .g = 195, .b = 121 },
    .{ .r = 209, .g = 154, .b = 102 },
    .{ .r = 97, .g = 175, .b = 239 },
    .{ .r = 198, .g = 120, .b = 221 },
    .{ .r = 86, .g = 182, .b = 194 },
    .{ .r = 171, .g = 178, .b = 191 },
    .{ .r = 92, .g = 99, .b = 112 },
    .{ .r = 224, .g = 108, .b = 117 },
    .{ .r = 152, .g = 195, .b = 121 },
    .{ .r = 229, .g = 192, .b = 123 },
    .{ .r = 97, .g = 175, .b = 239 },
    .{ .r = 198, .g = 120, .b = 221 },
    .{ .r = 86, .g = 182, .b = 194 },
    .{ .r = 205, .g = 214, .b = 224 },
};

pub const Config = struct {
    font: FontConfig = .{},
    window: WindowConfig = .{},
    theme: ThemeConfig = .{},
    grid_rows: i32 = DEFAULT_GRID_ROWS,
    grid_cols: i32 = DEFAULT_GRID_COLS,

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
        var writer = std.io.Writer.fixed(&buf);
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

        config.migrateFromLegacy();
        config.grid_rows = std.math.clamp(config.grid_rows, MIN_GRID_SIZE, MAX_GRID_SIZE);
        config.grid_cols = std.math.clamp(config.grid_cols, MIN_GRID_SIZE, MAX_GRID_SIZE);

        return config;
    }

    fn migrateFromLegacy(self: *Config) void {
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
        if (self.font_family_owned) {
            if (self.font_family) |value| {
                allocator.free(value);
            }
        }
        self.font_family = null;
        self.font_family_owned = false;
    }

    pub fn getFontSize(self: Config) i32 {
        return self.font.size;
    }

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
        \\grid_rows = 3
        \\grid_cols = 4
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
    try std.testing.expectEqual(@as(i32, 3), config.grid_rows);
    try std.testing.expectEqual(@as(i32, 4), config.grid_cols);
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
        \\grid_rows = 3
        \\grid_cols = 4
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
    try std.testing.expectEqual(@as(i32, 3), config.grid_rows);
    try std.testing.expectEqual(@as(i32, 4), config.grid_cols);
}
