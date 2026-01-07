const std = @import("std");

const url_schemes = [_][]const u8{
    "https://",
    "http://",
    "mailto:",
    "ftp://",
    "file://",
    "ssh://",
    "git://",
    "tel:",
    "magnet:",
    "ipfs://",
    "ipns://",
    "gemini://",
    "gopher://",
    "news:",
};

pub const UrlMatch = struct {
    url: []const u8,
    start: usize,
    end: usize,
};

pub fn findUrlAtPosition(text: []const u8, col: usize) ?[]const u8 {
    if (text.len == 0 or col >= text.len) return null;

    var start_pos: usize = 0;
    var end_pos: usize = text.len;

    for (url_schemes) |scheme| {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_start, scheme)) |scheme_pos| {
            const url_start = scheme_pos;
            var url_end = scheme_pos + scheme.len;

            while (url_end < text.len and isUrlChar(text[url_end])) {
                url_end += 1;
            }

            url_end = trimUrlEnd(text[url_start..url_end]).len + url_start;

            if (col >= url_start and col < url_end) {
                start_pos = url_start;
                end_pos = url_end;
                return text[start_pos..end_pos];
            }

            search_start = scheme_pos + 1;
        }
    }

    return null;
}

pub fn findUrlMatchAtPosition(text: []const u8, col: usize) ?UrlMatch {
    if (text.len == 0 or col >= text.len) return null;

    for (url_schemes) |scheme| {
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_start, scheme)) |scheme_pos| {
            const url_start = scheme_pos;
            var url_end = scheme_pos + scheme.len;

            while (url_end < text.len and isUrlChar(text[url_end])) {
                url_end += 1;
            }

            url_end = trimUrlEnd(text[url_start..url_end]).len + url_start;

            if (col >= url_start and col < url_end) {
                return UrlMatch{
                    .url = text[url_start..url_end],
                    .start = url_start,
                    .end = url_end,
                };
            }

            search_start = scheme_pos + 1;
        }
    }

    return null;
}

fn isUrlChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '-', '.', '_', '~', ':', '/', '?', '#', '[', ']', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '%' => true,
        else => false,
    };
}

fn trimUrlEnd(url: []const u8) []const u8 {
    if (url.len == 0) return url;

    var end = url.len;

    while (end > 0) {
        const last_char = url[end - 1];
        switch (last_char) {
            '.', ',' => {
                end -= 1;
            },
            ')' => {
                if (!hasUnmatchedOpenParen(url[0..end])) {
                    end -= 1;
                } else {
                    break;
                }
            },
            else => break,
        }
    }

    return url[0..end];
}

fn hasUnmatchedOpenParen(text: []const u8) bool {
    var depth: i32 = 0;
    for (text) |c| {
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
        }
    }
    return depth > 0;
}

test "findUrlAtPosition - basic https" {
    const text = "hello https://example.com world";
    const url = findUrlAtPosition(text, 10);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://example.com", url.?);
}

test "findUrlAtPosition - click on scheme" {
    const text = "hello https://example.com world";
    const url = findUrlAtPosition(text, 6);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://example.com", url.?);
}

test "findUrlAtPosition - trailing period" {
    const text = "Link https://example.com. More text.";
    const url = findUrlAtPosition(text, 10);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://example.com", url.?);
}

test "findUrlAtPosition - trailing comma" {
    const text = "Link https://example.com, more text.";
    const url = findUrlAtPosition(text, 10);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://example.com", url.?);
}

test "findUrlAtPosition - inside parens" {
    const text = "(https://example.com)";
    const url = findUrlAtPosition(text, 5);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://example.com", url.?);
}

test "findUrlAtPosition - with path containing parens" {
    const text = "https://en.wikipedia.org/wiki/Rust_(video_game) more";
    const url = findUrlAtPosition(text, 10);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Rust_(video_game)", url.?);
}

test "findUrlAtPosition - no url" {
    const text = "hello world";
    const url = findUrlAtPosition(text, 5);
    try std.testing.expect(url == null);
}

test "findUrlAtPosition - multiple urls" {
    const text = "https://google.com https://github.com links";
    const url1 = findUrlAtPosition(text, 5);
    try std.testing.expect(url1 != null);
    try std.testing.expectEqualStrings("https://google.com", url1.?);

    const url2 = findUrlAtPosition(text, 25);
    try std.testing.expect(url2 != null);
    try std.testing.expectEqualStrings("https://github.com", url2.?);
}

test "findUrlAtPosition - http scheme" {
    const text = "http://example.com";
    const url = findUrlAtPosition(text, 5);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("http://example.com", url.?);
}

test "findUrlAtPosition - mailto scheme" {
    const text = "email me at mailto:test@example.com ok";
    const url = findUrlAtPosition(text, 20);
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("mailto:test@example.com", url.?);
}
