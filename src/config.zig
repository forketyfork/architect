const std = @import("std");
const fs = std.fs;
const json = std.json;

pub const MIN_GRID_SIZE: i32 = 1;
pub const MAX_GRID_SIZE: i32 = 12;
pub const DEFAULT_GRID_ROWS: i32 = 3;
pub const DEFAULT_GRID_COLS: i32 = 3;

pub const Config = struct {
    font_size: i32,
    window_width: i32,
    window_height: i32,
    window_x: i32,
    window_y: i32,
    grid_rows: i32,
    grid_cols: i32,

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
        const window_width_val = obj.get("window_width") orelse return error.InvalidConfig;
        const window_height_val = obj.get("window_height") orelse return error.InvalidConfig;
        const window_x_val = obj.get("window_x") orelse return error.InvalidConfig;
        const window_y_val = obj.get("window_y") orelse return error.InvalidConfig;

        if (font_size_val != .integer or window_width_val != .integer or window_height_val != .integer or
            window_x_val != .integer or window_y_val != .integer)
        {
            return error.InvalidConfig;
        }

        // Grid dimensions are optional for backward compatibility - use defaults if not present
        const grid_rows_val = obj.get("grid_rows");
        const grid_cols_val = obj.get("grid_cols");

        const grid_rows_raw: i32 = if (grid_rows_val) |v| blk: {
            if (v != .integer) break :blk DEFAULT_GRID_ROWS;
            break :blk @intCast(v.integer);
        } else DEFAULT_GRID_ROWS;

        const grid_cols_raw: i32 = if (grid_cols_val) |v| blk: {
            if (v != .integer) break :blk DEFAULT_GRID_COLS;
            break :blk @intCast(v.integer);
        } else DEFAULT_GRID_COLS;

        // Clamp to valid range
        const grid_rows = std.math.clamp(grid_rows_raw, MIN_GRID_SIZE, MAX_GRID_SIZE);
        const grid_cols = std.math.clamp(grid_cols_raw, MIN_GRID_SIZE, MAX_GRID_SIZE);

        return Config{
            .font_size = @intCast(font_size_val.integer),
            .window_width = @intCast(window_width_val.integer),
            .window_height = @intCast(window_height_val.integer),
            .window_x = @intCast(window_x_val.integer),
            .window_y = @intCast(window_y_val.integer),
            .grid_rows = grid_rows,
            .grid_cols = grid_cols,
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

        const content = try std.fmt.allocPrint(
            allocator,
            \\{{
            \\  "font_size": {d},
            \\  "window_width": {d},
            \\  "window_height": {d},
            \\  "window_x": {d},
            \\  "window_y": {d},
            \\  "grid_rows": {d},
            \\  "grid_cols": {d}
            \\}}
            \\
        ,
            .{ self.font_size, self.window_width, self.window_height, self.window_x, self.window_y, self.grid_rows, self.grid_cols },
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
};

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
        .window_width = 1920,
        .window_height = 1080,
        .window_x = 100,
        .window_y = 100,
        .grid_rows = 3,
        .grid_cols = 4,
    };

    const test_dir = try std.fs.cwd().makeOpenPath("test_config", .{});
    defer std.fs.cwd().deleteTree("test_config") catch {};

    const test_path = try fs.path.join(allocator, &[_][]const u8{ "test_config", "config.json" });
    defer allocator.free(test_path);

    const content = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "font_size": {d},
        \\  "window_width": {d},
        \\  "window_height": {d},
        \\  "window_x": {d},
        \\  "window_y": {d},
        \\  "grid_rows": {d},
        \\  "grid_cols": {d}
        \\}}
        \\
    ,
        .{ test_config.font_size, test_config.window_width, test_config.window_height, test_config.window_x, test_config.window_y, test_config.grid_rows, test_config.grid_cols },
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
    const window_width_val = obj.get("window_width").?;
    const window_height_val = obj.get("window_height").?;
    const window_x_val = obj.get("window_x").?;
    const window_y_val = obj.get("window_y").?;
    const grid_rows_val = obj.get("grid_rows").?;
    const grid_cols_val = obj.get("grid_cols").?;

    try std.testing.expectEqual(@as(i64, 16), font_size_val.integer);
    try std.testing.expectEqual(@as(i64, 1920), window_width_val.integer);
    try std.testing.expectEqual(@as(i64, 1080), window_height_val.integer);
    try std.testing.expectEqual(@as(i64, 100), window_x_val.integer);
    try std.testing.expectEqual(@as(i64, 100), window_y_val.integer);
    try std.testing.expectEqual(@as(i64, 3), grid_rows_val.integer);
    try std.testing.expectEqual(@as(i64, 4), grid_cols_val.integer);
}
