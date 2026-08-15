const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");

/// Draws the shared chrome for a centered modal: a full-window darkening
/// scrim behind a rounded, filled, bordered panel. `radius_px` is already
/// DPI-scaled by the caller.
pub fn renderScrimAndPanel(renderer: *c.SDL_Renderer, host: *const types.UiHost, modal: geom.Rect, radius_px: c_int) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 170);
    const scrim = c.SDL_FRect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(host.window_w),
        .h = @floatFromInt(host.window_h),
    };
    _ = c.SDL_RenderFillRect(renderer, &scrim);

    const fill = host.theme.selection;
    _ = c.SDL_SetRenderDrawColor(renderer, fill.r, fill.g, fill.b, 240);
    primitives.fillRoundedRect(renderer, modal, radius_px);
    const border = host.theme.accent;
    _ = c.SDL_SetRenderDrawColor(renderer, border.r, border.g, border.b, 255);
    primitives.drawRoundedBorder(renderer, modal, radius_px);
}

/// True when a key event should dismiss a modal: Escape or Cmd+W.
pub fn isDismissKey(key: c.SDL_Keycode, mod: c.SDL_Keymod) bool {
    return key == c.SDLK_ESCAPE or (key == c.SDLK_W and (mod & c.SDL_KMOD_GUI) != 0);
}
