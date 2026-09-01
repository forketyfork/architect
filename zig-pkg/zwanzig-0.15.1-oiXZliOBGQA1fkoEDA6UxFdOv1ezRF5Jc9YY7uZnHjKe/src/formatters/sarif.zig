const std = @import("std");
const CheckerManagerWithRules = @import("../checker.zig").CheckerManagerWithRules;
const diagnostic_mod = @import("../diagnostic.zig");
const Diagnostic = diagnostic_mod.Diagnostic;
const Location = diagnostic_mod.Location;
const SourceRange = diagnostic_mod.SourceRange;

pub const SarifFormatter = struct {
    allocator: std.mem.Allocator,
    checker_manager: *const CheckerManagerWithRules,
    tool_version: []const u8,
    diagnostics: []const Diagnostic,

    pub fn init(
        allocator: std.mem.Allocator,
        checker_manager: *const CheckerManagerWithRules,
        tool_version: []const u8,
        diagnostics: []const Diagnostic,
    ) SarifFormatter {
        return .{
            .allocator = allocator,
            .checker_manager = checker_manager,
            .tool_version = tool_version,
            .diagnostics = diagnostics,
        };
    }

    pub fn write(self: *SarifFormatter, output_writer: anytype) !void {
        var alloc_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer alloc_writer.deinit();

        var jw: std.json.Stringify = .{
            .writer = &alloc_writer.writer,
            .options = .{ .whitespace = .indent_2 },
        };

        try jw.beginObject();

        try jw.objectField("version");
        try jw.write("2.1.0");

        try jw.objectField("$schema");
        try jw.write("https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json");

        try jw.objectField("runs");
        try jw.beginArray();
        try jw.beginObject();

        // Tool section
        try jw.objectField("tool");
        try jw.beginObject();
        try jw.objectField("driver");
        try jw.beginObject();

        try jw.objectField("name");
        try jw.write("Zwanzig");

        try jw.objectField("informationUri");
        try jw.write("https://github.com/forketyfork/zwanzig");

        try jw.objectField("version");
        try jw.write(self.tool_version);

        // Rules array
        try jw.objectField("rules");
        try jw.beginArray();

        for (self.checker_manager.checkers.items) |checker| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(checker.name);
            try jw.objectField("shortDescription");
            try jw.beginObject();
            try jw.objectField("text");
            try jw.write(checker.name);
            try jw.endObject();
            try jw.objectField("defaultConfiguration");
            try jw.beginObject();
            try jw.objectField("level");
            try jw.write(checker.default_severity.toSarifLevel());
            try jw.endObject();
            try jw.endObject();
        }

        for (self.checker_manager.adapted_rules.items) |rule| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(rule.name);
            try jw.objectField("shortDescription");
            try jw.beginObject();
            try jw.objectField("text");
            try jw.write(rule.name);
            try jw.endObject();
            try jw.endObject();
        }

        try jw.endArray(); // rules
        try jw.endObject(); // driver
        try jw.endObject(); // tool

        // Results array
        try jw.objectField("results");
        try jw.beginArray();

        for (self.diagnostics) |diag| {
            try diag.writeSarifJson(&jw);
        }

        try jw.endArray(); // results
        try jw.endObject(); // run
        try jw.endArray(); // runs
        try jw.endObject(); // root

        try output_writer.writeAll(alloc_writer.written());
        try output_writer.writeByte('\n');
    }
};

test "SarifFormatter produces valid JSON" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    var diag = try Diagnostic.init(
        allocator,
        "test.zig",
        "test-rule",
        .err,
        "Test message",
        SourceRange.init(Location.init(1, 1), Location.init(1, 10)),
    );
    defer diag.deinit(allocator);

    const diagnostics = [_]Diagnostic{diag};

    var formatter = SarifFormatter.init(allocator, &manager, "1.0.0", &diagnostics);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try formatter.write(&output.writer);

    const result = output.written();
    try testing.expect(std.mem.indexOf(u8, result, "\"version\": \"2.1.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\": \"Zwanzig\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"results\":") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"ruleId\": \"test-rule\"") != null);
}

test "SarifFormatter escapes special characters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    var diag = try Diagnostic.init(
        allocator,
        "test.zig",
        "test-rule",
        .warning,
        "Message with \"quotes\" and\nnewline",
        SourceRange.init(Location.init(1, 1), Location.init(1, 1)),
    );
    defer diag.deinit(allocator);

    const diagnostics = [_]Diagnostic{diag};

    var formatter = SarifFormatter.init(allocator, &manager, "1.0.0", &diagnostics);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try formatter.write(&output.writer);

    const result = output.written();
    // Check that quotes and newlines are properly escaped
    try testing.expect(std.mem.indexOf(u8, result, "\\\"quotes\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
}
