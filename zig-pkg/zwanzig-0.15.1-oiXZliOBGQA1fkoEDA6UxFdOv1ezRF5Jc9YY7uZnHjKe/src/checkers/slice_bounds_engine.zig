const std = @import("std");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;
const ids = @import("../ids.zig");
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;
const scan = @import("slice_bounds/scan.zig");

pub const SliceBoundsEngineChecker = struct {
    pub const checker: Checker = .{
        .name = "slice-bounds-engine",
        .default_severity = .err,
        .checkAstFn = checkAst,
    };

    fn checkAst(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        var reported: std.AutoHashMap(u32, void) = std.AutoHashMap(u32, void).init(allocator);
        defer reported.deinit();

        for (0..tags.len) |i| {
            if (tags[i] == .fn_decl or tags[i] == .test_decl) {
                try analyzeFunction(src, allocator, ids.astId(@intCast(i)), diagnostics, context, &reported);
            }
        }
    }

    fn analyzeFunction(
        src: *Source,
        allocator: std.mem.Allocator,
        fn_node: ids.AstNodeId,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
        reported: *std.AutoHashMap(u32, void),
    ) CheckerError!void {
        var cfg_handle = (context.getOrBuildCfg(allocator, src, fn_node) catch return) orelse return;
        defer cfg_handle.deinit();

        var engine = AnalysisEngine.initWithSource(allocator, cfg_handle.cfg, src);
        defer engine.deinit();
        engine.setCheckerName("slice-bounds-engine");
        if (context.type_context) |type_ctx| {
            engine.setTypeContext(type_ctx);
        }
        if (context.cached_artifacts) |artifacts| {
            engine.setCachedArtifacts(artifacts);
        }
        if (context.build_metadata) |metadata| {
            engine.setBuildMetadata(metadata);
        }
        if (context.config) |config| {
            engine.setConfig(config);
        }
        if (context.analysis_limits.max_worklist_steps) |steps| {
            engine.setMaxWorklistSteps(steps);
        }
        if (context.analysis_limits.max_states_per_point) |max| {
            engine.setMaxStatesPerPoint(max);
        }
        if (context.analysis_limits.use_widening) |use_w| {
            engine.setUseWidening(use_w);
        }

        var run_ok = true;
        engine.run() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AnalysisLimitExceeded => run_ok = false,
        };
        if (context.analysis_stats) |stats| {
            stats.recordRun();
            stats.recordWidening(engine.getGraph().getWidenedNodeCount(), engine.getGraph().getWideningConvergedCount());
        }

        if (context.dump_exploded_graph_dir) |dir| {
            engine_mod.dot.writeExplodedGraphToFile(engine.getGraph(), context.io_context, dir, src.getFilePath(), cfg_handle.cfg.fn_name, allocator);
        }
        if (context.dump_annotated_cfg_dir) |dir| {
            engine_mod.dot.writeAnnotatedCfgToFile(engine.getGraph(), context.io_context, dir, src.getFilePath(), cfg_handle.cfg.fn_name, allocator);
        }
        if (context.dump_path_trace_dir) |dir| {
            engine_mod.dot.writePathTracesToFile(engine.getGraph(), context.io_context, dir, src.getFilePath(), cfg_handle.cfg.fn_name, allocator);
        }

        if (!run_ok) return;

        const tree = src.ast() catch return;
        try scan.scanForBoundsViolations(src, allocator, diagnostics, tree, &engine, cfg_handle.cfg, fn_node, reported);
    }
};

test "SliceBoundsEngineChecker initialization" {
    const testing = std.testing;
    try testing.expectEqualStrings("slice-bounds-engine", SliceBoundsEngineChecker.checker.name);
    try testing.expectEqual(checker_mod.Severity.err, SliceBoundsEngineChecker.checker.default_severity);
}
