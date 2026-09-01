const std = @import("std");
const Ast = std.zig.Ast;
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const TypeContext = @import("../type_context.zig").TypeContext;
const ast_walk = @import("../ast_walk.zig");
const call_utils = @import("../analysis/call_utils.zig");
const ZirBridge = @import("../zir_bridge.zig").ZirBridge;
const TypeInfo = @import("../zir_bridge.zig").TypeInfo;

/// Detects sentinel-terminated allocations that can cause memory mismatch bugs.
///
/// Sentinel-terminated allocations (e.g., `[:0]u8`) allocate `len + 1` bytes but
/// the slice length is `len`. Zig's allocator correctly handles freeing if the
/// slice type preserves sentinel information. However, if the slice is stored in
/// a non-sentinel type (e.g., `[]u8`), the sentinel info is lost and freeing will
/// cause an allocation size mismatch.
///
/// This rule warns about functions that create sentinel-terminated allocations:
/// - `readToEndAllocOptions` with non-null sentinel parameter
/// - `allocWithOptions` with non-null sentinel parameter
/// - `allocSentinel` (always creates sentinel-terminated allocation)
/// - `dupeZ` (always creates null-terminated copy)
/// - `allocPrintSentinel` (always creates sentinel-terminated string)
///
/// To fix: either use null sentinel if not needed, preserve the sentinel type,
/// or manually free with `ptr[0..len+1]` to include the sentinel byte.
pub const SentinelAllocRule = struct {
    pub const rule: Rule = .{
        .name = "sentinel-alloc",
        .checkFn = check,
    };

    const SentinelCallKind = enum {
        read_to_end_alloc_options, // sentinel is 5th param, optional
        alloc_with_options, // sentinel is 4th param, optional
        alloc_sentinel, // always sentinel
        dupe_z, // always null-terminated
        alloc_print_sentinel, // always sentinel
    };

    const StructField = struct {
        struct_name: []const u8,
        field_name: []const u8,
        has_sentinel: bool,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        var type_ctx = TypeContext.init(allocator, src);
        defer type_ctx.deinit();
        const bridge = type_ctx.getZirBridge();

        const parent_map = try allocator.alloc(u32, tags.len);
        defer allocator.free(parent_map);
        @memset(parent_map, 0);
        for (0..tags.len) |i| {
            switch (tags[i]) {
                .fn_decl,
                .test_decl,
                .simple_var_decl,
                .local_var_decl,
                .global_var_decl,
                .aligned_var_decl,
                => ast_walk.fillParentMap(tree, @intCast(i), parent_map),
                else => {},
            }
        }

        var struct_fields: std.ArrayList(StructField) = .empty;
        defer struct_fields.deinit(allocator);
        try collectStructFieldSentinels(allocator, tree, tags, datas, token_tags, main_tokens, &struct_fields);

        for (0..tags.len) |i| {
            const node_idx: Ast.Node.Index = @enumFromInt(i);
            const tag = tags[i];

            // Look for function calls
            if (!call_utils.isCallNode(tag)) continue;

            // Get the full call information
            var buf: [1]Ast.Node.Index = undefined;
            const full_call = tree.fullCall(&buf, node_idx) orelse continue;

            // Check if this is a method call (field_access on left side)
            const callee_idx = @intFromEnum(full_call.ast.fn_expr);
            if (callee_idx >= tags.len) continue;
            if (tags[callee_idx] != .field_access) continue;

            // Get the method name
            const field_access_data = datas[callee_idx].node_and_token;
            const field_token = field_access_data[1];
            if (field_token >= token_tags.len or token_tags[field_token] != .identifier) continue;
            const method_name = tree.tokenSlice(field_token);

            // Identify the kind of sentinel call
            const call_kind: ?SentinelCallKind = if (std.mem.eql(u8, method_name, "readToEndAllocOptions"))
                .read_to_end_alloc_options
            else if (std.mem.eql(u8, method_name, "allocWithOptions"))
                .alloc_with_options
            else if (std.mem.eql(u8, method_name, "allocSentinel"))
                .alloc_sentinel
            else if (std.mem.eql(u8, method_name, "dupeZ"))
                .dupe_z
            else if (std.mem.eql(u8, method_name, "allocPrintSentinel"))
                .alloc_print_sentinel
            else
                null;

            const kind = call_kind orelse continue;

            // Check if this is a sentinel allocation that should warn
            const should_warn = switch (kind) {
                .read_to_end_alloc_options => blk: {
                    // Sentinel is the 5th parameter (index 4)
                    if (full_call.ast.params.len < 5) break :blk false;
                    break :blk !isNullLiteral(tree, tags, token_tags, main_tokens, full_call.ast.params[4]);
                },
                .alloc_with_options => blk: {
                    // Sentinel is the 4th parameter (index 3)
                    if (full_call.ast.params.len < 4) break :blk false;
                    break :blk !isNullLiteral(tree, tags, token_tags, main_tokens, full_call.ast.params[3]);
                },
                // These always create sentinel-terminated allocations
                .alloc_sentinel, .dupe_z, .alloc_print_sentinel => true,
            };

            if (!should_warn) continue;
            if (isSentinelPreserved(
                tree,
                tags,
                datas,
                token_tags,
                main_tokens,
                parent_map,
                struct_fields.items,
                &type_ctx,
                bridge,
                @intCast(i),
            )) {
                continue;
            }

            // Emit warning
            const token_starts = tree.tokens.items(.start);
            const call_token = main_tokens[callee_idx];
            const byte_offset = token_starts[call_token];
            const loc = try src.byteToLocation(byte_offset);

            const message = switch (kind) {
                .read_to_end_alloc_options => "readToEndAllocOptions with non-null sentinel allocates len+1 bytes; if stored as []u8, freeing will cause size mismatch",
                .alloc_with_options => "allocWithOptions with non-null sentinel allocates len+1 bytes; if stored as []T, freeing will cause size mismatch",
                .alloc_sentinel => "allocSentinel allocates len+1 bytes; if stored as []T, freeing will cause size mismatch",
                .dupe_z => "dupeZ allocates len+1 bytes for null terminator; if stored as []T, freeing will cause size mismatch",
                .alloc_print_sentinel => "allocPrintSentinel allocates len+1 bytes; if stored as []u8, freeing will cause size mismatch",
            };

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

    fn isSentinelPreserved(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        parent_map: []const u32,
        struct_fields: []const StructField,
        type_ctx: *TypeContext,
        bridge: ?*const ZirBridge,
        call_node: u32,
    ) bool {
        const context_type = findContextType(
            tree,
            tags,
            datas,
            token_tags,
            main_tokens,
            parent_map,
            struct_fields,
            type_ctx,
            bridge,
            call_node,
        ) orelse return false;
        return context_type.hasSentinel();
    }

    fn findContextType(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        parent_map: []const u32,
        struct_fields: []const StructField,
        type_ctx: *TypeContext,
        bridge: ?*const ZirBridge,
        call_node: u32,
    ) ?TypeInfo {
        if (call_utils.resolveResultLocationType(tree, type_ctx, parent_map, call_node)) |ti| {
            if (!isUnknownTypeInfo(ti)) return ti;
        }

        var node = call_node;
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
                            var buf: [2]Ast.Node.Index = undefined;
                            const params = tree.builtinCallParams(&buf, @enumFromInt(parent)) orelse return null;
                            if (params.len < 2) return null;
                            const type_node = @intFromEnum(params[0]);
                            const value_node = @intFromEnum(params[1]);
                            if (!ast_walk.isAncestor(value_node, call_node, parent_map)) {
                                return null;
                            }
                            if (bridge) |zir_bridge| {
                                return zir_bridge.getTypeFromAstNode(type_node);
                            }
                            if (typeInfoFromTypeNode(tree, tags, datas, type_node)) |ti| {
                                return ti;
                            }
                        }
                    }
                    return null;
                },
                .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                    const full = tree.fullVarDecl(@enumFromInt(parent)) orelse return null;
                    const type_node_opt = full.ast.type_node.unwrap();
                    if (type_node_opt) |type_node| {
                        if (bridge) |zir_bridge| {
                            if (zir_bridge.getTypeFromAstNode(@intFromEnum(type_node))) |ti| {
                                return ti;
                            }
                        }
                        if (typeInfoFromTypeNode(tree, tags, datas, @intFromEnum(type_node))) |ti| {
                            return ti;
                        }
                    }
                    if (full.ast.init_node.unwrap()) |init_node| {
                        if (ast_walk.isAncestor(@intFromEnum(init_node), call_node, parent_map)) {
                            if (type_ctx.getExpressionTypeStrict(@intFromEnum(init_node))) |ti| {
                                if (!isUnknownTypeInfo(ti)) {
                                    return ti;
                                }
                            }
                        }
                    }
                    return null;
                },
                .@"return" => {
                    if (findAncestorFn(tags, parent_map, parent)) |fn_node| {
                        if (type_ctx.getContainingFunctionReturnType(fn_node)) |ti| {
                            if (!isUnknownTypeInfo(ti)) {
                                return ti;
                            }
                        }
                        if (returnTypeInfoFromFn(tree, tags, datas, fn_node)) |ti| {
                            return ti;
                        }
                    }
                    return null;
                },
                else => {
                    if (isAssignTag(tags[parent])) {
                        const pair = datas[parent].node_and_node;
                        const lhs = @intFromEnum(pair[0]);
                        const rhs = @intFromEnum(pair[1]);
                        if (ast_walk.isAncestor(rhs, call_node, parent_map)) {
                            if (type_ctx.getExpressionTypeStrict(lhs)) |ti| {
                                if (!isUnknownTypeInfo(ti)) {
                                    return ti;
                                }
                            }
                            if (tags[lhs] == .identifier) {
                                if (findVarDeclTypeInfo(tree, tags, datas, token_tags, lhs)) |ti| {
                                    return ti;
                                }
                            } else if (tags[lhs] == .field_access) {
                                if (findFieldAccessTypeInfo(tree, tags, datas, token_tags, main_tokens, struct_fields, lhs)) |ti| {
                                    return ti;
                                }
                            }
                        }
                    }
                    return null;
                },
            }
        }
        return null;
    }

    fn builtinCallName(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        node_idx: u32,
    ) ?[]const u8 {
        switch (tags[node_idx]) {
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
            else => return null,
        }

        const builtin_token = tree.nodes.items(.main_token)[node_idx];
        if (builtin_token >= token_tags.len) return null;
        if (token_tags[builtin_token] != .builtin) return null;
        return tree.tokenSlice(builtin_token);
    }

    fn isAssignTag(tag: Ast.Node.Tag) bool {
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

    fn isUnknownTypeInfo(info: TypeInfo) bool {
        return info.kind == .unknown and info.type_str == null and !info.hasSentinel();
    }

    fn findAncestorFn(tags: []const Ast.Node.Tag, parent_map: []const u32, start_node: u32) ?u32 {
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

    fn typeInfoFromTypeNode(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
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

    fn findVarDeclTypeInfo(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        ident_node: u32,
    ) ?TypeInfo {
        const main_tokens = tree.nodes.items(.main_token);
        const ident_token = main_tokens[ident_node];
        if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return null;
        const name = tree.tokenSlice(ident_token);

        for (0..tags.len) |i| {
            const node_idx: u32 = @intCast(i);
            if (tags[node_idx] != .simple_var_decl and
                tags[node_idx] != .aligned_var_decl and
                tags[node_idx] != .local_var_decl and
                tags[node_idx] != .global_var_decl)
            {
                continue;
            }

            const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;

            if (full.ast.type_node.unwrap()) |type_node| {
                if (typeInfoFromTypeNode(tree, tags, datas, @intFromEnum(type_node))) |ti| {
                    return ti;
                }
            }
        }
        return null;
    }

    fn findFieldAccessTypeInfo(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        struct_fields: []const StructField,
        field_access_node: u32,
    ) ?TypeInfo {
        const field_access_data = datas[field_access_node].node_and_token;
        const base_node = @intFromEnum(field_access_data[0]);
        const field_token = field_access_data[1];
        if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
        const field_name = tree.tokenSlice(field_token);

        if (base_node >= tags.len or tags[base_node] != .identifier) return null;
        const base_token = main_tokens[base_node];
        if (base_token >= token_tags.len or token_tags[base_token] != .identifier) return null;
        const base_name = tree.tokenSlice(base_token);

        const type_name = findVarDeclTypeName(tree, tags, token_tags, base_name) orelse return null;
        if (findStructFieldSentinel(struct_fields, type_name, field_name)) |has_sentinel| {
            return if (has_sentinel)
                TypeInfo{ .kind = .slice, .sentinel = .{ .value = 0 } }
            else
                TypeInfo{ .kind = .slice };
        }

        return null;
    }

    fn findVarDeclTypeName(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        name: []const u8,
    ) ?[]const u8 {
        const main_tokens = tree.nodes.items(.main_token);
        for (0..tags.len) |i| {
            const node_idx: u32 = @intCast(i);
            if (tags[node_idx] != .simple_var_decl and
                tags[node_idx] != .aligned_var_decl and
                tags[node_idx] != .local_var_decl and
                tags[node_idx] != .global_var_decl)
            {
                continue;
            }

            const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
            if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;

            if (full.ast.type_node.unwrap()) |type_node| {
                const type_idx = @intFromEnum(type_node);
                if (type_idx < tags.len and tags[type_idx] == .identifier) {
                    const type_token = main_tokens[type_idx];
                    if (type_token < token_tags.len and token_tags[type_token] == .identifier) {
                        return tree.tokenSlice(type_token);
                    }
                }
            }
        }
        return null;
    }

    fn findStructFieldSentinel(struct_fields: []const StructField, struct_name: []const u8, field_name: []const u8) ?bool {
        for (struct_fields) |field| {
            if (std.mem.eql(u8, field.struct_name, struct_name) and std.mem.eql(u8, field.field_name, field_name)) {
                return field.has_sentinel;
            }
        }
        return null;
    }

    fn collectStructFieldSentinels(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        out: *std.ArrayList(StructField),
    ) !void {
        for (0..tags.len) |i| {
            const node_idx: u32 = @intCast(i);
            if (tags[node_idx] != .simple_var_decl and
                tags[node_idx] != .aligned_var_decl and
                tags[node_idx] != .global_var_decl)
            {
                continue;
            }

            const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse continue;
            const init_node = full.ast.init_node.unwrap() orelse continue;
            const init_idx: u32 = @intFromEnum(init_node);
            if (init_idx >= tags.len) continue;
            if (!isStructContainer(tags, main_tokens, token_tags, init_idx)) continue;

            const name_token = full.ast.mut_token + 1;
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
            const struct_name = tree.tokenSlice(name_token);

            var member_buf: [2]Ast.Node.Index = undefined;
            const members = getContainerMembers(tree, tags, init_idx, &member_buf) orelse continue;
            for (members) |member| {
                const member_idx: u32 = @intFromEnum(member);
                if (!isContainerField(tags[member_idx])) continue;

                const field_name = fieldNameFromNode(tree, token_tags, member_idx) orelse continue;
                const field = tree.fullContainerField(@enumFromInt(member_idx)) orelse continue;
                if (field.ast.type_expr.unwrap()) |type_node| {
                    const field_type = typeInfoFromTypeNode(tree, tags, datas, @intFromEnum(type_node)) orelse TypeInfo.initUnknown();
                    try out.append(allocator, .{
                        .struct_name = struct_name,
                        .field_name = field_name,
                        .has_sentinel = field_type.hasSentinel(),
                    });
                }
            }
        }
    }

    fn returnTypeInfoFromFn(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        fn_node: u32,
    ) ?TypeInfo {
        if (fn_node >= tags.len or tags[fn_node] != .fn_decl) return null;
        var buf: [1]Ast.Node.Index = undefined;
        const fn_proto = tree.fullFnProto(&buf, @enumFromInt(fn_node)) orelse return null;
        const ret_type_node = @intFromEnum(fn_proto.ast.return_type);
        return typeInfoFromTypeNode(tree, tags, datas, ret_type_node);
    }

    fn getContainerMembers(tree: *const Ast, tags: []const Ast.Node.Tag, node_idx: u32, buf: *[2]Ast.Node.Index) ?[]const Ast.Node.Index {
        return switch (tags[node_idx]) {
            .container_decl, .container_decl_trailing => tree.containerDecl(@enumFromInt(node_idx)).ast.members,
            .container_decl_two, .container_decl_two_trailing => tree.containerDeclTwo(buf, @enumFromInt(node_idx)).ast.members,
            .container_decl_arg, .container_decl_arg_trailing => tree.containerDeclArg(@enumFromInt(node_idx)).ast.members,
            .tagged_union, .tagged_union_trailing => tree.taggedUnion(@enumFromInt(node_idx)).ast.members,
            .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => tree.taggedUnionEnumTag(@enumFromInt(node_idx)).ast.members,
            .tagged_union_two, .tagged_union_two_trailing => tree.taggedUnionTwo(buf, @enumFromInt(node_idx)).ast.members,
            else => null,
        };
    }

    fn isStructContainer(
        tags: []const Ast.Node.Tag,
        main_tokens: []const Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        node_idx: u32,
    ) bool {
        if (node_idx >= tags.len) return false;
        if (!isContainerDecl(tags[node_idx])) return false;
        const token = main_tokens[node_idx];
        if (token >= token_tags.len) return false;
        return token_tags[token] == .keyword_struct;
    }

    fn isContainerDecl(tag: Ast.Node.Tag) bool {
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

    fn isContainerField(tag: Ast.Node.Tag) bool {
        return switch (tag) {
            .container_field,
            .container_field_init,
            .container_field_align,
            => true,
            else => false,
        };
    }

    fn fieldNameFromNode(
        tree: *const Ast,
        token_tags: []const std.zig.Token.Tag,
        field_node: u32,
    ) ?[]const u8 {
        const main_tokens = tree.nodes.items(.main_token);
        const token = main_tokens[field_node];
        if (token >= token_tags.len or token_tags[token] != .identifier) return null;
        return tree.tokenSlice(token);
    }

    fn isNullLiteral(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        param: Ast.Node.Index,
    ) bool {
        const param_idx = @intFromEnum(param);
        if (param_idx >= tags.len) return false;

        if (tags[param_idx] == .identifier) {
            const token = main_tokens[param_idx];
            if (token < token_tags.len and token_tags[token] == .identifier) {
                const value = tree.tokenSlice(token);
                return std.mem.eql(u8, value, "null");
            }
        }
        return false;
    }
};

test "sentinel_alloc detects readToEndAllocOptions with non-null sentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() void {
        \\    const file = std.fs.cwd().openFile("test.txt", .{}) catch return;
        \\    defer file.close();
        \\    const content: []u8 = file.readToEndAllocOptions(
        \\        std.heap.page_allocator,
        \\        1024,
        \\        null,
        \\        @alignOf(u8),
        \\        0,
        \\    ) catch return;
        \\    _ = content;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expectEqualStrings("sentinel-alloc", diagnostics.items[0].rule_id);
}

test "sentinel_alloc ignores null sentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() void {
        \\    const file = std.fs.cwd().openFile("test.txt", .{}) catch return;
        \\    defer file.close();
        \\    const content = file.readToEndAllocOptions(
        \\        std.heap.page_allocator,
        \\        1024,
        \\        null,
        \\        @alignOf(u8),
        \\        null,
        \\    ) catch return;
        \\    _ = content;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "sentinel_alloc detects dupeZ stored as non-sentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) void {
        \\    const s: []u8 = allocator.dupeZ(u8, "hello") catch return;
        \\    _ = s;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "dupeZ") != null);
}

test "sentinel_alloc ignores dupeZ stored as sentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) void {
        \\    const s: [:0]u8 = allocator.dupeZ(u8, "hello") catch return;
        \\    _ = s;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "sentinel_alloc detects allocSentinel stored as non-sentinel" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) void {
        \\    const s: []u8 = allocator.allocSentinel(u8, 10, 0) catch return;
        \\    _ = s;
        \\}
    ;

    var source = Source.init(alloc, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| {
            diag.deinit(alloc);
        }
        diagnostics.deinit(alloc);
    }

    try SentinelAllocRule.rule.checkFn(&source, alloc, &diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try testing.expect(std.mem.indexOf(u8, diagnostics.items[0].message, "allocSentinel") != null);
}
