const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Source = @import("../source.zig").Source;

/// Rule that detects task-marker comments in Zig code.
/// Task-marker comments indicate unfinished work that should be tracked.
/// This rule scans line and block comments for task markers and reports
/// each occurrence with its location.
pub const TodoCommentRule = struct {
    pub const rule: Rule = Rule{
        .name = "todo",
        .default_severity = .hint,
        .checkFn = check,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const content = src.getContent();

        var line_number: usize = 1;
        var line_start: usize = 0;

        var i: usize = 0;
        while (i < content.len) {
            if (content[i] == '\n') {
                line_start = i + 1;
                line_number += 1;
                i += 1;
                continue;
            }

            if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '/') {
                const comment_start = i;
                i += 2;

                while (i < content.len and (content[i] == '/' or content[i] == '!')) {
                    i += 1;
                }

                while (i < content.len and (content[i] == ' ' or content[i] == '\t')) {
                    i += 1;
                }

                if (isTodoAt(content, i) and isTodoBoundary(content, i + 4)) {
                    const todo_col = comment_start - line_start + 1;

                    var comment_end = i;
                    while (comment_end < content.len and content[comment_end] != '\n') {
                        comment_end += 1;
                    }

                    const range = try src.byteRangeToSourceRange(comment_start, comment_end);
                    const todo_text = extractTodoMessage(content[i..comment_end]);

                    const diag = try Diagnostic.init(
                        allocator,
                        src.getFilePath(),
                        "todo",
                        .hint,
                        todo_text,
                        range,
                    );
                    try diagnostics.append(allocator, diag);

                    _ = todo_col;
                    i = comment_end;
                    continue;
                }
            } else if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '*') {
                const start_index = i;
                i += 2;

                while (i < content.len and (content[i] == '*' or content[i] == '!')) {
                    i += 1;
                }

                var comment_end = i;
                while (comment_end + 1 < content.len) : (comment_end += 1) {
                    if (content[comment_end] == '*' and content[comment_end + 1] == '/') break;
                }

                const scan_end = if (comment_end + 1 < content.len) comment_end else content.len;
                var scan = i;
                while (scan + 3 < scan_end) {
                    if (isTodoAt(content, scan) and isTodoBoundary(content, scan + 4) and isTodoBoundaryBefore(content, scan)) {
                        var message_end = scan;
                        while (message_end < scan_end and content[message_end] != '\n') {
                            message_end += 1;
                        }

                        const range = try src.byteRangeToSourceRange(scan, message_end);
                        const todo_text = extractTodoMessage(content[scan..message_end]);

                        const diag = try Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "todo",
                            .hint,
                            todo_text,
                            range,
                        );
                        try diagnostics.append(allocator, diag);
                        scan = message_end;
                    } else {
                        scan += 1;
                    }
                }

                const advance_end = if (comment_end + 1 < content.len) comment_end + 2 else comment_end;
                var advance = start_index;
                while (advance < advance_end) : (advance += 1) {
                    if (content[advance] == '\n') {
                        line_start = advance + 1;
                        line_number += 1;
                    }
                }

                i = advance_end;
                continue;
            }

            i += 1;
        }
    }

    fn isTodoAt(content: []const u8, pos: usize) bool {
        if (pos + 4 > content.len) return false;
        return (std.ascii.toLower(content[pos + 0]) == 't' and
            std.ascii.toLower(content[pos + 1]) == 'o' and
            std.ascii.toLower(content[pos + 2]) == 'd' and
            std.ascii.toLower(content[pos + 3]) == 'o');
    }

    fn isTodoBoundary(content: []const u8, pos: usize) bool {
        if (pos >= content.len) return true;
        const c = content[pos];
        return !std.ascii.isAlphanumeric(c) and c != '_';
    }

    fn isTodoBoundaryBefore(content: []const u8, pos: usize) bool {
        if (pos == 0) return true;
        const c = content[pos - 1];
        return !std.ascii.isAlphanumeric(c) and c != '_';
    }

    fn extractTodoMessage(todo_content: []const u8) []const u8 {
        if (todo_content.len < 4) return "TODO comment found";

        var start: usize = 4;

        while (start < todo_content.len and (todo_content[start] == ':' or todo_content[start] == ' ' or todo_content[start] == '\t')) {
            start += 1;
        }

        if (start >= todo_content.len) {
            return "TODO comment found";
        }

        var end = todo_content.len;
        while (end > start and (todo_content[end - 1] == ' ' or todo_content[end - 1] == '\t' or todo_content[end - 1] == '\r')) {
            end -= 1;
        }

        if (end > start) {
            return todo_content[start..end];
        }

        return "TODO comment found";
    }
};
