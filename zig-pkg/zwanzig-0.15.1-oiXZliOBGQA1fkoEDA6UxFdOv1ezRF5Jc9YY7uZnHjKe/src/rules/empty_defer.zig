const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const empty_block = @import("empty_block.zig");

pub const EmptyDeferRule = struct {
    pub const rule: Rule = .{
        .name = "empty-defer",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        for (tags, 0..) |tag, i| {
            if (tag == .@"defer") {
                const defer_node: u32 = @intCast(i);
                const defer_body = data[defer_node].node;
                const defer_body_idx = @intFromEnum(defer_body);
                if (empty_block.isEmptyBlock(tags, data, defer_body_idx)) {
                    try empty_block.emitEmptyBlockDiagnostic(
                        src,
                        allocator,
                        diagnostics,
                        tree,
                        defer_node,
                        rule.name,
                        "empty defer block",
                    );
                }
            }
        }
    }
};
