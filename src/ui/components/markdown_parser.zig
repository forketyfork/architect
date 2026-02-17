const std = @import("std");

pub const BlockKind = enum {
    heading,
    paragraph,
    list_item,
    blockquote,
    prompt_separator,
    table_row,
    code,
    horizontal_rule,
    blank,
};

pub const InlineStyle = enum {
    normal,
    bold,
    italic,
    strikethrough,
    code,
    link,
};

pub const StyledSpan = struct {
    text: []u8,
    style: InlineStyle,
    href: ?[]u8 = null,
};

pub const TaskState = enum {
    none,
    unchecked,
    checked,
};

pub const DisplayBlock = struct {
    kind: BlockKind,
    level: u8 = 0,
    ordered_index: ?usize = null,
    task_state: TaskState = .none,
    code_language: ?[]u8 = null,
    spans: []StyledSpan = &.{},
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(DisplayBlock) {
    var blocks = std.ArrayList(DisplayBlock).empty;
    errdefer freeBlocks(allocator, &blocks);
    if (input.len == 0) return blocks;

    var paragraph_lines = std.ArrayList([]const u8).empty;
    defer paragraph_lines.deinit(allocator);

    var in_code = false;
    var code_language: ?[]u8 = null;

    var line_start: usize = 0;
    while (line_start < input.len) {
        const line_info = readLine(input, line_start);
        const line = trimRightSpaces(line_info.line);
        const next_start = line_info.next_start orelse input.len;

        if (in_code) {
            if (isFenceLine(line)) {
                in_code = false;
                if (code_language) |lang| allocator.free(lang);
                code_language = null;
            } else {
                var block = DisplayBlock{ .kind = .code };
                if (code_language) |lang| {
                    block.code_language = try allocator.dupe(u8, lang);
                }
                block.spans = try buildSingleSpan(allocator, line, .code);
                try blocks.append(allocator, block);
            }
            line_start = next_start;
            continue;
        }

        if (isFenceLine(line)) {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            in_code = true;
            const lang = parseFenceLanguage(line);
            if (lang.len > 0) {
                code_language = try allocator.dupe(u8, lang);
            }
            line_start = next_start;
            continue;
        }

        if (line.len == 0) {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            try blocks.append(allocator, .{ .kind = .blank });
            line_start = next_start;
            continue;
        }

        if (std.mem.eql(u8, line, prompt_marker_line)) {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            try blocks.append(allocator, .{ .kind = .prompt_separator });
            line_start = next_start;
            continue;
        }

        const has_recent_prompt_separator = blocks.items.len > 0 and
            blocks.items[blocks.items.len - 1].kind == .prompt_separator;
        if (isPromptHeuristicLine(line) and !has_recent_prompt_separator) {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            try blocks.append(allocator, .{ .kind = .prompt_separator });
        }

        if (isTableRowCandidate(line) and line_info.next_start != null) {
            const sep_info = readLine(input, line_info.next_start.?);
            if (isTableSeparatorLine(sep_info.line)) {
                try flushParagraph(allocator, &blocks, &paragraph_lines);

                var table_lines = std.ArrayList([]const u8).empty;
                errdefer table_lines.deinit(allocator);
                try table_lines.append(allocator, line);

                var scan_start = sep_info.next_start orelse input.len;
                while (scan_start < input.len) {
                    const row_info = readLine(input, scan_start);
                    const row_line = trimRightSpaces(row_info.line);
                    if (row_line.len == 0 or !isTableRowCandidate(row_line) or isFenceLine(row_line)) break;
                    try table_lines.append(allocator, row_line);
                    scan_start = row_info.next_start orelse input.len;
                }

                try appendTableBlocks(allocator, &blocks, table_lines.items);
                table_lines.deinit(allocator);
                line_start = scan_start;
                continue;
            }
        }

        if (parseHeading(line)) |heading| {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            var block = DisplayBlock{ .kind = .heading, .level = heading.level };
            block.spans = try parseInlineSpans(allocator, heading.text);
            try blocks.append(allocator, block);
            line_start = next_start;
            continue;
        }

        if (parseListItem(line)) |item| {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            var block = DisplayBlock{
                .kind = .list_item,
                .level = item.indent,
                .ordered_index = item.ordered_index,
                .task_state = item.task_state,
            };
            block.spans = try parseInlineSpans(allocator, item.text);
            try blocks.append(allocator, block);
            line_start = next_start;
            continue;
        }

        if (parseBlockquote(line)) |quote| {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            var block = DisplayBlock{ .kind = .blockquote, .level = quote.depth };
            block.spans = try parseInlineSpans(allocator, quote.text);
            try blocks.append(allocator, block);
            line_start = next_start;
            continue;
        }

        if (isHorizontalRule(line)) {
            try flushParagraph(allocator, &blocks, &paragraph_lines);
            try blocks.append(allocator, .{ .kind = .horizontal_rule });
            line_start = next_start;
            continue;
        }

        try paragraph_lines.append(allocator, line);
        try flushParagraph(allocator, &blocks, &paragraph_lines);
        line_start = next_start;
    }

    if (in_code and code_language != null) {
        allocator.free(code_language.?);
    }

    try flushParagraph(allocator, &blocks, &paragraph_lines);
    return blocks;
}

pub fn freeBlocks(allocator: std.mem.Allocator, blocks: *std.ArrayList(DisplayBlock)) void {
    for (blocks.items) |block| {
        if (block.code_language) |lang| allocator.free(lang);
        for (block.spans) |span| {
            allocator.free(span.text);
            if (span.href) |href| allocator.free(href);
        }
        if (block.spans.len > 0) {
            allocator.free(block.spans);
        }
    }
    blocks.deinit(allocator);
    blocks.* = .{};
}

fn trimRightSpaces(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, " \t");
}

const LineInfo = struct {
    line: []const u8,
    next_start: ?usize,
};

fn readLine(input: []const u8, start: usize) LineInfo {
    const line_end = std.mem.indexOfScalarPos(u8, input, start, '\n') orelse input.len;
    const raw_line = std.mem.trimRight(u8, input[start..line_end], "\r");
    const next_start: ?usize = if (line_end < input.len) line_end + 1 else null;
    return .{
        .line = raw_line,
        .next_start = next_start,
    };
}

fn isFenceLine(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "```");
}

fn parseFenceLanguage(line: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "```")) return "";
    return std.mem.trim(u8, trimmed[3..], " \t");
}

fn isHorizontalRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;

    const marker = trimmed[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;

    for (trimmed) |ch| {
        if (ch != marker) return false;
    }
    return true;
}

const Heading = struct {
    level: u8,
    text: []const u8,
};

fn parseHeading(line: []const u8) ?Heading {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] != '#') return null;

    var level: usize = 0;
    while (level < trimmed.len and trimmed[level] == '#') : (level += 1) {}
    if (level == 0 or level > 6) return null;
    if (level >= trimmed.len or trimmed[level] != ' ') return null;

    return .{
        .level = @intCast(level),
        .text = std.mem.trim(u8, trimmed[level + 1 ..], " \t"),
    };
}

const ListItem = struct {
    indent: u8,
    ordered_index: ?usize,
    task_state: TaskState,
    text: []const u8,
};

fn parseListItem(line: []const u8) ?ListItem {
    const leading = countLeadingSpaces(line);
    const indent_level: u8 = @intCast(@min(leading / 2, 12));
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len < 2) return null;

    if ((trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
        const task = parseTaskState(std.mem.trim(u8, trimmed[2..], " \t"));
        return .{
            .indent = indent_level,
            .ordered_index = null,
            .task_state = task.state,
            .text = task.text,
        };
    }

    var pos: usize = 0;
    while (pos < trimmed.len and std.ascii.isDigit(trimmed[pos])) : (pos += 1) {}
    if (pos == 0 or pos + 1 >= trimmed.len) return null;

    const delimiter = trimmed[pos];
    if (delimiter != '.' and delimiter != ')') return null;
    if (trimmed[pos + 1] != ' ') return null;

    const idx = std.fmt.parseInt(usize, trimmed[0..pos], 10) catch return null;
    const task = parseTaskState(std.mem.trim(u8, trimmed[pos + 2 ..], " \t"));
    return .{
        .indent = indent_level,
        .ordered_index = idx,
        .task_state = task.state,
        .text = task.text,
    };
}

const ParsedTask = struct {
    state: TaskState,
    text: []const u8,
};

fn parseTaskState(text: []const u8) ParsedTask {
    if (text.len >= 4 and text[0] == '[' and (text[1] == ' ' or text[1] == 'x' or text[1] == 'X') and text[2] == ']' and text[3] == ' ') {
        return .{
            .state = if (text[1] == ' ') .unchecked else .checked,
            .text = std.mem.trim(u8, text[4..], " \t"),
        };
    }
    return .{ .state = .none, .text = text };
}

const BlockquoteLine = struct {
    depth: u8,
    text: []const u8,
};

fn parseBlockquote(line: []const u8) ?BlockquoteLine {
    var trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] != '>') return null;

    var depth: usize = 0;
    while (trimmed.len > 0 and trimmed[0] == '>') {
        depth += 1;
        trimmed = trimmed[1..];
        trimmed = std.mem.trimLeft(u8, trimmed, " \t");
    }

    return .{
        .depth = @intCast(@min(depth, 8)),
        .text = std.mem.trim(u8, trimmed, " \t"),
    };
}

fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ') {
            count += 1;
        } else if (ch == '\t') {
            count += 4;
        } else {
            break;
        }
    }
    return count;
}

fn isTableRowCandidate(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

fn isPromptHeuristicLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;

    if (std.mem.startsWith(u8, trimmed, "#") or
        std.mem.startsWith(u8, trimmed, "- ") or
        std.mem.startsWith(u8, trimmed, "* ") or
        std.mem.startsWith(u8, trimmed, ">") or
        std.mem.startsWith(u8, trimmed, "```") or
        std.mem.indexOfScalar(u8, trimmed, '|') != null)
    {
        return false;
    }

    if (std.mem.indexOf(u8, trimmed, "➭") != null) return true;

    const last = trimmed[trimmed.len - 1];
    if (last != '$' and last != '%' and last != '#') return false;

    return std.mem.indexOfScalar(u8, trimmed, '~') != null or
        std.mem.indexOfScalar(u8, trimmed, '/') != null or
        std.mem.indexOfScalar(u8, trimmed, '@') != null;
}

const max_table_columns: usize = 32;
const prompt_marker_line = "@@ARCH_PROMPT@@";

fn splitTableCellsFixed(line: []const u8, cells: *[max_table_columns][]const u8) usize {
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
    while (start <= inner.len and count < max_table_columns) {
        const end = std.mem.indexOfScalarPos(u8, inner, start, '|') orelse inner.len;
        cells[count] = std.mem.trim(u8, inner[start..end], " \t");
        count += 1;
        if (end == inner.len) break;
        start = end + 1;
    }
    return count;
}

fn isTableSeparatorCell(cell: []const u8) bool {
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

fn isTableSeparatorLine(line: []const u8) bool {
    if (!isTableRowCandidate(line)) return false;

    var cells: [max_table_columns][]const u8 = undefined;
    const cell_count = splitTableCellsFixed(line, &cells);
    if (cell_count == 0) return false;

    for (cells[0..cell_count]) |cell| {
        if (!isTableSeparatorCell(cell)) return false;
    }
    return true;
}

fn ensureColumnWidths(widths: *std.ArrayList(usize), allocator: std.mem.Allocator, target: usize) !void {
    while (widths.items.len < target) {
        try widths.append(allocator, 0);
    }
}

fn formatTableRowAlloc(allocator: std.mem.Allocator, cells: []const []const u8, widths: []const usize) ![]u8 {
    var total: usize = 1;
    for (widths) |width| total += 3 + width;

    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    out[pos] = '|';
    pos += 1;

    for (widths, 0..) |width, idx| {
        const cell = if (idx < cells.len) cells[idx] else "";
        const pad = if (width > cell.len) width - cell.len else 0;

        out[pos] = ' ';
        pos += 1;
        if (cell.len > 0) {
            @memcpy(out[pos .. pos + cell.len], cell);
            pos += cell.len;
        }
        if (pad > 0) {
            @memset(out[pos .. pos + pad], ' ');
            pos += pad;
        }
        out[pos] = ' ';
        out[pos + 1] = '|';
        pos += 2;
    }

    return out;
}

fn formatTableSeparatorAlloc(allocator: std.mem.Allocator, widths: []const usize) ![]u8 {
    var total: usize = 1;
    for (widths) |width| total += 3 + @max(@as(usize, 3), width);

    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    out[pos] = '|';
    pos += 1;

    for (widths) |width| {
        const dash_count = @max(@as(usize, 3), width);
        out[pos] = ' ';
        pos += 1;
        @memset(out[pos .. pos + dash_count], '-');
        pos += dash_count;
        out[pos] = ' ';
        out[pos + 1] = '|';
        pos += 2;
    }

    return out;
}

fn appendTableBlocks(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(DisplayBlock),
    rows: []const []const u8,
) !void {
    if (rows.len == 0) return;

    var widths = std.ArrayList(usize).empty;
    defer widths.deinit(allocator);

    var cells: [max_table_columns][]const u8 = undefined;

    for (rows) |row| {
        const cell_count = splitTableCellsFixed(row, &cells);
        try ensureColumnWidths(&widths, allocator, cell_count);
        for (cells[0..cell_count], 0..) |cell, idx| {
            widths.items[idx] = @max(widths.items[idx], cell.len);
        }
    }

    var row_idx: usize = 0;
    while (row_idx < rows.len) : (row_idx += 1) {
        const cell_count = splitTableCellsFixed(rows[row_idx], &cells);
        const formatted = try formatTableRowAlloc(allocator, cells[0..cell_count], widths.items);
        errdefer allocator.free(formatted);
        var row_block = DisplayBlock{ .kind = .table_row };
        row_block.spans = try buildSingleSpan(allocator, formatted, .normal);
        allocator.free(formatted);
        try blocks.append(allocator, row_block);

        if (row_idx == 0) {
            const separator = try formatTableSeparatorAlloc(allocator, widths.items);
            errdefer allocator.free(separator);
            var separator_block = DisplayBlock{ .kind = .table_row };
            separator_block.spans = try buildSingleSpan(allocator, separator, .normal);
            allocator.free(separator);
            try blocks.append(allocator, separator_block);
        }
    }
}

fn flushParagraph(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(DisplayBlock),
    paragraph_lines: *std.ArrayList([]const u8),
) !void {
    if (paragraph_lines.items.len == 0) return;

    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);

    for (paragraph_lines.items, 0..) |line, idx| {
        if (idx > 0) {
            try joined.append(allocator, ' ');
        }
        try joined.appendSlice(allocator, line);
    }

    var block = DisplayBlock{ .kind = .paragraph };
    block.spans = try parseInlineSpans(allocator, joined.items);
    try blocks.append(allocator, block);
    paragraph_lines.clearRetainingCapacity();
}

fn buildSingleSpan(allocator: std.mem.Allocator, text: []const u8, style: InlineStyle) ![]StyledSpan {
    var spans = std.ArrayList(StyledSpan).empty;
    errdefer {
        for (spans.items) |span| allocator.free(span.text);
        spans.deinit(allocator);
    }

    try appendSpan(&spans, allocator, text, style);
    return spans.toOwnedSlice(allocator);
}

fn parseInlineSpans(allocator: std.mem.Allocator, text: []const u8) ![]StyledSpan {
    var spans = std.ArrayList(StyledSpan).empty;
    errdefer {
        for (spans.items) |span| {
            allocator.free(span.text);
            if (span.href) |href| allocator.free(href);
        }
        spans.deinit(allocator);
    }

    var i: usize = 0;
    while (i < text.len) {
        if (parseMarkdownLinkAt(text, i)) |link| {
            try appendSpanWithHref(&spans, allocator, link.label, .link, link.href);
            i = link.next_index;
            continue;
        }

        if (i + 1 < text.len and text[i] == '~' and text[i + 1] == '~') {
            if (std.mem.indexOfPos(u8, text, i + 2, "~~")) |end| {
                try appendSpan(&spans, allocator, text[i + 2 .. end], .strikethrough);
                i = end + 2;
                continue;
            }
        }

        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try appendSpan(&spans, allocator, text[i + 2 .. end], .bold);
                i = end + 2;
                continue;
            }
        }

        if (text[i] == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                try appendSpan(&spans, allocator, text[i + 1 .. end], .italic);
                i = end + 1;
                continue;
            }
        }

        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                try appendSpan(&spans, allocator, text[i + 1 .. end], .code);
                i = end + 1;
                continue;
            }
        }

        const next_special = findNextInlineMarker(text, i + 1) orelse text.len;
        try appendSpan(&spans, allocator, text[i..next_special], .normal);
        i = next_special;
    }

    if (spans.items.len == 0) {
        try appendSpan(&spans, allocator, "", .normal);
    }

    return spans.toOwnedSlice(allocator);
}

fn findNextInlineMarker(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (text[i] == '*' or text[i] == '`' or text[i] == '~' or text[i] == '[') return i;
    }
    return null;
}

fn appendSpan(spans: *std.ArrayList(StyledSpan), allocator: std.mem.Allocator, text: []const u8, style: InlineStyle) !void {
    if (text.len == 0) return;
    try spans.append(allocator, .{
        .text = try allocator.dupe(u8, text),
        .style = style,
        .href = null,
    });
}

fn appendSpanWithHref(
    spans: *std.ArrayList(StyledSpan),
    allocator: std.mem.Allocator,
    text: []const u8,
    style: InlineStyle,
    href: []const u8,
) !void {
    if (text.len == 0 or href.len == 0) return;

    const text_dupe = try allocator.dupe(u8, text);
    errdefer allocator.free(text_dupe);
    const href_dupe = try allocator.dupe(u8, href);
    errdefer allocator.free(href_dupe);

    try spans.append(allocator, .{
        .text = text_dupe,
        .style = style,
        .href = href_dupe,
    });
}

const ParsedLink = struct {
    label: []const u8,
    href: []const u8,
    next_index: usize,
};

fn parseMarkdownLinkAt(text: []const u8, start: usize) ?ParsedLink {
    if (start >= text.len or text[start] != '[') return null;

    const close_label = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (close_label + 1 >= text.len or text[close_label + 1] != '(') return null;
    const close_href = std.mem.indexOfScalarPos(u8, text, close_label + 2, ')') orelse return null;

    const label = text[start + 1 .. close_label];
    const href = std.mem.trim(u8, text[close_label + 2 .. close_href], " \t");
    if (label.len == 0 or href.len == 0) return null;

    return .{
        .label = label,
        .href = href,
        .next_index = close_href + 1,
    };
}

test "parser handles headings and inline styles" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "# Heading\n\nParagraph with **bold** and *italic* and ~~strike~~ and `code`.\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 3), blocks.items.len);
    try std.testing.expectEqual(BlockKind.heading, blocks.items[0].kind);
    try std.testing.expectEqual(@as(u8, 1), blocks.items[0].level);

    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[2].kind);
    var saw_bold = false;
    var saw_italic = false;
    var saw_strike = false;
    var saw_code = false;
    for (blocks.items[2].spans) |span| {
        if (span.style == .bold) saw_bold = true;
        if (span.style == .italic) saw_italic = true;
        if (span.style == .strikethrough) saw_strike = true;
        if (span.style == .code) saw_code = true;
    }
    try std.testing.expect(saw_bold);
    try std.testing.expect(saw_italic);
    try std.testing.expect(saw_strike);
    try std.testing.expect(saw_code);
}

test "parser handles fenced code blocks" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "```zig\nconst x = 1;\nconst y = 2;\n```\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 2), blocks.items.len);
    try std.testing.expectEqual(BlockKind.code, blocks.items[0].kind);
    try std.testing.expectEqualStrings("zig", blocks.items[0].code_language.?);
    try std.testing.expectEqualStrings("const x = 1;", blocks.items[0].spans[0].text);
}

test "parser handles lists and blockquotes" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "- one\n  - two\n1. first\n> quote\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 4), blocks.items.len);
    try std.testing.expectEqual(BlockKind.list_item, blocks.items[0].kind);
    try std.testing.expectEqual(@as(u8, 0), blocks.items[0].level);
    try std.testing.expectEqual(@as(?usize, null), blocks.items[0].ordered_index);
    try std.testing.expectEqual(TaskState.none, blocks.items[0].task_state);

    try std.testing.expectEqual(BlockKind.list_item, blocks.items[1].kind);
    try std.testing.expectEqual(@as(u8, 1), blocks.items[1].level);

    try std.testing.expectEqual(BlockKind.list_item, blocks.items[2].kind);
    try std.testing.expectEqual(@as(?usize, 1), blocks.items[2].ordered_index);

    try std.testing.expectEqual(BlockKind.blockquote, blocks.items[3].kind);
}

test "parser handles task checkboxes and markdown links" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "- [ ] unchecked task\n- [x] checked task\n\n[Architect](https://example.com)\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 4), blocks.items.len);
    try std.testing.expectEqual(BlockKind.list_item, blocks.items[0].kind);
    try std.testing.expectEqual(TaskState.unchecked, blocks.items[0].task_state);
    try std.testing.expectEqualStrings("unchecked task", blocks.items[0].spans[0].text);

    try std.testing.expectEqual(BlockKind.list_item, blocks.items[1].kind);
    try std.testing.expectEqual(TaskState.checked, blocks.items[1].task_state);
    try std.testing.expectEqualStrings("checked task", blocks.items[1].spans[0].text);

    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[3].kind);
    try std.testing.expectEqual(@as(usize, 1), blocks.items[3].spans.len);
    try std.testing.expectEqual(InlineStyle.link, blocks.items[3].spans[0].style);
    try std.testing.expectEqualStrings("Architect", blocks.items[3].spans[0].text);
    try std.testing.expectEqualStrings("https://example.com", blocks.items[3].spans[0].href.?);
}

test "parser handles horizontal rule and plain text" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "plain text\n---\nmore text\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 3), blocks.items.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[0].kind);
    try std.testing.expectEqual(BlockKind.horizontal_rule, blocks.items[1].kind);
    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[2].kind);
}

test "parser handles markdown tables" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "| Name | Value |\n| --- | --- |\n| alpha | beta |\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 3), blocks.items.len);
    try std.testing.expectEqual(BlockKind.table_row, blocks.items[0].kind);
    try std.testing.expectEqual(BlockKind.table_row, blocks.items[1].kind);
    try std.testing.expectEqual(BlockKind.table_row, blocks.items[2].kind);
    try std.testing.expect(std.mem.startsWith(u8, blocks.items[0].spans[0].text, "| Name"));
    try std.testing.expect(std.mem.indexOf(u8, blocks.items[2].spans[0].text, "alpha") != null);
}

test "parser handles empty input" {
    const allocator = std.testing.allocator;

    var blocks = try parse(allocator, "");
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
}

test "parser preserves hard line breaks and emits prompt separators" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "{13:36}~/dev/github/forketyfork ➭\n{13:52}~/dev/github/forketyfork ➭\n{13:52}~/dev/github/forketyfork ➭\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 6), blocks.items.len);
    try std.testing.expectEqual(BlockKind.prompt_separator, blocks.items[0].kind);
    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[1].kind);
    try std.testing.expectEqual(BlockKind.prompt_separator, blocks.items[2].kind);
    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[3].kind);
    try std.testing.expectEqual(BlockKind.prompt_separator, blocks.items[4].kind);
    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[5].kind);
    try std.testing.expect(std.mem.indexOf(u8, blocks.items[1].spans[0].text, "{13:36}") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocks.items[3].spans[0].text, "{13:52}") != null);
}

test "parser emits single prompt separator for OSC marker plus prompt line" {
    const allocator = std.testing.allocator;

    var blocks = try parse(
        allocator,
        "hello\n@@ARCH_PROMPT@@\n{14:28}~/dev/github/forketyfork ➭ echo hi\n",
    );
    defer freeBlocks(allocator, &blocks);

    try std.testing.expectEqual(@as(usize, 3), blocks.items.len);
    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[0].kind);
    try std.testing.expectEqual(BlockKind.prompt_separator, blocks.items[1].kind);
    try std.testing.expectEqual(BlockKind.paragraph, blocks.items[2].kind);
}
