const std = @import("std");
const compat = @import("compat.zig");
const build_options = @import("build_options");
const cli_run = @import("cli/run.zig");
const args_mod = @import("cli/args.zig");

comptime {
    _ = @import("compat.zig");
}

pub const std_options = std.Options{
    .log_level = @enumFromInt(@intFromEnum(build_options.log_level)),
};

test {
    _ = @import("ir.zig");
    _ = @import("cfg.zig");
    _ = @import("checker.zig");
    _ = @import("zir_bridge.zig");
    _ = @import("engine.zig");
    _ = @import("checkers/empty_catch_engine.zig");
    _ = @import("checkers/swallowed_error.zig");
    _ = @import("checkers/unreachable_code_checker.zig");
    _ = @import("checkers/store_violations_engine.zig");
    _ = @import("checkers/optional_unwrap_engine.zig");
    _ = @import("build_metadata.zig");
    _ = @import("config.zig");
    _ = @import("cache.zig");
    _ = @import("cli/args.zig");
    _ = @import("cli/config_merge.zig");
    _ = @import("cli/registry.zig");
    _ = @import("cli/run.zig");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cli_args = cli_run.parseCliArgs(compat.defaultContext(), allocator, args);
    defer args_mod.freeCliArgs(allocator, cli_args);

    var io_context = try compat.Context.init(allocator, cli_args.thread_count);
    defer io_context.deinit();

    try cli_run.runParsed(allocator, cli_args, &io_context);
}
