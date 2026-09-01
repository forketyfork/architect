const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const zir_bridge_mod = @import("../zir_bridge.zig");

/// Rule that enforces Zig naming conventions:
/// - Type names (struct, enum, union, opaque, error set): PascalCase
/// - Function names: camelCase
/// - Variable/constant names: snake_case
/// - Parameter and payload names: snake_case
/// - SCREAMING_SNAKE_CASE is allowed only when aliasing external conventions
///
/// Names starting with underscore (_) are ignored as they indicate
/// intentionally ignored/internal identifiers.
pub const IdentifierStyleRule = struct {
    pub const rule: Rule = .{
        .name = "identifier-style",
        .default_severity = .warning,
        .checkFn = check,
    };

    const Style = enum {
        pascal_case,
        camel_case,
        snake_case,
    };

    /// Result of type-aware classification for a declaration.
    /// When ZIR-based type information is available, we can definitively
    /// classify the declaration. Otherwise, we fall back to heuristics.
    const DeclClassification = enum {
        type_decl, // Struct, enum, union, or type alias - should be PascalCase
        function_type, // Function type (fn() void) - should be PascalCase
        function, // Function declaration - should be camelCase
        constant, // Constant value - should be snake_case
        variable, // Variable - should be snake_case
        unknown, // Could not determine - fall back to heuristics
    };

    /// Classify a declaration using ZIR-based type information.
    /// Returns .unknown if type info is not available, allowing fallback to heuristics.
    fn classifyDeclWithTypeInfo(src: *Source, name: []const u8, node_idx: u32) DeclClassification {
        const decl = findDeclByAstNode(src, node_idx) orelse return .unknown;
        if (!std.mem.eql(u8, decl.name, name)) return .unknown;

        // Check if it's a function
        if (decl.is_fn) return .function;

        // Check type kind from ZIR
        switch (decl.type_info.kind) {
            .@"struct" => {
                if (isNamespaceStructDecl(src, decl)) return .unknown;
                return .type_decl;
            },
            .@"enum", .@"union", .type_type => return .type_decl,
            .function => return .function_type,
            .unknown => return .unknown,
            else => {},
        }

        // It's a value declaration
        if (decl.is_const) return .constant;
        return .variable;
    }

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const datas = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);

        for (tags, 0..) |tag, i| {
            switch (tag) {
                .fn_decl => {
                    const proto_node = @intFromEnum(datas[i].node_and_node[0]);
                    try checkFnProto(src, allocator, diagnostics, tree, proto_node, token_tags, token_starts);
                },
                // Note: standalone fn_proto nodes are function types (e.g., const Fn = fn() void)
                // not function declarations, so we don't check their naming here
                .simple_var_decl, .aligned_var_decl, .local_var_decl, .global_var_decl => {
                    try checkVarDecl(src, allocator, diagnostics, tree, @intCast(i), tags, datas, main_tokens, token_tags, token_starts);
                },
                .@"if", .if_simple => {
                    try checkIfPayloads(src, allocator, diagnostics, tree, @intCast(i), token_tags, token_starts);
                },
                .@"while", .while_simple, .while_cont => {
                    try checkWhilePayloads(src, allocator, diagnostics, tree, @intCast(i), token_tags, token_starts);
                },
                .@"for", .for_simple => {
                    try checkForPayloads(src, allocator, diagnostics, tree, @intCast(i), token_tags, token_starts);
                },
                .@"switch", .switch_comma => {
                    try checkSwitchPayloads(src, allocator, diagnostics, tree, @intCast(i), token_tags, token_starts);
                },
                .@"catch" => {
                    try checkCatchPayload(src, allocator, diagnostics, tree, @intCast(i), token_tags, token_starts);
                },
                .@"errdefer" => {
                    try checkErrdeferPayload(src, allocator, diagnostics, tree, @intCast(i), token_tags, token_starts);
                },
                else => {},
            }
        }
    }

    fn checkFnProto(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const tags = tree.nodes.items(.tag);
        const tag = tags[node_idx];

        const proto = switch (tag) {
            .fn_proto => tree.fnProto(@enumFromInt(node_idx)),
            .fn_proto_simple => tree.fnProtoSimple(&buffer, @enumFromInt(node_idx)),
            .fn_proto_one => tree.fnProtoOne(&buffer, @enumFromInt(node_idx)),
            .fn_proto_multi => tree.fnProtoMulti(@enumFromInt(node_idx)),
            else => return,
        };

        if (proto.name_token) |name_token| {
            if (token_tags[name_token] == .identifier) {
                const name = tree.tokenSlice(name_token);
                if (!shouldSkipName(name) and !isCamelCase(name)) {
                    const byte_offset = token_starts[name_token];
                    const loc = try src.byteToLocation(byte_offset);
                    const message = try std.fmt.allocPrint(
                        allocator,
                        "function '{s}' should use camelCase naming",
                        .{name},
                    );
                    defer allocator.free(message);

                    const diag = try Diagnostic.initAtLocation(
                        allocator,
                        src.getFilePath(),
                        "identifier-style",
                        .warning,
                        message,
                        loc.line,
                        loc.column,
                    );
                    try diagnostics.append(allocator, diag);
                }
            }
        }

        var it = proto.iterate(tree);
        while (it.next()) |param| {
            if (param.name_token) |tok| {
                try checkParamName(src, allocator, diagnostics, tree, token_tags, token_starts, tok, param);
            }
        }
    }

    fn checkVarDecl(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const std.zig.Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        const full = tree.fullVarDecl(@enumFromInt(node_idx)) orelse return;
        const name_token = full.ast.mut_token + 1;
        if (name_token >= token_tags.len) return;
        if (token_tags[name_token] != .identifier) return;

        const name = tree.tokenSlice(name_token);
        if (shouldSkipName(name)) return;

        const is_const = token_tags[full.ast.mut_token] == .keyword_const;
        const init_idx_opt = if (full.ast.init_node.unwrap()) |init_node|
            @intFromEnum(init_node)
        else
            null;

        // First, try to use ZIR-based type information for definitive classification.
        // This provides more accurate results than heuristics when available.
        const type_classification = classifyDeclWithTypeInfo(src, name, node_idx);
        switch (type_classification) {
            .type_decl => {
                // ZIR confirms this is a type - must be PascalCase
                if (!isPascalCase(name) and !isCTypeAliasName(name)) {
                    try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "type", .pascal_case);
                }
                return;
            },
            .function_type => {
                // ZIR confirms this is a function type alias - must be PascalCase
                if (!isPascalCase(name) and !isCTypeAliasName(name)) {
                    try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "function type", .pascal_case);
                }
                return;
            },
            .function => {
                // This shouldn't happen for var decls, but handle gracefully
                if (!isCamelCase(name)) {
                    try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "function", .camel_case);
                }
                return;
            },
            .constant => {
                // ZIR confirms this is a constant value (not a type)
                // Check for external convention aliasing
                const is_external_alias = isScreamingSnakeCase(name) and
                    (if (init_idx_opt) |init_idx|
                        isExternalConventionAlias(tree, tags, datas, token_tags, init_idx)
                    else
                        false);
                if (!isLowerSnakeCase(name) and !is_external_alias) {
                    // Allow function aliases to use camelCase
                    if (init_idx_opt) |init_idx| {
                        if (isFunctionAlias(tree, tags, datas, token_tags, init_idx) and isCamelCase(name)) {
                            return;
                        }
                    }
                    try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "constant", .snake_case);
                }
                return;
            },
            .variable => {
                // ZIR confirms this is a variable
                if (!isLowerSnakeCase(name)) {
                    try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "variable", .snake_case);
                }
                return;
            },
            .unknown => {
                // ZIR info not available, fall back to heuristic analysis
            },
        }

        // Fallback: heuristic-based analysis when ZIR type info is not available
        // Check if this is a type definition (const Foo = struct { ... })
        if (is_const) {
            if (init_idx_opt) |init_idx| {
                if (init_idx < tags.len) {
                    const init_tag = tags[init_idx];
                    if (isTypeDefinitionTag(init_tag)) {
                        const is_struct = isStructContainer(init_idx, main_tokens, token_tags);
                        if (!is_struct or init_tag == .error_set_decl) {
                            if (!isPascalCase(name) and !isCTypeAliasName(name)) {
                                try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "type", .pascal_case);
                            }
                            return;
                        }

                        const has_fields = containerHasFields(tree, tags, init_idx);
                        if (has_fields) {
                            if (!isPascalCase(name) and !isCTypeAliasName(name)) {
                                try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "type", .pascal_case);
                            }
                            return;
                        }

                        if (!isLowerSnakeCase(name) and !isPascalCase(name)) {
                            try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "namespace", .snake_case);
                        }
                        return;
                    }

                    // Check for function type (const foo = fn() void)
                    if (isFunctionTypeTag(init_tag)) {
                        // Function type alias - check for PascalCase
                        if (!isPascalCase(name) and !isCTypeAliasName(name)) {
                            try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "function type", .pascal_case);
                        }
                        return;
                    }

                    // Check for type alias from import: const Foo = @import("...").Foo
                    // or type alias: const Foo = SomeType
                    if (isLikelyTypeAlias(tree, tags, datas, main_tokens, token_tags, init_idx)) {
                        // This is likely a type alias - check for PascalCase
                        if (!isPascalCase(name) and !isCTypeAliasName(name)) {
                            try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "type alias", .pascal_case);
                        }
                        return;
                    }

                    if (isFunctionAlias(tree, tags, datas, token_tags, init_idx)) {
                        if (!isCamelCase(name) and !isLowerSnakeCase(name)) {
                            try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "constant", .snake_case);
                        }
                        return;
                    }
                }
            }
        }

        // For constants: require snake_case unless aliasing an external convention
        if (is_const) {
            const is_external_alias = isScreamingSnakeCase(name) and
                (if (init_idx_opt) |init_idx|
                    isExternalConventionAlias(tree, tags, datas, token_tags, init_idx)
                else
                    false);
            if (!isLowerSnakeCase(name) and !is_external_alias) {
                try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "constant", .snake_case);
            }
            return;
        }

        // For var declarations: require snake_case
        if (!isLowerSnakeCase(name)) {
            try emitDiagnostic(src, allocator, diagnostics, token_starts[name_token], name, "variable", .snake_case);
        }
    }

    /// Check if the init expression is likely a type alias (field access on import, or PascalCase identifier)
    fn isLikelyTypeAlias(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const std.zig.Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        init_idx: usize,
    ) bool {
        const init_tag = tags[init_idx];
        if (isTypeDefinitionTag(init_tag)) return true;

        return switch (init_tag) {
            // Direct identifier reference - check if PascalCase (likely type)
            .identifier => isTypeAliasCallee(tree, tags, datas, token_tags, init_idx),
            // Field access: @import("...").Foo or Module.Type
            .field_access => isTypeAliasCallee(tree, tags, datas, token_tags, init_idx),
            .call, .call_comma, .call_one, .call_one_comma => isTypeFactoryCall(tree, tags, datas, main_tokens, token_tags, init_idx),
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => blk: {
                const builtin_name = builtinCallName(tree, tags, token_tags, init_idx) orelse break :blk false;
                break :blk isTypeFactoryBuiltin(builtin_name);
            },
            .merge_error_sets,
            .error_union,
            .optional_type,
            .anyframe_type,
            .ptr_type,
            .ptr_type_sentinel,
            .ptr_type_bit_range,
            .ptr_type_aligned,
            .array_type,
            .array_type_sentinel,
            => true,
            .@"switch", .switch_comma => isTypeSwitchAlias(tree, tags, datas, main_tokens, token_tags, init_idx),
            .@"if", .if_simple => isTypeIfAlias(tree, tags, datas, main_tokens, token_tags, init_idx),
            .unwrap_optional,
            .grouped_expression,
            => blk: {
                const data = datas[init_idx].node_and_token;
                break :blk isLikelyTypeAlias(tree, tags, datas, main_tokens, token_tags, @intFromEnum(data[0]));
            },
            else => false,
        };
    }

    fn isTypeSwitchAlias(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const std.zig.Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        init_idx: usize,
    ) bool {
        const full_switch = tree.switchFull(@enumFromInt(init_idx));
        for (full_switch.ast.cases) |case_node| {
            const full_case = tree.fullSwitchCase(case_node) orelse return false;
            const target_idx = @intFromEnum(full_case.ast.target_expr);
            if (isCompileErrorExpr(tree, tags, datas, token_tags, target_idx)) continue;
            if (!isLikelyTypeAlias(tree, tags, datas, main_tokens, token_tags, target_idx)) return false;
        }
        return true;
    }

    fn isTypeIfAlias(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const std.zig.Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        init_idx: usize,
    ) bool {
        const full_if = tree.fullIf(@enumFromInt(init_idx)) orelse return false;
        const then_idx = @intFromEnum(full_if.ast.then_expr);
        const else_expr = full_if.ast.else_expr.unwrap() orelse return false;
        const else_idx = @intFromEnum(else_expr);

        const then_is_type = isCompileErrorExpr(tree, tags, datas, token_tags, then_idx) or
            isLikelyTypeAlias(tree, tags, datas, main_tokens, token_tags, then_idx);
        const else_is_type = isCompileErrorExpr(tree, tags, datas, token_tags, else_idx) or
            isLikelyTypeAlias(tree, tags, datas, main_tokens, token_tags, else_idx);
        return then_is_type and else_is_type;
    }

    fn isExternalConventionAlias(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        init_idx: usize,
    ) bool {
        return switch (tags[init_idx]) {
            .identifier => isScreamingIdentifier(tree, token_tags, init_idx),
            .field_access => blk: {
                const field_token = datas[init_idx].node_and_token[1];
                if (field_token >= token_tags.len or token_tags[field_token] != .identifier) break :blk false;
                const field_name = tree.tokenSlice(field_token);
                break :blk isScreamingSnakeCase(field_name);
            },
            .unwrap_optional,
            .grouped_expression,
            => blk: {
                const data = datas[init_idx].node_and_token;
                break :blk isExternalConventionAlias(tree, tags, datas, token_tags, @intFromEnum(data[0]));
            },
            else => false,
        };
    }

    fn isScreamingIdentifier(
        tree: *const std.zig.Ast,
        token_tags: []const std.zig.Token.Tag,
        node_idx: usize,
    ) bool {
        const ident_token = tree.nodes.items(.main_token)[node_idx];
        if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return false;
        return isScreamingSnakeCase(tree.tokenSlice(ident_token));
    }

    fn isCompileErrorExpr(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        node_idx: usize,
    ) bool {
        return switch (tags[node_idx]) {
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => blk: {
                const builtin_name = builtinCallName(tree, tags, token_tags, node_idx) orelse break :blk false;
                break :blk std.mem.eql(u8, builtin_name, "@compileError");
            },
            .unwrap_optional,
            .grouped_expression,
            => blk: {
                const data = datas[node_idx].node_and_token;
                break :blk isCompileErrorExpr(tree, tags, datas, token_tags, @intFromEnum(data[0]));
            },
            else => false,
        };
    }

    fn builtinCallName(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        node_idx: usize,
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

    fn isTypeFactoryBuiltin(name: []const u8) bool {
        return std.mem.eql(u8, name, "@TypeOf") or
            std.mem.eql(u8, name, "@Type") or
            std.mem.eql(u8, name, "@This") or
            std.mem.eql(u8, name, "@OpaqueType") or
            std.mem.eql(u8, name, "@Vector") or
            std.mem.eql(u8, name, "@Struct") or
            std.mem.eql(u8, name, "@Enum") or
            std.mem.eql(u8, name, "@Union");
    }

    fn isTypeInfoBuiltin(name: []const u8) bool {
        return std.mem.eql(u8, name, "@typeInfo");
    }

    fn isTypeInfoDerivedExpr(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        node_idx: usize,
    ) bool {
        return switch (tags[node_idx]) {
            .field_access => blk: {
                const data = datas[node_idx].node_and_token;
                const base_idx = @intFromEnum(data[0]);
                const field_token = data[1];
                if (field_token >= token_tags.len or token_tags[field_token] != .identifier) break :blk false;
                const field_name = tree.tokenSlice(field_token);
                if (!isTypeInfoTypeField(field_name)) break :blk false;
                break :blk isTypeInfoBaseExpr(tree, tags, datas, token_tags, base_idx);
            },
            .unwrap_optional,
            .grouped_expression,
            => blk: {
                const data = datas[node_idx].node_and_token;
                break :blk isTypeInfoDerivedExpr(tree, tags, datas, token_tags, @intFromEnum(data[0]));
            },
            else => false,
        };
    }

    fn isTypeInfoTypeField(name: []const u8) bool {
        return std.mem.eql(u8, name, "return_type");
    }

    fn isTypeInfoBaseExpr(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        node_idx: usize,
    ) bool {
        return switch (tags[node_idx]) {
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => isTypeInfoBuiltinCall(tree, tags, token_tags, node_idx),
            .field_access => blk: {
                const data = datas[node_idx].node_and_token;
                break :blk isTypeInfoBaseExpr(tree, tags, datas, token_tags, @intFromEnum(data[0]));
            },
            .unwrap_optional,
            .grouped_expression,
            => blk: {
                const data = datas[node_idx].node_and_token;
                break :blk isTypeInfoBaseExpr(tree, tags, datas, token_tags, @intFromEnum(data[0]));
            },
            else => false,
        };
    }

    fn isTypeInfoBuiltinCall(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        token_tags: []const std.zig.Token.Tag,
        node_idx: usize,
    ) bool {
        const builtin_name = builtinCallName(tree, tags, token_tags, node_idx) orelse return false;
        return isTypeInfoBuiltin(builtin_name);
    }

    fn isTypeAliasCallee(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        node_idx: usize,
    ) bool {
        const tag = tags[node_idx];
        return switch (tag) {
            .identifier => {
                const ident_token = tree.nodes.items(.main_token)[node_idx];
                if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return false;
                const ident_name = tree.tokenSlice(ident_token);
                return isPascalCase(ident_name) or isBuiltinTypeName(ident_name) or isCTypeAliasName(ident_name);
            },
            .field_access => {
                if (isTypeInfoDerivedExpr(tree, tags, datas, token_tags, node_idx)) return true;
                const data = datas[node_idx];
                const field_token = data.node_and_token[1];
                if (field_token < token_tags.len and token_tags[field_token] == .identifier) {
                    const field_name = tree.tokenSlice(field_token);
                    return isPascalCase(field_name) or isCTypeAliasName(field_name);
                }
                return false;
            },
            .unwrap_optional,
            .grouped_expression,
            => {
                const data = datas[node_idx].node_and_token;
                return isTypeAliasCallee(tree, tags, datas, token_tags, @intFromEnum(data[0]));
            },
            else => false,
        };
    }

    fn isCTypeAliasName(name: []const u8) bool {
        if (!isLowerSnakeCase(name)) return false;
        return std.mem.endsWith(u8, name, "_t");
    }

    fn isBuiltinTypeName(name: []const u8) bool {
        if (std.mem.eql(u8, name, "bool") or
            std.mem.eql(u8, name, "void") or
            std.mem.eql(u8, name, "noreturn") or
            std.mem.eql(u8, name, "type") or
            std.mem.eql(u8, name, "anytype") or
            std.mem.eql(u8, name, "anyopaque") or
            std.mem.eql(u8, name, "anyerror") or
            std.mem.eql(u8, name, "usize") or
            std.mem.eql(u8, name, "isize") or
            std.mem.eql(u8, name, "comptime_int") or
            std.mem.eql(u8, name, "comptime_float"))
        {
            return true;
        }

        if (name.len < 2) return false;
        const prefix = name[0];
        if (prefix != 'u' and prefix != 'i' and prefix != 'f') return false;
        for (name[1..]) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }

    fn isTypeFactoryCall(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        main_tokens: []const std.zig.Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
        init_idx: usize,
    ) bool {
        var buf: [1]std.zig.Ast.Node.Index = undefined;
        const call_info = tree.fullCall(&buf, @enumFromInt(init_idx)) orelse return false;
        const callee_idx = @intFromEnum(call_info.ast.fn_expr);
        if (!isTypeAliasCallee(tree, tags, datas, token_tags, callee_idx)) return false;

        var saw_type_arg = false;
        for (call_info.ast.params) |param| {
            const arg_idx = @intFromEnum(param);
            if (isLikelyTypeAlias(tree, tags, datas, main_tokens, token_tags, arg_idx)) {
                saw_type_arg = true;
                continue;
            }
            if (isTypeFactoryLiteral(tags, datas, arg_idx)) {
                continue;
            }
            return false;
        }

        return saw_type_arg;
    }

    fn isTypeFactoryLiteral(
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        node_idx: usize,
    ) bool {
        return switch (tags[node_idx]) {
            .number_literal,
            .string_literal,
            .multiline_string_literal,
            .char_literal,
            .enum_literal,
            => true,
            .unwrap_optional,
            .grouped_expression,
            => blk: {
                const data = datas[node_idx].node_and_token;
                break :blk isTypeFactoryLiteral(tags, datas, @intFromEnum(data[0]));
            },
            else => false,
        };
    }

    fn isFunctionAlias(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        datas: []const std.zig.Ast.Node.Data,
        token_tags: []const std.zig.Token.Tag,
        init_idx: usize,
    ) bool {
        const init_tag = tags[init_idx];

        switch (init_tag) {
            .identifier => {
                const ident_token = tree.nodes.items(.main_token)[init_idx];
                if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return false;
                const ident_name = tree.tokenSlice(ident_token);
                return isCamelCase(ident_name);
            },
            .field_access => {
                const data = datas[init_idx];
                const field_token = data.node_and_token[1];
                if (field_token < token_tags.len and token_tags[field_token] == .identifier) {
                    const field_name = tree.tokenSlice(field_token);
                    return isCamelCase(field_name);
                }
                return false;
            },
            else => return false,
        }
    }

    fn emitDiagnostic(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        byte_offset: u32,
        name: []const u8,
        kind: []const u8,
        expected_style: Style,
    ) RuleError!void {
        const loc = try src.byteToLocation(byte_offset);
        const style_name = switch (expected_style) {
            .pascal_case => "PascalCase",
            .camel_case => "camelCase",
            .snake_case => "snake_case",
        };
        const message = try std.fmt.allocPrint(
            allocator,
            "{s} '{s}' should use {s} naming",
            .{ kind, name, style_name },
        );
        defer allocator.free(message);

        const diag = try Diagnostic.initAtLocation(
            allocator,
            src.getFilePath(),
            "identifier-style",
            .warning,
            message,
            loc.line,
            loc.column,
        );
        try diagnostics.append(allocator, diag);
    }

    fn isTypeDefinitionTag(tag: std.zig.Ast.Node.Tag) bool {
        return switch (tag) {
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
            .error_set_decl,
            => true,
            else => false,
        };
    }

    fn isStructContainer(
        node_idx: usize,
        main_tokens: []const std.zig.Ast.TokenIndex,
        token_tags: []const std.zig.Token.Tag,
    ) bool {
        if (node_idx >= main_tokens.len) return false;
        const token = main_tokens[node_idx];
        if (token >= token_tags.len) return false;
        return token_tags[token] == .keyword_struct;
    }

    fn containerHasFields(
        tree: *const std.zig.Ast,
        tags: []const std.zig.Ast.Node.Tag,
        node_idx: usize,
    ) bool {
        var buf: [2]std.zig.Ast.Node.Index = undefined;

        const members: []const std.zig.Ast.Node.Index = switch (tags[node_idx]) {
            .container_decl, .container_decl_trailing => tree.containerDecl(@enumFromInt(node_idx)).ast.members,
            .container_decl_two, .container_decl_two_trailing => tree.containerDeclTwo(&buf, @enumFromInt(node_idx)).ast.members,
            .container_decl_arg, .container_decl_arg_trailing => tree.containerDeclArg(@enumFromInt(node_idx)).ast.members,
            .tagged_union, .tagged_union_trailing => tree.taggedUnion(@enumFromInt(node_idx)).ast.members,
            .tagged_union_enum_tag, .tagged_union_enum_tag_trailing => tree.taggedUnionEnumTag(@enumFromInt(node_idx)).ast.members,
            .tagged_union_two, .tagged_union_two_trailing => tree.taggedUnionTwo(&buf, @enumFromInt(node_idx)).ast.members,
            else => return false,
        };

        for (members) |member| {
            if (isContainerField(tags[@intFromEnum(member)])) return true;
        }

        return false;
    }

    fn isContainerField(tag: std.zig.Ast.Node.Tag) bool {
        return switch (tag) {
            .container_field,
            .container_field_init,
            .container_field_align,
            => true,
            else => false,
        };
    }

    fn isNamespaceStructDecl(src: *Source, decl: zir_bridge_mod.DeclInfo) bool {
        const ast_node = decl.ast_node orelse return false;
        const tree = src.ast() catch return false;
        const tags = tree.nodes.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        const full = tree.fullVarDecl(@enumFromInt(ast_node)) orelse return false;
        const init_node = full.ast.init_node.unwrap() orelse return false;
        const init_idx = @intFromEnum(init_node);
        if (init_idx >= tags.len) return false;
        if (!isTypeDefinitionTag(tags[init_idx])) return false;
        if (!isStructContainer(init_idx, main_tokens, token_tags)) return false;

        return !containerHasFields(tree, tags, init_idx);
    }

    fn findDeclByAstNode(src: *Source, node_idx: u32) ?zir_bridge_mod.DeclInfo {
        const count = src.getDeclCount();
        for (0..count) |i| {
            if (src.getDecl(i)) |decl| {
                if (decl.ast_node) |decl_node| {
                    if (decl_node == node_idx) return decl;
                }
            }
        }
        return null;
    }

    fn isFunctionTypeTag(tag: std.zig.Ast.Node.Tag) bool {
        return switch (tag) {
            .fn_proto,
            .fn_proto_simple,
            .fn_proto_one,
            .fn_proto_multi,
            => true,
            else => false,
        };
    }

    fn shouldSkipName(name: []const u8) bool {
        if (name.len == 0) return true;
        // Skip names starting with underscore (intentionally ignored)
        if (name[0] == '_') return true;
        // Skip special names
        if (std.mem.eql(u8, name, "main")) return true;
        if (std.mem.eql(u8, name, "panic")) return true;
        // Skip @"quoted" identifiers which may need to break conventions
        if (name.len >= 3 and std.mem.startsWith(u8, name, "@\"")) return true;
        return false;
    }

    /// Check if name follows PascalCase: starts with uppercase, no underscores between words
    fn isPascalCase(name: []const u8) bool {
        if (name.len == 0) return false;
        // Must start with uppercase letter
        if (!std.ascii.isUpper(name[0])) return false;
        // Should not contain underscores (except trailing for disambiguation like Type_)
        for (name[1..], 1..) |c, i| {
            if (c == '_') {
                // Allow trailing underscore for disambiguation
                if (i == name.len - 1) continue;
                return false;
            }
        }
        return true;
    }

    /// Check if name follows camelCase: starts with lowercase, no underscores between words
    fn isCamelCase(name: []const u8) bool {
        if (name.len == 0) return false;
        // Must start with lowercase letter
        if (!std.ascii.isLower(name[0])) return false;
        // Should not contain underscores
        for (name[1..]) |c| {
            if (c == '_') return false;
        }
        return true;
    }

    /// Check if name follows snake_case: all lowercase with underscores
    fn isSnakeCase(name: []const u8) bool {
        return isLowerSnakeCase(name);
    }

    fn isLowerSnakeCase(name: []const u8) bool {
        if (name.len == 0) return false;

        var has_lower = false;
        for (name) |c| {
            if (std.ascii.isLower(c)) {
                has_lower = true;
                continue;
            }
            if (std.ascii.isUpper(c)) return false;
            if (std.ascii.isDigit(c)) continue;
            if (c == '_') continue;
            return false;
        }

        return has_lower;
    }

    fn isScreamingSnakeCase(name: []const u8) bool {
        if (name.len == 0) return false;

        var has_upper = false;
        for (name) |c| {
            if (std.ascii.isUpper(c)) {
                has_upper = true;
                continue;
            }
            if (std.ascii.isLower(c)) return false;
            if (std.ascii.isDigit(c)) continue;
            if (c == '_') continue;
            return false;
        }

        return has_upper;
    }

    fn checkSnakeCaseToken(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
        token: u32,
        kind: []const u8,
    ) RuleError!void {
        if (token >= token_tags.len or token_tags[token] != .identifier) return;
        const name = tree.tokenSlice(token);
        if (shouldSkipName(name)) return;
        if (!isLowerSnakeCase(name)) {
            try emitDiagnostic(src, allocator, diagnostics, token_starts[token], name, kind, .snake_case);
        }
    }

    fn checkParamName(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
        token: u32,
        param: std.zig.Ast.full.FnProto.Param,
    ) RuleError!void {
        if (token >= token_tags.len or token_tags[token] != .identifier) return;
        const name = tree.tokenSlice(token);
        if (shouldSkipName(name)) return;
        if (isLowerSnakeCase(name)) return;
        if (isTypeParam(tree, param) and isPascalCase(name)) return;
        try emitDiagnostic(src, allocator, diagnostics, token_starts[token], name, "parameter", .snake_case);
    }

    fn isTypeParam(tree: *const std.zig.Ast, param: std.zig.Ast.full.FnProto.Param) bool {
        if (param.anytype_ellipsis3 != null) return true;
        const comptime_token = param.comptime_noalias orelse return false;
        if (tree.tokenTag(comptime_token) != .keyword_comptime) return false;
        const type_expr = param.type_expr orelse return false;
        const type_idx = @intFromEnum(type_expr);
        const tags = tree.nodes.items(.tag);
        if (type_idx >= tags.len) return false;
        if (tags[type_idx] != .identifier) return false;
        const ident_token = tree.nodes.items(.main_token)[type_idx];
        if (tree.tokenTag(ident_token) != .identifier) return false;
        return std.mem.eql(u8, tree.tokenSlice(ident_token), "type");
    }

    fn checkIfPayloads(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        const full_if = tree.fullIf(@enumFromInt(node_idx)) orelse return;
        if (full_if.payload_token) |tok| {
            try checkPayloadToken(src, allocator, diagnostics, tree, token_tags, token_starts, tok, "payload");
        }
        if (full_if.error_token) |tok| {
            try checkPayloadToken(src, allocator, diagnostics, tree, token_tags, token_starts, tok, "payload");
        }
    }

    fn checkWhilePayloads(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        const tags = tree.nodes.items(.tag);
        const full_while = switch (tags[node_idx]) {
            .while_simple => tree.whileSimple(@enumFromInt(node_idx)),
            .while_cont => tree.whileCont(@enumFromInt(node_idx)),
            .@"while" => tree.whileFull(@enumFromInt(node_idx)),
            else => return,
        };

        if (full_while.payload_token) |tok| {
            try checkPayloadToken(src, allocator, diagnostics, tree, token_tags, token_starts, tok, "payload");
        }
        if (full_while.error_token) |tok| {
            try checkPayloadToken(src, allocator, diagnostics, tree, token_tags, token_starts, tok, "payload");
        }
    }

    fn checkForPayloads(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        const tags = tree.nodes.items(.tag);
        const full_for = switch (tags[node_idx]) {
            .@"for" => tree.forFull(@enumFromInt(node_idx)),
            .for_simple => tree.forSimple(@enumFromInt(node_idx)),
            else => return,
        };

        try checkForPayloadTokens(src, allocator, diagnostics, tree, token_tags, token_starts, full_for.payload_token);
    }

    fn checkSwitchPayloads(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        const full_switch = tree.switchFull(@enumFromInt(node_idx));
        for (full_switch.ast.cases) |case_node| {
            const full_case = tree.fullSwitchCase(case_node) orelse continue;
            if (full_case.payload_token) |tok| {
                try checkPayloadToken(src, allocator, diagnostics, tree, token_tags, token_starts, tok, "payload");
            }
        }
    }

    fn checkCatchPayload(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        const main_tokens = tree.nodes.items(.main_token);
        const catch_token = main_tokens[node_idx];
        if (catch_token + 2 >= token_tags.len) return;
        if (token_tags[catch_token + 1] != .pipe) return;
        try checkPayloadToken(src, allocator, diagnostics, tree, token_tags, token_starts, catch_token + 2, "payload");
    }

    fn checkErrdeferPayload(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        node_idx: u32,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
    ) RuleError!void {
        const data = tree.nodes.items(.data)[node_idx].opt_token_and_node;
        const payload_token = data[0].unwrap() orelse return;
        try checkPayloadToken(src, allocator, diagnostics, tree, token_tags, token_starts, payload_token, "payload");
    }

    fn checkPayloadToken(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
        token: u32,
        kind: []const u8,
    ) RuleError!void {
        if (token >= token_tags.len) return;
        var idx = token;
        if (token_tags[idx] == .pipe) idx += 1;
        if (idx < token_tags.len and token_tags[idx] == .asterisk) idx += 1;
        if (idx < token_tags.len and token_tags[idx] == .identifier) {
            try checkSnakeCaseToken(src, allocator, diagnostics, tree, token_tags, token_starts, idx, kind);
        }
    }

    fn checkForPayloadTokens(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        tree: *const std.zig.Ast,
        token_tags: []const std.zig.Token.Tag,
        token_starts: []const u32,
        token: u32,
    ) RuleError!void {
        var idx = token;
        if (idx >= token_tags.len) return;

        if (token_tags[idx] == .pipe) idx += 1;
        while (idx < token_tags.len) : (idx += 1) {
            const tag = token_tags[idx];
            if (tag == .pipe) break;
            if (tag == .asterisk) {
                idx += 1;
                if (idx < token_tags.len and token_tags[idx] == .identifier) {
                    try checkSnakeCaseToken(src, allocator, diagnostics, tree, token_tags, token_starts, idx, "payload");
                }
                continue;
            }
            if (tag == .identifier) {
                try checkSnakeCaseToken(src, allocator, diagnostics, tree, token_tags, token_starts, idx, "payload");
            }
        }
    }
};

test "isPascalCase" {
    const isPascalCase = IdentifierStyleRule.isPascalCase;
    try std.testing.expect(isPascalCase("Foo"));
    try std.testing.expect(isPascalCase("FooBar"));
    try std.testing.expect(isPascalCase("FooBarBaz"));
    try std.testing.expect(isPascalCase("F"));
    try std.testing.expect(isPascalCase("Type_")); // trailing underscore allowed
    try std.testing.expect(!isPascalCase("foo"));
    try std.testing.expect(!isPascalCase("fooBar"));
    try std.testing.expect(!isPascalCase("foo_bar"));
    try std.testing.expect(!isPascalCase("Foo_Bar"));
    try std.testing.expect(!isPascalCase("FOO_BAR"));
}

test "isCamelCase" {
    const isCamelCase = IdentifierStyleRule.isCamelCase;
    try std.testing.expect(isCamelCase("foo"));
    try std.testing.expect(isCamelCase("fooBar"));
    try std.testing.expect(isCamelCase("fooBarBaz"));
    try std.testing.expect(isCamelCase("f"));
    try std.testing.expect(!isCamelCase("Foo"));
    try std.testing.expect(!isCamelCase("FooBar"));
    try std.testing.expect(!isCamelCase("foo_bar"));
    try std.testing.expect(!isCamelCase("foo_Bar"));
}

test "isSnakeCase" {
    const isSnakeCase = IdentifierStyleRule.isSnakeCase;
    try std.testing.expect(isSnakeCase("foo"));
    try std.testing.expect(isSnakeCase("foo_bar"));
    try std.testing.expect(isSnakeCase("foo_bar_baz"));
    try std.testing.expect(!isSnakeCase("fooBar"));
    try std.testing.expect(!isSnakeCase("FooBar"));
    try std.testing.expect(!isSnakeCase("foo_Bar"));
    try std.testing.expect(!isSnakeCase("FOO"));
    try std.testing.expect(!isSnakeCase("FOO_BAR"));
}

test "isLowerSnakeCase" {
    const isLowerSnakeCase = IdentifierStyleRule.isLowerSnakeCase;
    try std.testing.expect(isLowerSnakeCase("foo"));
    try std.testing.expect(isLowerSnakeCase("foo_bar"));
    try std.testing.expect(isLowerSnakeCase("foo2_bar3"));
    try std.testing.expect(!isLowerSnakeCase("FOO"));
    try std.testing.expect(!isLowerSnakeCase("Foo"));
    try std.testing.expect(!isLowerSnakeCase("foo_Bar"));
}

test "isScreamingSnakeCase" {
    const isScreamingSnakeCase = IdentifierStyleRule.isScreamingSnakeCase;
    try std.testing.expect(isScreamingSnakeCase("FOO"));
    try std.testing.expect(isScreamingSnakeCase("FOO_BAR"));
    try std.testing.expect(isScreamingSnakeCase("FOO2_BAR3"));
    try std.testing.expect(isScreamingSnakeCase("MAX_SIZE"));
    try std.testing.expect(!isScreamingSnakeCase("foo"));
    try std.testing.expect(!isScreamingSnakeCase("Foo"));
    try std.testing.expect(!isScreamingSnakeCase("foo_Bar"));
}

test "classifyDeclWithTypeInfo for struct" {
    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "const MyStruct = struct { value: i32 };";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const node_idx = @intFromEnum(root_decls[0]);
    const classification = IdentifierStyleRule.classifyDeclWithTypeInfo(&source, "MyStruct", node_idx);
    try std.testing.expectEqual(IdentifierStyleRule.DeclClassification.type_decl, classification);
}

test "classifyDeclWithTypeInfo for enum" {
    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "const MyEnum = enum { a, b, c };";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const node_idx = @intFromEnum(root_decls[0]);
    const classification = IdentifierStyleRule.classifyDeclWithTypeInfo(&source, "MyEnum", node_idx);
    try std.testing.expectEqual(IdentifierStyleRule.DeclClassification.type_decl, classification);
}

test "classifyDeclWithTypeInfo for constant" {
    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "const my_const: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const node_idx = @intFromEnum(root_decls[0]);
    const classification = IdentifierStyleRule.classifyDeclWithTypeInfo(&source, "my_const", node_idx);
    try std.testing.expectEqual(IdentifierStyleRule.DeclClassification.constant, classification);
}

test "classifyDeclWithTypeInfo for variable" {
    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "var my_var: i32 = 0;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const node_idx = @intFromEnum(root_decls[0]);
    const classification = IdentifierStyleRule.classifyDeclWithTypeInfo(&source, "my_var", node_idx);
    try std.testing.expectEqual(IdentifierStyleRule.DeclClassification.variable, classification);
}

test "classifyDeclWithTypeInfo for function" {
    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "fn myFunc() void {}";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const node_idx = @intFromEnum(root_decls[0]);
    const classification = IdentifierStyleRule.classifyDeclWithTypeInfo(&source, "myFunc", node_idx);
    try std.testing.expectEqual(IdentifierStyleRule.DeclClassification.function, classification);
}

test "classifyDeclWithTypeInfo returns unknown for nonexistent" {
    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const node_idx = @intFromEnum(root_decls[0]);
    const classification = IdentifierStyleRule.classifyDeclWithTypeInfo(&source, "nonexistent", node_idx);
    try std.testing.expectEqual(IdentifierStyleRule.DeclClassification.unknown, classification);
}
