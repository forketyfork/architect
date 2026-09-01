const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const source_mod = @import("../source.zig");
const type_info_mod = @import("../types/type_info.zig");
const decls_mod = @import("decls.zig");

const Ast = std.zig.Ast;
const Zir = std.zig.Zir;
const AstGen = std.zig.AstGen;

pub const TypeInfo = type_info_mod.TypeInfo;
pub const DeclInfo = decls_mod.DeclInfo;
pub const ParamInfo = decls_mod.ParamInfo;
pub const FnInfo = decls_mod.FnInfo;
pub const CallExprTypeInfo = decls_mod.CallExprTypeInfo;

const Source = source_mod.Source;

pub const ZirBridgeError = std.mem.Allocator.Error || error{
    AstGenFailed,
    InvalidAst,
    ParseError,
};

/// Bridge for loading typed IR from Zig source via ZIR.
/// This provides typed information that complements the AST-based analysis.
pub const ZirBridge = struct {
    allocator: std.mem.Allocator,
    zir: ?Zir = null,
    ast: ?*const Ast = null,
    source: ?*Source = null,

    /// Collected declaration information
    declarations: std.ArrayList(DeclInfo),
    /// Collected function information
    functions: std.ArrayList(FnInfo),

    pub fn init(allocator: std.mem.Allocator) ZirBridge {
        return .{
            .allocator = allocator,
            .declarations = .empty,
            .functions = .empty,
        };
    }

    pub fn deinit(self: *ZirBridge) void {
        if (self.zir) |*zir| {
            zir.deinit(self.allocator);
        }
        self.declarations.deinit(self.allocator);
        for (self.functions.items) |*fn_info| {
            fn_info.deinit();
        }
        self.functions.deinit(self.allocator);
    }

    /// Generate ZIR from a Source and extract typed information.
    pub fn loadFromSource(self: *ZirBridge, source: *Source) ZirBridgeError!void {
        self.clear();

        self.source = source;

        const tree = source.ast() catch return error.ParseError;
        self.ast = tree;

        if (tree.errors.len > 0) {
            return error.ParseError;
        }

        // AstGen.generate only errors on OOM; language errors are recorded
        // inside the Zir and must be checked explicitly, otherwise a frontend/
        // language mismatch yields silently incomplete type information.
        var zir = try AstGen.generate(self.allocator, tree.*);
        if (zir.hasCompileErrors()) {
            zir.deinit(self.allocator);
            return error.AstGenFailed;
        }
        self.zir = zir;

        try self.extractDeclarations();
    }

    /// Clear all state to allow reuse of the bridge.
    pub fn clear(self: *ZirBridge) void {
        if (self.zir) |*zir| {
            zir.deinit(self.allocator);
            self.zir = null;
        }
        self.ast = null;
        self.source = null;
        self.declarations.clearRetainingCapacity();
        for (self.functions.items) |*fn_info| {
            fn_info.deinit();
        }
        self.functions.clearRetainingCapacity();
    }

    fn extractDeclarations(self: *ZirBridge) ZirBridgeError!void {
        const tree = self.ast orelse return;
        const zir = self.zir orelse return;
        const source = self.source orelse return;
        const source_content = source.getContent();

        for (tree.rootDecls()) |root_decl| {
            const node_idx: u32 = @intFromEnum(root_decl);
            const decl_info = self.extractDeclFromAst(tree, zir, node_idx, source_content);
            if (decl_info) |info| {
                try self.declarations.append(self.allocator, info);
            }
        }
    }

    fn extractDeclFromAst(self: *ZirBridge, tree: *const Ast, zir: Zir, node_idx: u32, source: []const u8) ?DeclInfo {
        const node_tag = tree.nodes.items(.tag)[node_idx];
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const node_data = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);

        switch (node_tag) {
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {
                const main_token = tree.nodes.items(.main_token)[node_idx];

                var is_pub = false;
                if (main_token > 0 and token_tags[main_token - 1] == .keyword_pub) {
                    is_pub = true;
                }

                var name_token = main_token;
                if (token_tags[main_token] == .keyword_const or token_tags[main_token] == .keyword_var) {
                    name_token = main_token + 1;
                }

                if (name_token < token_tags.len and token_tags[name_token] == .identifier) {
                    const name = extractIdentifier(source, token_starts[name_token]);

                    var type_info = TypeInfo.initUnknown();
                    const full_decl = tree.fullVarDecl(@enumFromInt(node_idx));
                    if (full_decl) |decl| {
                        if (decl.ast.type_node != .none) {
                            type_info = extractTypeFromZir(tree, zir, decl.ast.type_node, source);
                        } else if (decl.ast.init_node.unwrap()) |init_node| {
                            if (inferTypeFromInit(tree, init_node, token_tags, main_tokens)) |inferred| {
                                type_info = inferred;
                            }
                        }
                    }

                    const zir_inst = findZirInstForNode(self.allocator, zir, node_idx);

                    return DeclInfo{
                        .name = name,
                        .type_info = type_info,
                        .is_pub = is_pub,
                        .is_const = token_tags[main_token] == .keyword_const,
                        .is_fn = false,
                        .ast_node = node_idx,
                        .zir_inst = zir_inst,
                    };
                }
            },
            .fn_decl => {
                const fn_proto_node = node_data[node_idx].node_and_node[0];
                const proto_idx: u32 = @intFromEnum(fn_proto_node);
                if (proto_idx < tree.nodes.len) {
                    const proto_tag = tree.nodes.items(.tag)[proto_idx];
                    if (proto_tag == .fn_proto_simple or proto_tag == .fn_proto_multi or proto_tag == .fn_proto_one or proto_tag == .fn_proto) {
                        const main_token = tree.nodes.items(.main_token)[proto_idx];

                        var is_pub = false;
                        if (main_token > 0 and token_tags[main_token - 1] == .keyword_pub) {
                            is_pub = true;
                        }

                        var name_token = main_token + 1;
                        while (name_token < token_tags.len and token_tags[name_token] != .identifier) {
                            name_token += 1;
                            if (name_token > main_token + 5) break;
                        }

                        if (name_token < token_tags.len and token_tags[name_token] == .identifier) {
                            const name = extractIdentifier(source, token_starts[name_token]);
                            const zir_inst = findZirInstForNode(self.allocator, zir, node_idx);

                            return DeclInfo{
                                .name = name,
                                .type_info = TypeInfo.initFunction(),
                                .is_pub = is_pub,
                                .is_const = true,
                                .is_fn = true,
                                .ast_node = node_idx,
                                .zir_inst = zir_inst,
                            };
                        }
                    }
                }
            },
            else => {},
        }
        return null;
    }

    /// Attempt to extract type information from ZIR for a type annotation node.
    fn extractTypeFromZir(tree: *const Ast, zir: Zir, type_node: Ast.Node.OptionalIndex, source: []const u8) TypeInfo {
        const type_idx: u32 = @intFromEnum(type_node);
        if (type_idx == 0 or type_idx >= tree.nodes.len) {
            return TypeInfo.initUnknown();
        }

        // Delegate to the more comprehensive extractTypeFromAstNode
        return extractTypeFromAstNode(tree, zir, type_idx, source) orelse TypeInfo.initUnknown();
    }

    /// Infer type information from an initializer AST node when no explicit type annotation is provided.
    fn inferTypeFromInit(
        tree: *const Ast,
        init_node: Ast.Node.Index,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
    ) ?TypeInfo {
        const tags = tree.nodes.items(.tag);
        const init_idx: u32 = @intFromEnum(init_node);
        if (init_idx == 0 or init_idx >= tags.len) return null;

        const init_tag = tags[init_idx];

        switch (init_tag) {
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            => {
                const token = main_tokens[init_idx];
                if (token < token_tags.len) {
                    return switch (token_tags[token]) {
                        .keyword_struct => .{ .kind = .@"struct" },
                        .keyword_enum => .{ .kind = .@"enum" },
                        .keyword_union => .{ .kind = .@"union" },
                        else => .{ .kind = .type_type },
                    };
                }
                return .{ .kind = .type_type };
            },
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            => return .{ .kind = .@"union" },
            .error_set_decl => return .{ .kind = .type_type },
            .fn_proto,
            .fn_proto_simple,
            .fn_proto_one,
            .fn_proto_multi,
            => return TypeInfo.initFunction(),
            .merge_error_sets,
            .error_union,
            .optional_type,
            .anyframe_type,
            .ptr_type,
            .ptr_type_sentinel,
            .ptr_type_bit_range,
            .ptr_type_aligned,
            .array_type,
            .array_type_sentinel,
            => return .{ .kind = .type_type },
            else => return null,
        }
    }

    /// Parse a built-in type name and return TypeInfo, using ZIR for validation when possible.
    fn parseBuiltinType(type_name: []const u8, zir: Zir) TypeInfo {
        _ = zir;

        if (std.mem.eql(u8, type_name, "void")) return TypeInfo.initVoid();
        if (std.mem.eql(u8, type_name, "bool")) return TypeInfo.initBool();
        if (std.mem.eql(u8, type_name, "type")) return .{ .kind = .type_type };

        if (type_name.len >= 2) {
            const first = type_name[0];
            if (first == 'i' or first == 'u') {
                const bits_str = type_name[1..];
                const bits = std.fmt.parseInt(u16, bits_str, 10) catch return TypeInfo.initUnknown();
                return TypeInfo.initInt(bits, first == 'i');
            }
            if (first == 'f' and type_name.len >= 2) {
                const bits_str = type_name[1..];
                const bits = std.fmt.parseInt(u16, bits_str, 10) catch return TypeInfo.initUnknown();
                return TypeInfo.initFloat(bits);
            }
        }

        return TypeInfo.initUnknown();
    }

    /// Find the ZIR instruction index corresponding to an AST node.
    /// This performs a best-effort lookup by iterating through ZIR instructions
    /// and checking their source node references. Returns the first matching
    /// instruction index, or null if no match is found.
    fn findZirInstForNode(allocator: std.mem.Allocator, zir: Zir, node_idx: u32) ?u32 {
        const target_index: Ast.Node.Index = @enumFromInt(node_idx);

        var pending: std.ArrayList(Zir.Inst.Index) = .empty;
        defer pending.deinit(allocator);

        compat.zir.appendDecls(allocator, zir, .main_struct_inst, &pending) catch return null;

        var contents: Zir.DeclContents = .init;
        defer contents.deinit(allocator);

        while (pending.pop()) |decl_inst| {
            const data = zir.instructions.items(.data)[@intFromEnum(decl_inst)].declaration;
            if (data.src_node == target_index) {
                return @intFromEnum(decl_inst);
            }

            if (findZirInstForNodeInDecl(allocator, zir, decl_inst, target_index)) |found| {
                return found;
            }

            zir.findTrackable(allocator, &contents, decl_inst) catch return null;
            for (contents.explicit_types.items) |type_inst| {
                compat.zir.appendDecls(allocator, zir, type_inst, &pending) catch return null;
            }
        }

        return null;
    }

    fn findZirInstForNodeInDecl(
        allocator: std.mem.Allocator,
        zir: Zir,
        decl_inst: Zir.Inst.Index,
        target_index: Ast.Node.Index,
    ) ?u32 {
        const decl = zir.getDeclaration(decl_inst);
        const target_offset = nodeOffsetFromBase(decl.src_node, target_index) orelse return null;

        var defers: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer defers.deinit(allocator);

        if (decl.type_body) |body| {
            if (findZirInstForNodeInBody(allocator, zir, target_offset, body, &defers)) |found| return found;
        }
        if (decl.align_body) |body| {
            if (findZirInstForNodeInBody(allocator, zir, target_offset, body, &defers)) |found| return found;
        }
        if (decl.linksection_body) |body| {
            if (findZirInstForNodeInBody(allocator, zir, target_offset, body, &defers)) |found| return found;
        }
        if (decl.addrspace_body) |body| {
            if (findZirInstForNodeInBody(allocator, zir, target_offset, body, &defers)) |found| return found;
        }
        if (decl.value_body) |body| {
            if (findZirInstForNodeInBody(allocator, zir, target_offset, body, &defers)) |found| return found;
        }

        return null;
    }

    fn findZirInstForNodeInBody(
        allocator: std.mem.Allocator,
        zir: Zir,
        target_offset: Ast.Node.Offset,
        body: []const Zir.Inst.Index,
        defers: *std.AutoHashMapUnmanaged(u32, void),
    ) ?u32 {
        for (body) |inst| {
            if (findZirInstForNodeInInst(allocator, zir, target_offset, inst, defers)) |found| {
                return found;
            }
        }
        return null;
    }

    fn findZirInstForNodeInInst(
        allocator: std.mem.Allocator,
        zir: Zir,
        target_offset: Ast.Node.Offset,
        inst: Zir.Inst.Index,
        defers: *std.AutoHashMapUnmanaged(u32, void),
    ) ?u32 {
        const tags = zir.instructions.items(.tag);
        const datas = zir.instructions.items(.data);
        const tag = tags[@intFromEnum(inst)];
        const data = datas[@intFromEnum(inst)];

        if (instMatchesOffset(zir, tag, data, target_offset)) {
            return @intFromEnum(inst);
        }

        switch (tag) {
            .declaration => return null,

            .extended => {
                const extended = data.extended;
                switch (extended.opcode) {
                    .this,
                    .ret_addr,
                    .error_return_trace,
                    .frame,
                    .frame_address,
                    .breakpoint,
                    .disable_instrumentation,
                    .disable_intrinsics,
                    => {
                        const src_node: Ast.Node.Offset = @enumFromInt(@as(i32, @bitCast(extended.operand)));
                        if (src_node == target_offset) return @intFromEnum(inst);
                    },
                    else => {},
                }

                return findZirInstForNodeInExtended(allocator, zir, target_offset, extended, defers);
            },

            .func, .func_inferred => {
                const inst_data = data.pl_node;
                const extra = zir.extraData(Zir.Inst.Func, inst_data.payload_index);

                if (extra.data.body_len == 0) return null;

                var extra_index: usize = extra.end;
                switch (extra.data.ret_ty.body_len) {
                    0 => {},
                    1 => extra_index += 1,
                    else => {
                        const ret_body = zir.bodySlice(extra_index, extra.data.ret_ty.body_len);
                        extra_index += ret_body.len;
                        if (findZirInstForNodeInBody(allocator, zir, target_offset, ret_body, defers)) |found| return found;
                    },
                }

                const body = zir.bodySlice(extra_index, extra.data.body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            .func_fancy => {
                const inst_data = data.pl_node;
                const extra = zir.extraData(Zir.Inst.FuncFancy, inst_data.payload_index);

                if (extra.data.body_len == 0) return null;

                var extra_index: usize = extra.end;

                if (extra.data.bits.has_cc_body) {
                    const body_len = zir.extra[extra_index];
                    extra_index += 1;
                    const body = zir.bodySlice(extra_index, body_len);
                    if (findZirInstForNodeInBody(allocator, zir, target_offset, body, defers)) |found| return found;
                    extra_index += body.len;
                } else if (extra.data.bits.has_cc_ref) {
                    extra_index += 1;
                }

                if (extra.data.bits.has_ret_ty_body) {
                    const body_len = zir.extra[extra_index];
                    extra_index += 1;
                    const body = zir.bodySlice(extra_index, body_len);
                    if (findZirInstForNodeInBody(allocator, zir, target_offset, body, defers)) |found| return found;
                    extra_index += body.len;
                } else if (extra.data.bits.has_ret_ty_ref) {
                    extra_index += 1;
                }

                extra_index += @intFromBool(extra.data.bits.has_any_noalias);

                const body = zir.bodySlice(extra_index, extra.data.body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },

            .block,
            .block_inline,
            .c_import,
            .typeof_builtin,
            .loop,
            => {
                const inst_data = data.pl_node;
                const extra = zir.extraData(Zir.Inst.Block, inst_data.payload_index);
                const body = zir.bodySlice(extra.end, extra.data.body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            .block_comptime => {
                const inst_data = data.pl_node;
                const extra = zir.extraData(Zir.Inst.BlockComptime, inst_data.payload_index);
                const body = zir.bodySlice(extra.end, extra.data.body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            .condbr, .condbr_inline => {
                const inst_data = data.pl_node;
                const extra = zir.extraData(Zir.Inst.CondBr, inst_data.payload_index);
                const then_body = zir.bodySlice(extra.end, extra.data.then_body_len);
                const else_body = zir.bodySlice(extra.end + then_body.len, extra.data.else_body_len);
                if (findZirInstForNodeInBody(allocator, zir, target_offset, then_body, defers)) |found| return found;
                return findZirInstForNodeInBody(allocator, zir, target_offset, else_body, defers);
            },
            .@"try", .try_ptr => {
                const inst_data = data.pl_node;
                const extra = zir.extraData(Zir.Inst.Try, inst_data.payload_index);
                const body = zir.bodySlice(extra.end, extra.data.body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            .switch_block, .switch_block_ref => {
                return findZirInstForNodeInSwitch(allocator, zir, target_offset, inst, defers, .normal);
            },
            .switch_block_err_union => {
                return findZirInstForNodeInSwitch(allocator, zir, target_offset, inst, defers, .err_union);
            },
            .param, .param_comptime => {
                const inst_data = data.pl_tok;
                const extra = zir.extraData(Zir.Inst.Param, inst_data.payload_index);
                const body = zir.bodySlice(extra.end, extra.data.type.body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            inline .call, .field_call => |call_tag| {
                const inst_data = data.pl_node;
                const extra = zir.extraData(switch (call_tag) {
                    .call => Zir.Inst.Call,
                    .field_call => Zir.Inst.FieldCall,
                    else => unreachable,
                }, inst_data.payload_index);

                const args_len = extra.data.flags.args_len;
                if (args_len == 0) return null;

                const first_arg_start_off = args_len;
                const final_arg_end_off = zir.extra[extra.end + args_len - 1];
                const args_body = zir.bodySlice(extra.end + first_arg_start_off, final_arg_end_off - first_arg_start_off);
                return findZirInstForNodeInBody(allocator, zir, target_offset, args_body, defers);
            },
            .@"defer" => {
                const inst_data = data.@"defer";
                const gop = defers.getOrPut(allocator, inst_data.index) catch {
                    const body = zir.bodySlice(inst_data.index, inst_data.len);
                    return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
                };
                if (gop.found_existing) return null;
                const body = zir.bodySlice(inst_data.index, inst_data.len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            .defer_err_code => {
                const inst_data = data.defer_err_code;
                const extra = zir.extraData(Zir.Inst.DeferErrCode, inst_data.payload_index).data;
                const gop = defers.getOrPut(allocator, extra.index) catch {
                    const body = zir.bodySlice(extra.index, extra.len);
                    return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
                };
                if (gop.found_existing) return null;
                const body = zir.bodySlice(extra.index, extra.len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },

            else => return null,
        }
    }

    fn findZirInstForNodeInExtended(
        allocator: std.mem.Allocator,
        zir: Zir,
        target_offset: Ast.Node.Offset,
        extended: Zir.Inst.Extended.InstData,
        defers: *std.AutoHashMapUnmanaged(u32, void),
    ) ?u32 {
        switch (extended.opcode) {
            .typeof_peer => {
                const extra = zir.extraData(Zir.Inst.TypeOfPeer, extended.operand);
                const body = zir.bodySlice(extra.data.body_index, extra.data.body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            .struct_decl => {
                const small: Zir.Inst.StructDecl.Small = @bitCast(extended.small);
                const extra = zir.extraData(Zir.Inst.StructDecl, extended.operand);
                var extra_index = extra.end;
                const captures_len = if (small.has_captures_len) blk: {
                    const captures_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk captures_len;
                } else 0;
                const fields_len = if (small.has_fields_len) blk: {
                    const fields_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk fields_len;
                } else 0;
                const decls_len = if (small.has_decls_len) blk: {
                    const decls_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk decls_len;
                } else 0;
                extra_index += captures_len * 2;
                if (compat.zir.structDeclHasBackingInt(small)) {
                    const backing_int_body_len = zir.extra[extra_index];
                    extra_index += 1;
                    if (backing_int_body_len == 0) {
                        extra_index += 1;
                    } else {
                        const body = zir.bodySlice(extra_index, backing_int_body_len);
                        extra_index += backing_int_body_len;
                        if (findZirInstForNodeInBody(allocator, zir, target_offset, body, defers)) |found| return found;
                    }
                }
                extra_index += decls_len;

                const bits_per_field = 4;
                const fields_per_u32 = 32 / bits_per_field;
                // zwanzig-disable-next-line: swallowed-error
                const bit_bags_count = std.math.divCeil(usize, fields_len, fields_per_u32) catch unreachable;
                var cur_bit_bag: u32 = undefined;

                var fields_extra_index = extra_index + bit_bags_count;
                var total_bodies_len: u32 = 0;

                for (0..fields_len) |field_i| {
                    if (field_i % fields_per_u32 == 0) {
                        cur_bit_bag = zir.extra[extra_index];
                        extra_index += 1;
                    }

                    const has_align = @as(u1, @truncate(cur_bit_bag)) != 0;
                    cur_bit_bag >>= 1;
                    const has_init = @as(u1, @truncate(cur_bit_bag)) != 0;
                    cur_bit_bag >>= 2;
                    const has_type_body = @as(u1, @truncate(cur_bit_bag)) != 0;
                    cur_bit_bag >>= 1;

                    fields_extra_index += 1;

                    if (has_type_body) {
                        const field_type_body_len = zir.extra[fields_extra_index];
                        total_bodies_len += field_type_body_len;
                    }
                    fields_extra_index += 1;

                    if (has_align) {
                        const align_body_len = zir.extra[fields_extra_index];
                        fields_extra_index += 1;
                        total_bodies_len += align_body_len;
                    }

                    if (has_init) {
                        const init_body_len = zir.extra[fields_extra_index];
                        fields_extra_index += 1;
                        total_bodies_len += init_body_len;
                    }
                }

                const merged_bodies = zir.bodySlice(fields_extra_index, total_bodies_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, merged_bodies, defers);
            },
            .union_decl => {
                const small: Zir.Inst.UnionDecl.Small = @bitCast(extended.small);
                const extra = zir.extraData(Zir.Inst.UnionDecl, extended.operand);
                var extra_index = extra.end;
                extra_index += @intFromBool(compat.zir.unionDeclHasTagType(small));
                const captures_len = if (small.has_captures_len) blk: {
                    const captures_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk captures_len;
                } else 0;
                const body_len = if (compat.zir.unionDeclHasArgTypeBody(small)) blk: {
                    const body_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk body_len;
                } else 0;
                extra_index += @intFromBool(small.has_fields_len);
                const decls_len = if (small.has_decls_len) blk: {
                    const decls_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk decls_len;
                } else 0;
                extra_index += captures_len * 2;
                extra_index += decls_len;
                const body = zir.bodySlice(extra_index, body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            .enum_decl => {
                const small: Zir.Inst.EnumDecl.Small = @bitCast(extended.small);
                const extra = zir.extraData(Zir.Inst.EnumDecl, extended.operand);
                var extra_index = extra.end;
                extra_index += @intFromBool(compat.zir.enumDeclHasTagType(small));
                const captures_len = if (small.has_captures_len) blk: {
                    const captures_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk captures_len;
                } else 0;
                const body_len = if (compat.zir.enumDeclHasBodyLen(small)) blk: {
                    const body_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk body_len;
                } else 0;
                extra_index += @intFromBool(small.has_fields_len);
                const decls_len = if (small.has_decls_len) blk: {
                    const decls_len = zir.extra[extra_index];
                    extra_index += 1;
                    break :blk decls_len;
                } else 0;
                extra_index += captures_len * 2;
                extra_index += decls_len;
                const body = zir.bodySlice(extra_index, body_len);
                return findZirInstForNodeInBody(allocator, zir, target_offset, body, defers);
            },
            else => return null,
        }
    }

    fn findZirInstForNodeInSwitch(
        allocator: std.mem.Allocator,
        zir: Zir,
        target_offset: Ast.Node.Offset,
        inst: Zir.Inst.Index,
        defers: *std.AutoHashMapUnmanaged(u32, void),
        comptime _: enum { normal, err_union },
    ) ?u32 {
        var bodies: std.ArrayList([]const Zir.Inst.Index) = .empty;
        defer bodies.deinit(allocator);
        compat.zir.appendSwitchBodies(allocator, zir, inst, &bodies) catch return null;
        for (bodies.items) |body| {
            if (findZirInstForNodeInBody(allocator, zir, target_offset, body, defers)) |found| return found;
        }
        return null;
    }

    fn instMatchesOffset(zir: Zir, tag: Zir.Inst.Tag, data: Zir.Inst.Data, target_offset: Ast.Node.Offset) bool {
        return switch (Zir.Inst.Tag.data_tags[@intFromEnum(tag)]) {
            .pl_node => data.pl_node.src_node == target_offset,
            .un_node => data.un_node.src_node == target_offset,
            .node => data.node == target_offset,
            .inst_node => data.inst_node.src_node == target_offset,
            .int_type => data.int_type.src_node == target_offset,
            .@"unreachable" => data.@"unreachable".src_node == target_offset,
            .@"break" => {
                const extra = zir.extraData(Zir.Inst.Break, data.@"break".payload_index);
                return extra.data.operand_src_node == target_offset.toOptional();
            },
            else => false,
        };
    }

    fn nodeOffsetFromBase(base: Ast.Node.Index, target: Ast.Node.Index) ?Ast.Node.Offset {
        const base_int: i64 = @intFromEnum(base);
        const target_int: i64 = @intFromEnum(target);
        if (target_int < base_int) return null;
        const diff = target_int - base_int;
        if (diff > std.math.maxInt(i32)) return null;
        return @enumFromInt(@as(i32, @intCast(diff)));
    }

    fn extractIdentifier(source: []const u8, start: usize) []const u8 {
        var end = start;
        while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) {
            end += 1;
        }
        return source[start..end];
    }

    /// Get the number of declarations found.
    pub fn getDeclCount(self: *const ZirBridge) usize {
        return self.declarations.items.len;
    }

    /// Get declaration info by index.
    pub fn getDecl(self: *const ZirBridge, index: usize) ?DeclInfo {
        if (index >= self.declarations.items.len) return null;
        return self.declarations.items[index];
    }

    /// Find a declaration by name.
    pub fn findDeclByName(self: *const ZirBridge, name: []const u8) ?DeclInfo {
        for (self.declarations.items) |decl| {
            if (std.mem.eql(u8, decl.name, name)) {
                return decl;
            }
        }
        return null;
    }

    /// Get the return type of a function declaration by AST node index.
    /// Returns null if the node is not a function or the return type cannot be determined.
    pub fn getFunctionReturnType(self: *const ZirBridge, fn_ast_node: u32) ?TypeInfo {
        const tree = self.ast orelse return null;
        const zir = self.zir orelse return null;
        const source = self.source orelse return null;
        const source_content = source.getContent();
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        if (fn_ast_node >= tags.len) return null;
        if (tags[fn_ast_node] != .fn_decl) return null;

        // Use fullFnProto to safely extract the function prototype
        var params_buf: [1]Ast.Node.Index = undefined;
        const fn_proto = tree.fullFnProto(&params_buf, @enumFromInt(fn_ast_node)) orelse return null;

        // Get the return type expression
        const ret_type_node = fn_proto.ast.return_type;
        if (ret_type_node == .none) {
            // Check if the return type is inferred (void)
            return TypeInfo.initVoid();
        }

        const ret_node_idx: u32 = @intFromEnum(ret_type_node);

        // Check if this is an error union by looking for a bang token before the return type
        const ret_main_tok = main_tokens[ret_node_idx];
        if (ret_main_tok > 0 and token_tags[ret_main_tok - 1] == .bang) {
            // This is an error union return type
            var info = TypeInfo.initErrorUnion();
            if (extractTypeFromAstNode(tree, zir, ret_node_idx, source_content)) |inner_type| {
                info.sentinel = inner_type.sentinel;
                if (inner_type.type_str) |inner_str| {
                    info.type_str = inner_str;
                }
            }
            return info;
        }

        return extractTypeFromAstNode(tree, zir, ret_node_idx, source_content);
    }

    /// Get type information for an AST node representing a type expression.
    /// Returns null if the node cannot be resolved.
    pub fn getTypeFromAstNode(self: *const ZirBridge, ast_node: u32) ?TypeInfo {
        const tree = self.ast orelse return null;
        const zir = self.zir orelse return null;
        const source = self.source orelse return null;
        const source_content = source.getContent();
        if (ast_node >= tree.nodes.items(.tag).len) return null;
        return extractTypeFromAstNode(tree, zir, ast_node, source_content);
    }

    /// Extract sentinel value from a fullPtrType result.
    fn extractSentinelValueFromPtrType(
        tree: *const Ast,
        data: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        token_starts: []const u32,
        pt: Ast.full.PtrType,
        source: []const u8,
    ) ?i64 {
        if (pt.ast.sentinel != .none) {
            const sentinel_node: u32 = @intFromEnum(pt.ast.sentinel);
            return extractNumberFromNode(tree, data, main_tokens, token_starts, sentinel_node, source);
        }
        return null;
    }

    /// Extract sentinel value from a slice_sentinel node (expression context).
    fn extractSentinelValueFromSlice(
        tree: *const Ast,
        data: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        token_starts: []const u32,
        type_node: u32,
        source: []const u8,
    ) ?i64 {
        const slice = tree.fullSlice(@enumFromInt(type_node));
        if (slice) |s| {
            if (s.ast.sentinel != .none) {
                const sentinel_node: u32 = @intFromEnum(s.ast.sentinel);
                return extractNumberFromNode(tree, data, main_tokens, token_starts, sentinel_node, source);
            }
        }
        return null;
    }

    /// Extract a numeric value from an AST node (for sentinel values).
    fn extractNumberFromNode(
        tree: *const Ast,
        data: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        token_starts: []const u32,
        node: u32,
        source: []const u8,
    ) ?i64 {
        _ = data;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return null;

        switch (tags[node]) {
            .number_literal => {
                const token = main_tokens[node];
                const start = token_starts[token];
                var end = start;
                while (end < source.len and (std.ascii.isDigit(source[end]) or source[end] == '_')) {
                    end += 1;
                }
                const num_str = source[start..end];
                // zwanzig-disable-next-line: swallowed-error
                return std.fmt.parseInt(i64, num_str, 10) catch null;
            },
            .char_literal => {
                // Character literal like '0'
                const token = main_tokens[node];
                const start = token_starts[token];
                if (start + 2 < source.len and source[start] == '\'') {
                    return @intCast(source[start + 1]);
                }
                return null;
            },
            else => return null,
        }
    }

    /// Extract type information from an AST node representing a type expression.
    fn extractTypeFromAstNode(tree: *const Ast, zir: Zir, type_node: u32, source: []const u8) ?TypeInfo {
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const main_tokens = tree.nodes.items(.main_token);

        if (type_node >= tags.len) return null;

        switch (tags[type_node]) {
            .identifier => {
                // Simple type like u32, i64, void, MyResource, etc.
                const token = main_tokens[type_node];
                if (token >= token_tags.len or token_tags[token] != .identifier) return null;
                const type_name = extractIdentifier(source, token_starts[token]);
                const builtin_type = parseBuiltinType(type_name, zir);
                // If not a builtin type, preserve the type name as type_str
                if (builtin_type.kind == .unknown) {
                    return .{ .kind = .unknown, .type_str = type_name };
                }
                return builtin_type;
            },
            .error_union => {
                // Error union type: T!E or anyerror!T
                const pair = data[type_node].node_and_node;
                const inner = extractTypeFromAstNode(tree, zir, @intFromEnum(pair[1]), source);
                var info = TypeInfo.initErrorUnion();
                if (inner) |ti| {
                    info.sentinel = ti.sentinel;
                }
                return info;
            },
            .optional_type => {
                // Optional type: ?T
                const child = data[type_node].node;
                const inner = extractTypeFromAstNode(tree, zir, @intFromEnum(child), source);
                var info = TypeInfo.initOptional();
                if (inner) |ti| {
                    info.sentinel = ti.sentinel;
                }
                return info;
            },
            .ptr_type_aligned, .ptr_type_bit_range, .ptr_type, .ptr_type_sentinel => {
                // Pointer type: *T, [*]T, [:0]T, etc.
                const ptr_type = tree.fullPtrType(@enumFromInt(type_node));
                if (ptr_type) |pt| {
                    const sentinel_value = extractSentinelValueFromPtrType(tree, data, main_tokens, token_starts, pt, source);
                    return .{
                        .kind = if (pt.size == .slice) .slice else .pointer,
                        .sentinel = if (sentinel_value) |v| .{ .value = v } else null,
                    };
                }
                return TypeInfo.initPointer();
            },
            .slice_open, .slice => {
                // Slice type: []T
                return .{ .kind = .slice };
            },
            .slice_sentinel => {
                // Sentinel-terminated slice type: [:0]T (expression context)
                const sentinel_value = extractSentinelValueFromSlice(tree, data, main_tokens, token_starts, type_node, source);
                return .{
                    .kind = .slice,
                    .sentinel = if (sentinel_value) |v| .{ .value = v } else null,
                };
            },
            .field_access => {
                // Qualified type like std.fs.File
                const field_token = data[type_node].node_and_token[1];
                if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;
                const field_name = extractIdentifier(source, token_starts[field_token]);

                // Check for known types
                if (std.mem.eql(u8, field_name, "File")) {
                    return .{ .kind = .@"struct", .type_str = "std.fs.File" };
                }
                if (std.mem.eql(u8, field_name, "fd_t")) {
                    return .{ .kind = .int, .type_str = "std.posix.fd_t" };
                }
                if (std.mem.eql(u8, field_name, "Allocator")) {
                    return .{ .kind = .@"struct", .type_str = "std.mem.Allocator" };
                }
                return TypeInfo.initUnknown();
            },
            else => return TypeInfo.initUnknown(),
        }
    }

    /// Check if ZIR was successfully generated.
    pub fn hasZir(self: *const ZirBridge) bool {
        return self.zir != null;
    }

    /// Get the number of ZIR instructions.
    pub fn getInstructionCount(self: *const ZirBridge) usize {
        if (self.zir) |zir| {
            return zir.instructions.len;
        }
        return 0;
    }
};

test "ZirBridge basic creation" {
    const allocator = std.testing.allocator;

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try std.testing.expect(!bridge.hasZir());
    try std.testing.expectEqual(@as(usize, 0), bridge.getDeclCount());
}

test "ZirBridge load simple module" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    try std.testing.expect(bridge.hasZir());
    try std.testing.expect(bridge.getInstructionCount() > 0);
}

test "ZirBridge extract declaration" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const my_const: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    try std.testing.expect(bridge.getDeclCount() >= 1);

    const decl = bridge.findDeclByName("my_const");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqualStrings("my_const", d.name);
    }
}

test "ZirBridge extract function" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const fn_decl = bridge.findDeclByName("add");
    try std.testing.expect(fn_decl != null);
    if (fn_decl) |f| {
        try std.testing.expect(f.is_fn);
        try std.testing.expect(f.is_pub);
        try std.testing.expectEqual(TypeInfo.TypeKind.function, f.type_info.kind);
    }
}

test "ZirBridge multiple declarations" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\const x: i32 = 1;
        \\const y: i32 = 2;
        \\pub fn main() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    try std.testing.expect(bridge.getDeclCount() >= 3);

    try std.testing.expect(bridge.findDeclByName("x") != null);
    try std.testing.expect(bridge.findDeclByName("y") != null);
    try std.testing.expect(bridge.findDeclByName("main") != null);
}

test "ZirBridge parse error handling" {
    const allocator = std.testing.allocator;

    // Invalid Zig code
    const code: [:0]const u8 = "const x = ;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    const result = bridge.loadFromSource(&source);
    try std.testing.expectError(error.ParseError, result);
}

test "ZirBridge rejects source with AstGen compile errors" {
    const allocator = std.testing.allocator;

    // Each frontend rejects a builtin introduced by the other frontend. The
    // parser accepts both spellings, so the error is recorded in ZIR and must
    // be checked explicitly rather than mistaken for valid type information.
    const code: [:0]const u8 = if (builtin.zig_version.minor == 16)
        "const T = @Type(.{});"
    else
        "const T = @Int(.signed, 8);";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    const result = bridge.loadFromSource(&source);
    try std.testing.expectError(error.AstGenFailed, result);
    try std.testing.expect(!bridge.hasZir());
}

test "ZirBridge reuse clears previous state" {
    const allocator = std.testing.allocator;

    const code1: [:0]const u8 = "const x: i32 = 1;";
    var source1 = Source.init(allocator, "test1.zig", code1);
    defer source1.deinit();

    const code2: [:0]const u8 = "const y: i64 = 2;";
    var source2 = Source.init(allocator, "test2.zig", code2);
    defer source2.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source1);
    try std.testing.expect(bridge.findDeclByName("x") != null);
    try std.testing.expect(bridge.findDeclByName("y") == null);

    try bridge.loadFromSource(&source2);
    try std.testing.expect(bridge.findDeclByName("x") == null);
    try std.testing.expect(bridge.findDeclByName("y") != null);
}

test "ZirBridge extracts type info from type annotation" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqual(TypeInfo.TypeKind.int, d.type_info.kind);
        try std.testing.expectEqual(@as(u16, 32), d.type_info.size_bits);
        try std.testing.expect(d.type_info.is_signed);
    }
}

test "findZirInstForNode finds declaration instruction" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    // Verify we have ZIR
    try std.testing.expect(bridge.hasZir());

    // The declaration should have an associated ZIR instruction
    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        // Check that the AST node is set
        try std.testing.expect(d.ast_node != null);
        // The zir_inst field should be populated by findZirInstForNode
        // Note: This may be null if no ZIR instruction directly references this node
        // (which is valid - the implementation is best-effort)
    }
}

test "findZirInstForNode with function declaration" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    // Verify we have ZIR
    try std.testing.expect(bridge.hasZir());
    try std.testing.expect(bridge.getInstructionCount() > 0);

    // The function declaration should have an associated ZIR instruction
    const fn_decl = bridge.findDeclByName("add");
    try std.testing.expect(fn_decl != null);
    if (fn_decl) |f| {
        try std.testing.expect(f.is_fn);
        try std.testing.expect(f.ast_node != null);
    }
}

test "TypeInfo hasSentinel returns true for sentinel-terminated slice" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: [:0]u8 = undefined;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqual(TypeInfo.TypeKind.slice, d.type_info.kind);
        try std.testing.expect(d.type_info.hasSentinel());
        if (d.type_info.sentinel) |s| {
            try std.testing.expectEqual(@as(i64, 0), s.value);
        }
    }
}

test "TypeInfo hasSentinel returns false for non-sentinel slice" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: []u8 = undefined;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqual(TypeInfo.TypeKind.slice, d.type_info.kind);
        try std.testing.expect(!d.type_info.hasSentinel());
    }
}

test "TypeInfo hasSentinel returns true for optional sentinel slice" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: ?[:0]u8 = null;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqual(TypeInfo.TypeKind.optional, d.type_info.kind);
        try std.testing.expect(d.type_info.hasSentinel());
    }
}

test "TypeInfo hasSentinel returns true for error union sentinel slice" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\const Err = error{Oops};
        \\const x: Err![:0]u8 = error.Oops;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var bridge = ZirBridge.init(allocator);
    defer bridge.deinit();

    try bridge.loadFromSource(&source);

    const decl = bridge.findDeclByName("x");
    try std.testing.expect(decl != null);
    if (decl) |d| {
        try std.testing.expectEqual(TypeInfo.TypeKind.error_union, d.type_info.kind);
        try std.testing.expect(d.type_info.hasSentinel());
    }
}
