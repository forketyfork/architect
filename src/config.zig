const std = @import("std");
const fs = std.fs;
const toml = @import("toml");

pub const MIN_GRID_SIZE: i32 = 1;
pub const MAX_GRID_SIZE: i32 = 12;
pub const DEFAULT_GRID_ROWS: i32 = 3;
pub const DEFAULT_GRID_COLS: i32 = 3;
pub const DEFAULT_FONT_SIZE: i32 = 14;
pub const DEFAULT_WINDOW_WIDTH: i32 = 1200;
pub const DEFAULT_WINDOW_HEIGHT: i32 = 900;
pub const DEFAULT_WINDOW_X: i32 = -1;
pub const DEFAULT_WINDOW_Y: i32 = -1;

pub const Rendering = struct {
    vsync: bool = true,
};

pub const Config = struct {
    font_size: i32 = DEFAULT_FONT_SIZE,
    font_family: ?[]const u8 = null,
    font_family_owned: bool = false,
    window_width: i32 = DEFAULT_WINDOW_WIDTH,
    window_height: i32 = DEFAULT_WINDOW_HEIGHT,
    window_x: i32 = DEFAULT_WINDOW_X,
    window_y: i32 = DEFAULT_WINDOW_Y,
    grid_rows: i32 = DEFAULT_GRID_ROWS,
    grid_cols: i32 = DEFAULT_GRID_COLS,
    rendering: Rendering = .{},

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

        var buf: [2048]u8 = undefined;
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

        config.grid_rows = std.math.clamp(config.grid_rows, MIN_GRID_SIZE, MAX_GRID_SIZE);
        config.grid_cols = std.math.clamp(config.grid_cols, MIN_GRID_SIZE, MAX_GRID_SIZE);

        if (config.font_family) |ff| {
            if (ff.len > 0) {
                config.font_family = try allocator.dupe(u8, ff);
                config.font_family_owned = true;
            } else {
                config.font_family = null;
                config.font_family_owned = false;
            }
        }

        return config;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.font_family_owned) {
            if (self.font_family) |value| {
                allocator.free(value);
            }
        }
        self.font_family = null;
        self.font_family_owned = false;
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

test "Config - decode toml with all fields" {
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
        \\[rendering]
        \\vsync = false
        \\
    ;

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(content);
    defer result.deinit();

    const decoded = result.value;

    try std.testing.expectEqual(@as(i32, 16), decoded.font_size);
    try std.testing.expect(decoded.font_family != null);
    try std.testing.expectEqualStrings("VictorMonoNerdFont", decoded.font_family.?);
    try std.testing.expectEqual(@as(i32, 1920), decoded.window_width);
    try std.testing.expectEqual(@as(i32, 1080), decoded.window_height);
    try std.testing.expectEqual(@as(i32, 100), decoded.window_x);
    try std.testing.expectEqual(@as(i32, 100), decoded.window_y);
    try std.testing.expectEqual(@as(i32, 3), decoded.grid_rows);
    try std.testing.expectEqual(@as(i32, 4), decoded.grid_cols);
    try std.testing.expectEqual(false, decoded.rendering.vsync);
}

test "Config - decode toml with partial fields uses defaults" {
    const allocator = std.testing.allocator;

    const content =
        \\font_size = 18
        \\
    ;

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(content);
    defer result.deinit();

    const decoded = result.value;

    try std.testing.expectEqual(@as(i32, 18), decoded.font_size);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.font_family);
    try std.testing.expectEqual(DEFAULT_WINDOW_WIDTH, decoded.window_width);
    try std.testing.expectEqual(DEFAULT_WINDOW_HEIGHT, decoded.window_height);
    try std.testing.expectEqual(DEFAULT_WINDOW_X, decoded.window_x);
    try std.testing.expectEqual(DEFAULT_WINDOW_Y, decoded.window_y);
    try std.testing.expectEqual(DEFAULT_GRID_ROWS, decoded.grid_rows);
    try std.testing.expectEqual(DEFAULT_GRID_COLS, decoded.grid_cols);
    try std.testing.expectEqual(true, decoded.rendering.vsync);
}

test "Config - decode empty toml uses all defaults" {
    const allocator = std.testing.allocator;

    const content = "";

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseString(content);
    defer result.deinit();

    const decoded = result.value;

    try std.testing.expectEqual(DEFAULT_FONT_SIZE, decoded.font_size);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.font_family);
    try std.testing.expectEqual(DEFAULT_WINDOW_WIDTH, decoded.window_width);
    try std.testing.expectEqual(DEFAULT_WINDOW_HEIGHT, decoded.window_height);
    try std.testing.expectEqual(DEFAULT_WINDOW_X, decoded.window_x);
    try std.testing.expectEqual(DEFAULT_WINDOW_Y, decoded.window_y);
    try std.testing.expectEqual(DEFAULT_GRID_ROWS, decoded.grid_rows);
    try std.testing.expectEqual(DEFAULT_GRID_COLS, decoded.grid_cols);
    try std.testing.expectEqual(true, decoded.rendering.vsync);
}
