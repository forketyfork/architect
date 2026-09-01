const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const zir_bridge_mod = @import("zir_bridge.zig");
const log = std.log.scoped(.source);

pub const Location = diagnostic.Location;
pub const SourceRange = diagnostic.SourceRange;
pub const LocationMapper = diagnostic.LocationMapper;
pub const ZirBridge = zir_bridge_mod.ZirBridge;
pub const TypeInfo = zir_bridge_mod.TypeInfo;
pub const DeclInfo = zir_bridge_mod.DeclInfo;

pub const Source = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: [:0]const u8,

    cached_ast: ?std.zig.Ast = null,
    cached_location_mapper: ?LocationMapper = null,
    cached_zir_bridge: ?ZirBridge = null,
    zir_load_attempted: bool = false,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8, content: [:0]const u8) Source {
        return Source{
            .allocator = allocator,
            .file_path = file_path,
            .content = content,
            .cached_ast = null,
            .cached_location_mapper = null,
            .cached_zir_bridge = null,
            .zir_load_attempted = false,
        };
    }

    pub fn deinit(self: *Source) void {
        if (self.cached_ast) |*ast_ptr| {
            ast_ptr.deinit(self.allocator);
        }
        if (self.cached_location_mapper) |*mapper| {
            mapper.deinit();
        }
        if (self.cached_zir_bridge) |*bridge| {
            bridge.deinit();
        }
    }

    pub fn getContent(self: *const Source) []const u8 {
        return self.content;
    }

    pub fn getFilePath(self: *const Source) []const u8 {
        return self.file_path;
    }

    pub fn tokens(self: *Source) !std.zig.Ast.TokenList.Slice {
        const ast_result = try self.ast();
        return ast_result.tokens;
    }

    pub fn ast(self: *Source) !*const std.zig.Ast {
        if (self.cached_ast == null) {
            const parsed = try std.zig.Ast.parse(self.allocator, self.content, .zig);
            self.cached_ast = parsed;
        }
        return &self.cached_ast.?;
    }

    pub fn locationMapper(self: *Source) !*const LocationMapper {
        if (self.cached_location_mapper == null) {
            self.cached_location_mapper = try LocationMapper.init(self.allocator, self.content);
        }
        return &self.cached_location_mapper.?;
    }

    pub fn byteToLocation(self: *Source, byte_offset: usize) !Location {
        const mapper = try self.locationMapper();
        return mapper.byteToLocation(byte_offset);
    }

    pub fn byteRangeToSourceRange(self: *Source, start_byte: usize, end_byte: usize) !SourceRange {
        const mapper = try self.locationMapper();
        return mapper.byteRangeToSourceRange(start_byte, end_byte);
    }

    pub fn tokenLocation(self: *Source, token_index: u32) !Location {
        const parsed_ast = try self.ast();
        const token_starts = parsed_ast.tokens.items(.start);
        if (token_index >= token_starts.len) {
            return Location.init(1, 1);
        }
        const byte_offset = token_starts[token_index];
        return self.byteToLocation(byte_offset);
    }

    // =========================================================================
    // Type Information API (ZirBridge integration)
    // =========================================================================

    /// Attempt to load ZIR-based type information for this source.
    /// This is a lazy operation - ZIR is only generated on first access.
    /// Returns null if parsing or AstGen fails, including unsupported syntax.
    /// Subsequent calls return the cached result.
    pub fn zirBridge(self: *Source) ?*const ZirBridge {
        if (!self.zir_load_attempted) {
            self.zir_load_attempted = true;
            self.loadZirBridge();
        }
        if (self.cached_zir_bridge) |*bridge| {
            return bridge;
        }
        return null;
    }

    /// Force loading of ZIR bridge (internal use).
    fn loadZirBridge(self: *Source) void {
        var bridge = ZirBridge.init(self.allocator);
        bridge.loadFromSource(self) catch |err| {
            // Expected for files with parse errors or syntax this binary's
            // embedded Zig frontend does not support; typed analysis is
            // disabled for this file and AST/token rules still run.
            log.debug("ZIR bridge unavailable for {s}: {s}", .{ self.file_path, @errorName(err) });
            bridge.deinit();
            return;
        };
        self.cached_zir_bridge = bridge;
    }

    /// Check if type information is available for this source.
    pub fn hasTypeInfo(self: *Source) bool {
        return self.zirBridge() != null;
    }

    /// Find type information for a declaration by name.
    /// Returns null if ZIR is not available or the declaration is not found.
    pub fn findDeclType(self: *Source, name: []const u8) ?TypeInfo {
        const bridge = self.zirBridge() orelse return null;
        const decl = bridge.findDeclByName(name) orelse return null;
        return decl.type_info;
    }

    /// Find full declaration information by name.
    /// Returns null if ZIR is not available or the declaration is not found.
    pub fn findDecl(self: *Source, name: []const u8) ?DeclInfo {
        const bridge = self.zirBridge() orelse return null;
        return bridge.findDeclByName(name);
    }

    /// Get the number of declarations found in ZIR.
    pub fn getDeclCount(self: *Source) usize {
        const bridge = self.zirBridge() orelse return 0;
        return bridge.getDeclCount();
    }

    /// Get declaration info by index.
    pub fn getDecl(self: *Source, index: usize) ?DeclInfo {
        const bridge = self.zirBridge() orelse return null;
        return bridge.getDecl(index);
    }

    /// Check if a declaration is a function.
    pub fn isDeclFunction(self: *Source, name: []const u8) bool {
        const decl = self.findDecl(name) orelse return false;
        return decl.is_fn;
    }

    /// Check if a declaration is a type (struct, enum, union).
    pub fn isDeclType(self: *Source, name: []const u8) bool {
        const decl = self.findDecl(name) orelse return false;
        return switch (decl.type_info.kind) {
            .@"struct", .@"enum", .@"union", .type_type => true,
            else => false,
        };
    }

    /// Check if a declaration is public.
    pub fn isDeclPublic(self: *Source, name: []const u8) bool {
        const decl = self.findDecl(name) orelse return false;
        return decl.is_pub;
    }

    /// Check if a declaration is a constant.
    pub fn isDeclConst(self: *Source, name: []const u8) bool {
        const decl = self.findDecl(name) orelse return false;
        return decl.is_const;
    }
};

test "Source basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expectEqualStrings("test.zig", source.getFilePath());
    try testing.expectEqualStrings(code, source.getContent());
}

test "Source tokens caching via AST" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tokens1 = try source.tokens();
    const tokens2 = try source.tokens();

    try testing.expect(tokens1.len == tokens2.len);
    try testing.expect(tokens1.len > 0);
    try testing.expect(source.cached_ast != null);
}

test "Source AST caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const ast1 = try source.ast();
    const ast2 = try source.ast();

    try testing.expect(ast1 == ast2);
    try testing.expect(ast1.nodes.len == ast2.nodes.len);
    try testing.expect(ast1.tokens.len == ast2.tokens.len);
}

test "Source AST parsing valid code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    const x = 42;
        \\}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const parsed_ast = try source.ast();
    try testing.expect(parsed_ast.nodes.len > 0);
    try testing.expect(parsed_ast.tokens.len > 0);
}

test "Source tokens and AST share data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const parsed_ast = try source.ast();
    const tok = try source.tokens();

    try testing.expect(tok.len == parsed_ast.tokens.len);
}

test "Source byteToLocation single line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const loc0 = try source.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc0.line);
    try testing.expectEqual(@as(usize, 1), loc0.column);

    const loc6 = try source.byteToLocation(6);
    try testing.expectEqual(@as(usize, 1), loc6.line);
    try testing.expectEqual(@as(usize, 7), loc6.column);
}

test "Source byteToLocation multiple lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 1;\nconst y = 2;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const loc_line1 = try source.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc_line1.line);
    try testing.expectEqual(@as(usize, 1), loc_line1.column);

    const loc_line2 = try source.byteToLocation(13);
    try testing.expectEqual(@as(usize, 2), loc_line2.line);
    try testing.expectEqual(@as(usize, 1), loc_line2.column);
}

test "Source locationMapper caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expect(source.cached_location_mapper == null);

    const mapper1 = try source.locationMapper();
    try testing.expect(source.cached_location_mapper != null);

    const mapper2 = try source.locationMapper();
    try testing.expect(mapper1 == mapper2);
}

test "Source tokenLocation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const loc = try source.tokenLocation(0);
    try testing.expectEqual(@as(usize, 1), loc.line);
    try testing.expectEqual(@as(usize, 1), loc.column);
}

test "Source byteRangeToSourceRange" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const range = try source.byteRangeToSourceRange(6, 7);
    try testing.expectEqual(@as(usize, 1), range.start.line);
    try testing.expectEqual(@as(usize, 7), range.start.column);
    try testing.expectEqual(@as(usize, 1), range.end.line);
    try testing.expectEqual(@as(usize, 8), range.end.column);
}

// =========================================================================
// Type Information (ZirBridge) Tests
// =========================================================================

test "Source zirBridge caching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expect(!source.zir_load_attempted);
    try testing.expect(source.cached_zir_bridge == null);

    const bridge1 = source.zirBridge();
    try testing.expect(source.zir_load_attempted);
    try testing.expect(bridge1 != null);

    const bridge2 = source.zirBridge();
    try testing.expect(bridge1 == bridge2);
}

test "Source hasTypeInfo" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expect(source.hasTypeInfo());
}

test "Source findDeclType" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 = "const x: i32 = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const type_info = source.findDeclType("x");
    try testing.expect(type_info != null);
    if (type_info) |ti| {
        try testing.expectEqual(TypeInfo.TypeKind.int, ti.kind);
        try testing.expectEqual(@as(u16, 32), ti.size_bits);
        try testing.expect(ti.is_signed);
    }

    // Non-existent declaration
    try testing.expect(source.findDeclType("nonexistent") == null);
}

test "Source findDecl" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\pub const MY_CONST: u64 = 100;
        \\var my_var: i32 = 0;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const const_decl = source.findDecl("MY_CONST");
    try testing.expect(const_decl != null);
    if (const_decl) |d| {
        try testing.expect(d.is_pub);
        try testing.expect(d.is_const);
        try testing.expectEqual(TypeInfo.TypeKind.uint, d.type_info.kind);
        try testing.expectEqual(@as(u16, 64), d.type_info.size_bits);
    }

    const var_decl = source.findDecl("my_var");
    try testing.expect(var_decl != null);
    if (var_decl) |d| {
        try testing.expect(!d.is_pub);
        try testing.expect(!d.is_const);
        try testing.expectEqual(TypeInfo.TypeKind.int, d.type_info.kind);
    }
}

test "Source isDeclFunction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\pub fn myFunc() void {}
        \\const x: i32 = 42;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expect(source.isDeclFunction("myFunc"));
    try testing.expect(!source.isDeclFunction("x"));
    try testing.expect(!source.isDeclFunction("nonexistent"));
}

test "Source isDeclPublic and isDeclConst" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\pub const public_const: i32 = 1;
        \\const private_const: i32 = 2;
        \\pub var public_var: i32 = 3;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    try testing.expect(source.isDeclPublic("public_const"));
    try testing.expect(source.isDeclConst("public_const"));

    try testing.expect(!source.isDeclPublic("private_const"));
    try testing.expect(source.isDeclConst("private_const"));

    try testing.expect(source.isDeclPublic("public_var"));
    try testing.expect(!source.isDeclConst("public_var"));
}

test "Source getDeclCount and getDecl" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\const a: i32 = 1;
        \\const b: i32 = 2;
        \\const c: i32 = 3;
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const count = source.getDeclCount();
    try testing.expect(count >= 3);

    // Check we can access declarations by index
    var found_a = false;
    var found_b = false;
    var found_c = false;
    for (0..count) |i| {
        if (source.getDecl(i)) |decl| {
            if (std.mem.eql(u8, decl.name, "a")) found_a = true;
            if (std.mem.eql(u8, decl.name, "b")) found_b = true;
            if (std.mem.eql(u8, decl.name, "c")) found_c = true;
        }
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
    try testing.expect(found_c);
}

test "Source type info with parse errors returns null" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Invalid Zig code
    const code: [:0]const u8 = "const x = ;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    // Should not crash, just return null
    try testing.expect(!source.hasTypeInfo());
    try testing.expect(source.findDeclType("x") == null);
}
