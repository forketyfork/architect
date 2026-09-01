const std = @import("std");
const ast_walk = @import("../../ast_walk.zig");
const call_utils = @import("../../analysis/call_utils.zig");
const ids = @import("../../ids.zig");

pub fn isGuardedByLazyInit(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    unwrapped_var: u32,
    parent_map: []const u32,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    // Find the containing block
    var node = unwrap_node;
    var block_node: ?u32 = null;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        if (tags[parent] == .block or tags[parent] == .block_two or
            tags[parent] == .block_two_semicolon)
        {
            block_node = parent;
            break;
        }
        node = parent;
    }

    const block = block_node orelse return false;

    // Scan the block for lazy init pattern
    return scanBlockForLazyInit(tree, block, unwrap_node, unwrapped_var, tags, datas, main_tokens, token_starts);
}

fn scanBlockForLazyInit(
    tree: *const std.zig.Ast,
    block: u32,
    unwrap_node: u32,
    unwrapped_var: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
    token_starts: []const u32,
) bool {
    if (block >= tags.len) return false;

    // Get position of the unwrap node
    if (unwrap_node >= main_tokens.len) return false;
    const unwrap_pos = token_starts[main_tokens[unwrap_node]];

    // Get statements from the block
    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(tree, block, &stmts_buf) orelse return false;

    // Look for an if statement before the unwrap that initializes the variable
    for (stmts_buf[0..stmt_count]) |stmt| {
        if (stmt >= tags.len) continue;
        if (stmt >= main_tokens.len) continue;

        const stmt_pos = token_starts[main_tokens[stmt]];

        // Only look at statements before the unwrap
        if (stmt_pos >= unwrap_pos) continue;

        // Check if this is an if statement
        if (tags[stmt] != .@"if" and tags[stmt] != .if_simple) continue;

        // Check if the condition is `var == null`
        const full = tree.fullIf(@enumFromInt(stmt)) orelse continue;
        const cond = @intFromEnum(full.ast.cond_expr);

        if (!checksNull(tree, cond, unwrapped_var)) continue;

        // Check if the then branch assigns to the variable
        const then_expr = @intFromEnum(full.ast.then_expr);
        if (assignsToVariable(tree, then_expr, unwrapped_var, tags, datas)) {
            return true;
        }
    }

    return false;
}

fn assignsToVariable(
    tree: *const std.zig.Ast,
    node: u32,
    var_node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    if (node >= tags.len) return false;

    switch (tags[node]) {
        .assign => {
            const lhs = @intFromEnum(datas[node].node_and_node[0]);
            return sameVariable(tree, lhs, var_node);
        },
        .block, .block_semicolon => {
            const extra = datas[node].extra_range;
            const start: usize = @intFromEnum(extra.start);
            const end: usize = @intFromEnum(extra.end);
            for (start..end) |i| {
                const stmt = tree.extra_data[i];
                if (assignsToVariable(tree, stmt, var_node, tags, datas)) {
                    return true;
                }
            }
            return false;
        },
        .block_two, .block_two_semicolon => {
            const opt_nodes = datas[node].opt_node_and_opt_node;
            if (opt_nodes[0].unwrap()) |n| {
                if (assignsToVariable(tree, @intFromEnum(n), var_node, tags, datas)) {
                    return true;
                }
            }
            if (opt_nodes[1].unwrap()) |n| {
                if (assignsToVariable(tree, @intFromEnum(n), var_node, tags, datas)) {
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

pub fn isGuardedByEarlyExit(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    unwrapped_var: u32,
    parent_map: []const u32,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    // Find the containing block (could be loop body or function body)
    var node = unwrap_node;
    var block_node: ?u32 = null;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        if (tags[parent] == .block or tags[parent] == .block_two or
            tags[parent] == .block_semicolon or tags[parent] == .block_two_semicolon)
        {
            block_node = parent;
            break;
        }
        node = parent;
    }

    const block = block_node orelse return false;

    // Scan the block for early exit pattern
    return scanBlockForEarlyExit(tree, block, unwrap_node, unwrapped_var, tags, datas, main_tokens, token_starts);
}

pub fn isGuardedBySwitchNullCase(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    unwrapped_var: u32,
    parent_map: []const u32,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    // Find the containing block (could be loop body or function body)
    var node = unwrap_node;
    var block_node: ?u32 = null;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        if (tags[parent] == .block or tags[parent] == .block_two or
            tags[parent] == .block_semicolon or tags[parent] == .block_two_semicolon)
        {
            block_node = parent;
            break;
        }
        node = parent;
    }

    const block = block_node orelse return false;

    return scanBlockForSwitchNullCase(tree, block, unwrap_node, unwrapped_var, tags, datas, main_tokens, token_starts);
}

fn scanBlockForEarlyExit(
    tree: *const std.zig.Ast,
    block: u32,
    unwrap_node: u32,
    unwrapped_var: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
    token_starts: []const u32,
) bool {
    if (block >= tags.len) return false;

    // Get position of the unwrap node
    if (unwrap_node >= main_tokens.len) return false;
    const unwrap_pos = token_starts[main_tokens[unwrap_node]];

    // Get statements from the block
    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(tree, block, &stmts_buf) orelse return false;

    // Look for an if statement before the unwrap that exits on null
    for (stmts_buf[0..stmt_count]) |stmt| {
        if (stmt >= tags.len) continue;
        if (stmt >= main_tokens.len) continue;

        const stmt_pos = token_starts[main_tokens[stmt]];

        // Only look at statements before the unwrap
        if (stmt_pos >= unwrap_pos) continue;

        // Check if this is an if statement
        if (tags[stmt] != .@"if" and tags[stmt] != .if_simple) continue;

        // Check if the condition is `var == null`
        const full = tree.fullIf(@enumFromInt(stmt)) orelse continue;
        const cond = @intFromEnum(full.ast.cond_expr);

        if (!checksNull(tree, cond, unwrapped_var)) continue;

        // Check if the then branch is an early exit (continue, break, return)
        const then_expr = @intFromEnum(full.ast.then_expr);
        if (isEarlyExitExpr(tree, then_expr, tags, datas)) {
            return true;
        }
    }

    return false;
}

fn scanBlockForSwitchNullCase(
    tree: *const std.zig.Ast,
    block: u32,
    unwrap_node: u32,
    unwrapped_var: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
    token_starts: []const u32,
) bool {
    if (block >= tags.len) return false;

    if (unwrap_node >= main_tokens.len) return false;
    const unwrap_pos = token_starts[main_tokens[unwrap_node]];

    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(tree, block, &stmts_buf) orelse return false;

    for (stmts_buf[0..stmt_count]) |stmt| {
        if (stmt >= tags.len) continue;
        if (stmt >= main_tokens.len) continue;

        const stmt_pos = token_starts[main_tokens[stmt]];
        if (stmt_pos >= unwrap_pos) continue;

        if (tags[stmt] != .@"switch" and tags[stmt] != .switch_comma) continue;

        const full_switch = tree.switchFull(@enumFromInt(stmt));
        const cond = @intFromEnum(full_switch.ast.condition);
        if (!sameVariable(tree, cond, unwrapped_var)) continue;

        if (switchHasNullCaseEarlyExit(tree, stmt, tags, datas)) {
            return true;
        }
    }

    return false;
}

fn switchHasNullCaseEarlyExit(
    tree: *const std.zig.Ast,
    switch_node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    const full_switch = tree.switchFull(@enumFromInt(switch_node));
    for (full_switch.ast.cases) |case_node| {
        const full_case = tree.fullSwitchCase(case_node) orelse continue;
        if (!caseHasNullValue(tree, full_case)) continue;

        const target_expr = @intFromEnum(full_case.ast.target_expr);
        if (isEarlyExitExpr(tree, target_expr, tags, datas)) {
            return true;
        }
    }

    return false;
}

fn caseHasNullValue(
    tree: *const std.zig.Ast,
    full_case: std.zig.Ast.full.SwitchCase,
) bool {
    for (full_case.ast.values) |value| {
        if (isNullIdentifier(tree, @intFromEnum(value))) {
            return true;
        }
    }
    return false;
}

fn isEarlyExitExpr(
    tree: *const std.zig.Ast,
    node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    if (node >= tags.len) return false;

    return switch (tags[node]) {
        .@"continue", .@"break", .@"return" => true,
        // Handle blocks that contain a single early exit statement
        .block, .block_semicolon => {
            const extra = datas[node].extra_range;
            const start: usize = @intFromEnum(extra.start);
            const end: usize = @intFromEnum(extra.end);
            if (end > start) {
                // Check if any statement in the block is an early exit
                for (start..end) |i| {
                    const stmt = tree.extra_data[i];
                    if (stmt < tags.len) {
                        switch (tags[stmt]) {
                            .@"continue", .@"break", .@"return" => return true,
                            else => {},
                        }
                    }
                }
            }
            return false;
        },
        .block_two, .block_two_semicolon => {
            const opt_nodes = datas[node].opt_node_and_opt_node;
            if (opt_nodes[0].unwrap()) |n| {
                const n_idx = @intFromEnum(n);
                if (n_idx < tags.len) {
                    switch (tags[n_idx]) {
                        .@"continue", .@"break", .@"return" => return true,
                        else => {},
                    }
                }
            }
            if (opt_nodes[1].unwrap()) |n| {
                const n_idx = @intFromEnum(n);
                if (n_idx < tags.len) {
                    switch (tags[n_idx]) {
                        .@"continue", .@"break", .@"return" => return true,
                        else => {},
                    }
                }
            }
            return false;
        },
        else => false,
    };
}

pub fn isGuardedByPriorAssignment(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    unwrapped_var: u32,
    parent_map: []const u32,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    // Find the containing block
    var node = unwrap_node;
    var block_node: ?u32 = null;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        if (tags[parent] == .block or tags[parent] == .block_two or
            tags[parent] == .block_semicolon or tags[parent] == .block_two_semicolon)
        {
            block_node = parent;
            break;
        }
        node = parent;
    }

    const block = block_node orelse return false;

    return scanBlockForPriorAssignment(tree, block, unwrap_node, unwrapped_var, tags, datas, main_tokens, token_starts);
}

fn scanBlockForPriorAssignment(
    tree: *const std.zig.Ast,
    block: u32,
    unwrap_node: u32,
    unwrapped_var: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
    token_starts: []const u32,
) bool {
    if (block >= tags.len) return false;

    // Get position of the unwrap node
    if (unwrap_node >= main_tokens.len) return false;
    const unwrap_pos = token_starts[main_tokens[unwrap_node]];

    // Get statements from the block
    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(tree, block, &stmts_buf) orelse return false;

    // Look for an assignment statement before the unwrap
    // Start from the statement closest to the unwrap and work backwards
    var i: usize = stmt_count;
    while (i > 0) {
        i -= 1;
        const stmt = stmts_buf[i];
        if (stmt >= tags.len) continue;
        if (stmt >= main_tokens.len) continue;

        const stmt_pos = token_starts[main_tokens[stmt]];

        // Only look at statements before the unwrap
        if (stmt_pos >= unwrap_pos) continue;

        // Check if this is an assignment to the variable
        if (tags[stmt] == .assign) {
            const lhs = @intFromEnum(datas[stmt].node_and_node[0]);
            const rhs = @intFromEnum(datas[stmt].node_and_node[1]);

            if (sameVariable(tree, lhs, unwrapped_var)) {
                // Check if RHS is an orelse with early exit
                if (isOrelseWithEarlyExit(rhs, tags, datas)) {
                    return true;
                }
                // Check if RHS is a try expression - try only succeeds with non-null value
                if (rhs < tags.len and tags[rhs] == .@"try") {
                    return true;
                }
                // Check if RHS is an identifier that was assigned via `try` earlier
                if (isNonNullIdentifier(tree, rhs, block, stmt_pos, tags, datas, main_tokens, token_starts)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn isOrelseWithEarlyExit(
    node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    if (node >= tags.len) return false;

    // Check for orelse expression
    if (tags[node] != .@"orelse") return false;

    // The RHS of orelse is in data[1]
    const rhs = @intFromEnum(datas[node].node_and_node[1]);
    if (rhs >= tags.len) return false;

    // Check if the RHS is an early exit
    return switch (tags[rhs]) {
        .@"return" => true,
        .@"break" => true,
        .@"continue" => true,
        // Also handle error_value for `orelse return error.Foo`
        .error_value => true,
        else => false,
    };
}

fn isNonNullIdentifier(
    tree: *const std.zig.Ast,
    node: u32,
    block: u32,
    use_pos: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
    token_starts: []const u32,
) bool {
    if (node >= tags.len) return false;

    // The node must be an identifier
    if (tags[node] != .identifier) return false;

    // Get the identifier's token text
    const ident_token = main_tokens[node];
    const ident_text = tree.tokenSlice(ident_token);

    // Scan the block for a prior declaration of this identifier with `try` or `orelse`
    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(tree, block, &stmts_buf) orelse return false;

    for (0..stmt_count) |idx| {
        const stmt = stmts_buf[idx];
        if (stmt >= tags.len or stmt >= main_tokens.len) continue;

        const stmt_pos = token_starts[main_tokens[stmt]];
        if (stmt_pos >= use_pos) break; // Only look at statements before the use

        // Check for var decls: `var x = ...` or `const x = ...`
        if (tags[stmt] == .simple_var_decl or tags[stmt] == .local_var_decl or
            tags[stmt] == .aligned_var_decl)
        {
            // Use fullVarDecl to get the name token and init node
            const full = tree.fullVarDecl(@enumFromInt(stmt)) orelse continue;
            const name_token = full.ast.mut_token + 1;
            const token_tags = tree.tokens.items(.tag);
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
            const decl_name = tree.tokenSlice(name_token);
            if (std.mem.eql(u8, decl_name, ident_text)) {
                const init_node = @intFromEnum(full.ast.init_node);
                if (init_node != 0 and init_node < tags.len) {
                    if (tags[init_node] == .@"try") {
                        return true;
                    }
                    // Check for orelse with early exit
                    if (isOrelseWithEarlyExit(init_node, tags, datas)) {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

pub fn isGuardedByMethodCallWithCatch(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    unwrapped_var: u32,
    parent_map: []const u32,
    fn_node: ids.AstNodeId,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    // First, check if the unwrapped variable is a field access on self (e.g., self.texture)
    if (unwrapped_var >= tags.len) return false;
    if (tags[unwrapped_var] != .field_access) return false;

    // Get the object being accessed and the field name
    const obj = @intFromEnum(datas[unwrapped_var].node_and_token[0]);
    const field_token = datas[unwrapped_var].node_and_token[1];
    const field_name = tree.tokenSlice(field_token);

    // Check if the object is `self`
    if (obj >= tags.len) return false;
    if (tags[obj] != .identifier) return false;
    const obj_name = tree.tokenSlice(main_tokens[obj]);
    if (!std.mem.eql(u8, obj_name, "self")) return false;

    // Find the containing block
    var node = unwrap_node;
    var block_node: ?u32 = null;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        if (tags[parent] == .block or tags[parent] == .block_two or
            tags[parent] == .block_semicolon or tags[parent] == .block_two_semicolon)
        {
            block_node = parent;
            break;
        }
        node = parent;
    }

    const block = block_node orelse return false;

    // Scan for method calls with catch before the unwrap
    return scanBlockForMethodCallWithCatch(tree, block, unwrap_node, field_name, tags, datas, main_tokens, token_starts, fn_node);
}

fn scanBlockForMethodCallWithCatch(
    tree: *const std.zig.Ast,
    block: u32,
    unwrap_node: u32,
    field_name: []const u8,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
    token_starts: []const u32,
    fn_node: ids.AstNodeId,
) bool {
    if (block >= tags.len) return false;

    // Get position of the unwrap node
    if (unwrap_node >= main_tokens.len) return false;
    const unwrap_pos = token_starts[main_tokens[unwrap_node]];

    // Get statements from the block
    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(tree, block, &stmts_buf) orelse return false;

    // Look for catch expressions before the unwrap
    for (stmts_buf[0..stmt_count]) |stmt| {
        if (stmt >= tags.len) continue;
        if (stmt >= main_tokens.len) continue;

        const stmt_pos = token_starts[main_tokens[stmt]];

        // Only look at statements before the unwrap
        if (stmt_pos >= unwrap_pos) continue;

        // Check if this is a catch expression with early exit handler
        if (tags[stmt] != .@"catch") continue;

        // Get the operand and handler
        const operand = @intFromEnum(datas[stmt].node_and_node[0]);
        const handler = @intFromEnum(datas[stmt].node_and_node[1]);

        // Check if handler is an early exit (return, break, continue)
        if (!isEarlyExitExpr(tree, handler, tags, datas)) continue;

        // Check if operand is a method call on self
        if (!isMethodCallOnSelf(tree, operand, tags, datas, main_tokens)) continue;

        // Get method name
        const method_name = getMethodNameFromCall(tree, operand, tags, datas) orelse continue;

        // Use interprocedural analysis to check if the method assigns to the field
        if (methodAssignsToField(tree, method_name, field_name, fn_node)) {
            return true;
        }
    }

    return false;
}

fn isMethodCallOnSelf(
    tree: *const std.zig.Ast,
    call_node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
) bool {
    if (call_node >= tags.len) return false;

    if (!call_utils.isCallNode(tags[call_node])) {
        return false;
    }

    // Get the callee
    var call_buf: [1]std.zig.Ast.Node.Index = undefined;
    const full_call = tree.fullCall(&call_buf, @enumFromInt(call_node)) orelse return false;
    const callee = @intFromEnum(full_call.ast.fn_expr);

    // Check if callee is a field access on self
    if (callee >= tags.len) return false;
    if (tags[callee] != .field_access) return false;

    const obj = @intFromEnum(datas[callee].node_and_token[0]);
    if (obj >= tags.len) return false;
    if (tags[obj] != .identifier) return false;
    const obj_name = tree.tokenSlice(main_tokens[obj]);
    return std.mem.eql(u8, obj_name, "self");
}

fn getMethodNameFromCall(
    tree: *const std.zig.Ast,
    call_node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) ?[]const u8 {
    if (call_node >= tags.len) return null;

    if (!call_utils.isCallNode(tags[call_node])) {
        return null;
    }

    // Get the callee
    var call_buf: [1]std.zig.Ast.Node.Index = undefined;
    const full_call = tree.fullCall(&call_buf, @enumFromInt(call_node)) orelse return null;
    const callee = @intFromEnum(full_call.ast.fn_expr);

    if (callee >= tags.len) return null;
    if (tags[callee] != .field_access) return null;

    // Get the method name
    const field_token = datas[callee].node_and_token[1];
    return tree.tokenSlice(field_token);
}

fn methodAssignsToField(
    tree: *const std.zig.Ast,
    method_name: []const u8,
    field_name: []const u8,
    fn_node: ids.AstNodeId,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);

    // Scan function declarations in the file to find matching method
    for (0..tags.len) |i| {
        if (tags[i] != .fn_decl) continue;

        // Get function name from proto
        const fn_proto_idx = @intFromEnum(datas[i].node_and_node[0]);
        if (fn_proto_idx >= tags.len) continue;
        const proto_tag = tags[fn_proto_idx];

        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (proto_tag) {
            .fn_proto => tree.fnProto(@enumFromInt(fn_proto_idx)),
            .fn_proto_simple => tree.fnProtoSimple(&buf, @enumFromInt(fn_proto_idx)),
            .fn_proto_one => tree.fnProtoOne(&buf, @enumFromInt(fn_proto_idx)),
            .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(fn_proto_idx)),
            else => null,
        } orelse continue;

        if (proto.name_token) |name_tok| {
            const fn_name = tree.tokenSlice(name_tok);
            if (!std.mem.eql(u8, fn_name, method_name)) continue;

            // Avoid self-recursion (don't use current function as guard)
            if (i == ids.astIndex(fn_node)) continue;

            // Check if function body assigns to self.field_name
            if (bodyAssignsToSelfField(tree, @intCast(i), field_name, tags, datas, main_tokens)) {
                return true;
            }
        }
    }

    return false;
}

fn bodyAssignsToSelfField(
    tree: *const std.zig.Ast,
    fn_decl: u32,
    field_name: []const u8,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
) bool {
    // Find the body node
    if (fn_decl >= tags.len) return false;
    const fn_data = datas[fn_decl].node_and_node;
    const body = @intFromEnum(fn_data[1]);
    if (body == 0) return false;

    // Traverse the body looking for assignments to self.field_name
    var stack: [256]u32 = undefined;
    var stack_len: usize = 0;
    stack[stack_len] = body;
    stack_len += 1;

    while (stack_len > 0) {
        stack_len -= 1;
        const node = stack[stack_len];
        if (node >= tags.len) continue;

        if (tags[node] == .assign) {
            const lhs = @intFromEnum(datas[node].node_and_node[0]);
            if (isSelfFieldAccess(tree, lhs, field_name, tags, datas, main_tokens)) {
                return true;
            }
        }

        // Push children based on node type
        switch (tags[node]) {
            .block, .block_semicolon => {
                const extra = datas[node].extra_range;
                const start: usize = @intFromEnum(extra.start);
                const end: usize = @intFromEnum(extra.end);
                for (start..end) |i| {
                    const child = tree.extra_data[i];
                    if (stack_len < stack.len) {
                        stack[stack_len] = child;
                        stack_len += 1;
                    }
                }
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = datas[node].opt_node_and_opt_node;
                if (opt_nodes[0].unwrap()) |n| {
                    if (stack_len < stack.len) {
                        stack[stack_len] = @intFromEnum(n);
                        stack_len += 1;
                    }
                }
                if (opt_nodes[1].unwrap()) |n| {
                    if (stack_len < stack.len) {
                        stack[stack_len] = @intFromEnum(n);
                        stack_len += 1;
                    }
                }
            },
            .@"if", .if_simple => {
                const full_if = tree.fullIf(@enumFromInt(node)) orelse continue;
                if (stack_len < stack.len) {
                    stack[stack_len] = @intFromEnum(full_if.ast.then_expr);
                    stack_len += 1;
                }
                if (full_if.ast.else_expr.unwrap()) |else_node| {
                    if (stack_len < stack.len) {
                        stack[stack_len] = @intFromEnum(else_node);
                        stack_len += 1;
                    }
                }
            },
            else => {},
        }
    }

    return false;
}

fn isSelfFieldAccess(
    tree: *const std.zig.Ast,
    node: u32,
    field_name: []const u8,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
) bool {
    if (node >= tags.len) return false;
    if (tags[node] != .field_access) return false;

    const obj = @intFromEnum(datas[node].node_and_token[0]);
    const field_token = datas[node].node_and_token[1];

    if (obj >= tags.len or tags[obj] != .identifier) return false;
    const obj_name = tree.tokenSlice(main_tokens[obj]);
    if (!std.mem.eql(u8, obj_name, "self")) return false;

    const name = tree.tokenSlice(field_token);
    return std.mem.eql(u8, name, field_name);
}

pub fn isGuardedByLabeledBlockInvariant(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    unwrapped_var: u32,
    parent_map: []const u32,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    const if_node = findEnclosingIfForUnwrap(tree, unwrap_node, parent_map, tags) orelse return false;
    const full_if = tree.fullIf(@enumFromInt(if_node)) orelse return false;
    const cond_node = @intFromEnum(full_if.ast.cond_expr);
    if (cond_node >= tags.len or tags[cond_node] != .identifier) return false;

    const cond_token = main_tokens[cond_node];
    const cond_name = tree.tokenSlice(cond_token);

    const block_node = findContainingBlock(tree, if_node, parent_map, tags) orelse return false;
    const if_pos = token_starts[main_tokens[if_node]];

    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(tree, block_node, &stmts_buf) orelse return false;

    for (0..stmt_count) |idx| {
        const stmt = stmts_buf[idx];
        if (stmt >= tags.len or stmt >= main_tokens.len) continue;

        const stmt_pos = token_starts[main_tokens[stmt]];
        if (stmt_pos >= if_pos) break;

        if (isGuardFlagAssignment(tree, stmt, cond_name, unwrapped_var, tags, datas, main_tokens)) {
            return true;
        }
    }

    return false;
}

fn findEnclosingIfForUnwrap(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    parent_map: []const u32,
    tags: []const std.zig.Ast.Node.Tag,
) ?u32 {
    var node = unwrap_node;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        if (tags[parent] == .@"if" or tags[parent] == .if_simple) {
            const full_if = tree.fullIf(@enumFromInt(parent)) orelse return null;
            if (isInSubtree(tree, @intFromEnum(full_if.ast.then_expr), unwrap_node)) {
                return parent;
            }
        }

        node = parent;
    }

    return null;
}

fn findContainingBlock(
    tree: *const std.zig.Ast,
    node: u32,
    parent_map: []const u32,
    tags: []const std.zig.Ast.Node.Tag,
) ?u32 {
    _ = tree;
    var current = node;
    var depth: u32 = 0;

    while (current < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[current];
        if (parent == 0 or parent >= tags.len) break;

        switch (tags[parent]) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => return parent,
            else => {},
        }

        current = parent;
    }

    return null;
}

fn isGuardFlagAssignment(
    tree: *const std.zig.Ast,
    stmt: u32,
    flag_name: []const u8,
    unwrapped_var: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    main_tokens: []const u32,
) bool {
    if (stmt >= tags.len) return false;

    switch (tags[stmt]) {
        .simple_var_decl, .local_var_decl, .aligned_var_decl => {
            const full = tree.fullVarDecl(@enumFromInt(stmt)) orelse return false;
            const name_token = full.ast.mut_token + 1;
            const token_tags = tree.tokens.items(.tag);
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) return false;

            const decl_name = tree.tokenSlice(name_token);
            if (!std.mem.eql(u8, decl_name, flag_name)) return false;

            const init_node = @intFromEnum(full.ast.init_node);
            if (init_node == 0 or init_node >= tags.len) return false;
            return isLabeledBlockGuardExpr(tree, init_node, unwrapped_var, tags, datas);
        },
        .assign => {
            const lhs = @intFromEnum(datas[stmt].node_and_node[0]);
            const rhs = @intFromEnum(datas[stmt].node_and_node[1]);
            if (lhs >= tags.len or rhs >= tags.len) return false;
            if (tags[lhs] != .identifier) return false;
            const lhs_name = tree.tokenSlice(main_tokens[lhs]);
            if (!std.mem.eql(u8, lhs_name, flag_name)) return false;
            return isLabeledBlockGuardExpr(tree, rhs, unwrapped_var, tags, datas);
        },
        else => return false,
    }
}

fn isLabeledBlockGuardExpr(
    tree: *const std.zig.Ast,
    node: u32,
    unwrapped_var: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    if (node >= tags.len) return false;

    return switch (tags[node]) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => subtreeHasNullGuardBreak(tree, node, unwrapped_var, tags, datas),
        else => false,
    };
}

fn subtreeHasNullGuardBreak(
    tree: *const std.zig.Ast,
    root: u32,
    unwrapped_var: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    const Visitor = struct {
        stop: bool = false,
        unwrapped_var: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,

        const Self = @This();

        pub fn visit(self: *Self, inner_tree: *const std.zig.Ast, node: u32, tag: std.zig.Ast.Node.Tag) !void {
            if (self.stop) return;

            switch (tag) {
                .@"orelse" => {
                    const pair = self.datas[node].node_and_node;
                    const lhs = @intFromEnum(pair[0]);
                    const rhs = @intFromEnum(pair[1]);
                    if (sameVariable(inner_tree, lhs, self.unwrapped_var) and
                        isBreakWithFalseAndLabel(inner_tree, rhs, self.tags, self.datas))
                    {
                        self.stop = true;
                        return;
                    }
                },
                .@"if", .if_simple => {
                    const full_if = inner_tree.fullIf(@enumFromInt(node)) orelse return;
                    const cond = @intFromEnum(full_if.ast.cond_expr);
                    if (checksNull(inner_tree, cond, self.unwrapped_var)) {
                        const then_expr = @intFromEnum(full_if.ast.then_expr);
                        if (subtreeHasBreakFalseLabel(inner_tree, then_expr, self.tags, self.datas)) {
                            self.stop = true;
                            return;
                        }
                    }
                },
                else => {},
            }
        }
    };

    var visitor = Visitor{ .unwrapped_var = unwrapped_var, .tags = tags, .datas = datas };
    ast_walk.walk(Visitor, tree, root, &visitor) catch return false;
    return visitor.stop;
}

fn subtreeHasBreakFalseLabel(
    tree: *const std.zig.Ast,
    root: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    const Visitor = struct {
        stop: bool = false,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,

        const Self = @This();

        pub fn visit(self: *Self, inner_tree: *const std.zig.Ast, node: u32, tag: std.zig.Ast.Node.Tag) !void {
            if (self.stop) return;
            if (tag != .@"break") return;

            if (isBreakWithFalseAndLabel(inner_tree, node, self.tags, self.datas)) {
                self.stop = true;
            }
        }
    };

    var visitor = Visitor{ .tags = tags, .datas = datas };
    ast_walk.walk(Visitor, tree, root, &visitor) catch return false;
    return visitor.stop;
}

fn isBreakWithFalseAndLabel(
    tree: *const std.zig.Ast,
    node: u32,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
) bool {
    if (node >= tags.len) return false;
    if (tags[node] != .@"break") return false;

    const break_data = datas[node].opt_token_and_opt_node;
    const break_label_token = break_data[0].unwrap() orelse return false;
    if (break_label_token >= tree.tokens.items(.tag).len) return false;

    const value_node = break_data[1].unwrap() orelse return false;
    const value_idx = @intFromEnum(value_node);
    if (value_idx >= tags.len) return false;
    if (tags[value_idx] != .identifier) return false;

    const value_name = tree.tokenSlice(tree.nodes.items(.main_token)[value_idx]);
    return std.mem.eql(u8, value_name, "false");
}

test "labeled block invariant guard" {
    const allocator = std.testing.allocator;
    const source =
        \\const Terminal = struct {
        \\    value: u32,
        \\};
        \\
        \\const Session = struct {
        \\    terminal: ?Terminal = null,
        \\};
        \\
        \\pub fn handleEvent(session: Session) bool {
        \\    const should_forward = blk: {
        \\        const terminal = session.terminal orelse break :blk false;
        \\        break :blk terminal.value > 0;
        \\    };
        \\
        \\    if (should_forward) {
        \\        const terminal = session.terminal.?;
        \\        return terminal.value > 10;
        \\    }
        \\    return false;
        \\}
    ;

    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    var fn_node: u32 = 0;
    for (tags, 0..) |tag, idx| {
        if (tag == .fn_decl) {
            fn_node = @intCast(idx);
            break;
        }
    }
    try std.testing.expect(fn_node != 0);

    const parent_map = try allocator.alloc(u32, tags.len);
    defer allocator.free(parent_map);
    @memset(parent_map, 0);
    ast_walk.fillParentMap(&tree, fn_node, parent_map);

    var unwrap_node: u32 = 0;
    for (tags, 0..) |tag, idx| {
        if (tag != .unwrap_optional) continue;
        if (idx == fn_node) continue;
        if (idx >= parent_map.len) continue;
        if (parent_map[idx] == 0) continue;
        unwrap_node = @intCast(idx);
        break;
    }
    try std.testing.expect(unwrap_node != 0);

    const unwrapped_var = @intFromEnum(datas[unwrap_node].node_and_token[0]);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);

    const if_node = findEnclosingIfForUnwrap(&tree, unwrap_node, parent_map, tags) orelse
        return error.TestUnexpectedResult;
    const full_if = tree.fullIf(@enumFromInt(if_node)) orelse return error.TestUnexpectedResult;
    const cond_node = @intFromEnum(full_if.ast.cond_expr);
    try std.testing.expect(cond_node < tags.len);
    try std.testing.expect(tags[cond_node] == .identifier);

    const cond_name = tree.tokenSlice(main_tokens[cond_node]);
    const block_node = findContainingBlock(&tree, if_node, parent_map, tags) orelse
        return error.TestUnexpectedResult;
    const if_pos = token_starts[main_tokens[if_node]];

    var stmts_buf: [ast_walk.max_block_statements]u32 = undefined;
    const stmt_count = ast_walk.getBlockStatements(&tree, block_node, &stmts_buf) orelse
        return error.TestUnexpectedResult;
    var found_assignment = false;
    for (0..stmt_count) |idx| {
        const stmt = stmts_buf[idx];
        if (stmt >= tags.len or stmt >= main_tokens.len) continue;
        const stmt_pos = token_starts[main_tokens[stmt]];
        if (stmt_pos >= if_pos) break;
        if (isGuardFlagAssignment(&tree, stmt, cond_name, unwrapped_var, tags, datas, main_tokens)) {
            found_assignment = true;
            break;
        }
    }
    try std.testing.expect(found_assignment);
    try std.testing.expect(isGuardedByLabeledBlockInvariant(&tree, unwrap_node, unwrapped_var, parent_map));
}

pub fn isGuardedByShortCircuit(
    tree: *const std.zig.Ast,
    unwrap_node: u32,
    unwrapped_var: u32,
    parent_map: []const u32,
) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    var node = unwrap_node;
    var depth: u32 = 0;

    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        // Check if we're inside a boolean expression (and/or)
        if (tags[parent] == .bool_and or tags[parent] == .bool_or) {
            // For `and`, if left side checks non-null, right side is safe
            if (tags[parent] == .bool_and) {
                const left = @intFromEnum(datas[parent].node_and_node[0]);
                if (checksNotNull(tree, left, unwrapped_var)) {
                    return true;
                }
            }

            // For `or`, if left side checks null, right side is safe for unwrap
            if (tags[parent] == .bool_or) {
                const left = @intFromEnum(datas[parent].node_and_node[0]);
                if (checksNull(tree, left, unwrapped_var)) {
                    return true;
                }
            }
        }

        // Check for ternary if expression
        if (tags[parent] == .@"if" or tags[parent] == .if_simple) {
            const full_if = tree.fullIf(@enumFromInt(parent)) orelse break;
            const cond = @intFromEnum(full_if.ast.cond_expr);

            // If the unwrap is in the then branch, condition should check non-null
            if (isInSubtree(tree, @intFromEnum(full_if.ast.then_expr), unwrap_node)) {
                if (conditionImpliesNotNull(tree, cond, unwrapped_var)) {
                    return true;
                }
            }

            // If the unwrap is in the else branch, condition should check null
            if (full_if.ast.else_expr.unwrap()) |else_node| {
                if (isInSubtree(tree, @intFromEnum(else_node), unwrap_node)) {
                    if (conditionImpliesNull(tree, cond, unwrapped_var)) {
                        return true;
                    }
                }
            }
        }

        node = parent;
    }

    return false;
}

fn isInSubtree(tree: *const std.zig.Ast, root_node: u32, target_node: u32) bool {
    if (root_node == target_node) return true;
    const tags = tree.nodes.items(.tag);
    if (root_node >= tags.len) return false;

    const Visitor = struct {
        stop: bool = false,
        target: u32,

        const Self = @This();

        pub fn visit(self: *Self, _: *const std.zig.Ast, node: u32, _: std.zig.Ast.Node.Tag) !void {
            if (self.stop) return;
            if (node == self.target) {
                self.stop = true;
            }
        }
    };

    var visitor = Visitor{ .target = target_node };
    ast_walk.walk(Visitor, tree, root_node, &visitor) catch return false;
    return visitor.stop;
}

fn checksNull(tree: *const std.zig.Ast, cond_node: u32, var_node: u32) bool {
    return checkNullComparison(tree, cond_node, var_node, true);
}

fn checksNotNull(tree: *const std.zig.Ast, cond_node: u32, var_node: u32) bool {
    return checkNullComparison(tree, cond_node, var_node, false);
}

fn conditionImpliesNotNull(tree: *const std.zig.Ast, cond_node: u32, var_node: u32) bool {
    return conditionImpliesNullness(tree, cond_node, var_node, false);
}

fn conditionImpliesNull(tree: *const std.zig.Ast, cond_node: u32, var_node: u32) bool {
    return conditionImpliesNullness(tree, cond_node, var_node, true);
}

fn conditionImpliesNullness(tree: *const std.zig.Ast, cond_node: u32, var_node: u32, want_null: bool) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (cond_node >= tags.len) return false;

    return switch (tags[cond_node]) {
        .bool_and => blk: {
            const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
            const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);
            break :blk conditionImpliesNullness(tree, lhs, var_node, want_null) or
                conditionImpliesNullness(tree, rhs, var_node, want_null);
        },
        .bool_or => blk: {
            const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
            const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);
            break :blk conditionImpliesNullness(tree, lhs, var_node, want_null) and
                conditionImpliesNullness(tree, rhs, var_node, want_null);
        },
        .grouped_expression => blk: {
            const inner = @intFromEnum(datas[cond_node].node_and_token[0]);
            break :blk conditionImpliesNullness(tree, inner, var_node, want_null);
        },
        .bool_not => blk: {
            const inner = @intFromEnum(datas[cond_node].node);
            break :blk conditionImpliesNullness(tree, inner, var_node, !want_null);
        },
        .equal_equal, .bang_equal => checkNullComparison(tree, cond_node, var_node, want_null),
        else => false,
    };
}

fn checkNullComparison(tree: *const std.zig.Ast, cond_node: u32, var_node: u32, is_null_check: bool) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);

    if (cond_node >= tags.len) return false;

    const cond_tag = tags[cond_node];
    if (cond_tag != .equal_equal and cond_tag != .bang_equal) return false;

    const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
    const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);

    // Check if one side is null and the other is our variable
    const lhs_is_null = isNullIdentifier(tree, lhs);
    const rhs_is_null = isNullIdentifier(tree, rhs);

    if (lhs_is_null and sameVariable(tree, rhs, var_node)) {
        return is_null_check == (cond_tag == .equal_equal);
    }
    if (rhs_is_null and sameVariable(tree, lhs, var_node)) {
        return is_null_check == (cond_tag == .equal_equal);
    }

    return false;
}

fn isNullIdentifier(tree: *const std.zig.Ast, node: u32) bool {
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    if (node >= tags.len) return false;
    if (tags[node] != .identifier) return false;

    const token = main_tokens[node];
    const name = tree.tokenSlice(token);
    return std.mem.eql(u8, name, "null");
}

fn sameVariable(tree: *const std.zig.Ast, node1: u32, node2: u32) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);

    if (node1 >= tags.len or node2 >= tags.len) return false;
    if (tags[node1] == .identifier and tags[node2] == .identifier) {
        const tok1 = main_tokens[node1];
        const tok2 = main_tokens[node2];
        if (tok1 >= tree.tokens.items(.tag).len or tok2 >= tree.tokens.items(.tag).len) return false;

        const name1 = tree.tokenSlice(tok1);
        const name2 = tree.tokenSlice(tok2);
        return std.mem.eql(u8, name1, name2);
    }

    if (tags[node1] == .field_access and tags[node2] == .field_access) {
        const base1 = @intFromEnum(datas[node1].node_and_token[0]);
        const base2 = @intFromEnum(datas[node2].node_and_token[0]);
        const field1 = datas[node1].node_and_token[1];
        const field2 = datas[node2].node_and_token[1];

        const name1 = tree.tokenSlice(field1);
        const name2 = tree.tokenSlice(field2);
        if (!std.mem.eql(u8, name1, name2)) return false;

        if (base1 >= tags.len or base2 >= tags.len) return false;
        if (tags[base1] != .identifier or tags[base2] != .identifier) return false;

        const base_tok1 = main_tokens[base1];
        const base_tok2 = main_tokens[base2];
        if (base_tok1 >= tree.tokens.items(.tag).len or base_tok2 >= tree.tokens.items(.tag).len) return false;

        const base_name1 = tree.tokenSlice(base_tok1);
        const base_name2 = tree.tokenSlice(base_tok2);
        return std.mem.eql(u8, base_name1, base_name2);
    }

    return false;
}
