const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const ast_walk = @import("../ast_walk.zig");

/// Rule that detects variable shadowing.
///
/// This rule warns when a variable in an inner scope has the same name as a
/// variable in an outer scope, which can lead to subtle bugs where the
/// programmer thinks they're using one variable but actually using another.
///
/// Examples of detected issues:
/// - Function parameter shadowed by local variable
/// - Outer scope variable shadowed by inner block variable
/// - For/while loop variable shadowed by inner declaration
pub const ShadowedVariableRule = struct {
    pub const rule: Rule = .{
        .name = "shadowed-variable",
        .default_severity = .warning,
        .checkFn = check,
    };

    const NameInfo = struct {
        name: []const u8,
        byte_offset: usize,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();

        var scanner = ShadowScanner{
            .src = src,
            .tree = tree,
            .allocator = allocator,
            .diagnostics = diagnostics,
            .scope_stack = .empty,
        };
        defer scanner.deinit();

        try scanner.scanRoot();
    }

    const ShadowScanner = struct {
        src: *Source,
        tree: *const std.zig.Ast,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        scope_stack: std.ArrayListUnmanaged(std.ArrayListUnmanaged(NameInfo)),

        fn deinit(self: *ShadowScanner) void {
            for (self.scope_stack.items) |*scope| {
                scope.deinit(self.allocator);
            }
            self.scope_stack.deinit(self.allocator);
        }

        fn pushScope(self: *ShadowScanner) RuleError!void {
            try self.scope_stack.append(self.allocator, .empty);
        }

        fn popScope(self: *ShadowScanner) void {
            if (self.scope_stack.items.len > 0) {
                var scope = self.scope_stack.pop() orelse return;
                scope.deinit(self.allocator);
            }
        }

        fn addName(self: *ShadowScanner, name: []const u8, byte_offset: usize) RuleError!void {
            if (self.scope_stack.items.len == 0) return;
            const current_scope = &self.scope_stack.items[self.scope_stack.items.len - 1];
            try current_scope.append(self.allocator, .{ .name = name, .byte_offset = byte_offset });
        }

        fn isNameInOuterScope(self: *ShadowScanner, name: []const u8) ?NameInfo {
            if (self.scope_stack.items.len <= 1) return null;
            // Check all scopes except the current one
            for (self.scope_stack.items[0 .. self.scope_stack.items.len - 1]) |scope| {
                for (scope.items) |info| {
                    if (std.mem.eql(u8, info.name, name)) {
                        return info;
                    }
                }
            }
            return null;
        }

        fn reportShadow(self: *ShadowScanner, name: []const u8, byte_offset: usize) RuleError!void {
            const loc = try self.src.byteToLocation(byte_offset);
            const message = try std.fmt.allocPrint(
                self.allocator,
                "Variable '{s}' shadows a variable from an outer scope",
                .{name},
            );
            defer self.allocator.free(message);

            const diag = try Diagnostic.initAtLocation(
                self.allocator,
                self.src.getFilePath(),
                rule.name,
                .warning,
                message,
                loc.line,
                loc.column,
            );
            try self.diagnostics.append(self.allocator, diag);
        }

        fn checkAndAddName(self: *ShadowScanner, name: []const u8, byte_offset: usize) RuleError!void {
            // Skip special names (underscore prefix)
            if (name.len > 0 and name[0] == '_') return;

            if (self.isNameInOuterScope(name)) |_| {
                try self.reportShadow(name, byte_offset);
            }
            try self.addName(name, byte_offset);
        }

        fn scanRoot(self: *ShadowScanner) RuleError!void {
            try self.pushScope();
            defer self.popScope();

            const root_decls = self.tree.rootDecls();
            for (root_decls) |decl_idx| {
                try self.scanNode(@intFromEnum(decl_idx));
            }
        }

        fn scanNode(self: *ShadowScanner, node: u32) RuleError!void {
            if (node == 0) return;

            const tags = self.tree.nodes.items(.tag);
            if (node >= tags.len) return;

            const tag = tags[node];

            switch (tag) {
                .fn_decl => try self.scanFnDecl(node),
                .fn_proto,
                .fn_proto_simple,
                .fn_proto_one,
                .fn_proto_multi,
                => try self.scanFnProto(node, false),
                .simple_var_decl,
                .aligned_var_decl,
                .local_var_decl,
                .global_var_decl,
                => try self.scanVarDecl(node),
                .block,
                .block_semicolon,
                .block_two,
                .block_two_semicolon,
                => try self.scanBlock(node),
                .@"if",
                .if_simple,
                => try self.scanIf(node),
                .@"while",
                .while_simple,
                .while_cont,
                => try self.scanWhile(node),
                .@"for",
                .for_simple,
                => try self.scanFor(node),
                .@"switch",
                .switch_comma,
                => try self.scanSwitch(node),
                .@"catch" => try self.scanCatch(node),
                .@"errdefer" => try self.scanErrdefer(node),
                .container_decl,
                .container_decl_trailing,
                .container_decl_two,
                .container_decl_two_trailing,
                .container_decl_arg,
                .container_decl_arg_trailing,
                .tagged_union,
                .tagged_union_trailing,
                .tagged_union_enum_tag,
                .tagged_union_enum_tag_trailing,
                .tagged_union_two,
                .tagged_union_two_trailing,
                => try self.scanContainer(node),
                else => try self.scanChildren(node),
            }
        }

        fn scanChildren(self: *ShadowScanner, node: u32) RuleError!void {
            const child = struct {
                fn visit(_: *const std.zig.Ast, child_node: u32, scanner: *ShadowScanner) RuleError!void {
                    try scanner.scanNode(child_node);
                }
            };

            try ast_walk.walkChildren(ShadowScanner, self.tree, node, self, child.visit);
        }

        fn scanFnDecl(self: *ShadowScanner, node: u32) RuleError!void {
            const data = self.tree.nodes.items(.data)[node];
            const proto_node = @intFromEnum(data.node_and_node[0]);
            const body_node = @intFromEnum(data.node_and_node[1]);

            // Scan the prototype (creates a new scope for parameters)
            try self.scanFnProto(proto_node, true);

            // Scan the body (in its own nested scope)
            if (body_node != 0) {
                try self.scanNode(body_node);
            }

            // Pop the function parameter scope
            self.popScope();
        }

        fn scanFnProto(self: *ShadowScanner, node: u32, create_scope: bool) RuleError!void {
            const tags = self.tree.nodes.items(.tag);
            const tag = tags[node];
            var buffer: [1]std.zig.Ast.Node.Index = undefined;

            const proto = switch (tag) {
                .fn_proto => self.tree.fnProto(@enumFromInt(node)),
                .fn_proto_simple => self.tree.fnProtoSimple(&buffer, @enumFromInt(node)),
                .fn_proto_one => self.tree.fnProtoOne(&buffer, @enumFromInt(node)),
                .fn_proto_multi => self.tree.fnProtoMulti(@enumFromInt(node)),
                else => return,
            };

            // Only process parameters for actual function declarations, not function type expressions
            if (!create_scope) return;

            try self.pushScope();

            const token_starts = self.tree.tokens.items(.start);
            var it = proto.iterate(self.tree);
            while (it.next()) |param| {
                if (param.name_token) |name_tok| {
                    const name = self.tree.tokenSlice(name_tok);
                    const byte_offset = token_starts[name_tok];
                    try self.checkAndAddName(name, byte_offset);
                }
            }
        }

        fn scanVarDecl(self: *ShadowScanner, node: u32) RuleError!void {
            const full = self.tree.fullVarDecl(@enumFromInt(node)) orelse return;
            const token_tags = self.tree.tokens.items(.tag);
            const token_starts = self.tree.tokens.items(.start);

            // Scan the init expression first
            if (full.ast.init_node.unwrap()) |init_node| {
                try self.scanNode(@intFromEnum(init_node));
            }

            // Get the variable name
            const name_token = full.ast.mut_token + 1;
            if (name_token >= token_tags.len) return;
            if (token_tags[name_token] != .identifier) return;

            const name = self.tree.tokenSlice(name_token);
            const byte_offset = token_starts[name_token];

            // Check for shadowing and add to scope
            try self.checkAndAddName(name, byte_offset);
        }

        fn scanBlock(self: *ShadowScanner, node: u32) RuleError!void {
            const tags = self.tree.nodes.items(.tag);
            const data = self.tree.nodes.items(.data);

            var statements: []const u32 = &.{};
            var scratch_buf: [2]u32 = undefined;

            switch (tags[node]) {
                .block, .block_semicolon => {
                    const extra_range = data[node].extra_range;
                    const start = @intFromEnum(extra_range.start);
                    const end = @intFromEnum(extra_range.end);
                    statements = self.tree.extra_data[start..end];
                },
                .block_two, .block_two_semicolon => {
                    const opt_nodes = data[node].opt_node_and_opt_node;
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
                else => return,
            }

            try self.pushScope();
            defer self.popScope();

            for (statements) |stmt| {
                try self.scanNode(stmt);
            }
        }

        fn scanIf(self: *ShadowScanner, node: u32) RuleError!void {
            const full_if = self.tree.fullIf(@enumFromInt(node)) orelse return;

            // Scan condition
            try self.scanNode(@intFromEnum(full_if.ast.cond_expr));

            // Scan then branch with payload
            try self.pushScope();
            if (full_if.payload_token) |tok| {
                try self.addPayloadName(tok);
            }
            try self.scanNode(@intFromEnum(full_if.ast.then_expr));
            self.popScope();

            // Scan else branch with error payload
            if (full_if.ast.else_expr.unwrap()) |else_node| {
                try self.pushScope();
                if (full_if.error_token) |tok| {
                    try self.addPayloadName(tok);
                }
                try self.scanNode(@intFromEnum(else_node));
                self.popScope();
            }
        }

        fn scanWhile(self: *ShadowScanner, node: u32) RuleError!void {
            const tags = self.tree.nodes.items(.tag);
            const full_while = switch (tags[node]) {
                .while_simple => self.tree.whileSimple(@enumFromInt(node)),
                .while_cont => self.tree.whileCont(@enumFromInt(node)),
                .@"while" => self.tree.whileFull(@enumFromInt(node)),
                else => return,
            };

            // Scan condition
            try self.scanNode(@intFromEnum(full_while.ast.cond_expr));

            // Scan body with payload
            try self.pushScope();
            if (full_while.payload_token) |tok| {
                try self.addPayloadName(tok);
            }
            try self.scanNode(@intFromEnum(full_while.ast.then_expr));
            self.popScope();

            // Scan else branch
            if (full_while.ast.else_expr.unwrap()) |else_node| {
                try self.pushScope();
                if (full_while.error_token) |tok| {
                    try self.addPayloadName(tok);
                }
                try self.scanNode(@intFromEnum(else_node));
                self.popScope();
            }
        }

        fn scanFor(self: *ShadowScanner, node: u32) RuleError!void {
            const tags = self.tree.nodes.items(.tag);
            const full_for = switch (tags[node]) {
                .@"for" => self.tree.forFull(@enumFromInt(node)),
                .for_simple => self.tree.forSimple(@enumFromInt(node)),
                else => return,
            };

            // Scan inputs
            for (full_for.ast.inputs) |input| {
                try self.scanNode(@intFromEnum(input));
            }

            // Scan body with payloads
            try self.pushScope();
            try self.addForPayloads(full_for.payload_token);
            try self.scanNode(@intFromEnum(full_for.ast.then_expr));
            self.popScope();

            // Scan else branch
            if (full_for.ast.else_expr.unwrap()) |else_node| {
                try self.scanNode(@intFromEnum(else_node));
            }
        }

        fn scanSwitch(self: *ShadowScanner, node: u32) RuleError!void {
            const full_switch = self.tree.switchFull(@enumFromInt(node));

            // Scan condition
            try self.scanNode(@intFromEnum(full_switch.ast.condition));

            // Scan cases
            for (full_switch.ast.cases) |case_node| {
                try self.scanSwitchCase(@intFromEnum(case_node));
            }
        }

        fn scanSwitchCase(self: *ShadowScanner, node: u32) RuleError!void {
            const full_case = self.tree.fullSwitchCase(@enumFromInt(node)) orelse return;

            // Scan case values
            for (full_case.ast.values) |value| {
                try self.scanNode(@intFromEnum(value));
            }

            // Scan target with payload
            try self.pushScope();
            if (full_case.payload_token) |tok| {
                try self.addPayloadName(tok);
            }
            try self.scanNode(@intFromEnum(full_case.ast.target_expr));
            self.popScope();
        }

        fn scanCatch(self: *ShadowScanner, node: u32) RuleError!void {
            const data = self.tree.nodes.items(.data)[node].node_and_node;
            const main_tokens = self.tree.nodes.items(.main_token);
            const token_tags = self.tree.tokens.items(.tag);

            // Scan LHS
            try self.scanNode(@intFromEnum(data[0]));

            // Find payload token
            var payload_token: ?u32 = null;
            const catch_token = main_tokens[node];
            if (catch_token + 2 < token_tags.len and token_tags[catch_token + 1] == .pipe) {
                payload_token = catch_token + 2;
            }

            // Scan RHS with payload
            try self.pushScope();
            if (payload_token) |tok| {
                try self.addPayloadName(tok);
            }
            try self.scanNode(@intFromEnum(data[1]));
            self.popScope();
        }

        fn scanErrdefer(self: *ShadowScanner, node: u32) RuleError!void {
            const data = self.tree.nodes.items(.data)[node].opt_token_and_node;
            const payload_token = data[0].unwrap();
            const expr_node = data[1];

            try self.pushScope();
            if (payload_token) |tok| {
                try self.addPayloadName(tok);
            }
            try self.scanNode(@intFromEnum(expr_node));
            self.popScope();
        }

        fn scanContainer(self: *ShadowScanner, node: u32) RuleError!void {
            const tags = self.tree.nodes.items(.tag);
            var buf: [2]std.zig.Ast.Node.Index = undefined;

            const members: []const std.zig.Ast.Node.Index = switch (tags[node]) {
                .container_decl, .container_decl_trailing => self.tree.containerDecl(@enumFromInt(node)).ast.members,
                .container_decl_two, .container_decl_two_trailing => self.tree.containerDeclTwo(&buf, @enumFromInt(node)).ast.members,
                .container_decl_arg, .container_decl_arg_trailing => self.tree.containerDeclArg(@enumFromInt(node)).ast.members,
                .tagged_union, .tagged_union_trailing => self.tree.taggedUnion(@enumFromInt(node)).ast.members,
                .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => self.tree.taggedUnionEnumTag(@enumFromInt(node)).ast.members,
                .tagged_union_two, .tagged_union_two_trailing => self.tree.taggedUnionTwo(&buf, @enumFromInt(node)).ast.members,
                else => return,
            };

            // Containers have their own isolated scope - save and replace the scope stack
            const saved_stack = self.scope_stack;
            self.scope_stack = .empty;
            defer {
                for (self.scope_stack.items) |*scope| {
                    scope.deinit(self.allocator);
                }
                self.scope_stack.deinit(self.allocator);
                self.scope_stack = saved_stack;
            }

            try self.pushScope();
            defer self.popScope();

            for (members) |member| {
                try self.scanNode(@intFromEnum(member));
            }
        }

        fn addPayloadName(self: *ShadowScanner, token: u32) RuleError!void {
            const token_tags = self.tree.tokens.items(.tag);
            const token_starts = self.tree.tokens.items(.start);

            if (token >= token_tags.len) return;

            var tok = token;
            // Skip pipe if present
            if (token_tags[tok] == .pipe) tok += 1;
            // Skip asterisk if present (for pointer payloads)
            if (tok < token_tags.len and token_tags[tok] == .asterisk) tok += 1;

            if (tok < token_tags.len and token_tags[tok] == .identifier) {
                const name = self.tree.tokenSlice(tok);
                const byte_offset = token_starts[tok];
                try self.checkAndAddName(name, byte_offset);
            }
        }

        fn addForPayloads(self: *ShadowScanner, token: u32) RuleError!void {
            const token_tags = self.tree.tokens.items(.tag);
            const token_starts = self.tree.tokens.items(.start);

            var idx = token;
            // Skip opening pipe
            if (idx < token_tags.len and token_tags[idx] == .pipe) {
                idx += 1;
            }

            while (idx < token_tags.len) : (idx += 1) {
                const tag = token_tags[idx];
                if (tag == .pipe) break; // Closing pipe
                if (tag == .asterisk) {
                    idx += 1;
                    if (idx < token_tags.len and token_tags[idx] == .identifier) {
                        const name = self.tree.tokenSlice(idx);
                        const byte_offset = token_starts[idx];
                        try self.checkAndAddName(name, byte_offset);
                    }
                } else if (tag == .identifier) {
                    const name = self.tree.tokenSlice(idx);
                    const byte_offset = token_starts[idx];
                    try self.checkAndAddName(name, byte_offset);
                }
            }
        }
    };
};

test "shadowed variable: parameter shadowed by local" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn foo(x: i32) void {
        \\    const x = 5;
        \\    _ = x;
        \\}
    ;

    var src = try Source.initText(allocator, source_text);
    defer src.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try ShadowedVariableRule.rule.checkFn(&src, allocator, &diagnostics);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("shadowed-variable", diagnostics.items[0].rule_name);
}

test "shadowed variable: outer block shadowed by inner block" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn foo() void {
        \\    const x = 5;
        \\    {
        \\        const x = 10;
        \\        _ = x;
        \\    }
        \\    _ = x;
        \\}
    ;

    var src = try Source.initText(allocator, source_text);
    defer src.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try ShadowedVariableRule.rule.checkFn(&src, allocator, &diagnostics);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "shadowed variable: no shadow for underscore prefix" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn foo(_x: i32) void {
        \\    const _x = 5;
        \\    _ = _x;
        \\}
    ;

    var src = try Source.initText(allocator, source_text);
    defer src.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try ShadowedVariableRule.rule.checkFn(&src, allocator, &diagnostics);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "shadowed variable: no shadow for different names" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn foo(x: i32) void {
        \\    const y = 5;
        \\    _ = x;
        \\    _ = y;
        \\}
    ;

    var src = try Source.initText(allocator, source_text);
    defer src.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try ShadowedVariableRule.rule.checkFn(&src, allocator, &diagnostics);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}

test "shadowed variable: for loop payload shadowed" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn foo() void {
        \\    const items = [_]i32{1, 2, 3};
        \\    for (items) |item| {
        \\        const item = 0;
        \\        _ = item;
        \\    }
        \\}
    ;

    var src = try Source.initText(allocator, source_text);
    defer src.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try ShadowedVariableRule.rule.checkFn(&src, allocator, &diagnostics);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "shadowed variable: if payload shadowed" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn foo(opt: ?i32) void {
        \\    if (opt) |value| {
        \\        const value = 0;
        \\        _ = value;
        \\    }
        \\}
    ;

    var src = try Source.initText(allocator, source_text);
    defer src.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try ShadowedVariableRule.rule.checkFn(&src, allocator, &diagnostics);

    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
}

test "shadowed variable: nested containers don't leak scope" {
    const allocator = std.testing.allocator;

    const source_text =
        \\const Outer = struct {
        \\    const x = 1;
        \\    const Inner = struct {
        \\        const x = 2;
        \\    };
        \\};
    ;

    var src = try Source.initText(allocator, source_text);
    defer src.deinit(allocator);

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |diag| {
            diag.deinit(allocator);
        }
        diagnostics.deinit(allocator);
    }

    try ShadowedVariableRule.rule.checkFn(&src, allocator, &diagnostics);

    // Container scopes are isolated, so this should not be a shadow
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);
}
