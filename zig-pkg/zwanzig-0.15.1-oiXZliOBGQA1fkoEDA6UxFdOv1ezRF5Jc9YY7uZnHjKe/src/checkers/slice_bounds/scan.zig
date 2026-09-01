const std = @import("std");
const ast_walk = @import("../../ast_walk.zig");
const checker_mod = @import("../../checker.zig");
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const Source = @import("../../source.zig").Source;
const ids = @import("../../ids.zig");
const cfg_mod = @import("../../cfg.zig");
const Cfg = cfg_mod.Cfg;
const engine_mod = @import("../../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;
const evaluator = @import("evaluator.zig");

const BoundsSite = evaluator.BoundsSite;

const BoundsOutcome = enum {
    safe,
    definitely_oob,
    possibly_oob,
};

pub fn scanForBoundsViolations(
    src: *Source,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    tree: *const std.zig.Ast,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
    fn_node: ids.AstNodeId,
    reported: *std.AutoHashMap(u32, void),
) CheckerError!void {
    _ = engine.getGraph();

    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    const fn_index = ids.astIndex(fn_node);
    if (fn_index >= tags.len) return;

    const parent_map = try allocator.alloc(u32, tags.len);
    defer allocator.free(parent_map);
    @memset(parent_map, 0);
    ast_walk.fillParentMap(tree, fn_index, parent_map);

    var sites: std.ArrayList(BoundsSite) = .empty;
    defer sites.deinit(allocator);

    // Find all array/slice access sites
    for (0..tags.len) |i| {
        const node = @as(u32, @intCast(i));
        if (!isInFunctionSubtree(node, fn_index, parent_map)) continue;

        if (tags[i] == .array_access) {
            const pair = datas[i].node_and_node;
            try sites.append(allocator, .{
                .ast_node = node,
                .array_or_slice_node = @intFromEnum(pair[0]),
                .index_node = @intFromEnum(pair[1]),
            });
        }
    }

    for (sites.items) |site| {
        if (reported.contains(site.ast_node)) continue;

        const outcome = blk: {
            if (findCfgNodeForAst(cfg, site.ast_node, tree)) |cfg_node| {
                break :blk assessWithCfg(tree, engine, cfg, cfg_node, site);
            }
            break :blk assessWithoutCfg(tree, site);
        };

        switch (outcome) {
            .safe => continue,
            .definitely_oob => {
                try emitDiagnostic(src, allocator, diagnostics, tree, site, true);
                try reported.put(site.ast_node, {});
            },
            .possibly_oob => {
                try emitDiagnostic(src, allocator, diagnostics, tree, site, false);
                try reported.put(site.ast_node, {});
            },
        }
    }
}

fn isInFunctionSubtree(node: u32, fn_index: u32, parent_map: []const u32) bool {
    if (node == fn_index) return true;
    if (node >= parent_map.len) return false;

    var current = node;
    var depth: u32 = 0;
    while (depth < 256 and current < parent_map.len) : (depth += 1) {
        const parent = parent_map[current];
        if (parent == 0) return false;
        if (parent == fn_index) return true;
        current = parent;
    }

    return false;
}

fn assessWithCfg(
    tree: *const std.zig.Ast,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
    cfg_node_idx: ids.CfgNodeId,
    site: BoundsSite,
) BoundsOutcome {
    const graph = engine.getGraph();

    var reached_paths: usize = 0;
    var saw_definite_oob = false;
    var saw_possible_oob = false;
    var saw_safe = false;
    var informative_paths: usize = 0;

    for (graph.nodes.items) |exploded_node| {
        if (exploded_node.point.cfg != cfg) continue;
        if (exploded_node.point.kind != .pre) continue;
        if (exploded_node.point.node_index != cfg_node_idx) continue;

        reached_paths += 1;
        const risk = evaluator.assessBoundsRiskWithState(tree, site, &exploded_node.state, engine, cfg);
        switch (risk) {
            .definitely_oob => {
                saw_definite_oob = true;
                informative_paths += 1;
            },
            .possibly_oob => {
                saw_possible_oob = true;
                informative_paths += 1;
            },
            .safe => {
                saw_safe = true;
                informative_paths += 1;
            },
            .unknown => {},
        }
    }

    if (reached_paths == 0) {
        return .safe;
    }
    if (informative_paths == 0) {
        return assessWithoutCfg(tree, site);
    }
    if (saw_definite_oob and !saw_possible_oob and !saw_safe) {
        return .definitely_oob;
    }
    if (saw_definite_oob or saw_possible_oob) {
        return .possibly_oob;
    }
    return .safe;
}

fn assessWithoutCfg(tree: *const std.zig.Ast, site: BoundsSite) BoundsOutcome {
    return switch (evaluator.assessBoundsRiskWithoutState(tree, site)) {
        .definitely_oob => .definitely_oob,
        .possibly_oob => .possibly_oob,
        .unknown, .safe => .safe,
    };
}

fn findCfgNodeForAst(cfg: *const Cfg, ast_node: u32, tree: *const std.zig.Ast) ?ids.CfgNodeId {
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    if (ast_node >= main_tokens.len) return null;

    for (cfg.nodes.items, 0..) |node, idx| {
        if (node.ir_node.ast_node) |node_ast| {
            if (node_ast == ast_node) return ids.cfgId(@intCast(idx));
        }
    }

    const target_token = main_tokens[ast_node];
    if (target_token >= token_starts.len) return null;
    const target_pos = token_starts[target_token];

    var best_match: ?ids.CfgNodeId = null;
    var best_start: u32 = 0;

    for (cfg.nodes.items, 0..) |node, idx| {
        if (node.ir_node.ast_node) |node_ast| {
            if (node_ast >= main_tokens.len) continue;
            const cfg_token = main_tokens[node_ast];
            if (cfg_token >= token_starts.len) continue;
            const cfg_pos = token_starts[cfg_token];
            if (cfg_pos <= target_pos and cfg_pos >= best_start) {
                best_start = cfg_pos;
                best_match = ids.cfgId(@intCast(idx));
            }
        }
    }

    return best_match;
}

fn emitDiagnostic(
    src: *Source,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    tree: *const std.zig.Ast,
    site: BoundsSite,
    is_definite: bool,
) CheckerError!void {
    const token = tree.nodes.items(.main_token)[site.ast_node];
    const loc = src.tokenLocation(token) catch return;

    const message = if (is_definite)
        "Array/slice index is definitely out of bounds"
    else
        "Array/slice index may be out of bounds";

    const diag = try Diagnostic.initAtLocation(
        allocator,
        src.getFilePath(),
        "slice-bounds-engine",
        .err,
        message,
        loc.line,
        loc.column,
    );
    try diagnostics.append(allocator, diag);
}
