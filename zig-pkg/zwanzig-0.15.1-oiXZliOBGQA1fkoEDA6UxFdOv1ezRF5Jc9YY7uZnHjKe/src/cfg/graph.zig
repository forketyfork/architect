const std = @import("std");
const ir = @import("../ir.zig");
const diagnostic = @import("../diagnostic.zig");
const ids = @import("../ids.zig");

pub const IrNode = ir.IrNode;
pub const IrTag = ir.IrTag;
pub const SourceRange = diagnostic.SourceRange;
pub const Location = diagnostic.Location;
pub const CfgNodeId = ids.CfgNodeId;
pub const AstNodeId = ids.AstNodeId;

/// Edge kind for CFG edges.
pub const EdgeKind = enum {
    /// Normal sequential control flow
    normal,
    /// Unconditional jump (e.g., from return)
    jump,
    /// Branch taken when condition is true
    branch_true,
    /// Branch taken when condition is false
    branch_false,
    /// Loop back-edge (from loop body back to condition)
    loop_back,
    /// Loop exit edge (when condition is false)
    loop_exit,
    /// Defer execution edge (before return/exit)
    defer_edge,
    /// Errdefer execution edge (on error path)
    errdefer_edge,
    /// Error path from try expression (propagates to caller)
    try_error,
    /// Success path from try expression (continues normally)
    try_success,
    /// Error path into catch block
    catch_error,
    /// Success path from catch (after handling error)
    catch_success,
};

/// An edge in the control-flow graph.
pub const CfgEdge = struct {
    /// Source node index
    from: CfgNodeId,
    /// Destination node index
    to: CfgNodeId,
    /// Kind of edge
    kind: EdgeKind,

    pub fn init(from: CfgNodeId, to: CfgNodeId) CfgEdge {
        return .{
            .from = from,
            .to = to,
            .kind = .normal,
        };
    }

    pub fn initWithKind(from: CfgNodeId, to: CfgNodeId, kind: EdgeKind) CfgEdge {
        return .{
            .from = from,
            .to = to,
            .kind = kind,
        };
    }
};

/// A node in the control-flow graph.
pub const CfgNode = struct {
    /// The IR node at this CFG point
    ir_node: IrNode,
    /// Unique index of this node in the CFG
    index: CfgNodeId,
};

/// A control-flow graph for a single function.
pub const Cfg = struct {
    allocator: std.mem.Allocator,
    /// All nodes in the CFG
    nodes: std.ArrayList(CfgNode),
    /// All edges in the CFG
    edges: std.ArrayList(CfgEdge),
    /// Index of the entry node (always 0)
    entry: CfgNodeId,
    /// Index of the exit node
    exit: CfgNodeId,
    /// Function name (if available)
    fn_name: ?[]const u8,
    /// AST node index of the function
    fn_ast_node: ?AstNodeId,

    pub fn init(allocator: std.mem.Allocator) Cfg {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .edges = .empty,
            .entry = ids.cfgId(0),
            .exit = ids.cfgId(0),
            .fn_name = null,
            .fn_ast_node = null,
        };
    }

    pub fn deinit(self: *Cfg) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
    }

    pub fn addNode(self: *Cfg, ir_node: IrNode) !CfgNodeId {
        const index = ids.cfgId(@intCast(self.nodes.items.len));
        try self.nodes.append(self.allocator, .{
            .ir_node = ir_node,
            .index = index,
        });
        return index;
    }

    pub fn addEdge(self: *Cfg, from: CfgNodeId, to: CfgNodeId) !void {
        try self.edges.append(self.allocator, CfgEdge.init(from, to));
    }

    pub fn addEdgeWithKind(self: *Cfg, from: CfgNodeId, to: CfgNodeId, kind: EdgeKind) !void {
        try self.edges.append(self.allocator, CfgEdge.initWithKind(from, to, kind));
    }

    pub fn nodeCount(self: *const Cfg) usize {
        return self.nodes.items.len;
    }

    pub fn edgeCount(self: *const Cfg) usize {
        return self.edges.items.len;
    }

    pub fn getNode(self: *const Cfg, index: CfgNodeId) ?*const CfgNode {
        const idx: usize = @intCast(ids.cfgIndex(index));
        if (idx >= self.nodes.items.len) return null;
        return &self.nodes.items[idx];
    }

    pub fn getSuccessors(self: *const Cfg, allocator: std.mem.Allocator, node_index: CfgNodeId, result: *std.ArrayList(CfgNodeId)) !void {
        for (self.edges.items) |edge| {
            if (edge.from == node_index) {
                try result.append(allocator, edge.to);
            }
        }
    }

    pub fn getPredecessors(self: *const Cfg, allocator: std.mem.Allocator, node_index: CfgNodeId, result: *std.ArrayList(CfgNodeId)) !void {
        for (self.edges.items) |edge| {
            if (edge.to == node_index) {
                try result.append(allocator, edge.from);
            }
        }
    }
};

test "Cfg basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    try testing.expectEqual(ids.cfgId(0), entry);
    try testing.expectEqual(@as(usize, 1), cfg.nodeCount());

    const exit = try cfg.addNode(IrNode.init(.fn_exit));
    try testing.expectEqual(ids.cfgId(1), exit);

    try cfg.addEdge(entry, exit);
    try testing.expectEqual(@as(usize, 1), cfg.edgeCount());

    if (cfg.getNode(entry)) |node| {
        try testing.expectEqual(IrTag.fn_entry, node.ir_node.tag);
    } else {
        return error.TestExpectedEqual;
    }
}

test "Cfg successors and predecessors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    const n0 = try cfg.addNode(IrNode.init(.fn_entry));
    const n1 = try cfg.addNode(IrNode.init(.var_decl));
    const n2 = try cfg.addNode(IrNode.init(.fn_exit));

    try cfg.addEdge(n0, n1);
    try cfg.addEdge(n1, n2);

    var succs: std.ArrayList(CfgNodeId) = .empty;
    defer succs.deinit(allocator);

    try cfg.getSuccessors(allocator, n0, &succs);
    try testing.expectEqual(@as(usize, 1), succs.items.len);
    try testing.expectEqual(n1, succs.items[0]);

    succs.clearRetainingCapacity();
    try cfg.getSuccessors(allocator, n1, &succs);
    try testing.expectEqual(@as(usize, 1), succs.items.len);
    try testing.expectEqual(n2, succs.items[0]);

    var preds: std.ArrayList(CfgNodeId) = .empty;
    defer preds.deinit(allocator);

    try cfg.getPredecessors(allocator, n2, &preds);
    try testing.expectEqual(@as(usize, 1), preds.items.len);
    try testing.expectEqual(n1, preds.items[0]);
}
