const std = @import("std");
const compat = @import("compat.zig");
const cfg_graph = @import("cfg/graph.zig");

const EdgeKind = cfg_graph.EdgeKind;

pub fn edgeStyle(kind: EdgeKind) []const u8 {
    return switch (kind) {
        .branch_true => "color=green",
        .branch_false => "color=red",
        .loop_back => "color=blue, style=dashed",
        .loop_exit => "color=orange",
        .try_error, .catch_error, .errdefer_edge => "color=red, style=dotted",
        .try_success, .catch_success => "color=green, style=dotted",
        .defer_edge => "color=purple, style=dashed",
        .jump => "style=bold",
        .normal => "",
    };
}

pub fn stemFromPath(source_path: []const u8) []const u8 {
    const basename = std.fs.path.basename(source_path);
    return if (std.mem.lastIndexOf(u8, basename, ".")) |idx| basename[0..idx] else basename;
}

pub fn writeDotFile(io_context: *compat.Context, dir: []const u8, file_path: []const u8, dot: []const u8) !void {
    try compat.makePath(io_context, dir);
    try compat.writeFile(io_context, file_path, dot);
}
