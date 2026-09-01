const graph = @import("../graph.zig");
const Source = @import("../../source.zig").Source;
const IrNode = graph.IrNode;

pub fn mixin(comptime _Builder: type) type {
    return struct {
        /// Annotate an IR node with type information if available.
        /// Returns the node (possibly enriched with type info).
        pub fn annotateWithType(self: *_Builder, node: IrNode, source: *Source, ast_node: u32) IrNode {
            // Try to get type from TypeContext first (cached)
            if (self.type_context) |ctx| {
                if (ctx.getNodeType(ast_node)) |ti| {
                    return node.withType(ti);
                }
            }

            // Fallback: try to get type from source's ZirBridge
            if (self.type_context == null) {
                // No type context, but we can still try source's ZirBridge
                if (source.zirBridge()) |bridge| {
                    const count = bridge.getDeclCount();
                    for (0..count) |i| {
                        if (bridge.getDecl(i)) |decl| {
                            if (decl.ast_node == ast_node) {
                                return node.withType(decl.type_info);
                            }
                        }
                    }
                }
            }

            return node;
        }
    };
}
