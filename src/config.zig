const std = @import("std");
const fs = std.fs;
const json = std.json;

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

        const file = fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ConfigNotFound,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
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

        return Config{
            .font_size = @intCast(font_size_val.integer),
            .font_family = font_family,
            .font_family_owned = font_family_owned,
            .window_width = @intCast(window_width_val.integer),
            .window_height = @intCast(window_height_val.integer),
            .window_x = @intCast(window_x_val.integer),
            .window_y = @intCast(window_y_val.integer),
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

        const font_family = self.font_family orelse DEFAULT_FONT_FAMILY;
        const content = try std.fmt.allocPrint(
            allocator,
            \\{{
            \\  "font_size": {d},
            \\  "font_family": "{s}",
            \\  "window_width": {d},
            \\  "window_height": {d},
            \\  "window_x": {d},
            \\  "window_y": {d}
            \\}}
            \\
        ,
            .{ self.font_size, font_family, self.window_width, self.window_height, self.window_x, self.window_y },
        );
        defer allocator.free(content);

        const file = try fs.createFileAbsolute(config_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
    }

    fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        return try fs.path.join(allocator, &[_][]const u8{ home, ".config", "architect", "config.json" });
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

pub const DEFAULT_FONT_FAMILY = "VictorMonoNerdFont";

pub const LoadError = error{
    ConfigNotFound,
    InvalidConfig,
    HomeNotFound,
    InvalidPath,
    OutOfMemory,
} || fs.File.OpenError || fs.File.ReadError || json.ParseError(json.Scanner);

pub const SaveError = error{
    HomeNotFound,
    InvalidPath,
    OutOfMemory,
} || fs.File.OpenError || fs.File.WriteError || fs.Dir.MakeError;

test "Config - save and load" {
    const allocator = std.testing.allocator;

    const test_config = Config{
        .font_size = 16,
        .font_family = DEFAULT_FONT_FAMILY,
        .window_width = 1920,
        .window_height = 1080,
        .window_x = 100,
        .window_y = 100,
    };

    const test_dir = try std.fs.cwd().makeOpenPath("test_config", .{});
    defer std.fs.cwd().deleteTree("test_config") catch {};

    const test_path = try fs.path.join(allocator, &[_][]const u8{ "test_config", "config.json" });
    defer allocator.free(test_path);

    const content = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "font_size": {d},
        \\  "font_family": "{s}",
        \\  "window_width": {d},
        \\  "window_height": {d},
        \\  "window_x": {d},
        \\  "window_y": {d}
        \\}}
        \\
    ,
        .{ test_config.font_size, test_config.font_family.?, test_config.window_width, test_config.window_height, test_config.window_x, test_config.window_y },
    );
    defer allocator.free(content);

    try test_dir.writeFile(.{ .sub_path = "config.json", .data = content });

    const file = try fs.cwd().openFile(test_path, .{});
    defer file.close();

    const read_content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(read_content);

    const parsed = try json.parseFromSlice(json.Value, allocator, read_content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root == .object);
    const obj = root.object;

    const font_size_val = obj.get("font_size").?;
    const font_family_val = obj.get("font_family").?;
    const window_width_val = obj.get("window_width").?;
    const window_height_val = obj.get("window_height").?;
    const window_x_val = obj.get("window_x").?;
    const window_y_val = obj.get("window_y").?;

    try std.testing.expectEqual(@as(i64, 16), font_size_val.integer);
    try std.testing.expectEqualStrings(DEFAULT_FONT_FAMILY, font_family_val.string);
    try std.testing.expectEqual(@as(i64, 1920), window_width_val.integer);
    try std.testing.expectEqual(@as(i64, 1080), window_height_val.integer);
    try std.testing.expectEqual(@as(i64, 100), window_x_val.integer);
    try std.testing.expectEqual(@as(i64, 100), window_y_val.integer);
}
