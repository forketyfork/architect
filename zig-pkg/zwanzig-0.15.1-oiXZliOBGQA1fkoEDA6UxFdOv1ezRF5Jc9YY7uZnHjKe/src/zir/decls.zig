const std = @import("std");
const TypeInfo = @import("../types/type_info.zig").TypeInfo;

/// Information about a declaration extracted from ZIR.
pub const DeclInfo = struct {
    /// Name of the declaration
    name: []const u8,
    /// Type information
    type_info: TypeInfo,
    /// Whether this is exported (pub)
    is_pub: bool = false,
    /// Whether this is a constant
    is_const: bool = false,
    /// Whether this is a function
    is_fn: bool = false,
    /// AST node index
    ast_node: ?u32 = null,
    /// ZIR instruction index
    zir_inst: ?u32 = null,
};

/// Information about a function parameter extracted from ZIR.
pub const ParamInfo = struct {
    /// Parameter name (may be empty for anonymous params)
    name: []const u8,
    /// Parameter type
    type_info: TypeInfo,
    /// Whether this is comptime
    is_comptime: bool = false,
};

/// Information about a function extracted from ZIR.
pub const FnInfo = struct {
    /// Function name
    name: []const u8,
    /// Return type
    return_type: TypeInfo,
    /// Parameter information
    params: std.ArrayList(ParamInfo),
    /// Whether this is exported
    is_pub: bool = false,
    /// AST node index
    ast_node: ?u32 = null,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FnInfo {
        return .{
            .name = "",
            .return_type = TypeInfo.initUnknown(),
            .params = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FnInfo) void {
        self.params.deinit(self.allocator);
    }
};

/// Information about a call expression's return type.
pub const CallExprTypeInfo = struct {
    /// The return type of the called function
    return_type: TypeInfo,
    /// Whether the called function could be resolved
    resolved: bool,
};
