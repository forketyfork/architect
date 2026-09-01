const std = @import("std");

// Only the adapter matching the compiler frontend is selected by compat.zig.
// zwanzig-disable: unused-decl

pub fn structDeclHasBackingInt(small: std.zig.Zir.Inst.StructDecl.Small) bool {
    return small.has_backing_int;
}

pub fn unionDeclHasTagType(small: std.zig.Zir.Inst.UnionDecl.Small) bool {
    return small.has_tag_type;
}

pub fn unionDeclHasArgTypeBody(small: std.zig.Zir.Inst.UnionDecl.Small) bool {
    return small.has_body_len;
}

pub fn enumDeclHasTagType(small: std.zig.Zir.Inst.EnumDecl.Small) bool {
    return small.has_tag_type;
}

pub fn enumDeclHasBodyLen(small: std.zig.Zir.Inst.EnumDecl.Small) bool {
    return small.has_body_len;
}

test "enum body length is independent from tag type" {
    const small: std.zig.Zir.Inst.EnumDecl.Small = .{
        .has_tag_type = false,
        .has_captures_len = false,
        .has_body_len = true,
        .has_fields_len = false,
        .has_decls_len = false,
        .name_strategy = .parent,
        .nonexhaustive = false,
    };
    try std.testing.expect(enumDeclHasBodyLen(small));
}

pub fn appendDecls(
    allocator: std.mem.Allocator,
    zir: std.zig.Zir,
    type_inst: std.zig.Zir.Inst.Index,
    declarations: *std.ArrayList(std.zig.Zir.Inst.Index),
) !void {
    var iterator = zir.declIterator(type_inst);
    while (iterator.next()) |decl_inst| {
        try declarations.append(allocator, decl_inst);
    }
}

pub fn appendSwitchBodies(
    allocator: std.mem.Allocator,
    zir: std.zig.Zir,
    switch_inst: std.zig.Zir.Inst.Index,
    bodies: *std.ArrayList([]const std.zig.Zir.Inst.Index),
) !void {
    const inst_data = zir.instructions.items(.data)[@intFromEnum(switch_inst)].pl_node;
    const tag = zir.instructions.items(.tag)[@intFromEnum(switch_inst)];
    switch (tag) {
        .switch_block, .switch_block_ref => try appendNormalSwitchBodies(allocator, zir, inst_data.payload_index, bodies),
        .switch_block_err_union => try appendErrUnionSwitchBodies(allocator, zir, inst_data.payload_index, bodies),
        else => unreachable,
    }
}

fn appendNormalSwitchBodies(
    allocator: std.mem.Allocator,
    zir: std.zig.Zir,
    payload_index: u32,
    bodies: *std.ArrayList([]const std.zig.Zir.Inst.Index),
) !void {
    const extra = zir.extraData(std.zig.Zir.Inst.SwitchBlock, payload_index);
    var extra_index: usize = extra.end;
    const multi_cases_len = if (extra.data.bits.has_multi_cases) blk: {
        const len = zir.extra[extra_index];
        extra_index += 1;
        break :blk len;
    } else 0;

    if (extra.data.bits.any_has_tag_capture) extra_index += 1;
    if (extra.data.bits.special_prongs != .none) {
        if (extra.data.bits.special_prongs.hasElse()) {
            const prong_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
            extra_index += 1;
            const body = zir.bodySlice(extra_index, prong_info.body_len);
            extra_index += body.len;
            try bodies.append(allocator, body);
        }
        if (extra.data.bits.special_prongs.hasUnder()) {
            var trailing_items_len: u32 = 0;
            if (extra.data.bits.special_prongs.hasOneAdditionalItem()) {
                extra_index += 1;
            } else if (extra.data.bits.special_prongs.hasManyAdditionalItems()) {
                const items_len = zir.extra[extra_index];
                extra_index += 1;
                const ranges_len = zir.extra[extra_index];
                extra_index += 1;
                trailing_items_len = items_len + ranges_len * 2;
            }
            const prong_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
            extra_index += 1 + trailing_items_len;
            const body = zir.bodySlice(extra_index, prong_info.body_len);
            extra_index += body.len;
            try bodies.append(allocator, body);
        }
    }

    for (0..extra.data.bits.scalar_cases_len) |_| {
        extra_index += 1;
        const prong_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
        extra_index += 1;
        const body = zir.bodySlice(extra_index, prong_info.body_len);
        extra_index += body.len;
        try bodies.append(allocator, body);
    }

    for (0..multi_cases_len) |_| {
        const items_len = zir.extra[extra_index];
        extra_index += 1;
        const ranges_len = zir.extra[extra_index];
        extra_index += 1;
        const prong_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
        extra_index += 1 + items_len + ranges_len * 2;
        const body = zir.bodySlice(extra_index, prong_info.body_len);
        extra_index += body.len;
        try bodies.append(allocator, body);
    }
}

fn appendErrUnionSwitchBodies(
    allocator: std.mem.Allocator,
    zir: std.zig.Zir,
    payload_index: u32,
    bodies: *std.ArrayList([]const std.zig.Zir.Inst.Index),
) !void {
    const extra = zir.extraData(std.zig.Zir.Inst.SwitchBlockErrUnion, payload_index);
    var extra_index: usize = extra.end;
    const multi_cases_len = if (extra.data.bits.has_multi_cases) blk: {
        const len = zir.extra[extra_index];
        extra_index += 1;
        break :blk len;
    } else 0;

    if (extra.data.bits.any_uses_err_capture) extra_index += 1;
    const non_err_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
    extra_index += 1;
    const non_err_body = zir.bodySlice(extra_index, non_err_info.body_len);
    extra_index += non_err_body.len;
    try bodies.append(allocator, non_err_body);

    if (extra.data.bits.has_else) {
        const else_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
        extra_index += 1;
        const else_body = zir.bodySlice(extra_index, else_info.body_len);
        extra_index += else_body.len;
        try bodies.append(allocator, else_body);
    }

    for (0..extra.data.bits.scalar_cases_len) |_| {
        extra_index += 1;
        const prong_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
        extra_index += 1;
        const body = zir.bodySlice(extra_index, prong_info.body_len);
        extra_index += body.len;
        try bodies.append(allocator, body);
    }

    for (0..multi_cases_len) |_| {
        const items_len = zir.extra[extra_index];
        extra_index += 1;
        const ranges_len = zir.extra[extra_index];
        extra_index += 1;
        const prong_info: std.zig.Zir.Inst.SwitchBlock.ProngInfo = @bitCast(zir.extra[extra_index]);
        extra_index += 1 + items_len + ranges_len * 2;
        const body = zir.bodySlice(extra_index, prong_info.body_len);
        extra_index += body.len;
        try bodies.append(allocator, body);
    }
}
