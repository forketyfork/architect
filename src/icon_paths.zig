const std = @import("std");

pub const IconPaths = struct {
    gemini: [:0]const u8,
    openai: [:0]const u8,
    claude: [:0]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !IconPaths {
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        const exe_dir = std.fs.path.dirname(exe_path) orelse return error.NoExeDir;

        var paths: IconPaths = undefined;
        paths.allocator = allocator;

        const candidates = [_][]const u8{
            "../share/architect/icons",
            "../../share/architect/icons",
            "../../assets/icons",
            "assets/icons",
        };

        var icon_dir_path: ?[]const u8 = null;
        for (candidates) |candidate| {
            const test_path = try std.fs.path.join(allocator, &.{ exe_dir, candidate });
            defer allocator.free(test_path);

            const real_path = std.fs.realpathAlloc(allocator, test_path) catch continue;
            defer allocator.free(real_path);

            std.fs.accessAbsolute(real_path, .{}) catch continue;
            icon_dir_path = try allocator.dupe(u8, real_path);
            break;
        }

        if (icon_dir_path) |dir| {
            defer allocator.free(dir);

            paths.gemini = try std.fs.path.joinZ(allocator, &.{ dir, "gemini.bmp" });
            paths.openai = try std.fs.path.joinZ(allocator, &.{ dir, "openai.bmp" });
            paths.claude = try std.fs.path.joinZ(allocator, &.{ dir, "claude.bmp" });
        } else {
            return error.IconsNotFound;
        }

        return paths;
    }

    pub fn deinit(self: *IconPaths) void {
        self.allocator.free(self.gemini);
        self.allocator.free(self.openai);
        self.allocator.free(self.claude);
    }
};
