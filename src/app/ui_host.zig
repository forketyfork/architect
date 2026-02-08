const app_state = @import("app_state.zig");
const c = @import("../c.zig");
const colors_mod = @import("../colors.zig");
const session_state = @import("../session/state.zig");
const ui_mod = @import("../ui/mod.zig");
const view_state = @import("../ui/session_view_state.zig");

const AnimationState = app_state.AnimationState;
const Rect = app_state.Rect;
const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;

pub fn applyMouseContext(ui: *ui_mod.UiRoot, host: *ui_mod.UiHost, event: *const c.SDL_Event) void {
    switch (event.type) {
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            const mouse_x: c_int = @intFromFloat(event.button.x);
            const mouse_y: c_int = @intFromFloat(event.button.y);
            host.mouse_x = mouse_x;
            host.mouse_y = mouse_y;
            host.mouse_has_position = true;
            host.mouse_over_ui = ui.hitTest(host, mouse_x, mouse_y);
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            const mouse_x: c_int = @intFromFloat(event.motion.x);
            const mouse_y: c_int = @intFromFloat(event.motion.y);
            host.mouse_x = mouse_x;
            host.mouse_y = mouse_y;
            host.mouse_has_position = true;
            host.mouse_over_ui = ui.hitTest(host, mouse_x, mouse_y);
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            const mouse_x: c_int = @intFromFloat(event.wheel.mouse_x);
            const mouse_y: c_int = @intFromFloat(event.wheel.mouse_y);
            host.mouse_x = mouse_x;
            host.mouse_y = mouse_y;
            host.mouse_has_position = true;
            host.mouse_over_ui = ui.hitTest(host, mouse_x, mouse_y);
        },
        c.SDL_EVENT_DROP_POSITION => {
            const mouse_x: c_int = @intFromFloat(event.drop.x);
            const mouse_y: c_int = @intFromFloat(event.drop.y);
            host.mouse_x = mouse_x;
            host.mouse_y = mouse_y;
            host.mouse_has_position = true;
            host.mouse_over_ui = ui.hitTest(host, mouse_x, mouse_y);
        },
        else => {},
    }
}

pub fn makeUiHost(
    now: i64,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    grid_cols: usize,
    grid_rows: usize,
    term_cols: u16,
    term_rows: u16,
    anim_state: *const AnimationState,
    sessions: []const *SessionState,
    buffer: []ui_mod.SessionUiInfo,
    views: []const SessionViewState,
    focused_has_foreground_process: bool,
    theme: *const colors_mod.Theme,
) ui_mod.UiHost {
    for (sessions, 0..) |session, i| {
        buffer[i] = .{
            .dead = session.dead,
            .spawned = session.spawned,
            .cwd_path = session.cwd_path,
            .cwd_basename = session.cwd_basename,
            .session_status = if (i < views.len) views[i].status else .idle,
        };
    }

    const focused_session = sessions[anim_state.focused_session];
    const focused_cwd = focused_session.cwd_path;
    const animating_rect: ?Rect = switch (anim_state.mode) {
        .Expanding, .Collapsing => anim_state.getCurrentRect(now),
        else => null,
    };

    return .{
        .now_ms = now,
        .window_w = render_width,
        .window_h = render_height,
        .ui_scale = ui_scale,
        .grid_cols = grid_cols,
        .grid_rows = grid_rows,
        .cell_w = cell_width_pixels,
        .cell_h = cell_height_pixels,
        .term_cols = term_cols,
        .term_rows = term_rows,
        .view_mode = anim_state.mode,
        .focused_session = anim_state.focused_session,
        .focused_cwd = focused_cwd,
        .focused_has_foreground_process = focused_has_foreground_process,
        .animating_rect = animating_rect,
        .sessions = buffer[0..sessions.len],
        .theme = theme,
    };
}
