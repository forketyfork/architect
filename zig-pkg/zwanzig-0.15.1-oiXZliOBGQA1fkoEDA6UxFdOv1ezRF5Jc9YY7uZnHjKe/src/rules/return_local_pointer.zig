const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const ast_walk = @import("../ast_walk.zig");
const call_utils = @import("../analysis/call_utils.zig");

const Ast = std.zig.Ast;

/// Rule that detects returning pointers or slices derived from local stack variables.
///
/// This catches use-after-return bugs where a function returns a slice or pointer
/// that points to a local buffer which goes out of scope when the function returns.
///
/// Example of buggy code:
/// ```zig
/// fn getMembers() []const Node.Index {
///     var buf: [2]Node.Index = undefined;  // local buffer
///     return tree.containerDeclTwo(&buf, node).ast.members;  // returns slice pointing to buf
/// }
/// ```
pub const ReturnLocalPointerRule = struct {
    pub const rule: Rule = .{
        .name = "return-local-ptr",
        .default_severity = .warning,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        for (tags, 0..) |tag, i| {
            if (tag != .fn_decl) continue;

            const fn_node: u32 = @intCast(i);
            const data = datas[fn_node].node_and_node;
            const body_node = @intFromEnum(data[1]);
            if (body_node == 0 or body_node >= tags.len) continue;

            try checkFunction(
                src,
                allocator,
                diagnostics,
                tree,
                tags,
                datas,
                token_tags,
                main_tokens,
                fn_node,
                body_node,
            );
        }
    }

    fn checkFunction(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        main_tokens: []const Ast.TokenIndex,
        fn_node: u32,
        body_node: u32,
    ) RuleError!void {
        if (!returnTypeIsPointerLike(tree, tags, datas, fn_node)) return;

        // Collect local array variables in the function body
        var local_arrays: std.ArrayList(LocalArrayInfo) = .empty;
        defer local_arrays.deinit(allocator);

        try collectLocalArrays(allocator, tree, tags, token_tags, body_node, &local_arrays);
        if (local_arrays.items.len == 0) return;

        var local_inits: std.ArrayList(LocalValueInfo) = .empty;
        defer local_inits.deinit(allocator);

        try collectLocalInits(allocator, tree, tags, token_tags, body_node, &local_inits);

        // Collect all return statements in the function body
        var return_nodes: std.ArrayList(u32) = .empty;
        defer return_nodes.deinit(allocator);

        try collectNodesByTagSkippingNestedFns(allocator, tree, body_node, .@"return", &return_nodes);

        // For each return statement, check if it returns something derived from a local array
        for (return_nodes.items) |ret_node| {
            const ret_expr = datas[ret_node].opt_node.unwrap() orelse continue;
            const ret_expr_idx = @intFromEnum(ret_expr);

            for (local_arrays.items) |local_info| {
                if (try checkReturnDerivedFromLocal(
                    tree,
                    tags,
                    datas,
                    main_tokens,
                    ret_expr_idx,
                    local_info.name,
                    local_inits.items,
                    0,
                )) {
                    const loc = try src.tokenLocation(main_tokens[ret_node]);
                    const message = try std.fmt.allocPrint(
                        allocator,
                        "returning slice/pointer derived from local variable '{s}' - the local goes out of scope",
                        .{local_info.name},
                    );
                    defer allocator.free(message);

                    const diag = try Diagnostic.initAtLocation(
                        allocator,
                        src.getFilePath(),
                        rule.name,
                        .warning,
                        message,
                        loc.line,
                        loc.column,
                    );
                    try diagnostics.append(allocator, diag);
                    break;
                }
            }
        }
    }

    const LocalArrayInfo = struct {
        node: u32,
        name: []const u8,
    };

    const LocalValueInfo = struct {
        name: []const u8,
        init_node: u32,
    };

    fn walkNoNestedFns(
        comptime Visitor: type,
        tree: *const Ast,
        node: u32,
        visitor: *Visitor,
    ) RuleError!void {
        if (node == 0) return;
        const tags = tree.nodes.items(.tag);
        if (node >= tags.len) return;
        if (@hasField(Visitor, "stop") and visitor.stop) return;

        const tag = tags[node];
        if (tag == .fn_decl or tag == .test_decl) return;

        try visitor.visit(tree, node, tag);
        if (@hasField(Visitor, "stop") and visitor.stop) return;

        const child = struct {
            fn visitChild(inner_tree: *const Ast, child_node: u32, inner_visitor: *Visitor) RuleError!void {
                return walkNoNestedFns(Visitor, inner_tree, child_node, inner_visitor);
            }
        };

        try ast_walk.walkChildren(Visitor, tree, node, visitor, child.visitChild);
    }

    fn collectNodesByTagSkippingNestedFns(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        root: u32,
        target_tag: Ast.Node.Tag,
        out: *std.ArrayList(u32),
    ) RuleError!void {
        const Collector = struct {
            allocator: std.mem.Allocator,
            target_tag: Ast.Node.Tag,
            out: *std.ArrayList(u32),
            stop: bool = false,

            pub fn visit(self: *@This(), _: *const Ast, node: u32, tag: Ast.Node.Tag) RuleError!void {
                if (tag == self.target_tag) {
                    try self.out.append(self.allocator, node);
                }
            }
        };

        var collector = Collector{
            .allocator = allocator,
            .target_tag = target_tag,
            .out = out,
        };

        try walkNoNestedFns(Collector, tree, root, &collector);
    }

    fn returnTypeIsPointerLike(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        fn_node: u32,
    ) bool {
        if (fn_node >= tags.len or tags[fn_node] != .fn_decl) return false;
        var buf: [1]Ast.Node.Index = undefined;
        const fn_proto = tree.fullFnProto(&buf, @enumFromInt(fn_node)) orelse return false;
        const ret_type_node = @intFromEnum(fn_proto.ast.return_type);
        return typeNodeIsPointerLike(tags, datas, ret_type_node);
    }

    fn typeNodeIsPointerLike(
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        type_node: u32,
    ) bool {
        if (type_node >= tags.len) return false;
        return switch (tags[type_node]) {
            .error_union => {
                const pair = datas[type_node].node_and_node;
                return typeNodeIsPointerLike(tags, datas, @intFromEnum(pair[1]));
            },
            .optional_type => {
                const child = datas[type_node].node;
                return typeNodeIsPointerLike(tags, datas, @intFromEnum(child));
            },
            .ptr_type_sentinel, .ptr_type, .ptr_type_aligned, .ptr_type_bit_range => true,
            .slice, .slice_open, .slice_sentinel => true,
            else => false,
        };
    }

    fn collectLocalArrays(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        body_node: u32,
        out: *std.ArrayList(LocalArrayInfo),
    ) RuleError!void {
        // Get all variable declarations in the function body
        var var_decls: std.ArrayList(u32) = .empty;
        defer var_decls.deinit(allocator);

        try collectNodesByTagSkippingNestedFns(allocator, tree, body_node, .local_var_decl, &var_decls);
        try collectNodesByTagSkippingNestedFns(allocator, tree, body_node, .simple_var_decl, &var_decls);

        for (var_decls.items) |var_node| {
            const full = tree.fullVarDecl(@enumFromInt(var_node)) orelse continue;

            // Check if it's a 'var' (mutable) declaration - immutable consts are less likely to be buffers
            const mut_token = full.ast.mut_token;
            if (mut_token >= token_tags.len) continue;
            if (token_tags[mut_token] != .keyword_var) continue;

            // Get the variable name
            const name_token = mut_token + 1;
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
            const name = tree.tokenSlice(name_token);

            var is_array = false;
            // Check if it has an array type annotation
            if (full.ast.type_node.unwrap()) |type_node| {
                const type_idx = @intFromEnum(type_node);
                if (type_idx < tags.len and isArrayType(tags[type_idx])) {
                    is_array = true;
                }
            } else if (full.ast.init_node.unwrap()) |init_node| {
                if (isArrayInitType(tree, tags, init_node)) {
                    is_array = true;
                }
            }

            if (is_array) {
                try out.append(allocator, .{ .node = var_node, .name = name });
            }
        }
    }

    fn collectLocalInits(
        allocator: std.mem.Allocator,
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        body_node: u32,
        out: *std.ArrayList(LocalValueInfo),
    ) RuleError!void {
        var var_decls: std.ArrayList(u32) = .empty;
        defer var_decls.deinit(allocator);

        try collectNodesByTagSkippingNestedFns(allocator, tree, body_node, .local_var_decl, &var_decls);
        try collectNodesByTagSkippingNestedFns(allocator, tree, body_node, .simple_var_decl, &var_decls);
        try collectNodesByTagSkippingNestedFns(allocator, tree, body_node, .aligned_var_decl, &var_decls);

        for (var_decls.items) |var_node| {
            const full = tree.fullVarDecl(@enumFromInt(var_node)) orelse continue;
            const name_token = full.ast.mut_token + 1;
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
            const init = full.ast.init_node.unwrap() orelse continue;
            const init_idx = @intFromEnum(init);
            if (init_idx == 0 or init_idx >= tags.len) continue;

            const name = tree.tokenSlice(name_token);
            try out.append(allocator, .{ .name = name, .init_node = init_idx });
        }
    }

    fn isArrayType(tag: Ast.Node.Tag) bool {
        return tag == .array_type or tag == .array_type_sentinel;
    }

    fn isArrayInitType(tree: *const Ast, tags: []const Ast.Node.Tag, init_node: Ast.Node.Index) bool {
        const init_idx = @intFromEnum(init_node);
        if (init_idx >= tags.len) return false;
        return switch (tags[init_idx]) {
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            => {
                var buf: [2]Ast.Node.Index = undefined;
                const array_init = tree.fullArrayInit(&buf, @enumFromInt(init_idx)) orelse return false;
                if (array_init.ast.type_expr.unwrap()) |type_node| {
                    const type_idx = @intFromEnum(type_node);
                    return type_idx < tags.len and isArrayType(tags[type_idx]);
                }
                return false;
            },
            else => false,
        };
    }

    /// Check if a return expression is derived from a local variable.
    /// Returns true if the return expression involves taking the address of the local
    /// and passing it to a function whose result (or a field of it) is returned.
    fn checkReturnDerivedFromLocal(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        ret_expr: u32,
        local_name: []const u8,
        local_inits: []const LocalValueInfo,
        depth: u8,
    ) RuleError!bool {
        if (ret_expr >= tags.len) return false;
        if (depth > 4) return false;

        const tag = tags[ret_expr];

        // Pattern 1: return local
        if (tag == .identifier) {
            if (isIdentifierLocal(tree, tags, main_tokens, ret_expr, local_name)) {
                return true;
            }
            const token = main_tokens[ret_expr];
            const name = tree.tokenSlice(token);
            if (resolveLocalInit(local_inits, name)) |init_node| {
                if (init_node == ret_expr) return false;
                return checkReturnDerivedFromLocal(
                    tree,
                    tags,
                    datas,
                    main_tokens,
                    init_node,
                    local_name,
                    local_inits,
                    depth + 1,
                );
            }
            return false;
        }

        // Pattern 2: return &local
        if (tag == .address_of) {
            const operand = @intFromEnum(datas[ret_expr].node);
            if (isIdentifierLocal(tree, tags, main_tokens, operand, local_name)) {
                return true;
            }
            if (operand < tags.len and tags[operand] == .array_access) {
                const base = @intFromEnum(datas[operand].node_and_node[0]);
                return isIdentifierLocal(tree, tags, main_tokens, base, local_name);
            }
            return false;
        }

        // Pattern 3: return local[0..] or return func(&local)[0..]
        if (tag == .slice or tag == .slice_open or tag == .slice_sentinel) {
            const slice = tree.fullSlice(@enumFromInt(ret_expr)) orelse return false;
            const sliced = @intFromEnum(slice.ast.sliced);
            return checkReturnDerivedFromLocal(tree, tags, datas, main_tokens, sliced, local_name, local_inits, depth + 1);
        }

        // Pattern 4: return func(&local).field
        // Pattern 5: return func(&local).field.subfield (chain of field accesses)
        if (tag == .field_access) {
            const base = @intFromEnum(datas[ret_expr].node_and_token[0]);
            return checkReturnDerivedFromLocal(tree, tags, datas, main_tokens, base, local_name, local_inits, depth + 1);
        }

        // Pattern 6: return func(&local)
        if (call_utils.isCallNode(tag)) {
            return checkCallTakesAddressOfLocal(tree, tags, datas, main_tokens, ret_expr, local_name);
        }

        // Pattern 7: return switch (...) { ... => func(&local).field, ... }
        if (tag == .@"switch" or tag == .switch_comma) {
            return checkSwitchReturnsLocalPointer(tree, tags, datas, main_tokens, ret_expr, local_name, local_inits, depth + 1);
        }

        // Pattern 8: return if (...) expr else expr
        if (tag == .@"if" or tag == .if_simple) {
            return checkIfReturnsLocalPointer(tree, tags, datas, main_tokens, ret_expr, local_name, local_inits, depth + 1);
        }

        return false;
    }

    fn isIdentifierLocal(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        main_tokens: []const Ast.TokenIndex,
        node: u32,
        local_name: []const u8,
    ) bool {
        if (node >= tags.len or tags[node] != .identifier) return false;
        const token = main_tokens[node];
        const name = tree.tokenSlice(token);
        return std.mem.eql(u8, name, local_name);
    }

    fn checkCallTakesAddressOfLocal(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        call_node: u32,
        local_name: []const u8,
    ) RuleError!bool {
        var buf: [1]Ast.Node.Index = undefined;
        const full = tree.fullCall(&buf, @enumFromInt(call_node)) orelse return false;

        for (full.ast.params) |param| {
            const param_idx = @intFromEnum(param);
            if (param_idx >= tags.len) continue;
            if (exprContainsAddressOfLocal(tree, tags, datas, main_tokens, param_idx, local_name)) {
                return true;
            }
        }

        return false;
    }

    fn exprContainsAddressOfLocal(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        expr_node: u32,
        local_name: []const u8,
    ) bool {
        const Finder = struct {
            local_name: []const u8,
            main_tokens: []const Ast.TokenIndex,
            tags: []const Ast.Node.Tag,
            datas: []const Ast.Node.Data,
            found: bool = false,
            stop: bool = false,

            pub fn visit(self: *@This(), ast: *const Ast, node: u32, tag: Ast.Node.Tag) RuleError!void {
                if (tag != .address_of) return;
                const operand = @intFromEnum(self.datas[node].node);
                if (operand >= self.tags.len or self.tags[operand] != .identifier) return;
                const token = self.main_tokens[operand];
                const name = ast.tokenSlice(token);
                if (std.mem.eql(u8, name, self.local_name)) {
                    self.found = true;
                    self.stop = true;
                }
            }
        };

        var finder = Finder{
            .local_name = local_name,
            .main_tokens = main_tokens,
            .tags = tags,
            .datas = datas,
        };

        ast_walk.walk(Finder, tree, expr_node, &finder) catch return false;
        return finder.found;
    }

    fn checkSwitchReturnsLocalPointer(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        switch_node: u32,
        local_name: []const u8,
        local_inits: []const LocalValueInfo,
        depth: u8,
    ) RuleError!bool {
        const full = tree.switchFull(@enumFromInt(switch_node));

        for (full.ast.cases) |case_node| {
            const case_idx = @intFromEnum(case_node);
            const case = tree.fullSwitchCase(@enumFromInt(case_idx)) orelse continue;
            const target_expr = @intFromEnum(case.ast.target_expr);

            if (try checkReturnDerivedFromLocal(
                tree,
                tags,
                datas,
                main_tokens,
                target_expr,
                local_name,
                local_inits,
                depth + 1,
            )) {
                return true;
            }
        }

        return false;
    }

    fn checkIfReturnsLocalPointer(
        tree: *const Ast,
        tags: []const Ast.Node.Tag,
        datas: []const Ast.Node.Data,
        main_tokens: []const Ast.TokenIndex,
        if_node: u32,
        local_name: []const u8,
        local_inits: []const LocalValueInfo,
        depth: u8,
    ) RuleError!bool {
        const full = tree.fullIf(@enumFromInt(if_node)) orelse return false;
        const then_expr = @intFromEnum(full.ast.then_expr);
        if (try checkReturnDerivedFromLocal(
            tree,
            tags,
            datas,
            main_tokens,
            then_expr,
            local_name,
            local_inits,
            depth + 1,
        )) {
            return true;
        }
        if (full.ast.else_expr.unwrap()) |else_node| {
            const else_expr = @intFromEnum(else_node);
            if (try checkReturnDerivedFromLocal(
                tree,
                tags,
                datas,
                main_tokens,
                else_expr,
                local_name,
                local_inits,
                depth + 1,
            )) {
                return true;
            }
        }
        return false;
    }

    fn resolveLocalInit(local_inits: []const LocalValueInfo, name: []const u8) ?u32 {
        for (local_inits) |info| {
            if (std.mem.eql(u8, info.name, name)) return info.init_node;
        }
        return null;
    }
};

test "detects return of field access on call with local buffer" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn bad() []const u32 {
        \\    var buf: [2]u32 = undefined;
        \\    return getSlice(&buf).data;
        \\}
    ;

    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try ReturnLocalPointerRule.rule.check(&src, allocator, &diagnostics);

    try std.testing.expectEqual(1, diagnostics.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, diagnostics.items[0].message, 1, "buf"));
}

test "allows return of non-local-derived value" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn good(external_buf: *[2]u32) []const u32 {
        \\    return getSlice(external_buf).data;
        \\}
    ;

    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try ReturnLocalPointerRule.rule.check(&src, allocator, &diagnostics);

    try std.testing.expectEqual(0, diagnostics.items.len);
}

test "detects return via switch expression" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn bad(tag: u8) []const u32 {
        \\    var buf: [2]u32 = undefined;
        \\    return switch (tag) {
        \\        0 => getSlice(&buf).data,
        \\        else => &.{},
        \\    };
        \\}
    ;

    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try ReturnLocalPointerRule.rule.check(&src, allocator, &diagnostics);

    try std.testing.expectEqual(1, diagnostics.items.len);
}

test "detects return of address of local buffer" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn bad() *[2]u32 {
        \\    var buf: [2]u32 = undefined;
        \\    return &buf;
        \\}
    ;

    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try ReturnLocalPointerRule.rule.check(&src, allocator, &diagnostics);

    try std.testing.expectEqual(1, diagnostics.items.len);
}

test "detects return of slice derived from local buffer" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn bad() []const u32 {
        \\    var buf: [2]u32 = undefined;
        \\    return buf[0..];
        \\}
    ;

    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try ReturnLocalPointerRule.rule.check(&src, allocator, &diagnostics);

    try std.testing.expectEqual(1, diagnostics.items.len);
}

test "ignores non-pointer return type" {
    const allocator = std.testing.allocator;

    const source_text =
        \\fn count(items: *[2]u32) usize {
        \\    _ = items;
        \\    return 0;
        \\}
        \\
        \\fn good() usize {
        \\    var buf: [2]u32 = undefined;
        \\    return count(&buf);
        \\}
    ;

    var src = Source.initForTest("test.zig", source_text);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    defer for (diagnostics.items) |d| d.deinit(allocator);

    try ReturnLocalPointerRule.rule.check(&src, allocator, &diagnostics);

    try std.testing.expectEqual(0, diagnostics.items.len);
}
