const std = @import("std");
const log = std.log.scoped(.empty_catch_engine);
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../source.zig").Source;
const ids = @import("../ids.zig");
const cfg_mod = @import("../cfg.zig");
const Cfg = cfg_mod.Cfg;
const CfgNodeId = ids.CfgNodeId;
const AstNodeId = ids.AstNodeId;
const engine_mod = @import("../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;

/// Engine-based checker that detects empty catch blocks using CFG and ProgramState.
/// This checker uses control-flow analysis to identify catch expressions where the
/// error handler body is empty (no statements).
///
/// Unlike the AST-based empty_catch rule, this checker:
/// - Uses CFG structure to identify catch nodes and their handlers
/// - Leverages the analysis engine's error state tracking
/// - Can be extended to support more sophisticated error-handling patterns
pub const EmptyCatchEngineChecker = struct {
    pub const checker: Checker = .{
        .name = "empty-catch-engine",
        .default_severity = .warning,
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

        // Find all function declarations and analyze each one
        for (0..tags.len) |i| {
            const tag = tags[i];
            if (tag == .fn_decl) {
                try analyzeFunction(src, allocator, ids.astId(@intCast(i)), diagnostics, context);
            }
        }

        // Also check for empty catch blocks at file scope (top-level declarations)
        try checkTopLevelCatches(src, allocator, diagnostics);
    }

    fn checkTopLevelCatches(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);

        // Build a list of function body token ranges (start, end)
        const Range = struct { start: u32, end: u32 };
        var fn_body_ranges: std.ArrayList(Range) = .empty;
        defer fn_body_ranges.deinit(allocator);

        for (tags, 0..) |tag, i| {
            if (tag == .fn_decl) {
                const fn_data = datas[i];
                const body_node: u32 = @intFromEnum(fn_data.node_and_node[1]);
                if (body_node != 0) {
                    // Get token range of the function body
                    const body_start = main_tokens[body_node];
                    const body_end = tree.lastToken(@enumFromInt(body_node));
                    fn_body_ranges.append(allocator, .{ .start = body_start, .end = body_end }) catch return;
                }
            }
        }

        // Find catch nodes that are not inside any function body (by token position)
        for (tags, 0..) |tag, node_idx| {
            if (tag == .@"catch") {
                const catch_token = main_tokens[node_idx];

                // Check if this catch token is inside any function body
                var inside_fn = false;
                for (fn_body_ranges.items) |range| {
                    if (catch_token >= range.start and catch_token <= range.end) {
                        inside_fn = true;
                        break;
                    }
                }

                if (!inside_fn) {
                    // Check if the catch has an empty body
                    if (hasEmptyCatchBody(token_tags, catch_token)) {
                        const catch_start = token_starts[catch_token];
                        const range = src.byteRangeToSourceRange(catch_start, catch_start + 5) catch |err| {
                            log.warn("failed to get source range: {}", .{err});
                            continue;
                        };

                        const diag = Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "empty-catch-engine",
                            .warning,
                            "Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.",
                            range,
                        ) catch return;

                        diagnostics.append(allocator, diag) catch return;
                    }
                }
            }
        }
    }

    fn hasEmptyCatchBody(token_tags: []const std.zig.Token.Tag, catch_token: u32) bool {
        // Scan forward from catch token to find the block
        var token_idx = catch_token + 1;
        const num_tokens = token_tags.len;

        // Skip whitespace, comments, and potential |err| capture
        while (token_idx < num_tokens) {
            const tok_tag = token_tags[token_idx];

            if (tok_tag == .l_brace) {
                // Found the opening brace of the catch block
                // Check if the next token is the closing brace
                const next_token_idx = token_idx + 1;
                if (next_token_idx < num_tokens and token_tags[next_token_idx] == .r_brace) {
                    return true;
                }
                return false;
            } else if (tok_tag == .pipe) {
                // Skip past the |err| capture: | identifier |
                token_idx += 1;
                while (token_idx < num_tokens and token_tags[token_idx] != .pipe) {
                    token_idx += 1;
                }
            } else if (tok_tag == .semicolon or tok_tag == .r_paren or tok_tag == .r_brace) {
                // Hit a boundary without finding a block - not an empty block pattern
                return false;
            }
            token_idx += 1;
        }
        return false;
    }

    fn analyzeFunction(
        src: *Source,
        allocator: std.mem.Allocator,
        fn_node: AstNodeId,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        var cfg_handle = (context.getOrBuildCfg(allocator, src, fn_node) catch return) orelse return;
        defer cfg_handle.deinit();

        // Run the analysis engine with a worklist limit to avoid pathological cases
        var engine = AnalysisEngine.initWithSource(allocator, cfg_handle.cfg, src);
        defer engine.deinit();
        engine.setCheckerName("empty-catch-engine");
        if (context.cached_artifacts) |artifacts| {
            engine.setCachedArtifacts(artifacts);
        }
        if (context.build_metadata) |metadata| {
            engine.setBuildMetadata(metadata);
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
        engine.run() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AnalysisLimitExceeded => {},
        };
        if (context.analysis_stats) |stats| {
            stats.recordRun();
            stats.recordWidening(engine.getGraph().getWidenedNodeCount(), engine.getGraph().getWideningConvergedCount());
        }

        // Dump visualizations if requested
        if (context.dump_exploded_graph_dir) |dir| {
            engine_mod.dot.writeExplodedGraphToFile(engine.getGraph(), context.io_context, dir, src.getFilePath(), cfg_handle.cfg.fn_name, allocator);
        }
        if (context.dump_annotated_cfg_dir) |dir| {
            engine_mod.dot.writeAnnotatedCfgToFile(engine.getGraph(), context.io_context, dir, src.getFilePath(), cfg_handle.cfg.fn_name, allocator);
        }
        if (context.dump_path_trace_dir) |dir| {
            engine_mod.dot.writePathTracesToFile(engine.getGraph(), context.io_context, dir, src.getFilePath(), cfg_handle.cfg.fn_name, allocator);
        }

        // Examine CFG nodes for catch_expr with empty handlers
        for (cfg_handle.cfg.nodes.items) |cfg_node| {
            if (cfg_node.ir_node.tag == .catch_expr) {
                if (hasEmptyHandler(cfg_handle.cfg, cfg_node.index)) {
                    // Get source range from IR node
                    if (cfg_node.ir_node.source_range) |range| {
                        const diag = Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "empty-catch-engine",
                            .warning,
                            "Empty catch block detected. Consider handling the error or using '_' to explicitly ignore it.",
                            range,
                        ) catch return;

                        diagnostics.append(allocator, diag) catch return;
                    }
                }
            }
        }
    }

    /// Check if a catch_expr node has an empty handler.
    /// A catch handler is considered empty if the catch_error edge goes directly
    /// to the same merge node as catch_success (no intervening handler nodes).
    fn hasEmptyHandler(cfg: *const Cfg, catch_node_idx: CfgNodeId) bool {
        // Find both catch_error and catch_success targets
        var catch_error_target: ?CfgNodeId = null;
        var catch_success_target: ?CfgNodeId = null;

        for (cfg.edges.items) |edge| {
            if (edge.from == catch_node_idx) {
                if (edge.kind == .catch_error) {
                    catch_error_target = edge.to;
                } else if (edge.kind == .catch_success) {
                    catch_success_target = edge.to;
                }
            }
        }

        // Empty handler: catch_error goes directly to the same merge node as catch_success
        if (catch_error_target != null and catch_success_target != null) {
            return catch_error_target.? == catch_success_target.?;
        }
        return false;
    }
};

test "empty_catch_engine - detects empty catch via CFG" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: empty catch block
    const code1: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() void {
        \\    const x = foo() catch {};
        \\    _ = x;
        \\}
    ;
    var source1 = Source.init(allocator, "test.zig", code1);
    defer source1.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try EmptyCatchEngineChecker.checker.checkAst(&source1, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("empty-catch-engine", diagnostics.items[0].rule_id);
}

test "empty_catch_engine - no diagnostic for non-empty catch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: non-empty catch block
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() i32 {
        \\    const x = foo() catch {
        \\        return 0;
        \\    };
        \\    return x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try EmptyCatchEngineChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "empty_catch_engine - detects catch with capture but empty body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch with error capture but empty body
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() void {
        \\    const x = foo() catch |_| {};
        \\    _ = x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try EmptyCatchEngineChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "empty_catch_engine - detects empty catch at file scope" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: empty catch block at top-level (file scope)
    const code: [:0]const u8 =
        \\fn tryFunc() !i32 {
        \\    return 42;
        \\}
        \\const x = tryFunc() catch {};
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try EmptyCatchEngineChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("empty-catch-engine", diagnostics.items[0].rule_id);
}

test "empty_catch_engine - no diagnostic for non-empty catch at file scope" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: non-empty catch block at top-level
    const code: [:0]const u8 =
        \\fn tryFunc() !i32 {
        \\    return error.Failed;
        \\}
        \\const x = tryFunc() catch {
        \\    @compileError("initialization failed");
        \\};
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try EmptyCatchEngineChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
