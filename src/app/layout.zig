const std = @import("std");
const app_state = @import("app_state.zig");
const c = @import("../c.zig");
const font_mod = @import("../font.zig");
const pty_mod = @import("../pty.zig");
const renderer_mod = @import("../render/renderer.zig");
const session_state = @import("../session/state.zig");
const vt_stream = @import("../vt_stream.zig");

const AnimationState = app_state.AnimationState;
const SessionState = session_state.SessionState;

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
};

pub fn updateRenderSizes(
    window: *c.SDL_Window,
    window_w: *c_int,
    window_h: *c_int,
    render_w: *c_int,
    render_h: *c_int,
    scale_x: *f32,
    scale_y: *f32,
) void {
    _ = c.SDL_GetWindowSize(window, window_w, window_h);
    _ = c.SDL_GetWindowSizeInPixels(window, render_w, render_h);
    scale_x.* = if (window_w.* != 0) @as(f32, @floatFromInt(render_w.*)) / @as(f32, @floatFromInt(window_w.*)) else 1.0;
    scale_y.* = if (window_h.* != 0) @as(f32, @floatFromInt(render_h.*)) / @as(f32, @floatFromInt(window_h.*)) else 1.0;
}

pub fn scaleEventToRender(event: *const c.SDL_Event, scale_x: f32, scale_y: f32) c.SDL_Event {
    var e = event.*;
    switch (e.type) {
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            e.button.x *= scale_x;
            e.button.y *= scale_y;
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            e.button.x *= scale_x;
            e.button.y *= scale_y;
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            e.motion.x *= scale_x;
            e.motion.y *= scale_y;
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            e.wheel.mouse_x *= scale_x;
            e.wheel.mouse_y *= scale_y;
        },
        c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT, c.SDL_EVENT_DROP_POSITION => {
            e.drop.x *= scale_x;
            e.drop.y *= scale_y;
        },
        else => {},
    }
    return e;
}

pub fn calculateHoveredSession(
    mouse_x: c_int,
    mouse_y: c_int,
    anim_state: *const AnimationState,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    render_width: c_int,
    render_height: c_int,
    grid_cols: usize,
    grid_rows: usize,
) ?usize {
    return switch (anim_state.mode) {
        .Grid, .GridResizing => {
            if (mouse_x < 0 or mouse_x >= render_width or
                mouse_y < 0 or mouse_y >= render_height) return null;

            const grid_col_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), grid_cols - 1);
            const grid_row_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), grid_rows - 1);
            return grid_row_idx * grid_cols + grid_col_idx;
        },
        .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => anim_state.focused_session,
        .Expanding, .Collapsing => {
            const rect = anim_state.getCurrentRect(std.time.milliTimestamp());
            if (mouse_x >= rect.x and mouse_x < rect.x + rect.w and
                mouse_y >= rect.y and mouse_y < rect.y + rect.h)
            {
                return anim_state.focused_session;
            }
            return null;
        },
    };
}

pub fn calculateTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int, grid_font_scale: f32) TerminalSize {
    const padding = renderer_mod.TERMINAL_PADDING * 2;
    const usable_w = @max(0, window_width - padding);
    const usable_h = @max(0, window_height - padding);
    const scaled_cell_w = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(font.cell_width)) * grid_font_scale)));
    const scaled_cell_h = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(font.cell_height)) * grid_font_scale)));
    const cols = @max(1, @divFloor(usable_w, scaled_cell_w));
    const rows = @max(1, @divFloor(usable_h, scaled_cell_h));
    return .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
    };
}

pub fn calculateGridCellTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int, grid_font_scale: f32, grid_cols: usize, grid_rows: usize) TerminalSize {
    const cell_width = @divFloor(window_width, @as(c_int, @intCast(grid_cols)));
    const cell_height = @divFloor(window_height, @as(c_int, @intCast(grid_rows)));
    return calculateTerminalSize(font, cell_width, cell_height, grid_font_scale);
}

pub fn calculateTerminalSizeForMode(font: *const font_mod.Font, window_width: c_int, window_height: c_int, mode: app_state.ViewMode, grid_font_scale: f32, grid_cols: usize, grid_rows: usize) TerminalSize {
    return switch (mode) {
        .Grid, .Expanding, .Collapsing, .GridResizing => {
            const grid_dim = @max(grid_cols, grid_rows);
            const base_grid_scale: f32 = 1.0 / @as(f32, @floatFromInt(grid_dim));
            const effective_scale: f32 = base_grid_scale * grid_font_scale;
            return calculateGridCellTerminalSize(font, window_width, window_height, effective_scale, grid_cols, grid_rows);
        },
        else => calculateTerminalSize(font, window_width, window_height, 1.0),
    };
}

pub fn scaledFontSize(points: c_int, scale: f32) c_int {
    const scaled = std.math.round(@as(f32, @floatFromInt(points)) * scale);
    return @max(1, @as(c_int, @intFromFloat(scaled)));
}

pub fn gridFontScaleForMode(mode: app_state.ViewMode, grid_font_scale: f32) f32 {
    return switch (mode) {
        .Grid, .Expanding, .Collapsing, .GridResizing => grid_font_scale,
        else => 1.0,
    };
}

pub fn applyTerminalResize(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    render_width: c_int,
    render_height: c_int,
) void {
    const usable_width = @max(0, render_width - renderer_mod.TERMINAL_PADDING * 2);
    const usable_height = @max(0, render_height - renderer_mod.TERMINAL_PADDING * 2);

    const new_size = pty_mod.winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    for (sessions) |session| {
        session.pty_size = new_size;
        if (session.spawned) {
            const shell = &(session.shell orelse continue);
            const terminal = &(session.terminal orelse continue);

            shell.pty.setSize(new_size) catch |err| {
                std.debug.print("Failed to resize PTY for session {d}: {}\n", .{ session.id, err });
            };

            terminal.resize(allocator, cols, rows) catch |err| {
                std.debug.print("Failed to resize terminal for session {d}: {}\n", .{ session.id, err });
                continue;
            };

            if (session.stream) |*stream| {
                stream.handler.deinit();
                stream.handler = vt_stream.Handler.init(terminal, shell);
            } else {
                session.stream = vt_stream.initStream(allocator, terminal, shell);
            }

            session.markDirty();
        }
    }
}
