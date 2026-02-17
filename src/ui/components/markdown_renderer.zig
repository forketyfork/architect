const std = @import("std");
const parser = @import("markdown_parser.zig");

pub const LineKind = enum {
    text,
    code,
    table,
    prompt_separator,
    horizontal_rule,
    blank,
};

pub const RenderRun = struct {
    text: []u8,
    style: parser.InlineStyle,
    marker: bool = false,
    href: ?[]u8 = null,
};

pub const TableCell = struct {
    runs: []RenderRun = &.{},
    plain_text: []u8,
};

pub const RenderLine = struct {
    kind: LineKind,
    heading_level: u8 = 0,
    quote_depth: u8 = 0,
    indent_level: u8 = 0,
    runs: []RenderRun = &.{},
    table_cells: []TableCell = &.{},
    plain_text: []u8,
};

pub fn buildLines(
    allocator: std.mem.Allocator,
    blocks: []const parser.DisplayBlock,
    wrap_cols: usize,
) !std.ArrayList(RenderLine) {
    var lines = std.ArrayList(RenderLine).empty;
    errdefer freeLines(allocator, &lines);

    const effective_wrap = @max(@as(usize, 20), wrap_cols);

    for (blocks) |block| {
        switch (block.kind) {
            .blank => {
                try lines.append(allocator, .{
                    .kind = .blank,
                    .plain_text = try allocator.dupe(u8, ""),
                });
            },
            .horizontal_rule => {
                try lines.append(allocator, .{
                    .kind = .horizontal_rule,
                    .plain_text = try allocator.dupe(u8, ""),
                });
            },
            .prompt_separator => {
                try lines.append(allocator, .{
                    .kind = .prompt_separator,
                    .plain_text = try allocator.dupe(u8, ""),
                });
            },
            .code => {
                var run_inputs = std.ArrayList(RunInput).empty;
                defer run_inputs.deinit(allocator);
                for (block.spans) |span| {
                    try run_inputs.append(allocator, .{
                        .text = span.text,
                        .style = .code,
                        .marker = false,
                    });
                }
                try appendLineFromInputs(allocator, &lines, .{
                    .kind = .code,
                    .heading_level = 0,
                    .quote_depth = 0,
                    .indent_level = block.level,
                }, run_inputs.items);
            },
            .table_row => {
                var run_inputs = std.ArrayList(RunInput).empty;
                defer run_inputs.deinit(allocator);
                for (block.spans) |span| {
                    try run_inputs.append(allocator, .{
                        .text = span.text,
                        .style = .normal,
                        .marker = false,
                    });
                }
                const line_idx = lines.items.len;
                try appendLineFromInputs(allocator, &lines, .{
                    .kind = .table,
                    .heading_level = 0,
                    .quote_depth = 0,
                    .indent_level = 0,
                }, run_inputs.items);
                lines.items[line_idx].table_cells = try parseTableCells(allocator, lines.items[line_idx].plain_text);
            },
            .heading, .paragraph, .list_item, .blockquote => {
                var run_inputs = std.ArrayList(RunInput).empty;
                defer run_inputs.deinit(allocator);

                var heading_level: u8 = 0;
                var quote_depth: u8 = 0;
                var indent_level: u8 = 0;

                if (block.kind == .heading) {
                    heading_level = @max(@as(u8, 1), block.level);
                }

                if (block.kind == .blockquote) {
                    quote_depth = @max(@as(u8, 1), block.level);
                }

                if (block.kind == .list_item) {
                    indent_level = block.level;
                    const indent_spaces = @as(usize, indent_level) * 2;
                    if (indent_spaces > 0) {
                        const spaces = try allocator.alloc(u8, indent_spaces);
                        @memset(spaces, ' ');
                        defer allocator.free(spaces);
                        try run_inputs.append(allocator, .{ .text = spaces, .style = .normal, .marker = true });
                    }

                    if (block.task_state == .unchecked) {
                        try run_inputs.append(allocator, .{ .text = "⬜ ", .style = .normal, .marker = true });
                    } else if (block.task_state == .checked) {
                        try run_inputs.append(allocator, .{ .text = "✅ ", .style = .normal, .marker = true });
                    } else if (block.ordered_index) |idx| {
                        var marker_buf: [32]u8 = undefined;
                        const marker = try std.fmt.bufPrint(&marker_buf, "{d}. ", .{idx});
                        try run_inputs.append(allocator, .{ .text = marker, .style = .normal, .marker = true });
                    } else {
                        try run_inputs.append(allocator, .{ .text = "• ", .style = .normal, .marker = true });
                    }
                }

                for (block.spans) |span| {
                    try run_inputs.append(allocator, .{
                        .text = span.text,
                        .style = span.style,
                        .marker = false,
                        .href = span.href,
                    });
                }

                try appendWrappedLines(
                    allocator,
                    &lines,
                    run_inputs.items,
                    effective_wrap,
                    heading_level,
                    quote_depth,
                    indent_level,
                );
            },
        }
    }

    return lines;
}

pub fn freeLines(allocator: std.mem.Allocator, lines: *std.ArrayList(RenderLine)) void {
    for (lines.items) |line| {
        for (line.runs) |run| {
            allocator.free(run.text);
            if (run.href) |href| allocator.free(href);
        }
        if (line.runs.len > 0) allocator.free(line.runs);
        freeTableCells(allocator, line.table_cells);
        allocator.free(line.plain_text);
    }
    lines.deinit(allocator);
    lines.* = .{};
}

fn freeTableCells(allocator: std.mem.Allocator, table_cells: []TableCell) void {
    for (table_cells) |cell| {
        for (cell.runs) |run| {
            allocator.free(run.text);
            if (run.href) |href| allocator.free(href);
        }
        if (cell.runs.len > 0) allocator.free(cell.runs);
        allocator.free(cell.plain_text);
    }
    if (table_cells.len > 0) allocator.free(table_cells);
}

const RunInput = struct {
    text: []const u8,
    style: parser.InlineStyle,
    marker: bool,
    href: ?[]const u8 = null,
};

const LineMeta = struct {
    kind: LineKind,
    heading_level: u8,
    quote_depth: u8,
    indent_level: u8,
};

fn appendWrappedLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(RenderLine),
    runs: []const RunInput,
    wrap_cols: usize,
    heading_level: u8,
    quote_depth: u8,
    indent_level: u8,
) !void {
    var current = std.ArrayList(RenderRun).empty;
    defer {
        for (current.items) |run| {
            allocator.free(run.text);
            if (run.href) |href| allocator.free(href);
        }
        current.deinit(allocator);
    }

    var current_cols: usize = 0;

    for (runs) |run| {
        var token_start: usize = 0;
        while (token_start < run.text.len) {
            const is_space = run.text[token_start] == ' ';
            var token_end = token_start + 1;
            while (token_end < run.text.len and (run.text[token_end] == ' ') == is_space) : (token_end += 1) {}

            var token = run.text[token_start..token_end];
            token_start = token_end;

            while (token.len > 0) {
                if (is_space and current_cols == 0) {
                    break;
                }

                if (!is_space and token.len > wrap_cols) {
                    if (current_cols > 0) {
                        try flushCurrentLine(allocator, lines, &current, heading_level, quote_depth, indent_level);
                        current_cols = 0;
                    }

                    const chunk_len = @min(wrap_cols, token.len);
                    const href = if (run.href) |run_href| try allocator.dupe(u8, run_href) else null;
                    try current.append(allocator, .{
                        .text = try allocator.dupe(u8, token[0..chunk_len]),
                        .style = run.style,
                        .marker = run.marker,
                        .href = href,
                    });
                    current_cols += chunk_len;
                    token = token[chunk_len..];

                    if (current_cols >= wrap_cols) {
                        try flushCurrentLine(allocator, lines, &current, heading_level, quote_depth, indent_level);
                        current_cols = 0;
                    }
                    continue;
                }

                if (current_cols + token.len > wrap_cols and current_cols > 0) {
                    try flushCurrentLine(allocator, lines, &current, heading_level, quote_depth, indent_level);
                    current_cols = 0;
                    if (is_space) {
                        token = "";
                        continue;
                    }
                }

                const href = if (run.href) |run_href| try allocator.dupe(u8, run_href) else null;
                try current.append(allocator, .{
                    .text = try allocator.dupe(u8, token),
                    .style = run.style,
                    .marker = run.marker,
                    .href = href,
                });
                current_cols += token.len;
                token = "";
            }
        }
    }

    if (current.items.len > 0) {
        try flushCurrentLine(allocator, lines, &current, heading_level, quote_depth, indent_level);
    }
}

fn flushCurrentLine(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(RenderLine),
    current: *std.ArrayList(RenderRun),
    heading_level: u8,
    quote_depth: u8,
    indent_level: u8,
) !void {
    if (current.items.len == 0) {
        return;
    }

    const plain = try joinRunText(allocator, current.items);
    const runs = try current.toOwnedSlice(allocator);
    current.* = .{};

    try lines.append(allocator, .{
        .kind = .text,
        .heading_level = heading_level,
        .quote_depth = quote_depth,
        .indent_level = indent_level,
        .runs = runs,
        .plain_text = plain,
    });
}

fn appendLineFromInputs(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(RenderLine),
    meta: LineMeta,
    run_inputs: []const RunInput,
) !void {
    var runs = std.ArrayList(RenderRun).empty;
    errdefer {
        for (runs.items) |run| {
            allocator.free(run.text);
            if (run.href) |href| allocator.free(href);
        }
        runs.deinit(allocator);
    }

    for (run_inputs) |run| {
        if (run.text.len == 0) continue;
        const href = if (run.href) |run_href| try allocator.dupe(u8, run_href) else null;
        try runs.append(allocator, .{
            .text = try allocator.dupe(u8, run.text),
            .style = run.style,
            .marker = run.marker,
            .href = href,
        });
    }

    const plain = try joinRunText(allocator, runs.items);
    try lines.append(allocator, .{
        .kind = meta.kind,
        .heading_level = meta.heading_level,
        .quote_depth = meta.quote_depth,
        .indent_level = meta.indent_level,
        .runs = try runs.toOwnedSlice(allocator),
        .plain_text = plain,
    });
}

fn parseTableCells(allocator: std.mem.Allocator, row_text: []const u8) ![]TableCell {
    var cells_buf: [parser.max_table_columns][]const u8 = undefined;
    const col_count = splitTableCells(row_text, &cells_buf);
    if (col_count == 0) return &.{};
    if (isTableSeparatorLine(cells_buf[0..col_count])) return &.{};

    var table_cells = std.ArrayList(TableCell).empty;
    errdefer {
        freeTableCells(allocator, table_cells.items);
    }

    for (cells_buf[0..col_count]) |cell_text| {
        const spans = try parser.parseInlineSpans(allocator, cell_text);
        defer parser.freeStyledSpans(allocator, spans);

        var runs = std.ArrayList(RenderRun).empty;
        errdefer {
            for (runs.items) |run| {
                allocator.free(run.text);
                if (run.href) |href| allocator.free(href);
            }
            runs.deinit(allocator);
        }

        for (spans) |span| {
            const href = if (span.href) |span_href| try allocator.dupe(u8, span_href) else null;
            try runs.append(allocator, .{
                .text = try allocator.dupe(u8, span.text),
                .style = span.style,
                .marker = false,
                .href = href,
            });
        }

        const plain = try joinRunText(allocator, runs.items);
        try table_cells.append(allocator, .{
            .runs = try runs.toOwnedSlice(allocator),
            .plain_text = plain,
        });
    }

    return table_cells.toOwnedSlice(allocator);
}

fn splitTableCells(line: []const u8, cells: *[parser.max_table_columns][]const u8) usize {
    var inner = std.mem.trim(u8, line, " \t");
    if (inner.len == 0) return 0;
    if (inner[0] == '|') inner = inner[1..];
    if (inner.len > 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];
    if (inner.len == 0) {
        cells[0] = "";
        return 1;
    }

    var count: usize = 0;
    var start: usize = 0;
    while (start <= inner.len and count < parser.max_table_columns) {
        const end = std.mem.indexOfScalarPos(u8, inner, start, '|') orelse inner.len;
        cells[count] = std.mem.trim(u8, inner[start..end], " \t");
        count += 1;
        if (end == inner.len) break;
        start = end + 1;
    }
    return count;
}

fn isSeparatorCell(cell: []const u8) bool {
    if (cell.len == 0) return false;
    var dash_count: usize = 0;
    for (cell) |ch| {
        switch (ch) {
            '-' => dash_count += 1,
            ':' => {},
            else => return false,
        }
    }
    return dash_count >= 3;
}

fn isTableSeparatorLine(cells: []const []const u8) bool {
    if (cells.len == 0) return false;
    for (cells) |cell| {
        if (!isSeparatorCell(cell)) return false;
    }
    return true;
}

fn joinRunText(allocator: std.mem.Allocator, runs: []const RenderRun) ![]u8 {
    var total: usize = 0;
    for (runs) |run| total += run.text.len;

    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (runs) |run| {
        @memcpy(out[pos .. pos + run.text.len], run.text);
        pos += run.text.len;
    }

    return out;
}

test "renderer wraps paragraphs" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(allocator, "hello world from architect");
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 10);
    defer freeLines(allocator, &lines);

    try std.testing.expect(lines.items.len >= 2);
    try std.testing.expectEqual(LineKind.text, lines.items[0].kind);
}

test "renderer keeps code lines as code kind" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(allocator, "```\nconst x = 1;\n```");
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 80);
    defer freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(LineKind.code, lines.items[0].kind);
    try std.testing.expectEqualStrings("const x = 1;", lines.items[0].plain_text);
}

test "renderer emits table line kind for markdown tables" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(
        allocator,
        "| Name | Value |\n| --- | --- |\n| alpha | beta |\n",
    );
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 80);
    defer freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(LineKind.table, lines.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[2].plain_text, "alpha") != null);
}

test "renderer parses inline styles inside table cells" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(
        allocator,
        "| Name | Value |\n| --- | --- |\n| **bold** | *italic* and `code` |\n",
    );
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 80);
    defer freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqual(LineKind.table, lines.items[2].kind);
    try std.testing.expectEqual(@as(usize, 2), lines.items[2].table_cells.len);
    try std.testing.expectEqual(parser.InlineStyle.bold, lines.items[2].table_cells[0].runs[0].style);
    try std.testing.expectEqualStrings("bold", lines.items[2].table_cells[0].runs[0].text);

    const value_runs = lines.items[2].table_cells[1].runs;
    try std.testing.expectEqual(@as(usize, 3), value_runs.len);
    try std.testing.expectEqual(parser.InlineStyle.italic, value_runs[0].style);
    try std.testing.expectEqualStrings("italic", value_runs[0].text);
    try std.testing.expectEqual(parser.InlineStyle.code, value_runs[2].style);
    try std.testing.expectEqualStrings("code", value_runs[2].text);
}

test "renderer blockquote line omits marker characters" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(allocator, "> quoted text\n");
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 80);
    defer freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(LineKind.text, lines.items[0].kind);
    try std.testing.expectEqual(@as(u8, 1), lines.items[0].quote_depth);
    try std.testing.expectEqualStrings("quoted text", lines.items[0].plain_text);
}

test "renderer uses emoji markers for task list items" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(allocator, "- [ ] unchecked\n- [x] checked\n");
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 80);
    defer freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("⬜ unchecked", lines.items[0].plain_text);
    try std.testing.expectEqualStrings("✅ checked", lines.items[1].plain_text);
}

test "renderer preserves href on link runs" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(allocator, "[Architect](https://example.com)\n");
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 80);
    defer freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), lines.items[0].runs.len);
    try std.testing.expectEqual(parser.InlineStyle.link, lines.items[0].runs[0].style);
    try std.testing.expectEqualStrings("https://example.com", lines.items[0].runs[0].href.?);
}

test "renderer emits prompt separator line kind" {
    const allocator = std.testing.allocator;

    var blocks = try parser.parse(allocator, "@@ARCH_PROMPT@@\n{14:28}~/dev/github/forketyfork ➭\n");
    defer parser.freeBlocks(allocator, &blocks);

    var lines = try buildLines(allocator, blocks.items, 80);
    defer freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqual(LineKind.prompt_separator, lines.items[0].kind);
    try std.testing.expectEqual(LineKind.text, lines.items[1].kind);
}
