const runtime = @import("app/runtime.zig");

pub fn main() !void {
    try runtime.run();
}
