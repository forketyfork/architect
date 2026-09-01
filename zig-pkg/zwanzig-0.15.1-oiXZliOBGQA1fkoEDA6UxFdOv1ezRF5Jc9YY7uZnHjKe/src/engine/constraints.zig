const std = @import("std");
const ids = @import("../ids.zig");
const AbstractValue = @import("value.zig").AbstractValue;
const Environment = @import("env.zig").Environment;
const VarId = ids.VarId;

/// Maximum number of constraints per state to prevent state explosion in loops.
/// When this limit is reached, new constraints are silently dropped (over-approximation).
const max_constraints: usize = 50;

/// Comparison operator for constraints.
pub const CompareOp = enum {
    eq, // ==
    ne, // !=
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
};

/// A constraint on a variable's value.
/// Constraints are used to track path conditions from branch expressions.
pub const Constraint = union(enum) {
    /// Variable compared to an integer value: var <op> value
    int_compare: struct {
        var_id: VarId,
        op: CompareOp,
        value: i64,
    },
    /// Variable compared to null: var == null or var != null
    null_check: struct {
        var_id: VarId,
        is_null: bool, // true = var is null, false = var is non-null
    },
    /// Variable compared to another variable: var1 <op> var2
    var_compare: struct {
        var1_id: VarId,
        op: CompareOp,
        var2_id: VarId,
    },
    /// Variable expected to be a boolean value: var == true or var == false
    bool_check: struct {
        var_id: VarId,
        expected: bool, // true = var must be true, false = var must be false
    },
    /// Literal boolean constraint: always satisfiable (true) or never satisfiable (false).
    /// Used for literal `true`/`false` conditions to enable proper branch pruning.
    literal_bool: struct {
        value: bool, // true = always satisfiable, false = never satisfiable
    },

    pub fn eql(self: Constraint, other: Constraint) bool {
        return switch (self) {
            .int_compare => |ic1| switch (other) {
                .int_compare => |ic2| ic1.var_id == ic2.var_id and ic1.op == ic2.op and ic1.value == ic2.value,
                else => false,
            },
            .null_check => |nc1| switch (other) {
                .null_check => |nc2| nc1.var_id == nc2.var_id and nc1.is_null == nc2.is_null,
                else => false,
            },
            .var_compare => |vc1| switch (other) {
                .var_compare => |vc2| vc1.var1_id == vc2.var1_id and vc1.op == vc2.op and vc1.var2_id == vc2.var2_id,
                else => false,
            },
            .bool_check => |bc1| switch (other) {
                .bool_check => |bc2| bc1.var_id == bc2.var_id and bc1.expected == bc2.expected,
                else => false,
            },
            .literal_bool => |lb1| switch (other) {
                .literal_bool => |lb2| lb1.value == lb2.value,
                else => false,
            },
        };
    }

    pub fn hash(self: Constraint) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag_byte: u8 = switch (self) {
            .int_compare => 0,
            .null_check => 1,
            .var_compare => 2,
            .bool_check => 3,
            .literal_bool => 4,
        };
        hasher.update(&[_]u8{tag_byte});
        switch (self) {
            .int_compare => |ic| {
                const var_id = ids.varIndex(ic.var_id);
                hasher.update(std.mem.asBytes(&var_id));
                hasher.update(std.mem.asBytes(&ic.op));
                hasher.update(std.mem.asBytes(&ic.value));
            },
            .null_check => |nc| {
                const var_id = ids.varIndex(nc.var_id);
                hasher.update(std.mem.asBytes(&var_id));
                hasher.update(std.mem.asBytes(&nc.is_null));
            },
            .var_compare => |vc| {
                const var1_id = ids.varIndex(vc.var1_id);
                const var2_id = ids.varIndex(vc.var2_id);
                hasher.update(std.mem.asBytes(&var1_id));
                hasher.update(std.mem.asBytes(&vc.op));
                hasher.update(std.mem.asBytes(&var2_id));
            },
            .bool_check => |bc| {
                const var_id = ids.varIndex(bc.var_id);
                hasher.update(std.mem.asBytes(&var_id));
                hasher.update(&[_]u8{if (bc.expected) 1 else 0});
            },
            .literal_bool => |lb| {
                hasher.update(&[_]u8{if (lb.value) 1 else 0});
            },
        }
        return hasher.final();
    }

    /// Create an integer comparison constraint.
    pub fn intCompare(var_id: VarId, op: CompareOp, value: i64) Constraint {
        return .{ .int_compare = .{ .var_id = var_id, .op = op, .value = value } };
    }

    /// Create a null check constraint.
    pub fn nullCheck(var_id: VarId, is_null: bool) Constraint {
        return .{ .null_check = .{ .var_id = var_id, .is_null = is_null } };
    }

    /// Create a variable comparison constraint.
    pub fn varCompare(var1_id: VarId, op: CompareOp, var2_id: VarId) Constraint {
        return .{ .var_compare = .{ .var1_id = var1_id, .op = op, .var2_id = var2_id } };
    }

    /// Create a boolean check constraint.
    pub fn boolCheck(var_id: VarId, expected: bool) Constraint {
        return .{ .bool_check = .{ .var_id = var_id, .expected = expected } };
    }

    /// Create a literal boolean constraint for compile-time known conditions.
    /// Use this for literal `true`/`false` to enable proper branch pruning.
    pub fn literalBool(value: bool) Constraint {
        return .{ .literal_bool = .{ .value = value } };
    }

    /// Get the negation of this constraint (for else branches).
    pub fn negate(self: Constraint) Constraint {
        return switch (self) {
            .int_compare => |ic| .{ .int_compare = .{
                .var_id = ic.var_id,
                .op = negateOp(ic.op),
                .value = ic.value,
            } },
            .null_check => |nc| .{ .null_check = .{
                .var_id = nc.var_id,
                .is_null = !nc.is_null,
            } },
            .var_compare => |vc| .{ .var_compare = .{
                .var1_id = vc.var1_id,
                .op = negateOp(vc.op),
                .var2_id = vc.var2_id,
            } },
            .bool_check => |bc| .{ .bool_check = .{
                .var_id = bc.var_id,
                .expected = !bc.expected,
            } },
            .literal_bool => |lb| .{ .literal_bool = .{
                .value = !lb.value,
            } },
        };
    }

    fn negateOp(op: CompareOp) CompareOp {
        return switch (op) {
            .eq => .ne,
            .ne => .eq,
            .lt => .ge,
            .le => .gt,
            .gt => .le,
            .ge => .lt,
        };
    }
};

/// Manages path constraints for symbolic execution.
/// Tracks a set of constraints that must all hold on a given path.
pub const ConstraintManager = struct {
    /// List of active constraints on this path
    constraints: std.ArrayList(Constraint),
    allocator: std.mem.Allocator,
    /// Per-variable constraint lists for incremental contradiction checks
    per_var_constraints: std.AutoHashMap(VarId, VarConstraintLists),
    /// Whether a contradiction has been detected
    has_contradiction: bool,

    const VarConstraintLists = struct {
        int_constraints: std.ArrayList(Constraint) = .empty,
        null_constraints: std.ArrayList(Constraint) = .empty,
        bool_constraints: std.ArrayList(Constraint) = .empty,

        fn deinit(self: *VarConstraintLists, allocator: std.mem.Allocator) void {
            self.int_constraints.deinit(allocator);
            self.null_constraints.deinit(allocator);
            self.bool_constraints.deinit(allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator) ConstraintManager {
        return .{
            .constraints = .empty,
            .allocator = allocator,
            .per_var_constraints = std.AutoHashMap(VarId, VarConstraintLists).init(allocator),
            .has_contradiction = false,
        };
    }

    pub fn deinit(self: *ConstraintManager) void {
        self.constraints.deinit(self.allocator);
        var iter = self.per_var_constraints.valueIterator();
        while (iter.next()) |lists| {
            lists.deinit(self.allocator);
        }
        self.per_var_constraints.deinit();
    }

    pub fn clone(self: *const ConstraintManager) !ConstraintManager {
        var new_cm = ConstraintManager.init(self.allocator);
        errdefer new_cm.deinit();
        for (self.constraints.items) |c| {
            try new_cm.addConstraint(c);
        }
        new_cm.has_contradiction = self.has_contradiction;
        return new_cm;
    }

    /// Add a constraint to the manager.
    /// If the maximum constraint limit is reached, the constraint is silently dropped
    /// to prevent state explosion in loops (safe over-approximation).
    pub fn addConstraint(self: *ConstraintManager, constraint: Constraint) !void {
        // Limit constraints to prevent state explosion
        if (self.constraints.items.len >= max_constraints) {
            return;
        }
        // Check for duplicate before adding
        for (self.constraints.items) |c| {
            if (c.eql(constraint)) return;
        }
        try self.updateContradictionState(constraint);
        try self.constraints.append(self.allocator, constraint);
    }

    /// Check if the current constraint set is satisfiable.
    /// Returns false if there's a definite contradiction.
    pub fn isSatisfiable(self: *const ConstraintManager, env: *const Environment) bool {
        if (self.has_contradiction) {
            return false;
        }
        // Check each constraint against the environment
        for (self.constraints.items) |constraint| {
            if (!self.isConstraintSatisfiable(constraint, env)) {
                return false;
            }
        }

        return true;
    }

    fn updateContradictionState(self: *ConstraintManager, constraint: Constraint) !void {
        if (self.has_contradiction) return;
        switch (constraint) {
            .int_compare => |ic| {
                const entry = try self.per_var_constraints.getOrPut(ic.var_id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{};
                }
                var contradiction = false;
                for (entry.value_ptr.int_constraints.items) |existing| {
                    if (self.areContradictory(existing, constraint)) {
                        contradiction = true;
                        break;
                    }
                }
                try entry.value_ptr.int_constraints.append(self.allocator, constraint);
                if (contradiction) {
                    self.has_contradiction = true;
                }
            },
            .null_check => |nc| {
                const entry = try self.per_var_constraints.getOrPut(nc.var_id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{};
                }
                var contradiction = false;
                for (entry.value_ptr.null_constraints.items) |existing| {
                    if (self.areContradictory(existing, constraint)) {
                        contradiction = true;
                        break;
                    }
                }
                try entry.value_ptr.null_constraints.append(self.allocator, constraint);
                if (contradiction) {
                    self.has_contradiction = true;
                }
            },
            .bool_check => |bc| {
                const entry = try self.per_var_constraints.getOrPut(bc.var_id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{};
                }
                var contradiction = false;
                for (entry.value_ptr.bool_constraints.items) |existing| {
                    if (self.areContradictory(existing, constraint)) {
                        contradiction = true;
                        break;
                    }
                }
                try entry.value_ptr.bool_constraints.append(self.allocator, constraint);
                if (contradiction) {
                    self.has_contradiction = true;
                }
            },
            .var_compare => {},
            .literal_bool => |lb| {
                // literal_bool(false) is a contradiction by itself
                if (!lb.value) {
                    self.has_contradiction = true;
                }
            },
        }
    }

    fn isConstraintSatisfiable(self: *const ConstraintManager, constraint: Constraint, env: *const Environment) bool {
        _ = self;
        switch (constraint) {
            .int_compare => |ic| {
                if (env.get(ic.var_id)) |val| {
                    return isValueCompatibleWithIntConstraint(val, ic.op, ic.value);
                }
                return true; // Unknown variable, constraint might be satisfiable
            },
            .null_check => |nc| {
                if (env.get(nc.var_id)) |val| {
                    return isValueCompatibleWithNullCheck(val, nc.is_null);
                }
                return true;
            },
            .bool_check => |bc| {
                if (env.get(bc.var_id)) |val| {
                    return isValueCompatibleWithBoolCheck(val, bc.expected);
                }
                return true;
            },
            .var_compare => {
                // Variable comparisons are conservatively satisfiable unless we have concrete values
                return true;
            },
            .literal_bool => |lb| {
                // Literal boolean constraints are definitively satisfiable or not
                return lb.value;
            },
        }
    }

    fn areContradictory(self: *const ConstraintManager, c1: Constraint, c2: Constraint) bool {
        _ = self;
        switch (c1) {
            .int_compare => |ic1| {
                switch (c2) {
                    .int_compare => |ic2| {
                        if (ic1.var_id != ic2.var_id) return false;
                        return areIntConstraintsContradictory(ic1.op, ic1.value, ic2.op, ic2.value);
                    },
                    else => return false,
                }
            },
            .null_check => |nc1| {
                switch (c2) {
                    .null_check => |nc2| {
                        // x == null AND x != null is contradictory
                        return nc1.var_id == nc2.var_id and nc1.is_null != nc2.is_null;
                    },
                    else => return false,
                }
            },
            .bool_check => |bc1| {
                switch (c2) {
                    .bool_check => |bc2| {
                        // x == true AND x == false is contradictory
                        return bc1.var_id == bc2.var_id and bc1.expected != bc2.expected;
                    },
                    else => return false,
                }
            },
            .var_compare => return false,
            .literal_bool => |lb1| {
                switch (c2) {
                    .literal_bool => |lb2| {
                        // literal_bool(true) AND literal_bool(false) is contradictory
                        return lb1.value != lb2.value;
                    },
                    else => return false,
                }
            },
        }
    }

    pub fn size(self: *const ConstraintManager) usize {
        return self.constraints.items.len;
    }

    pub fn eql(self: *const ConstraintManager, other: *const ConstraintManager) bool {
        if (self.constraints.items.len != other.constraints.items.len) return false;
        for (self.constraints.items) |c1| {
            var found = false;
            for (other.constraints.items) |c2| {
                if (c1.eql(c2)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    pub fn computeHash(self: *const ConstraintManager) u64 {
        var combined_hash: u64 = 0;
        for (self.constraints.items) |c| {
            combined_hash ^= c.hash();
        }
        return combined_hash;
    }

    /// Returns true if `self` is at least as general as `other`.
    /// For constraints, fewer constraints means more general, so we require
    /// that every constraint in `self` is present in `other`.
    pub fn subsumes(self: *const ConstraintManager, other: *const ConstraintManager) bool {
        for (self.constraints.items) |c1| {
            var found = false;
            for (other.constraints.items) |c2| {
                if (c1.eql(c2)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// Widening operator for constraint managers.
    /// Used at widening points to ensure convergence.
    /// This implements a sound but simple policy: keep only constraints that appear in both.
    /// This is the intersection of constraints, which is sound (over-approximation).
    pub fn widen(self: *const ConstraintManager, other: *const ConstraintManager) !ConstraintManager {
        var result = ConstraintManager.init(self.allocator);
        errdefer result.deinit();

        // Keep only constraints that appear in both managers (intersection)
        for (self.constraints.items) |c1| {
            for (other.constraints.items) |c2| {
                if (c1.eql(c2)) {
                    try result.addConstraint(c1);
                    break;
                }
            }
        }

        return result;
    }

    /// Refine an abstract value based on a constraint.
    /// Returns the refined value, or null if the constraint is unsatisfiable.
    pub fn refineValue(value: AbstractValue, constraint: Constraint) ?AbstractValue {
        switch (constraint) {
            .int_compare => |ic| {
                return refineValueWithIntConstraint(value, ic.op, ic.value);
            },
            .null_check => |nc| {
                if (nc.is_null) {
                    // Constraint: variable is null
                    return switch (value) {
                        .null_val => .null_val,
                        .non_null => null, // Contradiction
                        .unknown => .null_val,
                        else => null, // Concrete int, range, or bool can't be null
                    };
                } else {
                    // Constraint: variable is non-null
                    return switch (value) {
                        .null_val => null, // Contradiction
                        .non_null => .non_null,
                        .unknown => .non_null,
                        .int_range, .concrete_int, .concrete_bool => value, // Ints and bools are non-null
                    };
                }
            },
            .bool_check => |bc| {
                return refineValueWithBoolCheck(value, bc.expected);
            },
            .var_compare => return value, // No refinement for var-var comparisons yet
            .literal_bool => |lb| {
                // Literal bool constraints don't refine variable values;
                // they only affect path satisfiability
                return if (lb.value) value else null;
            },
        }
    }
};

fn isValueCompatibleWithIntConstraint(val: AbstractValue, op: CompareOp, value: i64) bool {
    switch (val) {
        .concrete_int => |v| {
            return switch (op) {
                .eq => v == value,
                .ne => v != value,
                .lt => v < value,
                .le => v <= value,
                .gt => v > value,
                .ge => v >= value,
            };
        },
        .int_range => |r| {
            return switch (op) {
                .eq => r.contains(value),
                .ne => !(r.min == value and r.max == value), // Only contradictory if range is single value equal to value
                .lt => r.min < value, // At least some values can be < value
                .le => r.min <= value,
                .gt => r.max > value,
                .ge => r.max >= value,
            };
        },
        else => return true, // Unknown, null, non_null are conservatively compatible
    }
}

fn isValueCompatibleWithNullCheck(val: AbstractValue, is_null: bool) bool {
    if (is_null) {
        // Checking if variable is null
        return switch (val) {
            .null_val => true,
            .non_null => false,
            .concrete_int, .int_range, .concrete_bool => false, // Ints and bools are not null
            .unknown => true,
        };
    } else {
        // Checking if variable is non-null
        return switch (val) {
            .null_val => false,
            .non_null => true,
            .concrete_int, .int_range, .concrete_bool => true,
            .unknown => true,
        };
    }
}

fn isValueCompatibleWithBoolCheck(val: AbstractValue, expected: bool) bool {
    return switch (val) {
        .concrete_bool => |b| b == expected,
        .unknown => true, // Conservatively compatible
        else => false, // Ints, ranges, null, non_null are not boolean values
    };
}

fn refineValueWithBoolCheck(value: AbstractValue, expected: bool) ?AbstractValue {
    return switch (value) {
        .unknown => .{ .concrete_bool = expected },
        .concrete_bool => |b| if (b == expected) value else null, // Contradiction if different
        else => null, // Can't refine int/null to boolean - contradiction
    };
}

fn areIntConstraintsContradictory(op1: CompareOp, val1: i64, op2: CompareOp, val2: i64) bool {
    // Check for obvious contradictions
    // x == 5 AND x == 6 is contradictory
    if (op1 == .eq and op2 == .eq and val1 != val2) return true;

    // x == 5 AND x != 5 is contradictory
    if (op1 == .eq and op2 == .ne and val1 == val2) return true;
    if (op1 == .ne and op2 == .eq and val1 == val2) return true;

    // x < 5 AND x > 10 is contradictory (or x > 5 AND x < 5)
    if (op1 == .lt and op2 == .gt and val1 <= val2) return true;
    if (op1 == .gt and op2 == .lt and val1 >= val2) return true;

    // x < 5 AND x >= 5 is contradictory
    if (op1 == .lt and op2 == .ge and val1 <= val2) return true;
    if (op1 == .ge and op2 == .lt and val1 >= val2) return true;

    // x <= 5 AND x > 5 is contradictory
    if (op1 == .le and op2 == .gt and val1 == val2) return true;
    if (op1 == .gt and op2 == .le and val1 == val2) return true;

    // x == 5 AND x < 5 is contradictory
    if (op1 == .eq and op2 == .lt and val1 >= val2) return true;
    if (op1 == .lt and op2 == .eq and val1 <= val2) return true;

    // x == 5 AND x > 5 is contradictory
    if (op1 == .eq and op2 == .gt and val1 <= val2) return true;
    if (op1 == .gt and op2 == .eq and val1 >= val2) return true;

    return false;
}

fn refineValueWithIntConstraint(value: AbstractValue, op: CompareOp, constraint_val: i64) ?AbstractValue {
    switch (value) {
        .unknown => {
            // Refine unknown based on constraint
            return switch (op) {
                .eq => .{ .concrete_int = constraint_val },
                .ne => .unknown, // Still unknown, just not equal to one value
                .lt => blk: {
                    // x < minInt is unsatisfiable
                    if (constraint_val == std.math.minInt(i64)) return null;
                    break :blk .{ .int_range = AbstractValue.IntRange.init(std.math.minInt(i64), constraint_val - 1) };
                },
                .le => .{ .int_range = AbstractValue.IntRange.init(std.math.minInt(i64), constraint_val) },
                .gt => blk: {
                    // x > maxInt is unsatisfiable
                    if (constraint_val == std.math.maxInt(i64)) return null;
                    break :blk .{ .int_range = AbstractValue.IntRange.init(constraint_val + 1, std.math.maxInt(i64)) };
                },
                .ge => .{ .int_range = AbstractValue.IntRange.init(constraint_val, std.math.maxInt(i64)) },
            };
        },
        .concrete_int => |v| {
            const satisfies = switch (op) {
                .eq => v == constraint_val,
                .ne => v != constraint_val,
                .lt => v < constraint_val,
                .le => v <= constraint_val,
                .gt => v > constraint_val,
                .ge => v >= constraint_val,
            };
            return if (satisfies) value else null;
        },
        .int_range => |r| {
            const new_range = switch (op) {
                .eq => if (r.contains(constraint_val)) AbstractValue.IntRange.single(constraint_val) else return null,
                .ne => r, // Can't easily narrow a range for !=
                .lt => blk: {
                    // x < minInt is unsatisfiable
                    if (constraint_val == std.math.minInt(i64)) return null;
                    if (r.min >= constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(r.min, @min(r.max, constraint_val - 1));
                },
                .le => blk: {
                    if (r.min > constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(r.min, @min(r.max, constraint_val));
                },
                .gt => blk: {
                    // x > maxInt is unsatisfiable
                    if (constraint_val == std.math.maxInt(i64)) return null;
                    if (r.max <= constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(@max(r.min, constraint_val + 1), r.max);
                },
                .ge => blk: {
                    if (r.max < constraint_val) return null;
                    break :blk AbstractValue.IntRange.init(@max(r.min, constraint_val), r.max);
                },
            };
            return .{ .int_range = new_range };
        },
        .null_val, .non_null, .concrete_bool => return value,
    }
}

test "Constraint creation and equality" {
    const testing = std.testing;

    const c1 = Constraint.intCompare(ids.varId(1), .eq, 42);
    const c2 = Constraint.intCompare(ids.varId(1), .eq, 42);
    const c3 = Constraint.intCompare(ids.varId(1), .ne, 42);

    try testing.expect(c1.eql(c2));
    try testing.expect(!c1.eql(c3));
}

test "Constraint negation" {
    const testing = std.testing;

    const c1 = Constraint.intCompare(ids.varId(1), .eq, 42);
    const neg = c1.negate();
    try testing.expect(neg.eql(Constraint.intCompare(ids.varId(1), .ne, 42)));

    const c2 = Constraint.nullCheck(ids.varId(2), true);
    const neg2 = c2.negate();
    try testing.expect(neg2.eql(Constraint.nullCheck(ids.varId(2), false)));
}

test "ConstraintManager basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try testing.expectEqual(@as(usize, 0), cm.size());

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm.addConstraint(Constraint.nullCheck(ids.varId(2), true));

    try testing.expectEqual(@as(usize, 2), cm.size());
}

test "ConstraintManager cloning" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm.addConstraint(Constraint.nullCheck(ids.varId(2), true));

    var cm2 = try cm.clone();
    defer cm2.deinit();

    try testing.expect(cm.eql(&cm2));
}

test "ConstraintManager satisfiability with environment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try env.set(ids.varId(1), .{ .concrete_int = 42 });

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));

    try testing.expect(cm.isSatisfiable(&env));

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 43));
    try testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager null check satisfiability" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try env.set(ids.varId(1), .null_val);

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.nullCheck(ids.varId(1), true));
    try testing.expect(cm.isSatisfiable(&env));

    try cm.addConstraint(Constraint.nullCheck(ids.varId(1), false));
    try testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager contradictory constraints" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try env.set(ids.varId(1), .{ .concrete_int = 42 });

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm.addConstraint(Constraint.intCompare(ids.varId(1), .ne, 42));

    try testing.expect(!cm.isSatisfiable(&env));
}

test "ConstraintManager refineValue for int constraint" {
    const testing = std.testing;

    const refined = ConstraintManager.refineValue(.unknown, Constraint.intCompare(ids.varId(1), .eq, 42));
    try testing.expect(refined != null);
    try testing.expect(refined.?.eql(.{ .concrete_int = 42 }));
}

test "ConstraintManager refineValue for null constraint" {
    const testing = std.testing;

    const refined = ConstraintManager.refineValue(.unknown, Constraint.nullCheck(ids.varId(1), true));
    try testing.expect(refined != null);
    try testing.expect(refined.?.eql(.null_val));
}

test "areIntConstraintsContradictory" {
    const testing = std.testing;

    try testing.expect(areIntConstraintsContradictory(.eq, 5, .eq, 6));
    try testing.expect(areIntConstraintsContradictory(.eq, 5, .ne, 5));
    try testing.expect(areIntConstraintsContradictory(.lt, 5, .ge, 5));
    try testing.expect(!areIntConstraintsContradictory(.lt, 5, .gt, 1));
}

test "isValueCompatibleWithIntConstraint" {
    const testing = std.testing;

    const val: AbstractValue = .{ .concrete_int = 10 };
    try testing.expect(isValueCompatibleWithIntConstraint(val, .eq, 10));
    try testing.expect(!isValueCompatibleWithIntConstraint(val, .eq, 11));
}

test "isValueCompatibleWithNullCheck" {
    const testing = std.testing;

    const null_val: AbstractValue = .null_val;
    try testing.expect(isValueCompatibleWithNullCheck(null_val, true));
    try testing.expect(!isValueCompatibleWithNullCheck(null_val, false));
}

test "ConstraintManager widen keeps intersection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm1 = ConstraintManager.init(allocator);
    defer cm1.deinit();

    var cm2 = ConstraintManager.init(allocator);
    defer cm2.deinit();

    // Shared constraint
    const shared = Constraint.intCompare(ids.varId(1), .eq, 42);
    try cm1.addConstraint(shared);
    try cm2.addConstraint(shared);

    // Constraint only in cm1
    try cm1.addConstraint(Constraint.intCompare(ids.varId(2), .lt, 10));

    // Constraint only in cm2
    try cm2.addConstraint(Constraint.nullCheck(ids.varId(3), true));

    var widened = try cm1.widen(&cm2);
    defer widened.deinit();

    // Only the shared constraint should remain
    try testing.expectEqual(@as(usize, 1), widened.size());

    // Verify the shared constraint is present
    var found = false;
    for (widened.constraints.items) |c| {
        if (c.eql(shared)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ConstraintManager widen with empty managers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm1 = ConstraintManager.init(allocator);
    defer cm1.deinit();

    var cm2 = ConstraintManager.init(allocator);
    defer cm2.deinit();

    // Both empty
    var widened1 = try cm1.widen(&cm2);
    defer widened1.deinit();
    try testing.expectEqual(@as(usize, 0), widened1.size());

    // One has constraints, one empty -> result empty (intersection)
    try cm1.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));

    var widened2 = try cm1.widen(&cm2);
    defer widened2.deinit();
    try testing.expectEqual(@as(usize, 0), widened2.size());
}

test "ConstraintManager widen with identical constraints" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm1 = ConstraintManager.init(allocator);
    defer cm1.deinit();

    var cm2 = ConstraintManager.init(allocator);
    defer cm2.deinit();

    try cm1.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm1.addConstraint(Constraint.nullCheck(ids.varId(2), false));

    try cm2.addConstraint(Constraint.intCompare(ids.varId(1), .eq, 42));
    try cm2.addConstraint(Constraint.nullCheck(ids.varId(2), false));

    var widened = try cm1.widen(&cm2);
    defer widened.deinit();

    // All constraints should remain
    try testing.expectEqual(@as(usize, 2), widened.size());
}

test "bool_check constraint creation and equality" {
    const testing = std.testing;

    const c1 = Constraint.boolCheck(ids.varId(1), true);
    const c2 = Constraint.boolCheck(ids.varId(1), true);
    const c3 = Constraint.boolCheck(ids.varId(1), false);

    try testing.expect(c1.eql(c2));
    try testing.expect(!c1.eql(c3));
}

test "bool_check constraint negation" {
    const testing = std.testing;

    const c1 = Constraint.boolCheck(ids.varId(1), true);
    const neg = c1.negate();
    try testing.expect(neg.eql(Constraint.boolCheck(ids.varId(1), false)));

    const c2 = Constraint.boolCheck(ids.varId(2), false);
    const neg2 = c2.negate();
    try testing.expect(neg2.eql(Constraint.boolCheck(ids.varId(2), true)));
}

test "bool_check satisfiability with environment" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    try env.set(ids.varId(1), .{ .concrete_bool = true });

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.boolCheck(ids.varId(1), true));
    try testing.expect(cm.isSatisfiable(&env));

    try cm.addConstraint(Constraint.boolCheck(ids.varId(1), false));
    try testing.expect(!cm.isSatisfiable(&env));
}

test "bool_check contradictory constraints" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    try cm.addConstraint(Constraint.boolCheck(ids.varId(1), true));
    try cm.addConstraint(Constraint.boolCheck(ids.varId(1), false));

    try testing.expect(!cm.isSatisfiable(&env));
}

test "refineValue for bool_check constraint" {
    const testing = std.testing;

    // Refine unknown to concrete bool
    const refined_true = ConstraintManager.refineValue(.unknown, Constraint.boolCheck(ids.varId(1), true));
    try testing.expect(refined_true != null);
    try testing.expect(refined_true.?.eql(.{ .concrete_bool = true }));

    const refined_false = ConstraintManager.refineValue(.unknown, Constraint.boolCheck(ids.varId(1), false));
    try testing.expect(refined_false != null);
    try testing.expect(refined_false.?.eql(.{ .concrete_bool = false }));

    // Compatible bool value returns unchanged
    const same = ConstraintManager.refineValue(.{ .concrete_bool = true }, Constraint.boolCheck(ids.varId(1), true));
    try testing.expect(same != null);
    try testing.expect(same.?.eql(.{ .concrete_bool = true }));

    // Incompatible bool value returns null (contradiction)
    const contradiction = ConstraintManager.refineValue(.{ .concrete_bool = true }, Constraint.boolCheck(ids.varId(1), false));
    try testing.expect(contradiction == null);

    // Non-bool value with bool constraint returns null (contradiction)
    const int_with_bool = ConstraintManager.refineValue(.{ .concrete_int = 42 }, Constraint.boolCheck(ids.varId(1), true));
    try testing.expect(int_with_bool == null);
}

test "isValueCompatibleWithBoolCheck" {
    const testing = std.testing;

    const bool_true: AbstractValue = .{ .concrete_bool = true };
    const bool_false: AbstractValue = .{ .concrete_bool = false };

    try testing.expect(isValueCompatibleWithBoolCheck(bool_true, true));
    try testing.expect(!isValueCompatibleWithBoolCheck(bool_true, false));
    try testing.expect(isValueCompatibleWithBoolCheck(bool_false, false));
    try testing.expect(!isValueCompatibleWithBoolCheck(bool_false, true));

    // Unknown is conservatively compatible
    try testing.expect(isValueCompatibleWithBoolCheck(.unknown, true));
    try testing.expect(isValueCompatibleWithBoolCheck(.unknown, false));

    // Ints are not compatible with bool checks
    try testing.expect(!isValueCompatibleWithBoolCheck(.{ .concrete_int = 1 }, true));
}

test "ConstraintManager subsumes ordering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var general = ConstraintManager.init(allocator);
    defer general.deinit();

    var specific = ConstraintManager.init(allocator);
    defer specific.deinit();

    try specific.addConstraint(.{ .null_check = .{ .var_id = ids.varId(1), .is_null = false } });

    try testing.expect(general.subsumes(&specific));
    try testing.expect(!specific.subsumes(&general));
}

test "literal_bool constraint creation and equality" {
    const testing = std.testing;

    const c_true = Constraint.literalBool(true);
    const c_true2 = Constraint.literalBool(true);
    const c_false = Constraint.literalBool(false);

    try testing.expect(c_true.eql(c_true2));
    try testing.expect(!c_true.eql(c_false));
}

test "literal_bool constraint negation" {
    const testing = std.testing;

    const c_true = Constraint.literalBool(true);
    const neg = c_true.negate();
    try testing.expect(neg.eql(Constraint.literalBool(false)));

    const c_false = Constraint.literalBool(false);
    const neg2 = c_false.negate();
    try testing.expect(neg2.eql(Constraint.literalBool(true)));
}

test "literal_bool satisfiability - true is always satisfiable" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    // literal_bool(true) should always be satisfiable
    try cm.addConstraint(Constraint.literalBool(true));
    try testing.expect(cm.isSatisfiable(&env));
}

test "literal_bool satisfiability - false is never satisfiable" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    // literal_bool(false) should never be satisfiable (it's a contradiction)
    try cm.addConstraint(Constraint.literalBool(false));
    try testing.expect(!cm.isSatisfiable(&env));
}

test "literal_bool causes contradiction when false" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cm = ConstraintManager.init(allocator);
    defer cm.deinit();

    // Adding literal_bool(false) should mark the constraint manager as contradictory
    try cm.addConstraint(Constraint.literalBool(false));
    try testing.expect(cm.has_contradiction);

    // literal_bool(true) should not cause contradiction
    var cm2 = ConstraintManager.init(allocator);
    defer cm2.deinit();

    try cm2.addConstraint(Constraint.literalBool(true));
    try testing.expect(!cm2.has_contradiction);
}

test "literal_bool refineValue behavior" {
    const testing = std.testing;

    // literal_bool(true) doesn't change the value
    const unchanged = ConstraintManager.refineValue(.unknown, Constraint.literalBool(true));
    try testing.expect(unchanged != null);
    try testing.expect(unchanged.?.eql(.unknown));

    // literal_bool(false) returns null (unsatisfiable path)
    const pruned = ConstraintManager.refineValue(.unknown, Constraint.literalBool(false));
    try testing.expect(pruned == null);

    // Also works with concrete values
    const concrete_unchanged = ConstraintManager.refineValue(.{ .concrete_int = 42 }, Constraint.literalBool(true));
    try testing.expect(concrete_unchanged != null);
    try testing.expect(concrete_unchanged.?.eql(.{ .concrete_int = 42 }));

    const concrete_pruned = ConstraintManager.refineValue(.{ .concrete_int = 42 }, Constraint.literalBool(false));
    try testing.expect(concrete_pruned == null);
}
