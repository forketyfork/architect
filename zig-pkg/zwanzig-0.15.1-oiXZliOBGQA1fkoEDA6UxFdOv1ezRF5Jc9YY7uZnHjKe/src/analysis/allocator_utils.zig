const std = @import("std");
const TypeContext = @import("../type_context.zig").TypeContext;

pub fn isAllocatorExpr(tree: *const std.zig.Ast, type_ctx: ?*TypeContext, expr_node: u32) bool {
    if (isAllocatorType(type_ctx, expr_node)) return true;
    if (isAllocatorName(tree, expr_node)) return true;
    if (isStdHeapAllocatorAccess(tree, expr_node)) return true;
    return false;
}

fn isAllocatorType(type_ctx: ?*TypeContext, expr_node: u32) bool {
    const ctx = type_ctx orelse return false;
    const info = ctx.getExpressionType(expr_node) orelse return false;
    const type_str = info.type_str orelse return false;
    return isAllocatorTypeName(type_str);
}

fn isAllocatorTypeName(type_str: []const u8) bool {
    var slice = type_str;
    while (slice.len > 0 and (slice[0] == '*' or slice[0] == '?')) {
        slice = slice[1..];
    }
    if (std.mem.startsWith(u8, slice, "const ")) {
        slice = slice["const ".len..];
    }
    return std.mem.eql(u8, slice, "std.mem.Allocator");
}

fn isAllocatorName(tree: *const std.zig.Ast, expr_node: u32) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const token_tags = tree.tokens.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    if (expr_node >= tags.len) return false;
    switch (tags[expr_node]) {
        .identifier => {
            const token = main_tokens[expr_node];
            if (token >= token_tags.len or token_tags[token] != .identifier) return false;
            const name = tree.tokenSlice(token);
            return std.mem.eql(u8, name, "allocator") or std.mem.endsWith(u8, name, "allocator");
        },
        .field_access => {
            const field_token = datas[expr_node].node_and_token[1];
            if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return false;
            const name = tree.tokenSlice(field_token);
            return std.mem.eql(u8, name, "allocator") or std.mem.endsWith(u8, name, "allocator");
        },
        else => return false,
    }
}

fn isStdHeapAllocatorAccess(tree: *const std.zig.Ast, expr_node: u32) bool {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const token_tags = tree.tokens.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);

    if (expr_node >= tags.len or tags[expr_node] != .field_access) return false;
    const access = datas[expr_node].node_and_token;
    const field_token = access[1];
    if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return false;
    const field_name = tree.tokenSlice(field_token);
    if (!std.mem.endsWith(u8, field_name, "allocator")) return false;

    const base_node = @intFromEnum(access[0]);
    if (base_node >= tags.len or tags[base_node] != .field_access) return false;
    const base_access = datas[base_node].node_and_token;
    const base_field_token = base_access[1];
    if (base_field_token >= token_tags.len or token_tags[base_field_token] != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(base_field_token), "heap")) return false;

    const root_node = @intFromEnum(base_access[0]);
    if (root_node >= tags.len or tags[root_node] != .identifier) return false;
    const root_token = main_tokens[root_node];
    if (root_token >= token_tags.len or token_tags[root_token] != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(root_token), "std");
}
