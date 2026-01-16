const std = @import("std");
const c = @import("../c.zig");
const app_state = @import("../app/app_state.zig");

pub const FontSizeDirection = enum { increase, decrease };
pub const GridNavDirection = enum { up, down, left, right };

pub fn fontSizeShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?FontSizeDirection {
    if ((mod & c.SDL_KMOD_GUI) == 0) return null;

    return switch (key) {
        c.SDLK_EQUALS, c.SDLK_KP_PLUS => if ((mod & c.SDL_KMOD_SHIFT) != 0) .increase else null,
        c.SDLK_MINUS, c.SDLK_KP_MINUS => .decrease,
        else => null,
    };
}

pub fn gridNavShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?GridNavDirection {
    if ((mod & c.SDL_KMOD_GUI) == 0) return null;
    if ((mod & c.SDL_KMOD_SHIFT) != 0) return null;
    return switch (key) {
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        else => null,
    };
}

pub fn canHandleEscapePress(mode: app_state.ViewMode) bool {
    return mode != .Grid and mode != .Collapsing;
}

/// Compute CSI-u modifier value from SDL modifiers.
/// Returns modifier+1 as per kitty keyboard protocol.
fn computeCsiModifier(mod: c.SDL_Keymod) u8 {
    var result: u8 = 1; // Base value (modifier+1 format)
    if ((mod & c.SDL_KMOD_SHIFT) != 0) result += 1;
    if ((mod & c.SDL_KMOD_ALT) != 0) result += 2;
    if ((mod & c.SDL_KMOD_CTRL) != 0) result += 4;
    if ((mod & c.SDL_KMOD_GUI) != 0) result += 8;
    return result;
}

pub fn keyToChar(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?u8 {
    const shift = (mod & c.SDL_KMOD_SHIFT) != 0;

    if (key >= c.SDLK_A and key <= c.SDLK_Z) {
        const base: u8 = @intCast(key - c.SDLK_A);
        return if (shift) 'A' + base else 'a' + base;
    }

    if (key >= c.SDLK_0 and key <= c.SDLK_9) {
        if (shift) {
            return switch (key) {
                c.SDLK_0 => ')',
                c.SDLK_1 => '!',
                c.SDLK_2 => '@',
                c.SDLK_3 => '#',
                c.SDLK_4 => '$',
                c.SDLK_5 => '%',
                c.SDLK_6 => '^',
                c.SDLK_7 => '&',
                c.SDLK_8 => '*',
                c.SDLK_9 => '(',
                else => null,
            };
        }
        const base: u8 = @intCast(key - c.SDLK_0);
        return '0' + base;
    }

    return switch (key) {
        c.SDLK_SPACE => ' ',
        c.SDLK_MINUS => if (shift) '_' else '-',
        c.SDLK_EQUALS => if (shift) '+' else '=',
        c.SDLK_LEFTBRACKET => if (shift) '{' else '[',
        c.SDLK_RIGHTBRACKET => if (shift) '}' else ']',
        c.SDLK_BACKSLASH => if (shift) '|' else '\\',
        c.SDLK_SEMICOLON => if (shift) ':' else ';',
        c.SDLK_APOSTROPHE => if (shift) '"' else '\'',
        c.SDLK_GRAVE => if (shift) '~' else '`',
        c.SDLK_COMMA => if (shift) '<' else ',',
        c.SDLK_PERIOD => if (shift) '>' else '.',
        c.SDLK_SLASH => if (shift) '?' else '/',
        else => null,
    };
}

pub fn encodeKeyWithMod(key: c.SDL_Keycode, mod: c.SDL_Keymod, kitty_enabled: bool, buf: []u8) usize {
    if (mod & c.SDL_KMOD_CTRL != 0) {
        if (key >= c.SDLK_A and key <= c.SDLK_Z) {
            buf[0] = @as(u8, @intCast(key - c.SDLK_A + 1));
            return 1;
        }
        const ctrl_result: usize = switch (key) {
            c.SDLK_LEFTBRACKET => blk: {
                buf[0] = 27;
                break :blk 1;
            },
            c.SDLK_RIGHTBRACKET => blk: {
                buf[0] = 29;
                break :blk 1;
            },
            c.SDLK_BACKSLASH => blk: {
                buf[0] = 28;
                break :blk 1;
            },
            else => 0,
        };
        if (ctrl_result > 0) return ctrl_result;
    }

    if (mod & c.SDL_KMOD_GUI != 0) {
        return switch (key) {
            c.SDLK_LEFT => blk: {
                buf[0] = 1;
                break :blk 1;
            },
            c.SDLK_RIGHT => blk: {
                buf[0] = 5;
                break :blk 1;
            },
            c.SDLK_BACKSPACE => blk: {
                buf[0] = 21;
                break :blk 1;
            },
            else => 0,
        };
    }

    if (mod & c.SDL_KMOD_ALT != 0) {
        return switch (key) {
            c.SDLK_LEFT => blk: {
                @memcpy(buf[0..2], "\x1bb");
                break :blk 2;
            },
            c.SDLK_RIGHT => blk: {
                @memcpy(buf[0..2], "\x1bf");
                break :blk 2;
            },
            c.SDLK_BACKSPACE => blk: {
                buf[0] = 23;
                break :blk 1;
            },
            else => 0,
        };
    }

    // Modified special keys: Tab, Enter, Backspace
    // When kitty enabled: any modifier combo emits CSI-u
    // When kitty disabled: only Shift+Tab has special encoding, others fall through to legacy
    const special_keycode: ?u8 = switch (key) {
        c.SDLK_TAB => 9,
        c.SDLK_RETURN => 13,
        c.SDLK_BACKSPACE => 127,
        else => null,
    };
    if (special_keycode) |kc| {
        const has_modifier = (mod & (c.SDL_KMOD_SHIFT | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_GUI)) != 0;
        if (kitty_enabled and has_modifier) {
            // Full CSI-u encoding with all modifier bits: ESC [ keycode ; modifier+1 u
            const csi_mod = computeCsiModifier(mod);
            const result = std.fmt.bufPrint(buf, "\x1b[{d};{d}u", .{ kc, csi_mod }) catch return 0;
            return result.len;
        } else if (!kitty_enabled and (mod & c.SDL_KMOD_SHIFT) != 0) {
            // Legacy encoding for Shift-modified keys
            return switch (key) {
                c.SDLK_TAB => blk: {
                    @memcpy(buf[0..3], "\x1b[Z");
                    break :blk 3;
                },
                c.SDLK_RETURN => blk: {
                    buf[0] = '\r';
                    break :blk 1;
                },
                c.SDLK_BACKSPACE => blk: {
                    buf[0] = 127;
                    break :blk 1;
                },
                else => 0,
            };
        }
    }

    return switch (key) {
        c.SDLK_RETURN => blk: {
            buf[0] = '\r';
            break :blk 1;
        },
        c.SDLK_TAB => blk: {
            buf[0] = '\t';
            break :blk 1;
        },
        c.SDLK_BACKSPACE => blk: {
            buf[0] = 127;
            break :blk 1;
        },
        c.SDLK_ESCAPE => blk: {
            buf[0] = 27;
            break :blk 1;
        },
        c.SDLK_UP => blk: {
            @memcpy(buf[0..3], "\x1b[A");
            break :blk 3;
        },
        c.SDLK_DOWN => blk: {
            @memcpy(buf[0..3], "\x1b[B");
            break :blk 3;
        },
        c.SDLK_RIGHT => blk: {
            @memcpy(buf[0..3], "\x1b[C");
            break :blk 3;
        },
        c.SDLK_LEFT => blk: {
            @memcpy(buf[0..3], "\x1b[D");
            break :blk 3;
        },
        c.SDLK_HOME => blk: {
            buf[0] = 1;
            break :blk 1;
        },
        c.SDLK_END => blk: {
            buf[0] = 5;
            break :blk 1;
        },
        c.SDLK_DELETE => blk: {
            @memcpy(buf[0..4], "\x1b[3~");
            break :blk 4;
        },
        else => 0,
    };
}

test "encodeKeyWithMod - return key" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "encodeKeyWithMod - tab key" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_TAB, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\t'), buf[0]);
}

test "encodeKeyWithMod - backspace key" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 127), buf[0]);
}

test "encodeKeyWithMod - escape key" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_ESCAPE, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 27), buf[0]);
}

test "encodeKeyWithMod - arrow keys" {
    var buf: [16]u8 = undefined;

    const n_up = encodeKeyWithMod(c.SDLK_UP, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_up);
    try std.testing.expectEqualSlices(u8, "\x1b[A", buf[0..n_up]);

    const n_down = encodeKeyWithMod(c.SDLK_DOWN, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_down);
    try std.testing.expectEqualSlices(u8, "\x1b[B", buf[0..n_down]);

    const n_right = encodeKeyWithMod(c.SDLK_RIGHT, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_right);
    try std.testing.expectEqualSlices(u8, "\x1b[C", buf[0..n_right]);

    const n_left = encodeKeyWithMod(c.SDLK_LEFT, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_left);
    try std.testing.expectEqualSlices(u8, "\x1b[D", buf[0..n_left]);
}

test "encodeKeyWithMod - ctrl+a" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_A, c.SDL_KMOD_CTRL, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+left (beginning of line)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_GUI, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+right (end of line)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_GUI, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 5), buf[0]);
}

test "encodeKeyWithMod - home (beginning of line)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_HOME, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - end (end of line)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_END, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 5), buf[0]);
}

test "encodeKeyWithMod - alt+left (backward word)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_ALT, false, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bb", buf[0..n]);
}

test "encodeKeyWithMod - alt+right (forward word)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_ALT, false, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bf", buf[0..n]);
}

test "encodeKeyWithMod - cmd+backspace (delete line)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_GUI, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 21), buf[0]);
}

test "encodeKeyWithMod - alt+backspace (delete word)" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_ALT, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 23), buf[0]);
}

test "encodeKeyWithMod - unknown key" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(0, 0, false, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "fontSizeShortcut - plus/minus variants" {
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_KP_PLUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_KP_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expect(fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_SHIFT) == null);
}

test "encodeKeyWithMod - shift+tab legacy mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_SHIFT, false, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, "\x1b[Z", buf[0..n]);
}

test "encodeKeyWithMod - shift+tab kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_SHIFT, true, &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualSlices(u8, "\x1b[9;2u", buf[0..n]);
}

test "encodeKeyWithMod - shift+enter legacy mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_SHIFT, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "encodeKeyWithMod - shift+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_SHIFT, true, &buf);
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqualSlices(u8, "\x1b[13;2u", buf[0..n]);
}

test "encodeKeyWithMod - shift+backspace legacy mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_SHIFT, false, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 127), buf[0]);
}

test "encodeKeyWithMod - shift+backspace kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_SHIFT, true, &buf);
    try std.testing.expectEqualSlices(u8, "\x1b[127;2u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+shift+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_CTRL | c.SDL_KMOD_SHIFT, true, &buf);
    // Ctrl(4) + Shift(1) + 1 = 6
    try std.testing.expectEqualSlices(u8, "\x1b[13;6u", buf[0..n]);
}

test "encodeKeyWithMod - alt+shift+tab kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, true, &buf);
    // Alt(2) + Shift(1) + 1 = 4
    try std.testing.expectEqualSlices(u8, "\x1b[9;4u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+alt+shift+backspace kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT, true, &buf);
    // Ctrl(4) + Alt(2) + Shift(1) + 1 = 8
    try std.testing.expectEqualSlices(u8, "\x1b[127;8u", buf[0..n]);
}

test "encodeKeyWithMod - alt+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_ALT, true, &buf);
    // Alt(2) + 1 = 3
    try std.testing.expectEqualSlices(u8, "\x1b[13;3u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+enter kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, c.SDL_KMOD_CTRL, true, &buf);
    // Ctrl(4) + 1 = 5
    try std.testing.expectEqualSlices(u8, "\x1b[13;5u", buf[0..n]);
}

test "encodeKeyWithMod - ctrl+tab kitty mode" {
    var buf: [16]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_TAB, c.SDL_KMOD_CTRL, true, &buf);
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
