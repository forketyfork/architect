const ghostty_vt = @import("ghostty-vt");
const input = @import("../input/mapper.zig");
const session_state = @import("../session/state.zig");
const c = @import("../c.zig");

const SessionState = session_state.SessionState;

pub fn isModifierKey(key: c.SDL_Keycode) bool {
    return key == c.SDLK_LSHIFT or key == c.SDLK_RSHIFT or
        key == c.SDLK_LCTRL or key == c.SDLK_RCTRL or
        key == c.SDLK_LALT or key == c.SDLK_RALT or
        key == c.SDLK_LGUI or key == c.SDLK_RGUI;
}

pub fn handleKeyInput(focused: *SessionState, key: c.SDL_Keycode, mod: c.SDL_Keymod) !void {
    if (key == c.SDLK_ESCAPE) return;

    const kitty_enabled = if (focused.terminal) |*terminal|
        terminal.screens.active.kitty_keyboard.current().int() != 0
    else
        false;

    var buf: [16]u8 = undefined;
    const n = input.encodeKeyWithMod(key, mod, kitty_enabled, &buf);
    if (n > 0) {
        try focused.sendInput(buf[0..n]);
    }
}
