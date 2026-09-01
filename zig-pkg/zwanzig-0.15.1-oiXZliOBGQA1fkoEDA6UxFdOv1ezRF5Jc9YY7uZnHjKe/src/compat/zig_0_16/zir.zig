const std = @import("std");

// Only the adapter matching the compiler frontend is selected by compat.zig.
// zwanzig-disable: unused-decl

pub fn structDeclHasBackingInt(small: std.zig.Zir.Inst.StructDecl.Small) bool {
    return small.has_backing_int_type;
}

pub fn unionDeclHasTagType(small: std.zig.Zir.Inst.UnionDecl.Small) bool {
    return small.kind.hasArgType();
}

pub fn unionDeclHasArgTypeBody(small: std.zig.Zir.Inst.UnionDecl.Small) bool {
    return small.kind.hasArgType();
}

pub fn enumDeclHasTagType(small: std.zig.Zir.Inst.EnumDecl.Small) bool {
    return small.has_tag_type;
}

pub fn enumDeclHasBodyLen(small: std.zig.Zir.Inst.EnumDecl.Small) bool {
    return small.has_tag_type;
}

test "enum body length follows tag type" {
    const small: std.zig.Zir.Inst.EnumDecl.Small = .{
        .has_captures_len = false,
        .has_decls_len = false,
        .has_fields_len = false,
        .name_strategy = .parent,
        .has_tag_type = true,
        .nonexhaustive = false,
        .any_field_values = false,
    };
    try std.testing.expect(enumDeclHasBodyLen(small));
}

pub fn appendDecls(
    allocator: std.mem.Allocator,
    zir: std.zig.Zir,
    type_inst: std.zig.Zir.Inst.Index,
    declarations: *std.ArrayList(std.zig.Zir.Inst.Index),
) !void {
    for (zir.typeDecls(type_inst)) |decl_inst| {
        try declarations.append(allocator, decl_inst);
    }
}

pub fn appendSwitchBodies(
    allocator: std.mem.Allocator,
    zir: std.zig.Zir,
    switch_inst: std.zig.Zir.Inst.Index,
    bodies: *std.ArrayList([]const std.zig.Zir.Inst.Index),
) !void {
    const switch_block = zir.getSwitchBlock(switch_inst);

    if (switch_block.non_err_case) |case| {
        try bodies.append(allocator, case.body);
    }
    if (switch_block.else_case) |case| {
        try bodies.append(allocator, case.body);
    }

    var extra_index = switch_block.end;
    var cases = switch_block.iterateCases();
    while (cases.next()) |case| {
        const prong_body = zir.bodySlice(extra_index, case.prong_info.body_len);
        extra_index += prong_body.len;
        try bodies.append(allocator, prong_body);

        for (case.item_infos) |item| {
            switch (item.unwrap()) {
                .body_len => |body_len| {
                    const body = zir.bodySlice(extra_index, body_len);
                    extra_index += body.len;
                    try bodies.append(allocator, body);
                },
                else => {},
            }
        }
        for (case.range_infos) |range| {
            for (range) |item| {
                switch (item.unwrap()) {
                    .body_len => |body_len| {
                        const body = zir.bodySlice(extra_index, body_len);
                        extra_index += body.len;
                        try bodies.append(allocator, body);
                    },
                    else => {},
                }
            }
        }
    }
}
