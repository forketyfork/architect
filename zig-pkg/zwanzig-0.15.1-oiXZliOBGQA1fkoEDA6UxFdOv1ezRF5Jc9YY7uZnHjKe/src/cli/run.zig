const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const analyzer_mod = @import("../analyzer.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const file_discovery = @import("../file_discovery.zig");
const build_options = @import("build_options");
const config = @import("../config.zig");
const build_metadata = @import("../build_metadata.zig");
const args_mod = @import("args.zig");
const merge_mod = @import("config_merge.zig");
const registry = @import("registry.zig");

const Analyzer = analyzer_mod.Analyzer;
const AnalysisResult = analyzer_mod.AnalysisResult;
pub const CliArgs = args_mod.CliArgs;
const CliError = args_mod.CliError;
const BuildMetadata = build_metadata.BuildMetadata;
const MergedConfig = merge_mod.MergedConfig;
const TargetConfig = build_metadata.TargetConfig;
const log = std.log.scoped(.zwanzig);

const WorkerContext = struct {
    analyzer: *Analyzer,
    files: []const []const u8,
    results: []?AnalysisResult,
    errors: []?anyerror,
};

fn workerTask(file_index: usize, ctx: *WorkerContext) void {
    // Use libc's allocator for per-task scratch. The engine eagerly frees its
    // temporaries (~1M allocations per file on a 3500-line input), so an arena
    // ends up retaining all of that churn until file-end, which on
    // engine-heavy files inflates peak RSS by an order of magnitude. libc
    // malloc has thread-local caches, so per-task usage doesn't contend.
    const file_path = ctx.files[file_index];
    const result = ctx.analyzer.analyzeFileResultWithScratchAllocator(file_path, std.heap.c_allocator);
    if (result) |r| {
        ctx.results[file_index] = r;
        ctx.errors[file_index] = null;
    } else |err| {
        ctx.results[file_index] = null;
        ctx.errors[file_index] = err;
    }
}

fn workerTaskAdapter(file_index: usize, context: *anyopaque) void {
    const ctx: *WorkerContext = @ptrCast(@alignCast(context));
    workerTask(file_index, ctx);
}

fn analyzeFilesParallel(
    analyzer: *Analyzer,
    files: []const []const u8,
    thread_count: usize,
    allocator: std.mem.Allocator,
    io_context: *compat.Context,
) !void {
    if (files.len == 0) return;

    const results = try allocator.alloc(?AnalysisResult, files.len);
    defer allocator.free(results);
    @memset(results, null);

    const errors = try allocator.alloc(?anyerror, files.len);
    defer allocator.free(errors);
    @memset(errors, null);

    var ctx = WorkerContext{
        .analyzer = analyzer,
        .files = files,
        .results = results,
        .errors = errors,
    };

    var executor = try compat.Executor.init(io_context, allocator, thread_count);
    defer executor.deinit();

    for (0..files.len) |i| {
        try executor.spawn(workerTaskAdapter, i, @ptrCast(&ctx));
    }
    try executor.wait();

    var first_error: ?anyerror = null;
    for (0..files.len) |i| {
        if (errors[i]) |err| {
            if (first_error == null) {
                first_error = err;
            }
        } else if (results[i]) |*result| {
            try analyzer.mergeResult(result);
        }
    }

    // Sort diagnostics for deterministic output ordering
    std.mem.sort(Diagnostic, analyzer.diagnostics.items, {}, Diagnostic.lessThan);

    if (first_error) |err| {
        return err;
    }
}

fn printUsage(io_context: *compat.Context) !void {
    var stdout: compat.OutputWriter = undefined;
    stdout.init(io_context, false);
    defer stdout.deinit();
    const writer = stdout.writer();
    try writer.writeAll("Usage: zwanzig [options] [path...]\n");
    try writer.writeAll("\nA static analyzer for Zig code.\n");
    try writer.writeAll("\nOptions:\n");
    try writer.writeAll("  -h, --help        Show this help message and exit\n");
    try writer.writeAll("  --version         Show version and exit\n");
    try writer.writeAll("  --file <path>     Specify a file or directory to analyze (can be repeated)\n");
    try writer.writeAll("  --do <rule>       Only run the specified rule (can be repeated)\n");
    try writer.writeAll("  --skip <rule>     Skip the specified rule (can be repeated)\n");
    try writer.writeAll("  --target <triple> Specify target triple (e.g., x86_64-linux-gnu)\n");
    try writer.writeAll("  --config <path>   Path to config file (default: .zwanzig.json)\n");
    try writer.writeAll("  --format <format> Output format: 'text', 'json', or 'sarif' (default: text)\n");
    try writer.writeAll("  --max-steps <n>   Max worklist steps per engine run\n");
    try writer.writeAll("  --max-states-per-point <n> Max unique states per CFG point\n");
    try writer.writeAll("  --use-widening    Enable widening for convergence (default: on)\n");
    try writer.writeAll("  --cache           Enable incremental caching\n");
    try writer.writeAll("  --threads <n>     Number of threads for parallel analysis (default: CPU count)\n");
    try writer.writeAll("  --dump-cfg <dir>  Dump CFG DOT files to directory for visualization\n");
    try writer.writeAll("  --dump-exploded-graph <dir>  Dump exploded graph (all states) as DOT\n");
    try writer.writeAll("  --dump-annotated-cfg <dir>   Dump CFG with state annotations as DOT\n");
    try writer.writeAll("  --dump-path-trace <dir>      Dump path traces to violations as DOT\n");
    try writer.writeAll("\n  Note: --do and --skip are mutually exclusive and override config file.\n");
    try writer.writeAll("\nArguments:\n");
    try writer.writeAll("  [path...]         Files or directories to analyze (default: current directory)\n");
    try writer.writeAll("\nIgnored directories:\n");
    try writer.writeAll("  zig-cache/, zig-out/, .zigmod/, .gyro/\n");
    try stdout.flush();
}

fn printVersion(io_context: *compat.Context) !void {
    var buffer: [128]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &buffer,
        "zwanzig {s} (Zig frontend {s})\n",
        .{ build_options.version, builtin.zig_version_string },
    );
    var stdout: compat.OutputWriter = undefined;
    stdout.init(io_context, false);
    defer stdout.deinit();
    try stdout.writer().writeAll(message);
    try stdout.flush();
}

fn writeError(io_context: *compat.Context, message: []const u8) void {
    var stderr: compat.OutputWriter = undefined;
    stderr.init(io_context, true);
    defer stderr.deinit();
    // This is already an error-reporting path; preserving the original error
    // is more useful than replacing it with a failure to write stderr.
    // zwanzig-disable-next-line: empty-catch-engine
    stderr.writer().writeAll(message) catch {};
    // zwanzig-disable-next-line: empty-catch-engine
    stderr.flush() catch {};
}

pub fn parseCliArgs(io_context: *compat.Context, allocator: std.mem.Allocator, args: []const []const u8) CliArgs {
    // Check for --help or -h before parsing other arguments
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(io_context) catch |err| {
                std.debug.print("Failed to print usage: {s}\n", .{@errorName(err)});
            };
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--version")) {
            printVersion(io_context) catch |err| {
                std.debug.print("Failed to print version: {s}\n", .{@errorName(err)});
            };
            std.process.exit(0);
        }
    }

    return args_mod.parseArgs(allocator, args) catch |err| {
        // zwanzig-disable: empty-catch-engine
        // We are on an error-exit path; failing to write to stderr (e.g. closed
        // pipe) must not mask the original error or crash the process.
        switch (err) {
            CliError.MutuallyExclusiveFlags => {
                writeError(io_context, "Error: --do and --skip are mutually exclusive\n");
            },
            CliError.MissingFlagValue => {
                writeError(io_context, "Error: Flag requires a value\n");
            },
            CliError.OutOfMemory => {
                writeError(io_context, "Error: Out of memory\n");
            },
            CliError.InvalidTargetTriple => {
                writeError(io_context, "Error: Invalid target triple format\n");
            },
            CliError.InvalidOutputFormat => {
                writeError(io_context, "Error: Invalid output format (use 'text', 'json', or 'sarif')\n");
            },
            CliError.InvalidNumericValue => {
                writeError(io_context, "Error: Invalid numeric value for limit\n");
            },
        }
        // zwanzig-enable: empty-catch-engine
        std.process.exit(1);
    };
}

fn loadMergedConfig(io_context: *compat.Context, allocator: std.mem.Allocator, cli_args: CliArgs) MergedConfig {
    return merge_mod.mergeConfig(io_context, allocator, cli_args) catch |err| {
        // zwanzig-disable: empty-catch-engine
        switch (err) {
            config.ConfigError.InvalidJson => {
                writeError(io_context, "Error: Invalid JSON in config file\n");
            },
            config.ConfigError.InvalidConfigFormat => {
                writeError(io_context, "Error: Invalid config file format\n");
            },
            config.ConfigError.MutuallyExclusiveFields => {
                writeError(io_context, "Error: Config file has both enabled_rules and disabled_rules\n");
            },
            config.ConfigError.FileNotFound => {
                writeError(io_context, "Error: Config file not found\n");
            },
            config.ConfigError.OutOfMemory => {
                writeError(io_context, "Error: Out of memory\n");
            },
        }
        // zwanzig-enable: empty-catch-engine
        std.process.exit(1);
    };
}

fn discoverInputFiles(io_context: *compat.Context, allocator: std.mem.Allocator, cli_args: CliArgs) []const []const u8 {
    return file_discovery.discoverFiles(io_context, allocator, cli_args.paths) catch |err| {
        // zwanzig-disable: empty-catch-engine
        switch (err) {
            file_discovery.FileDiscoveryError.FileNotFound => {
                writeError(io_context, "Error: File or directory not found\n");
            },
            file_discovery.FileDiscoveryError.AccessDenied => {
                writeError(io_context, "Error: Access denied\n");
            },
            else => {
                writeError(io_context, "Error: Failed to discover files\n");
            },
        }
        // zwanzig-enable: empty-catch-engine
        std.process.exit(1);
    };
}

fn configureBuildMetadata(analyzer: *Analyzer, metadata: ?BuildMetadata) !void {
    if (metadata) |value| {
        try analyzer.setBuildMetadata(value);
    }
}

fn configureAnalyzer(analyzer: *Analyzer, cli_args: CliArgs, final_config: MergedConfig) !void {
    analyzer.setToolVersion(build_options.version);
    try registry.registerDefaults(analyzer);

    analyzer.setRuleFilter(final_config.rule_filter);
    if (final_config.max_worklist_steps) |steps| {
        analyzer.setMaxWorklistSteps(steps);
    }
    if (final_config.max_states_per_point) |max| {
        analyzer.setMaxStatesPerPoint(max);
    }
    if (final_config.use_widening) |use_w| {
        analyzer.setUseWidening(use_w);
    }
    const has_models = final_config.resource_models.len > 0 or final_config.escape_models.len > 0 or final_config.escape_max_depth != null;
    if (has_models) {
        analyzer.setConfig(.{
            .rule_filter = .none,
            .resource_models = final_config.resource_models,
            .escape_models = final_config.escape_models,
            .escape_max_depth = final_config.escape_max_depth,
        });
    }

    try configureBuildMetadata(analyzer, cli_args.build_metadata);

    if (cli_args.use_cache) {
        try analyzer.enableCache();
    }

    if (cli_args.dump_cfg_dir) |dir| {
        analyzer.setDumpCfgDir(dir);
    }
    if (cli_args.dump_exploded_graph_dir) |dir| {
        analyzer.setDumpExplodedGraphDir(dir);
    }
    if (cli_args.dump_annotated_cfg_dir) |dir| {
        analyzer.setDumpAnnotatedCfgDir(dir);
    }
    if (cli_args.dump_path_trace_dir) |dir| {
        analyzer.setDumpPathTraceDir(dir);
    }
}

pub fn runParsed(allocator: std.mem.Allocator, cli_args: CliArgs, io_context: *compat.Context) !void {
    const final_config = loadMergedConfig(io_context, allocator, cli_args);
    defer merge_mod.freeMergedConfig(allocator, cli_args, final_config);

    const files = discoverInputFiles(io_context, allocator, cli_args);
    defer file_discovery.freeDiscoveredFiles(allocator, files);
    log.info("discovered {d} file(s)", .{files.len});

    if (files.len == 0) {
        var stderr: compat.OutputWriter = undefined;
        stderr.init(io_context, true);
        defer stderr.deinit();
        try stderr.writer().writeAll("No .zig files found.\n");
        try stderr.flush();
        return;
    }

    var analyzer = Analyzer.initWithContext(allocator, io_context);
    defer analyzer.deinit();

    try configureAnalyzer(&analyzer, cli_args, final_config);

    log.info("analyzing with {d} rule(s) using {d} thread(s)", .{ analyzer.totalCheckerCount(), cli_args.thread_count });
    try analyzeFilesParallel(&analyzer, files, cli_args.thread_count, allocator, io_context);
    try analyzer.analyzeProjectUnusedDecls(files);
    log.info("analysis complete", .{});
    analyzer.logAnalysisStats();

    try analyzer.printResults(cli_args.output_format);

    if (analyzer.hasDiagnostics()) {
        std.process.exit(1);
    }
}

test "configureBuildMetadata borrows CLI metadata" {
    const allocator = std.testing.allocator;

    const target_config = try TargetConfig.fromTriple(allocator, "x86_64-linux-gnu");
    var metadata = BuildMetadata.init(target_config, null);
    defer metadata.deinit(allocator);

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try configureBuildMetadata(&analyzer, metadata);

    try std.testing.expectEqualStrings("gnu", metadata.target.abi.?);
    try std.testing.expectEqualStrings("gnu", analyzer.getBuildMetadata().?.target.abi.?);
}
