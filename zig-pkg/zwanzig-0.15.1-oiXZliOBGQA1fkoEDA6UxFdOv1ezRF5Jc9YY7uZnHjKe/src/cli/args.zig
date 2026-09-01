const std = @import("std");
const analyzer_mod = @import("../analyzer.zig");
const RuleFilter = @import("../rule_filter.zig").RuleFilter;
const build_metadata = @import("../build_metadata.zig");

const OutputFormat = analyzer_mod.Analyzer.OutputFormat;
const BuildMetadata = build_metadata.BuildMetadata;
const TargetConfig = build_metadata.TargetConfig;

pub const CliArgs = struct {
    paths: []const []const u8,
    rule_filter: RuleFilter,
    build_metadata: ?BuildMetadata,
    config_path: ?[]const u8,
    output_format: OutputFormat,
    use_cache: bool,
    max_worklist_steps: ?usize,
    max_states_per_point: ?u32,
    use_widening: ?bool,
    dump_cfg_dir: ?[]const u8,
    dump_exploded_graph_dir: ?[]const u8,
    dump_annotated_cfg_dir: ?[]const u8,
    dump_path_trace_dir: ?[]const u8,
    thread_count: usize,
};

pub const CliError = error{
    MutuallyExclusiveFlags,
    MissingFlagValue,
    OutOfMemory,
    InvalidTargetTriple,
    InvalidOutputFormat,
    InvalidNumericValue,
};

fn outputFormatFromString(s: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "json")) return .json;
    if (std.mem.eql(u8, s, "sarif")) return .sarif;
    return null;
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) CliError!CliArgs {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(allocator);

    var do_rules: std.ArrayList([]const u8) = .empty;
    errdefer do_rules.deinit(allocator);

    var skip_rules: std.ArrayList([]const u8) = .empty;
    errdefer skip_rules.deinit(allocator);

    var target_triple: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var output_format: OutputFormat = .text;
    var use_cache: bool = false;
    var max_worklist_steps: ?usize = null;
    var max_states_per_point: ?u32 = null;
    var use_widening: ?bool = null;
    var dump_cfg_dir: ?[]const u8 = null;
    var dump_exploded_graph_dir: ?[]const u8 = null;
    var dump_annotated_cfg_dir: ?[]const u8 = null;
    var dump_path_trace_dir: ?[]const u8 = null;
    // zwanzig-disable-next-line: swallowed-error
    var thread_count: usize = std.Thread.getCpuCount() catch 1;
    var build_meta: ?BuildMetadata = null;
    errdefer {
        if (build_meta) |*meta| {
            meta.deinit(allocator);
        }
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--do")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            try do_rules.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--skip")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            try skip_rules.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--file")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            try paths.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            target_triple = args[i];
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            output_format = outputFormatFromString(args[i]) orelse return CliError.InvalidOutputFormat;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            use_cache = true;
        } else if (std.mem.eql(u8, arg, "--max-steps")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            const parsed = std.fmt.parseInt(usize, args[i], 10) catch return CliError.InvalidNumericValue;
            if (parsed == 0) return CliError.InvalidNumericValue;
            max_worklist_steps = parsed;
        } else if (std.mem.eql(u8, arg, "--max-states-per-point")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            const parsed = std.fmt.parseInt(u32, args[i], 10) catch return CliError.InvalidNumericValue;
            if (parsed == 0) return CliError.InvalidNumericValue;
            max_states_per_point = parsed;
        } else if (std.mem.eql(u8, arg, "--use-widening")) {
            use_widening = true;
        } else if (std.mem.eql(u8, arg, "--dump-cfg")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_cfg_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-exploded-graph")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_exploded_graph_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-annotated-cfg")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_annotated_cfg_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--dump-path-trace")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            dump_path_trace_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--threads")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                return CliError.MissingFlagValue;
            }
            i += 1;
            const parsed = std.fmt.parseInt(usize, args[i], 10) catch return CliError.InvalidNumericValue;
            if (parsed == 0) return CliError.InvalidNumericValue;
            thread_count = parsed;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            continue;
        } else {
            try paths.append(allocator, arg);
        }
    }

    if (do_rules.items.len > 0 and skip_rules.items.len > 0) {
        return CliError.MutuallyExclusiveFlags;
    }

    const rule_filter: RuleFilter = if (do_rules.items.len > 0)
        .{ .allowlist = try do_rules.toOwnedSlice(allocator) }
    else if (skip_rules.items.len > 0)
        .{ .blocklist = try skip_rules.toOwnedSlice(allocator) }
    else
        .none;

    if (target_triple) |triple| {
        const target_config = TargetConfig.fromTriple(allocator, triple) catch |err| {
            return if (err == error.InvalidTargetTriple) CliError.InvalidTargetTriple else CliError.OutOfMemory;
        };
        build_meta = BuildMetadata.init(target_config, null);
    } else {
        build_meta = BuildMetadata.fromNative();
    }

    return CliArgs{
        .paths = try paths.toOwnedSlice(allocator),
        .rule_filter = rule_filter,
        .build_metadata = build_meta,
        .config_path = config_path,
        .output_format = output_format,
        .use_cache = use_cache,
        .max_worklist_steps = max_worklist_steps,
        .max_states_per_point = max_states_per_point,
        .use_widening = use_widening,
        .dump_cfg_dir = dump_cfg_dir,
        .dump_exploded_graph_dir = dump_exploded_graph_dir,
        .dump_annotated_cfg_dir = dump_annotated_cfg_dir,
        .dump_path_trace_dir = dump_path_trace_dir,
        .thread_count = thread_count,
    };
}

pub fn freeCliArgs(allocator: std.mem.Allocator, cli_args: CliArgs) void {
    allocator.free(cli_args.paths);
    switch (cli_args.rule_filter) {
        .allowlist => |list| allocator.free(list),
        .blocklist => |list| allocator.free(list),
        .none => {},
    }
    if (cli_args.build_metadata) |*meta_const| {
        var meta = meta_const.*;
        meta.deinit(allocator);
    }
}

test "parseArgs: paths only" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file1.zig", "file2.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("file1.zig", result.paths[0]);
    try std.testing.expectEqualStrings("file2.zig", result.paths[1]);
    try std.testing.expectEqual(RuleFilter.none, result.rule_filter);
}

test "parseArgs: --do flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "empty-catch", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);

    switch (result.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: multiple --do flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "empty-catch", "--do", "unused-var", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    switch (result.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
            try std.testing.expectEqualStrings("unused-var", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: --skip flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip", "empty-catch", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);

    switch (result.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: multiple --skip flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip", "empty-catch", "--skip", "unused-var", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    switch (result.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 2), list.len);
            try std.testing.expectEqualStrings("empty-catch", list[0]);
            try std.testing.expectEqualStrings("unused-var", list[1]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "parseArgs: --do and --skip mutually exclusive" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "rule1", "--skip", "rule2", "file.zig" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MutuallyExclusiveFlags, result);
}

test "parseArgs: --do without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --skip without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --do with flag as value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--do", "--skip", "rule" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --skip with flag as value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--skip", "--do", "rule" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: paths before and after flags" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "file1.zig", "--do", "empty-catch", "file2.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("file1.zig", result.paths[0]);
    try std.testing.expectEqualStrings("file2.zig", result.paths[1]);
}

test "parseArgs: --file flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--file", "src", "--file", "tests" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("src", result.paths[0]);
    try std.testing.expectEqualStrings("tests", result.paths[1]);
}

test "parseArgs: --file without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--file" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: --file mixed with positional" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--file", "src", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.paths.len);
    try std.testing.expectEqualStrings("src", result.paths[0]);
    try std.testing.expectEqualStrings("file.zig", result.paths[1]);
}

test "parseArgs: empty paths" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{"zwanzig"};
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 0), result.paths.len);
}

test "parseArgs: --target flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target", "x86_64-linux-gnu", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);

    try std.testing.expect(result.build_metadata != null);
    const metadata = result.build_metadata.?;
    try std.testing.expectEqual(build_metadata.TargetArch.x86_64, metadata.target.arch);
    try std.testing.expectEqual(build_metadata.TargetOS.linux, metadata.target.os);
    try std.testing.expect(metadata.target.abi != null);
    try std.testing.expectEqualStrings("gnu", metadata.target.abi.?);
}

test "parseArgs: --target without ABI" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target", "aarch64-macos", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expect(result.build_metadata != null);
    const metadata = result.build_metadata.?;
    try std.testing.expectEqual(build_metadata.TargetArch.aarch64, metadata.target.arch);
    try std.testing.expectEqual(build_metadata.TargetOS.macos, metadata.target.os);
    try std.testing.expectEqual(@as(?[]const u8, null), metadata.target.abi);
}

test "parseArgs: --target without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}

test "parseArgs: invalid target triple" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--target", "invalid" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.InvalidTargetTriple, result);
}

test "parseArgs: --config flag" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--config", "custom.json", "file.zig" };
    const result = try parseArgs(allocator, &args);
    defer freeCliArgs(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.paths.len);
    try std.testing.expectEqualStrings("file.zig", result.paths[0]);
    try std.testing.expect(result.config_path != null);
    try std.testing.expectEqualStrings("custom.json", result.config_path.?);
}

test "parseArgs: --config without value" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "zwanzig", "--config" };
    const result = parseArgs(allocator, &args);

    try std.testing.expectError(CliError.MissingFlagValue, result);
}
