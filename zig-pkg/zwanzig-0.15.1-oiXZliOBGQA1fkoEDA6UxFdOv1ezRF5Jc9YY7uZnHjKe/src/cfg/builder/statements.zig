const source_range = @import("source_range.zig");
const graph = @import("../graph.zig");
const ids = @import("../../ids.zig");
const Source = @import("../../source.zig").Source;

const Cfg = graph.Cfg;
const EdgeKind = graph.EdgeKind;
const IrNode = graph.IrNode;
const CfgNodeId = ids.CfgNodeId;

pub fn mixin(comptime _Builder: type) type {
    return struct {
        pub fn processBlock(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const tags = tree.nodes.items(.tag);
            const data = tree.nodes.items(.data);

            const tag = tags[ast_node];

            var stmts: []const u32 = &[_]u32{};
            var inline_stmts: [2]u32 = undefined;

            switch (tag) {
                .block, .block_semicolon => {
                    const extra = data[ast_node].extra_range;
                    const start: usize = @intFromEnum(extra.start);
                    const end: usize = @intFromEnum(extra.end);
                    if (end > start) {
                        stmts = tree.extra_data[start..end];
                    }
                },
                .block_two, .block_two_semicolon => {
                    var count: usize = 0;
                    const opt_nodes = data[ast_node].opt_node_and_opt_node;
                    if (opt_nodes[0].unwrap()) |node| {
                        inline_stmts[count] = @intFromEnum(node);
                        count += 1;
                    }
                    if (opt_nodes[1].unwrap()) |node| {
                        inline_stmts[count] = @intFromEnum(node);
                        count += 1;
                    }
                    stmts = inline_stmts[0..count];
                },
                else => return .{ .last = null, .terminates = false },
            }

            if (stmts.len == 0) {
                return .{ .last = null, .terminates = false };
            }

            var current_prev = prev_node;
            var last_processed: ?CfgNodeId = null;
            var terminates = false;
            var pending_edge_kind: ?EdgeKind = null;

            for (stmts) |stmt| {
                const edge_count_before = cfg.edges.items.len;
                const result = try self.processNode(cfg, source, stmt, current_prev);

                // If the previous statement requested a specific edge kind for the
                // connection to the next statement, apply it now
                if (pending_edge_kind) |kind| {
                    self.markEdgeFromNode(cfg, edge_count_before, current_prev, kind);
                    pending_edge_kind = null;
                }

                if (result.last) |node_idx| {
                    last_processed = node_idx;
                    current_prev = node_idx;
                }

                // Save the edge kind for the next iteration (e.g., try_success after try)
                pending_edge_kind = result.next_edge_kind;

                if (result.terminates) {
                    terminates = true;
                    break;
                }
            }

            return .{ .last = last_processed, .terminates = terminates };
        }

        pub fn processReturn(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const range = try source_range.getSourceRange(source, ast_node);

            // Check if the return expression contains a try or catch expression
            // Return node data: opt_node format - a single optional return expression
            const data = tree.nodes.items(.data);
            const ret_expr_opt = data[ast_node].opt_node;
            if (ret_expr_opt.unwrap()) |ret_expr_node| {
                const ret_expr_idx = @intFromEnum(ret_expr_node);
                const tags = tree.nodes.items(.tag);
                if (ret_expr_idx < tags.len) {
                    const ret_expr_tag = tags[ret_expr_idx];
                    if (ret_expr_tag == .@"try") {
                        return try _Builder.error_flow.processReturnWithTry(self, cfg, source, ast_node, ret_expr_idx, prev_node, range);
                    } else if (ret_expr_tag == .@"catch") {
                        return try _Builder.error_flow.processReturnWithCatch(self, cfg, source, ast_node, ret_expr_idx, prev_node, range);
                    } else if (ret_expr_tag == .@"switch" or ret_expr_tag == .switch_comma) {
                        return try _Builder.switch_flow.processReturnWithSwitch(self, cfg, source, ast_node, ret_expr_idx, prev_node, range);
                    }
                }
            }

            const ret_node = try cfg.addNode(IrNode.initFull(.ret, ast_node, range));
            try cfg.addEdge(prev_node, ret_node);
            try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);
            return .{ .last = ret_node, .terminates = true };
        }

        pub fn processVarDecl(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const range = try source_range.getSourceRange(source, ast_node);

            // Check if the initializer contains a try or catch expression
            const full_var = tree.fullVarDecl(@enumFromInt(ast_node));
            if (full_var) |vd| {
                if (vd.ast.init_node.unwrap()) |init_node| {
                    const init_idx = @intFromEnum(init_node);
                    const tags = tree.nodes.items(.tag);
                    if (init_idx < tags.len) {
                        const init_tag = tags[init_idx];
                        if (init_tag == .@"try") {
                            return try _Builder.error_flow.processVarDeclWithTry(self, cfg, source, ast_node, init_idx, prev_node, range);
                        } else if (init_tag == .@"catch") {
                            return try _Builder.error_flow.processVarDeclWithCatch(self, cfg, source, ast_node, init_idx, prev_node, range);
                        } else if (init_tag == .@"switch" or init_tag == .switch_comma) {
                            return try _Builder.switch_flow.processVarDeclWithSwitch(self, cfg, source, ast_node, init_idx, prev_node, range);
                        }
                    }
                }
            }

            // Simple var decl without try/catch in initializer
            // Annotate with type information if available
            var ir_node = IrNode.initFull(.var_decl, ast_node, range);
            ir_node = _Builder.type_annotation.annotateWithType(self, ir_node, source, ast_node);

            const decl_node = try cfg.addNode(ir_node);
            try cfg.addEdge(prev_node, decl_node);
            return .{ .last = decl_node, .terminates = false };
        }

        pub fn processAssign(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const range = try source_range.getSourceRange(source, ast_node);

            // Check if the RHS contains a try or catch expression
            // Assign node data: lhs and rhs
            const data = tree.nodes.items(.data);
            const assign_data = data[ast_node].node_and_node;
            const lhs_idx = @intFromEnum(assign_data[0]);
            const rhs_idx = @intFromEnum(assign_data[1]);
            const tags = tree.nodes.items(.tag);
            if (rhs_idx < tags.len) {
                const rhs_tag = tags[rhs_idx];
                if (rhs_tag == .@"try") {
                    return try _Builder.error_flow.processAssignWithTry(self, cfg, source, ast_node, lhs_idx, rhs_idx, prev_node, range);
                } else if (rhs_tag == .@"catch") {
                    return try _Builder.error_flow.processAssignWithCatch(self, cfg, source, ast_node, lhs_idx, rhs_idx, prev_node, range);
                } else if (rhs_tag == .@"switch" or rhs_tag == .switch_comma) {
                    return try _Builder.switch_flow.processAssignWithSwitch(self, cfg, source, ast_node, lhs_idx, rhs_idx, prev_node, range);
                }
            }

            const assign_node = try cfg.addNode(IrNode.initAssign(ast_node, lhs_idx, rhs_idx, range));
            try cfg.addEdge(prev_node, assign_node);
            return .{ .last = assign_node, .terminates = false };
        }

        pub fn processCall(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            _ = self;
            const range = try source_range.getSourceRange(source, ast_node);
            const call_node = try cfg.addNode(IrNode.initFull(.call, ast_node, range));
            try cfg.addEdge(prev_node, call_node);
            return .{ .last = call_node, .terminates = false };
        }

        pub fn processGenericExpr(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            _ = self;
            const range = try source_range.getSourceRange(source, ast_node);
            const expr_node = try cfg.addNode(IrNode.initFull(.expr, ast_node, range));
            try cfg.addEdge(prev_node, expr_node);
            return .{ .last = expr_node, .terminates = false };
        }

        /// `unreachable` is a statically dead point: any path that reaches it
        /// does not continue. Create an IR node so analyses can see the
        /// statement, attach an incoming edge, and return `terminates = true`
        /// so the surrounding block stops feeding successors. No outgoing
        /// edges are added; the engine treats a node with no successors as a
        /// dead end and stops propagating state.
        pub fn processUnreachable(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            _ = self;
            const range = try source_range.getSourceRange(source, ast_node);
            const u_node = try cfg.addNode(IrNode.initFull(.unreachable_stmt, ast_node, range));
            try cfg.addEdge(prev_node, u_node);
            return .{ .last = u_node, .terminates = true };
        }
    };
}
