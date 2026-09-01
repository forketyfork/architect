const source_range = @import("source_range.zig");
const graph = @import("../graph.zig");
const ids = @import("../../ids.zig");
const Source = @import("../../source.zig").Source;

const Cfg = graph.Cfg;
const IrNode = graph.IrNode;
const CfgNodeId = ids.CfgNodeId;

pub fn mixin(comptime _Builder: type) type {
    return struct {
        /// Build the CFG for a switch expression as a multi-way branch.
        ///
        /// Shape:
        ///   prev_node -> branch(cond)
        ///   branch    -> arm_1_body -> merge
        ///   branch    -> arm_2_body -> merge
        ///   ...
        ///   merge     -> (caller wires up successor)
        ///
        /// Arms whose body terminates (return/unreachable) do not feed `merge`.
        /// If every arm terminates, the merge node is left as an orphan and the
        /// result is marked terminating (caller may discard it). Multi-target
        /// prongs (`.a, .b => body`) and ranges share a single arm body — values
        /// are not extracted in v1; every reachable arm contributes one edge.
        pub fn processSwitch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const range = try source_range.getSourceRange(source, ast_node);

            const full_switch = tree.switchFull(@enumFromInt(ast_node));

            var branch_ir = IrNode.initFull(.branch, ast_node, range);
            branch_ir.operand_node = @intFromEnum(full_switch.ast.condition);
            const branch_node = try cfg.addNode(branch_ir);
            try cfg.addEdge(prev_node, branch_node);

            if (full_switch.ast.cases.len == 0) {
                return .{ .last = branch_node, .terminates = false };
            }

            const merge_node = try cfg.addNode(IrNode.init(.nop));

            var any_reaches_merge = false;
            for (full_switch.ast.cases) |case_node| {
                const full_case = tree.fullSwitchCase(case_node) orelse continue;
                const target = @intFromEnum(full_case.ast.target_expr);

                if (target == 0) {
                    try cfg.addEdge(branch_node, merge_node);
                    any_reaches_merge = true;
                    continue;
                }

                const arm_result = try self.processNode(cfg, source, target, branch_node);
                if (arm_result.terminates) continue;

                if (arm_result.last) |arm_end| {
                    try cfg.addEdge(arm_end, merge_node);
                } else {
                    try cfg.addEdge(branch_node, merge_node);
                }
                any_reaches_merge = true;
            }

            if (!any_reaches_merge) {
                return .{ .last = branch_node, .terminates = true };
            }

            return .{ .last = merge_node, .terminates = false };
        }

        /// Inline switch as the initializer of a var_decl:
        ///   const x = switch (k) { .a => f(), .b => g(), };
        /// Build the switch sub-graph, then attach the var_decl downstream of
        /// the merge so the engine's worklist visits each arm's expression.
        pub fn processVarDeclWithSwitch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            var_decl_node: u32,
            switch_init_node: u32,
            prev_node: CfgNodeId,
            var_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            const switch_result = try processSwitch(self, cfg, source, switch_init_node, prev_node);

            if (switch_result.terminates or switch_result.last == null) {
                return switch_result;
            }

            var decl_ir = IrNode.initFull(.var_decl, var_decl_node, var_range);
            decl_ir = _Builder.type_annotation.annotateWithType(self, decl_ir, source, var_decl_node);
            const decl_node = try cfg.addNode(decl_ir);
            try cfg.addEdge(switch_result.last.?, decl_node);

            return .{ .last = decl_node, .terminates = false };
        }

        /// Inline switch as the RHS of an assignment:
        ///   x = switch (k) { .a => f(), .b => g(), };
        pub fn processAssignWithSwitch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            assign_node_ast: u32,
            lhs_node: u32,
            switch_expr_node: u32,
            prev_node: CfgNodeId,
            assign_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            const switch_result = try processSwitch(self, cfg, source, switch_expr_node, prev_node);

            if (switch_result.terminates or switch_result.last == null) {
                return switch_result;
            }

            const assign_node = try cfg.addNode(IrNode.initAssign(assign_node_ast, lhs_node, switch_expr_node, assign_range));
            try cfg.addEdge(switch_result.last.?, assign_node);

            return .{ .last = assign_node, .terminates = false };
        }

        /// Inline switch as the return expression:
        ///   return switch (k) { .a => 1, .b => 2, };
        pub fn processReturnWithSwitch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ret_node_ast: u32,
            switch_expr_node: u32,
            prev_node: CfgNodeId,
            ret_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            const switch_result = try processSwitch(self, cfg, source, switch_expr_node, prev_node);

            if (switch_result.terminates) {
                // All arms terminate on their own; we still pin the result to
                // the function exit so callers see a clean terminating path.
                return .{ .last = switch_result.last, .terminates = true };
            }

            const anchor = switch_result.last orelse prev_node;
            const ret_node = try cfg.addNode(IrNode.initFull(.ret, ret_node_ast, ret_range));
            try cfg.addEdge(anchor, ret_node);
            try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);

            return .{ .last = ret_node, .terminates = true };
        }
    };
}
