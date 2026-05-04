const std = @import("std");
const app_state = @import("app_state.zig");
const c = @import("../c.zig");
const font_mod = @import("../font.zig");
const ghostty_vt = @import("ghostty-vt");
const pty_mod = @import("../pty.zig");
const renderer_mod = @import("../render/renderer.zig");
const dpi = @import("../dpi.zig");
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

pub fn calculateTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int, grid_font_scale: f32, ui_scale: f32) TerminalSize {
    const padding = dpi.scale(renderer_mod.terminal_padding, ui_scale) * 2;
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

pub fn calculateGridCellTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int, grid_font_scale: f32, grid_cols: usize, grid_rows: usize, ui_scale: f32) TerminalSize {
    const cell_width = @divFloor(window_width, @as(c_int, @intCast(grid_cols)));
    const cell_height = @divFloor(window_height, @as(c_int, @intCast(grid_rows)));
    return calculateTerminalSize(font, cell_width, cell_height, grid_font_scale, ui_scale);
}

pub fn calculateTerminalSizeForMode(font: *const font_mod.Font, window_width: c_int, window_height: c_int, mode: app_state.ViewMode, grid_font_scale: f32, grid_cols: usize, grid_rows: usize, ui_scale: f32) TerminalSize {
    return switch (mode) {
        .Grid => {
            const grid_dim = @max(grid_cols, grid_rows);
            const base_grid_scale: f32 = 1.0 / @as(f32, @floatFromInt(grid_dim));
            const effective_scale: f32 = base_grid_scale * grid_font_scale;
            return calculateGridCellTerminalSize(font, window_width, window_height, effective_scale, grid_cols, grid_rows, ui_scale);
        },
        .Collapsing, .GridResizing, .Expanding, .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => calculateTerminalSize(font, window_width, window_height, 1.0, ui_scale),
    };
}

pub fn scaledFontSize(points: c_int, scale: f32) c_int {
    const scaled = std.math.round(@as(f32, @floatFromInt(points)) * scale);
    return @max(1, @as(c_int, @intFromFloat(scaled)));
}

pub fn applyTerminalResize(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
) bool {
    const usable_width = @max(0, render_width - dpi.scale(renderer_mod.terminal_padding, ui_scale) * 2);
    const usable_height = @max(0, render_height - dpi.scale(renderer_mod.terminal_padding, ui_scale) * 2);

    const new_size = pty_mod.winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    var terminal_resized = false;
    for (sessions) |session| {
        if (!session.spawned) {
            session.pty_size = new_size;
            continue;
        }

        const shell = &(session.shell orelse continue);
        const terminal = &(session.terminal orelse continue);

        const cells_changed = terminalCellSizeChanged(session.pty_size, cols, rows);
        const terminal_cells_changed = terminal.cols != cols or terminal.rows != rows;

        if (cells_changed) {
            shell.pty.setSize(new_size) catch |err| {
                std.debug.print("Failed to resize PTY for session {d}: {}\n", .{ session.id, err });
                continue;
            };
        }

        if (terminal_cells_changed) {
            resizeTerminal(allocator, terminal, cols, rows, new_size) catch |err| {
                std.debug.print("Failed to resize terminal for session {d}: {}\n", .{ session.id, err });
                continue;
            };

            if (session.stream == null) {
                session.stream = vt_stream.initStream(allocator, terminal, shell);
            }
            session.markDirty();
            terminal_resized = true;
        }

        session.pty_size = new_size;
    }
    return terminal_resized;
}

fn terminalCellSizeChanged(current: pty_mod.winsize, cols: u16, rows: u16) bool {
    return current.ws_col != cols or current.ws_row != rows;
}

fn resizeTerminal(
    allocator: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    cols: u16,
    rows: u16,
    size: pty_mod.winsize,
) !void {
    try terminal.resize(allocator, cols, rows);
    terminal.width_px = @intCast(size.ws_xpixel);
    terminal.height_px = @intCast(size.ws_ypixel);
    terminal.modes.set(.synchronized_output, false);
}

test "grid mode sizes terminals to the rendered tile area" {
    var font: font_mod.Font = undefined;
    font.cell_width = 10;
    font.cell_height = 20;

    const full = calculateTerminalSizeForMode(&font, 1200, 800, .Full, 1.0, 2, 1, 1.0);
    const normal_grid = calculateTerminalSizeForMode(&font, 1200, 800, .Grid, 1.0, 2, 1, 1.0);
    const enlarged_grid = calculateTerminalSizeForMode(&font, 1200, 800, .Grid, 2.0, 2, 1, 1.0);

    try std.testing.expect(normal_grid.cols < full.cols);
    try std.testing.expect(enlarged_grid.cols < normal_grid.cols);
    try std.testing.expectEqual(full, calculateTerminalSizeForMode(&font, 1200, 800, .Expanding, 1.0, 2, 1, 1.0));
    try std.testing.expectEqual(full, calculateTerminalSizeForMode(&font, 1200, 800, .Collapsing, 1.0, 2, 1, 1.0));
    try std.testing.expectEqual(full, calculateTerminalSizeForMode(&font, 1200, 800, .GridResizing, 1.0, 2, 1, 1.0));
}

test "terminal cell size ignores pixel-only resize differences" {
    const size = pty_mod.winsize{
        .ws_row = 40,
        .ws_col = 120,
        .ws_xpixel = 1200,
        .ws_ypixel = 800,
    };

    try std.testing.expect(!terminalCellSizeChanged(size, 120, 40));
    try std.testing.expect(terminalCellSizeChanged(size, 121, 40));
    try std.testing.expect(terminalCellSizeChanged(size, 120, 41));
}

test "terminal resize preserves prompt contents when shell does not redraw" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer terminal.deinit(allocator);

    const screen = terminal.screens.active;
    try screen.testWriteString("ABCDE\n");
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("> ");
    screen.cursorSetSemanticContent(.{ .input = .clear_eol });
    try screen.testWriteString("echo");
    terminal.flags.shell_redraws_prompt = .false;

    const before = try terminal.plainString(allocator);
    defer allocator.free(before);
    try std.testing.expectEqualStrings("ABCDE\n> echo", before);

    const size = pty_mod.winsize{ .ws_col = 20, .ws_row = 3, .ws_xpixel = 200, .ws_ypixel = 60 };
    try resizeTerminal(allocator, &terminal, 20, 3, size);

    const after = try terminal.plainString(allocator);
    defer allocator.free(after);
    try std.testing.expectEqualStrings("ABCDE\n> echo", after);
    try std.testing.expectEqual(@as(u32, 200), terminal.width_px);
    try std.testing.expectEqual(@as(u32, 60), terminal.height_px);
}

test "terminal resize clears semantic prompt when shell redraws prompt" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer terminal.deinit(allocator);

    const screen = terminal.screens.active;
    try screen.testWriteString("ABCDE\n");
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("> ");
    screen.cursorSetSemanticContent(.{ .input = .clear_eol });
    try screen.testWriteString("echo");

    terminal.flags.shell_redraws_prompt = .true;
    const size = pty_mod.winsize{ .ws_col = 20, .ws_row = 3, .ws_xpixel = 200, .ws_ypixel = 60 };
    try resizeTerminal(allocator, &terminal, 20, 3, size);
    try std.testing.expectEqual(.true, terminal.flags.shell_redraws_prompt);

    const after = try terminal.plainString(allocator);
    defer allocator.free(after);
    try std.testing.expectEqualStrings("ABCDE", after);
}
