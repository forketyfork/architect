const std = @import("std");
const import_resolver = @import("import_resolver.zig");
const TypeContext = @import("../type_context.zig").TypeContext;
const TypeInfo = @import("../zir_bridge.zig").TypeInfo;

pub const ResolvedType = struct {
    file_index: usize,
    type_name: ?[]const u8 = null,
};

pub const CallInfo = struct {
    call_node: u32,
    method_name: []const u8,
    receiver_type: ?[]const u8,
    fqn: ?[]const u8,
    base_node: ?u32,
    param_count: usize,
};

pub fn isCallNode(tag: std.zig.Ast.Node.Tag) bool {
    return tag == .call or tag == .call_comma or tag == .call_one or tag == .call_one_comma;
}

pub fn resolveCall(
    tree: *const std.zig.Ast,
    type_ctx: ?*TypeContext,
    call_node: u32,
    fqn_buffer: *[256]u8,
) ?CallInfo {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const token_tags = tree.tokens.items(.tag);

    if (call_node >= tags.len or !isCallNode(tags[call_node])) return null;

    var call_buf: [1]std.zig.Ast.Node.Index = undefined;
    const full_call = tree.fullCall(&call_buf, @enumFromInt(call_node)) orelse return null;
    const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
    if (callee_node >= tags.len) return null;

    return switch (tags[callee_node]) {
        .identifier => blk: {
            const token = tree.nodes.items(.main_token)[callee_node];
            if (token >= token_tags.len or token_tags[token] != .identifier) return null;
            const name = tree.tokenSlice(token);
            break :blk .{
                .call_node = call_node,
                .method_name = name,
                .receiver_type = null,
                .fqn = name,
                .base_node = null,
                .param_count = full_call.ast.params.len,
            };
        },
        .field_access => blk: {
            const field_access_data = datas[callee_node].node_and_token;
            const base_node = @intFromEnum(field_access_data[0]);
            const field_token = field_access_data[1];
            if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
            const field_name = tree.tokenSlice(field_token);
            const receiver_type = getReceiverTypeName(type_ctx, tree, base_node);
            const fqn = constructFqn(tree, base_node, field_name, fqn_buffer);
            break :blk .{
                .call_node = call_node,
                .method_name = field_name,
                .receiver_type = receiver_type,
                .fqn = fqn,
                .base_node = base_node,
                .param_count = full_call.ast.params.len,
            };
        },
        else => null,
    };
}

pub fn callParam(tree: *const std.zig.Ast, call_node: u32, index: usize) ?u32 {
    const tags = tree.nodes.items(.tag);
    if (call_node >= tags.len or !isCallNode(tags[call_node])) return null;

    var call_buf: [1]std.zig.Ast.Node.Index = undefined;
    const full_call = tree.fullCall(&call_buf, @enumFromInt(call_node)) orelse return null;
    if (index >= full_call.ast.params.len) return null;
    return @intFromEnum(full_call.ast.params[index]);
}

pub fn getReceiverTypeName(type_ctx: ?*TypeContext, tree: *const std.zig.Ast, base_node: u32) ?[]const u8 {
    const ctx = type_ctx orelse return null;
    const tags = tree.nodes.items(.tag);
    if (base_node >= tags.len) return null;
    if (ctx.getExpressionType(base_node)) |ti| {
        return ti.type_str;
    }
    return null;
}

pub fn constructFqn(
    tree: *const std.zig.Ast,
    base_node: u32,
    method_name: []const u8,
    buffer: *[256]u8,
) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    var parts: [16][]const u8 = undefined;
    var count: usize = 0;
    var node = base_node;

    while (true) {
        if (node >= tags.len) return null;

        switch (tags[node]) {
            .identifier => {
                const ident_token = main_tokens[node];
                if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return null;
                if (count >= parts.len) return null;
                parts[count] = tree.tokenSlice(ident_token);
                count += 1;
                break;
            },
            .field_access => {
                const field_access = datas[node].node_and_token;
                const field_token = field_access[1];
                if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
                if (count >= parts.len) return null;
                parts[count] = tree.tokenSlice(field_token);
                count += 1;
                node = @intFromEnum(field_access[0]);
            },
            else => return null,
        }
    }

    var pos: usize = 0;
    var idx: usize = count;
    while (idx > 0) : (idx -= 1) {
        if (!appendFqnPart(buffer, parts[idx - 1], &pos)) return null;
        if (idx > 1 and !appendFqnSeparator(buffer, &pos)) return null;
    }

    if (!appendFqnSeparator(buffer, &pos)) return null;
    if (!appendFqnPart(buffer, method_name, &pos)) return null;

    return buffer[0..pos];
}

pub fn resolveResultLocationType(
    tree: *const std.zig.Ast,
    type_ctx: *TypeContext,
    parent_map: []const u32,
    expr_node: u32,
) ?TypeInfo {
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const token_tags = tree.tokens.items(.tag);

    var node = expr_node;
    var depth: u32 = 0;
    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) break;

        switch (tags[parent]) {
            .grouped_expression, .unwrap_optional, .@"try", .@"catch", .if_simple, .@"if" => {
                node = parent;
                continue;
            },
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                if (builtinCallName(tree, tags, token_tags, parent)) |name| {
                    if (std.mem.eql(u8, name, "@as")) {
                        var buf: [2]std.zig.Ast.Node.Index = undefined;
                        const params = tree.builtinCallParams(&buf, @enumFromInt(parent)) orelse return null;
                        if (params.len < 2) return null;
                        const type_node = @intFromEnum(params[0]);
                        const value_node = @intFromEnum(params[1]);
                        if (!nodeIsAncestor(value_node, expr_node, parent_map)) return null;
                        if (type_ctx.getTypeFromAstNode(type_node)) |ti| return ti;
                        return typeInfoFromTypeNode(tree, tags, datas, type_node);
                    }
                }
                return null;
            },
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                const full = tree.fullVarDecl(@enumFromInt(parent)) orelse return null;
                if (full.ast.type_node.unwrap()) |type_node| {
                    if (type_ctx.getTypeFromAstNode(@intFromEnum(type_node))) |ti| return ti;
                    if (typeInfoFromTypeNode(tree, tags, datas, @intFromEnum(type_node))) |ti| return ti;
                }
                if (full.ast.init_node.unwrap()) |init_node| {
                    if (nodeIsAncestor(@intFromEnum(init_node), expr_node, parent_map)) {
                        if (type_ctx.getExpressionTypeStrict(@intFromEnum(init_node))) |ti| {
                            if (!isUnknownTypeInfo(ti)) return ti;
                        }
                    }
                }
                return null;
            },
            .@"return" => {
                if (findAncestorFn(tags, parent_map, parent)) |fn_node| {
                    if (type_ctx.getContainingFunctionReturnType(fn_node)) |ti| {
                        if (!isUnknownTypeInfo(ti)) return ti;
                    }
                    if (returnTypeInfoFromFn(tree, tags, datas, fn_node)) |ti| return ti;
                }
                return null;
            },
            else => {
                if (isAssignTag(tags[parent])) {
                    const pair = datas[parent].node_and_node;
                    const lhs = @intFromEnum(pair[0]);
                    const rhs = @intFromEnum(pair[1]);
                    if (nodeIsAncestor(rhs, expr_node, parent_map)) {
                        if (type_ctx.getExpressionTypeStrict(lhs)) |ti| {
                            if (!isUnknownTypeInfo(ti)) return ti;
                        }
                    }
                }
                return null;
            },
        }
    }
    return null;
}

pub const ProjectTypeResolver = struct {
    files: []const import_resolver.File,
    file_index: usize,

    fn currentFile(self: ProjectTypeResolver) import_resolver.File {
        return self.files[self.file_index];
    }

    pub fn resolveExprType(self: ProjectTypeResolver, node: usize) ?ResolvedType {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        switch (tags[node]) {
            .identifier => {
                const name = import_resolver.identifierName(tree, node) orelse return null;
                return self.resolveNameType(name, node);
            },
            .field_access => {
                const datas = tree.nodes.items(.data);
                const field_access = datas[node].node_and_token;
                const lhs = @intFromEnum(field_access[0]);
                const member_name = import_resolver.normalizeIdentifier(tree.tokenSlice(field_access[1]));
                const base_type = self.resolveExprType(lhs) orelse return null;
                return self.resolveMemberType(base_type, member_name);
            },
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            => return self.resolveCallType(@intCast(node)),
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => return self.resolveStructInitType(@intCast(node)),
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => return self.resolveBuiltinType(@intCast(node)),
            else => return null,
        }
    }

    pub fn resolveTypeNode(self: ProjectTypeResolver, node: usize) ?ResolvedType {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        switch (tags[node]) {
            .identifier => {
                const name = import_resolver.identifierName(tree, node) orelse return null;
                return self.resolveNameType(name, node);
            },
            .field_access => {
                const datas = tree.nodes.items(.data);
                const field_access = datas[node].node_and_token;
                const lhs = @intFromEnum(field_access[0]);
                const member_name = import_resolver.normalizeIdentifier(tree.tokenSlice(field_access[1]));
                const base_type = self.resolveTypeNode(lhs) orelse self.resolveExprType(lhs) orelse return null;
                return self.resolveMemberType(base_type, member_name);
            },
            .ptr_type,
            .ptr_type_aligned,
            .ptr_type_bit_range,
            .ptr_type_sentinel,
            => {
                const ptr = tree.fullPtrType(@enumFromInt(node)) orelse return null;
                return self.resolveTypeNode(@intFromEnum(ptr.ast.child_type));
            },
            .optional_type => return self.resolveTypeNode(@intFromEnum(tree.nodes.items(.data)[node].node)),
            .error_union => return self.resolveTypeNode(@intFromEnum(tree.nodes.items(.data)[node].node_and_node[1])),
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => return self.resolveBuiltinType(@intCast(node)),
            else => return null,
        }
    }

    pub fn varDeclInitializerReferencesExpectedTypeMethod(
        self: ProjectTypeResolver,
        full: std.zig.Ast.full.VarDecl,
        decl_file_index: usize,
        method_name: []const u8,
    ) bool {
        const type_node = full.ast.type_node.unwrap() orelse return false;
        const expected_type = self.resolveTypeNode(@intFromEnum(type_node)) orelse return false;
        if (expected_type.file_index != decl_file_index) return false;
        if (expected_type.type_name != null) return false;

        const init_node = full.ast.init_node.unwrap() orelse return false;
        return self.initializerReferencesExpectedTypeMethod(@intFromEnum(init_node), method_name);
    }

    fn resolveNameType(self: ProjectTypeResolver, name: []const u8, reference_node: usize) ?ResolvedType {
        if (self.resolveNearestBindingType(name, reference_node)) |resolved| return resolved;
        if (self.resolveNamedDeclType(self.file_index, name)) |resolved| return resolved;
        if (std.mem.eql(u8, name, import_resolver.fileStem(self.currentFile().path))) {
            return .{ .file_index = self.file_index };
        }
        return null;
    }

    fn resolveNearestBindingType(self: ProjectTypeResolver, name: []const u8, reference_node: usize) ?ResolvedType {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        const reference_start = import_resolver.nodeStart(tree, reference_node) orelse return null;

        var best_start: usize = 0;
        var best_type: ?ResolvedType = null;

        for (tags, 0..) |tag, node_index| {
            switch (tag) {
                .simple_var_decl,
                .aligned_var_decl,
                .global_var_decl,
                .local_var_decl,
                => {
                    const full = tree.fullVarDecl(@enumFromInt(node_index)) orelse continue;
                    const name_token = full.ast.mut_token + 1;
                    if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
                    const decl_name = import_resolver.normalizeIdentifier(tree.tokenSlice(name_token));
                    if (!std.mem.eql(u8, decl_name, name)) continue;

                    const start = tree.tokens.items(.start)[name_token];
                    if (start > reference_start or start < best_start) continue;
                    if (self.resolveVarDeclType(full, node_index, decl_name)) |resolved| {
                        best_start = start;
                        best_type = resolved;
                    }
                },
                .fn_decl,
                .fn_proto,
                .fn_proto_simple,
                .fn_proto_one,
                .fn_proto_multi,
                => {
                    if (self.resolveFnParamBindingType(@intCast(node_index), name, reference_start, &best_start)) |resolved| {
                        best_type = resolved;
                    }
                },
                else => {},
            }
        }

        return best_type;
    }

    fn resolveFnParamBindingType(
        self: ProjectTypeResolver,
        node: u32,
        name: []const u8,
        reference_start: usize,
        best_start: *usize,
    ) ?ResolvedType {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        if (tags[node] == .fn_decl) {
            const proto_node = @intFromEnum(tree.nodes.items(.data)[node].node_and_node[0]);
            return self.resolveFnParamBindingType(@intCast(proto_node), name, reference_start, best_start);
        }

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tags[node]) {
            .fn_proto => tree.fnProto(@enumFromInt(node)),
            .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(node)),
            .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(node)),
            .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(node)),
            else => return null,
        };

        var best_type: ?ResolvedType = null;
        for (proto.ast.params) |param_node| {
            const param_index = @intFromEnum(param_node);
            if (param_index >= tags.len) continue;

            if (import_resolver.isVarDeclTag(tags[param_index])) {
                const full = tree.fullVarDecl(param_node) orelse continue;
                const name_token = full.ast.mut_token + 1;
                if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
                const param_name = import_resolver.normalizeIdentifier(tree.tokenSlice(name_token));
                if (!std.mem.eql(u8, param_name, name)) continue;

                const start = tree.tokens.items(.start)[name_token];
                if (start > reference_start or start < best_start.*) continue;
                if (self.resolveVarDeclType(full, param_index, param_name)) |resolved| {
                    best_start.* = start;
                    best_type = resolved;
                }
                continue;
            }

            const name_token = import_resolver.paramNameTokenBeforeType(tree, param_index) orelse continue;
            const param_name = import_resolver.normalizeIdentifier(tree.tokenSlice(@intCast(name_token)));
            if (!std.mem.eql(u8, param_name, name)) continue;

            const start = tree.tokens.items(.start)[name_token];
            if (start > reference_start or start < best_start.*) continue;
            if (self.resolveTypeNode(param_index)) |resolved| {
                best_start.* = start;
                best_type = resolved;
            }
        }
        return best_type;
    }

    fn resolveVarDeclType(
        self: ProjectTypeResolver,
        full: std.zig.Ast.full.VarDecl,
        node_index: usize,
        decl_name: []const u8,
    ) ?ResolvedType {
        if (full.ast.type_node.unwrap()) |type_node| {
            if (self.resolveTypeNode(@intFromEnum(type_node))) |resolved| return resolved;
        }

        const init_node = full.ast.init_node.unwrap() orelse return null;
        const init_index = @intFromEnum(init_node);
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (init_index >= tags.len) return null;
        if (import_resolver.isBuiltinCallTag(tags[init_index])) {
            return self.resolveBuiltinType(@intCast(init_index));
        }
        if (isContainerTag(tags[init_index])) {
            return .{ .file_index = self.file_index, .type_name = decl_name };
        }
        if (isRootDeclNode(tree, node_index)) return null;
        return self.resolveInitializerType(init_index);
    }

    fn resolveInitializerType(self: ProjectTypeResolver, node: usize) ?ResolvedType {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        return switch (tags[node]) {
            .call, .call_comma, .call_one, .call_one_comma => self.resolveCallType(@intCast(node)),
            .@"try",
            .address_of,
            .deref,
            .optional_type,
            => self.resolveInitializerType(@intFromEnum(tree.nodes.items(.data)[node].node)),
            .grouped_expression,
            .unwrap_optional,
            => self.resolveInitializerType(@intFromEnum(tree.nodes.items(.data)[node].node_and_token[0])),
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => self.resolveStructInitType(@intCast(node)),
            .builtin_call,
            .builtin_call_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            => self.resolveBuiltinType(@intCast(node)),
            else => null,
        };
    }

    fn initializerReferencesExpectedTypeMethod(
        self: ProjectTypeResolver,
        node: usize,
        method_name: []const u8,
    ) bool {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return false;

        return switch (tags[node]) {
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            => self.callUsesImplicitResultMethod(@intCast(node), method_name),
            .@"try",
            .address_of,
            .deref,
            .optional_type,
            => self.initializerReferencesExpectedTypeMethod(@intFromEnum(tree.nodes.items(.data)[node].node), method_name),
            .grouped_expression,
            .unwrap_optional,
            => self.initializerReferencesExpectedTypeMethod(@intFromEnum(tree.nodes.items(.data)[node].node_and_token[0]), method_name),
            .@"catch" => self.initializerReferencesExpectedTypeMethod(@intFromEnum(tree.nodes.items(.data)[node].node_and_node[0]), method_name),
            else => false,
        };
    }

    fn callUsesImplicitResultMethod(self: ProjectTypeResolver, node: u32, method_name: []const u8) bool {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return false;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, @enumFromInt(node)) orelse return false;
        const callee = @intFromEnum(call.ast.fn_expr);
        if (callee >= tags.len or tags[callee] != .enum_literal) return false;

        const token = tree.nodes.items(.main_token)[callee];
        if (token >= tree.tokens.len) return false;
        return std.mem.eql(u8, import_resolver.normalizeIdentifier(tree.tokenSlice(token)), method_name);
    }

    fn resolveCallType(self: ProjectTypeResolver, node: u32) ?ResolvedType {
        const tree = self.currentFile().tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, @enumFromInt(node)) orelse return null;
        const callee = @intFromEnum(call.ast.fn_expr);
        if (callee >= tags.len) return null;
        if (tags[callee] == .field_access) {
            const lhs = @intFromEnum(tree.nodes.items(.data)[callee].node_and_token[0]);
            return self.resolveTypeNode(lhs) orelse self.resolveExprType(lhs);
        }
        return null;
    }

    fn resolveStructInitType(self: ProjectTypeResolver, node: u32) ?ResolvedType {
        const tree = self.currentFile().tree;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&buffer, @enumFromInt(node)) orelse return null;
        const type_node = init.ast.type_expr.unwrap() orelse return null;
        return self.resolveTypeNode(@intFromEnum(type_node));
    }

    fn resolveBuiltinType(self: ProjectTypeResolver, node: u32) ?ResolvedType {
        const tree = self.currentFile().tree;
        if (import_resolver.importPathFromBuiltinCall(tree, node)) |import_path| {
            if (import_resolver.resolveImportToFileIndex(self.files, self.currentFile().path, import_path)) |file_index| {
                return .{ .file_index = file_index };
            }
        }
        if (isThisBuiltinCall(tree, node)) {
            return .{ .file_index = self.file_index };
        }
        return null;
    }

    fn resolveMemberType(self: ProjectTypeResolver, base_type: ResolvedType, member_name: []const u8) ?ResolvedType {
        const member_resolver = ProjectTypeResolver{
            .files = self.files,
            .file_index = base_type.file_index,
        };
        if (member_resolver.resolveNamedDeclType(base_type.file_index, member_name)) |resolved| return resolved;
        return member_resolver.resolveFieldType(base_type, member_name);
    }

    fn resolveNamedDeclType(self: ProjectTypeResolver, file_index: usize, name: []const u8) ?ResolvedType {
        const file = self.files[file_index];
        const tree = file.tree;
        const tags = tree.nodes.items(.tag);

        for (tree.rootDecls()) |decl_idx| {
            const node_index = @intFromEnum(decl_idx);
            if (node_index >= tags.len or !import_resolver.isVarDeclTag(tags[node_index])) continue;
            const full = tree.fullVarDecl(decl_idx) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
            const decl_name = import_resolver.normalizeIdentifier(tree.tokenSlice(name_token));
            if (!std.mem.eql(u8, decl_name, name)) continue;

            const nested_resolver = ProjectTypeResolver{ .files = self.files, .file_index = file_index };
            if (nested_resolver.resolveVarDeclType(full, node_index, decl_name)) |resolved| return resolved;
        }
        return null;
    }

    fn resolveFieldType(self: ProjectTypeResolver, base_type: ResolvedType, field_name: []const u8) ?ResolvedType {
        if (base_type.type_name) |container_name| {
            if (self.findNamedContainerNode(base_type.file_index, container_name)) |container_node| {
                return self.resolveContainerFieldType(base_type.file_index, container_node, field_name);
            }
        }
        return self.resolveRootFieldType(base_type.file_index, field_name);
    }

    fn findNamedContainerNode(self: ProjectTypeResolver, file_index: usize, name: []const u8) ?u32 {
        const file = self.files[file_index];
        const tree = file.tree;
        const tags = tree.nodes.items(.tag);

        for (tree.rootDecls()) |decl_idx| {
            const node_index = @intFromEnum(decl_idx);
            if (node_index >= tags.len or !import_resolver.isVarDeclTag(tags[node_index])) continue;
            const full = tree.fullVarDecl(decl_idx) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) continue;
            if (!std.mem.eql(u8, import_resolver.normalizeIdentifier(tree.tokenSlice(name_token)), name)) continue;
            const init_node = full.ast.init_node.unwrap() orelse continue;
            const init_index = @intFromEnum(init_node);
            if (init_index < tags.len and isContainerTag(tags[init_index])) return @intCast(init_index);
        }
        return null;
    }

    fn resolveRootFieldType(self: ProjectTypeResolver, file_index: usize, field_name: []const u8) ?ResolvedType {
        const file = self.files[file_index];
        const tree = file.tree;
        const tags = tree.nodes.items(.tag);

        for (tree.rootDecls()) |decl_idx| {
            const node_index = @intFromEnum(decl_idx);
            if (node_index >= tags.len) continue;
            switch (tags[node_index]) {
                .container_field,
                .container_field_init,
                .container_field_align,
                => if (self.resolveContainerFieldNodeType(file_index, @intCast(node_index), field_name)) |resolved| return resolved,
                else => {},
            }
        }
        return null;
    }

    fn resolveContainerFieldType(self: ProjectTypeResolver, file_index: usize, container_node: u32, field_name: []const u8) ?ResolvedType {
        const file = self.files[file_index];
        const tree = file.tree;

        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, @enumFromInt(container_node)) orelse return null;
        for (container.ast.members) |member_node| {
            const member = @intFromEnum(member_node);
            if (self.resolveContainerFieldNodeType(file_index, @intCast(member), field_name)) |resolved| return resolved;
        }
        return null;
    }

    fn resolveContainerFieldNodeType(self: ProjectTypeResolver, file_index: usize, node: u32, field_name: []const u8) ?ResolvedType {
        const file = self.files[file_index];
        const tree = file.tree;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        const field = tree.fullContainerField(@enumFromInt(node)) orelse return null;
        if (field.ast.tuple_like) return null;
        const name_token = field.ast.main_token;
        if (name_token >= tree.tokens.len or tree.tokenTag(name_token) != .identifier) return null;
        if (!std.mem.eql(u8, import_resolver.normalizeIdentifier(tree.tokenSlice(name_token)), field_name)) return null;

        const nested_resolver = ProjectTypeResolver{ .files = self.files, .file_index = file_index };
        if (field.ast.type_expr.unwrap()) |type_node| {
            return nested_resolver.resolveTypeNode(@intFromEnum(type_node));
        }
        if (field.ast.value_expr.unwrap()) |value_node| {
            return nested_resolver.resolveInitializerType(@intFromEnum(value_node));
        }
        return null;
    }
};

pub fn typeInfoFromTypeNode(
    tree: *const std.zig.Ast,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    type_node: u32,
) ?TypeInfo {
    if (type_node >= tags.len) return null;
    return switch (tags[type_node]) {
        .error_union => {
            const pair = datas[type_node].node_and_node;
            return typeInfoFromTypeNode(tree, tags, datas, @intFromEnum(pair[1]));
        },
        .optional_type => {
            const child = datas[type_node].node;
            return typeInfoFromTypeNode(tree, tags, datas, @intFromEnum(child));
        },
        .ptr_type_sentinel, .ptr_type, .ptr_type_aligned, .ptr_type_bit_range => {
            if (tree.fullPtrType(@enumFromInt(type_node))) |pt| {
                const has_sentinel = pt.ast.sentinel != .none;
                return .{
                    .kind = if (pt.size == .slice) .slice else .pointer,
                    .sentinel = if (has_sentinel) .{ .value = 0 } else null,
                };
            }
            return TypeInfo.initPointer();
        },
        .slice_sentinel, .array_type_sentinel => TypeInfo{ .kind = .slice, .sentinel = .{ .value = 0 } },
        .slice, .slice_open => TypeInfo{ .kind = .slice },
        else => null,
    };
}

pub fn isAssignTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .assign,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        => true,
        else => false,
    };
}

pub fn isContainerTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => true,
        else => false,
    };
}

fn appendFqnPart(buffer: *[256]u8, part: []const u8, pos: *usize) bool {
    if (part.len == 0) return false;
    if (pos.* + part.len > buffer.len) return false;
    std.mem.copyForwards(u8, buffer[pos.* .. pos.* + part.len], part);
    pos.* += part.len;
    return true;
}

fn appendFqnSeparator(buffer: *[256]u8, pos: *usize) bool {
    if (pos.* >= buffer.len) return false;
    buffer[pos.*] = '.';
    pos.* += 1;
    return true;
}

fn builtinCallName(
    tree: *const std.zig.Ast,
    tags: []const std.zig.Ast.Node.Tag,
    token_tags: []const std.zig.Token.Tag,
    node_idx: u32,
) ?[]const u8 {
    if (!import_resolver.isBuiltinCallTag(tags[node_idx])) return null;

    const builtin_token = tree.nodes.items(.main_token)[node_idx];
    if (builtin_token >= token_tags.len) return null;
    if (token_tags[builtin_token] != .builtin) return null;
    return tree.tokenSlice(builtin_token);
}

fn isUnknownTypeInfo(info: TypeInfo) bool {
    return info.kind == .unknown and info.type_str == null and !info.hasSentinel();
}

fn findAncestorFn(tags: []const std.zig.Ast.Node.Tag, parent_map: []const u32, start_node: u32) ?u32 {
    var node = start_node;
    var depth: u32 = 0;
    while (node < parent_map.len and depth < 64) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= tags.len) return null;
        if (tags[parent] == .fn_decl) return parent;
        node = parent;
    }
    return null;
}

fn returnTypeInfoFromFn(
    tree: *const std.zig.Ast,
    tags: []const std.zig.Ast.Node.Tag,
    datas: []const std.zig.Ast.Node.Data,
    fn_node: u32,
) ?TypeInfo {
    if (fn_node >= tags.len or tags[fn_node] != .fn_decl) return null;
    var buf: [1]std.zig.Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buf, @enumFromInt(fn_node)) orelse return null;
    const ret_type_node = @intFromEnum(fn_proto.ast.return_type);
    return typeInfoFromTypeNode(tree, tags, datas, ret_type_node);
}

fn isRootDeclNode(tree: *const std.zig.Ast, node_index: usize) bool {
    for (tree.rootDecls()) |decl| {
        if (@intFromEnum(decl) == node_index) return true;
    }
    return false;
}

fn isThisBuiltinCall(tree: *const std.zig.Ast, node: usize) bool {
    const main_tokens = tree.nodes.items(.main_token);
    if (node >= main_tokens.len) return false;
    const token = main_tokens[node];
    if (token >= tree.tokens.len) return false;
    return std.mem.eql(u8, tree.tokenSlice(token), "@This");
}

fn nodeIsAncestor(ancestor: u32, descendant: u32, parent_map: []const u32) bool {
    if (ancestor == descendant) return true;
    var node = descendant;
    var depth: u32 = 0;
    while (node < parent_map.len and depth < 256) : (depth += 1) {
        const parent = parent_map[node];
        if (parent == 0 or parent >= parent_map.len) return false;
        if (parent == ancestor) return true;
        node = parent;
    }
    return false;
}
