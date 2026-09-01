const std = @import("std");
const ids = @import("../ids.zig");
const AbstractValue = @import("value.zig").AbstractValue;
const Constraint = @import("constraints.zig").Constraint;
const ConstraintManager = @import("constraints.zig").ConstraintManager;
const ProgramState = @import("state.zig").ProgramState;
const AstNodeId = ids.AstNodeId;
const VarId = ids.VarId;

/// Function summary capturing the effects of a function call.
/// Summaries store preconditions, postconditions, and error behavior to enable
/// reuse across call sites without re-analyzing the function body.
pub const FunctionSummary = struct {
    /// The AST node index of the function
    fn_ast_node: AstNodeId,
    /// Preconditions: constraints on parameter values that affect behavior
    preconditions: std.ArrayList(Constraint),
    /// Postconditions: constraints on the return value
    postconditions: std.ArrayList(Constraint),
    /// Whether the function can return an error
    may_return_error: bool,
    /// Whether the function always returns an error
    always_returns_error: bool,
    /// Whether the function may not return (e.g., @panic, noreturn)
    may_not_return: bool,
    /// Abstract value representing the return value (if known)
    return_value: AbstractValue,
    /// Whether the function has side effects (modifies global state, I/O, etc.)
    has_side_effects: bool,
    /// Number of times this summary has been used
    use_count: u32,
    /// Allocator used for internal data structures
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, fn_ast_node: AstNodeId) FunctionSummary {
        return .{
            .fn_ast_node = fn_ast_node,
            .preconditions = .empty,
            .postconditions = .empty,
            .may_return_error = false,
            .always_returns_error = false,
            .may_not_return = false,
            .return_value = .unknown,
            .has_side_effects = true, // Conservative default
            .use_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FunctionSummary) void {
        self.preconditions.deinit(self.allocator);
        self.postconditions.deinit(self.allocator);
    }

    /// Add a precondition constraint.
    pub fn addPrecondition(self: *FunctionSummary, constraint: Constraint) !void {
        try self.preconditions.append(self.allocator, constraint);
    }

    /// Add a postcondition constraint.
    pub fn addPostcondition(self: *FunctionSummary, constraint: Constraint) !void {
        try self.postconditions.append(self.allocator, constraint);
    }

    /// Set the error behavior.
    pub fn setErrorBehavior(self: *FunctionSummary, may_error: bool, always_error: bool) void {
        self.may_return_error = may_error;
        self.always_returns_error = always_error;
    }

    /// Set the return value.
    pub fn setReturnValue(self: *FunctionSummary, value: AbstractValue) void {
        self.return_value = value;
    }

    /// Mark as having no side effects.
    pub fn markPure(self: *FunctionSummary) void {
        self.has_side_effects = false;
    }

    /// Increment use count.
    pub fn recordUse(self: *FunctionSummary) void {
        self.use_count += 1;
    }

    /// Check if the summary is applicable given the current state.
    /// Returns true if all preconditions are satisfiable in the given state.
    pub fn isApplicable(self: *const FunctionSummary, state: *const ProgramState) bool {
        for (self.preconditions.items) |precond| {
            // Check if the precondition is satisfiable given the current environment
            const var_id: ?VarId = switch (precond) {
                .int_compare => |ic| ic.var_id,
                .null_check => |nc| nc.var_id,
                .bool_check => |bc| bc.var_id,
                .var_compare => |vc| vc.var1_id,
                .literal_bool => |lb| {
                    // Literal bool preconditions are immediately decidable
                    if (!lb.value) return false;
                    continue;
                },
            };

            if (var_id) |vid| {
                if (state.getVar(vid)) |val| {
                    // Check if the current value is compatible with the precondition
                    const refined = ConstraintManager.refineValue(val, precond);
                    if (refined == null) {
                        return false; // Precondition not satisfiable
                    }
                }
            }
        }
        return true;
    }

    /// Apply this summary to a program state, updating it with the postconditions.
    /// Returns true if the resulting state is satisfiable, false if postconditions
    /// contradict existing constraints (infeasible state).
    pub fn applyToState(self: *FunctionSummary, state: *ProgramState) !bool {
        // Apply postconditions
        for (self.postconditions.items) |postcond| {
            try state.addConstraint(postcond);
        }

        // Update error state based on summary
        if (self.always_returns_error) {
            state.setErrorState(.error_active);
        }

        self.recordUse();

        // Check if the resulting state is satisfiable
        return state.isSatisfiable();
    }
};

/// Cache for function summaries, keyed by function AST node index.
/// Stores analyzed summaries for reuse across call sites.
pub const SummaryCache = struct {
    /// Map from function AST node index to summary
    summaries: std.AutoHashMap(AstNodeId, *FunctionSummary),
    /// Allocator for summaries
    allocator: std.mem.Allocator,
    /// Statistics: number of cache hits
    cache_hits: u32,
    /// Statistics: number of cache misses
    cache_misses: u32,

    pub fn init(allocator: std.mem.Allocator) SummaryCache {
        return .{
            .summaries = std.AutoHashMap(AstNodeId, *FunctionSummary).init(allocator),
            .allocator = allocator,
            .cache_hits = 0,
            .cache_misses = 0,
        };
    }

    pub fn deinit(self: *SummaryCache) void {
        var iter = self.summaries.valueIterator();
        while (iter.next()) |summary_ptr| {
            summary_ptr.*.deinit();
            self.allocator.destroy(summary_ptr.*);
        }
        self.summaries.deinit();
    }

    /// Get a summary from the cache.
    pub fn get(self: *SummaryCache, fn_ast_node: AstNodeId) ?*FunctionSummary {
        if (self.summaries.get(fn_ast_node)) |summary| {
            self.cache_hits += 1;
            return summary;
        }
        self.cache_misses += 1;
        return null;
    }

    /// Store a summary in the cache.
    pub fn put(self: *SummaryCache, summary: FunctionSummary) !void {
        // Allocate on heap for stable pointer
        const summary_ptr = try self.allocator.create(FunctionSummary);
        errdefer self.allocator.destroy(summary_ptr);
        summary_ptr.* = summary;
        try self.summaries.put(summary.fn_ast_node, summary_ptr);
    }

    /// Check if a function has a cached summary.
    pub fn has(self: *const SummaryCache, fn_ast_node: AstNodeId) bool {
        return self.summaries.contains(fn_ast_node);
    }

    /// Get cache statistics.
    pub fn getStats(self: *const SummaryCache) struct { hits: u32, misses: u32, count: usize } {
        return .{
            .hits = self.cache_hits,
            .misses = self.cache_misses,
            .count = self.summaries.count(),
        };
    }

    /// Clear all cached summaries.
    pub fn clear(self: *SummaryCache) void {
        var iter = self.summaries.valueIterator();
        while (iter.next()) |summary_ptr| {
            summary_ptr.*.deinit();
            self.allocator.destroy(summary_ptr.*);
        }
        self.summaries.clearAndFree();
        self.cache_hits = 0;
        self.cache_misses = 0;
    }
};

test "FunctionSummary basic operations" {
    const allocator = std.testing.allocator;

    var summary = FunctionSummary.init(allocator, ids.astId(42));
    defer summary.deinit();

    try std.testing.expectEqual(ids.astId(42), summary.fn_ast_node);
    try std.testing.expect(!summary.may_return_error);
    try std.testing.expect(!summary.always_returns_error);
    try std.testing.expect(summary.has_side_effects); // Conservative default
    try std.testing.expectEqual(@as(u32, 0), summary.use_count);

    // Test error behavior setting
    summary.setErrorBehavior(true, false);
    try std.testing.expect(summary.may_return_error);
    try std.testing.expect(!summary.always_returns_error);

    // Test marking pure
    summary.markPure();
    try std.testing.expect(!summary.has_side_effects);

    // Test return value setting
    summary.setReturnValue(.{ .concrete_int = 100 });
    try std.testing.expect(summary.return_value.eql(.{ .concrete_int = 100 }));

    // Test use count
    summary.recordUse();
    try std.testing.expectEqual(@as(u32, 1), summary.use_count);
    summary.recordUse();
    try std.testing.expectEqual(@as(u32, 2), summary.use_count);
}

test "FunctionSummary preconditions and postconditions" {
    const allocator = std.testing.allocator;

    var summary = FunctionSummary.init(allocator, ids.astId(1));
    defer summary.deinit();

    // Add precondition
    try summary.addPrecondition(Constraint.intCompare(ids.varId(10), .ge, 0));
    try std.testing.expectEqual(@as(usize, 1), summary.preconditions.items.len);

    // Add postcondition
    try summary.addPostcondition(Constraint.intCompare(ids.varId(20), .eq, 100));
    try std.testing.expectEqual(@as(usize, 1), summary.postconditions.items.len);
}

test "FunctionSummary applicability check" {
    const allocator = std.testing.allocator;

    var summary = FunctionSummary.init(allocator, ids.astId(1));
    defer summary.deinit();

    // Create a state
    var state = ProgramState.init(allocator);
    defer state.deinit();

    // Summary with no preconditions is always applicable
    try std.testing.expect(summary.isApplicable(&state));

    // Add a precondition that x >= 0
    try summary.addPrecondition(Constraint.intCompare(ids.varId(10), .ge, 0));

    // State with x = 5 (satisfies x >= 0)
    try state.setVar(ids.varId(10), .{ .concrete_int = 5 });
    try std.testing.expect(summary.isApplicable(&state));

    // State with x = -5 (does not satisfy x >= 0)
    try state.setVar(ids.varId(10), .{ .concrete_int = -5 });
    try std.testing.expect(!summary.isApplicable(&state));
}

test "SummaryCache basic operations" {
    const allocator = std.testing.allocator;

    var cache = SummaryCache.init(allocator);
    defer cache.deinit();

    // Initially empty
    try std.testing.expect(!cache.has(ids.astId(42)));
    try std.testing.expect(cache.get(ids.astId(42)) == null);

    const stats1 = cache.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats1.hits);
    try std.testing.expectEqual(@as(u32, 1), stats1.misses); // get() incremented misses
    try std.testing.expectEqual(@as(usize, 0), stats1.count);

    // Add a summary
    var summary = FunctionSummary.init(allocator, ids.astId(42));
    summary.setErrorBehavior(true, false);
    try cache.put(summary);

    // Should now be present
    try std.testing.expect(cache.has(ids.astId(42)));
    const retrieved = cache.get(ids.astId(42));
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.may_return_error);

    const stats2 = cache.getStats();
    try std.testing.expectEqual(@as(u32, 1), stats2.hits);
    try std.testing.expectEqual(@as(usize, 1), stats2.count);
}

test "SummaryCache clear" {
    const allocator = std.testing.allocator;

    var cache = SummaryCache.init(allocator);
    defer cache.deinit();

    // Add some summaries
    const summary1 = FunctionSummary.init(allocator, ids.astId(1));
    const summary2 = FunctionSummary.init(allocator, ids.astId(2));
    try cache.put(summary1);
    try cache.put(summary2);

    try std.testing.expectEqual(@as(usize, 2), cache.getStats().count);

    // Clear the cache
    cache.clear();

    try std.testing.expectEqual(@as(usize, 0), cache.getStats().count);
    try std.testing.expect(!cache.has(ids.astId(1)));
    try std.testing.expect(!cache.has(ids.astId(2)));
}

test "SummaryCache reuse across call sites" {
    const allocator = std.testing.allocator;

    var cache = SummaryCache.init(allocator);
    defer cache.deinit();

    // Add a summary
    var summary = FunctionSummary.init(allocator, ids.astId(100));
    summary.markPure();
    try cache.put(summary);

    // Simulate multiple lookups (reuse across call sites)
    _ = cache.get(ids.astId(100));
    _ = cache.get(ids.astId(100));
    _ = cache.get(ids.astId(100));

    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u32, 3), stats.hits);
    try std.testing.expectEqual(@as(usize, 1), stats.count);
}

test "FunctionSummary apply to state" {
    const allocator = std.testing.allocator;

    var summary = FunctionSummary.init(allocator, ids.astId(1));
    defer summary.deinit();

    // Add postcondition that return value is positive
    try summary.addPostcondition(Constraint.intCompare(ids.varId(50), .gt, 0));

    var state = ProgramState.init(allocator);
    defer state.deinit();

    // Apply summary to state
    const is_satisfiable = try summary.applyToState(&state);
    try std.testing.expect(is_satisfiable);

    // Use count should be incremented
    try std.testing.expectEqual(@as(u32, 1), summary.use_count);

    // Constraint should be added to state
    try std.testing.expectEqual(@as(usize, 1), state.constraintCount());
}

test "FunctionSummary error behavior propagation" {
    const allocator = std.testing.allocator;

    var summary = FunctionSummary.init(allocator, ids.astId(1));
    defer summary.deinit();

    summary.setErrorBehavior(true, true); // always returns error

    var state = ProgramState.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.isNormalPath());

    // Apply summary to state
    const is_satisfiable = try summary.applyToState(&state);
    try std.testing.expect(is_satisfiable);

    // State should now be on error path
    try std.testing.expect(state.isErrorPath());
}
