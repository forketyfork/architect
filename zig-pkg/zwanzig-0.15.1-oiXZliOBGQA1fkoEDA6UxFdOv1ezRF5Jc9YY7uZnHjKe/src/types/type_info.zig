const std = @import("std");

/// Type information extracted from ZIR for a declaration or expression.
pub const TypeInfo = struct {
    /// The kind of type (e.g., integer, pointer, function, etc.)
    kind: TypeKind,
    /// Size in bits (for numeric types), 0 if unknown/not applicable
    size_bits: u16 = 0,
    /// Whether the type is signed (for integers)
    is_signed: bool = false,
    /// Whether this is a compile-time known value
    is_comptime: bool = false,
    /// Original type string (if available, for debugging)
    type_str: ?[]const u8 = null,
    /// Sentinel information for sentinel-terminated types (e.g., [:0]u8)
    sentinel: ?SentinelInfo = null,

    /// Sentinel value information for sentinel-terminated types.
    pub const SentinelInfo = struct {
        /// The sentinel value (e.g., 0 for [:0]u8)
        value: i64,
    };

    /// Returns true if this type has a sentinel terminator.
    pub fn hasSentinel(self: TypeInfo) bool {
        return self.sentinel != null;
    }

    pub const TypeKind = enum {
        unknown,
        void_type,
        bool_type,
        int,
        uint,
        float,
        pointer,
        slice,
        array,
        optional,
        error_union,
        function,
        @"struct",
        @"enum",
        @"union",
        type_type,
    };

    pub fn initUnknown() TypeInfo {
        return .{ .kind = .unknown };
    }

    pub fn initVoid() TypeInfo {
        return .{ .kind = .void_type };
    }

    pub fn initBool() TypeInfo {
        return .{ .kind = .bool_type };
    }

    pub fn initInt(bits: u16, signed: bool) TypeInfo {
        return .{
            .kind = if (signed) .int else .uint,
            .size_bits = bits,
            .is_signed = signed,
        };
    }

    pub fn initFloat(bits: u16) TypeInfo {
        return .{
            .kind = .float,
            .size_bits = bits,
        };
    }

    pub fn initPointer() TypeInfo {
        return .{ .kind = .pointer };
    }

    pub fn initOptional() TypeInfo {
        return .{ .kind = .optional };
    }

    pub fn initErrorUnion() TypeInfo {
        return .{ .kind = .error_union };
    }

    pub fn initFunction() TypeInfo {
        return .{ .kind = .function };
    }

    pub fn format(self: TypeInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .unknown => try writer.writeAll("unknown"),
            .void_type => try writer.writeAll("void"),
            .bool_type => try writer.writeAll("bool"),
            .int => try writer.print("i{d}", .{self.size_bits}),
            .uint => try writer.print("u{d}", .{self.size_bits}),
            .float => try writer.print("f{d}", .{self.size_bits}),
            .pointer => try writer.writeAll("*T"),
            .slice => try writer.writeAll("[]T"),
            .array => try writer.writeAll("[N]T"),
            .optional => try writer.writeAll("?T"),
            .error_union => try writer.writeAll("E!T"),
            .function => try writer.writeAll("fn"),
            .@"struct" => try writer.writeAll("struct"),
            .@"enum" => try writer.writeAll("enum"),
            .@"union" => try writer.writeAll("union"),
            .type_type => try writer.writeAll("type"),
        }
    }
};

test "TypeInfo formatting" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const int_type = TypeInfo.initInt(32, true);
    try int_type.format(&writer);
    try std.testing.expectEqualStrings("i32", writer.buffered());

    writer.end = 0;
    const uint_type = TypeInfo.initInt(64, false);
    try uint_type.format(&writer);
    try std.testing.expectEqualStrings("u64", writer.buffered());

    writer.end = 0;
    const void_type = TypeInfo.initVoid();
    try void_type.format(&writer);
    try std.testing.expectEqualStrings("void", writer.buffered());
}

test "TypeInfo hasSentinel handles sentinel presence" {
    const with_sentinel = TypeInfo{ .kind = .slice, .sentinel = .{ .value = 0 } };
    try std.testing.expect(with_sentinel.hasSentinel());

    const without_sentinel = TypeInfo{ .kind = .slice };
    try std.testing.expect(!without_sentinel.hasSentinel());
}
