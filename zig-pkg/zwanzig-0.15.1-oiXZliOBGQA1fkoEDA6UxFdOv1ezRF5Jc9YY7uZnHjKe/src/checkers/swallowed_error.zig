const std = @import("std");
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

/// Engine-based checker that detects catch blocks that swallow errors.
/// An error is considered "swallowed" when:
/// - The catch block has a non-empty handler body
/// - The handler does NOT rethrow the error (return error or propagate)
/// - The handler does NOT log the error (call to std.debug/log functions)
/// - The handler simply ignores the error and continues execution
///
/// This checker uses the CFG and analysis engine to trace error handling paths
/// and identify catch handlers that swallow errors without proper handling.
pub const SwallowedErrorChecker = struct {
    pub const checker: Checker = .{
        .name = "swallowed-error",
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

        const tree = src.ast() catch return;
        const data = tree.nodes.items(.data);

        // Run the analysis engine with a worklist limit to avoid pathological cases
        var engine = AnalysisEngine.initWithSource(allocator, cfg_handle.cfg, src);
        defer engine.deinit();
        engine.setCheckerName("swallowed-error");
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
        var engine_ok = true;
        engine.run() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AnalysisLimitExceeded => engine_ok = false,
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

        // Examine CFG nodes for catch_expr with swallowed errors
        for (cfg_handle.cfg.nodes.items) |cfg_node| {
            if (cfg_node.ir_node.tag == .catch_expr) {
                const catch_ast = cfg_node.ir_node.ast_node orelse continue;
                const handler_ast = ids.astId(@intFromEnum(data[catch_ast].node_and_node[1]));
                const engine_ptr: ?*const AnalysisEngine = if (engine_ok) &engine else null;
                if (try isErrorSwallowed(cfg_handle.cfg, cfg_node.index, handler_ast, tree, engine_ptr, allocator)) {
                    // Get source range from IR node
                    if (cfg_node.ir_node.source_range) |range| {
                        const diag = Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "swallowed-error",
                            .warning,
                            "Error is swallowed without logging or rethrowing. Consider handling the error properly.",
                            range,
                        ) catch return;

                        diagnostics.append(allocator, diag) catch return;
                    }
                }
            }
        }
    }

    /// Check if a catch_expr swallows an error.
    /// An error is swallowed if:
    /// 1. The catch handler is non-empty (has actual statements)
    /// 2. The handler does NOT return an error
    /// 3. The handler does NOT appear to log the error
    /// 4. The handler completes normally (reaches merge point)
    fn isErrorSwallowed(
        cfg: *const Cfg,
        catch_node_idx: CfgNodeId,
        handler_ast: AstNodeId,
        tree: *const std.zig.Ast,
        engine: ?*const AnalysisEngine,
        allocator: std.mem.Allocator,
    ) CheckerError!bool {
        // Find the catch_error edge
        var handler_entry: ?CfgNodeId = null;
        var merge_node: ?CfgNodeId = null;

        for (cfg.edges.items) |edge| {
            if (edge.from == catch_node_idx) {
                if (edge.kind == .catch_error) {
                    handler_entry = edge.to;
                } else if (edge.kind == .catch_success) {
                    // Track the merge node (where catch_success goes)
                    merge_node = edge.to;
                }
            }
        }

        // If no handler entry, no swallowed error (empty catch is handled separately)
        const entry = handler_entry orelse return false;

        // If handler entry is directly the merge node, it's empty (not swallowed)
        // This is the correct way to detect empty handlers - comparing to merge node
        if (merge_node != null and entry == merge_node.?) {
            return false;
        }

        // Trace through the handler to see if it:
        // 1. Returns an error (good)
        // 2. Contains a call (potentially logging)
        // 3. Just falls through (swallowed error)
        const scan = scanHandlerTokens(tree, handler_ast);
        var has_return = scan.has_return;
        var has_call = scan.has_call;
        var current_nodes: std.ArrayList(CfgNodeId) = .empty;
        defer current_nodes.deinit(allocator);
        var visited = std.AutoHashMap(CfgNodeId, void).init(allocator);
        defer visited.deinit();

        try current_nodes.append(allocator, entry);

        while (current_nodes.items.len > 0) {
            const node_idx = current_nodes.pop() orelse continue;

            if (visited.contains(node_idx)) continue;
            try visited.put(node_idx, {});

            // Stop if we reach the merge node
            if (merge_node != null and node_idx == merge_node.?) {
                continue;
            }

            const cfg_node = cfg.getNode(node_idx) orelse continue;

            switch (cfg_node.ir_node.tag) {
                .ret => {
                    has_return = true;
                },
                .call => {
                    has_call = true;
                },
                else => {},
            }

            // Find successors within the handler
            for (cfg.edges.items) |edge| {
                if (edge.from == node_idx) {
                    // Don't follow edges that leave the handler context
                    if (edge.kind != .catch_success) {
                        try current_nodes.append(allocator, edge.to);
                    }
                }
            }
        }

        // Check using the analysis engine for error state paths
        var reaches_merge_from_error = false;
        if (engine) |eng| {
            const graph = eng.getGraph();

            // Look for exploded nodes at the merge point with error_handled state
            if (merge_node) |merge| {
                for (graph.nodes.items) |exploded_node| {
                    if (exploded_node.point.node_index == merge and
                        exploded_node.point.kind == .pre)
                    {
                        // This node reached the merge - check if it came from error handler
                        // by looking at predecessors
                        for (exploded_node.predecessors.items) |pred_idx| {
                            if (graph.getNode(pred_idx)) |pred_node| {
                                if (pred_node.state.getErrorState() == .error_handled) {
                                    reaches_merge_from_error = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Error is swallowed if:
        // - Handler reaches merge without return
        // - Handler doesn't have a call (potential logging)
        // - Analysis shows error path reaches normal completion
        if (engine != null and !has_return and !has_call and reaches_merge_from_error) {
            return true;
        }

        // Also flag as swallowed if there's no return and no call even without engine check
        // This catches cases where the CFG structure shows a non-empty handler that
        // doesn't do anything useful
        if (!has_return and !has_call and handler_entry != merge_node) {
            // Verify the handler actually has statements by checking it's not just going to merge
            var nodes_in_handler: u32 = 0;
            var iter = visited.iterator();
            while (iter.next()) |_| {
                nodes_in_handler += 1;
            }
            // If we visited more than just the entry node, there's a handler body
            if (nodes_in_handler > 1) {
                return true;
            }
        }

        return false;
    }

    const TokenScan = struct {
        has_return: bool,
        has_call: bool,
    };

    fn scanHandlerTokens(tree: *const std.zig.Ast, handler_ast: AstNodeId) TokenScan {
        if (ids.astIndex(handler_ast) == 0) {
            return .{ .has_return = false, .has_call = false };
        }
        const token_tags = tree.tokens.items(.tag);
        const ast_index = ids.astIndex(handler_ast);
        const first = tree.firstToken(@enumFromInt(ast_index));
        const last = tree.lastToken(@enumFromInt(ast_index));
        if (first >= token_tags.len) {
            return .{ .has_return = false, .has_call = false };
        }
        var has_return = false;
        var has_call = false;
        var i = first;
        const end = if (last < token_tags.len) last else token_tags.len - 1;
        while (i <= end) : (i += 1) {
            const tag = token_tags[i];
            if (tag == .keyword_return) {
                has_return = true;
            }
            if (!has_call and (tag == .identifier or tag == .builtin)) {
                var j = i + 1;
                if (j <= end and token_tags[j] == .period) {
                    while (j + 1 <= end and token_tags[j] == .period and token_tags[j + 1] == .identifier) {
                        j += 2;
                    }
                }
                if (j <= end and token_tags[j] == .l_paren) {
                    has_call = true;
                }
            }
        }
        return .{ .has_return = has_return, .has_call = has_call };
    }
};

test "swallowed_error - no diagnostic for catch that returns error" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch that returns error (not swallowed)
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return error.Failed;
        \\}
        \\fn bar() !i32 {
        \\    const x = foo() catch |err| {
        \\        return err;
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
    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - no diagnostic for catch handler that returns in switch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return error.FontUnavailable;
        \\}
        \\fn bar() !i32 {
        \\    const x = foo() catch |err| switch (err) {
        \\        error.FontUnavailable => return err,
        \\        error.OutOfMemory => return err,
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
    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - no diagnostic for catch handler with call in switch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() !i32 {
        \\    return error.Failed;
        \\}
        \\fn bar() i32 {
        \\    const x = foo() catch |err| switch (err) {
        \\        error.Failed => std.debug.print("oops\\n", .{}),
        \\        else => {},
        \\    };
        \\    _ = x;
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - no diagnostic for catch with call (logging)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch that logs (has a call - not swallowed)
    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() !i32 {
        \\    return error.Failed;
        \\}
        \\fn bar() i32 {
        \\    const x = foo() catch |err| {
        \\        std.debug.print("Error: {}\n", .{err});
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
    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - no diagnostic for empty catch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: empty catch (handled by empty-catch rule, not swallowed-error)
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return 42;
        \\}
        \\fn bar() void {
        \\    const x = foo() catch {};
        \\    _ = x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "swallowed_error - detects swallowed error with assignment only" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test case: catch that just assigns to a variable (swallowed)
    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    return error.Failed;
        \\}
        \\fn bar() i32 {
        \\    var y: i32 = 0;
        \\    const x = foo() catch |_| {
        \\        y = 1;
        \\    };
        \\    _ = x;
        \\    return y;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try SwallowedErrorChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("swallowed-error", diagnostics.items[0].rule_id);
}
