const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const zir_bridge = @import("zir_bridge.zig");

pub const SourceRange = diagnostic.SourceRange;
pub const Location = diagnostic.Location;
pub const TypeInfo = zir_bridge.TypeInfo;

/// IR node tags representing different kinds of statements and expressions.
/// This is a minimal IR designed for control-flow analysis.
pub const IrTag = enum {
    /// Function entry point
    fn_entry,
    /// Function exit point (normal return path)
    fn_exit,
    /// Return statement
    ret,
    /// Variable declaration (const/var)
    var_decl,
    /// Assignment expression
    assign,
    /// Function call expression
    call,
    /// Block of statements
    block,
    /// Generic expression that doesn't fit other categories
    expr,
    /// No-op placeholder for control flow merge points
    nop,
    /// Branch condition evaluation (if/else)
    branch,
    /// While loop header (condition evaluation)
    loop_header,
    /// Loop body entry point
    loop_body,
    /// Defer statement body
    defer_stmt,
    /// Errdefer statement body
    errdefer_stmt,
    /// Try expression - propagates errors to caller
    try_expr,
    /// Catch expression - handles errors locally
    catch_expr,
    /// `unreachable` literal — terminates the current path
    unreachable_stmt,
};

/// A single IR node representing a statement or expression.
/// IR nodes are lightweight references that map back to AST nodes
/// and source locations. When ZIR is available, type information
/// is attached to enable type-aware analysis.
pub const IrNode = struct {
    /// The kind of IR node
    tag: IrTag,
    /// Index of the corresponding AST node (if any)
    ast_node: ?u32,
    /// Source range for diagnostic reporting
    source_range: ?SourceRange,
    /// Additional operand node for tags that need it (e.g., LHS of assign, RHS value)
    operand_node: ?u32,
    /// Second operand for tags that need two (e.g., RHS of assign)
    operand2_node: ?u32,
    /// Type information from ZIR (when available)
    type_info: ?TypeInfo,

    pub fn init(tag: IrTag) IrNode {
        return .{
            .tag = tag,
            .ast_node = null,
            .source_range = null,
            .operand_node = null,
            .operand2_node = null,
            .type_info = null,
        };
    }

    pub fn initWithAst(tag: IrTag, ast_node: u32) IrNode {
        return .{
            .tag = tag,
            .ast_node = ast_node,
            .source_range = null,
            .operand_node = null,
            .operand2_node = null,
            .type_info = null,
        };
    }

    pub fn initWithRange(tag: IrTag, range: SourceRange) IrNode {
        return .{
            .tag = tag,
            .ast_node = null,
            .source_range = range,
            .operand_node = null,
            .operand2_node = null,
            .type_info = null,
        };
    }

    pub fn initFull(tag: IrTag, ast_node: u32, range: SourceRange) IrNode {
        return .{
            .tag = tag,
            .ast_node = ast_node,
            .source_range = range,
            .operand_node = null,
            .operand2_node = null,
            .type_info = null,
        };
    }

    pub fn initAssign(ast_node: u32, lhs_node: u32, rhs_node: u32, range: SourceRange) IrNode {
        return .{
            .tag = .assign,
            .ast_node = ast_node,
            .source_range = range,
            .operand_node = lhs_node,
            .operand2_node = rhs_node,
            .type_info = null,
        };
    }

    /// Create an IR node with type information attached.
    pub fn initTyped(tag: IrTag, ast_node: u32, range: SourceRange, ti: TypeInfo) IrNode {
        return .{
            .tag = tag,
            .ast_node = ast_node,
            .source_range = range,
            .operand_node = null,
            .operand2_node = null,
            .type_info = ti,
        };
    }

    /// Attach type information to an existing IR node.
    pub fn withType(self: IrNode, ti: TypeInfo) IrNode {
        var node = self;
        node.type_info = ti;
        return node;
    }

    /// Check if this node has type information.
    pub fn hasType(self: *const IrNode) bool {
        return self.type_info != null;
    }

    /// Get the type kind if available.
    pub fn getTypeKind(self: *const IrNode) ?TypeInfo.TypeKind {
        if (self.type_info) |ti| {
            return ti.kind;
        }
        return null;
    }

    /// Check if this node has an error union type.
    pub fn isErrorUnion(self: *const IrNode) bool {
        if (self.type_info) |ti| {
            return ti.kind == .error_union;
        }
        return false;
    }

    /// Check if this node has an optional type.
    pub fn isOptional(self: *const IrNode) bool {
        if (self.type_info) |ti| {
            return ti.kind == .optional;
        }
        return false;
    }

    /// Check if this node has a pointer type.
    pub fn isPointer(self: *const IrNode) bool {
        if (self.type_info) |ti| {
            return ti.kind == .pointer;
        }
        return false;
    }

    /// Check if this node has an integer type.
    pub fn isInteger(self: *const IrNode) bool {
        if (self.type_info) |ti| {
            return ti.kind == .int or ti.kind == .uint;
        }
        return false;
    }
};

test "IrNode initialization" {
    const testing = std.testing;

    const node1 = IrNode.init(.fn_entry);
    try testing.expectEqual(IrTag.fn_entry, node1.tag);
    try testing.expect(node1.ast_node == null);
    try testing.expect(node1.source_range == null);
    try testing.expect(node1.type_info == null);

    const node2 = IrNode.initWithAst(.var_decl, 42);
    try testing.expectEqual(IrTag.var_decl, node2.tag);
    try testing.expectEqual(@as(u32, 42), node2.ast_node.?);
    try testing.expect(node2.source_range == null);
    try testing.expect(node2.type_info == null);

    const range = SourceRange.init(Location.init(1, 5), Location.init(1, 10));
    const node3 = IrNode.initFull(.ret, 10, range);
    try testing.expectEqual(IrTag.ret, node3.tag);
    try testing.expectEqual(@as(u32, 10), node3.ast_node.?);
    try testing.expectEqual(@as(usize, 1), node3.source_range.?.start.line);
    try testing.expectEqual(@as(usize, 5), node3.source_range.?.start.column);
    try testing.expect(node3.type_info == null);
}

test "IrNode with type info" {
    const testing = std.testing;

    const range = SourceRange.init(Location.init(1, 1), Location.init(1, 10));
    const ti = TypeInfo.initInt(32, true);

    // Test initTyped
    const typed_node = IrNode.initTyped(.var_decl, 5, range, ti);
    try testing.expectEqual(IrTag.var_decl, typed_node.tag);
    try testing.expect(typed_node.hasType());
    try testing.expectEqual(TypeInfo.TypeKind.int, typed_node.getTypeKind().?);
    try testing.expect(typed_node.isInteger());
    try testing.expect(!typed_node.isPointer());
    try testing.expect(!typed_node.isOptional());
    try testing.expect(!typed_node.isErrorUnion());

    // Test withType
    const basic_node = IrNode.init(.expr);
    const enriched = basic_node.withType(TypeInfo.initPointer());
    try testing.expect(enriched.hasType());
    try testing.expect(enriched.isPointer());
    try testing.expect(!enriched.isInteger());

    // Test error union detection
    const err_node = IrNode.init(.call).withType(TypeInfo.initErrorUnion());
    try testing.expect(err_node.isErrorUnion());

    // Test optional detection
    const opt_node = IrNode.init(.expr).withType(TypeInfo.initOptional());
    try testing.expect(opt_node.isOptional());
}
