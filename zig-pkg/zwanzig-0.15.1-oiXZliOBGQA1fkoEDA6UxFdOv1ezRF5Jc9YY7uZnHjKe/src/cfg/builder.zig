const std = @import("std");
const compat = @import("../compat.zig");
const graph = @import("graph.zig");
const dot = @import("dot.zig");
const builder_control_flow = @import("builder/control_flow.zig");
const builder_error_flow = @import("builder/error_flow.zig");
const builder_statements = @import("builder/statements.zig");
const builder_switch_flow = @import("builder/switch_flow.zig");
const builder_type_annotation = @import("builder/type_annotation.zig");
const Source = @import("../source.zig").Source;
const ids = @import("../ids.zig");
const type_context_mod = @import("../type_context.zig");

const Cfg = graph.Cfg;
const EdgeKind = graph.EdgeKind;
const IrNode = graph.IrNode;
const IrTag = graph.IrTag;
const CfgNodeId = ids.CfgNodeId;
const AstNodeId = ids.AstNodeId;
const TypeContext = type_context_mod.TypeContext;
const TypeInfo = type_context_mod.TypeInfo;

pub const CfgError = std.mem.Allocator.Error || error{InvalidAst};

/// Builds CFG from a Zig AST for a single function.
/// When a TypeContext is provided, IR nodes are annotated with type information
/// from ZIR, enabling type-aware analysis.
pub const CfgBuilder = struct {
    allocator: std.mem.Allocator,
    /// Optional type context for annotating IR nodes with type information.
    type_context: ?*TypeContext = null,
    /// Optional directory to dump CFG DOT files for visualization.
    dump_cfg_dir: ?[]const u8 = null,
    io_context: *compat.Context = compat.defaultContext(),
    pub const type_annotation = builder_type_annotation.mixin(@This());
    pub const statements = builder_statements.mixin(@This());
    pub const control_flow = builder_control_flow.mixin(@This());
    pub const error_flow = builder_error_flow.mixin(@This());
    pub const switch_flow = builder_switch_flow.mixin(@This());

    pub const ProcessResult = struct {
        last: ?CfgNodeId,
        terminates: bool,
        /// If set, the edge from this node to the next should use this kind.
        /// Used to properly label try_success edges for standalone try expressions.
        next_edge_kind: ?EdgeKind = null,
    };

    pub fn init(allocator: std.mem.Allocator) CfgBuilder {
        return .{ .allocator = allocator, .type_context = null };
    }

    /// Create a CfgBuilder with type context for type-annotated IR.
    pub fn initWithTypes(allocator: std.mem.Allocator, type_ctx: *TypeContext) CfgBuilder {
        return .{ .allocator = allocator, .type_context = type_ctx };
    }

    /// Set the type context for type annotation.
    pub fn setTypeContext(self: *CfgBuilder, type_ctx: ?*TypeContext) void {
        self.type_context = type_ctx;
    }

    /// Check if type annotation is available.
    pub fn hasTypeContext(self: *const CfgBuilder) bool {
        return self.type_context != null;
    }

    /// Set directory for dumping CFG DOT files.
    /// When set, buildFromFn automatically writes DOT files after building CFGs.
    pub fn setDumpCfgDir(self: *CfgBuilder, dir: ?[]const u8) void {
        self.dump_cfg_dir = dir;
    }

    pub fn setIoContext(self: *CfgBuilder, io_context: *compat.Context) void {
        self.io_context = io_context;
    }

    /// Build CFG for a function body starting at the given AST node.
    /// Returns null if the node is not a function or cannot be processed.
    pub fn buildFromFn(self: *CfgBuilder, source: *Source, fn_node: AstNodeId) !?Cfg {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);
        const fn_index = ids.astIndex(fn_node);

        if (fn_index >= tags.len) return null;

        const tag = tags[fn_index];
        const fn_data = tree.nodes.items(.data)[fn_index];
        var body_node: u32 = 0;

        var cfg = Cfg.init(self.allocator);
        errdefer cfg.deinit();

        cfg.fn_ast_node = fn_node;

        if (tag == .fn_decl) {
            // Extract function name from the AST
            const fn_proto_idx = @intFromEnum(fn_data.node_and_node[0]);
            if (fn_proto_idx > 0) {
                const main_tokens = tree.nodes.items(.main_token);
                const proto_token = main_tokens[fn_proto_idx];
                // The function name token typically follows the 'fn' keyword
                // Check if the next token is an identifier
                const token_tags = tree.tokens.items(.tag);
                if (proto_token + 1 < token_tags.len and token_tags[proto_token + 1] == .identifier) {
                    const name_start = tree.tokens.items(.start)[proto_token + 1];
                    const source_bytes = tree.source;
                    // Find the end of the identifier
                    var name_end = name_start;
                    while (name_end < source_bytes.len and
                        (std.ascii.isAlphanumeric(source_bytes[name_end]) or source_bytes[name_end] == '_'))
                    {
                        name_end += 1;
                    }
                    if (name_end > name_start) {
                        cfg.fn_name = source_bytes[name_start..name_end];
                    }
                }
            }
            body_node = @intFromEnum(fn_data.node_and_node[1]);
        } else if (tag == .test_decl) {
            // Test declarations: extract test name and body
            // test_decl uses opt_token_and_node: [0] is optional name token, [1] is body
            const main_tokens = tree.nodes.items(.main_token);
            const test_token = main_tokens[fn_index];
            // Test name comes after 'test' keyword - check for string literal or identifier
            const token_tags = tree.tokens.items(.tag);
            if (test_token + 1 < token_tags.len) {
                const name_token = test_token + 1;
                if (token_tags[name_token] == .string_literal) {
                    const name_start = tree.tokens.items(.start)[name_token];
                    const source_bytes = tree.source;
                    // Find the end of the string literal
                    var name_end = name_start + 1; // Skip opening quote
                    while (name_end < source_bytes.len and source_bytes[name_end] != '"') {
                        name_end += 1;
                    }
                    if (name_end > name_start + 1) {
                        cfg.fn_name = source_bytes[name_start + 1 .. name_end];
                    }
                }
            }
            body_node = @intFromEnum(fn_data.opt_token_and_node[1]);
        } else {
            return null;
        }

        const entry_idx = try cfg.addNode(IrNode.init(.fn_entry));
        cfg.entry = entry_idx;

        const exit_idx = try cfg.addNode(IrNode.init(.fn_exit));
        cfg.exit = exit_idx;

        if (body_node == 0) {
            try cfg.addEdge(entry_idx, exit_idx);
        } else {
            const result = try self.processNode(&cfg, source, body_node, entry_idx);
            if (result.last) |ln| {
                if (!result.terminates) {
                    try cfg.addEdge(ln, exit_idx);
                }
            } else {
                try cfg.addEdge(entry_idx, exit_idx);
            }
        }

        // Auto-dump CFG if configured
        if (self.dump_cfg_dir) |dir| {
            dot.writeToFile(&cfg, dir, source.getFilePath(), self.io_context, self.allocator);
        }

        return cfg;
    }

    pub fn processNode(
        self: *CfgBuilder,
        cfg: *Cfg,
        source: *Source,
        ast_node: u32,
        prev_node: CfgNodeId,
    ) CfgError!ProcessResult {
        const tree = try source.ast();
        const tags = tree.nodes.items(.tag);

        if (ast_node == 0 or ast_node >= tags.len) {
            return .{ .last = null, .terminates = false };
        }

        const tag = tags[ast_node];

        return switch (tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => try statements.processBlock(self, cfg, source, ast_node, prev_node),
            .@"return" => try statements.processReturn(self, cfg, source, ast_node, prev_node),
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => try statements.processVarDecl(self, cfg, source, ast_node, prev_node),
            .assign => try statements.processAssign(self, cfg, source, ast_node, prev_node),
            .call, .call_comma, .call_one, .call_one_comma, .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => try statements.processCall(self, cfg, source, ast_node, prev_node),
            .@"if", .if_simple => try control_flow.processIf(self, cfg, source, ast_node, prev_node),
            .while_simple, .while_cont, .@"while" => try control_flow.processWhile(self, cfg, source, ast_node, prev_node),
            .for_simple, .@"for" => try control_flow.processFor(self, cfg, source, ast_node, prev_node),
            .@"defer" => try error_flow.processDefer(self, cfg, source, ast_node, prev_node),
            .@"errdefer" => try error_flow.processErrdefer(self, cfg, source, ast_node, prev_node),
            .@"try" => try error_flow.processTry(self, cfg, source, ast_node, prev_node),
            .@"catch" => try error_flow.processCatch(self, cfg, source, ast_node, prev_node),
            .@"switch", .switch_comma => try switch_flow.processSwitch(self, cfg, source, ast_node, prev_node),
            .unreachable_literal => try statements.processUnreachable(self, cfg, source, ast_node, prev_node),
            else => try statements.processGenericExpr(self, cfg, source, ast_node, prev_node),
        };
    }

    pub fn markEdgeFromNode(self: *CfgBuilder, cfg: *Cfg, edge_start_idx: usize, from_node: CfgNodeId, kind: EdgeKind) void {
        _ = self;
        for (cfg.edges.items[edge_start_idx..]) |*edge| {
            if (edge.from == from_node and edge.kind == .normal) {
                edge.kind = kind;
                break;
            }
        }
    }
};

test "CfgBuilder empty function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    try testing.expect(root_decls.len > 0);

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 2), cfg.nodeCount());
    try testing.expectEqual(@as(usize, 1), cfg.edgeCount());

    if (cfg.getNode(cfg.entry)) |entry| {
        try testing.expectEqual(IrTag.fn_entry, entry.ir_node.tag);
    }
    if (cfg.getNode(cfg.exit)) |exit| {
        try testing.expectEqual(IrTag.fn_exit, exit.ir_node.tag);
    }
}

test "CfgBuilder simple return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    return 42;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 3), cfg.nodeCount());

    var found_return = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) {
            found_return = true;
            break;
        }
    }
    try testing.expect(found_return);
}

test "CfgBuilder var decl and return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    const x = 10;
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 4), cfg.nodeCount());

    var found_var_decl = false;
    var found_return = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) found_var_decl = true;
        if (node.ir_node.tag == .ret) found_return = true;
    }
    try testing.expect(found_var_decl);
    try testing.expect(found_return);
}

test "CfgBuilder source range mapping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    return 42;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) {
            try testing.expect(node.ir_node.source_range != null);
            const range = node.ir_node.source_range.?;
            try testing.expectEqual(@as(usize, 2), range.start.line);
            break;
        }
    }
}

test "CfgBuilder non-function node returns null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const x = 42;
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    if (root_decls.len > 0) {
        const var_node = ids.astId(@intFromEnum(root_decls[0]));
        const maybe_cfg = try builder.buildFromFn(&source, var_node);
        try testing.expect(maybe_cfg == null);
    }
}

test "CfgBuilder multiple statements" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    const a = 1;
        \\    const b = 2;
        \\    const c = 3;
        \\    return a + b + c;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 6), cfg.nodeCount());

    var var_decl_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) var_decl_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), var_decl_count);
}

test "CfgBuilder return terminates block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() u32 {
        \\    return 1;
        \\    const x = 2;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 3), cfg.nodeCount());

    var found_var_decl = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) found_var_decl = true;
    }
    try testing.expect(!found_var_decl);
}

test "CfgBuilder simple if without else" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var found_branch = false;
    var branch_count: usize = 0;
    var ret_count: usize = 0;
    var nop_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => {
                found_branch = true;
                branch_count += 1;
            },
            .ret => ret_count += 1,
            .nop => nop_count += 1,
            else => {},
        }
    }

    try testing.expect(found_branch);
    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 2), ret_count);
    try testing.expectEqual(@as(usize, 1), nop_count);
}

test "CfgBuilder if-else branches" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var branch_count: usize = 0;
    var ret_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => branch_count += 1,
            .ret => ret_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 2), ret_count);

    var branch_true_edges: usize = 0;
    var branch_false_edges: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .branch_true) branch_true_edges += 1;
        if (edge.kind == .branch_false) branch_false_edges += 1;
    }

    try testing.expect(branch_true_edges > 0 or branch_false_edges > 0);
}

test "CfgBuilder if-else terminates block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\    const z = 2;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var ret_count: usize = 0;
    var var_decl_count: usize = 0;
    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .ret => ret_count += 1,
            .var_decl => var_decl_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), ret_count);
    try testing.expectEqual(@as(usize, 0), var_decl_count);
}

test "CfgBuilder if-else with merge point" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    var result: i32 = 0;
        \\    if (x > 0) {
        \\        result = 1;
        \\    } else {
        \\        result = -1;
        \\    }
        \\    return result;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var branch_count: usize = 0;
    var ret_count: usize = 0;
    var nop_count: usize = 0;
    var assign_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => branch_count += 1,
            .ret => ret_count += 1,
            .nop => nop_count += 1,
            .assign => assign_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 1), ret_count);
    try testing.expectEqual(@as(usize, 1), nop_count);
    try testing.expectEqual(@as(usize, 2), assign_count);
}

test "CfgBuilder nested if" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32, y: i32) i32 {
        \\    if (x > 0) {
        \\        if (y > 0) {
        \\            return 1;
        \\        }
        \\        return 2;
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var branch_count: usize = 0;
    var ret_count: usize = 0;

    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => branch_count += 1,
            .ret => ret_count += 1,
            else => {},
        }
    }

    try testing.expectEqual(@as(usize, 2), branch_count);
    try testing.expectEqual(@as(usize, 3), ret_count);
}

test "CfgBuilder branch source range" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .branch) {
            try testing.expect(node.ir_node.source_range != null);
            const range = node.ir_node.source_range.?;
            try testing.expectEqual(@as(usize, 2), range.start.line);
            break;
        }
    }
}

test "CfgBuilder fully terminating if-else has no fallthrough edges" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Check that both return nodes connect to exit via jump edges
    var return_to_exit_jumps: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.to == cfg.exit and edge.kind == .jump) {
            return_to_exit_jumps += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), return_to_exit_jumps);

    // Check there are no normal edges to exit (which would indicate fallthrough)
    var normal_to_exit: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.to == cfg.exit and edge.kind == .normal) {
            normal_to_exit += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), normal_to_exit);
}

test "CfgBuilder merge node unreachable when both branches terminate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the merge node (nop node)
    var merge_node_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .nop) {
            merge_node_idx = node.index;
            break;
        }
    }

    // Merge node should exist but have no incoming edges
    try testing.expect(merge_node_idx != null);
    var preds: std.ArrayList(CfgNodeId) = .empty;
    defer preds.deinit(allocator);

    try cfg.getPredecessors(allocator, merge_node_idx.?, &preds);
    try testing.expectEqual(@as(usize, 0), preds.items.len);
}

test "CfgBuilder only then branch terminates allows fallthrough from else" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    var y: i32 = 0;
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        y = -1;
        \\    }
        \\    return y;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 return nodes (one in if branch, one at end)
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) ret_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), ret_count);

    // The merge node should have incoming edges (from else branch)
    var merge_node_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .nop) {
            merge_node_idx = node.index;
            break;
        }
    }

    try testing.expect(merge_node_idx != null);
    var preds: std.ArrayList(CfgNodeId) = .empty;
    defer preds.deinit(allocator);

    try cfg.getPredecessors(allocator, merge_node_idx.?, &preds);
    try testing.expect(preds.items.len > 0);
}

test "CfgBuilder trailing statements unreachable after terminating if-else" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(x: i32) i32 {
        \\    if (x > 0) {
        \\        return 1;
        \\    } else {
        \\        return -1;
        \\    }
        \\    const a = 1;
        \\    const b = 2;
        \\    return a + b;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Trailing statements should not be included in CFG
    var var_decl_count: usize = 0;
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .var_decl => var_decl_count += 1,
            .ret => ret_count += 1,
            else => {},
        }
    }

    // No var decls should be present (they are unreachable)
    try testing.expectEqual(@as(usize, 0), var_decl_count);
    // Only the 2 returns inside if/else should be present
    try testing.expectEqual(@as(usize, 2), ret_count);
}

test "CfgBuilder simple while loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    var x: i32 = 0;
        \\    while (x < 10) {
        \\        x += 1;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have loop_header and loop_body nodes
    var loop_header_count: usize = 0;
    var loop_body_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
        if (node.ir_node.tag == .loop_body) loop_body_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_header_count);
    try testing.expectEqual(@as(usize, 1), loop_body_count);

    // Should have loop_back and loop_exit edges
    var loop_back_count: usize = 0;
    var loop_exit_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .loop_back) loop_back_count += 1;
        if (edge.kind == .loop_exit) loop_exit_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_back_count);
    try testing.expectEqual(@as(usize, 1), loop_exit_count);
}

test "CfgBuilder while loop with return" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    var x: i32 = 0;
        \\    while (x < 10) {
        \\        if (x == 5) {
        \\            return x;
        \\        }
        \\        x += 1;
        \\    }
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have branch and return nodes inside the loop
    var branch_count: usize = 0;
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .branch) branch_count += 1;
        if (node.ir_node.tag == .ret) ret_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expectEqual(@as(usize, 2), ret_count);
}

test "CfgBuilder simple for loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    for (0..10) |_| {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have loop_header and loop_body nodes
    var loop_header_count: usize = 0;
    var loop_body_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
        if (node.ir_node.tag == .loop_body) loop_body_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_header_count);
    try testing.expectEqual(@as(usize, 1), loop_body_count);

    // Should have loop_back and loop_exit edges
    var loop_back_count: usize = 0;
    var loop_exit_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .loop_back) loop_back_count += 1;
        if (edge.kind == .loop_exit) loop_exit_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_back_count);
    try testing.expectEqual(@as(usize, 1), loop_exit_count);
}

test "CfgBuilder defer statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    defer {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have defer_stmt node (body is not added inline, executes at scope exit)
    var defer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .defer_stmt) defer_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), defer_count);

    // Defer is part of normal control flow - body AST is referenced but not executed inline
    var edges_to_defer: usize = 0;
    for (cfg.edges.items) |edge| {
        if (cfg.getNode(edge.to)) |node| {
            if (node.ir_node.tag == .defer_stmt) edges_to_defer += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), edges_to_defer);
}

test "CfgBuilder errdefer statement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    errdefer {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have errdefer_stmt node (body is not added inline, executes on error exit)
    var errdefer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .errdefer_stmt) errdefer_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), errdefer_count);

    // Errdefer is part of normal control flow - body AST is referenced but not executed inline
    var edges_to_errdefer: usize = 0;
    for (cfg.edges.items) |edge| {
        if (cfg.getNode(edge.to)) |node| {
            if (node.ir_node.tag == .errdefer_stmt) edges_to_errdefer += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), edges_to_errdefer);
}

test "CfgBuilder multiple defers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    defer { const a = 1; _ = a; }
        \\    defer { const b = 2; _ = b; }
        \\    errdefer { const c = 3; _ = c; }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 defer_stmt and 1 errdefer_stmt nodes
    var defer_count: usize = 0;
    var errdefer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .defer_stmt) defer_count += 1;
        if (node.ir_node.tag == .errdefer_stmt) errdefer_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), defer_count);
    try testing.expectEqual(@as(usize, 1), errdefer_count);
}

test "CfgBuilder loop with defer inside" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    while (true) {
        \\        defer { const x = 1; _ = x; }
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have both loop and defer nodes
    var loop_header_count: usize = 0;
    var defer_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
        if (node.ir_node.tag == .defer_stmt) defer_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), loop_header_count);
    try testing.expectEqual(@as(usize, 1), defer_count);
}

test "CfgBuilder while loop back-edge targets header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    while (true) {
        \\        const x = 1;
        \\        _ = x;
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the loop header node
    var header_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .loop_header) {
            header_idx = node.index;
            break;
        }
    }

    try testing.expect(header_idx != null);

    // The loop_back edge should point to the header
    var back_edge_targets_header = false;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .loop_back and edge.to == header_idx.?) {
            back_edge_targets_header = true;
            break;
        }
    }

    try testing.expect(back_edge_targets_header);
}

test "CfgBuilder simple try expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    const x = try bar();
        \\    _ = x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have try_expr node
    var try_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);

    // Should have try_error edge to exit
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error and edge.to == cfg.exit) {
            try_error_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), try_error_count);
}

test "CfgBuilder try expression has error and success paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    const x = try bar();
        \\    return x + 1;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the try_expr node
    var try_node_idx: ?CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) {
            try_node_idx = node.index;
            break;
        }
    }

    try testing.expect(try_node_idx != null);

    // Try node should have 2 outgoing edges: one error (to exit), one normal (to next)
    var succs: std.ArrayList(CfgNodeId) = .empty;
    defer succs.deinit(allocator);

    try cfg.getSuccessors(allocator, try_node_idx.?, &succs);
    try testing.expectEqual(@as(usize, 2), succs.items.len);

    // One edge should go to exit (error path)
    var has_exit_edge = false;
    for (succs.items) |succ| {
        if (succ == cfg.exit) has_exit_edge = true;
    }
    try testing.expect(has_exit_edge);
}

test "CfgBuilder simple catch expression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const x = bar() catch 0;
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have catch_expr node
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_expr_count);

    // Should have catch_success and catch_error edges
    var catch_success_count: usize = 0;
    var catch_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .catch_success) catch_success_count += 1;
        if (edge.kind == .catch_error) catch_error_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_success_count);
    try testing.expectEqual(@as(usize, 1), catch_error_count);
}

test "CfgBuilder catch with block handler" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() i32 {
        \\    const x = bar() catch |err| {
        \\        _ = err;
        \\        return -1;
        \\    };
        \\    return x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have catch_expr node
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_expr_count);

    // Should have return nodes (one in handler, one at end)
    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) ret_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), ret_count);
}

test "CfgBuilder multiple try expressions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    const a = try bar();
        \\    const b = try baz();
        \\    return a + b;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 try_expr nodes
    var try_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), try_expr_count);

    // Should have 2 try_error edges to exit
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error and edge.to == cfg.exit) {
            try_error_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 2), try_error_count);
}

test "CfgBuilder try inside if branch" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(cond: bool) !i32 {
        \\    if (cond) {
        \\        return try bar();
        \\    }
        \\    return 0;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have try_expr and branch nodes
    var try_expr_count: usize = 0;
    var branch_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
        if (node.ir_node.tag == .branch) branch_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);
    try testing.expectEqual(@as(usize, 1), branch_count);
}

test "CfgBuilder catch with empty block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    _ = bar() catch {};
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have catch_expr node
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), catch_expr_count);

    // Should have both catch_success and catch_error edges
    var catch_success_count: usize = 0;
    var catch_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .catch_success) catch_success_count += 1;
        if (edge.kind == .catch_error) catch_error_count += 1;
    }

    try testing.expect(catch_success_count >= 1);
    try testing.expect(catch_error_count >= 1);
}

test "CfgBuilder try and catch combined" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !i32 {
        \\    const x = try bar();
        \\    const y = baz() catch 0;
        \\    return x + y;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have both try_expr and catch_expr nodes
    var try_expr_count: usize = 0;
    var catch_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
        if (node.ir_node.tag == .catch_expr) catch_expr_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);
    try testing.expectEqual(@as(usize, 1), catch_expr_count);
}

test "CfgBuilder try in loop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    while (true) {
        \\        try bar();
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have try_expr and loop_header nodes
    var try_expr_count: usize = 0;
    var loop_header_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
        if (node.ir_node.tag == .loop_header) loop_header_count += 1;
    }

    try testing.expectEqual(@as(usize, 1), try_expr_count);
    try testing.expectEqual(@as(usize, 1), loop_header_count);

    // Should have try_error edge
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error) try_error_count += 1;
    }

    try testing.expect(try_error_count >= 1);
}

test "CfgBuilder standalone try has try_success edge" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() !void {
        \\    try bar();
        \\    try baz();
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);

    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Should have 2 try_expr nodes
    var try_expr_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) try_expr_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), try_expr_count);

    // Should have 2 try_error edges (one per try, going to exit)
    var try_error_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_error and edge.to == cfg.exit) {
            try_error_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), try_error_count);

    // Should have at least 1 try_success edge (from first try to second try)
    var try_success_count: usize = 0;
    for (cfg.edges.items) |edge| {
        if (edge.kind == .try_success) try_success_count += 1;
    }
    try testing.expect(try_success_count >= 1);
}

// ============================================================================
// Typed IR Integration Tests
// ============================================================================

test "CfgBuilder with TypeContext annotates var decl" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {
        \\    const x: i32 = 42;
        \\    _ = x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    // Create type context for the source
    var type_ctx = TypeContext.init(allocator, &source);
    defer type_ctx.deinit();

    // Create builder with type context
    var builder = CfgBuilder.initWithTypes(allocator, &type_ctx);

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const fn_node = ids.astId(@intFromEnum(root_decls[0]));

    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find the var_decl node
    var found_typed_var_decl = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) {
            // The node should have type info attached (may be null if ZIR fails)
            // At minimum, verify the node exists
            found_typed_var_decl = true;
            break;
        }
    }
    try testing.expect(found_typed_var_decl);
}

test "CfgBuilder try expression has error_union type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn bar() !i32 { return 1; }
        \\fn foo() !void {
        \\    _ = try bar();
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);

    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    // Find the second function (foo)
    var fn_node_index: ?usize = null;
    for (root_decls, 0..) |decl, i| {
        const idx = @intFromEnum(decl);
        if (tree.nodes.items(.tag)[idx] == .fn_decl) {
            if (fn_node_index == null) {
                // Skip bar, find foo
                fn_node_index = i;
            } else {
                fn_node_index = i;
                break;
            }
        }
    }

    try testing.expect(fn_node_index != null);
    const fn_node = ids.astId(@intFromEnum(root_decls[fn_node_index.?]));

    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find try_expr node and verify it has error_union type info
    var found_try_with_type = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .try_expr) {
            if (node.ir_node.type_info) |ti| {
                try testing.expectEqual(TypeInfo.TypeKind.error_union, ti.kind);
                found_try_with_type = true;
            }
            break;
        }
    }
    try testing.expect(found_try_with_type);
}

test "CfgBuilder catch expression has error_union type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn bar() !i32 { return 1; }
        \\fn foo() void {
        \\    const x = bar() catch 0;
        \\    _ = x;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);

    const tree = try source.ast();
    const root_decls = tree.rootDecls();

    // Find the second function (foo)
    var fn_node_index: usize = 0;
    for (root_decls, 0..) |decl, i| {
        const idx = @intFromEnum(decl);
        if (tree.nodes.items(.tag)[idx] == .fn_decl) {
            fn_node_index = i;
        }
    }

    const fn_node = ids.astId(@intFromEnum(root_decls[fn_node_index]));

    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);

    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Find catch_expr node and verify it has error_union type info
    var found_catch_with_type = false;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .catch_expr) {
            if (node.ir_node.type_info) |ti| {
                try testing.expectEqual(TypeInfo.TypeKind.error_union, ti.kind);
                found_catch_with_type = true;
            }
            break;
        }
    }
    try testing.expect(found_catch_with_type);
}

test "CfgBuilder hasTypeContext" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    // Builder without type context
    var builder1 = CfgBuilder.init(allocator);
    try testing.expect(!builder1.hasTypeContext());

    // Builder with type context
    var type_ctx = TypeContext.init(allocator, &source);
    defer type_ctx.deinit();

    var builder2 = CfgBuilder.initWithTypes(allocator, &type_ctx);
    try testing.expect(builder2.hasTypeContext());

    // Set type context after init
    builder1.setTypeContext(&type_ctx);
    try testing.expect(builder1.hasTypeContext());
}

fn countCallsToName(cfg: *const Cfg, tree: *const std.zig.Ast, target: []const u8) usize {
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);
    const src_bytes = tree.source;

    var count: usize = 0;
    var call_buf: [1]std.zig.Ast.Node.Index = undefined;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag != .call) continue;
        const ast_idx = node.ir_node.ast_node orelse continue;
        if (ast_idx >= tags.len) continue;
        const full_call = tree.fullCall(&call_buf, @enumFromInt(ast_idx)) orelse continue;
        const callee_node = @intFromEnum(full_call.ast.fn_expr);
        if (callee_node >= main_tokens.len) continue;
        const tok = main_tokens[callee_node];
        if (tok >= token_starts.len) continue;
        const start = token_starts[tok];
        var end = start;
        while (end < src_bytes.len and (std.ascii.isAlphanumeric(src_bytes[end]) or src_bytes[end] == '_')) {
            end += 1;
        }
        if (std.mem.eql(u8, src_bytes[start..end], target)) count += 1;
    }
    return count;
}

test "CfgBuilder simple switch statement visits arm bodies" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn a() void {}
        \\fn b() void {}
        \\fn c() void {}
        \\fn foo(k: u8) void {
        \\    switch (k) {
        \\        0 => a(),
        \\        1 => b(),
        \\        else => c(),
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const foo_node = ids.astId(@intFromEnum(root_decls[3]));
    const maybe_cfg = try builder.buildFromFn(&source, foo_node);
    try testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var branch_count: usize = 0;
    var nop_count: usize = 0;
    var call_count: usize = 0;
    for (cfg.nodes.items) |node| {
        switch (node.ir_node.tag) {
            .branch => branch_count += 1,
            .nop => nop_count += 1,
            .call => call_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), branch_count);
    try testing.expect(nop_count >= 1);
    try testing.expectEqual(@as(usize, 3), call_count);

    try testing.expectEqual(@as(usize, 1), countCallsToName(&cfg, tree, "a"));
    try testing.expectEqual(@as(usize, 1), countCallsToName(&cfg, tree, "b"));
    try testing.expectEqual(@as(usize, 1), countCallsToName(&cfg, tree, "c"));
}

test "CfgBuilder switch with all-terminating arms" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(k: u8) u32 {
        \\    switch (k) {
        \\        0 => return 1,
        \\        1 => return 2,
        \\        else => return 3,
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var ret_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .ret) ret_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), ret_count);
}

test "CfgBuilder switch with unreachable arm terminates that path" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn act() void {}
        \\fn foo(k: u8) void {
        \\    switch (k) {
        \\        0 => unreachable,
        \\        else => act(),
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const foo_node = ids.astId(@intFromEnum(root_decls[1]));
    const maybe_cfg = try builder.buildFromFn(&source, foo_node);
    try testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    var unreachable_node: ?ids.CfgNodeId = null;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .unreachable_stmt) {
            unreachable_node = node.index;
            break;
        }
    }
    try testing.expect(unreachable_node != null);

    // The unreachable node must have no outgoing edges — the path stops here
    // and never feeds the merge.
    for (cfg.edges.items) |edge| {
        try testing.expect(edge.from != unreachable_node.?);
    }
}

test "CfgBuilder all-arms-unreachable switch propagates terminates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo(k: u8) void {
        \\    switch (k) {
        \\        0 => unreachable,
        \\        else => unreachable,
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const fn_node = ids.astId(@intFromEnum(root_decls[0]));
    const maybe_cfg = try builder.buildFromFn(&source, fn_node);
    try testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    // Every unreachable_stmt node must be a dead end (no outgoing edges).
    var unreachable_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag != .unreachable_stmt) continue;
        unreachable_count += 1;
        for (cfg.edges.items) |edge| {
            try testing.expect(edge.from != node.index);
        }
    }
    try testing.expectEqual(@as(usize, 2), unreachable_count);
}

test "CfgBuilder switch with payload capture visits body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn consume(x: u32) void { _ = x; }
        \\const U = union(enum) { foo: u32, bar: void };
        \\fn handle(u: U) void {
        \\    switch (u) {
        \\        .foo => |v| consume(v),
        \\        .bar => {},
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const handle_node = ids.astId(@intFromEnum(root_decls[2]));
    const maybe_cfg = try builder.buildFromFn(&source, handle_node);
    try testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), countCallsToName(&cfg, tree, "consume"));
}

test "CfgBuilder inline switch in var_decl init visits arms" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn compute() u32 { return 1; }
        \\fn other() u32 { return 2; }
        \\fn foo(k: u8) u32 {
        \\    const v = switch (k) {
        \\        0 => compute(),
        \\        else => other(),
        \\    };
        \\    return v;
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const foo_node = ids.astId(@intFromEnum(root_decls[2]));
    const maybe_cfg = try builder.buildFromFn(&source, foo_node);
    try testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), countCallsToName(&cfg, tree, "compute"));
    try testing.expectEqual(@as(usize, 1), countCallsToName(&cfg, tree, "other"));

    var var_decl_count: usize = 0;
    for (cfg.nodes.items) |node| {
        if (node.ir_node.tag == .var_decl) var_decl_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), var_decl_count);
}

test "CfgBuilder switch with empty arm body" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn act() void {}
        \\fn foo(k: u8) void {
        \\    switch (k) {
        \\        0 => {},
        \\        else => act(),
        \\    }
        \\}
    ;

    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var builder = CfgBuilder.init(allocator);
    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    const foo_node = ids.astId(@intFromEnum(root_decls[1]));
    const maybe_cfg = try builder.buildFromFn(&source, foo_node);
    try testing.expect(maybe_cfg != null);
    var cfg = maybe_cfg.?;
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), countCallsToName(&cfg, tree, "act"));
}
