const std = @import("std");
const ids = @import("../ids.zig");

const VarId = ids.VarId;
const ResolveError = std.mem.Allocator.Error;

pub const VarResolver = struct {
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    mappings: std.AutoHashMap(u32, VarId),
    decl_mappings: std.AutoHashMap(VarId, DeclInfo),
    scope_stack: std.ArrayListUnmanaged(std.ArrayListUnmanaged(NameBinding)),

    pub const DeclInfo = struct {
        decl_node: u32,
        is_top_level: bool,
    };

    const NameBinding = struct {
        name: []const u8,
        var_id: VarId,
    };

    pub fn init(allocator: std.mem.Allocator, tree: *const std.zig.Ast, fn_node: ids.AstNodeId) ResolveError!VarResolver {
        var resolver = VarResolver{
            .allocator = allocator,
            .tree = tree,
            .mappings = std.AutoHashMap(u32, VarId).init(allocator),
            .decl_mappings = std.AutoHashMap(VarId, DeclInfo).init(allocator),
            .scope_stack = .empty,
        };
        errdefer resolver.deinit();

        try resolver.pushScope();
        try resolver.addGlobalDecls();

        try resolver.pushScope();
        try resolver.addFnParams(ids.astIndex(fn_node));

        const body_node = resolver.getFnBody(ids.astIndex(fn_node)) orelse 0;

        try resolver.pushScope();
        if (body_node != 0) {
            try resolver.scanNode(body_node);
        }
        resolver.popScope();
        resolver.popScope();
        resolver.popScope();

        return resolver;
    }

    pub fn deinit(self: *VarResolver) void {
        self.mappings.deinit();
        self.decl_mappings.deinit();

        for (self.scope_stack.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scope_stack.deinit(self.allocator);
    }

    pub fn resolve(self: *const VarResolver, identifier_node: u32) ?VarId {
        return self.mappings.get(identifier_node);
    }

    pub fn resolveDeclInfo(self: *const VarResolver, identifier_node: u32) ?DeclInfo {
        const var_id = self.resolve(identifier_node) orelse return null;
        return self.decl_mappings.get(var_id);
    }

    pub fn resolveDeclNode(self: *const VarResolver, identifier_node: u32) ?u32 {
        const info = self.resolveDeclInfo(identifier_node) orelse return null;
        return info.decl_node;
    }

    fn pushScope(self: *VarResolver) ResolveError!void {
        try self.scope_stack.append(self.allocator, .empty);
    }

    fn popScope(self: *VarResolver) void {
        if (self.scope_stack.items.len == 0) return;
        var scope = self.scope_stack.pop() orelse return;
        scope.deinit(self.allocator);
    }

    fn addBinding(self: *VarResolver, name: []const u8, var_id: VarId, decl_node: ?u32, is_top_level: bool) ResolveError!void {
        if (self.scope_stack.items.len == 0) return;
        var scope = &self.scope_stack.items[self.scope_stack.items.len - 1];
        try scope.append(self.allocator, .{ .name = name, .var_id = var_id });
        if (decl_node) |node| {
            try self.decl_mappings.put(var_id, .{ .decl_node = node, .is_top_level = is_top_level });
        }
    }

    fn resolveName(self: *const VarResolver, name: []const u8) ?VarId {
        if (self.scope_stack.items.len == 0) return null;
        var idx = self.scope_stack.items.len;
        while (idx > 0) : (idx -= 1) {
            const scope = &self.scope_stack.items[idx - 1];
            var i = scope.items.len;
            while (i > 0) : (i -= 1) {
                const binding = scope.items[i - 1];
                if (std.mem.eql(u8, binding.name, name)) {
                    return binding.var_id;
                }
            }
        }
        return null;
    }

    fn recordIdentifier(self: *VarResolver, node: u32) ResolveError!void {
        const main_tokens = self.tree.nodes.items(.main_token);
        const token_tags = self.tree.tokens.items(.tag);

        if (node >= main_tokens.len) return;
        const token = main_tokens[node];
        if (token >= token_tags.len or token_tags[token] != .identifier) return;

        const name = self.tree.tokenSlice(token);
        if (self.resolveName(name)) |var_id| {
            try self.mappings.put(node, var_id);
        }
    }

    fn addGlobalDecls(self: *VarResolver) ResolveError!void {
        const root_decls = self.tree.rootDecls();
        const tags = self.tree.nodes.items(.tag);
        const token_tags = self.tree.tokens.items(.tag);

        for (root_decls) |decl_idx| {
            const node = @intFromEnum(decl_idx);
            if (node >= tags.len) continue;
            switch (tags[node]) {
                .simple_var_decl,
                .aligned_var_decl,
                .local_var_decl,
                .global_var_decl,
                => {
                    const full = self.tree.fullVarDecl(@enumFromInt(node)) orelse continue;
                    const name_token = full.ast.mut_token + 1;
                    if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                    const name = self.tree.tokenSlice(name_token);
                    try self.addBinding(name, ids.varId(name_token), node, true);
                },
                else => {},
            }
        }
    }

    fn addFnParams(self: *VarResolver, fn_node: u32) ResolveError!void {
        const tags = self.tree.nodes.items(.tag);
        if (fn_node >= tags.len) return;

        // Test declarations don't have parameters
        if (tags[fn_node] == .test_decl) return;

        const data = self.tree.nodes.items(.data)[fn_node];
        const proto_node = @intFromEnum(data.node_and_node[0]);
        if (proto_node == 0 or proto_node >= tags.len) return;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tags[proto_node]) {
            .fn_proto => self.tree.fnProto(@enumFromInt(proto_node)),
            .fn_proto_simple => self.tree.fnProtoSimple(&buffer, @enumFromInt(proto_node)),
            .fn_proto_one => self.tree.fnProtoOne(&buffer, @enumFromInt(proto_node)),
            .fn_proto_multi => self.tree.fnProtoMulti(@enumFromInt(proto_node)),
            else => return,
        };

        var it = proto.iterate(self.tree);
        while (it.next()) |param| {
            if (param.name_token) |name_tok| {
                const name = self.tree.tokenSlice(name_tok);
                try self.addBinding(name, ids.varId(name_tok), null, false);
            }
        }
    }

    fn getFnBody(self: *const VarResolver, fn_node: u32) ?u32 {
        const tags = self.tree.nodes.items(.tag);
        if (fn_node >= tags.len) return null;

        const data = self.tree.nodes.items(.data)[fn_node];

        if (tags[fn_node] == .test_decl) {
            // test_decl uses opt_token_and_node: [1] is the body
            return @intFromEnum(data.opt_token_and_node[1]);
        }

        if (tags[fn_node] != .fn_decl) return null;
        return @intFromEnum(data.node_and_node[1]);
    }

    fn scanNode(self: *VarResolver, node: u32) ResolveError!void {
        if (node == 0) return;

        const tags = self.tree.nodes.items(.tag);
        if (node >= tags.len) return;

        switch (tags[node]) {
            .identifier => try self.recordIdentifier(node),
            .simple_var_decl,
            .aligned_var_decl,
            .local_var_decl,
            .global_var_decl,
            => try self.scanVarDecl(node),
            .block,
            .block_semicolon,
            .block_two,
            .block_two_semicolon,
            => try self.scanBlock(node),
            .@"if",
            .if_simple,
            => try self.scanIf(node),
            .@"while",
            .while_simple,
            .while_cont,
            => try self.scanWhile(node),
            .@"for",
            .for_simple,
            => try self.scanFor(node),
            .@"switch",
            .switch_comma,
            => try self.scanSwitch(node),
            .@"catch" => try self.scanCatch(node),
            .@"errdefer" => try self.scanErrdefer(node),
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
            => try self.scanContainer(node),
            else => try self.scanChildren(node),
        }
    }

    fn scanChildren(self: *VarResolver, node: u32) ResolveError!void {
        const tags = self.tree.nodes.items(.tag);
        const data = self.tree.nodes.items(.data);
        const tag = tags[node];

        switch (tag) {
            .equal_equal,
            .bang_equal,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
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
            .merge_error_sets,
            .mul,
            .div,
            .mod,
            .array_mult,
            .mul_wrap,
            .mul_sat,
            .add,
            .sub,
            .array_cat,
            .add_wrap,
            .sub_wrap,
            .add_sat,
            .sub_sat,
            .shl,
            .shl_sat,
            .shr,
            .bit_and,
            .bit_xor,
            .bit_or,
            .@"orelse",
            .bool_and,
            .bool_or,
            .error_union,
            .array_access,
            .switch_range,
            => {
                const pair = data[node].node_and_node;
                try self.scanNode(@intFromEnum(pair[0]));
                try self.scanNode(@intFromEnum(pair[1]));
            },

            .bool_not,
            .negation,
            .bit_not,
            .negation_wrap,
            .address_of,
            .@"try",
            .optional_type,
            .@"suspend",
            .@"resume",
            .@"nosuspend",
            .@"comptime",
            .deref,
            .@"defer",
            => try self.scanNode(@intFromEnum(data[node].node)),

            .unwrap_optional,
            .grouped_expression,
            => try self.scanNode(@intFromEnum(data[node].node_and_token[0])),

            .@"return" => {
                if (data[node].opt_node.unwrap()) |ret_node| {
                    try self.scanNode(@intFromEnum(ret_node));
                }
            },

            .field_access => {
                try self.scanNode(@intFromEnum(data[node].node_and_token[0]));
            },

            .call, .call_comma, .call_one, .call_one_comma => {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                const call_info = self.tree.fullCall(&buf, @enumFromInt(node)) orelse return;
                try self.scanNode(@intFromEnum(call_info.ast.fn_expr));
                for (call_info.ast.params) |param| {
                    try self.scanNode(@intFromEnum(param));
                }
            },

            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const params = self.tree.builtinCallParams(&buf, @enumFromInt(node)) orelse return;
                for (params) |param| {
                    try self.scanNode(@intFromEnum(param));
                }
            },

            .struct_init, .struct_init_comma, .struct_init_one, .struct_init_one_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const struct_init = self.tree.fullStructInit(&buf, @enumFromInt(node)) orelse return;
                if (struct_init.ast.type_expr.unwrap()) |type_node| {
                    try self.scanNode(@intFromEnum(type_node));
                }
                for (struct_init.ast.fields) |field| {
                    try self.scanNode(@intFromEnum(field));
                }
            },

            .array_init, .array_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const array_init = self.tree.fullArrayInit(&buf, @enumFromInt(node)) orelse return;
                if (array_init.ast.type_expr.unwrap()) |type_node| {
                    try self.scanNode(@intFromEnum(type_node));
                }
                for (array_init.ast.elements) |elem| {
                    try self.scanNode(@intFromEnum(elem));
                }
            },

            .slice, .slice_open, .slice_sentinel => {
                const slice = self.tree.fullSlice(@enumFromInt(node)) orelse return;
                try self.scanNode(@intFromEnum(slice.ast.sliced));
                try self.scanNode(@intFromEnum(slice.ast.start));
                if (slice.ast.end.unwrap()) |end_node| {
                    try self.scanNode(@intFromEnum(end_node));
                }
                if (slice.ast.sentinel.unwrap()) |sentinel_node| {
                    try self.scanNode(@intFromEnum(sentinel_node));
                }
            },

            else => {},
        }
    }

    fn scanVarDecl(self: *VarResolver, node: u32) ResolveError!void {
        const full = self.tree.fullVarDecl(@enumFromInt(node)) orelse return;
        const token_tags = self.tree.tokens.items(.tag);

        if (full.ast.init_node.unwrap()) |init_node| {
            try self.scanNode(@intFromEnum(init_node));
        }

        const name_token = full.ast.mut_token + 1;
        if (name_token >= token_tags.len or token_tags[name_token] != .identifier) return;
        const name = self.tree.tokenSlice(name_token);
        try self.addBinding(name, ids.varId(name_token), node, false);
    }

    fn scanBlock(self: *VarResolver, node: u32) ResolveError!void {
        const tags = self.tree.nodes.items(.tag);
        const data = self.tree.nodes.items(.data);

        var statements: []const u32 = &.{};
        var scratch_buf: [2]u32 = undefined;

        switch (tags[node]) {
            .block, .block_semicolon => {
                const extra_range = data[node].extra_range;
                const start = @intFromEnum(extra_range.start);
                const end = @intFromEnum(extra_range.end);
                statements = self.tree.extra_data[start..end];
            },
            .block_two, .block_two_semicolon => {
                const opt_nodes = data[node].opt_node_and_opt_node;
                var count: usize = 0;
                if (opt_nodes[0].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                if (opt_nodes[1].unwrap()) |n| {
                    scratch_buf[count] = @intFromEnum(n);
                    count += 1;
                }
                statements = scratch_buf[0..count];
            },
            else => return,
        }

        try self.pushScope();
        defer self.popScope();

        for (statements) |stmt| {
            try self.scanNode(stmt);
        }
    }

    fn scanIf(self: *VarResolver, node: u32) ResolveError!void {
        const full_if = self.tree.fullIf(@enumFromInt(node)) orelse return;

        try self.scanNode(@intFromEnum(full_if.ast.cond_expr));

        try self.pushScope();
        if (full_if.payload_token) |tok| {
            try self.addPayloadName(tok);
        }
        try self.scanNode(@intFromEnum(full_if.ast.then_expr));
        self.popScope();

        if (full_if.ast.else_expr.unwrap()) |else_node| {
            try self.pushScope();
            if (full_if.error_token) |tok| {
                try self.addPayloadName(tok);
            }
            try self.scanNode(@intFromEnum(else_node));
            self.popScope();
        }
    }

    fn scanWhile(self: *VarResolver, node: u32) ResolveError!void {
        const full_while = self.tree.fullWhile(@enumFromInt(node)) orelse return;

        try self.scanNode(@intFromEnum(full_while.ast.cond_expr));

        try self.pushScope();
        if (full_while.payload_token) |tok| {
            try self.addPayloadName(tok);
        }
        try self.scanNode(@intFromEnum(full_while.ast.then_expr));
        self.popScope();

        if (full_while.ast.else_expr.unwrap()) |else_node| {
            try self.pushScope();
            if (full_while.error_token) |tok| {
                try self.addPayloadName(tok);
            }
            try self.scanNode(@intFromEnum(else_node));
            self.popScope();
        }

        if (full_while.ast.cont_expr.unwrap()) |cont_node| {
            try self.scanNode(@intFromEnum(cont_node));
        }
    }

    fn scanFor(self: *VarResolver, node: u32) ResolveError!void {
        const full_for = self.tree.fullFor(@enumFromInt(node)) orelse return;

        for (full_for.ast.inputs) |input| {
            try self.scanNode(@intFromEnum(input));
        }

        try self.pushScope();
        try self.addForPayloads(full_for.payload_token);
        try self.scanNode(@intFromEnum(full_for.ast.then_expr));
        self.popScope();

        if (full_for.ast.else_expr.unwrap()) |else_node| {
            try self.pushScope();
            try self.scanNode(@intFromEnum(else_node));
            self.popScope();
        }
    }

    fn scanSwitch(self: *VarResolver, node: u32) ResolveError!void {
        const full_switch = self.tree.switchFull(@enumFromInt(node));

        try self.scanNode(@intFromEnum(full_switch.ast.condition));

        for (full_switch.ast.cases) |case_node| {
            try self.scanSwitchCase(@intFromEnum(case_node));
        }
    }

    fn scanSwitchCase(self: *VarResolver, node: u32) ResolveError!void {
        const full_case = self.tree.fullSwitchCase(@enumFromInt(node)) orelse return;

        for (full_case.ast.values) |value| {
            try self.scanNode(@intFromEnum(value));
        }

        try self.pushScope();
        if (full_case.payload_token) |tok| {
            try self.addPayloadName(tok);
        }
        try self.scanNode(@intFromEnum(full_case.ast.target_expr));
        self.popScope();
    }

    fn scanCatch(self: *VarResolver, node: u32) ResolveError!void {
        const data = self.tree.nodes.items(.data)[node].node_and_node;
        const main_tokens = self.tree.nodes.items(.main_token);
        const token_tags = self.tree.tokens.items(.tag);

        try self.scanNode(@intFromEnum(data[0]));

        var payload_token: ?u32 = null;
        const catch_token = main_tokens[node];
        if (catch_token + 2 < token_tags.len and token_tags[catch_token + 1] == .pipe) {
            payload_token = catch_token + 2;
        }

        try self.pushScope();
        if (payload_token) |tok| {
            try self.addPayloadName(tok);
        }
        try self.scanNode(@intFromEnum(data[1]));
        self.popScope();
    }

    fn scanErrdefer(self: *VarResolver, node: u32) ResolveError!void {
        const data = self.tree.nodes.items(.data)[node].opt_token_and_node;
        const payload_token = data[0].unwrap();
        const expr_node = data[1];

        try self.pushScope();
        if (payload_token) |tok| {
            try self.addPayloadName(tok);
        }
        try self.scanNode(@intFromEnum(expr_node));
        self.popScope();
    }

    fn scanContainer(self: *VarResolver, node: u32) ResolveError!void {
        const tags = self.tree.nodes.items(.tag);
        var buf: [2]std.zig.Ast.Node.Index = undefined;

        const members: []const std.zig.Ast.Node.Index = switch (tags[node]) {
            .container_decl, .container_decl_trailing => self.tree.containerDecl(@enumFromInt(node)).ast.members,
            .container_decl_two, .container_decl_two_trailing => self.tree.containerDeclTwo(&buf, @enumFromInt(node)).ast.members,
            .container_decl_arg, .container_decl_arg_trailing => self.tree.containerDeclArg(@enumFromInt(node)).ast.members,
            .tagged_union, .tagged_union_trailing => self.tree.taggedUnion(@enumFromInt(node)).ast.members,
            .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => self.tree.taggedUnionEnumTag(@enumFromInt(node)).ast.members,
            .tagged_union_two, .tagged_union_two_trailing => self.tree.taggedUnionTwo(&buf, @enumFromInt(node)).ast.members,
            else => return,
        };

        const saved_stack = self.scope_stack;
        self.scope_stack = .empty;
        defer {
            for (self.scope_stack.items) |*scope| {
                scope.deinit(self.allocator);
            }
            self.scope_stack.deinit(self.allocator);
            self.scope_stack = saved_stack;
        }

        try self.pushScope();
        defer self.popScope();

        for (members) |member| {
            try self.scanNode(@intFromEnum(member));
        }
    }

    fn addPayloadName(self: *VarResolver, token: u32) ResolveError!void {
        const token_tags = self.tree.tokens.items(.tag);

        if (token >= token_tags.len) return;

        var tok = token;
        if (token_tags[tok] == .pipe) tok += 1;
        if (tok < token_tags.len and token_tags[tok] == .asterisk) tok += 1;

        if (tok < token_tags.len and token_tags[tok] == .identifier) {
            const name = self.tree.tokenSlice(tok);
            try self.addBinding(name, ids.varId(tok), null, false);
        }
    }

    fn addForPayloads(self: *VarResolver, token: u32) ResolveError!void {
        const token_tags = self.tree.tokens.items(.tag);

        var idx = token;
        if (idx < token_tags.len and token_tags[idx] == .pipe) {
            idx += 1;
        }

        while (idx < token_tags.len) : (idx += 1) {
            const tag = token_tags[idx];
            if (tag == .pipe) break;
            if (tag == .asterisk) {
                idx += 1;
                if (idx < token_tags.len and token_tags[idx] == .identifier) {
                    const name = self.tree.tokenSlice(idx);
                    try self.addBinding(name, ids.varId(idx), null, false);
                }
            } else if (tag == .identifier) {
                const name = self.tree.tokenSlice(idx);
                try self.addBinding(name, ids.varId(idx), null, false);
            }
        }
    }
};
