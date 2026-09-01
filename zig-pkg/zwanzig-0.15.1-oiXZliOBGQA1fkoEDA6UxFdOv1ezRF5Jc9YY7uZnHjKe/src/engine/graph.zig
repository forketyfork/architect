const std = @import("std");
const cfg_mod = @import("../cfg.zig");
const ids = @import("../ids.zig");
const Cfg = cfg_mod.Cfg;
const IrNode = cfg_mod.IrNode;
const EngineError = @import("base.zig").EngineError;
const state_mod = @import("state.zig");
const ProgramPoint = state_mod.ProgramPoint;
const ProgramState = state_mod.ProgramState;
const WideningKey = state_mod.WideningKey;

/// Default maximum number of unique states per program point.
/// Beyond this, new states at the same point are widened into an existing node
/// with the same calling context (widening approximation).
const default_max_states_per_point: u32 = 50;

/// A node in the exploded graph, keyed by (ProgramPoint, ProgramState).
pub const ExplodedNode = struct {
    /// The program point (CFG location)
    point: ProgramPoint,
    /// The abstract program state at this point
    state: ProgramState,
    /// Unique index of this node in the exploded graph
    index: u32,
    /// Indices of predecessor nodes in the exploded graph
    predecessors: std.ArrayList(u32),
    /// Indices of successor nodes in the exploded graph
    successors: std.ArrayList(u32),

    pub fn init(point: ProgramPoint, state: ProgramState, index: u32) ExplodedNode {
        return .{
            .point = point,
            .state = state,
            .index = index,
            .predecessors = .empty,
            .successors = .empty,
        };
    }

    pub fn deinit(self: *ExplodedNode, allocator: std.mem.Allocator) void {
        self.state.deinit();
        self.predecessors.deinit(allocator);
        self.successors.deinit(allocator);
    }

    /// Compute a combined hash for point and state (used for deduplication)
    pub fn computeKey(point: ProgramPoint, state: *ProgramState) u64 {
        var hasher = std.hash.Wyhash.init(0);
        // Include CFG identity to prevent collisions across different CFGs
        // during interprocedural analysis
        hasher.update(std.mem.asBytes(&@intFromPtr(point.cfg)));
        const node_index = ids.cfgIndex(point.node_index);
        hasher.update(std.mem.asBytes(&node_index));
        hasher.update(std.mem.asBytes(&point.kind));
        const state_hash = state.computeHash();
        hasher.update(std.mem.asBytes(&state_hash));
        return hasher.final();
    }
};

/// The exploded graph: a representation of all reachable (ProgramPoint, ProgramState) pairs.
/// This is the core data structure for path-sensitive analysis.
pub const ExplodedGraph = struct {
    allocator: std.mem.Allocator,
    /// All nodes in the exploded graph
    nodes: std.ArrayList(ExplodedNode),
    /// Map from (point, state) hash to node index for deduplication
    /// Hash collisions are possible; we accept the small risk as a pragmatic
    /// tradeoff for memory and performance.
    node_map: std.AutoHashMap(u64, u32),
    /// Reference to the CFG being analyzed
    cfg: *const Cfg,
    /// Count of states per program point (for widening)
    point_state_counts: std.AutoHashMap(u64, u32),
    /// Node indices per program point (for subsumption and cap widening)
    point_nodes: std.AutoHashMap(u64, std.ArrayList(u32)),
    /// Maximum number of unique states per program point before cap widening
    max_states_per_point: u32,
    /// Stored states at widening points (keyed by WideningKey)
    widening_states: std.HashMap(WideningKey, ProgramState, WideningKey.HashContext, std.hash_map.default_max_load_percentage),
    /// Visit count at widening points for delayed widening (keyed by WideningKey)
    widening_visits: std.HashMap(WideningKey, u32, WideningKey.HashContext, std.hash_map.default_max_load_percentage),
    /// Count of nodes created after widening
    widened_nodes: u32,
    /// Count of times widening converged (widened state equals previous)
    widening_converged: u32,

    pub fn init(allocator: std.mem.Allocator, cfg: *const Cfg) ExplodedGraph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .node_map = std.AutoHashMap(u64, u32).init(allocator),
            .cfg = cfg,
            .point_state_counts = std.AutoHashMap(u64, u32).init(allocator),
            .point_nodes = std.AutoHashMap(u64, std.ArrayList(u32)).init(allocator),
            .max_states_per_point = default_max_states_per_point,
            .widening_states = std.HashMap(WideningKey, ProgramState, WideningKey.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .widening_visits = std.HashMap(WideningKey, u32, WideningKey.HashContext, std.hash_map.default_max_load_percentage).init(allocator),
            .widened_nodes = 0,
            .widening_converged = 0,
        };
    }

    pub fn deinit(self: *ExplodedGraph) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.node_map.deinit();
        self.point_state_counts.deinit();
        var point_iter = self.point_nodes.valueIterator();
        while (point_iter.next()) |list_ptr| {
            list_ptr.deinit(self.allocator);
        }
        self.point_nodes.deinit();
        // Deinit stored widening states
        var it = self.widening_states.valueIterator();
        while (it.next()) |state_ptr| {
            state_ptr.deinit();
        }
        self.widening_states.deinit();
        self.widening_visits.deinit();
    }

    /// Options for widening at program points.
    pub const WideningOptions = struct {
        /// Whether to apply widening at this point
        apply_widening: bool = false,
        /// The widening key (must be provided if apply_widening is true)
        widening_key: ?WideningKey = null,
    };

    /// Result of getOrCreateNode operation.
    pub const GetOrCreateResult = struct {
        /// Index of the node
        index: u32,
        /// Whether this is a newly created node
        is_new: bool,
        /// Whether widening was applied
        widening_applied: bool = false,
        /// Whether widening converged (state unchanged after widening)
        converged: bool = false,
        /// Whether an existing node's state was updated (reprocess needed)
        state_updated: bool = false,
        /// Whether the caller should deinit the input state.
        /// True when: (1) node already exists (is_new == false), or
        ///            (2) widening was applied (the widened state, not input, was consumed)
        caller_should_deinit: bool = false,
    };

    const CapWideningResult = struct {
        index: u32,
        applied: bool,
        converged: bool,
        state_updated: bool,
    };

    fn ensurePointNodes(self: *ExplodedGraph, point_key: u64) EngineError!*std.ArrayList(u32) {
        const entry = self.point_nodes.getOrPut(point_key) catch |err| switch (err) {
            error.OutOfMemory => return EngineError.OutOfMemory,
        };
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        return entry.value_ptr;
    }

    fn findSubsumingNode(self: *ExplodedGraph, point_key: u64, state: *const ProgramState) ?u32 {
        if (self.point_nodes.getPtr(point_key)) |list| {
            for (list.items) |index| {
                const existing_state = &self.nodes.items[index].state;
                if (existing_state.subsumes(state)) return index;
            }
        }
        return null;
    }

    fn sameContext(a: *const ProgramState, b: *const ProgramState) bool {
        if (a.inline_depth != b.inline_depth) return false;
        if (a.call_stack.items.len != b.call_stack.items.len) return false;
        for (a.call_stack.items, b.call_stack.items) |call_site, other_site| {
            if (call_site.call_node != other_site.call_node or
                call_site.return_node != other_site.return_node or
                call_site.caller_cfg != other_site.caller_cfg)
            {
                return false;
            }
        }
        return true;
    }

    fn widenOnCap(self: *ExplodedGraph, point_key: u64, state: *ProgramState) EngineError!CapWideningResult {
        const list = self.point_nodes.getPtr(point_key) orelse
            return .{ .index = std.math.maxInt(u32), .applied = false, .converged = false, .state_updated = false };
        if (list.items.len == 0) {
            return .{ .index = std.math.maxInt(u32), .applied = false, .converged = false, .state_updated = false };
        }

        var target_index: ?u32 = null;
        for (list.items) |index| {
            const existing_state = &self.nodes.items[index].state;
            if (sameContext(existing_state, state)) {
                target_index = index;
                break;
            }
        }

        const cap_index = target_index orelse
            return .{ .index = std.math.maxInt(u32), .applied = false, .converged = false, .state_updated = false };
        var target_node = &self.nodes.items[cap_index];

        var widened = target_node.state.widen(state) catch |err| switch (err) {
            error.OutOfMemory => return EngineError.OutOfMemory,
        };
        if (widened.eql(&target_node.state)) {
            widened.deinit();
            self.widening_converged += 1;
            return .{ .index = cap_index, .applied = true, .converged = true, .state_updated = false };
        }

        const new_key = ExplodedNode.computeKey(target_node.point, &widened);
        if (self.node_map.get(new_key)) |existing_index| {
            if (existing_index != cap_index) {
                widened.deinit();
                return .{ .index = existing_index, .applied = true, .converged = true, .state_updated = false };
            }
        }

        const old_key = ExplodedNode.computeKey(target_node.point, &target_node.state);
        target_node.state.deinit();
        target_node.state = widened;

        if (new_key != old_key) {
            _ = self.node_map.remove(old_key);
            self.node_map.put(new_key, cap_index) catch |err| switch (err) {
                error.OutOfMemory => return EngineError.OutOfMemory,
            };
        }

        self.widened_nodes += 1;
        return .{ .index = cap_index, .applied = true, .converged = false, .state_updated = true };
    }

    /// Get or create a node for the given point and state.
    /// Returns the node index and whether it was newly created.
    /// Ownership: The caller should deinit `state` if `is_new == false` OR if `widening_applied == true`.
    /// When widening is applied, the widened state (not the original) is used for the new node.
    pub fn getOrCreateNode(self: *ExplodedGraph, point: ProgramPoint, state: *ProgramState) EngineError!GetOrCreateResult {
        return self.getOrCreateNodeWithWidening(point, state, .{});
    }

    /// Get or create a node for the given point and state, with optional widening support.
    ///
    /// Flow:
    /// 1. Apply optional widening at the current program point.
    /// 2. Deduplicate by (point, state) hash as usual.
    /// 3. Drop states subsumed by an existing node at this point.
    /// 4. If max_states_per_point is reached, widen into an existing node.
    /// 5. Otherwise, create a new node.
    pub fn getOrCreateNodeWithWidening(
        self: *ExplodedGraph,
        point: ProgramPoint,
        state: *ProgramState,
        options: WideningOptions,
    ) EngineError!GetOrCreateResult {
        var current_state = state;
        var widened_state: ?ProgramState = null;
        var widening_applied = false;
        var converged = false;

        // Step 1: Apply optional widening at this point.
        if (options.apply_widening) {
            if (options.widening_key) |widening_key| {
                const visit_count = self.widening_visits.get(widening_key) orelse 0;

                if (visit_count == 0) {
                    // First visit: store a clone of the state for future widening
                    const state_clone = state.clone(self.allocator) catch |err| switch (err) {
                        error.OutOfMemory => return EngineError.OutOfMemory,
                    };
                    self.widening_states.put(widening_key, state_clone) catch |err| switch (err) {
                        error.OutOfMemory => return EngineError.OutOfMemory,
                    };
                    self.widening_visits.put(widening_key, 1) catch |err| switch (err) {
                        error.OutOfMemory => return EngineError.OutOfMemory,
                    };
                } else {
                    // Subsequent visits: widen incoming state with stored state
                    if (self.widening_states.getPtr(widening_key)) |stored_state| {
                        const ws = stored_state.widen(state) catch |err| switch (err) {
                            error.OutOfMemory => return EngineError.OutOfMemory,
                        };
                        widened_state = ws;
                        widening_applied = true;

                        // Check for convergence: if widened state equals stored state, we've converged
                        if (ws.eql(stored_state)) {
                            converged = true;
                            self.widening_converged += 1;
                        } else {
                            // Update stored state with widened result for next iteration
                            // Clone first, then replace to avoid leaving invalid state on OOM
                            var new_clone = ws.clone(self.allocator) catch |err| switch (err) {
                                error.OutOfMemory => return EngineError.OutOfMemory,
                            };
                            errdefer new_clone.deinit();
                            // Save old state before put() overwrites it
                            var old_state = stored_state.*;
                            // put() for existing key replaces value without allocation failure
                            // (capacity already exists), but we handle it defensively
                            self.widening_states.put(widening_key, new_clone) catch |err| switch (err) {
                                error.OutOfMemory => return EngineError.OutOfMemory,
                            };
                            // Deinit old state after successful replacement
                            old_state.deinit();
                        }

                        // Increment visit count
                        self.widening_visits.put(widening_key, visit_count + 1) catch |err| switch (err) {
                            error.OutOfMemory => return EngineError.OutOfMemory,
                        };
                    }

                    // Use widened state for deduplication
                    if (widened_state != null) {
                        current_state = &widened_state.?;
                    }
                }
            }
        }

        errdefer {
            if (widened_state) |*ws| {
                ws.deinit();
            }
        }

        // Step 2: Deduplicate by (point, state) hash
        const key = ExplodedNode.computeKey(point, current_state);
        if (self.node_map.get(key)) |existing_index| {
            if (widened_state) |*ws| {
                ws.deinit();
            }
            return .{
                .index = existing_index,
                .is_new = false,
                .widening_applied = widening_applied,
                .converged = converged,
                .state_updated = false,
                .caller_should_deinit = true,
            };
        }

        const point_key = point.hash();

        // Step 3: Subsumption check against existing nodes at this point
        if (self.findSubsumingNode(point_key, current_state)) |existing_index| {
            if (widened_state) |*ws| {
                ws.deinit();
            }
            return .{
                .index = existing_index,
                .is_new = false,
                .widening_applied = widening_applied,
                .converged = converged,
                .state_updated = false,
                .caller_should_deinit = true,
            };
        }

        // Step 4: Check per-point state limit and widen into existing node if needed
        const current_count = self.point_state_counts.get(point_key) orelse 0;
        if (current_count >= self.max_states_per_point) {
            const cap_result = try self.widenOnCap(point_key, current_state);
            if (cap_result.applied) {
                if (widened_state) |*ws| {
                    ws.deinit();
                }
                return .{
                    .index = cap_result.index,
                    .is_new = false,
                    .widening_applied = widening_applied or cap_result.applied,
                    .converged = converged or cap_result.converged,
                    .state_updated = cap_result.state_updated,
                    .caller_should_deinit = true,
                };
            }
        }

        const index: u32 = @intCast(self.nodes.items.len);

        // Use widened state if available, otherwise use original state
        const node_state = if (widened_state) |ws| ws else state.*;
        const node = ExplodedNode.init(point, node_state, index);

        self.nodes.append(self.allocator, node) catch |err| switch (err) {
            error.OutOfMemory => {
                if (widened_state) |*ws| {
                    ws.deinit();
                }
                return EngineError.OutOfMemory;
            },
        };
        self.node_map.put(key, index) catch |err| switch (err) {
            error.OutOfMemory => return EngineError.OutOfMemory,
        };
        self.point_state_counts.put(point_key, current_count + 1) catch |err| switch (err) {
            error.OutOfMemory => return EngineError.OutOfMemory,
        };

        var point_list = try self.ensurePointNodes(point_key);
        try point_list.append(self.allocator, index);

        if (widening_applied) {
            self.widened_nodes += 1;
        }

        // Caller should deinit the input state if widening was applied (the widened state was consumed, not the input)
        return .{
            .index = index,
            .is_new = true,
            .widening_applied = widening_applied,
            .converged = converged,
            .state_updated = false,
            .caller_should_deinit = widening_applied,
        };
    }

    /// Add an edge between two exploded graph nodes.
    /// Edges are deduplicated: a given (from, to) pair is recorded at most once,
    /// so repeated calls after state updates don't accumulate duplicates.
    /// On allocation failure neither list is mutated, so the successors/predecessors
    /// lockstep invariant is preserved.
    pub fn addEdge(self: *ExplodedGraph, from_index: u32, to_index: u32) EngineError!void {
        if (from_index >= self.nodes.items.len or to_index >= self.nodes.items.len) {
            return;
        }

        const successors = &self.nodes.items[from_index].successors;
        for (successors.items) |existing| {
            if (existing == to_index) return;
        }

        try successors.ensureUnusedCapacity(self.allocator, 1);
        try self.nodes.items[to_index].predecessors.ensureUnusedCapacity(self.allocator, 1);

        successors.appendAssumeCapacity(to_index);
        self.nodes.items[to_index].predecessors.appendAssumeCapacity(from_index);
    }

    /// Get a node by index
    pub fn getNode(self: *const ExplodedGraph, index: u32) ?*const ExplodedNode {
        if (index >= self.nodes.items.len) return null;
        return &self.nodes.items[index];
    }

    /// Get node count
    pub fn nodeCount(self: *const ExplodedGraph) usize {
        return self.nodes.items.len;
    }

    pub fn setMaxStatesPerPoint(self: *ExplodedGraph, max: u32) void {
        self.max_states_per_point = max;
    }

    /// Get the count of nodes created after widening.
    pub fn getWidenedNodeCount(self: *const ExplodedGraph) u32 {
        return self.widened_nodes;
    }

    /// Get the count of times widening converged.
    pub fn getWideningConvergedCount(self: *const ExplodedGraph) u32 {
        return self.widening_converged;
    }

    /// Get the count of distinct widening points being tracked.
    /// Each point in a unique calling context is counted separately.
    pub fn getTrackedWideningPointCount(self: *const ExplodedGraph) u32 {
        return @intCast(self.widening_states.count());
    }
};

test "ExplodedGraph node creation and deduplication" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 42 });

    const result1 = try graph.getOrCreateNode(point, &state1);
    try testing.expect(result1.is_new);
    try testing.expectEqual(@as(u32, 0), result1.index);
    try testing.expectEqual(@as(usize, 1), graph.nodeCount());

    // Same point, same state should deduplicate
    var state1_clone = try state1.clone(allocator);
    const result2 = try graph.getOrCreateNode(point, &state1_clone);
    if (result2.caller_should_deinit) {
        state1_clone.deinit();
    }
    try testing.expect(!result2.is_new);
    try testing.expect(result2.caller_should_deinit);
    try testing.expectEqual(@as(u32, 0), result2.index);
    try testing.expectEqual(@as(usize, 1), graph.nodeCount());

    // Same point, different state should create new node
    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 100 });
    const result3 = try graph.getOrCreateNode(point, &state2);
    try testing.expect(result3.is_new);
    try testing.expectEqual(@as(u32, 1), result3.index);
    try testing.expectEqual(@as(usize, 2), graph.nodeCount());
}

test "ExplodedGraph subsumption avoids redundant states" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var general = ProgramState.init(allocator);
    try general.setVar(ids.varId(1), .unknown);
    const result1 = try graph.getOrCreateNode(point, &general);
    try testing.expect(result1.is_new);

    var specific = ProgramState.init(allocator);
    try specific.setVar(ids.varId(1), .{ .concrete_int = 42 });

    const result2 = try graph.getOrCreateNode(point, &specific);
    try testing.expect(!result2.is_new);
    try testing.expectEqual(result1.index, result2.index);
    try testing.expectEqual(@as(usize, 1), graph.nodeCount());

    specific.deinit();
}

test "ExplodedGraph edge operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    const result1 = try graph.getOrCreateNode(point, &state1);

    var state2 = ProgramState.init(allocator);
    const result2 = try graph.getOrCreateNode(point, &state2);

    try graph.addEdge(result1.index, result2.index);

    const node1 = graph.getNode(result1.index) orelse return error.TestUnexpectedResult;
    const node2 = graph.getNode(result2.index) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 1), node1.successors.items.len);
    try testing.expectEqual(@as(usize, 1), node2.predecessors.items.len);
    try testing.expectEqual(result2.index, node1.successors.items[0]);
    try testing.expectEqual(result1.index, node2.predecessors.items[0]);
}

test "ExplodedGraph addEdge deduplicates repeated edges" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 1 });
    const result1 = try graph.getOrCreateNode(point, &state1);

    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 2 });
    const result2 = try graph.getOrCreateNode(point, &state2);

    try graph.addEdge(result1.index, result2.index);
    try graph.addEdge(result1.index, result2.index);
    try graph.addEdge(result1.index, result2.index);

    const node1 = graph.getNode(result1.index) orelse return error.TestUnexpectedResult;
    const node2 = graph.getNode(result2.index) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 1), node1.successors.items.len);
    try testing.expectEqual(@as(usize, 1), node2.predecessors.items.len);
    try testing.expectEqual(result2.index, node1.successors.items[0]);
    try testing.expectEqual(result1.index, node2.predecessors.items[0]);
}

test "ExplodedGraph addEdge keeps distinct edges" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 1 });
    const result1 = try graph.getOrCreateNode(point, &state1);

    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 2 });
    const result2 = try graph.getOrCreateNode(point, &state2);

    var state3 = ProgramState.init(allocator);
    try state3.setVar(ids.varId(1), .{ .concrete_int = 3 });
    const result3 = try graph.getOrCreateNode(point, &state3);

    try graph.addEdge(result1.index, result2.index);
    try graph.addEdge(result1.index, result3.index);
    try graph.addEdge(result1.index, result2.index);

    const node1 = graph.getNode(result1.index) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 2), node1.successors.items.len);
}

test "ExplodedGraph widening first visit stores state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state = ProgramState.init(allocator);
    try state.setVar(ids.varId(1), .{ .concrete_int = 10 });

    const widening_key = WideningKey.init(point, &state);

    const result = try graph.getOrCreateNodeWithWidening(point, &state, .{
        .apply_widening = true,
        .widening_key = widening_key,
    });

    try testing.expect(result.is_new);
    try testing.expect(!result.widening_applied);
    try testing.expect(!result.converged);
    try testing.expectEqual(@as(u32, 0), graph.getWidenedNodeCount());
    try testing.expectEqual(@as(u32, 0), graph.getWideningConvergedCount());

    // Verify state was stored
    try testing.expect(graph.widening_states.get(widening_key) != null);
    try testing.expectEqual(@as(?u32, 1), graph.widening_visits.get(widening_key));
}

test "ExplodedGraph widening subsequent visit applies widening" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    // First visit: store state
    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 10 });

    const widening_key = WideningKey.init(point, &state1);

    _ = try graph.getOrCreateNodeWithWidening(point, &state1, .{
        .apply_widening = true,
        .widening_key = widening_key,
    });

    // Second visit: different state should be widened
    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 20 }); // different value

    const result = try graph.getOrCreateNodeWithWidening(point, &state2, .{
        .apply_widening = true,
        .widening_key = widening_key,
    });

    try testing.expect(result.is_new);
    try testing.expect(result.widening_applied);
    try testing.expect(!result.converged); // widened to unknown, different from stored
    try testing.expectEqual(@as(u32, 1), graph.getWidenedNodeCount());
    try testing.expectEqual(@as(?u32, 2), graph.widening_visits.get(widening_key));
    // Caller needs to clean up state2 since it wasn't consumed (widened state was used instead)
    state2.deinit();
}

test "ExplodedGraph widening convergence detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    // First visit: store state with unknown value
    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .unknown);

    const widening_key = WideningKey.init(point, &state1);

    _ = try graph.getOrCreateNodeWithWidening(point, &state1, .{
        .apply_widening = true,
        .widening_key = widening_key,
    });

    // Second visit: same unknown value should converge
    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .unknown);

    const result = try graph.getOrCreateNodeWithWidening(point, &state2, .{
        .apply_widening = true,
        .widening_key = widening_key,
    });

    // Should deduplicate since widened state equals stored state
    try testing.expect(!result.is_new);
    try testing.expect(result.widening_applied);
    try testing.expect(result.converged);
    try testing.expectEqual(@as(u32, 1), graph.getWideningConvergedCount());
    // Caller needs to clean up state2 since it wasn't consumed
    state2.deinit();
}

test "ExplodedGraph widening stats tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    try testing.expectEqual(@as(u32, 0), graph.getWidenedNodeCount());
    try testing.expectEqual(@as(u32, 0), graph.getWideningConvergedCount());
}

test "ExplodedGraph widen-on-cap updates existing node" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.loop_header));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    graph.setMaxStatesPerPoint(2);

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 10 });
    const result1 = try graph.getOrCreateNode(point, &state1);
    try testing.expect(result1.is_new);

    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 20 });
    const result2 = try graph.getOrCreateNode(point, &state2);
    try testing.expect(result2.is_new);

    var state3 = ProgramState.init(allocator);
    try state3.setVar(ids.varId(1), .{ .concrete_int = 30 });

    const result = try graph.getOrCreateNodeWithWidening(point, &state3, .{});

    try testing.expect(!result.is_new);
    try testing.expect(result.widening_applied);
    try testing.expect(result.state_updated);

    const node = graph.getNode(result.index) orelse return error.TestUnexpectedResult;
    const val = node.state.getVar(ids.varId(1)) orelse return error.TestUnexpectedResult;
    try testing.expect(val.isUnknown());

    state3.deinit();
}

test "ExplodedGraph widen-on-cap respects context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));
    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    graph.setMaxStatesPerPoint(1);

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state1 = ProgramState.init(allocator);
    try state1.setVar(ids.varId(1), .{ .concrete_int = 10 });
    const result1 = try graph.getOrCreateNode(point, &state1);
    try testing.expect(result1.is_new);

    var state2 = ProgramState.init(allocator);
    try state2.setVar(ids.varId(1), .{ .concrete_int = 20 });
    try state2.pushCallSite(state_mod.CallSite{ .call_node = ids.cfgId(0), .caller_cfg = &cfg, .return_node = ids.cfgId(1) });

    const result2 = try graph.getOrCreateNodeWithWidening(point, &state2, .{});
    try testing.expect(result2.is_new);
    try testing.expect(!result2.widening_applied);
    try testing.expectEqual(@as(usize, 2), graph.nodeCount());

    if (result2.caller_should_deinit) {
        state2.deinit();
    }
}

test "ExplodedGraph without widening options works as before" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    _ = try cfg.addNode(IrNode.init(.fn_entry));

    var graph = ExplodedGraph.init(allocator, &cfg);
    defer graph.deinit();

    const point = ProgramPoint.initPre(ids.cfgId(0), &cfg);

    var state = ProgramState.init(allocator);
    try state.setVar(ids.varId(1), .{ .concrete_int = 42 });

    const result = try graph.getOrCreateNode(point, &state);

    try testing.expect(result.is_new);
    try testing.expect(!result.widening_applied);
    try testing.expect(!result.converged);
    try testing.expectEqual(@as(u32, 0), graph.getWidenedNodeCount());
}
