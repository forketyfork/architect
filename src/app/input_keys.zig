const input = @import("../input/mapper.zig");
const session_state = @import("../session/state.zig");
const c = @import("../c.zig");
const std = @import("std");
const app_state = @import("app_state.zig");

const SessionState = session_state.SessionState;

pub const DeferredEscape = struct {
    mod: c.SDL_Keymod = 0,

    pub fn observePress(self: *DeferredEscape, key: c.SDL_Keycode, mod: c.SDL_Keymod, repeat: bool) void {
        if (key == c.SDLK_ESCAPE and !repeat) self.mod = mod;
    }

    pub fn shouldSend(self: DeferredEscape, mode: app_state.ViewMode) bool {
        return input.canHandleEscapePress(mode) or
            (self.mod & (c.SDL_KMOD_SHIFT | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_GUI)) != 0;
    }
};

test "deferred escape retains press modifiers until release" {
    var escape: DeferredEscape = .{};
    escape.observePress(c.SDLK_ESCAPE, c.SDL_KMOD_SHIFT, false);
    escape.observePress(c.SDLK_LSHIFT, 0, false);
    escape.observePress(c.SDLK_ESCAPE, 0, true);
    try std.testing.expectEqual(@as(c.SDL_Keymod, c.SDL_KMOD_SHIFT), escape.mod);
    escape.observePress(c.SDLK_ESCAPE, 0, false);
    try std.testing.expectEqual(@as(c.SDL_Keymod, 0), escape.mod);
}

test "modified escape reaches the terminal in grid and transition modes" {
    var escape: DeferredEscape = .{};
    for ([_]app_state.ViewMode{ .Grid, .Collapsing, .GridResizing }) |mode| {
        try std.testing.expect(!escape.shouldSend(mode));
        for ([_]c.SDL_Keymod{ c.SDL_KMOD_SHIFT, c.SDL_KMOD_CTRL, c.SDL_KMOD_ALT, c.SDL_KMOD_GUI }) |mod| {
            escape.observePress(c.SDLK_ESCAPE, mod, false);
            try std.testing.expect(escape.shouldSend(mode));
        }
        escape.observePress(c.SDLK_ESCAPE, 0, false);
    }
}

pub fn isModifierKey(key: c.SDL_Keycode) bool {
    return key == c.SDLK_LSHIFT or key == c.SDLK_RSHIFT or
        key == c.SDLK_LCTRL or key == c.SDLK_RCTRL or
        key == c.SDLK_LALT or key == c.SDLK_RALT or
        key == c.SDLK_LGUI or key == c.SDLK_RGUI;
}

pub fn handleKeyInput(focused: *SessionState, key: c.SDL_Keycode, mod: c.SDL_Keymod) !void {
    var options: input.KeyEncodingOptions = if (focused.terminal) |*terminal|
        .fromTerminal(terminal)
    else
        .default;
    options.macos_option_as_alt = .true;

    var buf: [64]u8 = undefined;
    const n = try input.encodeKeyWithMod(key, mod, options, &buf);
    if (n > 0) {
        try focused.sendInput(buf[0..n]);
    }
}
