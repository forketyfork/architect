const source_range = @import("source_range.zig");
const graph = @import("../graph.zig");
const ids = @import("../../ids.zig");
const Source = @import("../../source.zig").Source;
const type_context_mod = @import("../../type_context.zig");

const Cfg = graph.Cfg;
const IrNode = graph.IrNode;
const CfgNodeId = ids.CfgNodeId;
const TypeInfo = type_context_mod.TypeInfo;

pub fn mixin(comptime _Builder: type) type {
    return struct {
        pub fn processReturnWithTry(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ret_node_ast: u32,
            try_expr_node: u32,
            prev_node: CfgNodeId,
            ret_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            _ = self;
            const try_range = try source_range.getSourceRange(source, try_expr_node);

            // Return with try expression: return try bar();
            //   prev -> try_node -> ret_node -> exit (success path)
            //   try_node --[try_error]--> fn_exit (error path)
            var try_ir = IrNode.initFull(.try_expr, try_expr_node, try_range);
            try_ir = try_ir.withType(TypeInfo.initErrorUnion());
            const try_node = try cfg.addNode(try_ir);
            try cfg.addEdge(prev_node, try_node);

            // Error path: propagate to function exit
            try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

            // Success path: continue to return statement
            const ret_node = try cfg.addNode(IrNode.initFull(.ret, ret_node_ast, ret_range));
            try cfg.addEdgeWithKind(try_node, ret_node, .try_success);
            try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);

            return .{ .last = ret_node, .terminates = true };
        }

        pub fn processReturnWithCatch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ret_node_ast: u32,
            catch_expr_node: u32,
            prev_node: CfgNodeId,
            ret_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const catch_range = try source_range.getSourceRange(source, catch_expr_node);
            const data = tree.nodes.items(.data);

            // Return with catch expression
            var catch_ir = IrNode.initFull(.catch_expr, catch_expr_node, catch_range);
            catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
            const catch_node = try cfg.addNode(catch_ir);
            try cfg.addEdge(prev_node, catch_node);

            // Get the handler from catch node
            const catch_data = data[catch_expr_node].node_and_node;
            const handler_ast = @intFromEnum(catch_data[1]);

            // Create the return node
            const ret_node = try cfg.addNode(IrNode.initFull(.ret, ret_node_ast, ret_range));

            // Success path: no error, value is unwrapped, goes to return
            try cfg.addEdgeWithKind(catch_node, ret_node, .catch_success);

            // Error path: process handler if present, then go to return
            if (handler_ast != 0) {
                const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

                if (handler_result.last) |handler_end| {
                    // Handler produced nodes - mark edge from catch to handler as error edge
                    markEdgeFromCatchError(self, cfg, catch_node);
                    if (!handler_result.terminates) {
                        try cfg.addEdge(handler_end, ret_node);
                    }
                } else {
                    // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                    try cfg.addEdgeWithKind(catch_node, ret_node, .catch_error);
                }
            } else {
                try cfg.addEdgeWithKind(catch_node, ret_node, .catch_error);
            }

            try cfg.addEdgeWithKind(ret_node, cfg.exit, .jump);
            return .{ .last = ret_node, .terminates = true };
        }

        pub fn processVarDeclWithTry(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            var_decl_node: u32,
            try_init_node: u32,
            prev_node: CfgNodeId,
            var_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            const try_range = try source_range.getSourceRange(source, try_init_node);

            // Try expression in var decl initializer:
            //   prev -> try_node -> var_decl_node (success path)
            //   try_node --[try_error]--> fn_exit
            var try_ir = IrNode.initFull(.try_expr, try_init_node, try_range);
            // Try expressions produce error unions
            try_ir = try_ir.withType(TypeInfo.initErrorUnion());
            const try_node = try cfg.addNode(try_ir);
            try cfg.addEdge(prev_node, try_node);

            // Error path: propagate to function exit
            try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

            // Success path: continue to var decl (try_success edge)
            // Annotate var decl with type info
            var decl_ir = IrNode.initFull(.var_decl, var_decl_node, var_range);
            decl_ir = _Builder.type_annotation.annotateWithType(self, decl_ir, source, var_decl_node);
            const decl_node = try cfg.addNode(decl_ir);
            try cfg.addEdgeWithKind(try_node, decl_node, .try_success);

            return .{ .last = decl_node, .terminates = false };
        }

        pub fn processVarDeclWithCatch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            var_decl_node: u32,
            catch_init_node: u32,
            prev_node: CfgNodeId,
            var_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const catch_range = try source_range.getSourceRange(source, catch_init_node);
            const data = tree.nodes.items(.data);

            // Catch expression in var decl initializer:
            //   prev -> catch_node -> var_decl_node
            //   catch_node has success and error paths that both lead to var_decl
            var catch_ir = IrNode.initFull(.catch_expr, catch_init_node, catch_range);
            // Catch expressions handle error unions
            catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
            const catch_node = try cfg.addNode(catch_ir);
            try cfg.addEdge(prev_node, catch_node);

            // Get the RHS (catch handler body) from the catch node
            // For catch nodes, data is node_and_node where [0] is LHS (operand), [1] is RHS (handler)
            const catch_data = data[catch_init_node].node_and_node;
            const handler_ast = @intFromEnum(catch_data[1]);

            // Create the var decl node that both paths lead to
            // Annotate with type information
            var decl_ir = IrNode.initFull(.var_decl, var_decl_node, var_range);
            decl_ir = _Builder.type_annotation.annotateWithType(self, decl_ir, source, var_decl_node);
            const decl_node = try cfg.addNode(decl_ir);

            // Success path: no error, value is unwrapped, goes to var decl
            try cfg.addEdgeWithKind(catch_node, decl_node, .catch_success);

            // Error path: process handler if present, then go to var decl
            if (handler_ast != 0) {
                const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

                if (handler_result.last) |handler_end| {
                    // Handler produced nodes - mark edge from catch to handler as error edge
                    markEdgeFromCatchError(self, cfg, catch_node);
                    if (!handler_result.terminates) {
                        try cfg.addEdge(handler_end, decl_node);
                    }
                } else {
                    // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                    try cfg.addEdgeWithKind(catch_node, decl_node, .catch_error);
                }
            } else {
                // No handler body (catch default value like `catch 0`)
                // Error edge goes directly to var decl
                try cfg.addEdgeWithKind(catch_node, decl_node, .catch_error);
            }

            return .{ .last = decl_node, .terminates = false };
        }

        pub fn processAssignWithTry(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            assign_node_ast: u32,
            lhs_node: u32,
            try_expr_node: u32,
            prev_node: CfgNodeId,
            assign_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            _ = self;
            const try_range = try source_range.getSourceRange(source, try_expr_node);

            // Assignment with try expression: x = try bar();
            //   prev -> try_node -> assign_node (success path)
            //   try_node --[try_error]--> fn_exit (error path)
            var try_ir = IrNode.initFull(.try_expr, try_expr_node, try_range);
            try_ir = try_ir.withType(TypeInfo.initErrorUnion());
            const try_node = try cfg.addNode(try_ir);
            try cfg.addEdge(prev_node, try_node);

            // Error path: propagate to function exit
            try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

            // Success path: continue to assignment
            const assign_node = try cfg.addNode(IrNode.initAssign(assign_node_ast, lhs_node, try_expr_node, assign_range));
            try cfg.addEdgeWithKind(try_node, assign_node, .try_success);

            return .{ .last = assign_node, .terminates = false };
        }

        pub fn processAssignWithCatch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            assign_node_ast: u32,
            lhs_node: u32,
            catch_expr_node: u32,
            prev_node: CfgNodeId,
            assign_range: graph.SourceRange,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const catch_range = try source_range.getSourceRange(source, catch_expr_node);
            const data = tree.nodes.items(.data);

            // Assignment with catch expression
            var catch_ir = IrNode.initFull(.catch_expr, catch_expr_node, catch_range);
            catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
            const catch_node = try cfg.addNode(catch_ir);
            try cfg.addEdge(prev_node, catch_node);

            // Get the handler from catch node
            const catch_data = data[catch_expr_node].node_and_node;
            const handler_ast = @intFromEnum(catch_data[1]);

            // Create the assign node
            const assign_node = try cfg.addNode(IrNode.initAssign(assign_node_ast, lhs_node, catch_expr_node, assign_range));

            // Success path: no error, value is unwrapped, goes to assign
            try cfg.addEdgeWithKind(catch_node, assign_node, .catch_success);

            // Error path: process handler if present, then go to assign
            if (handler_ast != 0) {
                const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

                if (handler_result.last) |handler_end| {
                    // Handler produced nodes - mark edge from catch to handler as error edge
                    markEdgeFromCatchError(self, cfg, catch_node);
                    if (!handler_result.terminates) {
                        try cfg.addEdge(handler_end, assign_node);
                    }
                } else {
                    // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                    try cfg.addEdgeWithKind(catch_node, assign_node, .catch_error);
                }
            } else {
                try cfg.addEdgeWithKind(catch_node, assign_node, .catch_error);
            }

            return .{ .last = assign_node, .terminates = false };
        }

        pub fn processTry(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            _ = self;
            const range = try source_range.getSourceRange(source, ast_node);

            // Try expression: evaluates an error union and either:
            // - On success: unwraps the value and continues normally
            // - On error: propagates the error to the caller (jumps to exit)
            //
            // CFG structure:
            //   prev_node -> try_node
            //   try_node --[try_success]--> (next statement)
            //   try_node --[try_error]--> fn_exit
            var try_ir = IrNode.initFull(.try_expr, ast_node, range);
            // Try expressions operate on error unions
            try_ir = try_ir.withType(TypeInfo.initErrorUnion());
            const try_node = try cfg.addNode(try_ir);
            try cfg.addEdge(prev_node, try_node);

            // Error path: propagate to function exit
            try cfg.addEdgeWithKind(try_node, cfg.exit, .try_error);

            // Success path continues to the next statement.
            // Return next_edge_kind so the block processing marks the edge as try_success.
            return .{ .last = try_node, .terminates = false, .next_edge_kind = .try_success };
        }

        pub fn processCatch(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            const tree = try source.ast();
            const range = try source_range.getSourceRange(source, ast_node);
            const data = tree.nodes.items(.data);

            // Catch expression: handles errors from an error union
            // Structure: expr catch |opt_err| handler
            //
            // CFG structure:
            //   prev_node -> catch_node
            //   catch_node --[catch_success]--> merge_node (value is unwrapped)
            //   catch_node --[catch_error]--> handler_body -> merge_node
            var catch_ir = IrNode.initFull(.catch_expr, ast_node, range);
            // Catch expressions handle error unions
            catch_ir = catch_ir.withType(TypeInfo.initErrorUnion());
            const catch_node = try cfg.addNode(catch_ir);
            try cfg.addEdge(prev_node, catch_node);

            // Get the RHS (catch handler body) from the catch node
            // For catch nodes, data is node_and_node where [0] is LHS (operand), [1] is RHS (handler)
            const catch_data = data[ast_node].node_and_node;
            const handler_ast = @intFromEnum(catch_data[1]);

            // Create merge node for after the catch
            const merge_node = try cfg.addNode(IrNode.init(.nop));

            // Success path: no error, value is unwrapped, goes directly to merge
            try cfg.addEdgeWithKind(catch_node, merge_node, .catch_success);

            // Error path: go to handler, then to merge
            if (handler_ast != 0) {
                const handler_result = try self.processNode(cfg, source, handler_ast, catch_node);

                if (handler_result.last) |handler_end| {
                    // Handler produced nodes - mark edge from catch to handler as error edge
                    markEdgeFromCatchError(self, cfg, catch_node);
                    if (!handler_result.terminates) {
                        try cfg.addEdgeWithKind(handler_end, merge_node, .catch_success);
                    }
                } else {
                    // Empty handler (e.g., `catch {}`) - add direct catch_error edge
                    try cfg.addEdgeWithKind(catch_node, merge_node, .catch_error);
                }
            } else {
                // No handler body (catch default value like `catch 0`)
                // Error edge goes directly to merge
                try cfg.addEdgeWithKind(catch_node, merge_node, .catch_error);
            }

            return .{ .last = merge_node, .terminates = false };
        }

        pub fn processDefer(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            _ = self;
            const range = try source_range.getSourceRange(source, ast_node);

            // Defer bodies execute at scope exit, not at declaration time.
            // We record the defer statement node (which references the body AST)
            // but don't add the body to the main control flow. The body can be
            // analyzed separately when needed for scope exit paths.
            const defer_node = try cfg.addNode(IrNode.initFull(.defer_stmt, ast_node, range));
            try cfg.addEdge(prev_node, defer_node);

            return .{ .last = defer_node, .terminates = false };
        }

        pub fn processErrdefer(
            self: *_Builder,
            cfg: *Cfg,
            source: *Source,
            ast_node: u32,
            prev_node: CfgNodeId,
        ) !_Builder.ProcessResult {
            _ = self;
            const range = try source_range.getSourceRange(source, ast_node);

            // Errdefer bodies execute at scope exit on error paths, not at declaration time.
            // We record the errdefer statement node (which references the body AST)
            // but don't add the body to the main control flow. The body can be
            // analyzed separately when needed for error exit paths.
            const errdefer_node = try cfg.addNode(IrNode.initFull(.errdefer_stmt, ast_node, range));
            try cfg.addEdge(prev_node, errdefer_node);

            return .{ .last = errdefer_node, .terminates = false };
        }

        fn markEdgeFromCatchError(self: *_Builder, cfg: *Cfg, catch_node: CfgNodeId) void {
            _ = self;
            // Find the most recent edge from catch_node that is normal and mark it as catch_error
            var i = cfg.edges.items.len;
            while (i > 0) {
                i -= 1;
                if (cfg.edges.items[i].from == catch_node and cfg.edges.items[i].kind == .normal) {
                    cfg.edges.items[i].kind = .catch_error;
                    break;
                }
            }
        }
    };
}
