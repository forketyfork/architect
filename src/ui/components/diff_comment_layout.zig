const std = @import("std");
const dpi = @import("../../dpi.zig");

const log = std.log.scoped(.diff_comment_layout);

pub const WrappedLine = struct {
    start: usize,
    end: usize,
};

pub const EditingLayout = struct {
    wrap_cols: usize = 0,
    line_count: usize,
    input_h: c_int,
    total_h: c_int,
};

pub fn textDisplayCols(text: []const u8, tab_width: usize, min_printable_char: u8) usize {
    var cols: usize = 0;
    for (text) |ch| {
        if (ch == '\t') cols += tab_width else if (ch >= min_printable_char) cols += 1;
    }
    return cols;
}

pub fn byteOffsetAtDisplayCol(text: []const u8, start: usize, max_cols: usize, tab_width: usize, min_printable_char: u8) usize {
    var cols: usize = 0;
    var i: usize = start;
    while (i < text.len) {
        const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch |err| blk: {
            log.warn("invalid UTF-8 lead byte at offset {}: {}", .{ i, err });
            break :blk 1;
        };
        const advance: usize = if (text[i] == '\t') tab_width else if (text[i] >= min_printable_char) 1 else 0;
        if (cols + advance > max_cols and cols > 0) break;
        cols += advance;
        i += @min(byte_len, text.len - i);
    }
    return i;
}

pub fn forEachWrappedLine(
    text: []const u8,
    max_cols: usize,
    tab_width: usize,
    min_printable_char: u8,
    context: anytype,
    comptime callback: fn (@TypeOf(context), WrappedLine) void,
) void {
    var logical_start: usize = 0;
    while (logical_start <= text.len) {
        const logical_end = std.mem.indexOfScalarPos(u8, text, logical_start, '\n') orelse text.len;
        const logical_line = text[logical_start..logical_end];

        if (logical_line.len == 0) {
            callback(context, .{ .start = logical_start, .end = logical_start });
        } else if (max_cols == 0 or textDisplayCols(logical_line, tab_width, min_printable_char) <= max_cols) {
            callback(context, .{ .start = logical_start, .end = logical_end });
        } else {
            var rel_start: usize = 0;
            while (rel_start < logical_line.len) {
                const rel_end = byteOffsetAtDisplayCol(logical_line, rel_start, max_cols, tab_width, min_printable_char);
                if (rel_end <= rel_start) {
                    const byte_len = std.unicode.utf8ByteSequenceLength(logical_line[rel_start]) catch |err| blk: {
                        log.warn("invalid UTF-8 lead byte in wrapped line at offset {}: {}", .{ rel_start, err });
                        break :blk 1;
                    };
                    const safe_end = @min(logical_line.len, rel_start + byte_len);
                    callback(context, .{
                        .start = logical_start + rel_start,
                        .end = logical_start + safe_end,
                    });
                    rel_start = safe_end;
                    continue;
                }
                callback(context, .{
                    .start = logical_start + rel_start,
                    .end = logical_start + rel_end,
                });
                rel_start = rel_end;
            }
        }

        if (logical_end == text.len) break;
        logical_start = logical_end + 1;
    }
}

pub fn wrappedLineCount(text: []const u8, max_cols: usize, tab_width: usize, min_printable_char: u8) usize {
    const CountContext = struct {
        count: usize = 0,

        fn visit(ctx: *@This(), _: WrappedLine) void {
            ctx.count += 1;
        }
    };

    var context = CountContext{};
    forEachWrappedLine(text, max_cols, tab_width, min_printable_char, &context, CountContext.visit);
    return @max(@as(usize, 1), context.count);
}

pub fn savedCommentHeightForLineCount(ui_scale: f32, line_height_px: c_int, min_height_px: c_int, line_count: usize) c_int {
    const wrapped_line_count = @max(@as(usize, 1), line_count);
    return @max(
        dpi.scale(min_height_px, ui_scale),
        @as(c_int, @intCast(wrapped_line_count)) * line_height_px + dpi.scale(8, ui_scale),
    );
}

pub fn editingCommentLayoutForLineCount(
    ui_scale: f32,
    line_height_px: c_int,
    input_min_height_px: c_int,
    total_min_height_px: c_int,
    extra_height_px: c_int,
    line_count: usize,
) EditingLayout {
    const wrapped_line_count = @max(@as(usize, 1), line_count);
    const input_h = @max(
        dpi.scale(input_min_height_px, ui_scale),
        @as(c_int, @intCast(wrapped_line_count)) * line_height_px + dpi.scale(8, ui_scale),
    );
    return .{
        .line_count = wrapped_line_count,
        .input_h = input_h,
        .total_h = @max(
            dpi.scale(total_min_height_px, ui_scale),
            input_h + dpi.scale(extra_height_px, ui_scale),
        ),
    };
}

test "wrapped diff comments expand beyond single-line minimum heights" {
    const long_comment =
        "This diff comment should wrap across multiple lines instead of shrinking to fit into one line.";
    const wrap_cols = 18;
    const line_count = wrappedLineCount(long_comment, wrap_cols, 4, 32);

    try std.testing.expect(line_count > 1);

    const saved_h = savedCommentHeightForLineCount(1.0, 22, 32, line_count);
    try std.testing.expect(saved_h > 32);

    const editing_layout = editingCommentLayoutForLineCount(1.0, 22, 44, 90, 46, line_count);
    try std.testing.expect(editing_layout.input_h > 44);
    try std.testing.expect(editing_layout.total_h > 90);
}
