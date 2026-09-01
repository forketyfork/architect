const std = @import("std");
const checker_mod = @import("../checker.zig");
const Checker = checker_mod.Checker;
const CheckerError = checker_mod.CheckerError;
const Diagnostic = checker_mod.Diagnostic;
const SourceRange = checker_mod.SourceRange;
const Source = @import("../source.zig").Source;
const value = @import("../engine/value.zig");

/// Engine-based checker that detects unreachable code using CFG and exploded graph reachability.
///
/// This checker handles path-sensitive unreachable code detection:
/// - Code inside `if (false)` or `while (false)` blocks
/// - Code inside branches that are never taken due to constant conditions
///
/// It complements the AST-based unreachable-code rule which handles:
/// - Code after return statements
/// - Code after fully-terminating branches
///
/// The checker is conservative: it only reports code as unreachable when the
/// condition is a compile-time constant.
pub const UnreachableCodeChecker = struct {
    pub const checker: Checker = .{
        .name = "unreachable-code-engine",
        .default_severity = .warning,
        .checkAstFn = checkAst,
    };

    fn checkAst(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: checker_mod.CheckerContext,
    ) CheckerError!void {
        _ = context;
        const tree = src.ast() catch return;
        const tags = tree.nodes.items(.tag);

        for (0..tags.len) |i| {
            const tag = tags[i];
            if (tag == .@"if" or tag == .if_simple) {
                try checkIfStatement(src, allocator, diagnostics, @intCast(i));
            } else if (tag == .while_simple or tag == .while_cont or tag == .@"while") {
                try checkWhileStatement(src, allocator, diagnostics, @intCast(i));
            }
        }
    }

    fn checkIfStatement(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        if_node: u32,
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const full_if = tree.fullIf(@enumFromInt(if_node)) orelse return;

        const cond_node: u32 = @intFromEnum(full_if.ast.cond_expr);
        const cond_value = evaluateConditionValue(tree, cond_node);

        if (cond_value) |is_true| {
            if (is_true) {
                if (full_if.ast.else_expr.unwrap()) |else_expr| {
                    const else_node: u32 = @intFromEnum(else_expr);
                    const range = getNodeRange(src, else_node) catch return;
                    if (range) |r| {
                        const diag = Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "unreachable-code-engine",
                            .warning,
                            "unreachable code: else branch is never executed because condition is always true",
                            r,
                        ) catch return;
                        try diagnostics.append(allocator, diag);
                    }
                }
            } else {
                const then_node: u32 = @intFromEnum(full_if.ast.then_expr);
                const range = getNodeRange(src, then_node) catch return;
                if (range) |r| {
                    const diag = Diagnostic.init(
                        allocator,
                        src.getFilePath(),
                        "unreachable-code-engine",
                        .warning,
                        "unreachable code: if body is never executed because condition is always false",
                        r,
                    ) catch return;
                    try diagnostics.append(allocator, diag);
                }
            }
        }
    }

    fn checkWhileStatement(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        while_node: u32,
    ) CheckerError!void {
        const tree = src.ast() catch return;
        const full_while = tree.fullWhile(@enumFromInt(while_node)) orelse return;

        const cond_node: u32 = @intFromEnum(full_while.ast.cond_expr);
        const cond_value = evaluateConditionValue(tree, cond_node);

        if (cond_value) |is_true| {
            if (!is_true) {
                const body_node: u32 = @intFromEnum(full_while.ast.then_expr);
                const range = getNodeRange(src, body_node) catch return;
                if (range) |r| {
                    const diag = Diagnostic.init(
                        allocator,
                        src.getFilePath(),
                        "unreachable-code-engine",
                        .warning,
                        "unreachable code: while body is never executed because condition is always false",
                        r,
                    ) catch return;
                    try diagnostics.append(allocator, diag);
                }
            }
        }
    }

    fn evaluateConditionValue(tree: *const std.zig.Ast, cond_node: u32) ?bool {
        return evaluateConstBool(tree, cond_node, 0);
    }

    fn evaluateConstBool(tree: *const std.zig.Ast, node: u32, depth: u8) ?bool {
        if (depth > 8) return null;

        if (value.evaluateBoolLiteral(tree, node)) |literal| {
            return literal;
        }

        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;
        const tag = tags[node];
        const datas = tree.nodes.items(.data);

        return switch (tag) {
            .identifier => blk: {
                const init_node = resolveConstInitNode(tree, node) orelse break :blk null;
                break :blk evaluateConstBool(tree, init_node, depth + 1);
            },
            .grouped_expression => blk: {
                const child = @intFromEnum(datas[node].node_and_token[0]);
                if (child == 0) break :blk null;
                break :blk evaluateConstBool(tree, child, depth + 1);
            },
            .bool_not => blk: {
                const child = @intFromEnum(datas[node].node);
                if (child == 0) break :blk null;
                const child_val = evaluateConstBool(tree, child, depth + 1) orelse break :blk null;
                break :blk !child_val;
            },
            .bool_and, .bool_or => blk: {
                const pair = datas[node].node_and_node;
                const lhs = @intFromEnum(pair[0]);
                const rhs = @intFromEnum(pair[1]);
                const lhs_val = evaluateConstBool(tree, lhs, depth + 1);
                if (lhs_val) |val| {
                    if (tag == .bool_and and !val) break :blk false;
                    if (tag == .bool_or and val) break :blk true;
                }
                const rhs_val = evaluateConstBool(tree, rhs, depth + 1);
                if (rhs_val) |val| {
                    if (tag == .bool_and and !val) break :blk false;
                    if (tag == .bool_or and val) break :blk true;
                }
                if (lhs_val == null or rhs_val == null) break :blk null;
                if (tag == .bool_and) break :blk lhs_val.? and rhs_val.?;
                break :blk lhs_val.? or rhs_val.?;
            },
            .equal_equal, .bang_equal => blk: {
                const pair = datas[node].node_and_node;
                const lhs = @intFromEnum(pair[0]);
                const rhs = @intFromEnum(pair[1]);

                if (evaluateConstInt(tree, lhs, depth + 1)) |lhs_int| {
                    if (evaluateConstInt(tree, rhs, depth + 1)) |rhs_int| {
                        const eq = lhs_int == rhs_int;
                        break :blk if (tag == .equal_equal) eq else !eq;
                    }
                }

                const lhs_bool = evaluateConstBool(tree, lhs, depth + 1) orelse break :blk null;
                const rhs_bool = evaluateConstBool(tree, rhs, depth + 1) orelse break :blk null;
                const eq = lhs_bool == rhs_bool;
                break :blk if (tag == .equal_equal) eq else !eq;
            },
            .less_than, .less_or_equal, .greater_than, .greater_or_equal => blk: {
                const pair = datas[node].node_and_node;
                const lhs = @intFromEnum(pair[0]);
                const rhs = @intFromEnum(pair[1]);
                const lhs_int = evaluateConstInt(tree, lhs, depth + 1) orelse break :blk null;
                const rhs_int = evaluateConstInt(tree, rhs, depth + 1) orelse break :blk null;
                break :blk switch (tag) {
                    .less_than => lhs_int < rhs_int,
                    .less_or_equal => lhs_int <= rhs_int,
                    .greater_than => lhs_int > rhs_int,
                    .greater_or_equal => lhs_int >= rhs_int,
                    else => null,
                };
            },
            else => null,
        };
    }

    fn evaluateConstInt(tree: *const std.zig.Ast, node: u32, depth: u8) ?i64 {
        if (depth > 8) return null;

        if (parseIntLiteral(tree, node)) |literal| {
            return literal;
        }

        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;
        const tag = tags[node];
        const datas = tree.nodes.items(.data);

        return switch (tag) {
            .identifier => blk: {
                const init_node = resolveConstInitNode(tree, node) orelse break :blk null;
                break :blk evaluateConstInt(tree, init_node, depth + 1);
            },
            .grouped_expression => blk: {
                const child = @intFromEnum(datas[node].node_and_token[0]);
                if (child == 0) break :blk null;
                break :blk evaluateConstInt(tree, child, depth + 1);
            },
            .negation => blk: {
                const child = @intFromEnum(datas[node].node);
                if (child == 0) break :blk null;
                const child_val = evaluateConstInt(tree, child, depth + 1) orelse break :blk null;
                if (child_val == std.math.minInt(i64)) break :blk null;
                break :blk -child_val;
            },
            .add, .sub, .mul, .div, .mod => blk: {
                const pair = datas[node].node_and_node;
                const lhs = @intFromEnum(pair[0]);
                const rhs = @intFromEnum(pair[1]);
                const lhs_val = evaluateConstInt(tree, lhs, depth + 1) orelse break :blk null;
                const rhs_val = evaluateConstInt(tree, rhs, depth + 1) orelse break :blk null;

                break :blk switch (tag) {
                    .add => blk_add: {
                        const sum = @addWithOverflow(lhs_val, rhs_val);
                        if (sum[1] != 0) break :blk_add null;
                        break :blk_add sum[0];
                    },
                    .sub => blk_sub: {
                        const diff = @subWithOverflow(lhs_val, rhs_val);
                        if (diff[1] != 0) break :blk_sub null;
                        break :blk_sub diff[0];
                    },
                    .mul => blk_mul: {
                        const prod = @mulWithOverflow(lhs_val, rhs_val);
                        if (prod[1] != 0) break :blk_mul null;
                        break :blk_mul prod[0];
                    },
                    .div => if (rhs_val == 0) null else @divTrunc(lhs_val, rhs_val),
                    .mod => if (rhs_val == 0) null else @mod(lhs_val, rhs_val),
                    else => null,
                };
            },
            else => null,
        };
    }

    fn resolveConstInitNode(tree: *const std.zig.Ast, ident_node: u32) ?u32 {
        const tags = tree.nodes.items(.tag);
        if (ident_node >= tags.len) return null;
        if (tags[ident_node] != .identifier) return null;

        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);
        const ident_token = main_tokens[ident_node];
        if (ident_token >= token_tags.len) return null;
        if (token_tags[ident_token] != .identifier) return null;
        const ident_name = tree.tokenSlice(ident_token);

        var i: usize = ident_node;
        while (i > 0) {
            i -= 1;
            const node_tag = tags[i];
            if (node_tag == .fn_decl) break;
            if (node_tag != .simple_var_decl and node_tag != .local_var_decl) continue;

            const var_decl = tree.fullVarDecl(@enumFromInt(@as(u32, @intCast(i)))) orelse continue;
            const decl_token = tree.tokens.items(.tag)[var_decl.ast.mut_token];
            if (decl_token != .keyword_const) continue;

            const name_token = var_decl.ast.mut_token + 1;
            if (name_token >= tree.tokens.items(.start).len) continue;
            const decl_name = tree.tokenSlice(name_token);
            if (!std.mem.eql(u8, ident_name, decl_name)) continue;

            const init_node = var_decl.ast.init_node.unwrap() orelse continue;
            return @intFromEnum(init_node);
        }

        return null;
    }

    fn parseIntLiteral(tree: *const std.zig.Ast, node: u32) ?i64 {
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;
        if (tags[node] != .number_literal) return null;

        const main_tokens = tree.nodes.items(.main_token);
        const token = main_tokens[node];
        const token_str = tree.tokenSlice(token);
        if (token_str.len == 0) return null;

        for (token_str) |c| {
            if (c == '.' or c == 'e' or c == 'E' or c == 'p' or c == 'P') return null;
            if (!std.ascii.isDigit(c) and c != '_' and c != 'x' and c != 'X' and
                c != 'b' and c != 'B' and c != 'o' and c != 'O' and
                !(c >= 'a' and c <= 'f') and !(c >= 'A' and c <= 'F'))
            {
                return null;
            }
        }

        var clean_buf: [64]u8 = undefined;
        var clean_len: usize = 0;
        for (token_str) |c| {
            if (c == '_') continue;
            if (clean_len >= clean_buf.len) return null;
            clean_buf[clean_len] = c;
            clean_len += 1;
        }
        if (clean_len == 0) return null;

        const clean_str = clean_buf[0..clean_len];
        var digits = clean_str;
        var base: i64 = 10;
        if (clean_len >= 2 and clean_buf[0] == '0') {
            if (clean_buf[1] == 'x' or clean_buf[1] == 'X') {
                base = 16;
                digits = clean_str[2..];
            } else if (clean_buf[1] == 'b' or clean_buf[1] == 'B') {
                base = 2;
                digits = clean_str[2..];
            } else if (clean_buf[1] == 'o' or clean_buf[1] == 'O') {
                base = 8;
                digits = clean_str[2..];
            }
        }
        if (digits.len == 0) return null;

        var result: i64 = 0;
        for (digits) |c| {
            const digit: i64 = switch (c) {
                '0'...'9' => @intCast(c - '0'),
                'a'...'f' => @intCast(10 + (c - 'a')),
                'A'...'F' => @intCast(10 + (c - 'A')),
                else => return null,
            };
            if (digit >= base) return null;
            const mul = @mulWithOverflow(result, base);
            if (mul[1] != 0) return null;
            const sum = @addWithOverflow(mul[0], digit);
            if (sum[1] != 0) return null;
            result = sum[0];
        }
        return result;
    }

    fn getNodeRange(src: *Source, node: u32) !?SourceRange {
        const tree = src.ast() catch return null;
        const main_tokens = tree.nodes.items(.main_token);
        const token_starts = tree.tokens.items(.start);

        if (node >= main_tokens.len) return null;

        const first_token = tree.firstToken(@enumFromInt(node));
        const last_token = tree.lastToken(@enumFromInt(node));

        if (first_token >= token_starts.len or last_token >= token_starts.len) return null;

        const start_byte = token_starts[first_token];
        const end_byte = token_starts[last_token] + tokenLen(tree, last_token);

        return src.byteRangeToSourceRange(start_byte, end_byte) catch return null;
    }

    fn tokenLen(tree: *const std.zig.Ast, token: u32) u32 {
        const token_starts = tree.tokens.items(.start);
        const token_tags = tree.tokens.items(.tag);

        if (token + 1 < token_starts.len) {
            return token_starts[token + 1] - token_starts[token];
        }

        const tag = token_tags[token];
        return switch (tag) {
            .identifier => blk: {
                const start = token_starts[token];
                var len: u32 = 0;
                const source = tree.source;
                while (start + len < source.len) {
                    const c = source[start + len];
                    if (!std.ascii.isAlphanumeric(c) and c != '_') break;
                    len += 1;
                }
                break :blk len;
            },
            else => 1,
        };
    }
};

test "unreachable_code_engine - detects if(false) body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    if (false) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - detects if(true) else branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    if (true) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - detects while(false) body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    while (false) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - no diagnostic for runtime condition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: bool) i32 {
        \\    if (x) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unreachable_code_engine - no diagnostic for empty function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unreachable_code_engine - no diagnostic for while(true) as it's a legitimate infinite loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() noreturn {
        \\    while (true) {}
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unreachable_code_engine - detects nested if(false)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: bool) i32 {
        \\    if (x) {
        \\        if (false) {
        \\            return 1;
        \\        }
        \\        return 2;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "unreachable_code_engine - no false positive for identifiers starting with true/false" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(trueValue: bool) i32 {
        \\    if (trueValue) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn bar(falsey: bool) i32 {
        \\    if (falsey) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "unreachable_code_engine - detects const flag false" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const debug = false;
        \\    if (debug) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - detects const flag true else branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const enabled = true;
        \\    if (enabled) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("unreachable-code-engine", diagnostics.items[0].rule_id);
}

test "unreachable_code_engine - no warning for var flag (may be reassigned)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(cond: bool) i32 {
        \\    var flag = true;
        \\    if (cond) flag = false;
        \\    if (flag) return 1;
        \\    return 0;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |diag| allocator.free(@constCast(diag.message));

    const context = checker_mod.CheckerContext{ .build_metadata = null };
    try UnreachableCodeChecker.checker.checkAst(&source, allocator, &diagnostics, context);

    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
