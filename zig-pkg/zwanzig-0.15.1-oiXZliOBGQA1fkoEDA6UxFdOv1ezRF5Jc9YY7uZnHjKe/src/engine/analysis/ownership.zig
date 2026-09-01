const std = @import("std");
const ids = @import("../../ids.zig");
const ast_walk = @import("../../ast_walk.zig");
const Cfg = @import("../../cfg.zig").Cfg;
const ProgramState = @import("../state.zig").ProgramState;
const EngineError = @import("../base.zig").EngineError;

pub fn mixin(comptime _Engine: type) type {
    return struct {
        pub fn resolveCallToken(self: *_Engine, call_node: u32) ?u32 {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const main_tokens = tree.nodes.items(.main_token);
            if (call_node >= main_tokens.len) return null;
            return main_tokens[call_node];
        }

        pub fn checkUseAfterFreeInCall(self: *_Engine, state: *ProgramState, call_node: u32, current_cfg: *const Cfg) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);

            if (call_node >= tags.len) return;

            var call_buf: [1]std.zig.Ast.Node.Index = undefined;
            const full_call = switch (tags[call_node]) {
                .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
                else => null,
            } orelse return;

            try checkUseAfterFreeInExpr(self, state, @intFromEnum(full_call.ast.fn_expr), current_cfg);

            for (full_call.ast.params) |param| {
                try checkUseAfterFreeInExpr(self, state, @intFromEnum(param), current_cfg);
            }
        }

        pub fn checkUseAfterFreeInExpr(self: *_Engine, state: *ProgramState, expr_node: u32, current_cfg: *const Cfg) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);
            const main_tokens = tree.nodes.items(.main_token);

            if (expr_node >= tags.len) return;

            switch (tags[expr_node]) {
                .identifier => {
                    if (_Engine.var_resolution.resolveVarIdFromIdentifier(self, expr_node, current_cfg)) |var_id| {
                        const token = main_tokens[expr_node];
                        try state.trackUse(var_id, token);
                    }
                },
                .grouped_expression, .unwrap_optional => {
                    const data = datas[expr_node].node_and_token;
                    try checkUseAfterFreeInExpr(self, state, @intFromEnum(data[0]), current_cfg);
                },
                .slice, .slice_open, .slice_sentinel => {
                    const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return;
                    try checkUseAfterFreeInExpr(self, state, @intFromEnum(slice.ast.sliced), current_cfg);
                },
                .array_access => {
                    const pair = datas[expr_node].node_and_node;
                    try checkUseAfterFreeInExpr(self, state, @intFromEnum(pair[0]), current_cfg);
                },
                .field_access => {
                    const data = datas[expr_node].node_and_token;
                    try checkUseAfterFreeInExpr(self, state, @intFromEnum(data[0]), current_cfg);
                },
                .address_of, .deref, .@"try" => {
                    const child = datas[expr_node].node;
                    try checkUseAfterFreeInExpr(self, state, @intFromEnum(child), current_cfg);
                },
                .@"catch" => {
                    const pair = datas[expr_node].node_and_node;
                    try checkUseAfterFreeInExpr(self, state, @intFromEnum(pair[0]), current_cfg);
                    try checkUseAfterFreeInExpr(self, state, @intFromEnum(pair[1]), current_cfg);
                },
                .call, .call_comma, .call_one, .call_one_comma => {
                    try checkUseAfterFreeInCall(self, state, expr_node, current_cfg);
                },
                else => {},
            }
        }

        pub fn markEscapedInExpr(self: *_Engine, state: *ProgramState, expr_node: u32, current_cfg: *const Cfg) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);
            const main_tokens = tree.nodes.items(.main_token);
            const token_tags = tree.tokens.items(.tag);

            if (expr_node >= tags.len) return;

            switch (tags[expr_node]) {
                .identifier => {
                    if (_Engine.var_resolution.resolveVarIdFromIdentifier(self, expr_node, current_cfg)) |var_id| {
                        try state.trackEscapeOwned(var_id);
                        state.trackEscape(var_id);
                        const token = main_tokens[expr_node];
                        if (ids.varIndex(var_id) == token and token < token_tags.len and token_tags[token] == .identifier) {
                            const name = tree.tokenSlice(token);
                            try state.trackEscapeByName(tree, name);
                        }
                    }
                },
                .grouped_expression, .unwrap_optional => {
                    const data = datas[expr_node].node_and_token;
                    try markEscapedInExpr(self, state, @intFromEnum(data[0]), current_cfg);
                },
                .slice, .slice_open, .slice_sentinel => {
                    const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return;
                    try markEscapedInExpr(self, state, @intFromEnum(slice.ast.sliced), current_cfg);
                },
                .array_access => {
                    const pair = datas[expr_node].node_and_node;
                    try markEscapedInExpr(self, state, @intFromEnum(pair[0]), current_cfg);
                },
                .field_access => {
                    const data = datas[expr_node].node_and_token;
                    try markEscapedInExpr(self, state, @intFromEnum(data[0]), current_cfg);
                },
                .address_of, .deref, .@"try" => {
                    const child = datas[expr_node].node;
                    try markEscapedInExpr(self, state, @intFromEnum(child), current_cfg);
                },
                .@"catch" => {
                    const pair = datas[expr_node].node_and_node;
                    try markEscapedInExpr(self, state, @intFromEnum(pair[0]), current_cfg);
                    try markEscapedInExpr(self, state, @intFromEnum(pair[1]), current_cfg);
                },
                .struct_init, .struct_init_comma, .struct_init_one, .struct_init_one_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const struct_init = tree.fullStructInit(&buf, @enumFromInt(expr_node)) orelse return;
                    for (struct_init.ast.fields) |field| {
                        try markEscapedInExpr(self, state, @intFromEnum(field), current_cfg);
                    }
                },
                .container_field, .container_field_init, .container_field_align => {
                    const field = tree.fullContainerField(@enumFromInt(expr_node)) orelse return;
                    if (field.ast.value_expr.unwrap()) |value_expr| {
                        try markEscapedInExpr(self, state, @intFromEnum(value_expr), current_cfg);
                    } else if (field.ast.tuple_like) {
                        if (field.ast.type_expr.unwrap()) |value_expr| {
                            try markEscapedInExpr(self, state, @intFromEnum(value_expr), current_cfg);
                        }
                    }
                },
                .array_init, .array_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => {
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const array_init = tree.fullArrayInit(&buf, @enumFromInt(expr_node)) orelse return;
                    for (array_init.ast.elements) |elem| {
                        try markEscapedInExpr(self, state, @intFromEnum(elem), current_cfg);
                    }
                },
                else => {},
            }
        }

        pub fn trackEscapesFromCall(self: *_Engine, state: *ProgramState, call_node: u32, current_cfg: *const Cfg) void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);
            const main_tokens = tree.nodes.items(.main_token);
            const token_tags = tree.tokens.items(.tag);

            if (call_node >= tags.len) return;

            var call_buf: [1]std.zig.Ast.Node.Index = undefined;
            const full_call = switch (tags[call_node]) {
                .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
                else => null,
            } orelse return;

            const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
            if (callee_node >= tags.len) return;

            const fn_name = blk: {
                switch (tags[callee_node]) {
                    .field_access => {
                        const field_access_data = datas[callee_node].node_and_token;
                        const field_token = field_access_data[1];
                        if (field_token >= token_tags.len or token_tags[field_token] != .identifier) break :blk null;
                        break :blk tree.tokenSlice(field_token);
                    },
                    .identifier => {
                        const fn_token = main_tokens[callee_node];
                        if (fn_token >= token_tags.len or token_tags[fn_token] != .identifier) break :blk null;
                        break :blk tree.tokenSlice(fn_token);
                    },
                    else => break :blk null,
                }
            } orelse return;

            if (std.mem.eql(u8, fn_name, "append") or
                std.mem.eql(u8, fn_name, "appendAssumeCapacity") or
                std.mem.eql(u8, fn_name, "appendSlice") or
                std.mem.eql(u8, fn_name, "appendSliceAssumeCapacity") or
                std.mem.eql(u8, fn_name, "insert") or
                std.mem.eql(u8, fn_name, "insertSlice") or
                std.mem.eql(u8, fn_name, "insertAssumeCapacity"))
            {
                if (full_call.ast.params.len == 0) return;
                const item_node = @intFromEnum(full_call.ast.params[full_call.ast.params.len - 1]);
                // Receiver is the base of the `<receiver>.append(...)` field access.
                // Must run before markEscapedInExpr because the latter clears the
                // deferred-free tracking we rely on here.
                if (tags[callee_node] == .field_access) {
                    const receiver_node = @intFromEnum(datas[callee_node].node_and_token[0]);
                    // *Slice methods (appendSlice / appendSliceAssumeCapacity /
                    // insertSlice) iterate the argument and copy each element. A
                    // direct slice arg (`appendSlice(out, tmp)` or `tmp[start..end]`)
                    // is consumed in the call; freeing `tmp` afterwards is safe.
                    // Nested references (`appendSlice(out, &.{tmp})` etc.) retain
                    // a reference, so they still go through the escape check.
                    const is_slice_store = std.mem.eql(u8, fn_name, "appendSlice") or
                        std.mem.eql(u8, fn_name, "appendSliceAssumeCapacity") or
                        std.mem.eql(u8, fn_name, "insertSlice");
                    const skip_escape_check = is_slice_store and isDirectSliceCopyArgument(tree, tags, datas, item_node);
                    if (!skip_escape_check) {
                        checkDeferFreesEscapeeIntoContainer(self, state, call_node, receiver_node, item_node, current_cfg) catch return;
                    }
                }
                markEscapedInExpr(self, state, item_node, current_cfg) catch return;
                return;
            }

            if (std.mem.eql(u8, fn_name, "put") or
                std.mem.eql(u8, fn_name, "putNoClobber") or
                std.mem.eql(u8, fn_name, "putAssumeCapacity") or
                std.mem.eql(u8, fn_name, "putNoClobberAssumeCapacity"))
            {
                if (full_call.ast.params.len >= 1) {
                    const key_node = @intFromEnum(full_call.ast.params[0]);
                    markEscapedInExpr(self, state, key_node, current_cfg) catch return;
                }
                if (full_call.ast.params.len >= 2) {
                    const value_node = @intFromEnum(full_call.ast.params[1]);
                    markEscapedInExpr(self, state, value_node, current_cfg) catch return;
                }
                return;
            }

            if (std.mem.startsWith(u8, fn_name, "init") or
                std.mem.startsWith(u8, fn_name, "setup") or
                std.mem.startsWith(u8, fn_name, "set") or
                std.mem.startsWith(u8, fn_name, "store") or
                std.mem.startsWith(u8, fn_name, "register") or
                std.mem.startsWith(u8, fn_name, "add") or
                std.mem.startsWith(u8, fn_name, "push"))
            {
                for (full_call.ast.params) |param| {
                    const param_node = @intFromEnum(param);
                    markEscapedInExpr(self, state, param_node, current_cfg) catch return;
                }
            }
        }

        fn isDirectSliceCopyArgument(
            tree: *const std.zig.Ast,
            tags: []const std.zig.Ast.Node.Tag,
            datas: []const std.zig.Ast.Node.Data,
            expr_node: u32,
        ) bool {
            if (expr_node >= tags.len) return false;

            switch (tags[expr_node]) {
                .identifier => return true,
                .grouped_expression, .unwrap_optional => {
                    const data = datas[expr_node].node_and_token;
                    return isDirectSliceCopyArgument(tree, tags, datas, @intFromEnum(data[0]));
                },
                .slice, .slice_open, .slice_sentinel => {
                    const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return false;
                    return isDirectSliceCopyArgument(tree, tags, datas, @intFromEnum(slice.ast.sliced));
                },
                else => return false,
            }
        }

        /// Detect the "defer frees an escapee" pattern: a resource with a queued
        /// deferred-free is appended into a container whose declaration outlives
        /// the defer's enclosing block. When the block exits the defer fires and
        /// the container is left holding a dangling slice — a future use-after-free.
        ///
        /// `receiver_node` is the LHS of the `<receiver>.append(...)` field
        /// access; `item_expr_node` is the value being appended.
        pub fn checkDeferFreesEscapeeIntoContainer(
            self: *_Engine,
            state: *ProgramState,
            call_node: u32,
            receiver_node: u32,
            item_expr_node: u32,
            current_cfg: *const Cfg,
        ) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const parent_map = try self.getParentMap(tree);
            const tags = tree.nodes.items(.tag);

            const call_token = _Engine.ownership.resolveCallToken(self, call_node);

            var seen: std.AutoHashMap(ids.VarId, void) = .init(self.allocator);
            defer seen.deinit();

            try collectEscapeeViolations(
                self,
                state,
                tree,
                tags,
                parent_map,
                receiver_node,
                item_expr_node,
                call_token,
                current_cfg,
                &seen,
            );
        }

        fn collectEscapeeViolations(
            self: *_Engine,
            state: *ProgramState,
            tree: *const std.zig.Ast,
            tags: []const std.zig.Ast.Node.Tag,
            parent_map: []const u32,
            receiver_node: u32,
            expr_node: u32,
            call_token: ?u32,
            current_cfg: *const Cfg,
            seen: *std.AutoHashMap(ids.VarId, void),
        ) EngineError!void {
            const datas = tree.nodes.items(.data);
            if (expr_node >= tags.len) return;

            switch (tags[expr_node]) {
                .identifier => {
                    const var_id = _Engine.var_resolution.resolveVarIdFromIdentifier(self, expr_node, current_cfg) orelse return;
                    if (seen.contains(var_id)) return;
                    try seen.put(var_id, {});
                    const defer_scope = state.store.pendingDeferredFreeScope(var_id) orelse return;
                    // Same-block locals are safe (defers fire in reverse declaration
                    // order, so the container is destroyed before the resource).
                    // Parameters, top-level decls, and any container declared outside
                    // the defer's scope are not. The bare-slice carve-out for the
                    // appendSlice / insertSlice family already excludes the byte-slice
                    // copy idiom upstream, so the remaining append/insert call shapes
                    // store by reference and a dangling escape is a real UAF.
                    if (containerOutlivesDeferScope(self, tree, tags, parent_map, receiver_node, defer_scope, current_cfg)) {
                        try state.store.recordDeferFreesEscapee(var_id, call_token);
                        state.invalidateCache();
                    }
                },
                .grouped_expression, .unwrap_optional => {
                    const data = datas[expr_node].node_and_token;
                    try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(data[0]), call_token, current_cfg, seen);
                },
                .slice, .slice_open, .slice_sentinel => {
                    const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return;
                    try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(slice.ast.sliced), call_token, current_cfg, seen);
                },
                .array_access => {
                    const pair = datas[expr_node].node_and_node;
                    try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(pair[0]), call_token, current_cfg, seen);
                },
                .field_access => {
                    const data = datas[expr_node].node_and_token;
                    try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(data[0]), call_token, current_cfg, seen);
                },
                .address_of, .deref, .@"try" => {
                    const child = datas[expr_node].node;
                    try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(child), call_token, current_cfg, seen);
                },
                .@"catch" => {
                    const pair = datas[expr_node].node_and_node;
                    try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(pair[0]), call_token, current_cfg, seen);
                    try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(pair[1]), call_token, current_cfg, seen);
                },
                .struct_init, .struct_init_comma, .struct_init_one, .struct_init_one_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const struct_init = tree.fullStructInit(&buf, @enumFromInt(expr_node)) orelse return;
                    for (struct_init.ast.fields) |field| {
                        try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(field), call_token, current_cfg, seen);
                    }
                },
                .container_field, .container_field_init, .container_field_align => {
                    const field = tree.fullContainerField(@enumFromInt(expr_node)) orelse return;
                    if (field.ast.value_expr.unwrap()) |value_expr| {
                        try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(value_expr), call_token, current_cfg, seen);
                    } else if (field.ast.tuple_like) {
                        if (field.ast.type_expr.unwrap()) |value_expr| {
                            try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(value_expr), call_token, current_cfg, seen);
                        }
                    }
                },
                .array_init, .array_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => {
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const array_init = tree.fullArrayInit(&buf, @enumFromInt(expr_node)) orelse return;
                    for (array_init.ast.elements) |elem| {
                        try collectEscapeeViolations(self, state, tree, tags, parent_map, receiver_node, @intFromEnum(elem), call_token, current_cfg, seen);
                    }
                },
                else => {},
            }
        }

        /// The container outlives the defer scope when its declaration is not
        /// inside the block whose exit will fire the defer. Parameters and
        /// top-level decls outlive by construction. If we can't pin the
        /// receiver to an identifier (e.g. `getList().append(...)`), stay
        /// conservative and don't fire.
        fn containerOutlivesDeferScope(
            self: *_Engine,
            tree: *const std.zig.Ast,
            tags: []const std.zig.Ast.Node.Tag,
            parent_map: []const u32,
            receiver_node: u32,
            defer_scope: u32,
            current_cfg: *const Cfg,
        ) bool {
            const root_ident_node = findRootIdentifierNode(tags, tree.nodes.items(.data), receiver_node) orelse return false;
            const decl_info = _Engine.var_resolution.resolveDeclInfoFromIdentifier(self, root_ident_node, current_cfg) orelse return true;
            if (decl_info.is_top_level) return true;
            return !ast_walk.isAncestor(defer_scope, decl_info.decl_node, parent_map);
        }

        fn findRootIdentifierNode(
            tags: []const std.zig.Ast.Node.Tag,
            datas: []const std.zig.Ast.Node.Data,
            expr_node: u32,
        ) ?u32 {
            var current = expr_node;
            var depth: u32 = 0;
            while (depth < 64) : (depth += 1) {
                if (current >= tags.len) return null;
                switch (tags[current]) {
                    .identifier => return current,
                    .field_access => current = @intFromEnum(datas[current].node_and_token[0]),
                    .grouped_expression, .unwrap_optional => current = @intFromEnum(datas[current].node_and_token[0]),
                    .address_of, .deref, .@"try" => current = @intFromEnum(datas[current].node),
                    else => return null,
                }
            }
            return null;
        }

        /// Record ownership when passing resources to functions that take a pointer as first argument.
        /// This handles patterns like `initCache(cache, entries, ...)` where entries becomes owned by cache.
        pub fn recordOwnershipFromCall(self: *_Engine, state: *ProgramState, call_node: u32, current_cfg: *const Cfg) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);
            const main_tokens = tree.nodes.items(.main_token);
            const token_tags = tree.tokens.items(.tag);

            if (call_node >= tags.len) return;

            var call_buf: [1]std.zig.Ast.Node.Index = undefined;
            const full_call = switch (tags[call_node]) {
                .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
                else => null,
            } orelse return;

            if (full_call.ast.params.len < 2) return;

            const first_arg_node = @intFromEnum(full_call.ast.params[0]);
            const first_arg_var = _Engine.var_resolution.resolveVarIdFromExpr(self, first_arg_node, current_cfg) orelse return;

            const first_arg_is_ptr = blk: {
                if (self.type_context) |type_ctx| {
                    const token = ids.varIndex(first_arg_var);
                    if (token < token_tags.len and token_tags[token] == .identifier) {
                        const name = tree.tokenSlice(token);
                        if (type_ctx.getDeclType(name)) |type_info| {
                            if (type_info.kind == .pointer) break :blk true;
                        }
                    }
                }
                if (first_arg_node < tags.len and tags[first_arg_node] == .address_of) {
                    break :blk true;
                }
                if (state.getRegionState(first_arg_var)) |rs| {
                    if (rs == .allocated) break :blk true;
                }
                break :blk false;
            };

            const callee_is_init_fn = blk: {
                const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
                if (callee_node >= tags.len) break :blk false;
                const fn_name_token = switch (tags[callee_node]) {
                    .identifier => main_tokens[callee_node],
                    .field_access => datas[callee_node].node_and_token[1],
                    else => break :blk false,
                };
                if (fn_name_token >= token_tags.len or token_tags[fn_name_token] != .identifier) break :blk false;
                const fn_name = tree.tokenSlice(fn_name_token);
                break :blk std.mem.startsWith(u8, fn_name, "init");
            };

            for (full_call.ast.params[1..]) |param| {
                const param_node = @intFromEnum(param);
                if (_Engine.var_resolution.resolveVarIdFromExpr(self, param_node, current_cfg)) |param_var| {
                    if (state.getRegionState(param_var)) |rs| {
                        if (rs == .allocated or rs == .open) {
                            if (first_arg_is_ptr or callee_is_init_fn) {
                                try state.trackOwnership(param_var, first_arg_var);
                                try state.trackEscapeOwned(param_var);
                                state.trackEscape(param_var);
                            }
                        }
                    }
                }
            }
        }

        pub fn trackEscapesInExpr(self: *_Engine, state: *ProgramState, expr_node: u32, current_cfg: *const Cfg) void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (expr_node >= tags.len) return;

            switch (tags[expr_node]) {
                .call, .call_comma, .call_one, .call_one_comma => {
                    trackEscapesFromCall(self, state, expr_node, current_cfg);
                },
                .grouped_expression, .unwrap_optional => {
                    const data = datas[expr_node].node_and_token;
                    trackEscapesInExpr(self, state, @intFromEnum(data[0]), current_cfg);
                },
                .slice, .slice_open, .slice_sentinel => {
                    const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse return;
                    trackEscapesInExpr(self, state, @intFromEnum(slice.ast.sliced), current_cfg);
                },
                .array_access => {
                    const pair = datas[expr_node].node_and_node;
                    trackEscapesInExpr(self, state, @intFromEnum(pair[0]), current_cfg);
                },
                .field_access => {
                    const data = datas[expr_node].node_and_token;
                    trackEscapesInExpr(self, state, @intFromEnum(data[0]), current_cfg);
                },
                .address_of, .deref, .@"try" => {
                    const child = datas[expr_node].node;
                    trackEscapesInExpr(self, state, @intFromEnum(child), current_cfg);
                },
                .@"catch" => {
                    const pair = datas[expr_node].node_and_node;
                    trackEscapesInExpr(self, state, @intFromEnum(pair[0]), current_cfg);
                    trackEscapesInExpr(self, state, @intFromEnum(pair[1]), current_cfg);
                },
                .struct_init, .struct_init_comma, .struct_init_one, .struct_init_one_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const struct_init = tree.fullStructInit(&buf, @enumFromInt(expr_node)) orelse return;
                    for (struct_init.ast.fields) |field| {
                        trackEscapesInExpr(self, state, @intFromEnum(field), current_cfg);
                    }
                },
                .array_init, .array_init_comma, .array_init_one, .array_init_one_comma, .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => {
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const array_init = tree.fullArrayInit(&buf, @enumFromInt(expr_node)) orelse return;
                    for (array_init.ast.elements) |elem| {
                        trackEscapesInExpr(self, state, @intFromEnum(elem), current_cfg);
                    }
                },
                else => {},
            }
        }

        pub fn recordOwnershipFromExpr(
            self: *_Engine,
            state: *ProgramState,
            expr_node: u32,
            container_var: ids.VarId,
            current_cfg: *const Cfg,
        ) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (expr_node >= tags.len) return;

            switch (tags[expr_node]) {
                .struct_init,
                .struct_init_comma,
                .struct_init_one,
                .struct_init_one_comma,
                .struct_init_dot,
                .struct_init_dot_comma,
                .struct_init_dot_two,
                .struct_init_dot_two_comma,
                => try recordOwnershipFromStructInit(self, state, expr_node, container_var, current_cfg),
                .grouped_expression, .unwrap_optional => {
                    const data = datas[expr_node].node_and_token;
                    try recordOwnershipFromExpr(self, state, @intFromEnum(data[0]), container_var, current_cfg);
                },
                .@"try" => try recordOwnershipFromExpr(self, state, @intFromEnum(datas[expr_node].node), container_var, current_cfg),
                .@"catch" => {
                    const pair = datas[expr_node].node_and_node;
                    try recordOwnershipFromExpr(self, state, @intFromEnum(pair[0]), container_var, current_cfg);
                    try recordOwnershipFromExpr(self, state, @intFromEnum(pair[1]), container_var, current_cfg);
                },
                else => {},
            }
        }

        pub fn recordOwnershipFromStructInit(
            self: *_Engine,
            state: *ProgramState,
            struct_node: u32,
            container_var: ids.VarId,
            current_cfg: *const Cfg,
        ) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);

            if (struct_node >= tags.len) return;

            var buf: [2]std.zig.Ast.Node.Index = undefined;
            const struct_init = tree.fullStructInit(&buf, @enumFromInt(struct_node)) orelse return;

            for (struct_init.ast.fields) |field| {
                const field_idx = @intFromEnum(field);
                if (field_idx >= tags.len) continue;

                switch (tags[field_idx]) {
                    .container_field, .container_field_init, .container_field_align => {
                        const full_field = tree.fullContainerField(@enumFromInt(field_idx)) orelse continue;
                        if (full_field.ast.value_expr.unwrap()) |value_expr| {
                            if (_Engine.var_resolution.resolveVarIdFromExpr(self, @intFromEnum(value_expr), current_cfg)) |var_id| {
                                try state.trackOwnership(var_id, container_var);
                            }
                        } else if (full_field.ast.tuple_like) {
                            if (full_field.ast.type_expr.unwrap()) |value_expr| {
                                if (_Engine.var_resolution.resolveVarIdFromExpr(self, @intFromEnum(value_expr), current_cfg)) |var_id| {
                                    try state.trackOwnership(var_id, container_var);
                                }
                            }
                        }
                    },
                    else => {
                        if (_Engine.var_resolution.resolveVarIdFromExpr(self, field_idx, current_cfg)) |var_id| {
                            try state.trackOwnership(var_id, container_var);
                        }
                    },
                }
            }
        }

        fn baseEscapes(
            self: *_Engine,
            state: *ProgramState,
            tree: *const std.zig.Ast,
            base_node: u32,
            container_var: ids.VarId,
        ) bool {
            const tags = tree.nodes.items(.tag);
            const main_tokens = tree.nodes.items(.main_token);
            const token_tags = tree.tokens.items(.tag);

            if (base_node < tags.len and tags[base_node] == .identifier) {
                const token = main_tokens[base_node];
                if (token < token_tags.len and token_tags[token] == .identifier) {
                    const name = tree.tokenSlice(token);
                    if (std.mem.eql(u8, name, "self")) {
                        return true;
                    }
                }
            }

            if (self.type_context) |type_ctx| {
                const token = ids.varIndex(container_var);
                if (token < token_tags.len and token_tags[token] == .identifier) {
                    const var_name = tree.tokenSlice(token);
                    if (type_ctx.getDeclType(var_name)) |type_info| {
                        if (type_info.kind == .pointer) {
                            return true;
                        }
                    }
                }
            }

            return state.getRegionState(container_var) == null;
        }

        pub fn escapeOwnedFromFieldBase(
            self: *_Engine,
            state: *ProgramState,
            tree: *const std.zig.Ast,
            base_node: u32,
            container_var: ids.VarId,
            resource_var: ids.VarId,
        ) EngineError!void {
            if (baseEscapes(self, state, tree, base_node, container_var)) {
                try state.trackEscapeOwned(resource_var);
                state.trackEscape(resource_var);
            }
        }

        pub fn recordOwnershipFromFieldAssign(
            self: *_Engine,
            state: *ProgramState,
            lhs_node: u32,
            rhs_node: u32,
            current_cfg: *const Cfg,
        ) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (lhs_node >= tags.len or tags[lhs_node] != .field_access) return;

            const field_access_data = datas[lhs_node].node_and_token;
            const base_node = @intFromEnum(field_access_data[0]);
            const container_var = _Engine.var_resolution.resolveVarIdFromExpr(self, base_node, current_cfg) orelse return;
            const resource_var = _Engine.var_resolution.resolveVarIdFromExpr(self, rhs_node, current_cfg) orelse return;
            try state.trackOwnership(resource_var, container_var);
            try _Engine.ownership.escapeOwnedFromFieldBase(self, state, tree, base_node, container_var, resource_var);
        }

        pub fn escapeReturnedVars(self: *_Engine, state: *ProgramState, fn_node: ids.AstNodeId, current_cfg: *const Cfg) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const fn_index = ids.astIndex(fn_node);
            if (fn_index >= tags.len or tags[fn_index] != .fn_decl) return;
            const fn_data = tree.nodes.items(.data)[fn_index];
            const body_node = @intFromEnum(fn_data.node_and_node[1]);
            if (body_node == 0) return;
            try escapeReturnedVarsInNode(self, state, body_node, current_cfg, tree);
        }

        pub fn escapeReturnedVarsInNode(
            self: *_Engine,
            state: *ProgramState,
            node: u32,
            current_cfg: *const Cfg,
            tree: *const std.zig.Ast,
        ) EngineError!void {
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (node == 0 or node >= tags.len) return;

            switch (tags[node]) {
                .@"return" => {
                    if (datas[node].opt_node.unwrap()) |ret_expr| {
                        try markEscapedInExpr(self, state, @intFromEnum(ret_expr), current_cfg);
                    }
                },
                .block, .block_semicolon, .block_two, .block_two_semicolon => {
                    var statements: []const u32 = &.{};
                    var scratch_buf: [2]u32 = undefined;

                    switch (tags[node]) {
                        .block, .block_semicolon => {
                            const extra_range = datas[node].extra_range;
                            const start = @intFromEnum(extra_range.start);
                            const end = @intFromEnum(extra_range.end);
                            statements = tree.extra_data[start..end];
                        },
                        .block_two, .block_two_semicolon => {
                            const opt_nodes = datas[node].opt_node_and_opt_node;
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
                        else => {},
                    }

                    for (statements) |stmt| {
                        try escapeReturnedVarsInNode(self, state, stmt, current_cfg, tree);
                    }
                },
                .@"if", .if_simple => {
                    const full_if = tree.fullIf(@enumFromInt(node)) orelse return;
                    try escapeReturnedVarsInNode(self, state, @intFromEnum(full_if.ast.then_expr), current_cfg, tree);
                    if (full_if.ast.else_expr.unwrap()) |else_node| {
                        try escapeReturnedVarsInNode(self, state, @intFromEnum(else_node), current_cfg, tree);
                    }
                },
                .@"while", .while_simple, .while_cont => {
                    const full_while = tree.fullWhile(@enumFromInt(node)) orelse return;
                    try escapeReturnedVarsInNode(self, state, @intFromEnum(full_while.ast.then_expr), current_cfg, tree);
                    if (full_while.ast.else_expr.unwrap()) |else_node| {
                        try escapeReturnedVarsInNode(self, state, @intFromEnum(else_node), current_cfg, tree);
                    }
                    if (full_while.ast.cont_expr.unwrap()) |cont_node| {
                        try escapeReturnedVarsInNode(self, state, @intFromEnum(cont_node), current_cfg, tree);
                    }
                },
                .@"for", .for_simple => {
                    const full_for = tree.fullFor(@enumFromInt(node)) orelse return;
                    try escapeReturnedVarsInNode(self, state, @intFromEnum(full_for.ast.then_expr), current_cfg, tree);
                    if (full_for.ast.else_expr.unwrap()) |else_node| {
                        try escapeReturnedVarsInNode(self, state, @intFromEnum(else_node), current_cfg, tree);
                    }
                },
                .@"switch", .switch_comma => {
                    const full_switch = tree.switchFull(@enumFromInt(node));
                    for (full_switch.ast.cases) |case_node| {
                        const full_case = tree.fullSwitchCase(case_node) orelse continue;
                        try escapeReturnedVarsInNode(self, state, @intFromEnum(full_case.ast.target_expr), current_cfg, tree);
                    }
                },
                else => {},
            }
        }
    };
}
