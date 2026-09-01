const std = @import("std");
const Source = @import("source.zig").Source;
const zir_bridge_mod = @import("zir_bridge.zig");

pub const TypeInfo = zir_bridge_mod.TypeInfo;
pub const DeclInfo = zir_bridge_mod.DeclInfo;
pub const ZirBridge = zir_bridge_mod.ZirBridge;

/// TypeContext provides a unified interface for type information queries.
/// It wraps ZirBridge and provides convenient methods for checkers and rules
/// to query type information during analysis.
///
/// The context supports:
/// - Declaration type lookups by name
/// - AST node to type mappings
/// - Type kind queries (is this an error union? optional? pointer?)
/// - Future: cross-file type resolution
pub const TypeContext = struct {
    allocator: std.mem.Allocator,
    source: *Source,

    /// Cache for frequently queried types by AST node index.
    /// This avoids repeated ZIR lookups for the same nodes.
    node_type_cache: std.AutoHashMap(u32, TypeInfo),

    pub fn init(allocator: std.mem.Allocator, source: *Source) TypeContext {
        return .{
            .allocator = allocator,
            .source = source,
            .node_type_cache = std.AutoHashMap(u32, TypeInfo).init(allocator),
        };
    }

    pub fn deinit(self: *TypeContext) void {
        self.node_type_cache.deinit();
    }

    // =========================================================================
    // Core Type Query API
    // =========================================================================

    /// Check if type information is available.
    pub fn isAvailable(self: *TypeContext) bool {
        return self.source.hasTypeInfo();
    }

    /// Get the ZirBridge if available.
    pub fn getZirBridge(self: *TypeContext) ?*const ZirBridge {
        return self.source.zirBridge();
    }

    // =========================================================================
    // Declaration Queries
    // =========================================================================

    /// Find type information for a declaration by name.
    pub fn getDeclType(self: *TypeContext, name: []const u8) ?TypeInfo {
        return self.source.findDeclType(name);
    }

    /// Find full declaration information by name.
    pub fn getDecl(self: *TypeContext, name: []const u8) ?DeclInfo {
        return self.source.findDecl(name);
    }

    /// Check if a declaration exists.
    pub fn hasDecl(self: *TypeContext, name: []const u8) bool {
        return self.source.findDecl(name) != null;
    }

    /// Check if a declaration is a function.
    pub fn isDeclFunction(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclFunction(name);
    }

    /// Check if a declaration is a type (struct, enum, union, type).
    pub fn isDeclType(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclType(name);
    }

    /// Check if a declaration is public.
    pub fn isDeclPublic(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclPublic(name);
    }

    /// Check if a declaration is a constant.
    pub fn isDeclConst(self: *TypeContext, name: []const u8) bool {
        return self.source.isDeclConst(name);
    }

    /// Get all declarations.
    pub fn getAllDecls(self: *TypeContext, result: *std.ArrayList(DeclInfo)) !void {
        const count = self.source.getDeclCount();
        for (0..count) |i| {
            if (self.source.getDecl(i)) |decl| {
                try result.append(self.allocator, decl);
            }
        }
    }

    // =========================================================================
    // AST Node Type Queries
    // =========================================================================

    /// Get type information for an AST node by index.
    /// Uses caching to avoid repeated lookups.
    pub fn getNodeType(self: *TypeContext, ast_node: u32) ?TypeInfo {
        // Check cache first
        if (self.node_type_cache.get(ast_node)) |cached| {
            return cached;
        }

        // Try to find type from ZirBridge
        const bridge = self.source.zirBridge() orelse return null;

        // Search declarations for matching AST node
        const count = bridge.getDeclCount();
        for (0..count) |i| {
            if (bridge.getDecl(i)) |decl| {
                if (decl.ast_node == ast_node) {
                    // Cache and return
                    self.node_type_cache.put(ast_node, decl.type_info) catch |err| {
                        std.debug.assert(err == error.OutOfMemory);
                    };
                    return decl.type_info;
                }
            }
        }

        return null;
    }

    /// Get type information for an expression node (call, return, etc.).
    /// This extends getNodeType to handle expression nodes that aren't declarations.
    pub fn getExpressionType(self: *TypeContext, ast_node: u32) ?TypeInfo {
        return self.getExpressionTypeInternal(ast_node, true, true);
    }

    /// Strict expression type query that avoids name-only heuristics.
    /// Use this when the result should only be driven by resolved type information.
    pub fn getExpressionTypeStrict(self: *TypeContext, ast_node: u32) ?TypeInfo {
        return self.getExpressionTypeInternal(ast_node, false, false);
    }

    fn getExpressionTypeInternal(self: *TypeContext, ast_node: u32, use_known_methods: bool, use_cache: bool) ?TypeInfo {
        if (use_cache) {
            if (self.node_type_cache.get(ast_node)) |cached| {
                return cached;
            }
        }

        const tree = self.source.ast() catch return null;
        const tags = tree.nodes.items(.tag);

        if (ast_node >= tags.len) return null;

        const type_info: ?TypeInfo = switch (tags[ast_node]) {
            .call, .call_comma, .call_one, .call_one_comma => self.getCallExpressionType(tree, ast_node, use_known_methods),
            .@"try" => self.getTryExpressionType(tree, ast_node),
            .@"catch" => self.getCatchExpressionType(tree, ast_node),
            .error_value => TypeInfo.initErrorUnion(),
            .identifier => self.getIdentifierType(tree, ast_node),
            .field_access => self.getFieldAccessType(tree, ast_node, use_known_methods, use_cache),
            else => null,
        };

        if (use_cache) {
            if (type_info) |ti| {
                self.node_type_cache.put(ast_node, ti) catch |err| {
                    std.debug.assert(err == error.OutOfMemory);
                };
                return ti;
            }
        }

        return type_info;
    }

    /// Get the return type of a call expression.
    fn getCallExpressionType(self: *TypeContext, tree: *const std.zig.Ast, call_node: u32, use_known_methods: bool) ?TypeInfo {
        const tags = tree.nodes.items(.tag);

        // Get the callee (function being called)
        var call_buf: [1]std.zig.Ast.Node.Index = undefined;
        const full_call = switch (tags[call_node]) {
            .call, .call_comma, .call_one, .call_one_comma => tree.fullCall(&call_buf, @enumFromInt(call_node)),
            else => return null,
        } orelse return null;

        const callee_node: u32 = @intFromEnum(full_call.ast.fn_expr);
        if (callee_node >= tags.len) return null;

        // If the callee is a simple identifier, look up the function declaration
        if (tags[callee_node] == .identifier) {
            return self.getFunctionReturnTypeByIdent(tree, callee_node);
        }

        // If the callee is a field access (method call), try to determine type from the field name
        if (tags[callee_node] == .field_access) {
            return self.getMethodReturnType(tree, callee_node, use_known_methods);
        }

        return null;
    }

    /// Get the return type of a function by looking up its declaration by identifier.
    fn getFunctionReturnTypeByIdent(self: *TypeContext, tree: *const std.zig.Ast, ident_node: u32) ?TypeInfo {
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        const ident_token = main_tokens[ident_node];
        if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return null;

        const fn_name = tree.tokenSlice(ident_token);

        // Look up the function declaration by name
        const bridge = self.source.zirBridge() orelse return null;
        if (bridge.findDeclByName(fn_name)) |decl| {
            if (decl.is_fn and decl.ast_node != null) {
                return bridge.getFunctionReturnType(decl.ast_node.?);
            }
        }

        return null;
    }

    /// Get the return type of a method call from field access.
    /// First tries known standard library methods, then falls back to looking up
    /// the method as a function declaration in the current file.
    fn getMethodReturnType(self: *TypeContext, tree: *const std.zig.Ast, field_node: u32, use_known_methods: bool) ?TypeInfo {
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const source = self.source.getContent();

        const field_token = datas[field_node].node_and_token[1];
        if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;

        const method_name = extractIdentifier(source, token_starts[field_token]);

        if (use_known_methods) {
            // First check hardcoded known methods, then fall back to function lookup
            if (self.getKnownMethodReturnType(method_name)) |ti| {
                return ti;
            }
        }

        // Fall back: scan for any matching function declaration (including container methods)
        if (self.findAnyFunctionReturnType(tree, method_name)) |ti| {
            return ti;
        }

        return null;
    }

    fn getFieldAccessType(self: *TypeContext, tree: *const std.zig.Ast, field_node: u32, use_known_methods: bool, use_cache: bool) ?TypeInfo {
        const datas = tree.nodes.items(.data);
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const source = self.source.getContent();

        const field_access = datas[field_node].node_and_token;
        const base_node = @intFromEnum(field_access[0]);
        const field_token = field_access[1];
        if (field_token >= token_tags.len or token_tags[field_token] != .identifier) return null;

        const field_name = extractIdentifier(source, token_starts[field_token]);
        const base_type = self.getExpressionTypeInternal(base_node, use_known_methods, use_cache) orelse return null;
        const base_type_name = base_type.type_str orelse return null;

        const container_node = self.findContainerDeclForType(tree, base_type_name) orelse return null;
        return self.getContainerFieldType(tree, container_node, field_name, use_known_methods, use_cache);
    }

    fn findContainerDeclForType(self: *TypeContext, tree: *const std.zig.Ast, type_name: []const u8) ?u32 {
        _ = self;
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);

        for (0..tags.len) |i| {
            const node_idx: u32 = @intCast(i);
            if (tags[node_idx] == .simple_var_decl or
                tags[node_idx] == .aligned_var_decl or
                tags[node_idx] == .local_var_decl or
                tags[node_idx] == .global_var_decl)
            {
                const full_decl = tree.fullVarDecl(@enumFromInt(node_idx)) orelse continue;
                const name_token = full_decl.ast.mut_token + 1;
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                const decl_name = tree.tokenSlice(name_token);
                if (!std.mem.eql(u8, decl_name, type_name)) continue;

                if (full_decl.ast.init_node.unwrap()) |init_node_idx| {
                    const init_node: u32 = @intFromEnum(init_node_idx);
                    if (init_node >= tags.len) continue;
                    switch (tags[init_node]) {
                        .container_decl,
                        .container_decl_trailing,
                        .container_decl_two,
                        .container_decl_two_trailing,
                        .container_decl_arg,
                        .container_decl_arg_trailing,
                        => return init_node,
                        else => {},
                    }
                }
            }
        }

        return null;
    }

    fn getContainerFieldType(
        self: *TypeContext,
        tree: *const std.zig.Ast,
        container_node: u32,
        field_name: []const u8,
        use_known_methods: bool,
        use_cache: bool,
    ) ?TypeInfo {
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, @enumFromInt(container_node)) orelse return null;

        for (container.ast.members) |member| {
            const member_idx: usize = @intCast(@intFromEnum(member));
            if (member_idx >= tags.len) continue;
            switch (tags[member_idx]) {
                .container_field => {
                    const field = tree.containerField(member);
                    if (field.ast.tuple_like) continue;
                    const name_token = field.ast.main_token;
                    if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                    const name = tree.tokenSlice(name_token);
                    if (!std.mem.eql(u8, name, field_name)) continue;
                    if (field.ast.type_expr.unwrap()) |type_node| {
                        return self.getTypeFromAstNode(@intFromEnum(type_node));
                    }
                    if (field.ast.value_expr.unwrap()) |value_node| {
                        return self.getExpressionTypeInternal(@intFromEnum(value_node), use_known_methods, use_cache);
                    }
                },
                .container_field_init => {
                    const field = tree.containerFieldInit(member);
                    if (field.ast.tuple_like) continue;
                    const name_token = field.ast.main_token;
                    if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                    const name = tree.tokenSlice(name_token);
                    if (!std.mem.eql(u8, name, field_name)) continue;
                    if (field.ast.type_expr.unwrap()) |type_node| {
                        return self.getTypeFromAstNode(@intFromEnum(type_node));
                    }
                    if (field.ast.value_expr.unwrap()) |value_node| {
                        return self.getExpressionTypeInternal(@intFromEnum(value_node), use_known_methods, use_cache);
                    }
                },
                .container_field_align => {
                    const field = tree.containerFieldAlign(member);
                    if (field.ast.tuple_like) continue;
                    const name_token = field.ast.main_token;
                    if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                    const name = tree.tokenSlice(name_token);
                    if (!std.mem.eql(u8, name, field_name)) continue;
                    if (field.ast.type_expr.unwrap()) |type_node| {
                        return self.getTypeFromAstNode(@intFromEnum(type_node));
                    }
                    if (field.ast.value_expr.unwrap()) |value_node| {
                        return self.getExpressionTypeInternal(@intFromEnum(value_node), use_known_methods, use_cache);
                    }
                },
                else => {},
            }
        }

        return null;
    }

    /// Get return type for known standard library methods.
    fn getKnownMethodReturnType(self: *TypeContext, method_name: []const u8) ?TypeInfo {
        _ = self;

        // File opening methods - return std.fs.File (wrapped in error union)
        if (std.mem.eql(u8, method_name, "openFile") or
            std.mem.eql(u8, method_name, "createFile"))
        {
            return .{ .kind = .error_union, .type_str = "std.fs.File" };
        }

        // Directory opening methods - return std.fs.Dir
        if (std.mem.eql(u8, method_name, "openDir")) {
            return .{ .kind = .error_union, .type_str = "std.fs.Dir" };
        }

        // Iterable directory methods
        if (std.mem.eql(u8, method_name, "openIterableDir")) {
            return .{ .kind = .error_union, .type_str = "std.fs.IterableDir" };
        }

        // Known methods that return error unions without specific type info
        if (std.mem.eql(u8, method_name, "alloc") or
            std.mem.eql(u8, method_name, "dupe") or
            std.mem.eql(u8, method_name, "create") or
            std.mem.eql(u8, method_name, "open") or
            std.mem.eql(u8, method_name, "read") or
            std.mem.eql(u8, method_name, "write") or
            std.mem.eql(u8, method_name, "readAll") or
            std.mem.eql(u8, method_name, "readToEndAlloc"))
        {
            return TypeInfo.initErrorUnion();
        }

        // Known methods that return optionals
        if (std.mem.eql(u8, method_name, "get") or
            std.mem.eql(u8, method_name, "getOrNull") or
            std.mem.eql(u8, method_name, "pop") or
            std.mem.eql(u8, method_name, "popOrNull"))
        {
            return TypeInfo.initOptional();
        }

        return null;
    }

    fn findAnyFunctionReturnType(self: *TypeContext, tree: *const std.zig.Ast, name: []const u8) ?TypeInfo {
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        const bridge = self.source.zirBridge() orelse return null;

        for (0..tags.len) |i| {
            if (tags[i] != .fn_decl) continue;
            const fn_node: u32 = @intCast(i);
            const fn_proto_node = data[fn_node].node_and_node[0];
            const proto_idx: u32 = @intFromEnum(fn_proto_node);
            if (proto_idx == 0 or proto_idx >= tags.len) continue;

            const proto_tag = tags[proto_idx];
            switch (proto_tag) {
                .fn_proto,
                .fn_proto_simple,
                .fn_proto_one,
                .fn_proto_multi,
                => {},
                else => continue,
            }

            const main_token = main_tokens[proto_idx];
            var name_token = main_token + 1;
            while (name_token < token_tags.len and token_tags[name_token] != .identifier) {
                name_token += 1;
                if (name_token > main_token + 5) break;
            }
            if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;

            const fn_name = tree.tokenSlice(name_token);
            if (!std.mem.eql(u8, fn_name, name)) continue;

            return bridge.getFunctionReturnType(fn_node);
        }

        return null;
    }

    /// Get the type of a try expression (unwraps error union).
    fn getTryExpressionType(self: *TypeContext, tree: *const std.zig.Ast, try_node: u32) ?TypeInfo {
        const datas = tree.nodes.items(.data);
        const inner_node = @intFromEnum(datas[try_node].node);

        // The inner expression should be an error union
        const inner_type = self.getExpressionType(inner_node);
        if (inner_type) |ti| {
            if (ti.kind == .error_union) {
                // Try unwraps error union, but we don't know the success type
                return TypeInfo.initUnknown();
            }
        }
        return inner_type;
    }

    /// Get the type of a catch expression.
    /// The catch expression evaluates to either the success value of the LHS
    /// or the RHS fallback value. For type purposes, we return the RHS type
    /// since that's what the expression evaluates to when an error occurs.
    fn getCatchExpressionType(self: *TypeContext, tree: *const std.zig.Ast, catch_node: u32) ?TypeInfo {
        const datas = tree.nodes.items(.data);
        const pair = datas[catch_node].node_and_node;

        // Return the RHS type (the catch body/fallback value)
        // This is what the expression evaluates to when an error is caught
        return self.getExpressionType(@intFromEnum(pair[1]));
    }

    /// Get the type of an identifier by looking up its declaration.
    fn getIdentifierType(self: *TypeContext, tree: *const std.zig.Ast, ident_node: u32) ?TypeInfo {
        const main_tokens = tree.nodes.items(.main_token);
        const token_tags = tree.tokens.items(.tag);

        const ident_token = main_tokens[ident_node];
        if (ident_token >= token_tags.len or token_tags[ident_token] != .identifier) return null;

        const name = tree.tokenSlice(ident_token);

        if (self.getLocalVarType(tree, name)) |ti| {
            return ti;
        }

        if (self.getDeclType(name)) |ti| {
            return ti;
        }

        return null;
    }

    /// Resolve a local variable type from its declaration or initializer.
    /// This handles cases like `var pool = MyPool{}` and `const err: anyerror = error.SomeError;`.
    fn getLocalVarType(self: *TypeContext, tree: *const std.zig.Ast, name: []const u8) ?TypeInfo {
        const tags = tree.nodes.items(.tag);
        const token_tags = tree.tokens.items(.tag);
        const main_tokens = tree.nodes.items(.main_token);

        // Search through the AST for variable declarations with this name
        for (0..tags.len) |i| {
            const node_idx: u32 = @intCast(i);
            if (tags[node_idx] == .simple_var_decl or
                tags[node_idx] == .aligned_var_decl or
                tags[node_idx] == .local_var_decl)
            {
                const full_decl = tree.fullVarDecl(@enumFromInt(node_idx)) orelse continue;

                // Get the variable name
                const name_token = full_decl.ast.mut_token + 1;
                if (name_token >= token_tags.len or token_tags[name_token] != .identifier) continue;
                const decl_name = tree.tokenSlice(name_token);

                if (!std.mem.eql(u8, decl_name, name)) continue;

                // Check if there's a type annotation
                if (full_decl.ast.type_node.unwrap()) |type_node_idx| {
                    const type_node: u32 = @intFromEnum(type_node_idx);
                    if (type_node < tags.len and tags[type_node] == .identifier) {
                        const type_token = main_tokens[type_node];
                        if (type_token < token_tags.len and token_tags[type_token] == .identifier) {
                            const type_name = tree.tokenSlice(type_token);
                            if (isErrorTypeName(type_name)) {
                                return TypeInfo.initErrorUnion();
                            }
                        }
                    }

                    if (self.getTypeFromAstNode(type_node)) |ti| {
                        if (ti.kind != .unknown or ti.type_str != null) {
                            return ti;
                        }
                    }
                }

                // Check if the initializer is an error value
                if (full_decl.ast.init_node.unwrap()) |init_node_idx| {
                    const init_node: u32 = @intFromEnum(init_node_idx);
                    if (init_node < tags.len and tags[init_node] == .error_value) {
                        return TypeInfo.initErrorUnion();
                    }

                    if (self.getTypeFromInit(tree, init_node, name)) |ti| {
                        return ti;
                    }
                }
            }
        }

        return null;
    }

    /// Check if an expression type is an error union.
    pub fn isExpressionErrorUnion(self: *TypeContext, ast_node: u32) bool {
        const ti = self.getExpressionType(ast_node) orelse return false;
        return ti.kind == .error_union;
    }

    /// Check if an expression type is an optional.
    pub fn isExpressionOptional(self: *TypeContext, ast_node: u32) bool {
        const ti = self.getExpressionType(ast_node) orelse return false;
        return ti.kind == .optional;
    }

    /// Get the return type of the containing function for a return expression.
    pub fn getContainingFunctionReturnType(self: *TypeContext, fn_ast_node: u32) ?TypeInfo {
        const bridge = self.source.zirBridge() orelse return null;
        return bridge.getFunctionReturnType(fn_ast_node);
    }

    fn extractIdentifier(source: []const u8, start: usize) []const u8 {
        var end = start;
        while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) {
            end += 1;
        }
        return source[start..end];
    }

    fn isErrorTypeName(name: []const u8) bool {
        return std.mem.eql(u8, name, "anyerror") or
            std.mem.indexOf(u8, name, "Error") != null or
            std.mem.indexOf(u8, name, "error") != null;
    }

    pub fn getTypeFromAstNode(self: *TypeContext, ast_node: u32) ?TypeInfo {
        const bridge = self.source.zirBridge() orelse return null;
        return bridge.getTypeFromAstNode(ast_node);
    }

    fn getTypeFromInit(self: *TypeContext, tree: *const std.zig.Ast, init_node: u32, decl_name: []const u8) ?TypeInfo {
        const tags = tree.nodes.items(.tag);

        if (init_node >= tags.len) return null;

        switch (tags[init_node]) {
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const struct_init = tree.fullStructInit(&buf, @enumFromInt(init_node)) orelse return null;
                if (struct_init.ast.type_expr.unwrap()) |type_node| {
                    if (self.getTypeFromAstNode(@intFromEnum(type_node))) |ti| {
                        if (ti.kind != .unknown or ti.type_str != null) return ti;
                    }
                }
            },
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            => {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const array_init = tree.fullArrayInit(&buf, @enumFromInt(init_node)) orelse return null;
                if (array_init.ast.type_expr.unwrap()) |type_node| {
                    if (self.getTypeFromAstNode(@intFromEnum(type_node))) |ti| {
                        if (ti.kind != .unknown or ti.type_str != null) return ti;
                    }
                }
            },
            .identifier => {
                const main_tokens = tree.nodes.items(.main_token);
                const token_tags = tree.tokens.items(.tag);
                const token = main_tokens[init_node];
                if (token < token_tags.len and token_tags[token] == .identifier) {
                    const name = tree.tokenSlice(token);
                    if (std.mem.eql(u8, name, decl_name)) {
                        return null;
                    }
                }
            },
            else => {},
        }

        if (self.getExpressionType(init_node)) |ti| {
            if (ti.kind != .unknown or ti.type_str != null) return ti;
        }
        return null;
    }

    /// Cache a type for an AST node (useful when building CFG).
    pub fn cacheNodeType(self: *TypeContext, ast_node: u32, type_info: TypeInfo) void {
        self.node_type_cache.put(ast_node, type_info) catch |err| {
            std.debug.assert(err == error.OutOfMemory);
        };
    }

    // =========================================================================
    // Type Kind Queries (convenience methods)
    // =========================================================================

    /// Check if a declaration has an error union type.
    pub fn isDeclErrorUnion(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .error_union;
    }

    /// Check if a declaration has an optional type.
    pub fn isDeclOptional(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .optional;
    }

    /// Check if a declaration has a pointer type.
    pub fn isDeclPointer(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .pointer;
    }

    /// Check if a declaration has an integer type (signed or unsigned).
    pub fn isDeclInteger(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .int or ti.kind == .uint;
    }

    /// Check if a declaration has a slice type.
    pub fn isDeclSlice(self: *TypeContext, name: []const u8) bool {
        const ti = self.getDeclType(name) orelse return false;
        return ti.kind == .slice;
    }

    // =========================================================================
    // Identifier Classification (for rules like identifier-style)
    // =========================================================================

    /// Classify an identifier as a type, function, constant, or variable.
    pub const IdentifierKind = enum {
        type_decl, // struct, enum, union, type alias
        function,
        constant,
        variable,
        unknown,
    };

    /// Classify an identifier by name.
    pub fn classifyIdentifier(self: *TypeContext, name: []const u8) IdentifierKind {
        const decl = self.getDecl(name) orelse return .unknown;

        if (decl.is_fn) return .function;

        switch (decl.type_info.kind) {
            .@"struct", .@"enum", .@"union", .type_type => return .type_decl,
            else => {},
        }

        if (decl.is_const) return .constant;
        return .variable;
    }

    /// Check if an identifier should use PascalCase (types).
    pub fn shouldBePascalCase(self: *TypeContext, name: []const u8) bool {
        return self.classifyIdentifier(name) == .type_decl;
    }

    /// Check if an identifier should use camelCase (functions, methods).
    pub fn shouldBeCamelCase(self: *TypeContext, name: []const u8) bool {
        return self.classifyIdentifier(name) == .function;
    }

    /// Check if an identifier should use snake_case (variables, constants).
    pub fn shouldBeSnakeCase(self: *TypeContext, name: []const u8) bool {
        const kind = self.classifyIdentifier(name);
        return kind == .constant or kind == .variable;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TypeContext basic creation" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expect(ctx.isAvailable());
}

test "TypeContext getDeclType" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    const ti = ctx.getDeclType("x");
    try std.testing.expect(ti != null);
    if (ti) |t| {
        try std.testing.expectEqual(TypeInfo.TypeKind.int, t.kind);
    }
}

test "TypeContext classifyIdentifier" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn myFunc() void {}
        \\const MY_CONST: i32 = 42;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expectEqual(TypeContext.IdentifierKind.function, ctx.classifyIdentifier("myFunc"));
    try std.testing.expectEqual(TypeContext.IdentifierKind.constant, ctx.classifyIdentifier("MY_CONST"));
    try std.testing.expectEqual(TypeContext.IdentifierKind.unknown, ctx.classifyIdentifier("nonexistent"));
}

test "TypeContext caseRecommendations" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\pub fn myFunc() void {}
        \\const MY_CONST: i32 = 42;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expect(ctx.shouldBeCamelCase("myFunc"));
    try std.testing.expect(!ctx.shouldBePascalCase("myFunc"));
    try std.testing.expect(ctx.shouldBeSnakeCase("MY_CONST"));
}

test "TypeContext nodeTypeCache" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    // Manually cache a type
    const ti = TypeInfo.initInt(64, false);
    ctx.cacheNodeType(100, ti);

    // Retrieve from cache
    const cached = ctx.getNodeType(100);
    try std.testing.expect(cached != null);
    if (cached) |c| {
        try std.testing.expectEqual(TypeInfo.TypeKind.uint, c.kind);
        try std.testing.expectEqual(@as(u16, 64), c.size_bits);
    }
}

test "TypeContext type kind queries" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\const int_val: i32 = 42;
        \\const ptr_val: *i32 = undefined;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    try std.testing.expect(ctx.isDeclInteger("int_val"));
    try std.testing.expect(!ctx.isDeclPointer("int_val"));
    try std.testing.expect(!ctx.isDeclOptional("int_val"));
}

test "TypeContext getExpressionType for call returning error union" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\fn mayFail() !i32 {
        \\    return 42;
        \\}
        \\fn caller() void {
        \\    const result = mayFail();
        \\    _ = result;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    // Find the call expression in the AST
    const tree = source.ast() catch unreachable;
    const tags = tree.nodes.items(.tag);

    var call_node: ?u32 = null;
    for (0..tags.len) |i| {
        if (tags[i] == .call or tags[i] == .call_one) {
            call_node = @intCast(i);
            break;
        }
    }

    try std.testing.expect(call_node != null);
    if (call_node) |cn| {
        const ti = ctx.getExpressionType(cn);
        try std.testing.expect(ti != null);
        if (ti) |t| {
            try std.testing.expectEqual(TypeInfo.TypeKind.error_union, t.kind);
        }
    }
}

test "TypeContext isExpressionErrorUnion" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\fn mayFail() !void {
        \\    return;
        \\}
        \\fn caller() void {
        \\    const x = mayFail();
        \\    _ = x;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    const tree = source.ast() catch unreachable;
    const tags = tree.nodes.items(.tag);

    var call_node: ?u32 = null;
    for (0..tags.len) |i| {
        if (tags[i] == .call or tags[i] == .call_one) {
            call_node = @intCast(i);
            break;
        }
    }

    try std.testing.expect(call_node != null);
    if (call_node) |cn| {
        try std.testing.expect(ctx.isExpressionErrorUnion(cn));
    }
}

test "TypeContext getContainingFunctionReturnType" {
    const allocator = std.testing.allocator;

    const code: [:0]const u8 =
        \\fn errorReturningFn() !i32 {
        \\    return 42;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var ctx = TypeContext.init(allocator, &source);
    defer ctx.deinit();

    const tree = source.ast() catch unreachable;
    const tags = tree.nodes.items(.tag);

    var fn_node: ?u32 = null;
    for (0..tags.len) |i| {
        if (tags[i] == .fn_decl) {
            fn_node = @intCast(i);
            break;
        }
    }

    try std.testing.expect(fn_node != null);
    if (fn_node) |fn_n| {
        const ti = ctx.getContainingFunctionReturnType(fn_n);
        try std.testing.expect(ti != null);
        if (ti) |t| {
            try std.testing.expectEqual(TypeInfo.TypeKind.error_union, t.kind);
        }
    }
}
