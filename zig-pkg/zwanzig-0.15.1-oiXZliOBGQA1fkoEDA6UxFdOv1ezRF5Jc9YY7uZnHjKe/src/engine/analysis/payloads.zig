const ids = @import("../../ids.zig");
const Cfg = @import("../../cfg.zig").Cfg;
const CfgNode = @import("../../cfg.zig").CfgNode;
const EdgeKind = @import("../../cfg.zig").EdgeKind;
const ProgramState = @import("../state.zig").ProgramState;

pub fn mixin(comptime _Engine: type) type {
    return struct {
        pub fn bindPayloadAlias(self: *_Engine, state: *ProgramState, payload_token: u32, expr_node: u32, current_cfg: *const Cfg) !void {
            const var_id = ids.varId(payload_token);
            state.resetRegion(var_id);
            try state.setVar(var_id, .unknown);
            if (_Engine.var_resolution.resolveVarIdFromExpr(self, expr_node, current_cfg)) |alias_target| {
                if (alias_target != var_id) {
                    try state.trackAlias(var_id, alias_target);
                }
            }
        }

        pub fn bindPayloadUnknown(self: *_Engine, state: *ProgramState, payload_token: u32) !void {
            _ = self;
            const var_id = ids.varId(payload_token);
            state.resetRegion(var_id);
            try state.setVar(var_id, .unknown);
        }

        pub fn bindForPayloads(self: *_Engine, state: *ProgramState, payload_token: u32) !void {
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const token_tags = tree.tokens.items(.tag);

            var idx = payload_token;
            if (idx < token_tags.len and token_tags[idx] == .pipe) {
                idx += 1;
            }

            while (idx < token_tags.len) : (idx += 1) {
                const tag = token_tags[idx];
                if (tag == .pipe) break;
                if (tag == .asterisk) {
                    idx += 1;
                    if (idx < token_tags.len and token_tags[idx] == .identifier) {
                        try bindPayloadUnknown(self, state, idx);
                    }
                } else if (tag == .identifier) {
                    try bindPayloadUnknown(self, state, idx);
                }
            }
        }

        pub fn applyPayloadBindings(self: *_Engine, cfg_node: *const CfgNode, edge_kind: EdgeKind, state: *ProgramState, current_cfg: *const Cfg) !void {
            const ast_node = cfg_node.ir_node.ast_node orelse return;
            const src = self.source orelse return;
            const tree = src.ast() catch return;
            const tags = tree.nodes.items(.tag);

            if (ast_node >= tags.len) return;

            switch (tags[ast_node]) {
                .@"if", .if_simple => {
                    const full_if = tree.fullIf(@enumFromInt(ast_node)) orelse return;
                    if (edge_kind == .branch_true) {
                        if (full_if.payload_token) |tok| {
                            try bindPayloadAlias(self, state, tok, @intFromEnum(full_if.ast.cond_expr), current_cfg);
                        }
                    } else if (edge_kind == .branch_false) {
                        if (full_if.error_token) |tok| {
                            try bindPayloadUnknown(self, state, tok);
                        }
                    }
                },
                .@"while", .while_simple, .while_cont => {
                    const full_while = tree.fullWhile(@enumFromInt(ast_node)) orelse return;
                    if (edge_kind == .branch_true) {
                        if (full_while.payload_token) |tok| {
                            try bindPayloadAlias(self, state, tok, @intFromEnum(full_while.ast.cond_expr), current_cfg);
                        }
                    }
                },
                .@"for", .for_simple => {
                    if (edge_kind != .branch_true) return;
                    const full_for = tree.fullFor(@enumFromInt(ast_node)) orelse return;
                    try bindForPayloads(self, state, full_for.payload_token);
                },
                else => {},
            }
        }
    };
}
