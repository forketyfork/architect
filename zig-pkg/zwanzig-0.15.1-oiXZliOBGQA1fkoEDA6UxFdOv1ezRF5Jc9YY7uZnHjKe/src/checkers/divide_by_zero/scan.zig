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

const SiteKind = enum {
    division,
    modulo,
};

const Site = struct {
    ast_node: u32,
    denominator_node: u32,
    kind: SiteKind,
};

const SiteOutcome = enum {
    none,
    definite,
    possible,
};

pub fn scanForZeroDivisors(
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

    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(allocator);

    for (0..tags.len) |i| {
        const node = @as(u32, @intCast(i));
        if (!isInFunctionSubtree(node, fn_index, parent_map)) continue;

        switch (tags[i]) {
            .div, .mod => {
                const pair = datas[i].node_and_node;
                try sites.append(allocator, .{
                    .ast_node = node,
                    .denominator_node = @intFromEnum(pair[1]),
                    .kind = if (tags[i] == .mod) .modulo else .division,
                });
            },
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                const builtin_kind = builtinKind(tree, node) orelse continue;
                var params_buf: [2]std.zig.Ast.Node.Index = undefined;
                const params = tree.builtinCallParams(&params_buf, @enumFromInt(node)) orelse continue;
                if (params.len < 2) continue;
                try sites.append(allocator, .{
                    .ast_node = node,
                    .denominator_node = @intFromEnum(params[1]),
                    .kind = builtin_kind,
                });
            },
            else => {},
        }
    }

    for (sites.items) |site| {
        if (reported.contains(site.ast_node)) continue;

        const outcome = blk: {
            if (findCfgNodeForAst(cfg, site.ast_node, tree)) |cfg_node| {
                break :blk assessWithCfg(tree, engine, cfg, cfg_node, site.denominator_node);
            }
            break :blk assessWithoutCfg(tree, site.denominator_node);
        };

        if (outcome == .none) continue;
        try emitDiagnostic(src, allocator, diagnostics, tree, site, outcome);
        try reported.put(site.ast_node, {});
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

fn builtinKind(tree: *const std.zig.Ast, node: u32) ?SiteKind {
    const token = tree.nodes.items(.main_token)[node];
    const token_tags = tree.tokens.items(.tag);
    if (token >= token_tags.len or token_tags[token] != .builtin) return null;

    const name = tree.tokenSlice(token);
    if (std.mem.eql(u8, name, "@divTrunc") or
        std.mem.eql(u8, name, "@divFloor") or
        std.mem.eql(u8, name, "@divExact"))
    {
        return .division;
    }

    if (std.mem.eql(u8, name, "@mod") or std.mem.eql(u8, name, "@rem")) {
        return .modulo;
    }

    return null;
}

fn assessWithCfg(
    tree: *const std.zig.Ast,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
    cfg_node_idx: ids.CfgNodeId,
    denominator_node: u32,
) SiteOutcome {
    const graph = engine.getGraph();

    var reached_paths: usize = 0;
    var saw_definite_zero = false;
    var saw_maybe_zero = false;
    var saw_definite_non_zero = false;
    var informative_paths: usize = 0;

    for (graph.nodes.items) |exploded_node| {
        if (exploded_node.point.cfg != cfg) continue;
        if (exploded_node.point.kind != .pre) continue;
        if (exploded_node.point.node_index != cfg_node_idx) continue;

        reached_paths += 1;
        const risk = evaluator.riskWithState(tree, denominator_node, &exploded_node.state, engine, cfg);
        switch (risk) {
            .definitely_zero => {
                saw_definite_zero = true;
                informative_paths += 1;
            },
            .maybe_zero => {
                saw_maybe_zero = true;
                informative_paths += 1;
            },
            .definitely_non_zero => {
                saw_definite_non_zero = true;
                informative_paths += 1;
            },
            .unknown => {},
        }
    }

    if (reached_paths == 0) {
        return .none;
    }
    if (informative_paths == 0) {
        return assessWithoutCfg(tree, denominator_node);
    }
    if (saw_definite_zero and !saw_maybe_zero and !saw_definite_non_zero) {
        return .definite;
    }
    if (saw_definite_zero or saw_maybe_zero) {
        return .possible;
    }
    return .none;
}

fn assessWithoutCfg(tree: *const std.zig.Ast, denominator_node: u32) SiteOutcome {
    return switch (evaluator.riskWithoutState(tree, denominator_node)) {
        .definitely_zero => .definite,
        .maybe_zero => .possible,
        else => .none,
    };
}

fn findCfgNodeForAst(cfg: *const Cfg, ast_node: u32, tree: *const std.zig.Ast) ?ids.CfgNodeId {
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    if (ast_node >= main_tokens.len) return null;

    for (cfg.nodes.items, 0..) |node, idx| {
        if (node.ir_node.ast_node) |node_ast| {
            if (node_ast == ast_node) {
                return ids.cfgId(@intCast(idx));
            }
        }
    }

    const target_pos = token_starts[main_tokens[ast_node]];

    var best_match: ?ids.CfgNodeId = null;
    var best_start: u32 = 0;

    for (cfg.nodes.items, 0..) |node, idx| {
        if (node.ir_node.ast_node) |node_ast| {
            if (node_ast >= main_tokens.len) continue;
            const cfg_pos = token_starts[main_tokens[node_ast]];
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
    site: Site,
    outcome: SiteOutcome,
) CheckerError!void {
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    if (site.ast_node >= main_tokens.len) return;
    const token = main_tokens[site.ast_node];
    if (token >= token_starts.len) return;

    const offset = token_starts[token];
    const loc = src.byteToLocation(offset) catch return;

    const severity: checker_mod.Severity = switch (outcome) {
        .definite => .err,
        .possible => .warning,
        .none => return,
    };
    const message: []const u8 = switch (site.kind) {
        .division => switch (outcome) {
            .definite => "division by zero can panic at runtime",
            .possible => "possible division by zero can panic at runtime",
            .none => return,
        },
        .modulo => switch (outcome) {
            .definite => "modulo by zero can panic at runtime",
            .possible => "possible modulo by zero can panic at runtime",
            .none => return,
        },
    };

    const diagnostic = Diagnostic.initAtLocation(
        allocator,
        src.getFilePath(),
        "divide-by-zero-engine",
        severity,
        message,
        loc.line,
        loc.column,
    ) catch return;
    try diagnostics.append(allocator, diagnostic);
}
