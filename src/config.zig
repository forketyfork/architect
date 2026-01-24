const std = @import("std");
const fs = std.fs;
const toml = @import("toml");

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

    window: WindowConfig = .{},
    font_size: c_int = 14,
    terminal_paths: std.ArrayListUnmanaged([]const u8) = .{},

    const TomlPersistenceV2 = struct {
        window: WindowConfig = .{},
        font_size: c_int = 14,
        terminals: ?[]const []const u8 = null,
    };

    const TomlPersistenceV1 = struct {
        window: WindowConfig = .{},
        font_size: c_int = 14,
        terminals: ?toml.HashMap([]const u8) = null,
    };

    pub fn init(allocator: std.mem.Allocator) Persistence {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *Persistence, allocator: std.mem.Allocator) void {
        self.clearTerminalPaths(allocator);
        self.terminal_paths.deinit(allocator);
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

        var persistence = Persistence.init(allocator);

        var parser_v2 = toml.Parser(TomlPersistenceV2).init(allocator);
        defer parser_v2.deinit();

        if (parser_v2.parseString(contents)) |result| {
            defer result.deinit();
            persistence.window = result.value.window;
            persistence.font_size = result.value.font_size;

            if (result.value.terminals) |paths| {
                for (paths) |path| {
                    try persistence.appendTerminalPath(allocator, path);
                }
            }

            return persistence;
        } else |_| {}

        var parser_v1 = toml.Parser(TomlPersistenceV1).init(allocator);
        defer parser_v1.deinit();

        var result_v1 = parser_v1.parseString(contents) catch |err| {
            std.log.err("Failed to parse persistence TOML: {any}", .{err});
            return Persistence.init(allocator);
        };
        defer result_v1.deinit();

        persistence.window = result_v1.value.window;
        persistence.font_size = result_v1.value.font_size;

        if (result_v1.value.terminals) |stored| {
            try persistence.appendLegacyTerminals(allocator, stored);
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

        try self.saveToPath(allocator, persistence_path);
    }

    pub fn saveToPath(self: Persistence, allocator: std.mem.Allocator, path: []const u8) !void {
        var writer = std.Io.Writer.Allocating.init(allocator);
        defer writer.deinit();
        try self.serializeToWriter(&writer.writer);
        const serialized = writer.written();

        const file = try fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(serialized);
    }

    pub fn serializeToWriter(self: Persistence, writer: anytype) !void {
        // Write font_size first (top-level scalar)
        try writer.print("font_size = {d}\n", .{self.font_size});

        // Write terminals array before any sections
        if (self.terminal_paths.items.len > 0) {
            try writer.writeAll("terminals = [");
            for (self.terminal_paths.items, 0..) |path, idx| {
                if (idx != 0) try writer.writeAll(", ");
                try writeTomlStringToWriter(writer, path);
            }
            try writer.writeAll("]\n");
        }

        // Write [window] section last
        try writer.writeAll("[window]\n");
        try writer.print("height = {d}\n", .{self.window.height});
        try writer.print("width = {d}\n", .{self.window.width});
        try writer.print("x = {d}\n", .{self.window.x});
        try writer.print("y = {d}\n", .{self.window.y});
    }

    pub fn getPersistencePath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "persistence.toml" });
    }

    pub fn appendTerminalPath(self: *Persistence, allocator: std.mem.Allocator, path: []const u8) !void {
        const value = try allocator.dupe(u8, path);
        errdefer allocator.free(value);
        try self.terminal_paths.append(allocator, value);
    }

    pub fn clearTerminalPaths(self: *Persistence, allocator: std.mem.Allocator) void {
        for (self.terminal_paths.items) |path| {
            allocator.free(path);
        }
        self.terminal_paths.clearRetainingCapacity();
    }

    fn appendLegacyTerminals(self: *Persistence, allocator: std.mem.Allocator, stored: toml.HashMap([]const u8)) !void {
        const LegacyTerminalEntry = struct {
            row: usize,
            col: usize,
            path: []const u8,

            fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
                if (lhs.row != rhs.row) return lhs.row < rhs.row;
                return lhs.col < rhs.col;
            }
        };

        var entries = std.ArrayList(LegacyTerminalEntry).empty;
        defer entries.deinit(allocator);

        var it = stored.map.iterator();
        while (it.next()) |entry| {
            const parsed = parseTerminalKey(entry.key_ptr.*) orelse continue;
            try entries.append(allocator, .{
                .row = parsed.row,
                .col = parsed.col,
                .path = entry.value_ptr.*,
            });
        }

        std.mem.sort(LegacyTerminalEntry, entries.items, {}, LegacyTerminalEntry.lessThan);

        for (entries.items) |entry| {
            try self.appendTerminalPath(allocator, entry.path);
        }
    }

    fn writeTomlStringToWriter(writer: anytype, value: []const u8) !void {
        _ = try writer.writeByte('"');
        var curr_pos: usize = 0;
        while (curr_pos < value.len) {
            const next_pos = std.mem.indexOfAnyPos(u8, value, curr_pos, &.{ '"', '\n', '\t', '\r', '\\', 0x0C, 0x08 }) orelse value.len;
            try writer.print("{s}", .{value[curr_pos..next_pos]});
            if (next_pos != value.len) {
                _ = try writer.writeByte('\\');
                switch (value[next_pos]) {
                    '"' => _ = try writer.writeByte('"'),
                    '\n' => _ = try writer.writeByte('n'),
                    '\t' => _ = try writer.writeByte('t'),
                    '\r' => _ = try writer.writeByte('r'),
                    '\\' => _ = try writer.writeByte('\\'),
                    0x0C => _ = try writer.writeByte('f'),
                    0x08 => _ = try writer.writeByte('b'),
                    else => unreachable,
                }
            }
            curr_pos = next_pos + 1;
        }
        _ = try writer.writeByte('"');
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
            \\# Grid options (grid size is dynamic based on terminal count)
            \\# [grid]
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
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), config.grid.font_scale, 0.0001);
    try std.testing.expectEqual(false, config.rendering.vsync);
    try std.testing.expectEqual(false, config.ui.show_hotkey_feedback);
    try std.testing.expectEqual(false, config.ui.enable_animations);
}

test "Config - parse with all theme palette colors" {
    const allocator = std.testing.allocator;

    const content =
        \\[font]
        \\size = 14
        \\
        \\[theme]
        \\background = "#0E1116"
        \\foreground = "#CDD6E0"
        \\
        \\[theme.palette]
        \\black = "#0E1116"
        \\red = "#E06C75"
        \\green = "#98C379"
        \\yellow = "#D19A66"
        \\blue = "#61AFEF"
        \\magenta = "#C678DD"
        \\cyan = "#56B6C2"
        \\white = "#ABB2BF"
        \\bright_black = "#5C6370"
        \\bright_red = "#E06C75"
        \\bright_green = "#98C379"
        \\bright_yellow = "#E5C07B"
        \\bright_blue = "#61AFEF"
        \\bright_magenta = "#C678DD"
        \\bright_cyan = "#56B6C2"
        \\bright_white = "#CDD6E0"
        \\
    ;

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(content);
    defer result.deinit();

    const config = result.value;

    try std.testing.expect(config.theme.palette.black != null);
    try std.testing.expectEqualStrings("#0E1116", config.theme.palette.black.?);
    try std.testing.expect(config.theme.palette.red != null);
    try std.testing.expectEqualStrings("#E06C75", config.theme.palette.red.?);
}

test "parseTerminalKey decodes 1-based coordinates" {
    const parsed = parseTerminalKey("terminal_2_3").?;
    try std.testing.expectEqual(@as(usize, 1), parsed.row);
    try std.testing.expectEqual(@as(usize, 2), parsed.col);
    try std.testing.expect(parseTerminalKey("terminal_x") == null);
    try std.testing.expect(parseTerminalKey("something_else") == null);
}

test "Persistence.appendTerminalPath preserves order" {
    const allocator = std.testing.allocator;
    var persistence = Persistence.init(allocator);
    defer persistence.deinit(allocator);

    try persistence.appendTerminalPath(allocator, "/one");
    try persistence.appendTerminalPath(allocator, "/two");

    try std.testing.expectEqual(@as(usize, 2), persistence.terminal_paths.items.len);
    try std.testing.expectEqualStrings("/one", persistence.terminal_paths.items[0]);
    try std.testing.expectEqualStrings("/two", persistence.terminal_paths.items[1]);
}

test "Persistence.appendLegacyTerminals migrates row-major order" {
    const allocator = std.testing.allocator;
    var persistence = Persistence.init(allocator);
    defer persistence.deinit(allocator);

    var legacy = toml.HashMap([]const u8){ .map = std.StringHashMap([]const u8).init(allocator) };
    defer {
        var it = legacy.map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        legacy.map.deinit();
    }

    const key_b = try allocator.dupe(u8, "terminal_2_1");
    errdefer allocator.free(key_b);
    const val_b = try allocator.dupe(u8, "/b");
    errdefer allocator.free(val_b);
    try legacy.map.put(key_b, val_b);

    const key_a = try allocator.dupe(u8, "terminal_1_2");
    errdefer allocator.free(key_a);
    const val_a = try allocator.dupe(u8, "/a");
    errdefer allocator.free(val_a);
    try legacy.map.put(key_a, val_a);

    try persistence.appendLegacyTerminals(allocator, legacy);

    try std.testing.expectEqual(@as(usize, 2), persistence.terminal_paths.items.len);
    try std.testing.expectEqualStrings("/a", persistence.terminal_paths.items[0]);
    try std.testing.expectEqualStrings("/b", persistence.terminal_paths.items[1]);
}

test "Persistence save/load round-trip preserves all fields" {
    const allocator = std.testing.allocator;

    const tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const test_file = try fs.path.join(allocator, &[_][]const u8{ tmp_path, "test_persistence.toml" });
    defer allocator.free(test_file);

    var original = Persistence.init(allocator);
    defer original.deinit(allocator);

    original.window.width = 1920;
    original.window.height = 1080;
    original.window.x = 100;
    original.window.y = 200;
    original.font_size = 16;
    try original.appendTerminalPath(allocator, "/home/user/project1");
    try original.appendTerminalPath(allocator, "/home/user/project2");
    try original.appendTerminalPath(allocator, "/tmp/test");

    try original.saveToPath(allocator, test_file);

    const file = try fs.openFileAbsolute(test_file, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    var loaded = Persistence.init(allocator);
    defer loaded.deinit(allocator);

    var parser = toml.Parser(Persistence.TomlPersistenceV2).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(contents);
    defer result.deinit();

    loaded.window = result.value.window;
    loaded.font_size = result.value.font_size;

    if (result.value.terminals) |paths| {
        for (paths) |path| {
            try loaded.appendTerminalPath(allocator, path);
        }
    }

    try std.testing.expectEqual(original.window.width, loaded.window.width);
    try std.testing.expectEqual(original.window.height, loaded.window.height);
    try std.testing.expectEqual(original.window.x, loaded.window.x);
    try std.testing.expectEqual(original.window.y, loaded.window.y);
    try std.testing.expectEqual(original.font_size, loaded.font_size);
    try std.testing.expectEqual(original.terminal_paths.items.len, loaded.terminal_paths.items.len);

    for (original.terminal_paths.items, loaded.terminal_paths.items) |orig_path, load_path| {
        try std.testing.expectEqualStrings(orig_path, load_path);
    }
}
