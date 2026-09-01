const std = @import("std");
const compat = @import("../compat.zig");
const Diagnostic = @import("../rule.zig").Diagnostic;

pub const ConsoleFormatter = struct {
    allocator: std.mem.Allocator,
    io_context: *compat.Context,
    file_cache: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, io_context: *compat.Context) ConsoleFormatter {
        return .{
            .allocator = allocator,
            .io_context = io_context,
            .file_cache = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ConsoleFormatter) void {
        var value_iter = self.file_cache.valueIterator();
        while (value_iter.next()) |value| {
            freeSentinelContent(self.allocator, value.*);
        }
        self.file_cache.deinit();
    }

    pub fn write(self: *ConsoleFormatter, writer: anytype, diagnostics: []const Diagnostic) !void {
        defer self.deinit();

        if (diagnostics.len == 0) {
            try writer.writeAll("No issues found.\n");
            return;
        }

        try writer.print("Found {d} issue(s):\n", .{diagnostics.len});
        for (diagnostics) |diag| {
            try diag.format(writer);

            const content = self.getFileContent(diag.file_path) orelse continue;
            const line = lineSliceFor(content, diag.range.start.line) orelse continue;

            try writer.print("  {s}\n", .{line});

            const line_len = line.len;
            var start_col = diag.range.start.column;
            if (start_col == 0) {
                start_col = 1;
            }
            if (line_len > 0 and start_col > line_len) {
                start_col = line_len;
            }

            var end_col: usize = start_col;
            if (diag.range.end.line == diag.range.start.line) {
                end_col = diag.range.end.column;
            }
            if (end_col < start_col) {
                end_col = start_col;
            }
            if (line_len > 0 and end_col > line_len) {
                end_col = line_len;
            }

            const caret_len = if (line_len == 0) 1 else @max(end_col - start_col + 1, 1);
            try writer.writeAll("  ");
            var space_index: usize = 1;
            while (space_index < start_col) : (space_index += 1) {
                try writer.writeByte(' ');
            }
            var caret_index: usize = 0;
            while (caret_index < caret_len) : (caret_index += 1) {
                try writer.writeByte('^');
            }
            try writer.writeByte('\n');
        }
    }

    fn getFileContent(self: *ConsoleFormatter, file_path: []const u8) ?[]const u8 {
        if (self.file_cache.get(file_path)) |cached| {
            return cached;
        }

        const max_size = 10 * 1024 * 1024;
        const loaded_with_sentinel = compat.readFileAlloc(self.io_context, self.allocator, file_path, max_size) catch return null;
        const loaded = loaded_with_sentinel[0..loaded_with_sentinel.len];

        self.file_cache.put(file_path, loaded) catch {
            freeSentinelContent(self.allocator, loaded_with_sentinel);
            return null;
        };
        return loaded;
    }
};

fn freeSentinelContent(allocator: std.mem.Allocator, content: []const u8) void {
    allocator.free(content.ptr[0 .. content.len + 1]);
}

fn lineSliceFor(content: []const u8, line_number: usize) ?[]const u8 {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var current_line: usize = 1;
    while (line_iter.next()) |line| : (current_line += 1) {
        if (current_line == line_number) {
            if (line.len > 0 and line[line.len - 1] == '\r') {
                return line[0 .. line.len - 1];
            }
            return line;
        }
    }
    return null;
}

test "lineSliceFor returns correct line" {
    const content = "line1\nline2\nline3";
    try std.testing.expectEqualStrings("line1", lineSliceFor(content, 1).?);
    try std.testing.expectEqualStrings("line2", lineSliceFor(content, 2).?);
    try std.testing.expectEqualStrings("line3", lineSliceFor(content, 3).?);
    try std.testing.expect(lineSliceFor(content, 4) == null);
    try std.testing.expect(lineSliceFor(content, 0) == null);
}

test "lineSliceFor strips CR from CRLF" {
    const content = "line1\r\nline2\r\n";
    try std.testing.expectEqualStrings("line1", lineSliceFor(content, 1).?);
    try std.testing.expectEqualStrings("line2", lineSliceFor(content, 2).?);
}

test "freeSentinelContent frees the sentinel byte" {
    const content = try std.testing.allocator.allocSentinel(u8, 3, 0);
    freeSentinelContent(std.testing.allocator, content);
}
