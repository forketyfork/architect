const std = @import("std");

/// Abstract value representing the possible values of a variable or expression.
/// These values are used for symbolic execution and dataflow analysis.
pub const AbstractValue = union(enum) {
    /// Value is unknown - no information available
    unknown,
    /// Value is definitely null/undefined
    null_val,
    /// Value is definitely not null (but actual value is unknown)
    non_null,
    /// Value is an integer within a known range
    int_range: IntRange,
    /// Value is a known concrete integer
    concrete_int: i64,
    /// Value is a known concrete boolean
    concrete_bool: bool,

    pub const IntRange = struct {
        min: i64,
        max: i64,

        pub fn init(min: i64, max: i64) IntRange {
            return .{ .min = min, .max = max };
        }

        pub fn single(value: i64) IntRange {
            return .{ .min = value, .max = value };
        }

        pub fn eql(self: IntRange, other: IntRange) bool {
            return self.min == other.min and self.max == other.max;
        }

        pub fn contains(self: IntRange, value: i64) bool {
            return value >= self.min and value <= self.max;
        }

        pub fn overlaps(self: IntRange, other: IntRange) bool {
            return self.min <= other.max and other.min <= self.max;
        }

        pub fn merge(self: IntRange, other: IntRange) IntRange {
            return .{
                .min = @min(self.min, other.min),
                .max = @max(self.max, other.max),
            };
        }
    };

    pub fn eql(self: AbstractValue, other: AbstractValue) bool {
        return switch (self) {
            .unknown => other == .unknown,
            .null_val => other == .null_val,
            .non_null => other == .non_null,
            .int_range => |r1| switch (other) {
                .int_range => |r2| r1.eql(r2),
                else => false,
            },
            .concrete_int => |v1| switch (other) {
                .concrete_int => |v2| v1 == v2,
                else => false,
            },
            .concrete_bool => |b1| switch (other) {
                .concrete_bool => |b2| b1 == b2,
                else => false,
            },
        };
    }

    pub fn hash(self: AbstractValue) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag_byte: u8 = switch (self) {
            .unknown => 0,
            .null_val => 1,
            .non_null => 2,
            .int_range => 3,
            .concrete_int => 4,
            .concrete_bool => 5,
        };
        hasher.update(&[_]u8{tag_byte});
        switch (self) {
            .int_range => |r| {
                hasher.update(std.mem.asBytes(&r.min));
                hasher.update(std.mem.asBytes(&r.max));
            },
            .concrete_int => |v| {
                hasher.update(std.mem.asBytes(&v));
            },
            .concrete_bool => |b| {
                hasher.update(&[_]u8{if (b) 1 else 0});
            },
            else => {},
        }
        return hasher.final();
    }

    pub fn isUnknown(self: AbstractValue) bool {
        return self == .unknown;
    }

    pub fn isNull(self: AbstractValue) bool {
        return self == .null_val;
    }

    pub fn isNonNull(self: AbstractValue) bool {
        return self == .non_null;
    }

    pub fn isConcrete(self: AbstractValue) bool {
        return self == .concrete_int or self == .concrete_bool;
    }

    pub fn isBool(self: AbstractValue) bool {
        return self == .concrete_bool;
    }

    pub fn toBool(self: AbstractValue) ?bool {
        return switch (self) {
            .concrete_bool => |b| b,
            else => null,
        };
    }

    pub fn toConcreteInt(self: AbstractValue) ?i64 {
        return switch (self) {
            .concrete_int => |v| v,
            .int_range => |r| if (r.min == r.max) r.min else null,
            else => null,
        };
    }

    pub fn merge(self: AbstractValue, other: AbstractValue) AbstractValue {
        if (self.eql(other)) return self;

        return switch (self) {
            .unknown => .unknown,
            .null_val => switch (other) {
                .unknown => .unknown,
                else => .unknown,
            },
            .non_null => switch (other) {
                .unknown => .unknown,
                .non_null => .non_null,
                else => .unknown,
            },
            .concrete_int => |v1| switch (other) {
                .concrete_int => |v2| .{ .int_range = IntRange.init(@min(v1, v2), @max(v1, v2)) },
                .int_range => |r| .{ .int_range = r.merge(IntRange.single(v1)) },
                else => .unknown,
            },
            .int_range => |r1| switch (other) {
                .int_range => |r2| .{ .int_range = r1.merge(r2) },
                .concrete_int => |v| .{ .int_range = r1.merge(IntRange.single(v)) },
                else => .unknown,
            },
            .concrete_bool => switch (other) {
                .concrete_bool => .unknown, // Different bool values (same would have returned early)
                else => .unknown,
            },
        };
    }

    /// Widening operator for abstract values.
    /// Used at widening points to ensure convergence by over-approximating.
    /// Unlike merge, widen is not symmetric: `self` is the previous state at the widening point,
    /// `other` is the new incoming state from a back-edge.
    ///
    /// Widening rules:
    /// - If either is `unknown`, result is `unknown`.
    /// - `null_val` vs `non_null` -> `unknown`.
    /// - `concrete_int` vs `concrete_int` -> same if equal; else widen to `unknown`.
    /// - `int_range` widening: if bounds expand, widen to `unknown` (simple policy for convergence).
    pub fn widen(self: AbstractValue, other: AbstractValue) AbstractValue {
        if (self.eql(other)) return self;

        return switch (self) {
            .unknown => .unknown,
            .null_val => switch (other) {
                .null_val => .null_val,
                else => .unknown,
            },
            .non_null => switch (other) {
                .non_null => .non_null,
                else => .unknown,
            },
            .concrete_int => |v1| switch (other) {
                .concrete_int => |v2| if (v1 == v2) self else .unknown,
                .int_range => .unknown,
                else => .unknown,
            },
            .int_range => |r1| switch (other) {
                .int_range => |r2| blk: {
                    // If bounds expand in any direction, widen to unknown
                    if (r2.min < r1.min or r2.max > r1.max) {
                        break :blk .unknown;
                    }
                    // Bounds stayed the same or contracted, keep the merged range
                    break :blk .{ .int_range = r1.merge(r2) };
                },
                .concrete_int => |v| blk: {
                    // If the concrete value expands the range, widen to unknown
                    if (v < r1.min or v > r1.max) {
                        break :blk .unknown;
                    }
                    break :blk self;
                },
                else => .unknown,
            },
            .concrete_bool => |b1| switch (other) {
                .concrete_bool => |b2| if (b1 == b2) self else .unknown,
                else => .unknown,
            },
        };
    }

    /// Returns true if `self` is at least as general as `other`.
    /// Used for subsumption checks to avoid adding redundant states.
    pub fn subsumes(self: AbstractValue, other: AbstractValue) bool {
        if (self.eql(other)) return true;

        return switch (self) {
            .unknown => true,
            .null_val => other == .null_val,
            .non_null => switch (other) {
                .non_null,
                .concrete_int,
                .int_range,
                .concrete_bool,
                => true,
                else => false,
            },
            .concrete_int => |v1| switch (other) {
                .concrete_int => |v2| v1 == v2,
                else => false,
            },
            .int_range => |r1| switch (other) {
                .int_range => |r2| r2.min >= r1.min and r2.max <= r1.max,
                .concrete_int => |v| v >= r1.min and v <= r1.max,
                else => false,
            },
            .concrete_bool => |b1| switch (other) {
                .concrete_bool => |b2| b1 == b2,
                else => false,
            },
        };
    }
};

/// Evaluate whether an AST node is a boolean literal (true or false).
/// This is a standalone utility for use by checkers that don't use the full analysis engine.
pub fn evaluateBoolLiteral(tree: *const std.zig.Ast, node: u32) ?bool {
    const tags = tree.nodes.items(.tag);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);
    const token_starts = tree.tokens.items(.start);

    if (node >= tags.len) return null;
    if (tags[node] != .identifier) return null;

    const token = main_tokens[node];
    if (token >= token_tags.len or token_tags[token] != .identifier) return null;

    const start = token_starts[token];
    var len: u32 = 0;
    while (start + len < tree.source.len) {
        const c = tree.source[start + len];
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        len += 1;
    }

    if (len == 5 and std.mem.eql(u8, tree.source[start .. start + 5], "false")) return false;
    if (len == 4 and std.mem.eql(u8, tree.source[start .. start + 4], "true")) return true;
    return null;
}

test "AbstractValue basic operations" {
    const testing = std.testing;

    const unknown: AbstractValue = .unknown;
    try testing.expect(unknown.isUnknown());
    try testing.expect(!unknown.isNull());
    try testing.expect(!unknown.isNonNull());
    try testing.expect(!unknown.isConcrete());

    const null_val: AbstractValue = .null_val;
    try testing.expect(null_val.isNull());
    try testing.expect(!null_val.isUnknown());

    const non_null: AbstractValue = .non_null;
    try testing.expect(non_null.isNonNull());

    const concrete: AbstractValue = .{ .concrete_int = 42 };
    try testing.expect(concrete.isConcrete());
    try testing.expectEqual(@as(?i64, 42), concrete.toConcreteInt());

    const bool_true: AbstractValue = .{ .concrete_bool = true };
    const bool_false: AbstractValue = .{ .concrete_bool = false };
    try testing.expect(bool_true.isConcrete());
    try testing.expect(bool_true.isBool());
    try testing.expectEqual(@as(?bool, true), bool_true.toBool());
    try testing.expectEqual(@as(?bool, false), bool_false.toBool());
    try testing.expect(!concrete.isBool());
    try testing.expectEqual(@as(?bool, null), concrete.toBool());

    try testing.expect(!unknown.eql(null_val));
    try testing.expect(unknown.eql(.unknown));
    try testing.expect(bool_true.eql(.{ .concrete_bool = true }));
    try testing.expect(!bool_true.eql(bool_false));
    try testing.expect(!bool_true.eql(concrete));
}

test "AbstractValue IntRange operations" {
    const testing = std.testing;
    const IntRange = AbstractValue.IntRange;

    const range1 = IntRange.init(0, 10);
    try testing.expect(range1.contains(5));
    try testing.expect(range1.contains(0));
    try testing.expect(range1.contains(10));
    try testing.expect(!range1.contains(-1));
    try testing.expect(!range1.contains(11));

    const range2 = IntRange.init(5, 15);
    try testing.expect(range1.overlaps(range2));

    const merged = range1.merge(range2);
    try testing.expectEqual(@as(i64, 0), merged.min);
    try testing.expectEqual(@as(i64, 15), merged.max);

    const single = IntRange.single(42);
    try testing.expectEqual(@as(i64, 42), single.min);
    try testing.expectEqual(@as(i64, 42), single.max);
}

test "AbstractValue merge operations" {
    const testing = std.testing;

    const concrete1: AbstractValue = .{ .concrete_int = 10 };
    const concrete2: AbstractValue = .{ .concrete_int = 20 };

    const merged = concrete1.merge(concrete2);
    switch (merged) {
        .int_range => |r| {
            try testing.expectEqual(@as(i64, 10), r.min);
            try testing.expectEqual(@as(i64, 20), r.max);
        },
        else => try testing.expect(false),
    }

    const unknown: AbstractValue = .unknown;
    const merged_unknown = concrete1.merge(unknown);
    try testing.expect(merged_unknown.isUnknown());

    const null_val: AbstractValue = .null_val;
    const non_null: AbstractValue = .non_null;
    const merged_nulls = null_val.merge(non_null);
    try testing.expect(merged_nulls.isUnknown());

    // Verify that merging two null_vals returns null_val (idempotent)
    const null_val2: AbstractValue = .null_val;
    const merged_same_nulls = null_val.merge(null_val2);
    try testing.expect(merged_same_nulls.isNull());
}

test "AbstractValue widen operations" {
    const testing = std.testing;
    const IntRange = AbstractValue.IntRange;

    // Widening identical values returns the same value
    const concrete1: AbstractValue = .{ .concrete_int = 10 };
    try testing.expect(concrete1.widen(concrete1).eql(concrete1));

    // Widening different concrete_ints widens to unknown
    const concrete2: AbstractValue = .{ .concrete_int = 20 };
    try testing.expect(concrete1.widen(concrete2).isUnknown());

    // Widening unknown with anything returns unknown
    const unknown: AbstractValue = .unknown;
    try testing.expect(unknown.widen(concrete1).isUnknown());
    try testing.expect(concrete1.widen(unknown).isUnknown());

    // Widening null_val with non_null widens to unknown
    const null_val: AbstractValue = .null_val;
    const non_null: AbstractValue = .non_null;
    try testing.expect(null_val.widen(non_null).isUnknown());
    try testing.expect(non_null.widen(null_val).isUnknown());

    // Widening identical null/non_null returns the same value
    try testing.expect(null_val.widen(.null_val).isNull());
    try testing.expect(non_null.widen(.non_null).isNonNull());

    // Widening int_range: if new range expands bounds, widen to unknown
    const range1: AbstractValue = .{ .int_range = IntRange.init(0, 10) };
    const range2: AbstractValue = .{ .int_range = IntRange.init(-5, 10) }; // expands min
    const range3: AbstractValue = .{ .int_range = IntRange.init(0, 15) }; // expands max
    const range4: AbstractValue = .{ .int_range = IntRange.init(2, 8) }; // contracts
    const range5: AbstractValue = .{ .int_range = IntRange.init(0, 10) }; // same

    try testing.expect(range1.widen(range2).isUnknown());
    try testing.expect(range1.widen(range3).isUnknown());

    // Contracted or same range should preserve the range
    const widened4 = range1.widen(range4);
    try testing.expect(widened4.eql(range1));

    const widened5 = range1.widen(range5);
    try testing.expect(widened5.eql(range1));

    // Widening int_range with concrete_int that expands bounds widens to unknown
    const range_small: AbstractValue = .{ .int_range = IntRange.init(5, 15) };
    const concrete_outside: AbstractValue = .{ .concrete_int = 20 };
    const concrete_inside: AbstractValue = .{ .concrete_int = 10 };

    try testing.expect(range_small.widen(concrete_outside).isUnknown());
    try testing.expect(range_small.widen(concrete_inside).eql(range_small));

    // Widening concrete_int with int_range widens to unknown
    try testing.expect(concrete1.widen(range1).isUnknown());
}

test "AbstractValue concrete_bool merge and widen" {
    const testing = std.testing;

    const bool_true: AbstractValue = .{ .concrete_bool = true };
    const bool_false: AbstractValue = .{ .concrete_bool = false };
    const unknown: AbstractValue = .unknown;
    const concrete_int: AbstractValue = .{ .concrete_int = 1 };

    // Merging identical booleans returns the same value
    try testing.expect(bool_true.merge(bool_true).eql(bool_true));
    try testing.expect(bool_false.merge(bool_false).eql(bool_false));

    // Merging different booleans returns unknown
    try testing.expect(bool_true.merge(bool_false).isUnknown());
    try testing.expect(bool_false.merge(bool_true).isUnknown());

    // Merging bool with unknown returns unknown
    try testing.expect(bool_true.merge(unknown).isUnknown());
    try testing.expect(unknown.merge(bool_true).isUnknown());

    // Merging bool with int returns unknown (incompatible types)
    try testing.expect(bool_true.merge(concrete_int).isUnknown());
    try testing.expect(concrete_int.merge(bool_true).isUnknown());

    // Widening identical booleans returns the same value
    try testing.expect(bool_true.widen(bool_true).eql(bool_true));
    try testing.expect(bool_false.widen(bool_false).eql(bool_false));

    // Widening different booleans returns unknown
    try testing.expect(bool_true.widen(bool_false).isUnknown());
    try testing.expect(bool_false.widen(bool_true).isUnknown());

    // Widening bool with unknown returns unknown
    try testing.expect(bool_true.widen(unknown).isUnknown());
    try testing.expect(unknown.widen(bool_true).isUnknown());

    // Widening bool with int returns unknown
    try testing.expect(bool_true.widen(concrete_int).isUnknown());
    try testing.expect(concrete_int.widen(bool_true).isUnknown());

    // Hash should be different for true vs false
    try testing.expect(bool_true.hash() != bool_false.hash());
}

test "AbstractValue subsumes ordering" {
    const testing = std.testing;

    const unknown: AbstractValue = .unknown;
    const null_val: AbstractValue = .null_val;
    const non_null: AbstractValue = .non_null;
    const int_one: AbstractValue = .{ .concrete_int = 1 };
    const int_two: AbstractValue = .{ .concrete_int = 2 };
    const int_outside: AbstractValue = .{ .concrete_int = 10 };
    const range_small: AbstractValue = .{ .int_range = .{ .min = 0, .max = 3 } };
    const range_big: AbstractValue = .{ .int_range = .{ .min = -10, .max = 10 } };
    const bool_true: AbstractValue = .{ .concrete_bool = true };

    try testing.expect(unknown.subsumes(int_one));
    try testing.expect(unknown.subsumes(null_val));

    try testing.expect(non_null.subsumes(int_one));
    try testing.expect(non_null.subsumes(bool_true));
    try testing.expect(!non_null.subsumes(null_val));

    try testing.expect(range_big.subsumes(range_small));
    try testing.expect(range_big.subsumes(int_one));
    try testing.expect(!range_small.subsumes(range_big));
    try testing.expect(!range_small.subsumes(int_outside));

    try testing.expect(int_one.subsumes(int_one));
    try testing.expect(!int_one.subsumes(int_two));
}
