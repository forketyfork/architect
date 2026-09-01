const std = @import("std");
const ids = @import("../ids.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Source = @import("../source.zig").Source;
const VarResolver = @import("../engine/var_resolver.zig").VarResolver;
const ast_walk = @import("../ast_walk.zig");

const Ast = std.zig.Ast;

/// Rule that detects unused function parameters.
///
/// Parameters prefixed with '_' are ignored (explicitly unused).
/// Parameters used only in type annotations (e.g., `comptime T: type` used in
/// other parameter types or return type) are considered used.
pub const UnusedParameterRule = struct {
    pub const rule: Rule = .{
        .name = "unused-parameter",
        .default_severity = .warning,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);

        for (tags, 0..) |tag, i| {
            if (tag != .fn_decl) continue;

            const node_idx: u32 = @intCast(i);
            const data = datas[node_idx].node_and_node;
            const proto_node = @intFromEnum(data[0]);
            const body_node = @intFromEnum(data[1]);
            if (proto_node == 0 or proto_node >= tags.len) continue;
            if (body_node == 0) continue;

            var resolver = try VarResolver.init(allocator, tree, ids.astId(node_idx));
            defer resolver.deinit();

            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const proto = switch (tags[proto_node]) {
                .fn_proto => tree.fnProto(@enumFromInt(proto_node)),
                .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(proto_node)),
                .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(proto_node)),
                .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(proto_node)),
                else => continue,
            };

            var it = proto.iterate(tree);
            while (it.next()) |param| {
                const name_tok = param.name_token orelse continue;
                if (name_tok >= token_tags.len or token_tags[name_tok] != .identifier) continue;

                const name = tree.tokenSlice(name_tok);
                if (shouldSkipName(name)) continue;

                const var_id = ids.varId(name_tok);
                if (isVarIdUsed(&resolver, var_id)) continue;

                // Check if parameter is used in signature (other param types or return type)
                if (isUsedInSignature(tree, proto, name)) continue;

                const loc = try src.tokenLocation(name_tok);
                const message = try std.fmt.allocPrint(allocator, "Unused parameter '{s}'", .{name});
                defer allocator.free(message);

                const diag = try Diagnostic.initAtLocation(
                    allocator,
                    src.getFilePath(),
                    rule.name,
                    .warning,
                    message,
                    loc.line,
                    loc.column,
                );
                try diagnostics.append(allocator, diag);
            }
        }
    }

    fn shouldSkipName(name: []const u8) bool {
        if (name.len == 0) return true;
        if (name[0] == '_') return true;
        return false;
    }

    fn isVarIdUsed(resolver: *const VarResolver, var_id: ids.VarId) bool {
        var it = resolver.mappings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == var_id) return true;
        }
        return false;
    }

    /// Check if a parameter name is used in the function signature:
    /// - In type annotations of other parameters
    /// - In the return type
    fn isUsedInSignature(tree: *const Ast, proto: Ast.full.FnProto, param_name: []const u8) bool {
        // Check return type
        const ret_node = @intFromEnum(proto.ast.return_type);
        if (ret_node != 0 and containsIdentifier(tree, ret_node, param_name)) {
            return true;
        }

        // Check all parameter type annotations
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.type_expr) |type_expr| {
                const type_node = @intFromEnum(type_expr);
                if (type_node != 0 and containsIdentifier(tree, type_node, param_name)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Recursively check if a node contains an identifier with the given name.
    fn containsIdentifier(tree: *const Ast, node: u32, target_name: []const u8) bool {
        return ast_walk.containsIdentifier(tree, node, target_name);
    }
};
