const std = @import("std");
const AbstractValue = @import("../../engine/value.zig").AbstractValue;
const ProgramState = @import("../../engine/state.zig").ProgramState;
const ids = @import("../../ids.zig");
const Cfg = @import("../../cfg.zig").Cfg;
const AnalysisEngine = @import("../../engine.zig").AnalysisEngine;

const BoundsRisk = enum {
    safe,
    definitely_oob,
    possibly_oob,
    unknown,
};

pub const BoundsSite = struct {
    ast_node: u32,
    array_or_slice_node: u32,
    index_node: u32,
};

pub fn assessBoundsRiskWithState(
    tree: *const std.zig.Ast,
    site: BoundsSite,
    state: *const ProgramState,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
) BoundsRisk {
    const index_value = evaluateExpr(tree, site.index_node, state, engine, cfg, 0);
    const length_value = evaluateLength(tree, site.array_or_slice_node, state, engine, cfg, 0);

    return compareBounds(index_value, length_value);
}

pub fn assessBoundsRiskWithoutState(tree: *const std.zig.Ast, site: BoundsSite) BoundsRisk {
    const index_value = evaluateExprWithoutState(tree, site.index_node);
    const length_value = evaluateLengthWithoutState(tree, site.array_or_slice_node);

    return compareBounds(index_value, length_value);
}

fn compareBounds(index_value: AbstractValue, length_value: AbstractValue) BoundsRisk {
    // If index is a concrete value and length is a concrete value, we can check precisely
    if (index_value == .concrete_int and length_value == .concrete_int) {
        if (index_value.concrete_int < 0 or index_value.concrete_int >= length_value.concrete_int) {
            return .definitely_oob;
        }
        return .safe;
    }

    // If index is a range and length is concrete, check if any value in range is OOB
    if (index_value == .int_range and length_value == .concrete_int) {
        const range = index_value.int_range;
        const len = length_value.concrete_int;

        // If the entire range is beyond bounds, definitely OOB
        if (range.max < 0 or range.min >= len) {
            return .definitely_oob;
        }
        // If the range partially overlaps invalid indices, possibly OOB
        if (range.min < 0 or range.max >= len) {
            return .possibly_oob;
        }
        return .safe;
    }

    // If index is concrete and length is a range, check conservatively
    if (index_value == .concrete_int and length_value == .int_range) {
        const idx = index_value.concrete_int;
        const range = length_value.int_range;

        if (idx < 0) {
            return .definitely_oob;
        }
        // If index is greater than or equal to max possible length, definitely OOB
        if (idx >= range.max) {
            return .definitely_oob;
        }
        // If index might be >= min length, possibly OOB
        if (idx >= range.min) {
            return .possibly_oob;
        }
        return .safe;
    }

    // If both are ranges, check for potential overlap
    if (index_value == .int_range and length_value == .int_range) {
        const idx_range = index_value.int_range;
        const len_range = length_value.int_range;

        // If minimum index is negative, definitely OOB
        if (idx_range.min < 0) {
            return .definitely_oob;
        }
        // If minimum index >= maximum possible length, definitely OOB
        if (idx_range.min >= len_range.max) {
            return .definitely_oob;
        }
        // If maximum index >= minimum possible length, possibly OOB
        if (idx_range.max >= len_range.min) {
            return .possibly_oob;
        }
        return .safe;
    }

    // If we can't determine, return unknown
    return .unknown;
}

fn evaluateExpr(
    tree: *const std.zig.Ast,
    node: u32,
    state: *const ProgramState,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
    depth: u8,
) AbstractValue {
    if (depth > 24) return .unknown;

    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (node >= tags.len) return .unknown;

    if (engine.resolveVarIdFromExpr(node, cfg)) |var_id| {
        if (resolveIndexValueFromState(state, var_id)) |value| return value;
    }

    switch (tags[node]) {
        .number_literal => {
            if (parseIntLiteral(tree, node)) |value| {
                return .{ .concrete_int = value };
            }
            return .unknown;
        },
        .identifier => {
            if (resolveIdentifierInitWithEngine(tree, node, engine, cfg)) |resolved| {
                if (resolved.is_const and resolved.init_node != node) {
                    return evaluateExpr(tree, resolved.init_node, state, engine, cfg, depth + 1);
                }
            }
            if (resolveIdentifierInitWithoutEngine(tree, node)) |resolved| {
                if (resolved.is_const and resolved.init_node != node) {
                    return evaluateExpr(tree, resolved.init_node, state, engine, cfg, depth + 1);
                }
            }
            return .unknown;
        },
        .grouped_expression, .unwrap_optional => {
            const child = @intFromEnum(datas[node].node_and_token[0]);
            return evaluateExpr(tree, child, state, engine, cfg, depth + 1);
        },
        .@"try", .negation, .negation_wrap => {
            const child = @intFromEnum(datas[node].node);
            const child_value = evaluateExpr(tree, child, state, engine, cfg, depth + 1);
            if (tags[node] == .@"try") return child_value;
            return negateValue(child_value);
        },
        .@"catch" => {
            const pair = datas[node].node_and_node;
            return evaluateExpr(tree, @intFromEnum(pair[0]), state, engine, cfg, depth + 1);
        },
        .@"orelse" => {
            const pair = datas[node].node_and_node;
            const lhs = evaluateExpr(tree, @intFromEnum(pair[0]), state, engine, cfg, depth + 1);
            if (lhs != .unknown) return lhs;
            return evaluateExpr(tree, @intFromEnum(pair[1]), state, engine, cfg, depth + 1);
        },
        .add, .sub => {
            const pair = datas[node].node_and_node;
            const lhs = evaluateExpr(tree, @intFromEnum(pair[0]), state, engine, cfg, depth + 1);
            const rhs = evaluateExpr(tree, @intFromEnum(pair[1]), state, engine, cfg, depth + 1);
            return evalBinaryOp(tags[node], lhs, rhs);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            return evaluateBuiltinExpr(tree, node, state, engine, cfg, depth + 1);
        },
        else => return .unknown,
    }
}

fn evaluateExprWithoutState(tree: *const std.zig.Ast, node: u32) AbstractValue {
    const tags = tree.nodes.items(.tag);

    if (node >= tags.len) return .unknown;

    switch (tags[node]) {
        .number_literal => {
            if (parseIntLiteral(tree, node)) |value| {
                return .{ .concrete_int = value };
            }
            return .unknown;
        },
        .identifier => {
            if (resolveIdentifierInitWithoutEngine(tree, node)) |resolved| {
                if (resolved.is_const and resolved.init_node != node) {
                    return evaluateExprWithoutState(tree, resolved.init_node);
                }
            }
            return .unknown;
        },
        .grouped_expression, .unwrap_optional => {
            const child = @intFromEnum(tree.nodes.items(.data)[node].node_and_token[0]);
            return evaluateExprWithoutState(tree, child);
        },
        .@"try", .negation, .negation_wrap => {
            const child = @intFromEnum(tree.nodes.items(.data)[node].node);
            const child_value = evaluateExprWithoutState(tree, child);
            if (tags[node] == .@"try") return child_value;
            return negateValue(child_value);
        },
        .@"catch" => {
            const pair = tree.nodes.items(.data)[node].node_and_node;
            return evaluateExprWithoutState(tree, @intFromEnum(pair[0]));
        },
        .@"orelse" => {
            const pair = tree.nodes.items(.data)[node].node_and_node;
            const lhs = evaluateExprWithoutState(tree, @intFromEnum(pair[0]));
            if (lhs != .unknown) return lhs;
            return evaluateExprWithoutState(tree, @intFromEnum(pair[1]));
        },
        .add, .sub => {
            const pair = tree.nodes.items(.data)[node].node_and_node;
            const lhs = evaluateExprWithoutState(tree, @intFromEnum(pair[0]));
            const rhs = evaluateExprWithoutState(tree, @intFromEnum(pair[1]));
            return evalBinaryOp(tags[node], lhs, rhs);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            return evaluateBuiltinExprWithoutState(tree, node);
        },
        else => return .unknown,
    }
}

fn evaluateLength(
    tree: *const std.zig.Ast,
    node: u32,
    state: *const ProgramState,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
    depth: u8,
) AbstractValue {
    if (depth > 24) return .unknown;

    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (node >= tags.len) return .unknown;

    if (arrayLengthFromLiteral(tree, node)) |len| {
        return .{ .concrete_int = len };
    }

    if (stringLengthFromLiteral(tree, node)) |len| {
        return .{ .concrete_int = len };
    }

    switch (tags[node]) {
        .identifier => {
            if (resolveIdentifierInitWithEngine(tree, node, engine, cfg)) |resolved| {
                if (resolved.init_node != node) {
                    return evaluateLength(tree, resolved.init_node, state, engine, cfg, depth + 1);
                }
            }
            if (resolveIdentifierInitWithoutEngine(tree, node)) |resolved| {
                if (resolved.init_node != node) {
                    return evaluateLength(tree, resolved.init_node, state, engine, cfg, depth + 1);
                }
            }
            return .unknown;
        },
        .field_access => {
            const pair = datas[node].node_and_token;
            const field_token = pair[1];
            const token_tags = tree.tokens.items(.tag);
            if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return .unknown;
            if (!std.mem.eql(u8, tree.tokenSlice(field_token), "len")) return .unknown;
            const base_node = @intFromEnum(pair[0]);
            return evaluateLength(tree, base_node, state, engine, cfg, depth + 1);
        },
        .grouped_expression, .unwrap_optional => {
            const child = @intFromEnum(datas[node].node_and_token[0]);
            return evaluateLength(tree, child, state, engine, cfg, depth + 1);
        },
        .@"try", .address_of, .deref => {
            const child = @intFromEnum(datas[node].node);
            return evaluateLength(tree, child, state, engine, cfg, depth + 1);
        },
        .@"catch" => {
            const pair = datas[node].node_and_node;
            return evaluateLength(tree, @intFromEnum(pair[0]), state, engine, cfg, depth + 1);
        },
        .@"orelse" => {
            const pair = datas[node].node_and_node;
            const lhs = evaluateLength(tree, @intFromEnum(pair[0]), state, engine, cfg, depth + 1);
            if (lhs != .unknown) return lhs;
            return evaluateLength(tree, @intFromEnum(pair[1]), state, engine, cfg, depth + 1);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            return evaluateBuiltinLength(tree, node, state, engine, cfg, depth + 1);
        },
        else => return .unknown,
    }
}

fn evaluateLengthWithoutState(tree: *const std.zig.Ast, node: u32) AbstractValue {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (node >= tags.len) return .unknown;

    if (arrayLengthFromLiteral(tree, node)) |len| {
        return .{ .concrete_int = len };
    }

    if (stringLengthFromLiteral(tree, node)) |len| {
        return .{ .concrete_int = len };
    }

    switch (tags[node]) {
        .identifier => {
            if (resolveIdentifierInitWithoutEngine(tree, node)) |resolved| {
                if (resolved.init_node != node) return evaluateLengthWithoutState(tree, resolved.init_node);
            }
            return .unknown;
        },
        .field_access => {
            const pair = datas[node].node_and_token;
            const field_token = pair[1];
            const token_tags = tree.tokens.items(.tag);
            if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return .unknown;
            if (!std.mem.eql(u8, tree.tokenSlice(field_token), "len")) return .unknown;
            const base_node = @intFromEnum(pair[0]);
            return evaluateLengthWithoutState(tree, base_node);
        },
        .grouped_expression, .unwrap_optional => {
            const child = @intFromEnum(datas[node].node_and_token[0]);
            return evaluateLengthWithoutState(tree, child);
        },
        .@"try", .address_of, .deref => {
            const child = @intFromEnum(datas[node].node);
            return evaluateLengthWithoutState(tree, child);
        },
        .@"catch" => {
            const pair = datas[node].node_and_node;
            return evaluateLengthWithoutState(tree, @intFromEnum(pair[0]));
        },
        .@"orelse" => {
            const pair = datas[node].node_and_node;
            const lhs = evaluateLengthWithoutState(tree, @intFromEnum(pair[0]));
            if (lhs != .unknown) return lhs;
            return evaluateLengthWithoutState(tree, @intFromEnum(pair[1]));
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            return evaluateBuiltinLengthWithoutState(tree, node);
        },
        else => return .unknown,
    }
}

fn evalBinaryOp(op: std.zig.Ast.Node.Tag, lhs: AbstractValue, rhs: AbstractValue) AbstractValue {
    if (lhs == .concrete_int and rhs == .concrete_int) {
        const result = switch (op) {
            .add => safeAdd(lhs.concrete_int, rhs.concrete_int) orelse return .unknown,
            .sub => safeSub(lhs.concrete_int, rhs.concrete_int) orelse return .unknown,
            else => return .unknown,
        };
        return .{ .concrete_int = result };
    }

    if (lhs == .int_range and rhs == .concrete_int) {
        const range = lhs.int_range;
        const value = rhs.concrete_int;
        return switch (op) {
            .add => .{ .int_range = .{
                .min = safeAdd(range.min, value) orelse return .unknown,
                .max = safeAdd(range.max, value) orelse return .unknown,
            } },
            .sub => .{ .int_range = .{
                .min = safeSub(range.min, value) orelse return .unknown,
                .max = safeSub(range.max, value) orelse return .unknown,
            } },
            else => .unknown,
        };
    }

    if (lhs == .concrete_int and rhs == .int_range) {
        const value = lhs.concrete_int;
        const range = rhs.int_range;
        return switch (op) {
            .add => .{ .int_range = .{
                .min = safeAdd(value, range.min) orelse return .unknown,
                .max = safeAdd(value, range.max) orelse return .unknown,
            } },
            .sub => .{ .int_range = .{
                .min = safeSub(value, range.max) orelse return .unknown,
                .max = safeSub(value, range.min) orelse return .unknown,
            } },
            else => .unknown,
        };
    }

    if (lhs == .int_range and rhs == .int_range) {
        const lhs_range = lhs.int_range;
        const rhs_range = rhs.int_range;
        return switch (op) {
            .add => .{ .int_range = .{
                .min = safeAdd(lhs_range.min, rhs_range.min) orelse return .unknown,
                .max = safeAdd(lhs_range.max, rhs_range.max) orelse return .unknown,
            } },
            .sub => .{ .int_range = .{
                .min = safeSub(lhs_range.min, rhs_range.max) orelse return .unknown,
                .max = safeSub(lhs_range.max, rhs_range.min) orelse return .unknown,
            } },
            else => .unknown,
        };
    }

    return .unknown;
}

fn evaluateBuiltinExpr(
    tree: *const std.zig.Ast,
    node: u32,
    state: *const ProgramState,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
    depth: u8,
) AbstractValue {
    const builtin_name = builtinName(tree, node) orelse return .unknown;
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, @enumFromInt(node)) orelse return .unknown;

    if (std.mem.eql(u8, builtin_name, "@as")) {
        if (params.len < 2) return .unknown;
        return evaluateExpr(tree, @intFromEnum(params[1]), state, engine, cfg, depth + 1);
    }
    if (std.mem.eql(u8, builtin_name, "@intCast") or
        std.mem.eql(u8, builtin_name, "@truncate") or
        std.mem.eql(u8, builtin_name, "@bitCast") or
        std.mem.eql(u8, builtin_name, "@enumFromInt"))
    {
        if (params.len < 1) return .unknown;
        return evaluateExpr(tree, @intFromEnum(params[0]), state, engine, cfg, depth + 1);
    }

    return .unknown;
}

fn evaluateBuiltinExprWithoutState(tree: *const std.zig.Ast, node: u32) AbstractValue {
    const builtin_name = builtinName(tree, node) orelse return .unknown;
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, @enumFromInt(node)) orelse return .unknown;

    if (std.mem.eql(u8, builtin_name, "@as")) {
        if (params.len < 2) return .unknown;
        return evaluateExprWithoutState(tree, @intFromEnum(params[1]));
    }
    if (std.mem.eql(u8, builtin_name, "@intCast") or
        std.mem.eql(u8, builtin_name, "@truncate") or
        std.mem.eql(u8, builtin_name, "@bitCast") or
        std.mem.eql(u8, builtin_name, "@enumFromInt"))
    {
        if (params.len < 1) return .unknown;
        return evaluateExprWithoutState(tree, @intFromEnum(params[0]));
    }

    return .unknown;
}

fn evaluateBuiltinLength(
    tree: *const std.zig.Ast,
    node: u32,
    state: *const ProgramState,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
    depth: u8,
) AbstractValue {
    const builtin_name = builtinName(tree, node) orelse return .unknown;
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, @enumFromInt(node)) orelse return .unknown;

    if (std.mem.eql(u8, builtin_name, "@as")) {
        if (params.len < 2) return .unknown;
        return evaluateLength(tree, @intFromEnum(params[1]), state, engine, cfg, depth + 1);
    }
    if (std.mem.eql(u8, builtin_name, "@intCast") or
        std.mem.eql(u8, builtin_name, "@truncate") or
        std.mem.eql(u8, builtin_name, "@bitCast"))
    {
        if (params.len < 1) return .unknown;
        return evaluateLength(tree, @intFromEnum(params[0]), state, engine, cfg, depth + 1);
    }

    return .unknown;
}

fn evaluateBuiltinLengthWithoutState(tree: *const std.zig.Ast, node: u32) AbstractValue {
    const builtin_name = builtinName(tree, node) orelse return .unknown;
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, @enumFromInt(node)) orelse return .unknown;

    if (std.mem.eql(u8, builtin_name, "@as")) {
        if (params.len < 2) return .unknown;
        return evaluateLengthWithoutState(tree, @intFromEnum(params[1]));
    }
    if (std.mem.eql(u8, builtin_name, "@intCast") or
        std.mem.eql(u8, builtin_name, "@truncate") or
        std.mem.eql(u8, builtin_name, "@bitCast"))
    {
        if (params.len < 1) return .unknown;
        return evaluateLengthWithoutState(tree, @intFromEnum(params[0]));
    }

    return .unknown;
}

const IdentifierInit = struct {
    init_node: u32,
    is_const: bool,
};

fn resolveIdentifierInitWithEngine(
    tree: *const std.zig.Ast,
    identifier_node: u32,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
) ?IdentifierInit {
    const decl_info = engine.resolveDeclInfoFromIdentifier(identifier_node, cfg) orelse return null;
    const full_decl = tree.fullVarDecl(@enumFromInt(decl_info.decl_node)) orelse return null;
    const token_tags = tree.tokens.items(.tag);
    const mut_token = full_decl.ast.mut_token;
    const is_const = mut_token < token_tags.len and token_tags[mut_token] == .keyword_const;
    if (full_decl.ast.init_node.unwrap()) |init_node| {
        return .{
            .init_node = @intFromEnum(init_node),
            .is_const = is_const,
        };
    }
    return null;
}

fn resolveIdentifierInitWithoutEngine(tree: *const std.zig.Ast, identifier_node: u32) ?IdentifierInit {
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);
    const token_starts = tree.tokens.items(.start);

    if (identifier_node >= tags.len or tags[identifier_node] != .identifier) return null;
    if (identifier_node >= main_tokens.len) return null;
    const ident_token = main_tokens[identifier_node];
    if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return null;
    if (ident_token >= token_starts.len) return null;

    const ident_name = tree.tokenSlice(ident_token);
    const ident_pos = token_starts[ident_token];

    var best_decl_pos: u32 = 0;
    var best_init: ?IdentifierInit = null;

    for (0..tags.len) |i| {
        switch (tags[i]) {
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => {
                const full_decl = tree.fullVarDecl(@enumFromInt(i)) orelse continue;
                const name_token = full_decl.ast.mut_token + 1;
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                if (name_token >= token_starts.len) continue;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), ident_name)) continue;

                const decl_pos = token_starts[name_token];
                if (decl_pos > ident_pos) continue;
                if (full_decl.ast.init_node.unwrap()) |init_node| {
                    if (best_init == null or decl_pos >= best_decl_pos) {
                        best_decl_pos = decl_pos;
                        const mut_token = full_decl.ast.mut_token;
                        const is_const = mut_token < token_tags.len and token_tags[mut_token] == .keyword_const;
                        best_init = .{
                            .init_node = @intFromEnum(init_node),
                            .is_const = is_const,
                        };
                    }
                }
            },
            else => {},
        }
    }

    return best_init;
}

fn resolveIndexValueFromState(state: *const ProgramState, var_id: ids.VarId) ?AbstractValue {
    var min_bound: i64 = std.math.minInt(i64);
    var max_bound: i64 = std.math.maxInt(i64);
    var has_bounds = false;
    var impossible = false;

    if (state.getVar(var_id)) |value| {
        switch (value) {
            .concrete_int => |v| {
                min_bound = v;
                max_bound = v;
                has_bounds = true;
            },
            .int_range => |r| {
                min_bound = r.min;
                max_bound = r.max;
                has_bounds = true;
            },
            else => {},
        }
    }

    for (state.constraints.constraints.items) |constraint| {
        switch (constraint) {
            .int_compare => |cmp| {
                if (cmp.var_id != var_id) continue;
                has_bounds = true;
                switch (cmp.op) {
                    .eq => {
                        min_bound = cmp.value;
                        max_bound = cmp.value;
                    },
                    .ne => {},
                    .gt => {
                        const lower = addOne(cmp.value) orelse {
                            impossible = true;
                            continue;
                        };
                        min_bound = @max(min_bound, lower);
                    },
                    .ge => {
                        min_bound = @max(min_bound, cmp.value);
                    },
                    .lt => {
                        const upper = subOne(cmp.value) orelse {
                            impossible = true;
                            continue;
                        };
                        max_bound = @min(max_bound, upper);
                    },
                    .le => {
                        max_bound = @min(max_bound, cmp.value);
                    },
                }
            },
            else => {},
        }
    }

    if (!has_bounds or impossible) return null;
    if (min_bound > max_bound) return null;
    if (min_bound == std.math.minInt(i64) or max_bound == std.math.maxInt(i64)) return null;
    if (min_bound == max_bound) return .{ .concrete_int = min_bound };
    return .{ .int_range = .{ .min = min_bound, .max = max_bound } };
}

fn arrayLengthFromLiteral(tree: *const std.zig.Ast, node: u32) ?i64 {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return null;

    switch (tags[node]) {
        .array_init,
        .array_init_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        => {},
        else => return null,
    }

    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const full = tree.fullArrayInit(&buf, @enumFromInt(node)) orelse return null;
    return @intCast(full.ast.elements.len);
}

fn stringLengthFromLiteral(tree: *const std.zig.Ast, node: u32) ?i64 {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return null;
    if (tags[node] != .string_literal and tags[node] != .multiline_string_literal) return null;

    const token = tree.nodes.items(.main_token)[node];
    const slice = tree.tokenSlice(token);
    if (slice.len < 2) return null;
    return @intCast(slice.len - 2);
}

fn builtinName(tree: *const std.zig.Ast, node_idx: u32) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    if (node_idx >= tags.len) return null;

    switch (tags[node_idx]) {
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }

    const token = tree.nodes.items(.main_token)[node_idx];
    const token_tags = tree.tokens.items(.tag);
    if (token >= token_tags.len or token_tags[token] != .builtin) return null;
    return tree.tokenSlice(token);
}

fn parseIntLiteral(tree: *const std.zig.Ast, node: u32) ?i64 {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len or tags[node] != .number_literal) return null;

    const token = tree.nodes.items(.main_token)[node];
    const token_str = tree.tokenSlice(token);
    if (token_str.len == 0) return null;

    for (token_str) |c| {
        if (c == '.' or c == 'e' or c == 'E' or c == 'p' or c == 'P') return null;
    }

    var clean_buf: [128]u8 = undefined;
    var clean_len: usize = 0;
    for (token_str) |c| {
        if (c == '_') continue;
        if (clean_len >= clean_buf.len) return null;
        clean_buf[clean_len] = c;
        clean_len += 1;
    }

    if (clean_len == 0) return null;
    const clean = clean_buf[0..clean_len];

    if (clean_len >= 2 and clean[0] == '0') {
        if (clean[1] == 'x' or clean[1] == 'X') {
            if (clean_len == 2) return null;
            return std.fmt.parseInt(i64, clean[2..], 16) catch return null;
        }
        if (clean[1] == 'b' or clean[1] == 'B') {
            if (clean_len == 2) return null;
            return std.fmt.parseInt(i64, clean[2..], 2) catch return null;
        }
        if (clean[1] == 'o' or clean[1] == 'O') {
            if (clean_len == 2) return null;
            return std.fmt.parseInt(i64, clean[2..], 8) catch return null;
        }
    }

    return std.fmt.parseInt(i64, clean, 10) catch return null;
}

fn negateValue(value: AbstractValue) AbstractValue {
    return switch (value) {
        .concrete_int => |v| blk: {
            if (v == std.math.minInt(i64)) break :blk .unknown;
            break :blk .{ .concrete_int = -v };
        },
        .int_range => |r| blk: {
            if (r.min == std.math.minInt(i64) or r.max == std.math.minInt(i64)) break :blk .unknown;
            break :blk .{ .int_range = .{ .min = -r.max, .max = -r.min } };
        },
        else => .unknown,
    };
}

fn safeAdd(a: i64, b: i64) ?i64 {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

fn safeSub(a: i64, b: i64) ?i64 {
    const result = @subWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

fn addOne(value: i64) ?i64 {
    return safeAdd(value, 1);
}

fn subOne(value: i64) ?i64 {
    return safeSub(value, 1);
}
