const std = @import("std");
const ids = @import("../../ids.zig");
const cfg_mod = @import("../../cfg.zig");
const Cfg = cfg_mod.Cfg;
const engine_mod = @import("../../engine.zig");
const AnalysisEngine = engine_mod.AnalysisEngine;
const ProgramState = @import("../../engine/state.zig").ProgramState;
const AbstractValue = @import("../../engine/value.zig").AbstractValue;

const DenominatorRisk = enum {
    definitely_zero,
    definitely_non_zero,
    maybe_zero,
    unknown,
};

pub fn riskWithState(
    tree: *const std.zig.Ast,
    expr_node: u32,
    state: *const ProgramState,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
) DenominatorRisk {
    if (expr_node >= tree.nodes.items(.tag).len) return .unknown;

    if (isLikelyFloatExpr(tree, expr_node, engine, cfg)) {
        return .unknown;
    }

    if (engine.resolveVarIdFromExpr(expr_node, cfg)) |var_id| {
        const var_risk = classifyVariableRisk(state, var_id);
        if (var_risk != .unknown) return var_risk;
    }

    const value = evalExpr(tree, expr_node, state, engine, cfg, 0) orelse return .unknown;
    return classifyValueRisk(value);
}

pub fn riskWithoutState(tree: *const std.zig.Ast, expr_node: u32) DenominatorRisk {
    if (expr_node >= tree.nodes.items(.tag).len) return .unknown;
    const value = evalExpr(tree, expr_node, null, null, null, 0) orelse return .unknown;
    return classifyValueRisk(value);
}

fn classifyValueRisk(value: AbstractValue) DenominatorRisk {
    return switch (value) {
        .concrete_int => |v| if (v == 0) .definitely_zero else .definitely_non_zero,
        .int_range => |r| blk: {
            if (r.min == 0 and r.max == 0) break :blk .definitely_zero;
            if (r.max < 0 or r.min > 0) break :blk .definitely_non_zero;
            break :blk .maybe_zero;
        },
        else => .unknown,
    };
}

fn classifyVariableRisk(state: *const ProgramState, var_id: ids.VarId) DenominatorRisk {
    var min_bound: i64 = std.math.minInt(i64);
    var max_bound: i64 = std.math.maxInt(i64);
    var has_bounds = false;
    var excludes_zero = false;
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
                    .ne => {
                        if (cmp.value == 0) excludes_zero = true;
                    },
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

    if (!has_bounds or impossible) return .unknown;
    if (min_bound > max_bound) return .unknown;
    if (excludes_zero and min_bound == 0 and max_bound == 0) return .unknown;
    if (min_bound == 0 and max_bound == 0) return .definitely_zero;
    if (max_bound < 0 or min_bound > 0) return .definitely_non_zero;
    if (excludes_zero) return .definitely_non_zero;
    if (min_bound <= 0 and max_bound >= 0) return .maybe_zero;
    return .definitely_non_zero;
}

fn addOne(value: i64) ?i64 {
    const result = @addWithOverflow(value, 1);
    if (result[1] != 0) return null;
    return result[0];
}

fn subOne(value: i64) ?i64 {
    const result = @subWithOverflow(value, 1);
    if (result[1] != 0) return null;
    return result[0];
}

fn evalExpr(
    tree: *const std.zig.Ast,
    expr_node: u32,
    state: ?*const ProgramState,
    engine: ?*AnalysisEngine,
    cfg: ?*const Cfg,
    depth: u8,
) ?AbstractValue {
    if (depth > 24) return null;

    const tags = tree.nodes.items(.tag);
    if (expr_node >= tags.len) return null;

    if (state != null and engine != null and cfg != null) {
        if (engine.?.resolveVarIdFromExpr(expr_node, cfg.?)) |var_id| {
            if (state.?.getVar(var_id)) |value| {
                switch (value) {
                    .concrete_int, .int_range => return value,
                    else => {},
                }
            }
        }
    }

    const datas = tree.nodes.items(.data);

    return switch (tags[expr_node]) {
        .number_literal => blk: {
            const value = parseIntLiteral(tree, expr_node) orelse break :blk null;
            break :blk .{ .concrete_int = value };
        },
        .grouped_expression, .unwrap_optional => blk: {
            const child = @intFromEnum(datas[expr_node].node_and_token[0]);
            break :blk evalExpr(tree, child, state, engine, cfg, depth + 1);
        },
        .@"try",
        .negation,
        .negation_wrap,
        => blk: {
            const child = @intFromEnum(datas[expr_node].node);
            if (tags[expr_node] == .@"try") {
                break :blk evalExpr(tree, child, state, engine, cfg, depth + 1);
            }
            const value = evalExpr(tree, child, state, engine, cfg, depth + 1) orelse break :blk null;
            break :blk negateValue(value);
        },
        .@"catch" => blk: {
            const lhs = @intFromEnum(datas[expr_node].node_and_node[0]);
            break :blk evalExpr(tree, lhs, state, engine, cfg, depth + 1);
        },
        .@"orelse" => blk: {
            const pair = datas[expr_node].node_and_node;
            const lhs = evalExpr(tree, @intFromEnum(pair[0]), state, engine, cfg, depth + 1);
            if (lhs) |known| {
                break :blk known;
            }
            break :blk evalExpr(tree, @intFromEnum(pair[1]), state, engine, cfg, depth + 1);
        },
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        => blk: {
            const pair = datas[expr_node].node_and_node;
            const lhs = evalExpr(tree, @intFromEnum(pair[0]), state, engine, cfg, depth + 1) orelse break :blk null;
            const rhs = evalExpr(tree, @intFromEnum(pair[1]), state, engine, cfg, depth + 1) orelse break :blk null;
            break :blk evalBinary(tags[expr_node], lhs, rhs);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => blk: {
            const builtin_name = builtinName(tree, expr_node) orelse break :blk null;
            var buf: [2]std.zig.Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buf, @enumFromInt(expr_node)) orelse break :blk null;
            if (std.mem.eql(u8, builtin_name, "@as")) {
                if (params.len < 2) break :blk null;
                if (isLikelyFloatTypeExpr(tree, @intFromEnum(params[0]))) {
                    break :blk null;
                }
                break :blk evalExpr(tree, @intFromEnum(params[1]), state, engine, cfg, depth + 1);
            }
            break :blk null;
        },
        else => null,
    };
}

fn negateValue(value: AbstractValue) ?AbstractValue {
    return switch (value) {
        .concrete_int => |v| blk: {
            if (v == std.math.minInt(i64)) break :blk null;
            break :blk .{ .concrete_int = -v };
        },
        .int_range => |r| blk: {
            if (r.min == std.math.minInt(i64) or r.max == std.math.minInt(i64)) break :blk null;
            break :blk .{ .int_range = .{ .min = -r.max, .max = -r.min } };
        },
        else => null,
    };
}

fn evalBinary(tag: std.zig.Ast.Node.Tag, lhs: AbstractValue, rhs: AbstractValue) ?AbstractValue {
    if (lhs.toConcreteInt()) |l| {
        if (rhs.toConcreteInt()) |r| {
            return evalConcreteBinary(tag, l, r);
        }
    }

    const lhs_range = toIntRange(lhs) orelse return null;
    const rhs_range = toIntRange(rhs) orelse return null;
    return evalRangeBinary(tag, lhs_range, rhs_range);
}

fn toIntRange(value: AbstractValue) ?AbstractValue.IntRange {
    return switch (value) {
        .concrete_int => |v| AbstractValue.IntRange.single(v),
        .int_range => |r| r,
        else => null,
    };
}

fn evalConcreteBinary(tag: std.zig.Ast.Node.Tag, lhs: i64, rhs: i64) ?AbstractValue {
    return switch (tag) {
        .add => blk: {
            const result = @addWithOverflow(lhs, rhs);
            if (result[1] != 0) break :blk null;
            break :blk .{ .concrete_int = result[0] };
        },
        .sub => blk: {
            const result = @subWithOverflow(lhs, rhs);
            if (result[1] != 0) break :blk null;
            break :blk .{ .concrete_int = result[0] };
        },
        .mul => blk: {
            const result = @mulWithOverflow(lhs, rhs);
            if (result[1] != 0) break :blk null;
            break :blk .{ .concrete_int = result[0] };
        },
        .div => blk: {
            if (rhs == 0) break :blk null;
            if (lhs == std.math.minInt(i64) and rhs == -1) break :blk null;
            break :blk .{ .concrete_int = @divTrunc(lhs, rhs) };
        },
        .mod => blk: {
            if (rhs == 0) break :blk null;
            break :blk .{ .concrete_int = @mod(lhs, rhs) };
        },
        else => null,
    };
}

fn evalRangeBinary(
    tag: std.zig.Ast.Node.Tag,
    lhs: AbstractValue.IntRange,
    rhs: AbstractValue.IntRange,
) ?AbstractValue {
    return switch (tag) {
        .add => blk: {
            const min_sum = safeAdd(lhs.min, rhs.min) orelse break :blk null;
            const max_sum = safeAdd(lhs.max, rhs.max) orelse break :blk null;
            break :blk .{ .int_range = .{ .min = min_sum, .max = max_sum } };
        },
        .sub => blk: {
            const min_diff = safeSub(lhs.min, rhs.max) orelse break :blk null;
            const max_diff = safeSub(lhs.max, rhs.min) orelse break :blk null;
            break :blk .{ .int_range = .{ .min = min_diff, .max = max_diff } };
        },
        .mul => blk: {
            const products = [_]?i64{
                safeMul(lhs.min, rhs.min),
                safeMul(lhs.min, rhs.max),
                safeMul(lhs.max, rhs.min),
                safeMul(lhs.max, rhs.max),
            };
            var min_val: ?i64 = null;
            var max_val: ?i64 = null;
            for (products) |item| {
                const v = item orelse break :blk null;
                min_val = if (min_val) |existing| @min(existing, v) else v;
                max_val = if (max_val) |existing| @max(existing, v) else v;
            }
            break :blk .{ .int_range = .{ .min = min_val.?, .max = max_val.? } };
        },
        .div => blk: {
            if (rhs.contains(0)) break :blk null;
            if (lhs.min == lhs.max and rhs.min == rhs.max) {
                if (lhs.min == std.math.minInt(i64) and rhs.min == -1) break :blk null;
                break :blk .{ .concrete_int = @divTrunc(lhs.min, rhs.min) };
            }
            break :blk null;
        },
        .mod => blk: {
            if (rhs.contains(0)) break :blk null;
            if (lhs.min == lhs.max and rhs.min == rhs.max) {
                break :blk .{ .concrete_int = @mod(lhs.min, rhs.min) };
            }
            break :blk null;
        },
        else => null,
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

fn safeMul(a: i64, b: i64) ?i64 {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
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
            return std.fmt.parseInt(i64, clean[2..], 16) catch |err| switch (err) {
                error.InvalidCharacter, error.Overflow => return null,
            };
        }
        if (clean[1] == 'b' or clean[1] == 'B') {
            if (clean_len == 2) return null;
            return std.fmt.parseInt(i64, clean[2..], 2) catch |err| switch (err) {
                error.InvalidCharacter, error.Overflow => return null,
            };
        }
        if (clean[1] == 'o' or clean[1] == 'O') {
            if (clean_len == 2) return null;
            return std.fmt.parseInt(i64, clean[2..], 8) catch |err| switch (err) {
                error.InvalidCharacter, error.Overflow => return null,
            };
        }
    }

    return std.fmt.parseInt(i64, clean, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return null,
    };
}

fn isLikelyFloatExpr(
    tree: *const std.zig.Ast,
    expr_node: u32,
    engine: *AnalysisEngine,
    cfg: *const Cfg,
) bool {
    const tags = tree.nodes.items(.tag);
    if (expr_node >= tags.len) return false;
    if (tags[expr_node] != .identifier) return false;

    if (engine.resolveDeclInfoFromIdentifier(expr_node, cfg)) |decl_info| {
        return isLikelyFloatDecl(tree, decl_info.decl_node);
    }

    return false;
}

fn isLikelyFloatDecl(tree: *const std.zig.Ast, decl_node: u32) bool {
    const full = tree.fullVarDecl(@enumFromInt(decl_node)) orelse return false;

    if (full.ast.type_node.unwrap()) |type_node| {
        if (isLikelyFloatTypeExpr(tree, @intFromEnum(type_node))) {
            return true;
        }
    }

    if (full.ast.init_node.unwrap()) |init_node| {
        if (isFloatLiteralNode(tree, @intFromEnum(init_node))) {
            return true;
        }
    }

    return false;
}

fn isLikelyFloatTypeExpr(tree: *const std.zig.Ast, node: u32) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len) return false;

    return switch (tags[node]) {
        .identifier => blk: {
            const token = tree.nodes.items(.main_token)[node];
            const name = tree.tokenSlice(token);
            break :blk std.mem.eql(u8, name, "f16") or
                std.mem.eql(u8, name, "f32") or
                std.mem.eql(u8, name, "f64") or
                std.mem.eql(u8, name, "f80") or
                std.mem.eql(u8, name, "f128") or
                std.mem.eql(u8, name, "comptime_float") or
                std.mem.eql(u8, name, "anyfloat");
        },
        .optional_type,
        .address_of,
        => blk: {
            const child = @intFromEnum(tree.nodes.items(.data)[node].node);
            break :blk isLikelyFloatTypeExpr(tree, child);
        },
        .grouped_expression => blk: {
            const child = @intFromEnum(tree.nodes.items(.data)[node].node_and_token[0]);
            break :blk isLikelyFloatTypeExpr(tree, child);
        },
        else => false,
    };
}

fn isFloatLiteralNode(tree: *const std.zig.Ast, node: u32) bool {
    const tags = tree.nodes.items(.tag);
    if (node >= tags.len or tags[node] != .number_literal) return false;
    const token = tree.nodes.items(.main_token)[node];
    const text = tree.tokenSlice(token);
    for (text) |c| {
        if (c == '.' or c == 'e' or c == 'E' or c == 'p' or c == 'P') return true;
    }
    return false;
}
