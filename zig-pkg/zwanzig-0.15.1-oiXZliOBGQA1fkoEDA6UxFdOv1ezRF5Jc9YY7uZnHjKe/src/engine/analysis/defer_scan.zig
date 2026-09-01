const std = @import("std");
const ids = @import("../../ids.zig");
const Cfg = @import("../../cfg.zig").Cfg;
const ProgramState = @import("../state.zig").ProgramState;
const EngineError = @import("../base.zig").EngineError;

pub fn mixin(comptime _Engine: type) type {
    return struct {
        pub fn applyDeferredReleases(self: *_Engine, state: *ProgramState, defer_node: u32, current_cfg: *const Cfg) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const data = tree.nodes.items(.data);
            const tags = tree.nodes.items(.tag);
            if (defer_node >= data.len) return;
            const body_node = @intFromEnum(data[defer_node].node);
            const parent_map = try self.getParentMap(tree);
            const scope_node = findEnclosingBlock(tags, parent_map, defer_node);
            try scanDeferredBody(self, state, body_node, current_cfg, false, scope_node);
        }

        pub fn applyErrdeferredReleases(self: *_Engine, state: *ProgramState, defer_node: u32, current_cfg: *const Cfg) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const data = tree.nodes.items(.data);
            const tags = tree.nodes.items(.tag);
            if (defer_node >= data.len) return;
            const body_node = @intFromEnum(data[defer_node].opt_token_and_node[1]);
            if (body_node == 0) return;
            const parent_map = try self.getParentMap(tree);
            const scope_node = findErrdeferScope(tags, parent_map, defer_node);
            try scanDeferredBody(self, state, body_node, current_cfg, true, scope_node);
        }

        pub fn scanDeferredBody(
            self: *_Engine,
            state: *ProgramState,
            node: u32,
            current_cfg: *const Cfg,
            error_only: bool,
            scope_node: ?u32,
        ) EngineError!void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (node == 0 or node >= tags.len) return;

            switch (tags[node]) {
                .call, .call_comma, .call_one, .call_one_comma => {
                    if (_Engine.resource_calls.resolveResourceCallFromExpr(self, tree, node)) |call_info| {
                        const call_token = _Engine.ownership.resolveCallToken(self, call_info.call_node);
                        switch (call_info.kind) {
                            .free => {
                                if (call_info.target_expr) |arg_node| {
                                    if (_Engine.var_resolution.resolveVarIdFromExpr(self, arg_node, current_cfg)) |var_id| {
                                        if (error_only) {
                                            try state.trackErrdeferredFree(var_id, call_token, scope_node);
                                        } else {
                                            try state.trackDeferredFree(var_id, call_token, scope_node);
                                        }
                                    }
                                }
                            },
                            .free_owned => {
                                if (call_info.target_expr) |arg_node| {
                                    if (_Engine.var_resolution.resolveVarIdFromExpr(self, arg_node, current_cfg)) |var_id| {
                                        if (error_only) {
                                            try state.trackErrdeferredFreeOwned(var_id, call_token, scope_node);
                                        } else {
                                            try state.trackDeferredFreeOwned(var_id, call_token, scope_node);
                                        }
                                    }
                                }
                            },
                            .close => {
                                if (call_info.target_expr) |arg_node| {
                                    if (_Engine.var_resolution.resolveVarIdFromExpr(self, arg_node, current_cfg)) |var_id| {
                                        if (error_only) {
                                            try state.trackErrdeferredClose(var_id, call_token, scope_node);
                                        } else {
                                            try state.trackDeferredClose(var_id, call_token, scope_node);
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
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
                        try scanDeferredBody(self, state, stmt, current_cfg, error_only, scope_node);
                    }
                },
                .@"if", .if_simple => {
                    const full_if = tree.fullIf(@enumFromInt(node)) orelse return;
                    if (full_if.payload_token) |tok| {
                        try _Engine.payloads.bindPayloadAlias(self, state, tok, @intFromEnum(full_if.ast.cond_expr), current_cfg);
                        try scanDeferredBody(self, state, @intFromEnum(full_if.ast.then_expr), current_cfg, error_only, scope_node);
                        state.resetRegion(ids.varId(tok));
                    } else {
                        try scanDeferredBody(self, state, @intFromEnum(full_if.ast.then_expr), current_cfg, error_only, scope_node);
                    }
                    if (full_if.ast.else_expr.unwrap()) |else_node| {
                        if (full_if.error_token) |tok| {
                            try _Engine.payloads.bindPayloadUnknown(self, state, tok);
                            try scanDeferredBody(self, state, @intFromEnum(else_node), current_cfg, error_only, scope_node);
                            state.resetRegion(ids.varId(tok));
                        } else {
                            try scanDeferredBody(self, state, @intFromEnum(else_node), current_cfg, error_only, scope_node);
                        }
                    }
                },
                .@"while", .while_simple, .while_cont => {
                    const full_while = tree.fullWhile(@enumFromInt(node)) orelse return;
                    if (full_while.payload_token) |tok| {
                        try _Engine.payloads.bindPayloadAlias(self, state, tok, @intFromEnum(full_while.ast.cond_expr), current_cfg);
                        try scanDeferredBody(self, state, @intFromEnum(full_while.ast.then_expr), current_cfg, error_only, scope_node);
                        state.resetRegion(ids.varId(tok));
                    } else {
                        try scanDeferredBody(self, state, @intFromEnum(full_while.ast.then_expr), current_cfg, error_only, scope_node);
                    }
                    if (full_while.ast.else_expr.unwrap()) |else_node| {
                        if (full_while.error_token) |tok| {
                            try _Engine.payloads.bindPayloadUnknown(self, state, tok);
                            try scanDeferredBody(self, state, @intFromEnum(else_node), current_cfg, error_only, scope_node);
                            state.resetRegion(ids.varId(tok));
                        } else {
                            try scanDeferredBody(self, state, @intFromEnum(else_node), current_cfg, error_only, scope_node);
                        }
                    }
                },
                .@"for", .for_simple => {
                    const full_for = tree.fullFor(@enumFromInt(node)) orelse return;
                    if (full_for.payload_token != 0) {
                        try _Engine.payloads.bindForPayloads(self, state, full_for.payload_token);
                        try scanDeferredBody(self, state, @intFromEnum(full_for.ast.then_expr), current_cfg, error_only, scope_node);
                    } else {
                        try scanDeferredBody(self, state, @intFromEnum(full_for.ast.then_expr), current_cfg, error_only, scope_node);
                    }
                    if (full_for.ast.else_expr.unwrap()) |else_node| {
                        try scanDeferredBody(self, state, @intFromEnum(else_node), current_cfg, error_only, scope_node);
                    }
                },
                .@"switch", .switch_comma => {
                    const full_switch = tree.switchFull(@enumFromInt(node));
                    for (full_switch.ast.cases) |case_node| {
                        const full_case = tree.fullSwitchCase(case_node) orelse continue;
                        try scanDeferredBody(self, state, @intFromEnum(full_case.ast.target_expr), current_cfg, error_only, scope_node);
                    }
                },
                else => {},
            }
        }

        /// Find the lexical block whose exit will execute this defer.
        /// A defer fires when its enclosing block terminates, so the "scope" is
        /// the closest block-shaped ancestor (.block*). Returns null if the
        /// defer is not nested under any block (shouldn't happen for valid AST).
        fn findEnclosingBlock(tags: []const std.zig.Ast.Node.Tag, parent_map: []const u32, node: u32) ?u32 {
            var current = node;
            var depth: u32 = 0;
            while (current < parent_map.len and depth < 64) : (depth += 1) {
                const parent = parent_map[current];
                if (parent == 0 or parent >= tags.len) return null;
                switch (tags[parent]) {
                    .block,
                    .block_semicolon,
                    .block_two,
                    .block_two_semicolon,
                    => return parent,
                    else => current = parent,
                }
            }
            return null;
        }

        fn findErrdeferScope(tags: []const std.zig.Ast.Node.Tag, parent_map: []const u32, node: u32) ?u32 {
            var current = node;
            var depth: u32 = 0;
            while (current < parent_map.len and depth < 64) : (depth += 1) {
                const parent = parent_map[current];
                if (parent == 0 or parent >= tags.len) return null;
                switch (tags[parent]) {
                    .block,
                    .block_semicolon,
                    .block_two,
                    .block_two_semicolon,
                    .@"if",
                    .if_simple,
                    .@"while",
                    .while_simple,
                    .while_cont,
                    .@"for",
                    .for_simple,
                    .@"switch",
                    .switch_comma,
                    .fn_decl,
                    .test_decl,
                    => return parent,
                    else => current = parent,
                }
            }
            return null;
        }
    };
}
