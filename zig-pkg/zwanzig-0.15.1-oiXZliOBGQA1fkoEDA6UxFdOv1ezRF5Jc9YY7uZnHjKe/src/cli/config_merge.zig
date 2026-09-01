const std = @import("std");
const compat = @import("../compat.zig");
const args_mod = @import("args.zig");
const config = @import("../config.zig");
const RuleFilter = @import("../rule_filter.zig").RuleFilter;

const CliArgs = args_mod.CliArgs;

pub const MergedConfig = struct {
    rule_filter: RuleFilter,
    max_worklist_steps: ?usize,
    max_states_per_point: ?u32,
    use_widening: ?bool,
    resource_models: []const config.ResourceModel = &.{},
    escape_models: []const config.EscapeModel = &.{},
    escape_max_depth: ?u32 = null,
};

fn defaultRuleFilter(allocator: std.mem.Allocator) !RuleFilter {
    var rule_names = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(rule_names);
    rule_names[0] = try allocator.dupe(u8, "sentinel-alloc");
    return .{ .blocklist = rule_names };
}

pub fn mergeConfig(io_context: *compat.Context, allocator: std.mem.Allocator, cli_args: CliArgs) !MergedConfig {
    const config_path = cli_args.config_path orelse ".zwanzig.json";

    var loaded_config = config.loadConfig(io_context, allocator, config_path) catch |err| {
        if (err == config.ConfigError.FileNotFound and cli_args.config_path == null) {
            const rule_filter = switch (cli_args.rule_filter) {
                .none => try defaultRuleFilter(allocator),
                else => cli_args.rule_filter,
            };
            return .{
                .rule_filter = rule_filter,
                .max_worklist_steps = cli_args.max_worklist_steps,
                .max_states_per_point = cli_args.max_states_per_point,
                .use_widening = cli_args.use_widening orelse true,
                .escape_max_depth = null,
            };
        }
        return err;
    };
    const max_worklist_steps = cli_args.max_worklist_steps orelse loaded_config.max_worklist_steps;
    const max_states_per_point = cli_args.max_states_per_point orelse loaded_config.max_states_per_point;
    const use_widening = cli_args.use_widening orelse loaded_config.use_widening orelse true;
    const resource_models = loaded_config.resource_models;
    const escape_models = loaded_config.escape_models;
    const escape_max_depth = loaded_config.escape_max_depth;

    switch (cli_args.rule_filter) {
        .none => {
            return .{
                .rule_filter = loaded_config.rule_filter,
                .max_worklist_steps = max_worklist_steps,
                .max_states_per_point = max_states_per_point,
                .use_widening = use_widening,
                .resource_models = resource_models,
                .escape_models = escape_models,
                .escape_max_depth = escape_max_depth,
            };
        },
        .allowlist => {
            // Free only the rule_filter part, keep resource_models
            loaded_config.resource_models = &.{}; // Prevent deinit from freeing
            loaded_config.escape_models = &.{}; // Prevent deinit from freeing
            loaded_config.deinit(allocator);
            return .{
                .rule_filter = cli_args.rule_filter,
                .max_worklist_steps = max_worklist_steps,
                .max_states_per_point = max_states_per_point,
                .use_widening = use_widening,
                .resource_models = resource_models,
                .escape_models = escape_models,
                .escape_max_depth = escape_max_depth,
            };
        },
        .blocklist => {
            // Free only the rule_filter part, keep resource_models
            loaded_config.resource_models = &.{}; // Prevent deinit from freeing
            loaded_config.escape_models = &.{}; // Prevent deinit from freeing
            loaded_config.deinit(allocator);
            return .{
                .rule_filter = cli_args.rule_filter,
                .max_worklist_steps = max_worklist_steps,
                .max_states_per_point = max_states_per_point,
                .use_widening = use_widening,
                .resource_models = resource_models,
                .escape_models = escape_models,
                .escape_max_depth = escape_max_depth,
            };
        },
    }
}

pub fn freeMergedConfig(allocator: std.mem.Allocator, cli_args: CliArgs, merged: MergedConfig) void {
    switch (merged.rule_filter) {
        .allowlist => |list| {
            const should_free = switch (cli_args.rule_filter) {
                .allowlist => |cli_list| list.ptr != cli_list.ptr,
                else => true,
            };
            if (should_free) {
                for (list) |rule_name| {
                    allocator.free(rule_name);
                }
                allocator.free(list);
            }
        },
        .blocklist => |list| {
            const should_free = switch (cli_args.rule_filter) {
                .blocklist => |cli_list| list.ptr != cli_list.ptr,
                else => true,
            };
            if (should_free) {
                for (list) |rule_name| {
                    allocator.free(rule_name);
                }
                allocator.free(list);
            }
        },
        .none => {},
    }

    for (merged.resource_models) |model| {
        if (model.method_name) |name| allocator.free(name);
        if (model.receiver_type) |ty| allocator.free(ty);
        if (model.return_type) |ty| allocator.free(ty);
        if (model.fqn) |name| allocator.free(name);
    }
    if (merged.resource_models.len > 0) {
        allocator.free(merged.resource_models);
    }

    for (merged.escape_models) |model| {
        if (model.fqn) |name| allocator.free(name);
        if (model.method_name) |name| allocator.free(name);
        if (model.receiver_type) |ty| allocator.free(ty);
        if (model.param_indices.len > 0) {
            allocator.free(model.param_indices);
        }
    }
    if (merged.escape_models.len > 0) {
        allocator.free(merged.escape_models);
    }
}

test "mergeConfig: CLI overrides config allowlist" {
    const allocator = std.testing.allocator;
    const io_context = compat.defaultContext();

    var tmp_dir = compat.TestDir.init();
    defer tmp_dir.cleanup();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}", .{tmp_dir.path()});

    var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/.zwanzig.json", .{tmp_path});

    const config_content =
        \\{
        \\  "enabled_rules": ["empty-catch"]
        \\}
    ;
    try tmp_dir.writeFile(".zwanzig.json", config_content);

    const cli_allowlist = [_][]const u8{"dupe-import"};
    const cli_args = CliArgs{
        .paths = &.{},
        .rule_filter = .{ .allowlist = &cli_allowlist },
        .build_metadata = null,
        .config_path = config_path,
        .output_format = .text,
        .use_cache = false,
        .max_worklist_steps = null,
        .max_states_per_point = null,
        .use_widening = null,
        .dump_cfg_dir = null,
        .dump_exploded_graph_dir = null,
        .dump_annotated_cfg_dir = null,
        .dump_path_trace_dir = null,
        .thread_count = 1,
    };

    const result = try mergeConfig(io_context, allocator, cli_args);
    defer freeMergedConfig(allocator, cli_args, result);

    switch (result.rule_filter) {
        .allowlist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("dupe-import", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}

test "mergeConfig: uses config when no CLI filter" {
    const allocator = std.testing.allocator;
    const io_context = compat.defaultContext();

    var tmp_dir = compat.TestDir.init();
    defer tmp_dir.cleanup();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}", .{tmp_dir.path()});

    var config_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/.zwanzig.json", .{tmp_path});

    const config_content =
        \\{
        \\  "disabled_rules": ["todo"]
        \\}
    ;
    try tmp_dir.writeFile(".zwanzig.json", config_content);

    const cli_args = CliArgs{
        .paths = &.{},
        .rule_filter = .none,
        .build_metadata = null,
        .config_path = config_path,
        .output_format = .text,
        .use_cache = false,
        .max_worklist_steps = null,
        .max_states_per_point = null,
        .use_widening = null,
        .dump_cfg_dir = null,
        .dump_exploded_graph_dir = null,
        .dump_annotated_cfg_dir = null,
        .dump_path_trace_dir = null,
        .thread_count = 1,
    };

    const result = try mergeConfig(io_context, allocator, cli_args);
    defer freeMergedConfig(allocator, cli_args, result);

    switch (result.rule_filter) {
        .blocklist => |list| {
            try std.testing.expectEqual(@as(usize, 1), list.len);
            try std.testing.expectEqualStrings("todo", list[0]);
        },
        else => return error.UnexpectedFilterType,
    }
}
