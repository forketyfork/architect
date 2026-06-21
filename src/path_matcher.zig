const std = @import("std");

/// A filesystem-path token detected in a line of terminal text. `path` is a
/// slice into the input `text` with any trailing `:line[:col]` reference and
/// trailing sentence dots already excluded. Resolving it against a working
/// directory and checking that it exists on disk is the caller's job.
pub const PathMatch = struct {
    path: []const u8,
    start: usize,
    end: usize,
};

/// Characters that can appear in a path token. Note `:` is intentionally NOT
/// included, so a "foo.zig:42" line reference naturally splits at the colon and
/// the matched token is just the path.
fn isPathChar(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '/', '.', '_', '-', '~' => true,
        else => false,
    };
}

/// Heuristic: a token is "path-like" if it is absolute (`/…`), home-relative
/// (`~…`), contains a directory separator, or has a dotted name (`foo.zig`).
/// Plain words like "hello" are rejected so we don't try to stat every word.
/// The caller's existence check is the real filter; this just avoids needless
/// filesystem lookups.
fn looksLikePath(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.eql(u8, token, ".") or std.mem.eql(u8, token, "..")) return false;
    if (token[0] == '/' or token[0] == '~') return true;
    var has_slash = false;
    var has_dot = false;
    for (token) |ch| {
        if (ch == '/') has_slash = true;
        if (ch == '.') has_dot = true;
    }
    return has_slash or has_dot;
}

/// Find a path-like token at byte position `col` in `text`. Returns null if the
/// character under the cursor isn't part of a path-like token.
pub fn findPathMatchAtPosition(text: []const u8, col: usize) ?PathMatch {
    if (text.len == 0 or col >= text.len) return null;
    if (!isPathChar(text[col])) return null;

    var start = col;
    while (start > 0 and isPathChar(text[start - 1])) start -= 1;
    var end = col + 1;
    while (end < text.len and isPathChar(text[end])) end += 1;

    // Trim trailing sentence dots ("see foo.zig." -> "foo.zig"), keeping at
    // least one character.
    while (end - start > 1 and text[end - 1] == '.') end -= 1;

    const token = text[start..end];
    if (!looksLikePath(token)) return null;

    return PathMatch{ .path = token, .start = start, .end = end };
}

test "findPathMatchAtPosition - absolute path" {
    const t = "edited /Users/roba/dev/x.zig now";
    const m = findPathMatchAtPosition(t, 12) orelse return error.TestExpectedMatch;
    try std.testing.expectEqualStrings("/Users/roba/dev/x.zig", m.path);
    try std.testing.expectEqual(@as(usize, 7), m.start);
}

test "findPathMatchAtPosition - relative with line suffix" {
    const t = "see src/config.zig:42 here";
    const m = findPathMatchAtPosition(t, 6) orelse return error.TestExpectedMatch;
    try std.testing.expectEqualStrings("src/config.zig", m.path);
}

test "findPathMatchAtPosition - trailing dot trimmed" {
    const t = "open foo.zig.";
    const m = findPathMatchAtPosition(t, 7) orelse return error.TestExpectedMatch;
    try std.testing.expectEqualStrings("foo.zig", m.path);
}

test "findPathMatchAtPosition - tilde home path" {
    const t = "~/.config/architect/config.toml";
    const m = findPathMatchAtPosition(t, 5) orelse return error.TestExpectedMatch;
    try std.testing.expectEqualStrings("~/.config/architect/config.toml", m.path);
}

test "findPathMatchAtPosition - plain words are not paths" {
    try std.testing.expect(findPathMatchAtPosition("hello world", 1) == null);
    try std.testing.expect(findPathMatchAtPosition("just text here", 6) == null);
}

test "findPathMatchAtPosition - bare dot and dotdot rejected" {
    try std.testing.expect(findPathMatchAtPosition("cd .. now", 3) == null);
    try std.testing.expect(findPathMatchAtPosition("a . b", 2) == null);
}

test "findPathMatchAtPosition - click off a path char returns null" {
    try std.testing.expect(findPathMatchAtPosition("a/b c", 3) == null); // space
}
