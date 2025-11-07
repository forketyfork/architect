const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub fn main() !void {
    std.debug.print("Architect - Terminal Wall\n", .{});
    std.debug.print("ghostty-vt module imported successfully\n", .{});
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
