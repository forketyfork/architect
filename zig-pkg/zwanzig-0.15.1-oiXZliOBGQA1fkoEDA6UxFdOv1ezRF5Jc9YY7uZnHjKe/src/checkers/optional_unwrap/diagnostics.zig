const std = @import("std");
const assertions = @import("../../assertions.zig");
const checker_mod = @import("../../checker.zig");
const Diagnostic = checker_mod.Diagnostic;
const CheckerError = checker_mod.CheckerError;
const Source = @import("../../source.zig").Source;

pub fn isInsideTestAssertion(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    parent_map: []const u32,
    scope: *const assertions.AssertionScope,
) bool {
    const tags = tree.nodes.items(.tag);
    var node = unwrap_node;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;
        switch (tags[parent]) {
            .call, .call_comma, .call_one, .call_one_comma => {
                if (isTestAssertionCall(tree, parent, scope)) {
                    return true;
                }
            },
            else => {},
        }
        node = parent;
    }

    return false;
}

fn isTestAssertionCall(tree: *const std.zig.Ast, call_node: u32, scope: *const assertions.AssertionScope) bool {
    const tags = tree.nodes.items(.tag);

    if (call_node >= tags.len) return false;

    var buf: [1]std.zig.Ast.Node.Index = undefined;
    const full = tree.fullCall(&buf, @enumFromInt(call_node)) orelse return false;

    return assertions.resolveAssertionName(tree, full.ast.fn_expr, scope) != null;
}

pub fn isInsideComptimeTypeExpr(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    parent_map: []const u32,
) bool {
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    const datas = tree.nodes.items(.data);

    // First check: walk up the structural parent chain for direct containment
    var node = unwrap_node;
    var depth: u32 = 0;
    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        switch (tags[parent]) {
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                if (isComptimeTypeBuiltin(tree, parent, main_tokens)) {
                    return true;
                }
            },
            .fn_decl => {
                // Check if the unwrap is in the return type position
                const fn_proto_node = @intFromEnum(datas[parent].node_and_node[0]);
                if (fn_proto_node < tags.len and isInFnReturnType(tree, fn_proto_node, node)) {
                    return true;
                }
            },
            else => {},
        }
        node = parent;
    }

    // Second check: for expressions like `@typeInfo(...).field.?`, walk down the operand
    // chain from the unwrap to find if the root expression is a comptime type builtin
    if (unwrap_node >= tags.len) return false;
    if (tags[unwrap_node] != .unwrap_optional) return false;

    // The operand of unwrap_optional is in data[0]
    const operand = @intFromEnum(datas[unwrap_node].node_and_token[0]);
    return exprRootIsComptimeTypeBuiltin(tree, operand, tags, main_tokens, datas);
}

fn exprRootIsComptimeTypeBuiltin(
    tree: *const std.zig.Ast,
    node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    main_tokens: []const u32,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    if (node >= tags.len) return false;

    return switch (tags[node]) {
        .field_access => {
            // Field access: walk down to the object being accessed
            const obj = @intFromEnum(datas[node].node_and_token[0]);
            return exprRootIsComptimeTypeBuiltin(tree, obj, tags, main_tokens, datas);
        },
        .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
            return isComptimeTypeBuiltin(tree, node, main_tokens);
        },
        else => false,
    };
}

/// Check if a builtin call is a comptime type-related builtin
fn isComptimeTypeBuiltin(tree: *const std.zig.Ast, node: u32, main_tokens: []const u32) bool {
    if (node >= main_tokens.len) return false;
    const token = main_tokens[node];
    const builtin_name = tree.tokenSlice(token);
    return std.mem.eql(u8, builtin_name, "@typeInfo") or
        std.mem.eql(u8, builtin_name, "@TypeOf") or
        std.mem.eql(u8, builtin_name, "@Type") or
        std.mem.eql(u8, builtin_name, "@compileError");
}

/// Check if a node is in the return type position of a function prototype
fn isInFnReturnType(tree: *const std.zig.Ast, fn_proto_node: u32, target_node: u32) bool {
    const tags = tree.nodes.items(.tag);
    if (fn_proto_node >= tags.len) return false;

    // Get the full function prototype
    var buf: [1]std.zig.Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buf, @enumFromInt(fn_proto_node)) orelse return false;

    // Check if target_node is in the return type expression
    const return_type = @intFromEnum(fn_proto.ast.return_type);
    if (return_type == 0) return false;

    return isInSubtree(tree, return_type, target_node) or return_type == target_node;
}

fn isInSubtree(tree: *const std.zig.Ast, root_node: u32, target_node: u32) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (root_node == target_node) return true;
    if (root_node >= tags.len) return false;

    switch (tags[root_node]) {
        .block, .block_semicolon => {
            const extra = datas[root_node].extra_range;
            const start: usize = @intFromEnum(extra.start);
            const end: usize = @intFromEnum(extra.end);
            for (start..end) |i| {
                const stmt = tree.extra_data[i];
                if (isInSubtree(tree, stmt, target_node)) return true;
            }
        },
        .block_two, .block_two_semicolon => {
            const opt_nodes = datas[root_node].opt_node_and_opt_node;
            if (opt_nodes[0].unwrap()) |n| {
                if (isInSubtree(tree, @intFromEnum(n), target_node)) return true;
            }
            if (opt_nodes[1].unwrap()) |n| {
                if (isInSubtree(tree, @intFromEnum(n), target_node)) return true;
            }
        },
        .@"if", .if_simple => {
            const full_if = tree.fullIf(@enumFromInt(root_node)) orelse return false;
            if (isInSubtree(tree, @intFromEnum(full_if.ast.cond_expr), target_node)) return true;
            if (isInSubtree(tree, @intFromEnum(full_if.ast.then_expr), target_node)) return true;
            if (full_if.ast.else_expr.unwrap()) |else_node| {
                if (isInSubtree(tree, @intFromEnum(else_node), target_node)) return true;
            }
        },
        .@"orelse" => {
            const pair = datas[root_node].node_and_node;
            if (isInSubtree(tree, @intFromEnum(pair[0]), target_node)) return true;
            if (isInSubtree(tree, @intFromEnum(pair[1]), target_node)) return true;
        },
        else => {},
    }

    return false;
}

pub fn reportUnsafeUnwrap(
    src: *Source,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    main_token: u32,
    token_starts: []const u32,
) CheckerError!void {
    if (main_token >= token_starts.len) return;

    const unwrap_offset = token_starts[main_token];
    const loc = src.byteToLocation(unwrap_offset) catch return;
    const diag = Diagnostic.initAtLocation(
        allocator,
        src.getFilePath(),
        "optional-unwrap",
        .warning,
        "forced optional unwrap can panic at runtime",
        loc.line,
        loc.column,
    ) catch return;
    try diagnostics.append(allocator, diag);
}
