const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const Source = @import("../source.zig").Source;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const RuleError = @import("../rule.zig").RuleError;
const empty_block = @import("empty_block.zig");

pub const EmptyErrdeferRule = struct {
    pub const rule: Rule = .{
        .name = "empty-errdefer",
        .checkFn = check,
    };

    fn check(src: *Source, allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic)) RuleError!void {
        const tree = try src.ast();
        const tags = tree.nodes.items(.tag);
        const data = tree.nodes.items(.data);

        for (tags, 0..) |tag, i| {
            if (tag == .@"errdefer") {
                const errdefer_node: u32 = @intCast(i);
                const errdefer_body = data[errdefer_node].opt_token_and_node[1];

                const errdefer_body_idx = @intFromEnum(errdefer_body);
                if (empty_block.isEmptyBlock(tags, data, errdefer_body_idx)) {
                    try empty_block.emitEmptyBlockDiagnostic(
                        src,
                        allocator,
                        diagnostics,
                        tree,
                        errdefer_node,
                        rule.name,
                        "empty errdefer block",
                    );
                }
            }
        }
    }
};
