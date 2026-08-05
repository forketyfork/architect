//! Backspace semantics shared by every single-line text input in the UI
//! (worktree name entry, recent-folder search, reader/story search, diff
//! comment editor). Components own their buffers; these helpers only compute
//! the resulting length, so a caller truncates with `items.len = ...`.

const std = @import("std");
const c = @import("../c.zig");

/// How much a Backspace press removes, following the macOS text-field
/// convention: Cmd clears the field, Alt deletes the previous word.
pub const DeleteScope = enum { character, word, all };

/// Word separators per input kind. Alt+Backspace stops at these.
pub const name_separators = "-_";
pub const path_separators = " \t/-_.";
pub const prose_separators = " \t\n-_/.,;:!?()[]{}";

pub fn scopeFromMods(mod: c.SDL_Keymod) DeleteScope {
    if ((mod & c.SDL_KMOD_GUI) != 0) return .all;
    if ((mod & c.SDL_KMOD_ALT) != 0) return .word;
    return .character;
}

/// Length `text` should be truncated to after one Backspace press.
pub fn backspace(text: []const u8, scope: DeleteScope, separators: []const u8) usize {
    return switch (scope) {
        .all => 0,
        .word => lastWordStart(text, separators),
        .character => lastCharacterStart(text),
    };
}

/// Start of the last UTF-8 sequence, so one press removes a whole codepoint
/// rather than a byte of it.
pub fn lastCharacterStart(text: []const u8) usize {
    if (text.len == 0) return 0;
    var i = text.len - 1;
    while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

/// Start of the last word: trailing separators are consumed together with the
/// word before them, so repeated presses always make progress instead of
/// stalling on a separator.
pub fn lastWordStart(text: []const u8, separators: []const u8) usize {
    var i = text.len;
    while (i > 0 and isSeparator(text[i - 1], separators)) i -= 1;
    while (i > 0 and !isSeparator(text[i - 1], separators)) i -= 1;
    return i;
}

fn isSeparator(ch: u8, separators: []const u8) bool {
    return std.mem.indexOfScalar(u8, separators, ch) != null;
}

// --- Tests ---

test "scopeFromMods follows the macOS convention" {
    try std.testing.expectEqual(DeleteScope.character, scopeFromMods(0));
    try std.testing.expectEqual(DeleteScope.word, scopeFromMods(c.SDL_KMOD_ALT));
    try std.testing.expectEqual(DeleteScope.all, scopeFromMods(c.SDL_KMOD_GUI));
    // Cmd wins when both are held.
    try std.testing.expectEqual(DeleteScope.all, scopeFromMods(c.SDL_KMOD_GUI | c.SDL_KMOD_ALT));
    // Shift does not change the scope.
    try std.testing.expectEqual(DeleteScope.character, scopeFromMods(c.SDL_KMOD_SHIFT));
}

test "backspace — empty text stays empty in every scope" {
    try std.testing.expectEqual(0, backspace("", .character, path_separators));
    try std.testing.expectEqual(0, backspace("", .word, path_separators));
    try std.testing.expectEqual(0, backspace("", .all, path_separators));
}

test "backspace — all clears the buffer" {
    try std.testing.expectEqual(0, backspace("dev/github", .all, path_separators));
}

test "lastCharacterStart — removes a whole multi-byte codepoint" {
    try std.testing.expectEqual(4, lastCharacterStart("hello"));
    // "é" is two bytes, "→" is three, "🙂" is four.
    try std.testing.expectEqual(0, lastCharacterStart("é"));
    try std.testing.expectEqual(0, lastCharacterStart("→"));
    try std.testing.expectEqual(0, lastCharacterStart("🙂"));
    try std.testing.expectEqual(1, lastCharacterStart("a🙂"));
}

test "lastWordStart — empty text" {
    try std.testing.expectEqual(0, lastWordStart("", name_separators));
}

test "lastWordStart — single word clears everything" {
    try std.testing.expectEqual(0, lastWordStart("feature", name_separators));
}

test "lastWordStart — stops after the preceding separator" {
    try std.testing.expectEqual(8, lastWordStart("feature-branch", name_separators));
}

test "lastWordStart — consumes trailing separators with the word" {
    try std.testing.expectEqual(8, lastWordStart("feature-branch--", name_separators));
    try std.testing.expectEqual(0, lastWordStart("feature--", name_separators));
}

test "lastWordStart — text of only separators clears everything" {
    try std.testing.expectEqual(0, lastWordStart("---", name_separators));
}

test "lastWordStart — path separators drop one segment at a time" {
    try std.testing.expectEqual(9, lastWordStart("dev/repo/architect", path_separators));
    try std.testing.expectEqual(4, lastWordStart("dev/repo/", path_separators));
}

test "lastWordStart — prose separators stop at punctuation" {
    try std.testing.expectEqual(13, lastWordStart("fix the bug, please", prose_separators));
    // The comma and the space before "please" go with it on the next press.
    try std.testing.expectEqual(8, lastWordStart("fix the bug, ", prose_separators));
    try std.testing.expectEqual(1, lastWordStart("(wrapped)", prose_separators));
}
