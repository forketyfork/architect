const std = @import("std");

const SuppressionError = error{
    OutOfMemory,
};

const LineRange = struct {
    start: usize,
    end: ?usize,
};

pub const SuppressionMap = struct {
    allocator: std.mem.Allocator,
    all_rules_suppressed_lines: std.AutoHashMap(usize, void),
    rule_specific_lines: std.StringHashMap(std.AutoHashMap(usize, void)),
    file_scope_ranges: std.StringHashMap(std.ArrayList(LineRange)),
    all_rules_file_scope_ranges: std.ArrayList(LineRange),

    pub fn init(allocator: std.mem.Allocator) SuppressionMap {
        return .{
            .allocator = allocator,
            .all_rules_suppressed_lines = std.AutoHashMap(usize, void).init(allocator),
            .rule_specific_lines = std.StringHashMap(std.AutoHashMap(usize, void)).init(allocator),
            .file_scope_ranges = std.StringHashMap(std.ArrayList(LineRange)).init(allocator),
            .all_rules_file_scope_ranges = .empty,
        };
    }

    pub fn deinit(self: *SuppressionMap) void {
        self.all_rules_suppressed_lines.deinit();
        var line_iter = self.rule_specific_lines.valueIterator();
        while (line_iter.next()) |line_set| {
            line_set.deinit();
        }
        self.rule_specific_lines.deinit();
        var range_iter = self.file_scope_ranges.valueIterator();
        while (range_iter.next()) |ranges| {
            ranges.deinit(self.allocator);
        }
        self.file_scope_ranges.deinit();
        self.all_rules_file_scope_ranges.deinit(self.allocator);
    }

    pub fn isSuppressed(self: *const SuppressionMap, line: usize, rule_id: []const u8) bool {
        if (self.all_rules_suppressed_lines.contains(line)) {
            return true;
        }

        if (self.rule_specific_lines.get(rule_id)) |lines_set| {
            if (lines_set.contains(line)) {
                return true;
            }
        }

        for (self.all_rules_file_scope_ranges.items) |range| {
            if (isLineInRange(line, range)) {
                return true;
            }
        }

        if (self.file_scope_ranges.get(rule_id)) |ranges| {
            for (ranges.items) |range| {
                if (isLineInRange(line, range)) {
                    return true;
                }
            }
        }

        return false;
    }

    fn isLineInRange(line: usize, range: LineRange) bool {
        if (line < range.start) return false;
        if (range.end) |end| {
            return line < end;
        }
        return true;
    }
};

const DirectiveKind = enum {
    next_line,
    file_scope,
    enable,
};

const DirectiveInfo = struct {
    prefix: []const u8,
    kind: DirectiveKind,
};

const directives = [_]DirectiveInfo{
    .{ .prefix = "zwanzig-disable-next-line", .kind = .next_line },
    .{ .prefix = "zwanzig-disable", .kind = .file_scope },
    .{ .prefix = "zwanzig-enable", .kind = .enable },
};

const ActiveSuppressions = struct {
    all_rules_start: ?usize,
    rule_starts: std.StringHashMap(usize),

    fn init(allocator: std.mem.Allocator) ActiveSuppressions {
        return .{
            .all_rules_start = null,
            .rule_starts = std.StringHashMap(usize).init(allocator),
        };
    }

    fn deinit(self: *ActiveSuppressions) void {
        self.rule_starts.deinit();
    }
};

pub fn parseSuppressions(
    allocator: std.mem.Allocator,
    content: []const u8,
) SuppressionError!SuppressionMap {
    var map = SuppressionMap.init(allocator);
    errdefer map.deinit();

    var active = ActiveSuppressions.init(allocator);
    defer active.deinit();

    var line_number: usize = 1;
    var i: usize = 0;

    while (i < content.len) {
        if (content[i] == '\n') {
            line_number += 1;
            i += 1;
            continue;
        }

        if (i + 1 < content.len and content[i] == '/' and content[i + 1] == '/') {
            i += 2;

            while (i < content.len and (content[i] == ' ' or content[i] == '\t')) {
                i += 1;
            }

            if (try tryParseDirective(content, i, line_number, &map, &active)) |new_i| {
                i = new_i;
                continue;
            }
        }

        i += 1;
    }

    if (active.all_rules_start) |start| {
        try map.all_rules_file_scope_ranges.append(allocator, .{ .start = start, .end = null });
    }
    var iter = active.rule_starts.iterator();
    while (iter.next()) |entry| {
        const ranges_entry = try map.file_scope_ranges.getOrPut(entry.key_ptr.*);
        if (!ranges_entry.found_existing) {
            ranges_entry.value_ptr.* = .empty;
        }
        try ranges_entry.value_ptr.append(allocator, .{ .start = entry.value_ptr.*, .end = null });
    }

    return map;
}

fn tryParseDirective(
    content: []const u8,
    start: usize,
    directive_line: usize,
    map: *SuppressionMap,
    active: *ActiveSuppressions,
) SuppressionError!?usize {
    for (directives) |directive_info| {
        const prefix = directive_info.prefix;
        const kind = directive_info.kind;

        if (start + prefix.len <= content.len and
            std.mem.eql(u8, content[start .. start + prefix.len], prefix))
        {
            var pos = start + prefix.len;

            var end_of_line = pos;
            while (end_of_line < content.len and content[end_of_line] != '\n') {
                end_of_line += 1;
            }

            if (pos < end_of_line and content[pos] == ':') {
                pos += 1;
                try applyDirectiveWithRules(map, active, kind, directive_line, content[pos..end_of_line]);
            } else {
                try applyDirectiveAllRules(map, active, kind, directive_line);
            }

            return end_of_line;
        }
    }

    return null;
}

fn applyDirectiveAllRules(
    map: *SuppressionMap,
    active: *ActiveSuppressions,
    kind: DirectiveKind,
    directive_line: usize,
) SuppressionError!void {
    const target_line = directive_line + 1;

    switch (kind) {
        .next_line => {
            try map.all_rules_suppressed_lines.put(target_line, {});
        },
        .file_scope => {
            if (active.all_rules_start == null) {
                active.all_rules_start = directive_line;
            }
        },
        .enable => {
            if (active.all_rules_start) |start| {
                try map.all_rules_file_scope_ranges.append(map.allocator, .{ .start = start, .end = directive_line });
                active.all_rules_start = null;
            }
            var iter = active.rule_starts.iterator();
            while (iter.next()) |entry| {
                const ranges_entry = try map.file_scope_ranges.getOrPut(entry.key_ptr.*);
                if (!ranges_entry.found_existing) {
                    ranges_entry.value_ptr.* = .empty;
                }
                try ranges_entry.value_ptr.append(map.allocator, .{ .start = entry.value_ptr.*, .end = directive_line });
            }
            active.rule_starts.clearRetainingCapacity();
        },
    }
}

fn applyDirectiveWithRules(
    map: *SuppressionMap,
    active: *ActiveSuppressions,
    kind: DirectiveKind,
    directive_line: usize,
    rule_list_text: []const u8,
) SuppressionError!void {
    const target_line = directive_line + 1;

    var iter = std.mem.splitSequence(u8, rule_list_text, ",");
    while (iter.next()) |part| {
        const rule_id = std.mem.trim(u8, part, " \t");
        if (rule_id.len == 0) continue;

        switch (kind) {
            .next_line => {
                const entry = try map.rule_specific_lines.getOrPut(rule_id);
                if (!entry.found_existing) {
                    entry.value_ptr.* = std.AutoHashMap(usize, void).init(map.allocator);
                }
                try entry.value_ptr.put(target_line, {});
            },
            .file_scope => {
                if (!active.rule_starts.contains(rule_id)) {
                    try active.rule_starts.put(rule_id, directive_line);
                }
            },
            .enable => {
                if (active.rule_starts.fetchRemove(rule_id)) |kv| {
                    const ranges_entry = try map.file_scope_ranges.getOrPut(rule_id);
                    if (!ranges_entry.found_existing) {
                        ranges_entry.value_ptr.* = .empty;
                    }
                    try ranges_entry.value_ptr.append(map.allocator, .{ .start = kv.value, .end = directive_line });
                }
            },
        }
    }
}

test "parseSuppressions: next-line all rules" {
    const allocator = std.testing.allocator;
    const content =
        \\const x = 1;
        \\// zwanzig-disable-next-line
        \\const y = 2;
        \\const z = 3;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(!map.isSuppressed(1, "any-rule"));
    try std.testing.expect(!map.isSuppressed(2, "any-rule"));
    try std.testing.expect(map.isSuppressed(3, "any-rule"));
    try std.testing.expect(map.isSuppressed(3, "other-rule"));
    try std.testing.expect(!map.isSuppressed(4, "any-rule"));
}

test "parseSuppressions: next-line specific rules" {
    const allocator = std.testing.allocator;
    const content =
        \\// zwanzig-disable-next-line: empty-catch, todo
        \\const x = 1;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(map.isSuppressed(2, "empty-catch"));
    try std.testing.expect(map.isSuppressed(2, "todo"));
    try std.testing.expect(!map.isSuppressed(2, "unused-decl"));
}

test "parseSuppressions: file scope suppression" {
    const allocator = std.testing.allocator;
    const content =
        \\const x = 1;
        \\// zwanzig-disable: todo
        \\const y = 2;
        \\const z = 3;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(!map.isSuppressed(1, "todo"));
    try std.testing.expect(map.isSuppressed(2, "todo"));
    try std.testing.expect(map.isSuppressed(3, "todo"));
    try std.testing.expect(map.isSuppressed(4, "todo"));
    try std.testing.expect(!map.isSuppressed(1, "other-rule"));
    try std.testing.expect(!map.isSuppressed(4, "other-rule"));
}

test "parseSuppressions: file scope with re-enable" {
    const allocator = std.testing.allocator;
    const content =
        \\// zwanzig-disable: todo
        \\const x = 1;
        \\// zwanzig-enable: todo
        \\const y = 2;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(map.isSuppressed(1, "todo"));
    try std.testing.expect(map.isSuppressed(2, "todo"));
    try std.testing.expect(!map.isSuppressed(3, "todo"));
    try std.testing.expect(!map.isSuppressed(4, "todo"));
}

test "parseSuppressions: all rules file scope" {
    const allocator = std.testing.allocator;
    const content =
        \\const x = 1;
        \\// zwanzig-disable
        \\const y = 2;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(!map.isSuppressed(1, "any-rule"));
    try std.testing.expect(map.isSuppressed(2, "any-rule"));
    try std.testing.expect(map.isSuppressed(3, "any-rule"));
}

test "parseSuppressions: whitespace handling" {
    const allocator = std.testing.allocator;
    const content =
        \\//   zwanzig-disable-next-line:  empty-catch  ,  todo
        \\const x = 1;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(map.isSuppressed(2, "empty-catch"));
    try std.testing.expect(map.isSuppressed(2, "todo"));
}

test "parseSuppressions: empty content" {
    const allocator = std.testing.allocator;
    const content = "";

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(!map.isSuppressed(1, "any-rule"));
}

test "parseSuppressions: no directives" {
    const allocator = std.testing.allocator;
    const content =
        \\// This is a regular comment
        \\const x = 1;
        \\// Another comment
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(!map.isSuppressed(1, "any-rule"));
    try std.testing.expect(!map.isSuppressed(2, "any-rule"));
    try std.testing.expect(!map.isSuppressed(3, "any-rule"));
}

test "parseSuppressions: all rules re-enable" {
    const allocator = std.testing.allocator;
    const content =
        \\// zwanzig-disable
        \\const x = 1;
        \\// zwanzig-enable
        \\const y = 2;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(map.isSuppressed(1, "any-rule"));
    try std.testing.expect(map.isSuppressed(2, "any-rule"));
    try std.testing.expect(!map.isSuppressed(3, "any-rule"));
    try std.testing.expect(!map.isSuppressed(4, "any-rule"));
}

test "parseSuppressions: repeated disable preserves first start" {
    const allocator = std.testing.allocator;
    const content =
        \\// zwanzig-disable
        \\const x = 1;
        \\// zwanzig-disable
        \\const y = 2;
        \\// zwanzig-enable
        \\const z = 3;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(map.isSuppressed(1, "any-rule"));
    try std.testing.expect(map.isSuppressed(2, "any-rule"));
    try std.testing.expect(map.isSuppressed(3, "any-rule"));
    try std.testing.expect(map.isSuppressed(4, "any-rule"));
    try std.testing.expect(!map.isSuppressed(5, "any-rule"));
    try std.testing.expect(!map.isSuppressed(6, "any-rule"));
}

test "parseSuppressions: repeated rule-specific disable preserves first start" {
    const allocator = std.testing.allocator;
    const content =
        \\// zwanzig-disable: todo
        \\const x = 1;
        \\// zwanzig-disable: todo
        \\const y = 2;
        \\// zwanzig-enable: todo
        \\const z = 3;
    ;

    var map = try parseSuppressions(allocator, content);
    defer map.deinit();

    try std.testing.expect(map.isSuppressed(1, "todo"));
    try std.testing.expect(map.isSuppressed(2, "todo"));
    try std.testing.expect(map.isSuppressed(3, "todo"));
    try std.testing.expect(map.isSuppressed(4, "todo"));
    try std.testing.expect(!map.isSuppressed(5, "todo"));
    try std.testing.expect(!map.isSuppressed(6, "todo"));
}
