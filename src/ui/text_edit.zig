//! Editing behavior shared by every text input in the UI (worktree name entry,
//! recent-folder search, reader/story search, diff comment editor).
//!
//! `TextInput` owns the buffer plus the state a focused field needs — caret
//! blink phase and the select-all flag — and handles the macOS editing keys:
//! Backspace (plain/⌥/⌘), ⌘A, ⌘C, ⌘V. Components keep ownership of layout and
//! rendering; they ask `caretVisible`/`select_all` for the visual state.
//!
//! The model is append-only by design: these are single-purpose fields, so the
//! caret always sits at the end and the only selection is "everything". The
//! free functions below are the pure length math behind it and stay usable on
//! their own.

const std = @import("std");
const c = @import("../c.zig");

const log = std.log.scoped(.text_edit);

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

/// Filter for single-line fields: drops control bytes, so pasting multi-line
/// clipboard content cannot smuggle newlines into a one-line search box.
pub fn isSingleLineChar(ch: u8) bool {
    return ch >= 0x20 and ch != 0x7F;
}

/// A focused single-line text field: buffer, caret blink phase, select-all.
pub const TextInput = struct {
    buf: std.ArrayList(u8) = .empty,
    /// ⌘A highlights the whole field; the next insert or Backspace replaces it.
    select_all: bool = false,
    blink_start_ms: i64 = 0,

    /// Word separators for ⌥Backspace.
    separators: []const u8 = prose_separators,
    /// Upper bound on the buffer length; inserts stop at it.
    max_len: usize = std.math.maxInt(usize),
    /// Optional per-byte filter for constrained fields (e.g. worktree names).
    /// Rejected bytes are dropped, matching how typed input is filtered.
    accepts: ?*const fn (u8) bool = null,

    /// Full on/off cycle of the caret.
    pub const blink_period_ms: i64 = 1000;

    /// What a key press did, so the caller knows whether to consume the event
    /// and whether dependent state (search matches, filters) must be rebuilt.
    pub const KeyResult = struct {
        consumed: bool = false,
        text_changed: bool = false,

        pub const ignored: KeyResult = .{};
    };

    pub fn deinit(self: *TextInput, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn text(self: *const TextInput) []const u8 {
        return self.buf.items;
    }

    pub fn isEmpty(self: *const TextInput) bool {
        return self.buf.items.len == 0;
    }

    pub fn clear(self: *TextInput) void {
        self.buf.clearRetainingCapacity();
        self.select_all = false;
    }

    /// Restart the blink cycle so the caret is solid right after an edit
    /// instead of possibly blinking out mid-keystroke.
    pub fn touch(self: *TextInput, now_ms: i64) void {
        self.blink_start_ms = now_ms;
    }

    pub fn caretVisible(self: *const TextInput, now_ms: i64) bool {
        const phase = @mod(now_ms - self.blink_start_ms, blink_period_ms);
        return phase < @divFloor(blink_period_ms, 2);
    }

    /// Append text (from `SDL_EVENT_TEXT_INPUT` or the clipboard), replacing a
    /// select-all first. Returns true when the buffer changed.
    pub fn insert(self: *TextInput, allocator: std.mem.Allocator, incoming: []const u8, now_ms: i64) bool {
        self.touch(now_ms);
        var changed = false;
        if (self.select_all) {
            changed = self.buf.items.len > 0;
            self.clear();
        }

        for (incoming) |ch| {
            if (self.buf.items.len >= self.max_len) break;
            if (self.accepts) |accepts| {
                if (!accepts(ch)) continue;
            }
            self.buf.append(allocator, ch) catch |err| {
                log.warn("failed to append text input: {}", .{err});
                break;
            };
            changed = true;
        }
        return changed;
    }

    /// Handle one `SDL_EVENT_KEY_DOWN`. Returns `.ignored` for keys the field
    /// does not own, so the component can fall through to its own shortcuts.
    pub fn handleKey(
        self: *TextInput,
        allocator: std.mem.Allocator,
        key: c.SDL_Keycode,
        mod: c.SDL_Keymod,
        now_ms: i64,
    ) KeyResult {
        const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
        const has_alt = (mod & c.SDL_KMOD_ALT) != 0;
        const has_ctrl = (mod & c.SDL_KMOD_CTRL) != 0;

        switch (key) {
            c.SDLK_BACKSPACE => {
                self.touch(now_ms);
                const new_len = if (self.select_all)
                    0
                else
                    backspace(self.buf.items, scopeFromMods(mod), self.separators);
                self.select_all = false;
                if (new_len == self.buf.items.len) return .{ .consumed = true };
                self.buf.items.len = new_len;
                return .{ .consumed = true, .text_changed = true };
            },
            c.SDLK_A => {
                if (!has_gui or has_alt or has_ctrl) return .ignored;
                self.touch(now_ms);
                self.select_all = !self.isEmpty();
                return .{ .consumed = true };
            },
            c.SDLK_C => {
                if (!has_gui or has_alt or has_ctrl) return .ignored;
                self.copyToClipboard(allocator);
                return .{ .consumed = true };
            },
            c.SDLK_V => {
                if (!has_gui or has_alt or has_ctrl) return .ignored;
                return .{ .consumed = true, .text_changed = self.pasteFromClipboard(allocator, now_ms) };
            },
            else => return .ignored,
        }
    }

    fn copyToClipboard(self: *const TextInput, allocator: std.mem.Allocator) void {
        if (self.isEmpty()) return;
        const buf = allocator.alloc(u8, self.buf.items.len + 1) catch |err| {
            log.warn("failed to allocate clipboard copy: {}", .{err});
            return;
        };
        defer allocator.free(buf);
        @memcpy(buf[0..self.buf.items.len], self.buf.items);
        buf[self.buf.items.len] = 0;
        if (!c.SDL_SetClipboardText(buf.ptr)) {
            log.warn("SDL_SetClipboardText failed: {s}", .{c.SDL_GetError()});
        }
    }

    fn pasteFromClipboard(self: *TextInput, allocator: std.mem.Allocator, now_ms: i64) bool {
        const clip_ptr = c.SDL_GetClipboardText();
        if (clip_ptr == null) {
            log.warn("SDL_GetClipboardText failed: {s}", .{c.SDL_GetError()});
            return false;
        }
        defer c.SDL_free(clip_ptr);
        const clip = std.mem.sliceTo(clip_ptr, 0);
        if (clip.len == 0) return false;
        return self.insert(allocator, clip, now_ms);
    }
};

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

test "TextInput — caret blinks on a one-second cycle and resets on edit" {
    var input = TextInput{};
    defer input.deinit(std.testing.allocator);
    input.touch(1000);

    try std.testing.expect(input.caretVisible(1000));
    try std.testing.expect(input.caretVisible(1499));
    try std.testing.expect(!input.caretVisible(1500));
    try std.testing.expect(!input.caretVisible(1999));
    try std.testing.expect(input.caretVisible(2000));

    // Typing mid-blink makes the caret solid again immediately.
    _ = input.insert(std.testing.allocator, "a", 1700);
    try std.testing.expect(input.caretVisible(1700));
}

test "TextInput — Cmd+A selects all and the next insert replaces it" {
    var input = TextInput{ .separators = path_separators };
    defer input.deinit(std.testing.allocator);
    _ = input.insert(std.testing.allocator, "dev/github", 0);

    const selected = input.handleKey(std.testing.allocator, c.SDLK_A, c.SDL_KMOD_GUI, 0);
    try std.testing.expect(selected.consumed);
    try std.testing.expect(!selected.text_changed);
    try std.testing.expect(input.select_all);

    try std.testing.expect(input.insert(std.testing.allocator, "x", 0));
    try std.testing.expectEqualStrings("x", input.text());
    try std.testing.expect(!input.select_all);
}

test "TextInput — Cmd+A on an empty field selects nothing" {
    var input = TextInput{};
    defer input.deinit(std.testing.allocator);

    _ = input.handleKey(std.testing.allocator, c.SDLK_A, c.SDL_KMOD_GUI, 0);
    try std.testing.expect(!input.select_all);
}

test "TextInput — Backspace clears the whole selection in one press" {
    var input = TextInput{ .separators = path_separators };
    defer input.deinit(std.testing.allocator);
    _ = input.insert(std.testing.allocator, "dev/github", 0);
    _ = input.handleKey(std.testing.allocator, c.SDLK_A, c.SDL_KMOD_GUI, 0);

    const result = input.handleKey(std.testing.allocator, c.SDLK_BACKSPACE, 0, 0);
    try std.testing.expect(result.text_changed);
    try std.testing.expectEqualStrings("", input.text());
    try std.testing.expect(!input.select_all);
}

test "TextInput — Backspace scopes still apply without a selection" {
    var input = TextInput{ .separators = path_separators };
    defer input.deinit(std.testing.allocator);
    _ = input.insert(std.testing.allocator, "dev/github", 0);

    _ = input.handleKey(std.testing.allocator, c.SDLK_BACKSPACE, 0, 0);
    try std.testing.expectEqualStrings("dev/githu", input.text());

    _ = input.handleKey(std.testing.allocator, c.SDLK_BACKSPACE, c.SDL_KMOD_ALT, 0);
    try std.testing.expectEqualStrings("dev/", input.text());

    _ = input.handleKey(std.testing.allocator, c.SDLK_BACKSPACE, c.SDL_KMOD_GUI, 0);
    try std.testing.expectEqualStrings("", input.text());
}

test "TextInput — Backspace on an empty field reports no change" {
    var input = TextInput{};
    defer input.deinit(std.testing.allocator);

    const result = input.handleKey(std.testing.allocator, c.SDLK_BACKSPACE, 0, 0);
    try std.testing.expect(result.consumed);
    try std.testing.expect(!result.text_changed);
}

test "TextInput — letters are only claimed with a bare Cmd" {
    var input = TextInput{};
    defer input.deinit(std.testing.allocator);

    // Plain letters arrive as SDL_EVENT_TEXT_INPUT, not as an edit key.
    try std.testing.expect(!input.handleKey(std.testing.allocator, c.SDLK_A, 0, 0).consumed);
    // Cmd+Alt+A / Ctrl+A belong to whatever else binds them.
    try std.testing.expect(!input.handleKey(std.testing.allocator, c.SDLK_A, c.SDL_KMOD_GUI | c.SDL_KMOD_ALT, 0).consumed);
    try std.testing.expect(!input.handleKey(std.testing.allocator, c.SDLK_C, c.SDL_KMOD_CTRL, 0).consumed);
    // Keys the field does not own fall through.
    try std.testing.expect(!input.handleKey(std.testing.allocator, c.SDLK_UP, 0, 0).consumed);
}

test "TextInput — max_len and the accepts filter bound what gets in" {
    var input = TextInput{ .max_len = 4, .accepts = isSingleLineChar };
    defer input.deinit(std.testing.allocator);

    try std.testing.expect(input.insert(std.testing.allocator, "ab\ncd\tef", 0));
    try std.testing.expectEqualStrings("abcd", input.text());
}

test "TextInput — inserting nothing acceptable reports no change" {
    var input = TextInput{ .accepts = isSingleLineChar };
    defer input.deinit(std.testing.allocator);

    try std.testing.expect(!input.insert(std.testing.allocator, "\n\n", 0));
    try std.testing.expectEqualStrings("", input.text());
}

test "lastWordStart — prose separators stop at punctuation" {
    try std.testing.expectEqual(13, lastWordStart("fix the bug, please", prose_separators));
    // The comma and the space before "please" go with it on the next press.
    try std.testing.expectEqual(8, lastWordStart("fix the bug, ", prose_separators));
    try std.testing.expectEqual(1, lastWordStart("(wrapped)", prose_separators));
}
