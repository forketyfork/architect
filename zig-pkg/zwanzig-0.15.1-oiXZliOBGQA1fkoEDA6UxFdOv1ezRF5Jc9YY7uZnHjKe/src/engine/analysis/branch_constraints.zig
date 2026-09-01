const std = @import("std");
const assertions = @import("../../assertions.zig");
const call_utils = @import("../../analysis/call_utils.zig");
const ids = @import("../../ids.zig");
const Cfg = @import("../../cfg.zig").Cfg;
const CfgNode = @import("../../cfg.zig").CfgNode;
const Constraint = @import("../constraints.zig").Constraint;

pub fn mixin(comptime _Engine: type) type {
    return struct {
        pub fn getAssertionScope(self: *_Engine, current_cfg: *const Cfg) ?*assertions.AssertionScope {
            const fn_node = current_cfg.fn_ast_node orelse return null;
            if (self.assertion_scopes.getPtr(fn_node)) |scope| return scope;

            const src = self.source orelse return null;
            const tree = src.ast() catch return null;

            var scope = assertions.buildAssertionScope(self.allocator, tree, ids.astIndex(fn_node), false) catch return null;
            errdefer scope.deinit(self.allocator);

            self.assertion_scopes.put(fn_node, scope) catch {
                scope.deinit(self.allocator);
                return null;
            };

            return self.assertion_scopes.getPtr(fn_node);
        }

        /// Extract a constraint from a branch node's condition.
        /// Returns null if no constraint can be extracted.
        pub fn extractBranchConstraint(self: *_Engine, cfg_node: *const CfgNode, current_cfg: *const Cfg) ?Constraint {
            const ir_node = cfg_node.ir_node;
            if (ir_node.operand_node) |cond_node| {
                // First check if the condition is a literal boolean
                if (_Engine.literals.evaluateLiteral(self, cond_node)) |literal_val| {
                    if (literal_val.toBool()) |bool_val| {
                        // Use literalBool for compile-time known conditions to enable
                        // proper branch pruning (e.g., if (false) should be pruned)
                        return Constraint.literalBool(bool_val);
                    }
                }

                // Check if the condition is a null comparison (x == null or x != null)
                if (extractNullCheckConstraint(self, cond_node, current_cfg)) |null_constraint| {
                    return null_constraint;
                }

                const var_key = if (self.source != null)
                    (_Engine.var_resolution.resolveVarIdFromExpr(self, cond_node, current_cfg) orelse ids.varId(cond_node))
                else
                    ids.varId(cond_node);
                if (ir_node.operand2_node) |cmp_info| {
                    return Constraint.intCompare(var_key, .eq, @as(i64, cmp_info));
                }
                if (ir_node.ast_node) |ast_node| {
                    if (hasPayloadCapture(self, ast_node)) {
                        return Constraint.nullCheck(var_key, false);
                    }
                }
                // If we only have a variable and no comparison info, check if it's an optional
                // being used as a boolean (if (optional_var) ...)
                if (isOptionalType(self, cond_node, current_cfg)) {
                    // When optional is used as condition: true branch means non-null
                    return Constraint.nullCheck(var_key, false);
                }
                return Constraint.boolCheck(var_key, true);
            }
            return null;
        }

        /// Extract multiple constraints from a branch condition.
        /// This handles compound null checks like `a == null or b == null`.
        pub fn extractBranchConstraints(
            self: *_Engine,
            cfg_node: *const CfgNode,
            current_cfg: *const Cfg,
            out_constraints: *[4]?Constraint,
        ) usize {
            const ir_node = cfg_node.ir_node;
            if (ir_node.operand_node) |cond_node| {
                // Try compound null constraints first (for bool_or/bool_and patterns)
                const count = extractCompoundNullConstraints(self, cond_node, current_cfg, out_constraints);
                if (count > 0) {
                    return count;
                }

                // Fall back to single constraint
                if (extractBranchConstraint(self, cfg_node, current_cfg)) |c| {
                    out_constraints[0] = c;
                    return 1;
                }
            }
            return 0;
        }

        /// Extract a null check constraint from a comparison expression.
        /// Handles patterns like `x == null` and `x != null`.
        pub fn extractNullCheckConstraint(self: *_Engine, cond_node: u32, current_cfg: *const Cfg) ?Constraint {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (cond_node >= tags.len) return null;

            const tag = tags[cond_node];
            if (tag != .equal_equal and tag != .bang_equal) return null;

            // Get both operands of the comparison
            const lhs = datas[cond_node].node_and_node[0];
            const rhs = datas[cond_node].node_and_node[1];

            // Check if either operand is `null`
            const lhs_is_null = _Engine.literals.isNullLiteral(self, @intFromEnum(lhs));
            const rhs_is_null = _Engine.literals.isNullLiteral(self, @intFromEnum(rhs));

            if (!lhs_is_null and !rhs_is_null) return null;

            // The other operand is the variable being compared
            const var_node = if (lhs_is_null) @intFromEnum(rhs) else @intFromEnum(lhs);
            const var_key = _Engine.var_resolution.resolveVarIdFromExpr(self, var_node, current_cfg) orelse ids.varId(var_node);

            // For == null: is_null=true (true branch means var is null)
            // For != null: is_null=false (true branch means var is non-null)
            const is_null = (tag == .equal_equal);
            return Constraint.nullCheck(var_key, is_null);
        }

        /// Extract multiple null check constraints from compound expressions.
        /// Handles patterns like:
        /// - `a == null or b == null` -> on false branch, both a and b are non-null
        /// - `a != null and b != null` -> on true branch, both a and b are non-null
        /// Returns constraints for the TRUE branch; caller should negate for false branch.
        pub fn extractCompoundNullConstraints(
            self: *_Engine,
            cond_node: u32,
            current_cfg: *const Cfg,
            out_constraints: *[4]?Constraint,
        ) usize {
            const src = self.source orelse return 0;
            const tree = src.ast() catch return 0;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (cond_node >= tags.len) return 0;

            const tag = tags[cond_node];

            // Handle bool_or: (a == null or b == null)
            // On TRUE branch: at least one is null (can't use easily)
            // On FALSE branch: both are non-null (useful!)
            // We return the TRUE branch constraint, so for bool_or we return is_null=true for both
            if (tag == .bool_or) {
                const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
                const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);

                var count: usize = 0;
                if (extractNullCheckConstraint(self, lhs, current_cfg)) |c| {
                    out_constraints[count] = c;
                    count += 1;
                }
                if (extractNullCheckConstraint(self, rhs, current_cfg)) |c| {
                    out_constraints[count] = c;
                    count += 1;
                }
                return count;
            }

            // Handle bool_and: (a != null and b != null)
            // On TRUE branch: both are non-null (useful!)
            // On FALSE branch: at least one is null (can't use easily)
            if (tag == .bool_and) {
                const lhs = @intFromEnum(datas[cond_node].node_and_node[0]);
                const rhs = @intFromEnum(datas[cond_node].node_and_node[1]);

                var count: usize = 0;
                if (extractNullCheckConstraint(self, lhs, current_cfg)) |c| {
                    out_constraints[count] = c;
                    count += 1;
                }
                if (extractNullCheckConstraint(self, rhs, current_cfg)) |c| {
                    out_constraints[count] = c;
                    count += 1;
                }
                return count;
            }

            // Fall back to single constraint
            if (extractNullCheckConstraint(self, cond_node, current_cfg)) |c| {
                out_constraints[0] = c;
                return 1;
            }

            return 0;
        }

        /// Extract a nullability constraint from an assertion call.
        /// Handles patterns like:
        /// - testing.expect(x != null)
        /// - std.testing.expect(x != null)
        /// - std.testing.expectEqual(x, null)
        /// After such a call, we assume the asserted relationship holds.
        pub fn extractAssertionConstraint(self: *_Engine, call_node: u32, current_cfg: *const Cfg) ?Constraint {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (call_node >= tags.len) return null;

            // Get the full call information
            var call_buf: [1]std.zig.Ast.Node.Index = undefined;
            const full_call = switch (tags[call_node]) {
                .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
                else => null,
            } orelse return null;

            const scope = getAssertionScope(self, current_cfg) orelse return null;
            var assertion_name = assertions.resolveAssertionName(tree, full_call.ast.fn_expr, scope);
            if (assertion_name == null) {
                assertion_name = assertions.resolveDebugAssertionName(tree, full_call.ast.fn_expr, scope);
            }
            const resolved_name = assertion_name orelse return null;
            const assertion_kind = assertions.constraintKindForName(resolved_name) orelse return null;

            // Get the first argument (the condition being asserted)
            const args = full_call.ast.params;
            if (args.len == 0) return null;

            switch (assertion_kind) {
                .boolean => {
                    const cond_node = @intFromEnum(args[0]);

                    // Check if the condition is a null check (x != null)
                    if (cond_node >= tags.len) return null;
                    const cond_tag = tags[cond_node];

                    if (cond_tag == .bang_equal) {
                        // x != null pattern - after expect(x != null), x is non-null
                        const lhs = datas[cond_node].node_and_node[0];
                        const rhs = datas[cond_node].node_and_node[1];

                        const lhs_is_null = _Engine.literals.isNullLiteral(self, @intFromEnum(lhs));
                        const rhs_is_null = _Engine.literals.isNullLiteral(self, @intFromEnum(rhs));

                        if (lhs_is_null or rhs_is_null) {
                            const var_node = if (lhs_is_null) @intFromEnum(rhs) else @intFromEnum(lhs);
                            const var_key = _Engine.var_resolution.resolveVarIdFromExpr(self, var_node, current_cfg) orelse return null;
                            // After expect(x != null), x is proven non-null (is_null=false)
                            return Constraint.nullCheck(var_key, false);
                        }
                    } else if (cond_tag == .equal_equal) {
                        // x == null pattern - after expect(x == null), x is proven null
                        // This is less common but we handle it for completeness
                        const lhs = datas[cond_node].node_and_node[0];
                        const rhs = datas[cond_node].node_and_node[1];

                        const lhs_is_null = _Engine.literals.isNullLiteral(self, @intFromEnum(lhs));
                        const rhs_is_null = _Engine.literals.isNullLiteral(self, @intFromEnum(rhs));

                        if (lhs_is_null or rhs_is_null) {
                            const var_node = if (lhs_is_null) @intFromEnum(rhs) else @intFromEnum(lhs);
                            const var_key = _Engine.var_resolution.resolveVarIdFromExpr(self, var_node, current_cfg) orelse return null;
                            // After expect(x == null), x is proven null (is_null=true)
                            return Constraint.nullCheck(var_key, true);
                        }
                    }

                    return null;
                },
                .equality => {
                    if (args.len < 2) return null;
                    const lhs_node = @intFromEnum(args[0]);
                    const rhs_node = @intFromEnum(args[1]);

                    const lhs_is_null = _Engine.literals.isNullLiteral(self, lhs_node);
                    const rhs_is_null = _Engine.literals.isNullLiteral(self, rhs_node);

                    if (lhs_is_null or rhs_is_null) {
                        const var_node = if (lhs_is_null) rhs_node else lhs_node;
                        const var_key = _Engine.var_resolution.resolveVarIdFromExpr(self, var_node, current_cfg) orelse return null;
                        return Constraint.nullCheck(var_key, true);
                    }

                    const lhs_is_non_null = _Engine.literals.isNonNullLiteral(self, lhs_node);
                    const rhs_is_non_null = _Engine.literals.isNonNullLiteral(self, rhs_node);

                    if (lhs_is_non_null or rhs_is_non_null) {
                        const var_node = if (lhs_is_non_null) rhs_node else lhs_node;
                        const var_key = _Engine.var_resolution.resolveVarIdFromExpr(self, var_node, current_cfg) orelse return null;
                        return Constraint.nullCheck(var_key, false);
                    }

                    return null;
                },
            }
        }

        /// Extract a non-null constraint from a try expression wrapping an assertion call.
        /// Handles patterns like: try testing.expect(x != null)
        pub fn extractTryAssertionConstraint(self: *_Engine, try_ast_node: u32, current_cfg: *const Cfg) ?Constraint {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (try_ast_node >= tags.len) return null;

            // Check if the AST node is a try expression
            if (tags[try_ast_node] != .@"try") return null;

            // Get the operand of the try expression
            const try_operand = @intFromEnum(datas[try_ast_node].node);
            if (try_operand >= tags.len) return null;

            // Check if the operand is a call expression
            const operand_tag = tags[try_operand];
            if (!call_utils.isCallNode(operand_tag)) {
                return null;
            }

            // Delegate to the regular assertion constraint extraction
            return extractAssertionConstraint(self, try_operand, current_cfg);
        }

        /// Check if a condition expression is an optional type.
        pub fn isOptionalType(self: *_Engine, cond_node: u32, current_cfg: *const Cfg) bool {
            _ = current_cfg;
            const src = self.source orelse return false;
            const tree = src.ast() catch return false;
            const tags = tree.nodes.items(.tag);

            if (cond_node >= tags.len) return false;

            // If it's an identifier, check if the type context knows it's optional
            if (tags[cond_node] == .identifier) {
                if (self.type_context) |type_ctx| {
                    const main_tokens = tree.nodes.items(.main_token);
                    const token = main_tokens[cond_node];
                    const name = tree.tokenSlice(token);
                    if (type_ctx.getDeclType(name)) |type_info| {
                        return type_info.kind == .optional;
                    }
                }
            }

            return false;
        }

        pub fn hasPayloadCapture(self: *_Engine, ast_node: u32) bool {
            const src = self.source orelse return false;
            const tree = src.ast() catch return false;
            const tags = tree.nodes.items(.tag);

            if (ast_node >= tags.len) return false;
            if (tags[ast_node] != .@"if" and tags[ast_node] != .if_simple) return false;
            const full_if = tree.fullIf(@enumFromInt(ast_node)) orelse return false;
            return full_if.payload_token != null;
        }
    };
}
