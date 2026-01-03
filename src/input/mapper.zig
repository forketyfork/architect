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

pub fn isSwitchTerminalShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?bool {
    if ((mod & c.SDL_KMOD_GUI) == 0 or (mod & c.SDL_KMOD_SHIFT) == 0) return null;
    if (key == c.SDLK_RIGHTBRACKET) return true;
    if (key == c.SDLK_LEFTBRACKET) return false;
    return null;
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
    return mode != .Grid and mode != .Collapsing and mode != .PreCollapse and mode != .CancelPreCollapse;
}

pub fn canStartPreCollapse(mode: app_state.ViewMode) bool {
    return mode != .Grid and mode != .PreCollapse and mode != .Collapsing and mode != .CancelPreCollapse;
}

pub fn encodeKeyWithMod(key: c.SDL_Keycode, mod: c.SDL_Keymod, buf: []u8) usize {
    if (mod & c.SDL_KMOD_CTRL != 0) {
        if (key >= c.SDLK_A and key <= c.SDLK_Z) {
            buf[0] = @as(u8, @intCast(key - c.SDLK_A + 1));
            return 1;
        }
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
        else => 0,
    };
}

test "encodeKeyWithMod - return key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, 0, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "encodeKeyWithMod - tab key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_TAB, 0, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\t'), buf[0]);
}

test "encodeKeyWithMod - backspace key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, 0, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 127), buf[0]);
}

test "encodeKeyWithMod - escape key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_ESCAPE, 0, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 27), buf[0]);
}

test "encodeKeyWithMod - arrow keys" {
    var buf: [8]u8 = undefined;

    const n_up = encodeKeyWithMod(c.SDLK_UP, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_up);
    try std.testing.expectEqualSlices(u8, "\x1b[A", buf[0..n_up]);

    const n_down = encodeKeyWithMod(c.SDLK_DOWN, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_down);
    try std.testing.expectEqualSlices(u8, "\x1b[B", buf[0..n_down]);

    const n_right = encodeKeyWithMod(c.SDLK_RIGHT, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_right);
    try std.testing.expectEqualSlices(u8, "\x1b[C", buf[0..n_right]);

    const n_left = encodeKeyWithMod(c.SDLK_LEFT, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_left);
    try std.testing.expectEqualSlices(u8, "\x1b[D", buf[0..n_left]);
}

test "encodeKeyWithMod - ctrl+a" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_A, c.SDL_KMOD_CTRL, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+left (beginning of line)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_GUI, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+right (end of line)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_GUI, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 5), buf[0]);
}

test "encodeKeyWithMod - alt+left (backward word)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_ALT, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bb", buf[0..n]);
}

test "encodeKeyWithMod - alt+right (forward word)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_ALT, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bf", buf[0..n]);
}

test "encodeKeyWithMod - cmd+backspace (delete line)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_GUI, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 21), buf[0]);
}

test "encodeKeyWithMod - alt+backspace (delete word)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_ALT, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 23), buf[0]);
}

test "encodeKeyWithMod - unknown key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(0, 0, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "fontSizeShortcut - plus/minus variants" {
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_KP_PLUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_KP_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expect(fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_SHIFT) == null);
}
