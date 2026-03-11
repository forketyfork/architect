const std = @import("std");
const runtime = @import("app/runtime.zig");
const logging = @import("logging.zig");

pub const std_options: std.Options = .{
    // Keep compile-time logging permissive; runtime filtering is handled by
    // logging.zig with the user-configured minimum level.
    .log_level = .debug,
    .logFn = logging.logFn,
};

pub fn main() !void {
    try runtime.run();
}
