const EngineError = @import("../base.zig").EngineError;
const FunctionSummary = @import("../summary.zig").FunctionSummary;
const ids = @import("../../ids.zig");

pub fn mixin(comptime _Engine: type) type {
    return struct {
        /// Get or compute a summary for a function.
        /// Returns the summary if it can be computed, or null if the function
        /// cannot be analyzed (e.g., missing source, external function).
        pub fn getOrComputeSummary(self: *_Engine, fn_ast_node: ids.AstNodeId) ?*FunctionSummary {
            // Check cache first
            if (self.summary_cache.get(fn_ast_node)) |summary| {
                return summary;
            }

            // Try to compute a summary
            const summary = computeSummary(self, fn_ast_node) catch return null;
            if (summary) |s| {
                self.summary_cache.put(s) catch return null;
                return self.summary_cache.get(fn_ast_node);
            }
            return null;
        }

        /// Compute a summary for a function by analyzing its CFG.
        pub fn computeSummary(self: *_Engine, fn_ast_node: ids.AstNodeId) EngineError!?FunctionSummary {
            // Get or build the function's CFG
            const callee_cfg = self.getOrBuildFunctionCfg(fn_ast_node) orelse return null;

            var summary = FunctionSummary.init(self.allocator, fn_ast_node);

            // Analyze the CFG to extract summary information
            // We do a lightweight traversal to determine error behavior and effects

            var has_error_return = false;
            var has_call = false;

            for (callee_cfg.nodes.items) |cfg_node| {
                switch (cfg_node.ir_node.tag) {
                    .try_expr => {
                        has_error_return = true;
                    },
                    .call => {
                        has_call = true;
                    },
                    else => {},
                }
            }

            // Check edges for error paths
            for (callee_cfg.edges.items) |edge| {
                if (edge.kind == .try_error) {
                    has_error_return = true;
                }
            }

            // Set error behavior based on analysis
            summary.setErrorBehavior(has_error_return, false);

            // If the function has calls, it likely has side effects
            // (conservative: we don't track pure functions yet)
            if (!has_call) {
                // Check if the function only does computation (no I/O, etc.)
                // For now, be conservative and assume all functions have side effects
                // unless they're trivially simple
                var only_computation = true;
                for (callee_cfg.nodes.items) |cfg_node| {
                    switch (cfg_node.ir_node.tag) {
                        .fn_entry, .fn_exit, .ret, .var_decl, .assign, .block, .expr, .nop, .branch => {},
                        else => {
                            only_computation = false;
                            break;
                        },
                    }
                }
                if (only_computation and !has_error_return) {
                    summary.markPure();
                }
            }

            // Set return value to unknown (conservative)
            // More precise analysis could track concrete return values
            summary.setReturnValue(.unknown);

            return summary;
        }
    };
}
