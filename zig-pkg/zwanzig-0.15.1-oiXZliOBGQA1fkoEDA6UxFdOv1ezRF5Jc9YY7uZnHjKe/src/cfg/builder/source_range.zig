const Source = @import("../../source.zig").Source;
const graph = @import("../graph.zig");

const SourceRange = graph.SourceRange;
const Location = graph.Location;

pub fn getSourceRange(source: *Source, ast_node: u32) !SourceRange {
    const tree = try source.ast();
    const token_starts = tree.tokens.items(.start);
    const main_tokens = tree.nodes.items(.main_token);

    if (ast_node >= main_tokens.len) {
        return SourceRange.fromSingleLocation(Location.init(1, 1));
    }

    const main_token = main_tokens[ast_node];
    if (main_token >= token_starts.len) {
        return SourceRange.fromSingleLocation(Location.init(1, 1));
    }

    const start_byte = token_starts[main_token];
    return source.byteRangeToSourceRange(start_byte, start_byte + 1);
}
