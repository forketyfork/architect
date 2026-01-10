const std = @import("std");
const fs = std.fs;
const json = std.json;
const tomlz = @import("tomlz");

pub const Config = struct {
    font_size: i32,
    font_family: ?[]const u8,
    font_family_owned: bool = false,
    window_width: i32,
    window_height: i32,
    window_x: i32,
    window_y: i32,

    pub fn load(allocator: std.mem.Allocator) LoadError!Config {
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        return loadTomlConfig(allocator, config_path) catch |err| switch (err) {
            error.ConfigNotFound => loadLegacyJson(allocator),
            else => return err,
        };
    }

    pub fn save(self: Config, allocator: std.mem.Allocator) SaveError!void {
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        const config_dir = fs.path.dirname(config_path) orelse return error.InvalidPath;
        fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        try tomlz.serialize(allocator, buffer.writer(), self);
        try buffer.append('\n');

        const file = try fs.createFileAbsolute(config_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(buffer.items);
    }

    fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "config.toml" });
    }

    fn getLegacyJsonPath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "config.json" });
    }

    fn loadTomlConfig(allocator: std.mem.Allocator, config_path: []const u8) LoadError!Config {
        const file = fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ConfigNotFound,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return tomlz.decode(Config, allocator, content) catch return error.InvalidConfig;
    }

    fn loadLegacyJson(allocator: std.mem.Allocator) LoadError!Config {
        const config_path = try getLegacyJsonPath(allocator);
        defer allocator.free(config_path);

        const file = fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ConfigNotFound,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = json.parseFromSlice(json.Value, allocator, content, .{}) catch return error.InvalidConfig;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidConfig;
        const obj = root.object;

        const font_size_val = obj.get("font_size") orelse return error.InvalidConfig;
        const font_family_val = obj.get("font_family");
        const window_width_val = obj.get("window_width") orelse return error.InvalidConfig;
        const window_height_val = obj.get("window_height") orelse return error.InvalidConfig;
        const window_x_val = obj.get("window_x") orelse return error.InvalidConfig;
        const window_y_val = obj.get("window_y") orelse return error.InvalidConfig;

        if (font_size_val != .integer or window_width_val != .integer or window_height_val != .integer or
            window_x_val != .integer or window_y_val != .integer)
        {
            return error.InvalidConfig;
        }

        var font_family: ?[]const u8 = null;
        var font_family_owned = false;
        if (font_family_val) |value| {
            if (value != .string) return error.InvalidConfig;
            if (value.string.len > 0) {
                font_family = try allocator.dupe(u8, value.string);
                font_family_owned = true;
            }
        }

        const legacy_config = Config{
            .font_size = @intCast(font_size_val.integer),
            .font_family = font_family,
            .font_family_owned = font_family_owned,
            .window_width = @intCast(window_width_val.integer),
            .window_height = @intCast(window_height_val.integer),
            .window_x = @intCast(window_x_val.integer),
            .window_y = @intCast(window_y_val.integer),
        };

        legacy_config.save(allocator) catch {};
        return legacy_config;
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
    OutOfMemory,
} || fs.File.OpenError || fs.File.WriteError || fs.Dir.MakeError || tomlz.serializer.SerializeError;

test "Config - decode toml" {
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

    var decoded = try tomlz.decode(Config, allocator, content);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 16), decoded.font_size);
    try std.testing.expect(decoded.font_family != null);
    try std.testing.expectEqualStrings("VictorMonoNerdFont", decoded.font_family.?);
    try std.testing.expectEqual(@as(i32, 1920), decoded.window_width);
    try std.testing.expectEqual(@as(i32, 1080), decoded.window_height);
    try std.testing.expectEqual(@as(i32, 100), decoded.window_x);
    try std.testing.expectEqual(@as(i32, 100), decoded.window_y);
}
