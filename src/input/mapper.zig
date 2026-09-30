const std = @import("std");
const c = @import("../c.zig");
const ghostty_vt = @import("ghostty-vt");
const app_state = @import("../app/app_state.zig");

pub const FontSizeDirection = enum { increase, decrease };
pub const GridNavDirection = enum { up, down, left, right };

pub fn fontSizeShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?FontSizeDirection {
    if ((mod & c.SDL_KMOD_GUI) == 0) return null;
    if ((mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0) return null;

    return switch (key) {
        // The keypad plus key produces a plus on its own; only the main-row
        // equals key needs Shift to become a plus.
        c.SDLK_KP_PLUS => .increase,
        c.SDLK_EQUALS => if ((mod & c.SDL_KMOD_SHIFT) != 0) .increase else null,
        c.SDLK_MINUS, c.SDLK_KP_MINUS => .decrease,
        else => null,
    };
}

pub fn gridNavShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?GridNavDirection {
    if ((mod & c.SDL_KMOD_GUI) == 0) return null;
    if ((mod & (c.SDL_KMOD_SHIFT | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0) return null;
    return switch (key) {
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        else => null,
    };
}

pub fn canHandleEscapePress(mode: app_state.ViewMode) bool {
    return mode != .Grid and mode != .Collapsing and mode != .GridResizing;
}

pub fn expandTerminalShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) bool {
    return key == c.SDLK_RETURN and (mod & c.SDL_KMOD_GUI) != 0 and
        (mod & (c.SDL_KMOD_SHIFT | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) == 0;
}

/// Returns terminal index (0-9) for Cmd+1..9,0 shortcuts.
/// Cmd+1 returns 0, Cmd+2 returns 1, ..., Cmd+9 returns 8, Cmd+0 returns 9.
pub fn terminalSwitchShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod, max_terminals: usize) ?usize {
    if ((mod & c.SDL_KMOD_GUI) == 0) return null;
    if ((mod & (c.SDL_KMOD_SHIFT | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0) return null;

    const idx: ?usize = if (key >= c.SDLK_1 and key <= c.SDLK_9)
        @intCast(key - c.SDLK_1)
    else if (key == c.SDLK_0)
        9
    else
        null;

    if (idx) |i| {
        if (i < max_terminals) return i;
    }
    return null;
}

const terminal_hotkey_labels = [_][]const u8{
    "⌘1",
    "⌘2",
    "⌘3",
    "⌘4",
    "⌘5",
    "⌘6",
    "⌘7",
    "⌘8",
    "⌘9",
    "⌘0",
};

pub fn terminalHotkeyLabel(index: usize) ?[]const u8 {
    if (index >= terminal_hotkey_labels.len) return null;
    return terminal_hotkey_labels[index];
}

pub const KeyEncodingOptions = ghostty_vt.input.KeyEncodeOptions;

/// Encode functional and control keys. Layout-dependent text is delivered by SDL_TEXT_INPUT.
pub fn encodeKeyWithMod(key: c.SDL_Keycode, mod: c.SDL_Keymod, options: KeyEncodingOptions, buf: []u8) std.Io.Writer.Error!usize {
    var writer = std.Io.Writer.fixed(buf);
    if (compatibilityKeyBinding(key, mod, options)) |sequence| {
        try writer.writeAll(sequence);
        return writer.end;
    }

    const mapped_key = terminalKey(key);
    const printable = key >= 0x20 and key <= 0x7e;
    if (printable and (mod & c.SDL_KMOD_CTRL) == 0) return 0;
    if (!printable and mapped_key == .unidentified) return 0;

    var text: [1]u8 = undefined;
    if (printable) {
        text[0] = @intCast(key);
        if ((mod & c.SDL_KMOD_SHIFT) != 0 and std.ascii.isLower(text[0])) {
            text[0] = std.ascii.toUpper(text[0]);
        }
    }
    try ghostty_vt.input.encodeKey(&writer, .{
        .key = mapped_key,
        .mods = .{
            .shift = (mod & c.SDL_KMOD_SHIFT) != 0,
            .ctrl = (mod & c.SDL_KMOD_CTRL) != 0,
            .alt = (mod & c.SDL_KMOD_ALT) != 0,
            .super = (mod & c.SDL_KMOD_GUI) != 0,
            .caps_lock = (mod & c.SDL_KMOD_CAPS) != 0,
            .num_lock = (mod & c.SDL_KMOD_NUM) != 0,
        },
        .utf8 = if (printable) &text else "",
        .unshifted_codepoint = if (printable) @intCast(key) else 0,
    }, options);
    return writer.end;
}

fn compatibilityKeyBinding(key: c.SDL_Keycode, mod: c.SDL_Keymod, options: KeyEncodingOptions) ?[]const u8 {
    const binding_mods = mod & (c.SDL_KMOD_SHIFT | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_GUI);
    const kitty_enabled = options.kitty_flags.int() != 0;
    if (options.kitty_flags.report_events or options.kitty_flags.report_all) return null;
    // Keep shell C0 aliases when no extended protocol was requested.
    if (!kitty_enabled and !options.modify_other_keys_state_2 and
        (binding_mods == c.SDL_KMOD_CTRL or binding_mods == (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)))
    {
        const alt = (binding_mods & c.SDL_KMOD_ALT) != 0;
        return switch (key) {
            c.SDLK_I => if (alt) "\x1b\t" else "\t",
            c.SDLK_M => if (alt) "\x1b\r" else "\r",
            c.SDLK_LEFTBRACKET => if (alt) "\x1b\x1b" else "\x1b",
            else => null,
        };
    }
    if (binding_mods == c.SDL_KMOD_GUI) {
        return switch (key) {
            c.SDLK_LEFT => "\x01",
            c.SDLK_RIGHT => "\x05",
            c.SDLK_BACKSPACE => if (!kitty_enabled) "\x15" else null,
            else => null,
        };
    }
    if (binding_mods == c.SDL_KMOD_ALT) {
        return switch (key) {
            c.SDLK_LEFT => "\x1bb",
            c.SDLK_RIGHT => "\x1bf",
            c.SDLK_BACKSPACE => if (!kitty_enabled) "\x17" else null,
            else => null,
        };
    }
    if (binding_mods == 0 and !kitty_enabled) {
        return switch (key) {
            c.SDLK_HOME => "\x01",
            c.SDLK_END => "\x05",
            else => null,
        };
    }
    return null;
}

fn terminalKey(key: c.SDL_Keycode) ghostty_vt.input.Key {
    if (key >= c.SDLK_A and key <= c.SDLK_Z) {
        return @enumFromInt(@intFromEnum(ghostty_vt.input.Key.key_a) + @as(c_int, @intCast(key - c.SDLK_A)));
    }
    if (key >= c.SDLK_0 and key <= c.SDLK_9) {
        return @enumFromInt(@intFromEnum(ghostty_vt.input.Key.digit_0) + @as(c_int, @intCast(key - c.SDLK_0)));
    }
    return switch (key) {
        c.SDLK_RETURN, c.SDLK_RETURN2 => .enter,
        c.SDLK_KP_ENTER => .numpad_enter,
        c.SDLK_TAB => .tab,
        c.SDLK_BACKSPACE => .backspace,
        c.SDLK_ESCAPE => .escape,
        c.SDLK_UP => .arrow_up,
        c.SDLK_DOWN => .arrow_down,
        c.SDLK_RIGHT => .arrow_right,
        c.SDLK_LEFT => .arrow_left,
        c.SDLK_HOME => .home,
        c.SDLK_END => .end,
        c.SDLK_INSERT => .insert,
        c.SDLK_DELETE => .delete,
        c.SDLK_PAGEUP => .page_up,
        c.SDLK_PAGEDOWN => .page_down,
        c.SDLK_F1 => .f1,
        c.SDLK_F2 => .f2,
        c.SDLK_F3 => .f3,
        c.SDLK_F4 => .f4,
        c.SDLK_F5 => .f5,
        c.SDLK_F6 => .f6,
        c.SDLK_F7 => .f7,
        c.SDLK_F8 => .f8,
        c.SDLK_F9 => .f9,
        c.SDLK_F10 => .f10,
        c.SDLK_F11 => .f11,
        c.SDLK_F12 => .f12,
        c.SDLK_SPACE => .space,
        c.SDLK_LEFTBRACKET => .bracket_left,
        c.SDLK_RIGHTBRACKET => .bracket_right,
        c.SDLK_BACKSLASH => .backslash,
        c.SDLK_SLASH => .slash,
        c.SDLK_MINUS => .minus,
        c.SDLK_EQUALS => .equal,
        c.SDLK_COMMA => .comma,
        c.SDLK_PERIOD => .period,
        c.SDLK_SEMICOLON => .semicolon,
        c.SDLK_APOSTROPHE => .quote,
        c.SDLK_GRAVE => .backquote,
        else => .unidentified,
    };
}

fn testKeyOptions(cursor_keys: bool, kitty_enabled: bool) KeyEncodingOptions {
    return .{
        .cursor_key_application = cursor_keys,
        .kitty_flags = if (kitty_enabled) .{ .disambiguate = true } else .disabled,
    };
}

test "encodeKeyWithMod - return key" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RETURN, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "encodeKeyWithMod - tab key" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_TAB, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\t'), buf[0]);
}

test "encodeKeyWithMod - backspace key" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_BACKSPACE, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 127), buf[0]);
}

test "encodeKeyWithMod - escape key" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_ESCAPE, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 27), buf[0]);
}

test "encodeKeyWithMod - arrow keys normal mode" {
    var buf: [16]u8 = undefined;

    const n_up = try encodeKeyWithMod(c.SDLK_UP, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_up);
    try std.testing.expectEqualSlices(u8, "\x1b[A", buf[0..n_up]);

    const n_down = try encodeKeyWithMod(c.SDLK_DOWN, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_down);
    try std.testing.expectEqualSlices(u8, "\x1b[B", buf[0..n_down]);

    const n_right = try encodeKeyWithMod(c.SDLK_RIGHT, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_right);
    try std.testing.expectEqualSlices(u8, "\x1b[C", buf[0..n_right]);

    const n_left = try encodeKeyWithMod(c.SDLK_LEFT, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_left);
    try std.testing.expectEqualSlices(u8, "\x1b[D", buf[0..n_left]);
}

test "encodeKeyWithMod - arrow keys application mode (DECCKM)" {
    var buf: [16]u8 = undefined;

    const n_up = try encodeKeyWithMod(c.SDLK_UP, 0, testKeyOptions(true, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_up);
    try std.testing.expectEqualSlices(u8, "\x1bOA", buf[0..n_up]);

    const n_down = try encodeKeyWithMod(c.SDLK_DOWN, 0, testKeyOptions(true, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_down);
    try std.testing.expectEqualSlices(u8, "\x1bOB", buf[0..n_down]);

    const n_right = try encodeKeyWithMod(c.SDLK_RIGHT, 0, testKeyOptions(true, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_right);
    try std.testing.expectEqualSlices(u8, "\x1bOC", buf[0..n_right]);

    const n_left = try encodeKeyWithMod(c.SDLK_LEFT, 0, testKeyOptions(true, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n_left);
    try std.testing.expectEqualSlices(u8, "\x1bOD", buf[0..n_left]);
}

test "encodeKeyWithMod - shift arrows preserve modifiers in every terminal mode" {
    const cases = [_]struct { key: c.SDL_Keycode, expected: []const u8 }{
        .{ .key = c.SDLK_LEFT, .expected = "\x1b[1;2D" },
        .{ .key = c.SDLK_RIGHT, .expected = "\x1b[1;2C" },
        .{ .key = c.SDLK_UP, .expected = "\x1b[1;2A" },
        .{ .key = c.SDLK_DOWN, .expected = "\x1b[1;2B" },
    };
    var buf: [16]u8 = undefined;
    for ([_]bool{ false, true }) |cursor_keys| {
        for ([_]bool{ false, true }) |kitty_enabled| {
            for (cases) |case| {
                const n = try encodeKeyWithMod(case.key, c.SDL_KMOD_SHIFT, testKeyOptions(cursor_keys, kitty_enabled), &buf);
                try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
            }
        }
    }
}

test "encodeKeyWithMod - combined navigation and function modifiers preserve every bit" {
    const cases = [_]struct { mod: c.SDL_Keymod, parameter: []const u8 }{
        .{ .mod = c.SDL_KMOD_SHIFT, .parameter = "2" },
        .{ .mod = c.SDL_KMOD_ALT, .parameter = "3" },
        .{ .mod = c.SDL_KMOD_GUI, .parameter = "9" },
        .{ .mod = c.SDL_KMOD_CTRL, .parameter = "5" },
        .{ .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT, .parameter = "6" },
        .{ .mod = c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, .parameter = "4" },
        .{ .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT, .parameter = "7" },
        .{ .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, .parameter = "8" },
        .{ .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT, .parameter = "10" },
        .{ .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_ALT, .parameter = "11" },
        .{ .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, .parameter = "12" },
        .{ .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL, .parameter = "13" },
        .{ .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT, .parameter = "14" },
        .{ .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT, .parameter = "15" },
        .{ .mod = c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, .parameter = "16" },
    };
    const keys = [_]struct { key: c.SDL_Keycode, parameter: u8, final: u8 }{
        .{ .key = c.SDLK_UP, .parameter = 1, .final = 'A' },
        .{ .key = c.SDLK_DOWN, .parameter = 1, .final = 'B' },
        .{ .key = c.SDLK_RIGHT, .parameter = 1, .final = 'C' },
        .{ .key = c.SDLK_LEFT, .parameter = 1, .final = 'D' },
        .{ .key = c.SDLK_HOME, .parameter = 1, .final = 'H' },
        .{ .key = c.SDLK_END, .parameter = 1, .final = 'F' },
        .{ .key = c.SDLK_INSERT, .parameter = 2, .final = '~' },
        .{ .key = c.SDLK_DELETE, .parameter = 3, .final = '~' },
        .{ .key = c.SDLK_PAGEUP, .parameter = 5, .final = '~' },
        .{ .key = c.SDLK_PAGEDOWN, .parameter = 6, .final = '~' },
        .{ .key = c.SDLK_F1, .parameter = 1, .final = 'P' },
        .{ .key = c.SDLK_F2, .parameter = 1, .final = 'Q' },
        .{ .key = c.SDLK_F3, .parameter = 13, .final = '~' },
        .{ .key = c.SDLK_F4, .parameter = 1, .final = 'S' },
        .{ .key = c.SDLK_F5, .parameter = 15, .final = '~' },
        .{ .key = c.SDLK_F6, .parameter = 17, .final = '~' },
        .{ .key = c.SDLK_F7, .parameter = 18, .final = '~' },
        .{ .key = c.SDLK_F8, .parameter = 19, .final = '~' },
        .{ .key = c.SDLK_F9, .parameter = 20, .final = '~' },
        .{ .key = c.SDLK_F10, .parameter = 21, .final = '~' },
        .{ .key = c.SDLK_F11, .parameter = 23, .final = '~' },
        .{ .key = c.SDLK_F12, .parameter = 24, .final = '~' },
    };
    var buf: [16]u8 = undefined;
    var expected_buf: [16]u8 = undefined;
    for ([_]bool{ false, true }) |cursor_keys| {
        for ([_]bool{ false, true }) |kitty_enabled| {
            for (cases) |case| {
                for (keys) |entry| {
                    if ((entry.key == c.SDLK_LEFT or entry.key == c.SDLK_RIGHT) and
                        (case.mod == c.SDL_KMOD_ALT or case.mod == c.SDL_KMOD_GUI)) continue;
                    const expected = try std.fmt.bufPrint(&expected_buf, "\x1b[{d};{s}{c}", .{ entry.parameter, case.parameter, entry.final });
                    const n = try encodeKeyWithMod(entry.key, case.mod, testKeyOptions(cursor_keys, kitty_enabled), &buf);
                    try std.testing.expectEqualSlices(u8, expected, buf[0..n]);
                }
            }
        }
    }
}

test "encodeKeyWithMod - alt and cmd vertical arrows preserve modifiers" {
    const cases = [_]struct { key: c.SDL_Keycode, mod: c.SDL_Keymod, expected: []const u8 }{
        .{ .key = c.SDLK_UP, .mod = c.SDL_KMOD_ALT, .expected = "\x1b[1;3A" },
        .{ .key = c.SDLK_DOWN, .mod = c.SDL_KMOD_ALT, .expected = "\x1b[1;3B" },
        .{ .key = c.SDLK_UP, .mod = c.SDL_KMOD_GUI, .expected = "\x1b[1;9A" },
        .{ .key = c.SDLK_DOWN, .mod = c.SDL_KMOD_GUI, .expected = "\x1b[1;9B" },
    };
    var buf: [16]u8 = undefined;
    for ([_]bool{ false, true }) |cursor_keys| {
        for ([_]bool{ false, true }) |kitty_enabled| {
            for (cases) |case| {
                const n = try encodeKeyWithMod(case.key, case.mod, testKeyOptions(cursor_keys, kitty_enabled), &buf);
                try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
            }
        }
    }
}

test "encodeKeyWithMod - macOS horizontal navigation shortcuts in every terminal mode" {
    const cases = [_]struct { key: c.SDL_Keycode, mod: c.SDL_Keymod, expected: []const u8 }{
        .{ .key = c.SDLK_LEFT, .mod = c.SDL_KMOD_ALT, .expected = "\x1bb" },
        .{ .key = c.SDLK_RIGHT, .mod = c.SDL_KMOD_ALT, .expected = "\x1bf" },
        .{ .key = c.SDLK_LEFT, .mod = c.SDL_KMOD_GUI, .expected = "\x01" },
        .{ .key = c.SDLK_RIGHT, .mod = c.SDL_KMOD_GUI, .expected = "\x05" },
    };
    var buf: [16]u8 = undefined;
    for ([_]bool{ false, true }) |cursor_keys| {
        for ([_]bool{ false, true }) |kitty_enabled| {
            for (cases) |case| {
                const n = try encodeKeyWithMod(case.key, case.mod, testKeyOptions(cursor_keys, kitty_enabled), &buf);
                try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
            }
        }
    }
}

test "encodeKeyWithMod - modified navigation keys" {
    const cases = [_]struct { key: c.SDL_Keycode, expected: []const u8 }{
        .{ .key = c.SDLK_HOME, .expected = "\x1b[1;2H" },
        .{ .key = c.SDLK_END, .expected = "\x1b[1;2F" },
        .{ .key = c.SDLK_INSERT, .expected = "\x1b[2;2~" },
        .{ .key = c.SDLK_DELETE, .expected = "\x1b[3;2~" },
        .{ .key = c.SDLK_PAGEUP, .expected = "\x1b[5;2~" },
        .{ .key = c.SDLK_PAGEDOWN, .expected = "\x1b[6;2~" },
    };
    var buf: [16]u8 = undefined;
    for ([_]bool{ false, true }) |cursor_keys| {
        for ([_]bool{ false, true }) |kitty_enabled| {
            for (cases) |case| {
                const n = try encodeKeyWithMod(case.key, c.SDL_KMOD_SHIFT, testKeyOptions(cursor_keys, kitty_enabled), &buf);
                try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
            }
        }
    }
}

test "encodeKeyWithMod - modified function keys" {
    const cases = [_]struct { key: c.SDL_Keycode, expected: []const u8 }{
        .{ .key = c.SDLK_F1, .expected = "\x1b[1;2P" },
        .{ .key = c.SDLK_F2, .expected = "\x1b[1;2Q" },
        .{ .key = c.SDLK_F3, .expected = "\x1b[13;2~" },
        .{ .key = c.SDLK_F4, .expected = "\x1b[1;2S" },
        .{ .key = c.SDLK_F5, .expected = "\x1b[15;2~" },
        .{ .key = c.SDLK_F6, .expected = "\x1b[17;2~" },
        .{ .key = c.SDLK_F7, .expected = "\x1b[18;2~" },
        .{ .key = c.SDLK_F8, .expected = "\x1b[19;2~" },
        .{ .key = c.SDLK_F9, .expected = "\x1b[20;2~" },
        .{ .key = c.SDLK_F10, .expected = "\x1b[21;2~" },
        .{ .key = c.SDLK_F11, .expected = "\x1b[23;2~" },
        .{ .key = c.SDLK_F12, .expected = "\x1b[24;2~" },
    };
    var buf: [16]u8 = undefined;
    for ([_]bool{ false, true }) |kitty_enabled| {
        for (cases) |case| {
            const n = try encodeKeyWithMod(case.key, c.SDL_KMOD_SHIFT, testKeyOptions(false, kitty_enabled), &buf);
            try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
        }
    }
}

test "encodeKeyWithMod - ctrl+alt letters preserve alt in legacy mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_A, c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT, testKeyOptions(false, false), &buf);
    try std.testing.expectEqualSlices(u8, "\x1b\x01", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+shift letters preserve shift in kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_A, c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT, testKeyOptions(false, true), &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[97;6u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+a" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_A, c.SDL_KMOD_CTRL, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+left (beginning of line)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_GUI, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+right (end of line)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_GUI, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 5), buf[0]);
}

test "encodeKeyWithMod - home (beginning of line)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_HOME, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - end (end of line)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_END, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 5), buf[0]);
}

test "encodeKeyWithMod - alt+left (backward word)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_ALT, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bb", buf[0..n]);
}

test "encodeKeyWithMod - alt+right (forward word)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_ALT, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bf", buf[0..n]);
}

test "encodeKeyWithMod - cmd+backspace (delete line)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_GUI, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 21), buf[0]);
}

test "encodeKeyWithMod - alt+backspace (delete word)" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_ALT, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 23), buf[0]);
}

test "encodeKeyWithMod - unknown key" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(0, 0, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "fontSizeShortcut - plus/minus variants" {
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_KP_PLUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_KP_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expect(fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_SHIFT) == null);
}

test "terminal shortcuts do not consume additional modifiers" {
    try std.testing.expect(expandTerminalShortcut(c.SDLK_RETURN, c.SDL_KMOD_GUI));
    for ([_]c.SDL_Keymod{ c.SDL_KMOD_SHIFT, c.SDL_KMOD_CTRL, c.SDL_KMOD_ALT }) |extra| {
        const mod: c.SDL_Keymod = @intCast(c.SDL_KMOD_GUI | extra);
        try std.testing.expect(!expandTerminalShortcut(c.SDLK_RETURN, mod));
    }
    for ([_]c.SDL_Keycode{ c.SDLK_LEFT, c.SDLK_RIGHT, c.SDLK_UP, c.SDLK_DOWN }) |key| {
        try std.testing.expect(gridNavShortcut(key, c.SDL_KMOD_GUI) != null);
        for ([_]c.SDL_Keymod{ c.SDL_KMOD_SHIFT, c.SDL_KMOD_CTRL, c.SDL_KMOD_ALT }) |extra| {
            const mod: c.SDL_Keymod = @intCast(c.SDL_KMOD_GUI | extra);
            try std.testing.expect(gridNavShortcut(key, mod) == null);
        }
    }
    for ([_]c.SDL_Keymod{ c.SDL_KMOD_CTRL, c.SDL_KMOD_ALT }) |extra| {
        const mod: c.SDL_Keymod = @intCast(c.SDL_KMOD_GUI | extra);
        const shifted_mod: c.SDL_Keymod = @intCast(c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT | extra);
        try std.testing.expect(fontSizeShortcut(c.SDLK_EQUALS, shifted_mod) == null);
        try std.testing.expect(fontSizeShortcut(c.SDLK_MINUS, mod) == null);
        try std.testing.expect(fontSizeShortcut(c.SDLK_KP_PLUS, mod) == null);
    }
}

test "encodeKeyWithMod - control characters and modified escape" {
    const cases = [_]struct { key: c.SDL_Keycode, mod: c.SDL_Keymod, kitty: bool, expected: []const u8 }{
        .{ .key = c.SDLK_SPACE, .mod = c.SDL_KMOD_CTRL, .kitty = false, .expected = "\x00" },
        .{ .key = c.SDLK_2, .mod = c.SDL_KMOD_CTRL, .kitty = false, .expected = "\x00" },
        .{ .key = c.SDLK_LEFTBRACKET, .mod = c.SDL_KMOD_CTRL, .kitty = false, .expected = "\x1b" },
        .{ .key = c.SDLK_M, .mod = c.SDL_KMOD_CTRL, .kitty = false, .expected = "\r" },
        .{ .key = c.SDLK_I, .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT, .kitty = false, .expected = "\x1b\t" },
        .{ .key = c.SDLK_RIGHTBRACKET, .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT, .kitty = false, .expected = "\x1b\x1d" },
        .{ .key = c.SDLK_ESCAPE, .mod = c.SDL_KMOD_SHIFT, .kitty = true, .expected = "\x1b[27;2u" },
        .{ .key = c.SDLK_ESCAPE, .mod = c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT, .kitty = true, .expected = "\x1b[27;7u" },
    };
    var buf: [16]u8 = undefined;
    for (cases) |case| {
        const n = try encodeKeyWithMod(case.key, case.mod, testKeyOptions(false, case.kitty), &buf);
        try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
    }
}

test "encodeKeyWithMod - ordinary printable keys remain on the SDL text path" {
    var buf: [16]u8 = undefined;
    for ([_]bool{ false, true }) |kitty_enabled| {
        for ([_]c.SDL_Keymod{ 0, c.SDL_KMOD_SHIFT, c.SDL_KMOD_ALT }) |mod| {
            try std.testing.expectEqual(@as(usize, 0), try encodeKeyWithMod(c.SDLK_A, mod, testKeyOptions(false, kitty_enabled), &buf));
        }
    }
}

test "encodeKeyWithMod - insufficient buffers fail explicitly" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_SHIFT, .default, &buf));
    try std.testing.expectError(error.WriteFailed, encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_GUI, .default, buf[0..0]));
}

test "encodeKeyWithMod - kitty report-all preserves original key identities" {
    const options: KeyEncodingOptions = .{ .kitty_flags = .{ .disambiguate = true, .report_all = true } };
    const cases = [_]struct { key: c.SDL_Keycode, mod: c.SDL_Keymod, expected: []const u8 }{
        .{ .key = c.SDLK_RETURN, .mod = 0, .expected = "\x1b[13u" },
        .{ .key = c.SDLK_TAB, .mod = 0, .expected = "\x1b[9u" },
        .{ .key = c.SDLK_BACKSPACE, .mod = 0, .expected = "\x1b[127u" },
        .{ .key = c.SDLK_HOME, .mod = 0, .expected = "\x1b[H" },
        .{ .key = c.SDLK_LEFT, .mod = c.SDL_KMOD_GUI, .expected = "\x1b[1;9D" },
        .{ .key = c.SDLK_RIGHT, .mod = c.SDL_KMOD_ALT, .expected = "\x1b[1;3C" },
    };
    var buf: [16]u8 = undefined;
    for (cases) |case| {
        const n = try encodeKeyWithMod(case.key, case.mod, options, &buf);
        try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
    }
}

test "encodeKeyWithMod - locks are ignored in legacy sequences and reported in kitty" {
    var buf: [16]u8 = undefined;
    const mod = c.SDL_KMOD_SHIFT | c.SDL_KMOD_CAPS | c.SDL_KMOD_NUM;
    const legacy_n = try encodeKeyWithMod(c.SDLK_LEFT, mod, .default, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[1;2D", buf[0..legacy_n]);
    const kitty_n = try encodeKeyWithMod(c.SDLK_LEFT, mod, testKeyOptions(false, true), &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[1;194D", buf[0..kitty_n]);
}

test "encodeKeyWithMod - unmodified navigation and function keys" {
    const cases = [_]struct { key: c.SDL_Keycode, expected: []const u8 }{
        .{ .key = c.SDLK_INSERT, .expected = "\x1b[2~" },
        .{ .key = c.SDLK_PAGEUP, .expected = "\x1b[5~" },
        .{ .key = c.SDLK_PAGEDOWN, .expected = "\x1b[6~" },
        .{ .key = c.SDLK_F1, .expected = "\x1bOP" },
        .{ .key = c.SDLK_F2, .expected = "\x1bOQ" },
        .{ .key = c.SDLK_F3, .expected = "\x1bOR" },
        .{ .key = c.SDLK_F4, .expected = "\x1bOS" },
        .{ .key = c.SDLK_F5, .expected = "\x1b[15~" },
        .{ .key = c.SDLK_F6, .expected = "\x1b[17~" },
        .{ .key = c.SDLK_F7, .expected = "\x1b[18~" },
        .{ .key = c.SDLK_F8, .expected = "\x1b[19~" },
        .{ .key = c.SDLK_F9, .expected = "\x1b[20~" },
        .{ .key = c.SDLK_F10, .expected = "\x1b[21~" },
        .{ .key = c.SDLK_F11, .expected = "\x1b[23~" },
        .{ .key = c.SDLK_F12, .expected = "\x1b[24~" },
        .{ .key = c.SDLK_RETURN2, .expected = "\r" },
        .{ .key = c.SDLK_KP_ENTER, .expected = "\r" },
    };
    var buf: [16]u8 = undefined;
    for (cases) |case| {
        const n = try encodeKeyWithMod(case.key, 0, .default, &buf);
        try std.testing.expectEqualSlices(u8, case.expected, buf[0..n]);
    }
}

test "encodeKeyWithMod - negotiated terminal modes reach the encoder" {
    const allocator = std.testing.allocator;
    var terminal = try ghostty_vt.Terminal.init(std.testing.io, allocator, .{ .cols = 10, .rows = 3 });
    defer terminal.deinit(allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    var buf: [16]u8 = undefined;

    stream.nextSlice("\x1b[?1h\x1b[?67h");
    const arrow_n = try encodeKeyWithMod(c.SDLK_LEFT, 0, .fromTerminal(&terminal), &buf);
    try std.testing.expectEqualSlices(u8, "\x1bOD", buf[0..arrow_n]);
    const backspace_n = try encodeKeyWithMod(c.SDLK_BACKSPACE, 0, .fromTerminal(&terminal), &buf);
    try std.testing.expectEqualSlices(u8, "\x08", buf[0..backspace_n]);

    stream.nextSlice("\x1b[>9u");
    const kitty_n = try encodeKeyWithMod(c.SDLK_RETURN, 0, .fromTerminal(&terminal), &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[13u", buf[0..kitty_n]);
    stream.nextSlice("\x1b[<u\x1b[>4;2m");
    const tab_n = try encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_SHIFT, .fromTerminal(&terminal), &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[27;2;9~", buf[0..tab_n]);
}

test "encodeKeyWithMod - shift+tab legacy mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_SHIFT, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, "\x1b[Z", buf[0..n]);
}

test "encodeKeyWithMod - shift+tab kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_SHIFT, testKeyOptions(false, true), &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualSlices(u8, "\x1b[9;2u", buf[0..n]);
}

test "encodeKeyWithMod - shift+enter legacy mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_SHIFT, testKeyOptions(false, false), &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[27;2;13~", buf[0..n]);
}

test "encodeKeyWithMod - shift+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_SHIFT, testKeyOptions(false, true), &buf);
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqualSlices(u8, "\x1b[13;2u", buf[0..n]);
}

test "encodeKeyWithMod - shift+backspace legacy mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_SHIFT, testKeyOptions(false, false), &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 127), buf[0]);
}

test "encodeKeyWithMod - shift+backspace kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_SHIFT, testKeyOptions(false, true), &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[127;2u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+shift+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT, testKeyOptions(false, true), &buf);
    // Ctrl(4) + Shift(1) + 1 = 6
    try std.testing.expectEqualSlices(u8, "\x1b[13;6u", buf[0..n]);
}

test "encodeKeyWithMod - alt+shift+tab kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, testKeyOptions(false, true), &buf);
    // Alt(2) + Shift(1) + 1 = 4
    try std.testing.expectEqualSlices(u8, "\x1b[9;4u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+alt+shift+backspace kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, testKeyOptions(false, true), &buf);
    // Ctrl(4) + Alt(2) + Shift(1) + 1 = 8
    try std.testing.expectEqualSlices(u8, "\x1b[127;8u", buf[0..n]);
}

test "encodeKeyWithMod - alt+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_ALT, testKeyOptions(false, true), &buf);
    // Alt(2) + 1 = 3
    try std.testing.expectEqualSlices(u8, "\x1b[13;3u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_CTRL, testKeyOptions(false, true), &buf);
    // Ctrl(4) + 1 = 5
    try std.testing.expectEqualSlices(u8, "\x1b[13;5u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+tab kitty mode" {
    var buf: [16]u8 = undefined;
    const n = try encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_CTRL, testKeyOptions(false, true), &buf);
    // Ctrl(4) + 1 = 5
    try std.testing.expectEqualSlices(u8, "\x1b[9;5u", buf[0..n]);
}

pub const MouseScrollDirection = enum { up, down };

/// Encodes a mouse scroll event for terminal mouse tracking.
/// When sgr_format is true, uses SGR format: CSI < button ; col ; row M
/// When sgr_format is false, uses X10 format: CSI M <button+32> <col+33> <row+33>
/// Button 64 = scroll up, 65 = scroll down (in both formats)
/// col and row are 0-based inputs; encoding adjusts as needed.
pub fn encodeMouseScroll(
    direction: MouseScrollDirection,
    col: u16,
    row: u16,
    sgr_format: bool,
    buf: []u8,
) usize {
    const button: u8 = switch (direction) {
        .up => 64,
        .down => 65,
    };

    if (sgr_format) {
        // SGR mouse format: ESC [ < button ; col ; row M (1-based coordinates)
        const result = std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}M", .{ button, col + 1, row + 1 }) catch return 0;
        return result.len;
    } else {
        // X10 mouse format: ESC [ M <button+32> <col+33> <row+33>
        // Clamp coordinates so (coord + 33) fits in a single byte.
        const x10_offset: u16 = 33;
        const x10_coord_max: u16 = 255 - x10_offset;
        const x = @min(col, x10_coord_max) + x10_offset;
        const y = @min(row, x10_coord_max) + x10_offset;
        if (buf.len < 6) return 0;
        buf[0] = '\x1b';
        buf[1] = '[';
        buf[2] = 'M';
        buf[3] = button + 32;
        buf[4] = @intCast(x);
        buf[5] = @intCast(y);
        return 6;
    }
}

test "encodeMouseScroll - scroll up SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseScroll(.up, 0, 0, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<64;1;1M", buf[0..n]);
}

test "encodeMouseScroll - scroll down SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseScroll(.down, 0, 0, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<65;1;1M", buf[0..n]);
}

test "encodeMouseScroll - with position SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseScroll(.up, 10, 5, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<64;11;6M", buf[0..n]);
}

test "encodeMouseScroll - scroll up X10" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseScroll(.up, 0, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualSlices(u8, "\x1b[M", buf[0..3]);
    try std.testing.expectEqual(@as(u8, 64 + 32), buf[3]); // button
    try std.testing.expectEqual(@as(u8, 33), buf[4]); // col + 33
    try std.testing.expectEqual(@as(u8, 33), buf[5]); // row + 33
}

test "encodeMouseScroll - scroll down X10 with position" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseScroll(.down, 10, 5, false, &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(u8, 65 + 32), buf[3]); // button
    try std.testing.expectEqual(@as(u8, 10 + 33), buf[4]); // col + 33
    try std.testing.expectEqual(@as(u8, 5 + 33), buf[5]); // row + 33
}

pub const MouseButton = enum(u8) { left = 0, middle = 1, right = 2 };

/// Encodes a mouse button press or release event for terminal mouse tracking.
/// SGR format: CSI < button ; col ; row M (press) or m (release). 1-based coordinates.
/// X10 format: CSI M <button+32> <col+33> <row+33>. Release uses button code 3.
pub fn encodeMouseButton(
    button: MouseButton,
    col: u16,
    row: u16,
    press: bool,
    sgr_format: bool,
    buf: []u8,
) usize {
    const btn: u8 = @intFromEnum(button);

    if (sgr_format) {
        const suffix: u8 = if (press) 'M' else 'm';
        const result = std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{ btn, col + 1, row + 1, suffix }) catch return 0;
        return result.len;
    } else {
        const x10_btn: u8 = if (press) btn else 3; // 3 = release indicator in X10
        const x10_offset: u16 = 33;
        const x10_coord_max: u16 = 255 - x10_offset;
        const x = @min(col, x10_coord_max) + x10_offset;
        const y = @min(row, x10_coord_max) + x10_offset;
        if (buf.len < 6) return 0;
        buf[0] = '\x1b';
        buf[1] = '[';
        buf[2] = 'M';
        buf[3] = x10_btn + 32;
        buf[4] = @intCast(x);
        buf[5] = @intCast(y);
        return 6;
    }
}

/// Encodes a mouse motion event for terminal mouse tracking.
/// Motion uses button code + 32 (the motion flag). Button code 3 means no button held.
/// SGR format: CSI < code ; col ; row M. X10 format: CSI M <code+32> <col+33> <row+33>.
pub fn encodeMouseMotion(
    button: ?MouseButton,
    col: u16,
    row: u16,
    sgr_format: bool,
    buf: []u8,
) usize {
    const base: u8 = if (button) |b| @intFromEnum(b) else 3; // 3 = no button
    const code: u8 = base + 32; // motion flag

    if (sgr_format) {
        const result = std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}M", .{ code, col + 1, row + 1 }) catch return 0;
        return result.len;
    } else {
        const x10_offset: u16 = 33;
        const x10_coord_max: u16 = 255 - x10_offset;
        const x = @min(col, x10_coord_max) + x10_offset;
        const y = @min(row, x10_coord_max) + x10_offset;
        if (buf.len < 6) return 0;
        buf[0] = '\x1b';
        buf[1] = '[';
        buf[2] = 'M';
        buf[3] = code + 32;
        buf[4] = @intCast(x);
        buf[5] = @intCast(y);
        return 6;
    }
}

test "encodeMouseButton - left press SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseButton(.left, 5, 3, true, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<0;6;4M", buf[0..n]);
}

test "encodeMouseButton - left release SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseButton(.left, 5, 3, false, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<0;6;4m", buf[0..n]);
}

test "encodeMouseButton - right press SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseButton(.right, 0, 0, true, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<2;1;1M", buf[0..n]);
}

test "encodeMouseButton - left press X10" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseButton(.left, 5, 3, true, false, &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualSlices(u8, "\x1b[M", buf[0..3]);
    try std.testing.expectEqual(@as(u8, 0 + 32), buf[3]);
    try std.testing.expectEqual(@as(u8, 5 + 33), buf[4]);
    try std.testing.expectEqual(@as(u8, 3 + 33), buf[5]);
}

test "encodeMouseButton - release X10 sends button 3" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseButton(.left, 5, 3, false, false, &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualSlices(u8, "\x1b[M", buf[0..3]);
    try std.testing.expectEqual(@as(u8, 3 + 32), buf[3]); // release = button 3
    try std.testing.expectEqual(@as(u8, 5 + 33), buf[4]);
    try std.testing.expectEqual(@as(u8, 3 + 33), buf[5]);
}

test "encodeMouseMotion - no button SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseMotion(null, 10, 5, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<35;11;6M", buf[0..n]);
}

test "encodeMouseMotion - left button held SGR" {
    var buf: [32]u8 = undefined;
    const n = encodeMouseMotion(.left, 2, 1, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[<32;3;2M", buf[0..n]);
}

test "terminalSwitchShortcut - cmd+1 returns 0" {
    try std.testing.expectEqual(@as(?usize, 0), terminalSwitchShortcut(c.SDLK_1, c.SDL_KMOD_GUI, 9));
}

test "terminalSwitchShortcut - cmd+9 returns 8" {
    try std.testing.expectEqual(@as(?usize, 8), terminalSwitchShortcut(c.SDLK_9, c.SDL_KMOD_GUI, 9));
}

test "terminalSwitchShortcut - cmd+0 returns 9" {
    try std.testing.expectEqual(@as(?usize, 9), terminalSwitchShortcut(c.SDLK_0, c.SDL_KMOD_GUI, 10));
}

test "terminalSwitchShortcut - cmd+0 returns null when max is 9" {
    try std.testing.expect(terminalSwitchShortcut(c.SDLK_0, c.SDL_KMOD_GUI, 9) == null);
}

test "terminalSwitchShortcut - without gui modifier returns null" {
    try std.testing.expect(terminalSwitchShortcut(c.SDLK_1, 0, 9) == null);
}

test "terminalSwitchShortcut - with shift modifier returns null" {
    try std.testing.expect(terminalSwitchShortcut(c.SDLK_1, c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT, 9) == null);
}

test "terminalSwitchShortcut - with ctrl modifier returns null" {
    try std.testing.expect(terminalSwitchShortcut(c.SDLK_1, c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL, 9) == null);
}

test "terminalSwitchShortcut - non-digit key returns null" {
    try std.testing.expect(terminalSwitchShortcut(c.SDLK_A, c.SDL_KMOD_GUI, 9) == null);
}

test "terminalHotkeyLabel - index 0 returns cmd+1" {
    try std.testing.expectEqualStrings("⌘1", terminalHotkeyLabel(0).?);
}

test "terminalHotkeyLabel - index 9 returns cmd+0" {
    try std.testing.expectEqualStrings("⌘0", terminalHotkeyLabel(9).?);
}

test "terminalHotkeyLabel - out of range returns null" {
    try std.testing.expect(terminalHotkeyLabel(10) == null);
}
