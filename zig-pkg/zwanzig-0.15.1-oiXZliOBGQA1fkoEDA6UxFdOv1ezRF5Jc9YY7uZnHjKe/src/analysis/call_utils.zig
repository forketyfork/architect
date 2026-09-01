const std = @import("std");
const call_resolver = @import("call_resolver.zig");
const TypeContext = @import("../type_context.zig").TypeContext;
const TypeInfo = @import("../zir_bridge.zig").TypeInfo;

pub const CallInfo = call_resolver.CallInfo;
pub const ProjectTypeResolver = call_resolver.ProjectTypeResolver;
pub const ResolvedType = call_resolver.ResolvedType;

pub fn isCallNode(tag: std.zig.Ast.Node.Tag) bool {
    return call_resolver.isCallNode(tag);
}

pub fn resolveCall(
    tree: *const std.zig.Ast,
    type_ctx: ?*TypeContext,
    call_node: u32,
    fqn_buffer: *[256]u8,
) ?CallInfo {
    return call_resolver.resolveCall(tree, type_ctx, call_node, fqn_buffer);
}

pub fn callParam(tree: *const std.zig.Ast, call_node: u32, index: usize) ?u32 {
    return call_resolver.callParam(tree, call_node, index);
}

pub fn resolveResultLocationType(
    tree: *const std.zig.Ast,
    type_ctx: *TypeContext,
    parent_map: []const u32,
    expr_node: u32,
) ?TypeInfo {
    return call_resolver.resolveResultLocationType(tree, type_ctx, parent_map, expr_node);
}
