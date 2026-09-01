const std = @import("std");
const AbstractValue = @import("../value.zig").AbstractValue;

pub fn mixin(comptime _Engine: type) type {
    return struct {
        /// Evaluate a literal expression to an AbstractValue.
        /// Returns null if the node is not a literal or cannot be evaluated.
        /// Handles:
        /// - Boolean literals (true/false identifiers)
        /// - Integer literals (number_literal nodes)
        pub fn evaluateLiteral(self: *_Engine, node: u32) ?AbstractValue {
            const src = self.source orelse return null;
            const tree = src.ast() catch return null;
            const tags = tree.nodes.items(.tag);
            const main_tokens = tree.nodes.items(.main_token);
            const token_tags = tree.tokens.items(.tag);
            const token_starts = tree.tokens.items(.start);

            if (node >= tags.len) return null;

            switch (tags[node]) {
                .identifier => {
                    // Check for true/false boolean literals using shared utility
                    const value_mod = @import("../value.zig");
                    if (value_mod.evaluateBoolLiteral(tree, node)) |b| {
                        return .{ .concrete_bool = b };
                    }
                    return null;
                },
                .grouped_expression, .unwrap_optional => {
                    const child = @intFromEnum(tree.nodes.items(.data)[node].node_and_token[0]);
                    if (child == 0) return null;
                    return evaluateLiteral(self, child);
                },
                .negation, .negation_wrap => {
                    const child = @intFromEnum(tree.nodes.items(.data)[node].node);
                    if (child == 0) return null;
                    const child_value = evaluateLiteral(self, child) orelse return null;
                    return switch (child_value) {
                        .concrete_int => |v| blk: {
                            if (v == std.math.minInt(i64)) break :blk null;
                            break :blk .{ .concrete_int = -v };
                        },
                        else => null,
                    };
                },
                .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                    const builtin_name = builtinCallName(tree, tags, token_tags, node) orelse return null;
                    if (!std.mem.eql(u8, builtin_name, "@as")) return null;
                    var params_buf: [2]std.zig.Ast.Node.Index = undefined;
                    const params = tree.builtinCallParams(&params_buf, @enumFromInt(node)) orelse return null;
                    if (params.len < 2) return null;
                    return evaluateLiteral(self, @intFromEnum(params[1]));
                },
                .number_literal => {
                    // Parse integer literal
                    const token = main_tokens[node];
                    if (token >= token_tags.len) return null;
                    const start = token_starts[token];
                    var end = start;
                    while (end < tree.source.len) {
                        const c = tree.source[end];
                        if (!std.ascii.isDigit(c) and c != '_' and c != 'x' and c != 'X' and
                            c != 'b' and c != 'B' and c != 'o' and c != 'O' and
                            !(c >= 'a' and c <= 'f') and !(c >= 'A' and c <= 'F'))
                        {
                            break;
                        }
                        end += 1;
                    }
                    const num_str = tree.source[start..end];
                    // Remove underscores for parsing
                    var clean_buf: [64]u8 = undefined;
                    var clean_len: usize = 0;
                    for (num_str) |c| {
                        if (c != '_' and clean_len < clean_buf.len) {
                            clean_buf[clean_len] = c;
                            clean_len += 1;
                        }
                    }
                    const clean_str = clean_buf[0..clean_len];
                    // Detect base and parse
                    if (clean_len >= 2 and clean_buf[0] == '0') {
                        if (clean_buf[1] == 'x' or clean_buf[1] == 'X') {
                            // Hex
                            const value = std.fmt.parseInt(i64, clean_str[2..], 16) catch return null;
                            return .{ .concrete_int = value };
                        } else if (clean_buf[1] == 'b' or clean_buf[1] == 'B') {
                            // Binary
                            const value = std.fmt.parseInt(i64, clean_str[2..], 2) catch return null;
                            return .{ .concrete_int = value };
                        } else if (clean_buf[1] == 'o' or clean_buf[1] == 'O') {
                            // Octal
                            const value = std.fmt.parseInt(i64, clean_str[2..], 8) catch return null;
                            return .{ .concrete_int = value };
                        }
                    }
                    // Decimal
                    const value = std.fmt.parseInt(i64, clean_str, 10) catch return null;
                    return .{ .concrete_int = value };
                },
                else => return null,
            }
        }

        pub fn isNullLiteral(self: *_Engine, node: u32) bool {
            const src = self.source orelse return false;
            const tree = src.ast() catch return false;
            const tags = tree.nodes.items(.tag);
            const main_tokens = tree.nodes.items(.main_token);

            if (node >= tags.len) return false;
            if (tags[node] != .identifier) return false;

            const token = main_tokens[node];
            const token_slice = tree.tokenSlice(token);
            return std.mem.eql(u8, token_slice, "null");
        }

        pub fn isNonNullLiteral(self: *_Engine, node: u32) bool {
            const src = self.source orelse return false;
            const tree = src.ast() catch return false;
            const tags = tree.nodes.items(.tag);
            const datas = tree.nodes.items(.data);
            const token_tags = tree.tokens.items(.tag);

            if (node >= tags.len) return false;

            return switch (tags[node]) {
                .number_literal,
                .char_literal,
                .string_literal,
                .multiline_string_literal,
                .enum_literal,
                .error_value,
                => true,
                .unwrap_optional,
                .grouped_expression,
                => blk: {
                    const data = datas[node].node_and_token;
                    break :blk isNonNullLiteral(self, @intFromEnum(data[0]));
                },
                .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => blk: {
                    const builtin_name = builtinCallName(tree, tags, token_tags, node) orelse break :blk false;
                    if (!std.mem.eql(u8, builtin_name, "@as")) break :blk false;
                    var buf: [2]std.zig.Ast.Node.Index = undefined;
                    const params = tree.builtinCallParams(&buf, @enumFromInt(node)) orelse break :blk false;
                    if (params.len < 2) break :blk false;
                    break :blk isNonNullLiteral(self, @intFromEnum(params[1]));
                },
                else => false,
            };
        }

        pub fn builtinCallName(
            tree: *const std.zig.Ast,
            tags: []const std.zig.Ast.Node.Tag,
            token_tags: []const std.zig.Token.Tag,
            node_idx: u32,
        ) ?[]const u8 {
            switch (tags[node_idx]) {
                .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {},
                else => return null,
            }

            const builtin_token = tree.nodes.items(.main_token)[node_idx];
            if (builtin_token >= token_tags.len) return null;
            if (token_tags[builtin_token] != .builtin) return null;
            return tree.tokenSlice(builtin_token);
        }
    };
}
