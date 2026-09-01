const ids = @import("../../ids.zig");
const Cfg = @import("../../cfg.zig").Cfg;
const VarResolver = @import("../var_resolver.zig").VarResolver;

pub fn mixin(comptime _Engine: type) type {
    return struct {
        pub fn resolveVarIdFromVarDecl(self: *_Engine, var_decl_node: u32) ?ids.VarId {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const full = tree.fullVarDecl(@enumFromInt(var_decl_node)) orelse return null;
            const token_tags = tree.tokens.items(.tag);
            const name_token = full.ast.mut_token + 1;
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) return null;
            return ids.varId(name_token);
        }

        pub fn resolveVarIdFromIdentifier(self: *_Engine, identifier_node: u32, current_cfg: *const Cfg) ?ids.VarId {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const tags = tree.nodes.items(.tag);
            const token_tags = tree.tokens.items(.tag);
            const main_tokens = tree.nodes.items(.main_token);

            if (identifier_node >= tags.len) return null;
            if (tags[identifier_node] != .identifier) return null;
            const token = main_tokens[identifier_node];
            if (token >= token_tags.len or token_tags[token] != .identifier) return null;

            if (current_cfg.fn_ast_node) |fn_node| {
                if (getOrBuildVarResolver(self, fn_node)) |resolver| {
                    if (resolver.resolve(identifier_node)) |var_id| {
                        return var_id;
                    }
                }
            }

            return ids.varId(token);
        }

        pub fn resolveDeclInfoFromIdentifier(self: *_Engine, identifier_node: u32, current_cfg: *const Cfg) ?VarResolver.DeclInfo {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const tags = tree.nodes.items(.tag);

            if (identifier_node >= tags.len or tags[identifier_node] != .identifier) return null;

            if (current_cfg.fn_ast_node) |fn_node| {
                if (getOrBuildVarResolver(self, fn_node)) |resolver| {
                    return resolver.resolveDeclInfo(identifier_node);
                }
            }

            return null;
        }

        /// Resolve a variable ID from an expression node.
        /// This handles identifiers, grouped expressions, unwrap operations, etc.
        /// Uses the VarResolver when available to correctly handle variable shadowing.
        pub fn resolveVarIdFromExpr(self: *_Engine, expr_node: u32, current_cfg: *const Cfg) ?ids.VarId {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);

            if (expr_node >= tags.len) return null;
            return switch (tags[expr_node]) {
                .identifier => resolveVarIdFromIdentifier(self, expr_node, current_cfg),
                .grouped_expression, .unwrap_optional => blk: {
                    const data = datas[expr_node].node_and_token;
                    break :blk resolveVarIdFromExpr(self, @intFromEnum(data[0]), current_cfg);
                },
                .field_access => blk: {
                    // For field access like self.cache_dir, create a combined VarId
                    // from the base expression and a hash of the field name
                    const field_access_data = datas[expr_node].node_and_token;
                    const base_node = @intFromEnum(field_access_data[0]);
                    const field_token = field_access_data[1];

                    // Hash the field name (not token position) for consistent VarId across usages
                    const field_name = tree.tokenSlice(field_token);
                    const field_name_hash = hashFieldName(field_name);

                    // Recursively resolve the base (handles chained field access like a.b.c)
                    if (resolveVarIdFromExpr(self, base_node, current_cfg)) |base_var_id| {
                        // Combine base VarId and field name hash to create a unique ID for the field access
                        break :blk combineFieldAccessId(base_var_id, field_name_hash);
                    }
                    // If we can't resolve the base, use the field name hash alone as a fallback
                    break :blk combineFieldAccessId(ids.varId(0), field_name_hash);
                },
                .slice, .slice_open, .slice_sentinel => blk: {
                    const slice = tree.fullSlice(@enumFromInt(expr_node)) orelse break :blk null;
                    break :blk resolveVarIdFromExpr(self, @intFromEnum(slice.ast.sliced), current_cfg);
                },
                .array_access => blk: {
                    const pair = datas[expr_node].node_and_node;
                    break :blk resolveVarIdFromExpr(self, @intFromEnum(pair[0]), current_cfg);
                },
                .address_of, .deref, .@"try" => blk: {
                    const child = datas[expr_node].node;
                    break :blk resolveVarIdFromExpr(self, @intFromEnum(child), current_cfg);
                },
                .@"catch" => blk: {
                    const pair = datas[expr_node].node_and_node;
                    if (resolveVarIdFromExpr(self, @intFromEnum(pair[0]), current_cfg)) |var_id| {
                        break :blk var_id;
                    }
                    break :blk resolveVarIdFromExpr(self, @intFromEnum(pair[1]), current_cfg);
                },
                else => null,
            };
        }

        /// Hash a field name to a u32 using FNV-1a.
        pub fn hashFieldName(name: []const u8) u32 {
            const fnv_offset: u32 = 2166136261;
            const fnv_prime: u32 = 16777619;

            var hash: u32 = fnv_offset;
            for (name) |byte| {
                hash ^= byte;
                hash *%= fnv_prime;
            }
            return hash;
        }

        /// Combine a base VarId with a field name hash to create a unique VarId for field access.
        /// Uses FNV-1a hash to combine the two values into a single u32.
        pub fn combineFieldAccessId(base_var_id: ids.VarId, field_name_hash: u32) ids.VarId {
            // Use FNV-1a hash to combine base_var_id and field_name_hash
            const fnv_offset: u32 = 2166136261;
            const fnv_prime: u32 = 16777619;

            var hash: u32 = fnv_offset;
            // Mix in the base var id
            const base_val = @intFromEnum(base_var_id);
            hash ^= @truncate(base_val & 0xFF);
            hash *%= fnv_prime;
            hash ^= @truncate((base_val >> 8) & 0xFF);
            hash *%= fnv_prime;
            hash ^= @truncate((base_val >> 16) & 0xFF);
            hash *%= fnv_prime;
            hash ^= @truncate((base_val >> 24) & 0xFF);
            hash *%= fnv_prime;
            // Mix in the field name hash
            hash ^= @truncate(field_name_hash & 0xFF);
            hash *%= fnv_prime;
            hash ^= @truncate((field_name_hash >> 8) & 0xFF);
            hash *%= fnv_prime;
            hash ^= @truncate((field_name_hash >> 16) & 0xFF);
            hash *%= fnv_prime;
            hash ^= @truncate((field_name_hash >> 24) & 0xFF);
            hash *%= fnv_prime;

            return ids.varId(hash);
        }

        pub fn getOrBuildVarResolver(self: *_Engine, fn_node: ids.AstNodeId) ?*VarResolver {
            if (self.var_resolvers.get(fn_node)) |resolver| return resolver;
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;

            const resolver_ptr = self.allocator.create(VarResolver) catch return null;
            resolver_ptr.* = VarResolver.init(self.allocator, tree, fn_node) catch {
                self.allocator.destroy(resolver_ptr);
                return null;
            };

            self.var_resolvers.put(fn_node, resolver_ptr) catch {
                resolver_ptr.deinit();
                self.allocator.destroy(resolver_ptr);
                return null;
            };
            return resolver_ptr;
        }

        pub fn resolveVarDeclInitNode(self: *_Engine, var_decl_node: u32) ?u32 {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const full = tree.fullVarDecl(@enumFromInt(var_decl_node)) orelse return null;
            if (full.ast.init_node.unwrap()) |init_node| {
                return @intFromEnum(init_node);
            }
            return null;
        }
    };
}
