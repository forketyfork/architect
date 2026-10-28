//! UTF-8 traversal for UI text that comes from documents and terminal output,
//! where valid UTF-8 cannot be assumed.
//!
//! `std.unicode.Utf8Iterator` asserts validity with `catch unreachable`. On a
//! malformed byte a release build computes a zero-length step and spins
//! forever, freezing the frame loop. These helpers treat each byte of a
//! malformed sequence as one U+FFFD unit, matching how SDL_ttf renders it, so
//! iteration always advances.
//!
//! Column math here counts codepoints: wrapping by bytes splits multi-byte
//! characters and makes non-ASCII lines wrap early.

const std = @import("std");

pub const Decoded = struct {
    /// U+FFFD for a malformed sequence.
    cp: u21,
    /// Bytes consumed; always at least 1.
    len: usize,
};

const malformed = Decoded{ .cp = std.unicode.replacement_character, .len = 1 };

/// Decodes the codepoint starting at `text[i]`.
pub fn decodeAt(text: []const u8, i: usize) Decoded {
    std.debug.assert(i < text.len);
    const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch return malformed;
    if (seq_len > text.len - i) return malformed;
    const cp = std.unicode.utf8Decode(text[i..][0..seq_len]) catch return malformed;
    return .{ .cp = cp, .len = seq_len };
}

/// Columns `text` occupies, one per codepoint or malformed byte.
pub fn columnCount(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (cols += 1) {
        i += decodeAt(text, i).len;
    }
    return cols;
}

/// Byte length of the longest prefix of `text` spanning at most `max_cols`
/// columns. The prefix never ends inside a codepoint.
pub fn prefixLen(text: []const u8, max_cols: usize) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < text.len and cols < max_cols) : (cols += 1) {
        i += decodeAt(text, i).len;
    }
    return i;
}

test "decodeAt decodes valid sequences" {
    const d = decodeAt("─x", 0);
    try std.testing.expectEqual(@as(u21, 0x2500), d.cp);
    try std.testing.expectEqual(@as(usize, 3), d.len);
    try std.testing.expectEqual(@as(u21, 'x'), decodeAt("─x", 3).cp);
}

test "decodeAt steps one byte over malformed input" {
    const cases = [_][]const u8{
        "\x80", // continuation byte as a lead
        "\xe2\x94", // truncated sequence
        "\xed\xa0\x80", // surrogate half
        "\xc0\x80", // overlong encoding
        "\xff",
    };
    for (cases) |text| {
        const d = decodeAt(text, 0);
        try std.testing.expectEqual(std.unicode.replacement_character, d.cp);
        try std.testing.expectEqual(@as(usize, 1), d.len);
    }
}

test "columnCount counts codepoints and malformed bytes" {
    try std.testing.expectEqual(@as(usize, 0), columnCount(""));
    try std.testing.expectEqual(@as(usize, 5), columnCount("héllo"));
    try std.testing.expectEqual(@as(usize, 3), columnCount("───"));
    try std.testing.expectEqual(@as(usize, 3), columnCount("\x80─\xe2"));
}

test "prefixLen stops on a codepoint boundary" {
    const rule = "─" ** 4;
    try std.testing.expectEqual(@as(usize, 6), prefixLen(rule, 2));
    try std.testing.expectEqual(rule.len, prefixLen(rule, 10));
    try std.testing.expectEqual(@as(usize, 0), prefixLen(rule, 0));
    try std.testing.expectEqual(@as(usize, 4), prefixLen("\x80─x", 2));
}
