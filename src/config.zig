const std = @import("std");
const fs = std.fs;
const toml = @import("toml");

pub const MIN_GRID_SIZE: i32 = 1;
pub const MAX_GRID_SIZE: i32 = 12;
pub const DEFAULT_GRID_ROWS: i32 = 3;
pub const DEFAULT_GRID_COLS: i32 = 3;
pub const MIN_GRID_FONT_SCALE: f32 = 0.5;
pub const MAX_GRID_FONT_SCALE: f32 = 3.0;

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

    pub fn duplicate(self: FontConfig, allocator: std.mem.Allocator) !FontConfig {
        return FontConfig{
            .size = self.size,
            .family = if (self.family) |f| try allocator.dupe(u8, f) else null,
            .family_owned = self.family != null,
        };
    }
};

pub const WindowConfig = struct {
    width: i32 = 1280,
    height: i32 = 720,
    x: i32 = -1,
    y: i32 = -1,
};

pub const GridConfig = struct {
    rows: i32 = DEFAULT_GRID_ROWS,
    cols: i32 = DEFAULT_GRID_COLS,
    font_scale: f32 = 1.0,
};

pub const UiConfig = struct {
    show_hotkey_feedback: bool = true,
    enable_animations: bool = true,
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
            if (h.len > 0) {
                if (Color.fromHex(h)) |c| return c;
            }
        }
        return default_palette[idx];
    }

    pub fn deinit(self: *PaletteConfig, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(PaletteConfig).@"struct".fields) |field| {
            if (@field(self, field.name)) |value| {
                allocator.free(value);
            }
        }
    }

    pub fn duplicate(self: PaletteConfig, allocator: std.mem.Allocator) !PaletteConfig {
        var result: PaletteConfig = .{};
        inline for (@typeInfo(PaletteConfig).@"struct".fields) |field| {
            if (@field(self, field.name)) |value| {
                @field(result, field.name) = try allocator.dupe(u8, value);
            }
        }
        return result;
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
            if (hex.len > 0) {
                if (Color.fromHex(hex)) |c| return c;
            }
        }
        return Color.default_background;
    }

    pub fn getForeground(self: ThemeConfig) Color {
        if (self.foreground) |hex| {
            if (hex.len > 0) {
                if (Color.fromHex(hex)) |c| return c;
            }
        }
        return Color.default_foreground;
    }

    pub fn getSelection(self: ThemeConfig) Color {
        if (self.selection) |hex| {
            if (hex.len > 0) {
                if (Color.fromHex(hex)) |c| return c;
            }
        }
        return Color.default_selection;
    }

    pub fn getAccent(self: ThemeConfig) Color {
        if (self.accent) |hex| {
            if (hex.len > 0) {
                if (Color.fromHex(hex)) |c| return c;
            }
        }
        return Color.default_accent;
    }

    pub fn getPaletteColor(self: ThemeConfig, idx: u4) Color {
        return self.palette.getColor(idx);
    }

    pub fn deinit(self: *ThemeConfig, allocator: std.mem.Allocator) void {
        if (self.background) |value| allocator.free(value);
        if (self.foreground) |value| allocator.free(value);
        if (self.selection) |value| allocator.free(value);
        if (self.accent) |value| allocator.free(value);
        self.palette.deinit(allocator);
    }

    pub fn duplicate(self: ThemeConfig, allocator: std.mem.Allocator) !ThemeConfig {
        return ThemeConfig{
            .background = if (self.background) |v| try allocator.dupe(u8, v) else null,
            .foreground = if (self.foreground) |v| try allocator.dupe(u8, v) else null,
            .selection = if (self.selection) |v| try allocator.dupe(u8, v) else null,
            .accent = if (self.accent) |v| try allocator.dupe(u8, v) else null,
            .palette = try self.palette.duplicate(allocator),
        };
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

pub const Rendering = struct {
    vsync: bool = true,
};

pub const MetricsConfig = struct {
    enabled: bool = false,
};

pub const Persistence = struct {
    const TerminalKeyPrefix = "terminal_";

    pub const TerminalEntry = struct {
        index: usize,
        path: []const u8,
    };

    window: WindowConfig = .{},
    font_size: c_int = 14,
    terminals: std.StringHashMap([]const u8),

    const TomlPersistence = struct {
        window: WindowConfig = .{},
        font_size: c_int = 14,
        terminals: ?toml.HashMap([]const u8) = null,
    };

    pub fn init(allocator: std.mem.Allocator) Persistence {
        return .{
            .window = .{},
            .font_size = 14,
            .terminals = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Persistence) void {
        self.clearTerminals();
        self.terminals.deinit();
    }

    pub fn load(allocator: std.mem.Allocator) !Persistence {
        const persistence_path = try getPersistencePath(allocator);
        defer allocator.free(persistence_path);

        const file = fs.openFileAbsolute(persistence_path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => Persistence.init(allocator),
                else => err,
            };
        };
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(contents);

        var parser = toml.Parser(TomlPersistence).init(allocator);
        defer parser.deinit();

        var result = parser.parseString(contents) catch |err| {
            std.log.err("Failed to parse persistence TOML: {any}", .{err});
            return Persistence.init(allocator);
        };
        defer result.deinit();

        var persistence = Persistence.init(allocator);
        persistence.window = result.value.window;
        persistence.font_size = result.value.font_size;

        if (result.value.terminals) |stored| {
            var it = stored.map.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);

                const val_copy = try allocator.dupe(u8, entry.value_ptr.*);
                errdefer allocator.free(val_copy);

                try persistence.terminals.put(key_copy, val_copy);
            }
        }

        return persistence;
    }

    pub fn save(self: Persistence, allocator: std.mem.Allocator) !void {
        const persistence_path = try getPersistencePath(allocator);
        defer allocator.free(persistence_path);

        const persistence_dir = fs.path.dirname(persistence_path) orelse return error.InvalidPath;
        fs.makeDirAbsolute(persistence_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        try toml.serialize(allocator, self, &writer.writer);
        const serialized = writer.written();

        const file = try fs.createFileAbsolute(persistence_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(serialized);
    }

    pub fn getPersistencePath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "persistence.toml" });
    }

    pub fn pruneTerminals(self: *Persistence, allocator: std.mem.Allocator, grid_cols: usize, grid_rows: usize) !bool {
        var to_remove = std.ArrayList([]const u8).empty;
        defer to_remove.deinit(allocator);

        var seen = std.AutoHashMap(usize, void).init(allocator);
        defer seen.deinit();

        var changed = false;
        var it = self.terminals.iterator();
        while (it.next()) |entry| {
            const parsed = parseTerminalKey(entry.key_ptr.*) orelse {
                try to_remove.append(allocator, entry.key_ptr.*);
                continue;
            };

            if (parsed.row >= grid_rows or parsed.col >= grid_cols) {
                try to_remove.append(allocator, entry.key_ptr.*);
                continue;
            }

            const index = parsed.row * grid_cols + parsed.col;
            if (seen.contains(index)) {
                try to_remove.append(allocator, entry.key_ptr.*);
                continue;
            }

            try seen.put(index, {});
        }

        for (to_remove.items) |key| {
            if (self.terminals.fetchRemove(key)) |removed| {
                allocator.free(removed.key);
                allocator.free(removed.value);
                changed = true;
            }
        }

        return changed;
    }

    pub fn collectTerminalEntries(self: *const Persistence, allocator: std.mem.Allocator, grid_cols: usize, grid_rows: usize) !std.ArrayList(TerminalEntry) {
        var entries = std.ArrayList(TerminalEntry).empty;
        errdefer entries.deinit(allocator);

        var it = self.terminals.iterator();
        while (it.next()) |entry| {
            const parsed = parseTerminalKey(entry.key_ptr.*) orelse continue;
            if (parsed.row >= grid_rows or parsed.col >= grid_cols) continue;
            const index = parsed.row * grid_cols + parsed.col;
            try entries.append(allocator, .{ .index = index, .path = entry.value_ptr.* });
        }

        return entries;
    }

    pub fn setTerminal(self: *Persistence, allocator: std.mem.Allocator, index: usize, grid_cols: usize, path: []const u8) !void {
        const row = index / grid_cols;
        const col = index % grid_cols;
        const key = try std.fmt.allocPrint(allocator, "{s}{d}_{d}", .{ TerminalKeyPrefix, row + 1, col + 1 });
        errdefer allocator.free(key);

        const value = try allocator.dupe(u8, path);
        errdefer allocator.free(value);

        if (self.terminals.fetchRemove(key)) |old_entry| {
            allocator.free(old_entry.key);
            allocator.free(old_entry.value);
        }

        try self.terminals.put(key, value);
    }

    pub fn clearTerminals(self: *Persistence) void {
        var it = self.terminals.iterator();
        while (it.next()) |entry| {
            self.terminals.allocator.free(entry.key_ptr.*);
            self.terminals.allocator.free(entry.value_ptr.*);
        }
        self.terminals.clearRetainingCapacity();
    }
};

fn parseTerminalKey(key: []const u8) ?struct { row: usize, col: usize } {
    if (!std.mem.startsWith(u8, key, Persistence.TerminalKeyPrefix)) return null;
    const suffix = key[Persistence.TerminalKeyPrefix.len..];
    const sep_index = std.mem.indexOfScalar(u8, suffix, '_') orelse return null;

    const row_str = suffix[0..sep_index];
    const col_str = suffix[sep_index + 1 ..];

    const row = std.fmt.parseInt(usize, row_str, 10) catch return null;
    const col = std.fmt.parseInt(usize, col_str, 10) catch return null;

    if (row == 0 or col == 0) return null;

    return .{ .row = row - 1, .col = col - 1 };
}

pub const Config = struct {
    font: FontConfig = .{},
    window: WindowConfig = .{},
    grid: GridConfig = .{},
    theme: ThemeConfig = .{},
    ui: UiConfig = .{},
    rendering: Rendering = .{},
    metrics: MetricsConfig = .{},

    pub fn load(allocator: std.mem.Allocator) LoadError!Config {
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        return loadTomlConfig(allocator, config_path);
    }

    pub fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "config.toml" });
    }

    pub fn createDefaultConfigFile(allocator: std.mem.Allocator) SaveError!void {
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        const config_dir = fs.path.dirname(config_path) orelse return error.InvalidPath;
        fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const template =
            \\# Architect configuration file (user-editable)
            \\# This file is read-only to the application - edit freely via Cmd+,
            \\# Changes take effect on next launch.
            \\#
            \\# Note: Window position/size and font size are stored in persistence.toml
            \\# and managed automatically by the application.
            \\
            \\# Font options
            \\# [font]
            \\# family = "SFNSMono"
            \\
            \\# Terminal grid size, 1-12 (default: 3x3)
            \\# [grid]
            \\# rows = 3
            \\# cols = 3
            \\# font_scale = 1.0
            \\
            \\# Rendering options
            \\# [rendering]
            \\# vsync = true
            \\
            \\# UI options
            \\# [ui]
            \\# show_hotkey_feedback = true
            \\# enable_animations = true
            \\
            \\# Theme colors (hex format)
            \\# [theme]
            \\# background = "#0E1116"
            \\# foreground = "#CDD6E0"
            \\# selection = "#1B2230"
            \\# accent = "#61AFEF"
            \\
            \\# ANSI palette (optional, uncomment to customize)
            \\# [theme.palette]
            \\# black = "#0E1116"
            \\# red = "#E06C75"
            \\# green = "#98C379"
            \\# yellow = "#D19A66"
            \\# blue = "#61AFEF"
            \\# magenta = "#C678DD"
            \\# cyan = "#56B6C2"
            \\# white = "#ABB2BF"
            \\# bright_black = "#5C6370"
            \\# bright_red = "#E06C75"
            \\# bright_green = "#98C379"
            \\# bright_yellow = "#E5C07B"
            \\# bright_blue = "#61AFEF"
            \\# bright_magenta = "#C678DD"
            \\# bright_cyan = "#56B6C2"
            \\# bright_white = "#CDD6E0"
            \\
            \\# Metrics overlay (Cmd+Shift+M to toggle when enabled)
            \\# [metrics]
            \\# enabled = false
            \\
        ;

        const file = try fs.createFileAbsolute(config_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(template);
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

        config.grid.rows = std.math.clamp(config.grid.rows, MIN_GRID_SIZE, MAX_GRID_SIZE);
        config.grid.cols = std.math.clamp(config.grid.cols, MIN_GRID_SIZE, MAX_GRID_SIZE);
        config.grid.font_scale = std.math.clamp(config.grid.font_scale, MIN_GRID_FONT_SCALE, MAX_GRID_FONT_SCALE);

        config.font = try config.font.duplicate(allocator);
        config.theme = try config.theme.duplicate(allocator);

        return config;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        self.font.deinit(allocator);
        self.theme.deinit(allocator);
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
        \\[grid]
        \\rows = 3
        \\cols = 4
        \\font_scale = 1.25
        \\
        \\[rendering]
        \\vsync = false
        \\
        \\[ui]
        \\show_hotkey_feedback = false
        \\enable_animations = false
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
    try std.testing.expectEqual(@as(i32, 3), config.grid.rows);
    try std.testing.expectEqual(@as(i32, 4), config.grid.cols);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), config.grid.font_scale, 0.0001);
    try std.testing.expectEqual(false, config.rendering.vsync);
    try std.testing.expectEqual(false, config.ui.show_hotkey_feedback);
    try std.testing.expectEqual(false, config.ui.enable_animations);
}

test "parseTerminalKey decodes 1-based coordinates" {
    const parsed = parseTerminalKey("terminal_2_3").?;
    try std.testing.expectEqual(@as(usize, 1), parsed.row);
    try std.testing.expectEqual(@as(usize, 2), parsed.col);
    try std.testing.expect(parseTerminalKey("terminal_x") == null);
    try std.testing.expect(parseTerminalKey("something_else") == null);
}

test "Persistence.pruneTerminals removes out-of-bounds entries" {
    const allocator = std.testing.allocator;
    var persistence = Persistence.init(allocator);
    defer persistence.deinit();

    try persistence.setTerminal(allocator, 0, 2, "/one");

    const bad_key = try std.fmt.allocPrint(allocator, "{s}3_1", .{Persistence.TerminalKeyPrefix});
    const bad_value = try allocator.dupe(u8, "/bad");
    try persistence.terminals.put(bad_key, bad_value);

    const changed = try persistence.pruneTerminals(allocator, 2, 2);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), persistence.terminals.count());
}

test "Persistence.collectTerminalEntries maps keys to session indices" {
    const allocator = std.testing.allocator;
    var persistence = Persistence.init(allocator);
    defer persistence.deinit();

    try persistence.setTerminal(allocator, 1, 3, "/a");
    try persistence.setTerminal(allocator, 5, 3, "/b");

    var entries = try persistence.collectTerminalEntries(allocator, 3, 3);
    defer entries.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), entries.items.len);

    var seen = std.AutoHashMap(usize, []const u8).init(allocator);
    defer seen.deinit();
    for (entries.items) |entry| {
        try seen.put(entry.index, entry.path);
    }

    try std.testing.expect(seen.contains(1));
    try std.testing.expect(seen.contains(5));
    try std.testing.expectEqualStrings("/a", seen.get(1).?);
    try std.testing.expectEqualStrings("/b", seen.get(5).?);
}
