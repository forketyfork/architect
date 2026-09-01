const std = @import("std");
const Rule = @import("../rule.zig").Rule;
const RuleError = @import("../rule.zig").RuleError;
const Diagnostic = @import("../rule.zig").Diagnostic;
const Source = @import("../source.zig").Source;
const log = std.log.scoped(.dupe_import);

/// Rule that detects duplicate @import statements in Zig code.
/// Duplicate imports can indicate copy-paste errors or redundant code.
/// This rule scans tokens to find @import("...") patterns and reports
/// when the same module is imported multiple times.
pub const DupeImportRule = struct {
    pub const rule: Rule = Rule{
        .name = "dupe-import",
        .default_severity = .warning,
        .checkFn = check,
    };

    const ImportInfo = struct {
        byte_offset: usize,
        import_path: []const u8,
    };

    fn check(
        src: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        const tree = try src.ast();
        const token_tags = tree.tokens.items(.tag);
        const token_starts = tree.tokens.items(.start);
        const content = src.getContent();

        var seen_imports = std.StringHashMap(ImportInfo).init(allocator);
        defer seen_imports.deinit();

        // Track allocated keys for cleanup
        var allocated_keys: std.ArrayList([]const u8) = .empty;
        defer {
            for (allocated_keys.items) |key| {
                allocator.free(key);
            }
            allocated_keys.deinit(allocator);
        }

        var i: usize = 0;
        while (i < token_tags.len) : (i += 1) {
            if (token_tags[i] == .builtin) {
                const start = token_starts[i];
                const builtin_name = tree.tokenSlice(@intCast(i));

                if (std.mem.eql(u8, builtin_name, "@import")) {
                    if (isDiscardImport(token_tags, tree, i)) continue;

                    const l_paren_idx = nextNonCommentToken(token_tags, i + 1) orelse continue;
                    if (token_tags[l_paren_idx] != .l_paren) continue;

                    const string_idx = nextNonCommentToken(token_tags, l_paren_idx + 1) orelse continue;
                    if (token_tags[string_idx] != .string_literal) continue;

                    const r_paren_idx = nextNonCommentToken(token_tags, string_idx + 1) orelse continue;
                    if (token_tags[r_paren_idx] != .r_paren) continue;

                    const string_start = token_starts[string_idx];
                    const import_path = getStringLiteralContent(content, string_start);

                    // Build full import key including field access chain
                    const full_key = buildImportKey(allocator, tree, token_tags, r_paren_idx, import_path) catch |err| {
                        log.debug("failed to build import key for '{s}': {}", .{ import_path, err });
                        continue;
                    };
                    const key_is_allocated = full_key.ptr != import_path.ptr;

                    if (seen_imports.get(full_key)) |_| {
                        // It's a duplicate - free the key if allocated and report
                        if (key_is_allocated) {
                            allocator.free(full_key);
                        }

                        const range = try src.byteRangeToSourceRange(start, start + builtin_name.len);

                        const diag = try Diagnostic.init(
                            allocator,
                            src.getFilePath(),
                            "dupe-import",
                            .warning,
                            "Duplicate import detected. This module has already been imported earlier in the file.",
                            range,
                        );
                        try diagnostics.append(allocator, diag);
                    } else {
                        // New import - store it
                        if (key_is_allocated) {
                            try allocated_keys.append(allocator, full_key);
                        }
                        try seen_imports.put(full_key, .{
                            .byte_offset = start,
                            .import_path = import_path,
                        });
                    }

                    i = string_idx;
                }
            }
        }
    }

    fn buildImportKey(
        allocator: std.mem.Allocator,
        tree: *const std.zig.Ast,
        token_tags: []const std.zig.Token.Tag,
        r_paren_idx: usize,
        import_path: []const u8,
    ) ![]const u8 {
        // Look for field access chain after the closing paren: .field1.field2...
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(allocator);

        var idx = nextNonCommentToken(token_tags, r_paren_idx + 1);
        while (idx) |current_idx| {
            if (token_tags[current_idx] != .period) break;

            const ident_idx = nextNonCommentToken(token_tags, current_idx + 1) orelse break;
            if (token_tags[ident_idx] != .identifier) break;

            const field_name = normalizeIdentifier(tree.tokenSlice(@intCast(ident_idx)));
            try fields.append(allocator, field_name);

            idx = nextNonCommentToken(token_tags, ident_idx + 1);
        }

        // If no fields, return the import path as-is (no allocation)
        if (fields.items.len == 0) {
            return import_path;
        }

        // Build the full key: "path.field1.field2..."
        var total_len: usize = import_path.len;
        for (fields.items) |field| {
            total_len += 1 + field.len; // "." + field
        }

        const key = try allocator.alloc(u8, total_len);
        @memcpy(key[0..import_path.len], import_path);

        var pos: usize = import_path.len;
        for (fields.items) |field| {
            key[pos] = '.';
            pos += 1;
            @memcpy(key[pos..][0..field.len], field);
            pos += field.len;
        }

        return key;
    }

    /// Normalize an identifier by stripping the @"..." wrapper if present.
    /// In Zig, @"foo" and foo refer to the same identifier.
    fn normalizeIdentifier(ident: []const u8) []const u8 {
        if (ident.len >= 3 and std.mem.startsWith(u8, ident, "@\"") and ident[ident.len - 1] == '"') {
            return ident[2 .. ident.len - 1];
        }
        return ident;
    }

    fn nextNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
        var idx = start;
        while (idx < token_tags.len) {
            const tag = token_tags[idx];
            if (tag != .container_doc_comment and tag != .doc_comment) {
                return idx;
            }
            idx += 1;
        }
        return null;
    }

    fn prevNonCommentToken(token_tags: []const std.zig.Token.Tag, start: usize) ?usize {
        if (start == 0) return null;
        var idx = start - 1;
        while (true) {
            const tag = token_tags[idx];
            if (tag != .container_doc_comment and tag != .doc_comment) {
                return idx;
            }
            if (idx == 0) return null;
            idx -= 1;
        }
    }

    fn isDiscardImport(token_tags: []const std.zig.Token.Tag, tree: *const std.zig.Ast, import_idx: usize) bool {
        const equal_idx = prevNonCommentToken(token_tags, import_idx) orelse return false;
        if (token_tags[equal_idx] != .equal) return false;

        const ident_idx = prevNonCommentToken(token_tags, equal_idx) orelse return false;
        if (token_tags[ident_idx] != .identifier) return false;

        const ident = tree.tokenSlice(@intCast(ident_idx));
        return std.mem.eql(u8, ident, "_");
    }

    fn getStringLiteralContent(content: []const u8, start: usize) []const u8 {
        if (start >= content.len or content[start] != '"') return "";

        const content_start = start + 1;
        var end = content_start;
        while (end < content.len and content[end] != '"') {
            if (content[end] == '\\' and end + 1 < content.len) {
                end += 2;
            } else {
                end += 1;
            }
        }

        return content[content_start..end];
    }
};
