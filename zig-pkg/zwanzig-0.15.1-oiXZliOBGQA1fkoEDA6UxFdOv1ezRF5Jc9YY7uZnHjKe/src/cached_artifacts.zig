const std = @import("std");
const cfg_mod = @import("cfg.zig");
const Cfg = cfg_mod.Cfg;
const CfgEdge = cfg_mod.CfgEdge;
const EdgeKind = cfg_mod.EdgeKind;
const IrNode = cfg_mod.IrNode;
const IrTag = cfg_mod.IrTag;
const ids = @import("ids.zig");
const diagnostic_mod = @import("diagnostic.zig");
const SourceRange = diagnostic_mod.SourceRange;
const Location = diagnostic_mod.Location;
const zir_bridge = @import("zir_bridge.zig");
const TypeInfo = zir_bridge.TypeInfo;

/// Magic bytes to identify cached artifact format.
const magic: [4]u8 = .{ 'Z', 'W', 'C', 'A' };

/// Current format version for cached artifacts.
/// Increment when the serialization format changes.
const format_version: u32 = 1;

/// Cached intermediate artifacts for a source file.
/// Contains CFGs for all functions and any other precomputed analysis data.
pub const CachedArtifacts = struct {
    allocator: std.mem.Allocator,
    /// CFGs for each function in the file, keyed by function AST node index.
    cfgs: std.AutoHashMap(u32, *Cfg),
    /// Whether ZIR/type info was available during caching.
    had_type_info: bool,

    pub fn init(allocator: std.mem.Allocator) CachedArtifacts {
        return .{
            .allocator = allocator,
            .cfgs = std.AutoHashMap(u32, *Cfg).init(allocator),
            .had_type_info = false,
        };
    }

    pub fn deinit(self: *CachedArtifacts) void {
        var iter = self.cfgs.valueIterator();
        while (iter.next()) |cfg_ptr| {
            // Free fn_name if it was allocated during deserialization
            if (cfg_ptr.*.fn_name) |name| {
                self.allocator.free(name);
            }
            cfg_ptr.*.deinit();
            self.allocator.destroy(cfg_ptr.*);
        }
        self.cfgs.deinit();
    }

    /// Add a CFG for a function to the artifacts.
    /// Takes ownership of the CFG and normalizes owned fields.
    pub fn addCfg(self: *CachedArtifacts, fn_ast_node: u32, cfg: *Cfg) !void {
        if (cfg.fn_name) |name| {
            cfg.fn_name = try self.allocator.dupe(u8, name);
        }
        try self.cfgs.put(fn_ast_node, cfg);
    }

    /// Get a CFG for a function by its AST node index.
    pub fn getCfg(self: *const CachedArtifacts, fn_ast_node: u32) ?*const Cfg {
        return self.cfgs.get(fn_ast_node);
    }

    /// Serialize artifacts to bytes.
    pub fn serialize(self: *const CachedArtifacts, allocator: std.mem.Allocator) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);

        try buffer.appendSlice(allocator, &magic);

        var version_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &version_bytes, format_version, .little);
        try buffer.appendSlice(allocator, &version_bytes);

        try buffer.append(allocator, if (self.had_type_info) 1 else 0);

        var cfg_count_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &cfg_count_bytes, @intCast(self.cfgs.count()), .little);
        try buffer.appendSlice(allocator, &cfg_count_bytes);

        var iter = self.cfgs.iterator();
        while (iter.next()) |entry| {
            const fn_node = entry.key_ptr.*;
            const cfg = entry.value_ptr.*;

            var fn_node_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &fn_node_bytes, fn_node, .little);
            try buffer.appendSlice(allocator, &fn_node_bytes);

            try serializeCfg(cfg, allocator, &buffer);
        }

        return buffer.toOwnedSlice(allocator);
    }

    /// Deserialize artifacts from bytes.
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !CachedArtifacts {
        if (data.len < 9) {
            return error.InvalidFormat;
        }

        if (!std.mem.eql(u8, data[0..4], &magic)) {
            return error.InvalidFormat;
        }

        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version != format_version) {
            return error.VersionMismatch;
        }

        const had_type_info = data[8] != 0;

        var offset: usize = 9;
        if (data.len < offset + 4) {
            return error.InvalidFormat;
        }

        const cfg_count = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        var artifacts = CachedArtifacts.init(allocator);
        errdefer artifacts.deinit();

        artifacts.had_type_info = had_type_info;

        for (0..cfg_count) |_| {
            if (data.len < offset + 4) {
                return error.InvalidFormat;
            }

            const fn_node = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            const cfg_result = try deserializeCfg(allocator, data, offset);
            offset = cfg_result.new_offset;

            try artifacts.cfgs.put(fn_node, cfg_result.cfg);
        }

        return artifacts;
    }

    /// Check if artifacts are valid/complete.
    pub fn isValid(self: *const CachedArtifacts) bool {
        return self.cfgs.count() > 0;
    }
};

fn serializeCfg(cfg: *const Cfg, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
    var node_count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &node_count_bytes, @intCast(cfg.nodes.items.len), .little);
    try buffer.appendSlice(allocator, &node_count_bytes);

    for (cfg.nodes.items) |node| {
        try serializeIrNode(&node.ir_node, allocator, buffer);
    }

    var edge_count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &edge_count_bytes, @intCast(cfg.edges.items.len), .little);
    try buffer.appendSlice(allocator, &edge_count_bytes);

    for (cfg.edges.items) |edge| {
        try serializeEdge(&edge, allocator, buffer);
    }

    var entry_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &entry_bytes, ids.cfgIndex(cfg.entry), .little);
    try buffer.appendSlice(allocator, &entry_bytes);

    var exit_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &exit_bytes, ids.cfgIndex(cfg.exit), .little);
    try buffer.appendSlice(allocator, &exit_bytes);

    const has_fn_name: u8 = if (cfg.fn_name != null) 1 else 0;
    try buffer.append(allocator, has_fn_name);
    if (cfg.fn_name) |name| {
        var name_len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &name_len_bytes, @intCast(name.len), .little);
        try buffer.appendSlice(allocator, &name_len_bytes);
        try buffer.appendSlice(allocator, name);
    }

    const has_fn_ast_node: u8 = if (cfg.fn_ast_node != null) 1 else 0;
    try buffer.append(allocator, has_fn_ast_node);
    if (cfg.fn_ast_node) |node_id| {
        var node_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &node_bytes, ids.astIndex(node_id), .little);
        try buffer.appendSlice(allocator, &node_bytes);
    }
}

fn serializeIrNode(node: *const IrNode, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
    try buffer.append(allocator, @intFromEnum(node.tag));

    const has_ast_node: u8 = if (node.ast_node != null) 1 else 0;
    try buffer.append(allocator, has_ast_node);
    if (node.ast_node) |ast| {
        var ast_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &ast_bytes, ast, .little);
        try buffer.appendSlice(allocator, &ast_bytes);
    }

    const has_range: u8 = if (node.source_range != null) 1 else 0;
    try buffer.append(allocator, has_range);
    if (node.source_range) |range| {
        try serializeSourceRange(&range, allocator, buffer);
    }

    const has_operand: u8 = if (node.operand_node != null) 1 else 0;
    try buffer.append(allocator, has_operand);
    if (node.operand_node) |op| {
        var op_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &op_bytes, op, .little);
        try buffer.appendSlice(allocator, &op_bytes);
    }

    const has_operand2: u8 = if (node.operand2_node != null) 1 else 0;
    try buffer.append(allocator, has_operand2);
    if (node.operand2_node) |op| {
        var op_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &op_bytes, op, .little);
        try buffer.appendSlice(allocator, &op_bytes);
    }

    const has_type: u8 = if (node.type_info != null) 1 else 0;
    try buffer.append(allocator, has_type);
    if (node.type_info) |ti| {
        try serializeTypeInfo(&ti, allocator, buffer);
    }
}

fn serializeSourceRange(range: *const SourceRange, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], @intCast(range.start.line), .little);
    std.mem.writeInt(u32, bytes[4..8], @intCast(range.start.column), .little);
    std.mem.writeInt(u32, bytes[8..12], @intCast(range.end.line), .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(range.end.column), .little);
    try buffer.appendSlice(allocator, &bytes);
}

fn serializeEdge(edge: *const CfgEdge, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
    var bytes: [9]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], ids.cfgIndex(edge.from), .little);
    std.mem.writeInt(u32, bytes[4..8], ids.cfgIndex(edge.to), .little);
    bytes[8] = @intFromEnum(edge.kind);
    try buffer.appendSlice(allocator, &bytes);
}

fn serializeTypeInfo(ti: *const TypeInfo, allocator: std.mem.Allocator, buffer: *std.ArrayList(u8)) !void {
    try buffer.append(allocator, @intFromEnum(ti.kind));

    var size_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &size_bytes, ti.size_bits, .little);
    try buffer.appendSlice(allocator, &size_bytes);

    const flags: u8 = (if (ti.is_signed) @as(u8, 1) else 0) | (if (ti.is_comptime) @as(u8, 2) else 0);
    try buffer.append(allocator, flags);
}

const DeserializeCfgResult = struct {
    cfg: *Cfg,
    new_offset: usize,
};

fn deserializeCfg(allocator: std.mem.Allocator, data: []const u8, start_offset: usize) !DeserializeCfgResult {
    var offset = start_offset;

    if (data.len < offset + 4) {
        return error.InvalidFormat;
    }
    const node_count = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    const cfg = try allocator.create(Cfg);
    cfg.* = Cfg.init(allocator);
    errdefer {
        cfg.deinit();
        allocator.destroy(cfg);
    }

    for (0..node_count) |i| {
        const node_result = try deserializeIrNode(data, offset);
        offset = node_result.new_offset;

        const idx = try cfg.addNode(node_result.node);
        std.debug.assert(ids.cfgIndex(idx) == @as(u32, @intCast(i)));
    }

    if (data.len < offset + 4) {
        return error.InvalidFormat;
    }
    const edge_count = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    for (0..edge_count) |_| {
        const edge_result = try deserializeEdge(data, offset);
        offset = edge_result.new_offset;

        try cfg.addEdgeWithKind(edge_result.edge.from, edge_result.edge.to, edge_result.edge.kind);
    }

    if (data.len < offset + 8) {
        return error.InvalidFormat;
    }
    cfg.entry = ids.cfgId(std.mem.readInt(u32, data[offset..][0..4], .little));
    offset += 4;
    cfg.exit = ids.cfgId(std.mem.readInt(u32, data[offset..][0..4], .little));
    offset += 4;

    if (data.len < offset + 1) {
        return error.InvalidFormat;
    }
    const has_fn_name = data[offset] != 0;
    offset += 1;

    if (has_fn_name) {
        if (data.len < offset + 4) {
            return error.InvalidFormat;
        }
        const name_len: usize = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (data.len < offset + name_len) {
            return error.InvalidFormat;
        }
        cfg.fn_name = try allocator.dupe(u8, data[offset..][0..name_len]);
        offset += name_len;
    }
    errdefer if (cfg.fn_name) |name| allocator.free(name);

    if (data.len < offset + 1) {
        return error.InvalidFormat;
    }
    const has_fn_ast_node = data[offset] != 0;
    offset += 1;

    if (has_fn_ast_node) {
        if (data.len < offset + 4) {
            return error.InvalidFormat;
        }
        cfg.fn_ast_node = ids.astId(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
    }

    return .{
        .cfg = cfg,
        .new_offset = offset,
    };
}

const DeserializeIrNodeResult = struct {
    node: IrNode,
    new_offset: usize,
};

fn deserializeIrNode(data: []const u8, start_offset: usize) !DeserializeIrNodeResult {
    var offset = start_offset;

    if (data.len < offset + 2) {
        return error.InvalidFormat;
    }

    const tag: IrTag = @enumFromInt(data[offset]);
    offset += 1;

    var node = IrNode.init(tag);

    const has_ast_node = data[offset] != 0;
    offset += 1;
    if (has_ast_node) {
        if (data.len < offset + 4) {
            return error.InvalidFormat;
        }
        node.ast_node = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
    }

    if (data.len < offset + 1) {
        return error.InvalidFormat;
    }
    const has_range = data[offset] != 0;
    offset += 1;
    if (has_range) {
        const range_result = try deserializeSourceRange(data, offset);
        node.source_range = range_result.range;
        offset = range_result.new_offset;
    }

    if (data.len < offset + 1) {
        return error.InvalidFormat;
    }
    const has_operand = data[offset] != 0;
    offset += 1;
    if (has_operand) {
        if (data.len < offset + 4) {
            return error.InvalidFormat;
        }
        node.operand_node = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
    }

    if (data.len < offset + 1) {
        return error.InvalidFormat;
    }
    const has_operand2 = data[offset] != 0;
    offset += 1;
    if (has_operand2) {
        if (data.len < offset + 4) {
            return error.InvalidFormat;
        }
        node.operand2_node = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
    }

    if (data.len < offset + 1) {
        return error.InvalidFormat;
    }
    const has_type = data[offset] != 0;
    offset += 1;
    if (has_type) {
        const ti_result = try deserializeTypeInfo(data, offset);
        node.type_info = ti_result.type_info;
        offset = ti_result.new_offset;
    }

    return .{
        .node = node,
        .new_offset = offset,
    };
}

const DeserializeSourceRangeResult = struct {
    range: SourceRange,
    new_offset: usize,
};

fn deserializeSourceRange(data: []const u8, start_offset: usize) !DeserializeSourceRangeResult {
    if (data.len < start_offset + 16) {
        return error.InvalidFormat;
    }

    const start_line = std.mem.readInt(u32, data[start_offset..][0..4], .little);
    const start_col = std.mem.readInt(u32, data[start_offset + 4 ..][0..4], .little);
    const end_line = std.mem.readInt(u32, data[start_offset + 8 ..][0..4], .little);
    const end_col = std.mem.readInt(u32, data[start_offset + 12 ..][0..4], .little);

    return .{
        .range = SourceRange.init(
            Location.init(start_line, start_col),
            Location.init(end_line, end_col),
        ),
        .new_offset = start_offset + 16,
    };
}

const DeserializeEdgeResult = struct {
    edge: CfgEdge,
    new_offset: usize,
};

fn deserializeEdge(data: []const u8, start_offset: usize) !DeserializeEdgeResult {
    if (data.len < start_offset + 9) {
        return error.InvalidFormat;
    }

    const from = ids.cfgId(std.mem.readInt(u32, data[start_offset..][0..4], .little));
    const to = ids.cfgId(std.mem.readInt(u32, data[start_offset + 4 ..][0..4], .little));
    const kind: EdgeKind = @enumFromInt(data[start_offset + 8]);

    return .{
        .edge = CfgEdge.initWithKind(from, to, kind),
        .new_offset = start_offset + 9,
    };
}

const DeserializeTypeInfoResult = struct {
    type_info: TypeInfo,
    new_offset: usize,
};

fn deserializeTypeInfo(data: []const u8, start_offset: usize) !DeserializeTypeInfoResult {
    if (data.len < start_offset + 4) {
        return error.InvalidFormat;
    }

    const kind: TypeInfo.TypeKind = @enumFromInt(data[start_offset]);
    const size_bits = std.mem.readInt(u16, data[start_offset + 1 ..][0..2], .little);
    const flags = data[start_offset + 3];

    return .{
        .type_info = .{
            .kind = kind,
            .size_bits = size_bits,
            .is_signed = (flags & 1) != 0,
            .is_comptime = (flags & 2) != 0,
            .type_str = null,
        },
        .new_offset = start_offset + 4,
    };
}

test "CachedArtifacts: serialize and deserialize empty" {
    const allocator = std.testing.allocator;

    var artifacts = CachedArtifacts.init(allocator);
    defer artifacts.deinit();

    const serialized = try artifacts.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try CachedArtifacts.deserialize(allocator, serialized);
    defer deserialized.deinit();

    try std.testing.expectEqual(false, deserialized.had_type_info);
    try std.testing.expectEqual(@as(usize, 0), deserialized.cfgs.count());
}

test "CachedArtifacts: serialize and deserialize with CFG" {
    const allocator = std.testing.allocator;

    var artifacts = CachedArtifacts.init(allocator);
    defer artifacts.deinit();
    artifacts.had_type_info = true;

    const cfg = try allocator.create(Cfg);
    cfg.* = Cfg.init(allocator);
    const entry = try cfg.addNode(IrNode.init(.fn_entry));
    const exit = try cfg.addNode(IrNode.init(.fn_exit));
    try cfg.addEdge(entry, exit);
    cfg.entry = entry;
    cfg.exit = exit;

    try artifacts.addCfg(42, cfg);

    const serialized = try artifacts.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try CachedArtifacts.deserialize(allocator, serialized);
    defer deserialized.deinit();

    try std.testing.expectEqual(true, deserialized.had_type_info);
    try std.testing.expectEqual(@as(usize, 1), deserialized.cfgs.count());

    const restored_cfg = deserialized.getCfg(42);
    try std.testing.expect(restored_cfg != null);
    try std.testing.expectEqual(@as(usize, 2), restored_cfg.?.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), restored_cfg.?.edgeCount());
}

test "CachedArtifacts: invalid format handling" {
    const allocator = std.testing.allocator;

    const result1 = CachedArtifacts.deserialize(allocator, "short");
    try std.testing.expectError(error.InvalidFormat, result1);

    const result2 = CachedArtifacts.deserialize(allocator, "BAD_magic_");
    try std.testing.expectError(error.InvalidFormat, result2);

    var bad_version = [_]u8{ 'Z', 'W', 'C', 'A', 99, 0, 0, 0, 0 };
    const result3 = CachedArtifacts.deserialize(allocator, &bad_version);
    try std.testing.expectError(error.VersionMismatch, result3);
}
