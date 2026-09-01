const std = @import("std");
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;

pub fn isEmptyBlock(
    tags: []const std.zig.Ast.Node.Tag,
    data: []const std.zig.Ast.Node.Data,
    node_idx: u32,
) bool {
    if (node_idx == 0 or node_idx >= tags.len) return false;

    return switch (tags[node_idx]) {
        .block, .block_semicolon => blk: {
            const extra = data[node_idx].extra_range;
            const start: usize = @intFromEnum(extra.start);
            const end: usize = @intFromEnum(extra.end);
            break :blk end <= start;
        },
        .block_two, .block_two_semicolon => blk: {
            const opt_nodes = data[node_idx].opt_node_and_opt_node;
            break :blk opt_nodes[0].unwrap() == null and opt_nodes[1].unwrap() == null;
        },
        else => false,
    };
}

pub fn emitEmptyBlockDiagnostic(
    src: *Source,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    tree: *const std.zig.Ast,
    node_idx: u32,
    rule_name: []const u8,
    message: []const u8,
) RuleError!void {
    const main_tokens = tree.nodes.items(.main_token);
    const token_starts = tree.tokens.items(.start);
    const main_token = main_tokens[node_idx];
    const byte_offset = token_starts[main_token];
    const loc = try src.byteToLocation(byte_offset);
    const diag = try Diagnostic.initAtLocation(
        allocator,
        src.getFilePath(),
        rule_name,
        .warning,
        message,
        loc.line,
        loc.column,
    );
    try diagnostics.append(allocator, diag);
}
