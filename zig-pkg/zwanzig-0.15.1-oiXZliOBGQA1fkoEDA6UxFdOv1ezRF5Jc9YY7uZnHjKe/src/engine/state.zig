const std = @import("std");
const ids = @import("../ids.zig");
const BuildMetadata = @import("../build_metadata.zig").BuildMetadata;
const Cfg = @import("../cfg.zig").Cfg;
const AbstractValue = @import("value.zig").AbstractValue;
const Constraint = @import("constraints.zig").Constraint;
const ConstraintManager = @import("constraints.zig").ConstraintManager;
const Environment = @import("env.zig").Environment;
const store_mod = @import("store.zig");
const VarId = ids.VarId;
const CfgNodeId = ids.CfgNodeId;
const ResourceState = store_mod.ResourceState;
const Store = store_mod.Store;
const StoreViolation = store_mod.StoreViolation;

/// Represents a position in the analysis - a specific point in the CFG.
/// ProgramPoint identifies a CFG node plus whether we are at the pre-state
/// (before the node executes) or post-state (after the node executes).
/// Includes the CFG pointer to distinguish nodes from different CFGs during
/// interprocedural analysis.
pub const ProgramPoint = struct {
    /// Index of the CFG node
    node_index: CfgNodeId,
    /// Whether this is a pre-state (before node execution) or post-state (after)
    kind: Kind,
    /// The CFG this node belongs to (for interprocedural analysis)
    cfg: *const Cfg,

    pub const Kind = enum {
        /// Before the CFG node is executed
        pre,
        /// After the CFG node has been executed
        post,
    };

    pub fn init(node_index: CfgNodeId, kind: Kind, cfg: *const Cfg) ProgramPoint {
        return .{
            .node_index = node_index,
            .kind = kind,
            .cfg = cfg,
        };
    }

    pub fn initPre(node_index: CfgNodeId, cfg: *const Cfg) ProgramPoint {
        return init(node_index, .pre, cfg);
    }

    pub fn initPost(node_index: CfgNodeId, cfg: *const Cfg) ProgramPoint {
        return init(node_index, .post, cfg);
    }

    pub fn eql(self: ProgramPoint, other: ProgramPoint) bool {
        return self.node_index == other.node_index and
            self.kind == other.kind and
            self.cfg == other.cfg;
    }

    pub fn hash(self: ProgramPoint) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const node_index = ids.cfgIndex(self.node_index);
        hasher.update(std.mem.asBytes(&node_index));
        hasher.update(std.mem.asBytes(&self.kind));
        hasher.update(std.mem.asBytes(&@intFromPtr(self.cfg)));
        return hasher.final();
    }
};

/// Error state of the program: whether we are on an error path or success path.
pub const ErrorState = enum {
    /// Normal execution path (no error)
    normal,
    /// Error path (error has been produced but not yet handled)
    error_active,
    /// Error has been caught and handled
    error_handled,
};

/// Represents a call site in the inline call stack.
/// Used to track interprocedural analysis context.
pub const CallSite = struct {
    /// CFG node index of the call instruction
    call_node: CfgNodeId,
    /// The CFG containing the call site
    caller_cfg: *const Cfg,
    /// Return point: the CFG node to continue from after the call returns
    return_node: CfgNodeId,
};

/// Key for identifying a widening point in a specific interprocedural context.
/// Used to track states at loop headers and other join points for widening.
/// States from different calling contexts must not be merged.
pub const WideningKey = struct {
    /// Hash of the ProgramPoint (node + CFG + pre/post)
    point_hash: u64,
    /// Hash of the calling context (inline depth + call stack)
    context_hash: u64,

    pub fn init(point: ProgramPoint, state: *const ProgramState) WideningKey {
        return .{
            .point_hash = point.hash(),
            .context_hash = state.contextHash(),
        };
    }

    pub fn eql(self: WideningKey, other: WideningKey) bool {
        return self.point_hash == other.point_hash and
            self.context_hash == other.context_hash;
    }

    pub fn hash(self: WideningKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.point_hash));
        hasher.update(std.mem.asBytes(&self.context_hash));
        return hasher.final();
    }

    pub const HashContext = struct {
        pub fn hash(_: HashContext, key: WideningKey) u64 {
            return key.hash();
        }

        pub fn eql(_: HashContext, a: WideningKey, b: WideningKey) bool {
            return a.eql(b);
        }
    };
};

/// Abstract program state for path-sensitive analysis.
/// Stores the environment mapping variables to abstract values,
/// plus path constraints from branch conditions, and error state.
pub const ProgramState = struct {
    /// Environment mapping variables to abstract values
    env: Environment,
    /// Constraint manager for path conditions
    constraints: ConstraintManager,
    /// Store tracking heap/resource regions
    store: Store,
    /// Error state tracking (normal, error_active, error_handled)
    error_state: ErrorState,
    /// Cached hash for efficient deduplication
    cached_hash: ?u64,
    /// Current inlining depth (0 = top-level function)
    inline_depth: u32,
    /// Call stack for interprocedural analysis (stored as indices into call_sites)
    call_stack: std.ArrayList(CallSite),
    /// Build metadata (target configuration, etc.) - shared pointer, not owned
    build_metadata: ?*const BuildMetadata,

    pub fn init(allocator: std.mem.Allocator) ProgramState {
        return .{
            .env = Environment.init(allocator),
            .constraints = ConstraintManager.init(allocator),
            .store = Store.init(allocator),
            .error_state = .normal,
            .cached_hash = null,
            .inline_depth = 0,
            .call_stack = .empty,
            .build_metadata = null,
        };
    }

    pub fn deinit(self: *ProgramState) void {
        self.env.deinit();
        self.constraints.deinit();
        self.store.deinit();
        self.call_stack.deinit(self.env.allocator);
    }

    pub fn eql(self: *const ProgramState, other: *const ProgramState) bool {
        if (self.inline_depth != other.inline_depth) return false;
        if (!self.env.eql(&other.env)) return false;
        if (!self.constraints.eql(&other.constraints)) return false;
        if (!self.store.eql(&other.store)) return false;
        if (self.error_state != other.error_state) return false;
        // Compare call stacks to distinguish different calling contexts
        if (self.call_stack.items.len != other.call_stack.items.len) return false;
        for (self.call_stack.items, other.call_stack.items) |cs1, cs2| {
            if (cs1.call_node != cs2.call_node or
                cs1.return_node != cs2.return_node or
                cs1.caller_cfg != cs2.caller_cfg)
            {
                return false;
            }
        }
        return true;
    }

    pub fn computeHash(self: *ProgramState) u64 {
        if (self.cached_hash) |h| return h;
        var hasher = std.hash.Wyhash.init(0);
        const env_hash = self.env.computeHash();
        hasher.update(std.mem.asBytes(&env_hash));
        const constraints_hash = self.constraints.computeHash();
        hasher.update(std.mem.asBytes(&constraints_hash));
        const store_hash = self.store.computeHash();
        hasher.update(std.mem.asBytes(&store_hash));
        hasher.update(std.mem.asBytes(&self.error_state));
        hasher.update(std.mem.asBytes(&self.inline_depth));
        // Include call stack in hash to distinguish different calling contexts
        for (self.call_stack.items) |cs| {
            const call_node = ids.cfgIndex(cs.call_node);
            const return_node = ids.cfgIndex(cs.return_node);
            hasher.update(std.mem.asBytes(&call_node));
            hasher.update(std.mem.asBytes(&return_node));
            hasher.update(std.mem.asBytes(&@intFromPtr(cs.caller_cfg)));
        }
        const h = hasher.final();
        self.cached_hash = h;
        return h;
    }

    pub fn clone(self: *const ProgramState, allocator: std.mem.Allocator) !ProgramState {
        var new_call_stack: std.ArrayList(CallSite) = .empty;
        errdefer new_call_stack.deinit(allocator);
        for (self.call_stack.items) |cs| {
            try new_call_stack.append(allocator, cs);
        }
        var new_env = try self.env.clone();
        errdefer new_env.deinit();
        var new_constraints = try self.constraints.clone();
        errdefer new_constraints.deinit();
        var new_store = try self.store.clone(allocator);
        errdefer new_store.deinit();
        return .{
            .env = new_env,
            .constraints = new_constraints,
            .store = new_store,
            .error_state = self.error_state,
            .cached_hash = self.cached_hash,
            .inline_depth = self.inline_depth,
            .call_stack = new_call_stack,
            .build_metadata = self.build_metadata,
        };
    }

    pub fn invalidateCache(self: *ProgramState) void {
        self.cached_hash = null;
    }

    pub fn getVar(self: *const ProgramState, var_id: VarId) ?AbstractValue {
        return self.env.get(var_id);
    }

    pub fn setVar(self: *ProgramState, var_id: VarId, value: AbstractValue) !void {
        try self.env.set(var_id, value);
        self.invalidateCache();
    }

    pub fn envSize(self: *const ProgramState) usize {
        return self.env.size();
    }

    /// Track a resource allocation for a region.
    pub fn trackAllocation(self: *ProgramState, region: VarId) !void {
        try self.store.markAllocated(region);
        self.invalidateCache();
    }

    /// Track a resource open for a region.
    pub fn trackOpen(self: *ProgramState, region: VarId) !void {
        try self.store.markOpened(region);
        self.invalidateCache();
    }

    /// Track a resource free for a region.
    pub fn trackFree(self: *ProgramState, region: VarId, call_token: ?u32) !void {
        try self.store.markFreed(region, call_token);
        self.invalidateCache();
    }

    /// Track freeing resources owned by a region (does not free the region itself).
    pub fn trackFreeOwned(self: *ProgramState, region: VarId, call_token: ?u32) !void {
        try self.store.markFreeOwned(region, call_token);
        self.invalidateCache();
    }

    /// Track a resource close for a region.
    pub fn trackClose(self: *ProgramState, region: VarId, call_token: ?u32) !void {
        try self.store.markClosed(region, call_token);
        self.invalidateCache();
    }

    /// Track a resource known to be non-allocated.
    pub fn trackNonAllocation(self: *ProgramState, region: VarId) !void {
        try self.store.markNonAllocated(region);
        self.invalidateCache();
    }

    pub fn resetRegion(self: *ProgramState, region: VarId) void {
        self.store.resetRegion(region);
        self.invalidateCache();
    }

    pub fn trackEscape(self: *ProgramState, region: VarId) void {
        self.store.escapeRegion(region);
        self.invalidateCache();
    }

    pub fn trackEscapeOwned(self: *ProgramState, region: VarId) std.mem.Allocator.Error!void {
        try self.store.escapeOwned(region);
        self.invalidateCache();
    }

    pub fn trackEscapeByName(self: *ProgramState, tree: *const std.zig.Ast, name: []const u8) !void {
        try self.store.escapeByName(tree, name);
        self.invalidateCache();
    }

    /// Track a resource use for a region.
    pub fn trackUse(self: *ProgramState, region: VarId, call_token: ?u32) !void {
        try self.store.markUsed(region, call_token);
        self.invalidateCache();
    }

    /// Track a deferred free for a region.
    pub fn trackDeferredFree(self: *ProgramState, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        try self.store.markDeferredFree(region, call_token, scope_node);
        self.invalidateCache();
    }

    /// Track a deferred free-owned for a region.
    pub fn trackDeferredFreeOwned(self: *ProgramState, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        try self.store.markDeferredFreeOwned(region, call_token, scope_node);
        self.invalidateCache();
    }

    /// Track a deferred close for a region.
    pub fn trackDeferredClose(self: *ProgramState, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        try self.store.markDeferredClose(region, call_token, scope_node);
        self.invalidateCache();
    }

    pub fn trackErrdeferredFree(self: *ProgramState, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        try self.store.markErrdeferredFree(region, call_token, scope_node);
        self.invalidateCache();
    }

    pub fn trackErrdeferredFreeOwned(self: *ProgramState, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        try self.store.markErrdeferredFreeOwned(region, call_token, scope_node);
        self.invalidateCache();
    }

    pub fn trackErrdeferredClose(self: *ProgramState, region: VarId, call_token: ?u32, scope_node: ?u32) !void {
        try self.store.markErrdeferredClose(region, call_token, scope_node);
        self.invalidateCache();
    }

    pub fn applyErrdeferredReleases(self: *ProgramState, return_node: u32, parent_map: []const u32) !void {
        try self.store.applyErrdeferredReleases(return_node, parent_map);
        self.invalidateCache();
    }

    pub fn trackOwnership(self: *ProgramState, resource: VarId, container: VarId) !void {
        try self.store.recordOwnership(resource, container);
        self.invalidateCache();
    }

    /// Track a region aliasing another region.
    pub fn trackAlias(self: *ProgramState, alias: VarId, target: VarId) !void {
        try self.store.aliasRegion(alias, target);
        self.invalidateCache();
    }

    /// Track resource leaks in the current state.
    pub fn trackLeaks(self: *ProgramState) !void {
        try self.store.recordLeaks(self.isErrorPath());
        self.invalidateCache();
    }

    /// Get the resource state for a region, if known.
    pub fn getRegionState(self: *const ProgramState, region: VarId) ?ResourceState {
        return self.store.getState(region);
    }

    /// Get store violations recorded in this state.
    pub fn getStoreViolations(self: *const ProgramState) []const StoreViolation {
        return self.store.getViolations();
    }

    /// Add a constraint to this state and refine variable values accordingly.
    pub fn addConstraint(self: *ProgramState, constraint: Constraint) !void {
        try self.constraints.addConstraint(constraint);
        self.invalidateCache();

        // Refine the relevant variable's value based on the constraint
        const var_id: ?VarId = switch (constraint) {
            .int_compare => |ic| ic.var_id,
            .null_check => |nc| nc.var_id,
            .bool_check => |bc| bc.var_id,
            .var_compare => |vc| vc.var1_id,
            .literal_bool => null, // No variable to refine for literal bool constraints
        };

        if (var_id) |vid| {
            if (self.env.get(vid)) |current_val| {
                if (ConstraintManager.refineValue(current_val, constraint)) |refined| {
                    try self.env.set(vid, refined);
                }
            }
        }
    }

    /// Check if this state's constraints are satisfiable.
    pub fn isSatisfiable(self: *const ProgramState) bool {
        return self.constraints.isSatisfiable(&self.env);
    }

    pub fn constraintCount(self: *const ProgramState) usize {
        return self.constraints.size();
    }

    /// Check if there's a constraint proving a variable is non-null.
    pub fn hasNonNullConstraint(self: *const ProgramState, var_id: VarId) bool {
        for (self.constraints.constraints.items) |constraint| {
            switch (constraint) {
                .null_check => |nc| {
                    if (nc.var_id == var_id and !nc.is_null) {
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// Set the error state of this program state.
    pub fn setErrorState(self: *ProgramState, error_state: ErrorState) void {
        self.error_state = error_state;
        self.invalidateCache();
    }

    /// Get the current error state.
    pub fn getErrorState(self: *const ProgramState) ErrorState {
        return self.error_state;
    }

    /// Check if we are on an error path.
    pub fn isErrorPath(self: *const ProgramState) bool {
        return self.error_state == .error_active;
    }

    /// Check if we are on a normal (non-error) path.
    pub fn isNormalPath(self: *const ProgramState) bool {
        return self.error_state == .normal;
    }

    /// Get the current inlining depth.
    pub fn getInlineDepth(self: *const ProgramState) u32 {
        return self.inline_depth;
    }

    /// Increment inline depth when entering an inlined function.
    pub fn incrementInlineDepth(self: *ProgramState) void {
        self.inline_depth += 1;
        self.invalidateCache();
    }

    /// Decrement inline depth when returning from an inlined function.
    pub fn decrementInlineDepth(self: *ProgramState) void {
        if (self.inline_depth > 0) {
            self.inline_depth -= 1;
        }
        self.invalidateCache();
    }

    /// Push a call site onto the call stack.
    pub fn pushCallSite(self: *ProgramState, call_site: CallSite) !void {
        try self.call_stack.append(self.env.allocator, call_site);
        self.invalidateCache();
    }

    /// Pop a call site from the call stack.
    pub fn popCallSite(self: *ProgramState) ?CallSite {
        if (self.call_stack.items.len > 0) {
            self.invalidateCache();
            return self.call_stack.pop();
        }
        return null;
    }

    /// Get the top of the call stack without removing it.
    pub fn peekCallSite(self: *const ProgramState) ?CallSite {
        if (self.call_stack.items.len > 0) {
            return self.call_stack.items[self.call_stack.items.len - 1];
        }
        return null;
    }

    /// Check if we are at an inline call site (depth > 0).
    pub fn isInlined(self: *const ProgramState) bool {
        return self.inline_depth > 0;
    }

    /// Compute a hash of the calling context (inline depth + call stack).
    /// Used to distinguish widening point states from different interprocedural contexts.
    pub fn contextHash(self: *const ProgramState) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.inline_depth));
        for (self.call_stack.items) |cs| {
            const call_node = ids.cfgIndex(cs.call_node);
            const return_node = ids.cfgIndex(cs.return_node);
            hasher.update(std.mem.asBytes(&call_node));
            hasher.update(std.mem.asBytes(&return_node));
            hasher.update(std.mem.asBytes(&@intFromPtr(cs.caller_cfg)));
        }
        return hasher.final();
    }

    /// Widening operator for program states.
    /// Used at widening points to ensure convergence by over-approximating.
    /// This should only be called on states with the same loop-header key
    /// (same ProgramPoint + same calling context).
    ///
    /// Widening rules:
    /// - Environment: widened using `Environment.widen`.
    /// - Constraints: widened using `ConstraintManager.widen` (intersection).
    /// - Store: widened using `Store.widen`.
    /// - Error state: if equal, keep; if different, set to `.error_active` (conservative).
    /// - Inline depth and call stack: preserved from `self` (same context assumption).
    /// - Cached hash: cleared after widening.
    pub fn widen(self: *const ProgramState, other: *const ProgramState) !ProgramState {
        const allocator = self.env.allocator;

        var new_env = try self.env.widen(&other.env);
        errdefer new_env.deinit();

        var new_constraints = try self.constraints.widen(&other.constraints);
        errdefer new_constraints.deinit();

        var new_store = try self.store.widen(&other.store, allocator);
        errdefer new_store.deinit();

        // Error state join: if different, set to .error_active (conservative)
        const new_error_state = if (self.error_state == other.error_state)
            self.error_state
        else
            .error_active;

        // Clone call stack from self (same context assumption)
        var new_call_stack: std.ArrayList(CallSite) = .empty;
        errdefer new_call_stack.deinit(allocator);
        for (self.call_stack.items) |cs| {
            try new_call_stack.append(allocator, cs);
        }

        return .{
            .env = new_env,
            .constraints = new_constraints,
            .store = new_store,
            .error_state = new_error_state,
            .cached_hash = null, // Clear cached hash after widening
            .inline_depth = self.inline_depth, // Preserve from self (same context)
            .call_stack = new_call_stack,
            .build_metadata = self.build_metadata,
        };
    }

    /// Returns true if `self` is at least as general as `other`.
    /// Requires the same calling context to avoid cross-context subsumption.
    pub fn subsumes(self: *const ProgramState, other: *const ProgramState) bool {
        if (self.inline_depth != other.inline_depth) return false;
        if (self.call_stack.items.len != other.call_stack.items.len) return false;
        for (self.call_stack.items, other.call_stack.items) |self_cs, other_cs| {
            if (self_cs.call_node != other_cs.call_node) return false;
            if (self_cs.return_node != other_cs.return_node) return false;
            if (@intFromPtr(self_cs.caller_cfg) != @intFromPtr(other_cs.caller_cfg)) return false;
        }

        if (self.error_state != other.error_state) return false;
        if (!self.env.subsumes(&other.env)) return false;
        if (!self.constraints.subsumes(&other.constraints)) return false;
        if (!self.store.subsumes(&other.store)) return false;

        return true;
    }
};

test "ProgramPoint basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg1 = Cfg.init(allocator);
    defer cfg1.deinit();
    var cfg2 = Cfg.init(allocator);
    defer cfg2.deinit();

    const point1 = ProgramPoint.initPre(ids.cfgId(5), &cfg1);
    try testing.expectEqual(ids.cfgId(5), point1.node_index);
    try testing.expectEqual(ProgramPoint.Kind.pre, point1.kind);

    const point2 = ProgramPoint.initPost(ids.cfgId(5), &cfg1);
    try testing.expectEqual(ids.cfgId(5), point2.node_index);
    try testing.expectEqual(ProgramPoint.Kind.post, point2.kind);

    try testing.expect(!point1.eql(point2));

    const point3 = ProgramPoint.initPre(ids.cfgId(5), &cfg1);
    try testing.expect(point1.eql(point3));

    try testing.expect(point1.hash() != point2.hash());
    try testing.expectEqual(point1.hash(), point3.hash());

    // Test CFG identity: same node index but different CFG should not be equal
    const point4 = ProgramPoint.initPre(ids.cfgId(5), &cfg2);
    try testing.expect(!point1.eql(point4));
    try testing.expect(point1.hash() != point4.hash());
}

test "ProgramState basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    try testing.expectEqual(@as(usize, 0), state1.envSize());

    try state1.setVar(ids.varId(42), .{ .concrete_int = 10 });
    try testing.expectEqual(@as(usize, 1), state1.envSize());

    const val = state1.getVar(ids.varId(42));
    try testing.expect(val != null);
    try testing.expect(val.?.eql(.{ .concrete_int = 10 }));

    var state2 = try state1.clone(allocator);
    defer state2.deinit();

    try testing.expect(state1.eql(&state2));

    try state2.setVar(ids.varId(42), .{ .concrete_int = 20 });
    try testing.expect(!state1.eql(&state2));
}

test "ProgramState with constraints" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try state.setVar(ids.varId(1), .{ .concrete_int = 42 });

    try state.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try testing.expectEqual(@as(usize, 1), state.constraintCount());
    try testing.expect(state.isSatisfiable());

    try state.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 43));
    try testing.expectEqual(@as(usize, 2), state.constraintCount());
    try testing.expect(!state.isSatisfiable());
}

test "ProgramState clone includes constraints" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try state.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));

    var state2 = try state.clone(allocator);
    defer state2.deinit();

    try testing.expect(state.eql(&state2));
}

test "ProgramState satisfiability" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try state.setVar(ids.varId(1), .{ .concrete_int = 10 });

    try state.addConstraint(Constraint.intCompare(ids.varId(1), .lt, 20));
    try testing.expect(state.isSatisfiable());

    try state.addConstraint(Constraint.intCompare(ids.varId(1), .gt, 20));
    try testing.expect(!state.isSatisfiable());
}

test "ErrorState enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 0), @intFromEnum(ErrorState.normal));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ErrorState.error_active));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ErrorState.error_handled));
}

test "ProgramState error state operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try testing.expect(state.isNormalPath());
    try testing.expect(!state.isErrorPath());

    state.setErrorState(.error_active);
    try testing.expect(state.isErrorPath());
    try testing.expect(!state.isNormalPath());

    state.setErrorState(.error_handled);
    try testing.expect(!state.isErrorPath());
}

test "ProgramState clone preserves error state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    state.setErrorState(.error_active);

    var state2 = try state.clone(allocator);
    defer state2.deinit();

    try testing.expectEqual(state.getErrorState(), state2.getErrorState());
}

test "ProgramState equality includes error state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expect(state1.eql(&state2));

    state2.setErrorState(.error_active);
    try testing.expect(!state1.eql(&state2));
}

test "ProgramState hash includes error state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expectEqual(state1.computeHash(), state2.computeHash());

    state2.setErrorState(.error_active);
    try testing.expect(state1.computeHash() != state2.computeHash());
}

test "ProgramState inline depth operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try testing.expectEqual(@as(u32, 0), state.getInlineDepth());
    try testing.expect(!state.isInlined());

    state.incrementInlineDepth();
    try testing.expectEqual(@as(u32, 1), state.getInlineDepth());
    try testing.expect(state.isInlined());

    state.decrementInlineDepth();
    try testing.expectEqual(@as(u32, 0), state.getInlineDepth());
    try testing.expect(!state.isInlined());

    // Should not go below 0
    state.decrementInlineDepth();
    try testing.expectEqual(@as(u32, 0), state.getInlineDepth());
}

test "ProgramState call stack operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state = ProgramState.init(allocator);
    defer state.deinit();

    const call_site = CallSite{ .call_node = ids.cfgId(1), .caller_cfg = &cfg, .return_node = ids.cfgId(2) };

    try testing.expectEqual(@as(?CallSite, null), state.peekCallSite());

    try state.pushCallSite(call_site);
    try testing.expect(state.peekCallSite() != null);
    try testing.expectEqual(ids.cfgId(1), state.peekCallSite().?.call_node);

    const popped = state.popCallSite();
    try testing.expect(popped != null);
    try testing.expectEqual(@as(?CallSite, null), state.peekCallSite());
}

test "ProgramState clone preserves inline depth and call stack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state = ProgramState.init(allocator);
    defer state.deinit();

    state.incrementInlineDepth();
    try state.pushCallSite(CallSite{ .call_node = ids.cfgId(1), .caller_cfg = &cfg, .return_node = ids.cfgId(2) });

    var state2 = try state.clone(allocator);
    defer state2.deinit();

    try testing.expectEqual(state.getInlineDepth(), state2.getInlineDepth());
    try testing.expectEqual(state.call_stack.items.len, state2.call_stack.items.len);
}

test "ProgramState equality includes inline depth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expect(state1.eql(&state2));

    state2.incrementInlineDepth();
    try testing.expect(!state1.eql(&state2));
}

test "ProgramState hash includes inline depth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expectEqual(state1.computeHash(), state2.computeHash());

    state2.incrementInlineDepth();
    try testing.expect(state1.computeHash() != state2.computeHash());
}

test "ProgramState store tracks allocation/free" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state = ProgramState.init(allocator);
    defer state.deinit();

    const region = ids.varId(42);

    try state.trackAllocation(region);
    try testing.expectEqual(ResourceState.allocated, state.getRegionState(region).?);

    try state.trackFree(region, 1);
    try testing.expectEqual(ResourceState.freed, state.getRegionState(region).?);
    try testing.expectEqual(@as(usize, 0), state.getStoreViolations().len);
}

test "ProgramState equality includes store" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expect(state1.eql(&state2));

    try state2.trackAllocation(ids.varId(5));
    try testing.expect(!state1.eql(&state2));
}

test "ProgramState hash includes store" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expectEqual(state1.computeHash(), state2.computeHash());

    try state2.trackAllocation(ids.varId(9));
    try testing.expect(state1.computeHash() != state2.computeHash());
}

test "ProgramState contextHash reflects inline depth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expectEqual(state1.contextHash(), state2.contextHash());

    state2.incrementInlineDepth();
    try testing.expect(state1.contextHash() != state2.contextHash());
}

test "ProgramState contextHash reflects call stack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    try testing.expectEqual(state1.contextHash(), state2.contextHash());

    try state2.pushCallSite(CallSite{ .call_node = ids.cfgId(1), .caller_cfg = &cfg, .return_node = ids.cfgId(2) });
    try testing.expect(state1.contextHash() != state2.contextHash());
}

test "ProgramState contextHash is stable" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state = ProgramState.init(allocator);
    defer state.deinit();

    state.incrementInlineDepth();
    try state.pushCallSite(CallSite{ .call_node = ids.cfgId(5), .caller_cfg = &cfg, .return_node = ids.cfgId(10) });

    const hash1 = state.contextHash();
    const hash2 = state.contextHash();
    try testing.expectEqual(hash1, hash2);
}

test "WideningKey basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state = ProgramState.init(allocator);
    defer state.deinit();

    const point1 = ProgramPoint.initPre(ids.cfgId(5), &cfg);
    const point2 = ProgramPoint.initPre(ids.cfgId(6), &cfg);

    const key1 = WideningKey.init(point1, &state);
    const key2 = WideningKey.init(point1, &state);
    const key3 = WideningKey.init(point2, &state);

    try testing.expect(key1.eql(key2));
    try testing.expect(!key1.eql(key3));
    try testing.expectEqual(key1.hash(), key2.hash());
    try testing.expect(key1.hash() != key3.hash());
}

test "WideningKey distinguishes calling contexts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    state2.incrementInlineDepth();
    try state2.pushCallSite(CallSite{ .call_node = ids.cfgId(1), .caller_cfg = &cfg, .return_node = ids.cfgId(2) });

    const point = ProgramPoint.initPre(ids.cfgId(5), &cfg);

    const key1 = WideningKey.init(point, &state1);
    const key2 = WideningKey.init(point, &state2);

    try testing.expect(!key1.eql(key2));
    try testing.expect(key1.hash() != key2.hash());
}

test "WideningKey HashContext works with HashMap" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state = ProgramState.init(allocator);
    defer state.deinit();

    const point1 = ProgramPoint.initPre(ids.cfgId(5), &cfg);
    const point2 = ProgramPoint.initPre(ids.cfgId(6), &cfg);

    const key1 = WideningKey.init(point1, &state);
    const key2 = WideningKey.init(point2, &state);

    var map = std.HashMap(WideningKey, u32, WideningKey.HashContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer map.deinit();

    try map.put(key1, 100);
    try map.put(key2, 200);

    try testing.expectEqual(@as(?u32, 100), map.get(key1));
    try testing.expectEqual(@as(?u32, 200), map.get(key2));
}

test "ProgramState widen composes domain widenings" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    // Set up environments with overlapping and disjoint variables
    try state1.setVar(ids.varId(1), .{ .concrete_int = 10 });
    try state1.setVar(ids.varId(2), .{ .concrete_int = 20 });

    try state2.setVar(ids.varId(1), .{ .concrete_int = 10 }); // same
    try state2.setVar(ids.varId(2), .{ .concrete_int = 30 }); // different

    // Add constraints
    try state1.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 10));
    try state2.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 10)); // shared

    // Track resources
    try state1.trackAllocation(ids.varId(100));
    try state2.trackAllocation(ids.varId(100)); // same

    var widened = try state1.widen(&state2);
    defer widened.deinit();

    // var1 should be preserved (same value)
    const val1 = widened.getVar(ids.varId(1));
    try testing.expect(val1 != null);
    try testing.expect(val1.?.eql(.{ .concrete_int = 10 }));

    // var2 should be widened to unknown (different values)
    const val2 = widened.getVar(ids.varId(2));
    try testing.expect(val2 != null);
    try testing.expect(val2.?.isUnknown());

    // Shared constraint should remain
    try testing.expectEqual(@as(usize, 1), widened.constraintCount());

    // Resource state should remain (both agree)
    try testing.expectEqual(ResourceState.allocated, widened.getRegionState(ids.varId(100)).?);
}

test "ProgramState widen clears cached hash" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    // Compute hash before widening
    _ = state1.computeHash();
    try testing.expect(state1.cached_hash != null);

    var widened = try state1.widen(&state2);
    defer widened.deinit();

    // Widened state should have null cached_hash
    try testing.expectEqual(@as(?u64, null), widened.cached_hash);
}

test "ProgramState widen error_state join same" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Both states have same error_state
    var state1 = ProgramState.init(allocator);
    defer state1.deinit();
    state1.setErrorState(.normal);

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();
    state2.setErrorState(.normal);

    var widened = try state1.widen(&state2);
    defer widened.deinit();

    try testing.expectEqual(ErrorState.normal, widened.getErrorState());

    // Now test with error_active
    var state3 = ProgramState.init(allocator);
    defer state3.deinit();
    state3.setErrorState(.error_active);

    var state4 = ProgramState.init(allocator);
    defer state4.deinit();
    state4.setErrorState(.error_active);

    var widened2 = try state3.widen(&state4);
    defer widened2.deinit();

    try testing.expectEqual(ErrorState.error_active, widened2.getErrorState());
}

test "ProgramState widen error_state join different becomes error_active" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();
    state1.setErrorState(.normal);

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();
    state2.setErrorState(.error_active);

    var widened = try state1.widen(&state2);
    defer widened.deinit();

    // Different error states should become error_active (conservative)
    try testing.expectEqual(ErrorState.error_active, widened.getErrorState());

    // Test the reverse
    var widened2 = try state2.widen(&state1);
    defer widened2.deinit();

    try testing.expectEqual(ErrorState.error_active, widened2.getErrorState());
}

test "ProgramState widen preserves inline depth and call stack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cfg = Cfg.init(allocator);
    defer cfg.deinit();

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();
    state1.incrementInlineDepth();
    try state1.pushCallSite(CallSite{ .call_node = ids.cfgId(1), .caller_cfg = &cfg, .return_node = ids.cfgId(2) });

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();
    state2.incrementInlineDepth();
    try state2.pushCallSite(CallSite{ .call_node = ids.cfgId(1), .caller_cfg = &cfg, .return_node = ids.cfgId(2) });

    var widened = try state1.widen(&state2);
    defer widened.deinit();

    // Inline depth and call stack should be preserved from self
    try testing.expectEqual(@as(u32, 1), widened.getInlineDepth());
    try testing.expectEqual(@as(usize, 1), widened.call_stack.items.len);
    try testing.expectEqual(ids.cfgId(1), widened.call_stack.items[0].call_node);
}

test "ProgramState widen with empty states" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    var widened = try state1.widen(&state2);
    defer widened.deinit();

    try testing.expectEqual(@as(usize, 0), widened.envSize());
    try testing.expectEqual(@as(usize, 0), widened.constraintCount());
    try testing.expectEqual(ErrorState.normal, widened.getErrorState());
    try testing.expectEqual(@as(u32, 0), widened.getInlineDepth());
}

test "ProgramState subsumes respects precision ordering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var general = ProgramState.init(allocator);
    defer general.deinit();

    var specific = ProgramState.init(allocator);
    defer specific.deinit();

    try specific.setVar(ids.varId(1), .{ .concrete_int = 1 });
    try specific.addConstraint(.{ .null_check = .{ .var_id = ids.varId(2), .is_null = false } });

    try testing.expect(general.subsumes(&specific));
    try testing.expect(!specific.subsumes(&general));
}

test "ProgramState widen store violations union" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var state1 = ProgramState.init(allocator);
    defer state1.deinit();

    var state2 = ProgramState.init(allocator);
    defer state2.deinit();

    // Create a violation in state1 (double free)
    try state1.trackAllocation(ids.varId(100));
    try state1.trackFree(ids.varId(100), 1);
    try state1.trackFree(ids.varId(100), 2);

    // Create a different violation in state2 (use after free)
    try state2.trackAllocation(ids.varId(200));
    try state2.trackFree(ids.varId(200), 3);
    try state2.trackUse(ids.varId(200), 4);

    try testing.expectEqual(@as(usize, 1), state1.getStoreViolations().len);
    try testing.expectEqual(@as(usize, 1), state2.getStoreViolations().len);

    var widened = try state1.widen(&state2);
    defer widened.deinit();

    // Both violations should be present (union)
    try testing.expectEqual(@as(usize, 2), widened.getStoreViolations().len);
}
