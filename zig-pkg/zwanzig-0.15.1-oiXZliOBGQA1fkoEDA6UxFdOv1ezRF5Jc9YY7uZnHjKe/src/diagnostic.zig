const std = @import("std");

/// Severity levels for diagnostics
pub const Severity = enum {
    /// Informational hint, does not indicate a problem
    hint,
    /// Warning that may indicate a potential issue
    warning,
    /// Error that indicates a definite problem
    err,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .hint => "hint",
            .warning => "warning",
            .err => "error",
        };
    }

    pub fn toSarifLevel(self: Severity) []const u8 {
        return switch (self) {
            .hint => "note",
            .warning => "warning",
            .err => "error",
        };
    }
};

/// A location in source code (line and column are 1-based)
pub const Location = struct {
    line: usize,
    column: usize,

    pub fn init(line: usize, column: usize) Location {
        return .{ .line = line, .column = column };
    }
};

/// A range in source code defined by start and end locations
pub const SourceRange = struct {
    start: Location,
    end: Location,

    pub fn init(start: Location, end: Location) SourceRange {
        return .{ .start = start, .end = end };
    }

    pub fn fromSingleLocation(loc: Location) SourceRange {
        return .{ .start = loc, .end = loc };
    }
};

/// A structured diagnostic representing an issue found during analysis
pub const Diagnostic = struct {
    file_path: []const u8,
    rule_id: []const u8,
    severity: Severity,
    message: []const u8,
    range: SourceRange,
    related_range: ?SourceRange = null,

    pub fn init(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        rule_id: []const u8,
        severity: Severity,
        message: []const u8,
        range: SourceRange,
    ) !Diagnostic {
        const owned_message = try allocator.dupe(u8, message);
        return .{
            .file_path = file_path,
            .rule_id = rule_id,
            .severity = severity,
            .message = owned_message,
            .range = range,
            .related_range = null,
        };
    }

    pub fn initWithRelated(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        rule_id: []const u8,
        severity: Severity,
        message: []const u8,
        range: SourceRange,
        related_range: ?SourceRange,
    ) !Diagnostic {
        const owned_message = try allocator.dupe(u8, message);
        return .{
            .file_path = file_path,
            .rule_id = rule_id,
            .severity = severity,
            .message = owned_message,
            .range = range,
            .related_range = related_range,
        };
    }

    pub fn initAtLocation(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        rule_id: []const u8,
        severity: Severity,
        message: []const u8,
        line: usize,
        column: usize,
    ) !Diagnostic {
        const loc = Location.init(line, column);
        return init(allocator, file_path, rule_id, severity, message, SourceRange.fromSingleLocation(loc));
    }

    pub fn initAtLocationWithRelated(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        rule_id: []const u8,
        severity: Severity,
        message: []const u8,
        line: usize,
        column: usize,
        related_range: ?SourceRange,
    ) !Diagnostic {
        const loc = Location.init(line, column);
        return initWithRelated(allocator, file_path, rule_id, severity, message, SourceRange.fromSingleLocation(loc), related_range);
    }

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }

    /// Create a copy of this diagnostic with message owned by a new allocator.
    /// This is useful for transferring diagnostics between allocators (e.g., from
    /// an arena allocator to a persistent allocator).
    pub fn clone(self: Diagnostic, allocator: std.mem.Allocator) !Diagnostic {
        return .{
            .file_path = self.file_path,
            .rule_id = self.rule_id,
            .severity = self.severity,
            .message = try allocator.dupe(u8, self.message),
            .range = self.range,
            .related_range = self.related_range,
        };
    }

    pub fn format(self: Diagnostic, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}: {s}: [{s}] {s}\n", .{
            self.file_path,
            self.range.start.line,
            self.range.start.column,
            self.severity.toString(),
            self.rule_id,
            self.message,
        });
        if (self.related_range) |related| {
            try writer.print("  related: {d}:{d}\n", .{ related.start.line, related.start.column });
        }
    }

    pub fn writeJsonValue(self: Diagnostic, jw: *std.json.Stringify) !void {
        try jw.beginObject();

        try jw.objectField("file");
        try jw.write(self.file_path);

        try jw.objectField("rule");
        try jw.write(self.rule_id);

        try jw.objectField("severity");
        try jw.write(self.severity.toString());

        try jw.objectField("message");
        try jw.write(self.message);

        try jw.objectField("location");
        try jw.beginObject();
        try jw.objectField("start");
        try jw.beginObject();
        try jw.objectField("line");
        try jw.write(self.range.start.line);
        try jw.objectField("column");
        try jw.write(self.range.start.column);
        try jw.endObject();
        try jw.objectField("end");
        try jw.beginObject();
        try jw.objectField("line");
        try jw.write(self.range.end.line);
        try jw.objectField("column");
        try jw.write(self.range.end.column);
        try jw.endObject();
        try jw.endObject();

        if (self.related_range) |related| {
            try jw.objectField("related");
            try jw.beginObject();
            try jw.objectField("start");
            try jw.beginObject();
            try jw.objectField("line");
            try jw.write(related.start.line);
            try jw.objectField("column");
            try jw.write(related.start.column);
            try jw.endObject();
            try jw.objectField("end");
            try jw.beginObject();
            try jw.objectField("line");
            try jw.write(related.end.line);
            try jw.objectField("column");
            try jw.write(related.end.column);
            try jw.endObject();
            try jw.endObject();
        }

        try jw.endObject();
    }

    /// Write SARIF result using std.json.Stringify for proper JSON encoding.
    /// Comparator for deterministic diagnostic ordering.
    /// Order: file_path, start line, start column, rule_id, message.
    pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        // First compare by file path
        const file_cmp = stringLessThan(a.file_path, b.file_path);
        if (file_cmp != .eq) return file_cmp == .lt;

        // Then by start line
        if (a.range.start.line != b.range.start.line) {
            return a.range.start.line < b.range.start.line;
        }

        // Then by start column
        if (a.range.start.column != b.range.start.column) {
            return a.range.start.column < b.range.start.column;
        }

        // Then by rule id
        const rule_cmp = stringLessThan(a.rule_id, b.rule_id);
        if (rule_cmp != .eq) return rule_cmp == .lt;

        // Finally by message
        return stringLessThan(a.message, b.message) == .lt;
    }

    const CompareResult = enum { lt, eq, gt };

    fn stringLessThan(a: []const u8, b: []const u8) CompareResult {
        const min_len = @min(a.len, b.len);
        for (0..min_len) |i| {
            if (a[i] < b[i]) return .lt;
            if (a[i] > b[i]) return .gt;
        }
        if (a.len < b.len) return .lt;
        if (a.len > b.len) return .gt;
        return .eq;
    }

    pub fn writeSarifJson(self: Diagnostic, jw: *std.json.Stringify) !void {
        try jw.beginObject();

        try jw.objectField("ruleId");
        try jw.write(self.rule_id);

        try jw.objectField("level");
        try jw.write(self.severity.toSarifLevel());

        try jw.objectField("message");
        try jw.beginObject();
        try jw.objectField("text");
        try jw.write(self.message);
        try jw.endObject();

        try jw.objectField("locations");
        try jw.beginArray();
        try jw.beginObject();

        try jw.objectField("physicalLocation");
        try jw.beginObject();

        try jw.objectField("artifactLocation");
        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(self.file_path);
        try jw.endObject();

        try jw.objectField("region");
        try jw.beginObject();
        try jw.objectField("startLine");
        try jw.write(self.range.start.line);
        try jw.objectField("startColumn");
        try jw.write(self.range.start.column);
        try jw.objectField("endLine");
        try jw.write(self.range.end.line);
        try jw.objectField("endColumn");
        try jw.write(self.range.end.column);
        try jw.endObject(); // region

        try jw.endObject(); // physicalLocation
        try jw.endObject(); // location item
        try jw.endArray(); // locations

        if (self.related_range) |related| {
            try jw.objectField("relatedLocations");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("physicalLocation");
            try jw.beginObject();
            try jw.objectField("artifactLocation");
            try jw.beginObject();
            try jw.objectField("uri");
            try jw.write(self.file_path);
            try jw.endObject();
            try jw.objectField("region");
            try jw.beginObject();
            try jw.objectField("startLine");
            try jw.write(related.start.line);
            try jw.objectField("startColumn");
            try jw.write(related.start.column);
            try jw.objectField("endLine");
            try jw.write(related.end.line);
            try jw.objectField("endColumn");
            try jw.write(related.end.column);
            try jw.endObject(); // region
            try jw.endObject(); // physicalLocation
            try jw.endObject(); // related item
            try jw.endArray(); // relatedLocations
        }

        try jw.endObject(); // result
    }
};

/// Maps byte offsets in source content to line/column locations.
/// Uses 1-based line and column numbers.
pub const LocationMapper = struct {
    content: []const u8,
    line_offsets: []usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !LocationMapper {
        var offsets: std.ArrayList(usize) = .empty;
        errdefer offsets.deinit(allocator);

        try offsets.append(allocator, 0);

        for (content, 0..) |c, i| {
            if (c == '\n') {
                try offsets.append(allocator, i + 1);
            }
        }

        return .{
            .content = content,
            .line_offsets = try offsets.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LocationMapper) void {
        self.allocator.free(self.line_offsets);
    }

    pub fn byteToLocation(self: *const LocationMapper, byte_offset: usize) Location {
        const line = self.byteToLine(byte_offset);
        const line_start = self.line_offsets[line - 1];
        const column = byte_offset - line_start + 1;
        return Location.init(line, column);
    }

    fn byteToLine(self: *const LocationMapper, byte_offset: usize) usize {
        var low: usize = 0;
        var high: usize = self.line_offsets.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.line_offsets[mid] <= byte_offset) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    pub fn byteRangeToSourceRange(
        self: *const LocationMapper,
        start_byte: usize,
        end_byte: usize,
    ) SourceRange {
        return SourceRange.init(
            self.byteToLocation(start_byte),
            self.byteToLocation(end_byte),
        );
    }
};

test "Severity.toString" {
    const testing = std.testing;
    try testing.expectEqualStrings("hint", Severity.hint.toString());
    try testing.expectEqualStrings("warning", Severity.warning.toString());
    try testing.expectEqualStrings("error", Severity.err.toString());
}

test "Location initialization" {
    const loc = Location.init(10, 5);
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 10), loc.line);
    try testing.expectEqual(@as(usize, 5), loc.column);
}

test "SourceRange from single location" {
    const loc = Location.init(3, 7);
    const range = SourceRange.fromSingleLocation(loc);
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 3), range.start.line);
    try testing.expectEqual(@as(usize, 7), range.start.column);
    try testing.expectEqual(@as(usize, 3), range.end.line);
    try testing.expectEqual(@as(usize, 7), range.end.column);
}

test "Diagnostic formatting" {
    const testing = std.testing;

    var diag = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "empty-catch",
        .err,
        "Empty catch block detected",
        SourceRange.init(Location.init(5, 10), Location.init(5, 15)),
    );
    defer diag.deinit(testing.allocator);

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try diag.format(&writer);

    const expected = "test.zig:5:10: error: [empty-catch] Empty catch block detected\n";
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "Diagnostic initAtLocation" {
    const testing = std.testing;

    var diag = try Diagnostic.initAtLocation(
        testing.allocator,
        "foo.zig",
        "test-rule",
        .warning,
        "Test message",
        3,
        12,
    );
    defer diag.deinit(testing.allocator);

    try testing.expectEqualStrings("foo.zig", diag.file_path);
    try testing.expectEqualStrings("test-rule", diag.rule_id);
    try testing.expectEqual(Severity.warning, diag.severity);
    try testing.expectEqual(@as(usize, 3), diag.range.start.line);
    try testing.expectEqual(@as(usize, 12), diag.range.start.column);
}

test "LocationMapper single line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "const x = 42;";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const loc0 = mapper.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc0.line);
    try testing.expectEqual(@as(usize, 1), loc0.column);

    const loc6 = mapper.byteToLocation(6);
    try testing.expectEqual(@as(usize, 1), loc6.line);
    try testing.expectEqual(@as(usize, 7), loc6.column);
}

test "LocationMapper multiple lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "line1\nline2\nline3";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const loc_line1 = mapper.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc_line1.line);
    try testing.expectEqual(@as(usize, 1), loc_line1.column);

    const loc_line2_start = mapper.byteToLocation(6);
    try testing.expectEqual(@as(usize, 2), loc_line2_start.line);
    try testing.expectEqual(@as(usize, 1), loc_line2_start.column);

    const loc_line2_mid = mapper.byteToLocation(8);
    try testing.expectEqual(@as(usize, 2), loc_line2_mid.line);
    try testing.expectEqual(@as(usize, 3), loc_line2_mid.column);

    const loc_line3 = mapper.byteToLocation(12);
    try testing.expectEqual(@as(usize, 3), loc_line3.line);
    try testing.expectEqual(@as(usize, 1), loc_line3.column);
}

test "LocationMapper byteRangeToSourceRange" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "line1\nline2\nline3";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const range = mapper.byteRangeToSourceRange(6, 10);

    try testing.expectEqual(@as(usize, 2), range.start.line);
    try testing.expectEqual(@as(usize, 1), range.start.column);
    try testing.expectEqual(@as(usize, 2), range.end.line);
    try testing.expectEqual(@as(usize, 5), range.end.column);
}

test "LocationMapper empty content" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    try testing.expectEqual(@as(usize, 1), mapper.line_offsets.len);
}

test "LocationMapper handles trailing newline" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content = "line1\n";
    var mapper = try LocationMapper.init(allocator, content);
    defer mapper.deinit();

    const loc_line1 = mapper.byteToLocation(0);
    try testing.expectEqual(@as(usize, 1), loc_line1.line);

    const loc_after_newline = mapper.byteToLocation(6);
    try testing.expectEqual(@as(usize, 2), loc_after_newline.line);
    try testing.expectEqual(@as(usize, 1), loc_after_newline.column);
}

test "Diagnostic writeJson" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag = try Diagnostic.init(
        allocator,
        "test.zig",
        "empty-catch",
        .err,
        "Empty catch block detected",
        SourceRange.init(Location.init(5, 10), Location.init(5, 15)),
    );
    defer diag.deinit(allocator);

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var jw: std.json.Stringify = .{
        .writer = &alloc_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try diag.writeJsonValue(&jw);

    const output = alloc_writer.written();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const file_val = obj.get("file") orelse return error.MissingField;
    try testing.expect(file_val == .string);
    try testing.expectEqualStrings("test.zig", file_val.string);
    const rule_val = obj.get("rule") orelse return error.MissingField;
    try testing.expect(rule_val == .string);
    try testing.expectEqualStrings("empty-catch", rule_val.string);
    const severity_val = obj.get("severity") orelse return error.MissingField;
    try testing.expect(severity_val == .string);
    try testing.expectEqualStrings("error", severity_val.string);
    const message_val = obj.get("message") orelse return error.MissingField;
    try testing.expect(message_val == .string);
    try testing.expectEqualStrings("Empty catch block detected", message_val.string);

    const location_val = obj.get("location") orelse return error.MissingField;
    try testing.expect(location_val == .object);
    const location = location_val.object;
    const start_val = location.get("start") orelse return error.MissingField;
    try testing.expect(start_val == .object);
    const start = start_val.object;
    const end_val = location.get("end") orelse return error.MissingField;
    try testing.expect(end_val == .object);
    const end = end_val.object;

    const start_line = start.get("line") orelse return error.MissingField;
    try testing.expect(start_line == .integer);
    const start_column = start.get("column") orelse return error.MissingField;
    try testing.expect(start_column == .integer);
    const end_line = end.get("line") orelse return error.MissingField;
    try testing.expect(end_line == .integer);
    const end_column = end.get("column") orelse return error.MissingField;
    try testing.expect(end_column == .integer);

    try testing.expectEqual(@as(i64, 5), start_line.integer);
    try testing.expectEqual(@as(i64, 10), start_column.integer);
    try testing.expectEqual(@as(i64, 5), end_line.integer);
    try testing.expectEqual(@as(i64, 15), end_column.integer);
}

test "Diagnostic writeJson with special characters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var diag = try Diagnostic.init(
        allocator,
        "path/with\"quotes.zig",
        "test-rule",
        .warning,
        "Message with\nnewline and \"quotes\" and \\ backslash",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag.deinit(allocator);

    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_writer.deinit();
    var jw: std.json.Stringify = .{
        .writer = &alloc_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try diag.writeJsonValue(&jw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, alloc_writer.written(), .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const file_val = obj.get("file") orelse return error.MissingField;
    try testing.expect(file_val == .string);
    try testing.expectEqualStrings("path/with\"quotes.zig", file_val.string);
    const message_val = obj.get("message") orelse return error.MissingField;
    try testing.expect(message_val == .string);
    try testing.expectEqualStrings("Message with\nnewline and \"quotes\" and \\ backslash", message_val.string);
}

test "Severity.toSarifLevel" {
    const testing = std.testing;
    try testing.expectEqualStrings("note", Severity.hint.toSarifLevel());
    try testing.expectEqualStrings("warning", Severity.warning.toSarifLevel());
    try testing.expectEqualStrings("error", Severity.err.toSarifLevel());
}

test "Diagnostic lessThan by file path" {
    const testing = std.testing;

    var diag_a = try Diagnostic.init(
        testing.allocator,
        "a.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_a.deinit(testing.allocator);

    var diag_b = try Diagnostic.init(
        testing.allocator,
        "b.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_b.deinit(testing.allocator);

    try testing.expect(Diagnostic.lessThan({}, diag_a, diag_b));
    try testing.expect(!Diagnostic.lessThan({}, diag_b, diag_a));
}

test "Diagnostic lessThan by line" {
    const testing = std.testing;

    var diag_a = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_a.deinit(testing.allocator);

    var diag_b = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(2, 1), Location.init(2, 1)),
    );
    defer diag_b.deinit(testing.allocator);

    try testing.expect(Diagnostic.lessThan({}, diag_a, diag_b));
    try testing.expect(!Diagnostic.lessThan({}, diag_b, diag_a));
}

test "Diagnostic lessThan by column" {
    const testing = std.testing;

    var diag_a = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_a.deinit(testing.allocator);

    var diag_b = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 5), Location.init(1, 5)),
    );
    defer diag_b.deinit(testing.allocator);

    try testing.expect(Diagnostic.lessThan({}, diag_a, diag_b));
    try testing.expect(!Diagnostic.lessThan({}, diag_b, diag_a));
}

test "Diagnostic lessThan by rule id" {
    const testing = std.testing;

    var diag_a = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "alpha-rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_a.deinit(testing.allocator);

    var diag_b = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "beta-rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_b.deinit(testing.allocator);

    try testing.expect(Diagnostic.lessThan({}, diag_a, diag_b));
    try testing.expect(!Diagnostic.lessThan({}, diag_b, diag_a));
}

test "Diagnostic lessThan by message" {
    const testing = std.testing;

    var diag_a = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "alpha message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_a.deinit(testing.allocator);

    var diag_b = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "beta message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_b.deinit(testing.allocator);

    try testing.expect(Diagnostic.lessThan({}, diag_a, diag_b));
    try testing.expect(!Diagnostic.lessThan({}, diag_b, diag_a));
}

test "Diagnostic lessThan equal diagnostics" {
    const testing = std.testing;

    var diag_a = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_a.deinit(testing.allocator);

    var diag_b = try Diagnostic.init(
        testing.allocator,
        "test.zig",
        "rule",
        .err,
        "message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag_b.deinit(testing.allocator);

    try testing.expect(!Diagnostic.lessThan({}, diag_a, diag_b));
    try testing.expect(!Diagnostic.lessThan({}, diag_b, diag_a));
}

test "Diagnostic sorting produces deterministic order" {
    const testing = std.testing;

    var diagnostics = [_]Diagnostic{
        try Diagnostic.init(
            testing.allocator,
            "z.zig",
            "rule",
            .err,
            "message",
            SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
        ),
        try Diagnostic.init(
            testing.allocator,
            "a.zig",
            "rule",
            .err,
            "message",
            SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
        ),
        try Diagnostic.init(
            testing.allocator,
            "a.zig",
            "rule",
            .err,
            "message",
            SourceRange.init(Location.init(5, 1), Location.init(5, 1)),
        ),
        try Diagnostic.init(
            testing.allocator,
            "a.zig",
            "rule",
            .err,
            "message",
            SourceRange.init(Location.init(5, 10), Location.init(5, 10)),
        ),
    };
    defer for (&diagnostics) |*d| d.deinit(testing.allocator);

    std.mem.sort(Diagnostic, &diagnostics, {}, Diagnostic.lessThan);

    try testing.expectEqualStrings("a.zig", diagnostics[0].file_path);
    try testing.expectEqual(@as(usize, 1), diagnostics[0].range.start.line);
    try testing.expectEqualStrings("a.zig", diagnostics[1].file_path);
    try testing.expectEqual(@as(usize, 5), diagnostics[1].range.start.line);
    try testing.expectEqual(@as(usize, 1), diagnostics[1].range.start.column);
    try testing.expectEqualStrings("a.zig", diagnostics[2].file_path);
    try testing.expectEqual(@as(usize, 5), diagnostics[2].range.start.line);
    try testing.expectEqual(@as(usize, 10), diagnostics[2].range.start.column);
    try testing.expectEqualStrings("z.zig", diagnostics[3].file_path);
}
