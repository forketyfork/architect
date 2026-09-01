const std = @import("std");
const app_state = @import("app_state.zig");
const clock = @import("../clock.zig");
const c = @import("../c.zig");
const font_mod = @import("../font.zig");
const ghostty_vt = @import("ghostty-vt");
const pty_mod = @import("../pty.zig");
const renderer_mod = @import("../render/renderer.zig");
const dpi = @import("../dpi.zig");
const session_state = @import("../session/state.zig");
const shell_mod = @import("../shell.zig");
const vt_stream = @import("../vt_stream.zig");
const colors_mod = @import("../colors.zig");

const log = std.log.scoped(.layout);
const AnimationState = app_state.AnimationState;
const SessionState = session_state.SessionState;

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
    /// Pixel area the cells actually occupy (cols * cell_width, rows * cell_height).
    /// Mirrored into `ws_xpixel`/`ws_ypixel` and DEC 2048 reports so sessions get the
    /// pixel dimensions of their own rendered area (matters for grid-tile sessions,
    /// which draw into a small tile rather than the whole window).
    width_px: u16,
    height_px: u16,
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
            const rect = anim_state.getCurrentRect(clock.nowMillis());
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
        .width_px = @intCast(cols * scaled_cell_w),
        .height_px = @intCast(rows * scaled_cell_h),
    };
}

pub fn calculateGridCellTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int, grid_font_scale: f32, grid_cols: usize, grid_rows: usize, ui_scale: f32) TerminalSize {
    const cell_width = @divFloor(window_width, @as(c_int, @intCast(grid_cols)));
    const cell_height = @divFloor(window_height, @as(c_int, @intCast(grid_rows)));
    return calculateTerminalSize(font, cell_width, cell_height, grid_font_scale, ui_scale);
}

pub const Sizes = struct {
    grid: TerminalSize,
    full: TerminalSize,
};

/// `grid_window_height` should be the render height with the Grid-mode CWD-bar
/// reservation applied (and should NOT vary across view modes — unfocused
/// sessions stay at grid size permanently, so the grid dims must be stable).
/// `full_window_height` is the raw render height (the focused session uses the
/// whole window when at full size).
pub fn calculateTerminalSizes(
    font: *const font_mod.Font,
    window_width: c_int,
    grid_window_height: c_int,
    full_window_height: c_int,
    grid_font_scale: f32,
    grid_cols: usize,
    grid_rows: usize,
    ui_scale: f32,
) Sizes {
    const grid_dim = @max(grid_cols, grid_rows);
    const base_grid_scale: f32 = 1.0 / @as(f32, @floatFromInt(grid_dim));
    const effective_scale: f32 = base_grid_scale * grid_font_scale;
    return .{
        .grid = calculateGridCellTerminalSize(font, window_width, grid_window_height, effective_scale, grid_cols, grid_rows, ui_scale),
        .full = calculateTerminalSize(font, window_width, full_window_height, 1.0, ui_scale),
    };
}

/// Describes which sessions need full-window cell dimensions. All other
/// sessions remain at grid-cell size. Only the focused session in stable Full
/// mode (and the previous focused session during a panning transition) is at
/// full size; the rest are invisible in Full mode and rendered at grid-cell
/// scale in Grid mode, so paying for full-size PTYs would just force them to
/// redraw their content on every view toggle.
pub const FullSet = struct {
    primary: ?usize = null,
    secondary: ?usize = null,

    pub fn contains(self: FullSet, idx: usize) bool {
        if (self.primary) |p| if (p == idx) return true;
        if (self.secondary) |s| if (s == idx) return true;
        return false;
    }
};

pub fn scaledFontSize(points: c_int, scale: f32) c_int {
    const scaled = std.math.round(@as(f32, @floatFromInt(points)) * scale);
    return @max(1, @as(c_int, @intFromFloat(scaled)));
}

pub fn applyTerminalResize(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    sizes: Sizes,
    full_set: FullSet,
) bool {
    const grid_size = pty_mod.winsize{
        .ws_row = sizes.grid.rows,
        .ws_col = sizes.grid.cols,
        .ws_xpixel = sizes.grid.width_px,
        .ws_ypixel = sizes.grid.height_px,
    };
    const full_size = pty_mod.winsize{
        .ws_row = sizes.full.rows,
        .ws_col = sizes.full.cols,
        .ws_xpixel = sizes.full.width_px,
        .ws_ypixel = sizes.full.height_px,
    };

    var terminal_resized = false;
    for (sessions, 0..) |session, idx| {
        const target = if (full_set.contains(idx)) full_size else grid_size;
        if (!session.spawned) {
            session.pty_size = target;
            continue;
        }

        const shell = &(session.shell orelse continue);
        const terminal = &(session.terminal orelse continue);

        const winsize_changed = !std.meta.eql(session.pty_size, target);
        const layout_cols_changed = session.pty_size.ws_col != target.ws_col;
        const preserve_deccolm_width = !layout_cols_changed and isDeccolmWidthOverride(terminal, target);
        const terminal_cols = if (preserve_deccolm_width) terminal.cols else target.ws_col;
        const terminal_cells_changed = terminal.cols != terminal_cols or terminal.rows != target.ws_row;
        const terminal_pixels_changed = terminal.width_px != @as(u32, target.ws_xpixel) or terminal.height_px != @as(u32, target.ws_ypixel);

        if (winsize_changed) {
            shell.pty.setSize(target) catch |err| {
                log.warn("failed to resize PTY session={d} target={d}x{d}: {}", .{ session.id, target.ws_col, target.ws_row, err });
                continue;
            };
        }

        if (terminal_cells_changed) {
            const prev_cols = terminal.cols;
            const prev_rows = terminal.rows;
            resizeTerminal(allocator, terminal, terminal_cols, target.ws_row, target) catch |err| {
                log.warn("failed to resize VT session={d} target={d}x{d}: {}", .{ session.id, terminal_cols, target.ws_row, err });
                continue;
            };

            if (session.stream == null) {
                session.stream = vt_stream.initStream(allocator, terminal, shell);
            }
            session.resetSynchronizedOutputTracking();
            log.debug("session {d}: terminal resized, {d}x{d} -> {d}x{d}", .{ session.id, prev_cols, prev_rows, terminal_cols, target.ws_row });
            session.markDirty();
            terminal_resized = true;
        } else if (terminal_pixels_changed) {
            updateTerminalPixelSize(terminal, target);
        }

        // DEC 2048 reports describe the VT model's logical cells plus pixel
        // geometry. Under DECCOLM, the logical columns can intentionally differ
        // from the PTY winsize columns.
        if (winsize_changed and terminal.modes.get(.in_band_size_reports)) {
            sendInBandSizeReport(shell, terminal);
        }

        session.pty_size = target;
    }
    return terminal_resized;
}

fn isDeccolmWidthOverride(terminal: *const ghostty_vt.Terminal, target: pty_mod.winsize) bool {
    if (!terminal.modes.get(.enable_mode_3)) return false;
    return (terminal.cols == 80 or terminal.cols == 132) and terminal.cols != target.ws_col;
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
    // Spec-allowed by DEC mode 2026: clear synchronized output on resize so the
    // change is shown immediately rather than buffered.
    terminal.modes.set(.synchronized_output, false);
}

fn updateTerminalPixelSize(
    terminal: *ghostty_vt.Terminal,
    size: pty_mod.winsize,
) void {
    terminal.width_px = @intCast(size.ws_xpixel);
    terminal.height_px = @intCast(size.ws_ypixel);
}

/// Write a DEC mode 2048 in-band size report to the shell. Apps that opt into
/// mode 2048 (nvim does) detect resizes via this report rather than SIGWINCH;
/// without it, they keep drawing at the pre-resize dimensions. Matches
/// ghostty's `src/termio/Termio.zig:sizeReportLocked` mode_2048 branch.
fn sendInBandSizeReport(shell: *shell_mod.Shell, terminal: *const ghostty_vt.Terminal) void {
    var buf: [64]u8 = undefined;
    const report = formatTerminalInBandSizeReport(&buf, terminal) catch return;
    _ = shell.write(report) catch |err| {
        log.warn("failed to write in-band size report: {}", .{err});
    };
}

fn formatTerminalInBandSizeReport(buf: []u8, terminal: *const ghostty_vt.Terminal) error{NoSpaceLeft}![]u8 {
    return vt_stream.formatInBandSizeReport(buf, terminal.rows, terminal.cols, terminal.height_px, terminal.width_px);
}

test "calculateTerminalSizes returns smaller grid than full and shrinks grid further when font scale shrinks" {
    var font: font_mod.Font = undefined;
    font.cell_width = 10;
    font.cell_height = 20;

    const normal = calculateTerminalSizes(&font, 1200, 800, 800, 1.0, 2, 1, 1.0);
    const enlarged = calculateTerminalSizes(&font, 1200, 800, 800, 2.0, 2, 1, 1.0);

    try std.testing.expect(normal.grid.cols < normal.full.cols);
    try std.testing.expect(enlarged.grid.cols < normal.grid.cols);
    try std.testing.expectEqual(normal.full, enlarged.full);
}

test "calculateTerminalSizes grid dims stay stable when only full height changes" {
    var font: font_mod.Font = undefined;
    font.cell_width = 10;
    font.cell_height = 20;

    // grid_window_height held constant; full_window_height varies (the typical
    // case across view-mode toggles where the CWD-bar reservation only changes
    // when the actual grid layout changes).
    const a = calculateTerminalSizes(&font, 1200, 700, 800, 1.0, 2, 1, 1.0);
    const b = calculateTerminalSizes(&font, 1200, 700, 750, 1.0, 2, 1, 1.0);
    try std.testing.expectEqual(a.grid, b.grid);
}

test "FullSet.contains identifies primary and secondary indices" {
    try std.testing.expect(!(FullSet{}).contains(0));
    try std.testing.expect((FullSet{ .primary = 3 }).contains(3));
    try std.testing.expect(!(FullSet{ .primary = 3 }).contains(2));
    try std.testing.expect((FullSet{ .primary = 3, .secondary = 5 }).contains(5));
    try std.testing.expect(!(FullSet{ .primary = 3, .secondary = 5 }).contains(4));
}

const TestSessionFixture = struct {
    session: SessionState,
    slave_fd: pty_mod.Pty.Fd,

    fn deinit(self: *TestSessionFixture, allocator: std.mem.Allocator) void {
        self.session.dead = true;
        self.session.deinit(allocator);
        std.posix.close(self.slave_fd);
    }
};

fn initSpawnedTestSession(
    allocator: std.mem.Allocator,
    pty_size: pty_mod.winsize,
    terminal_cols: u16,
    terminal_rows: u16,
) !TestSessionFixture {
    var pty = try pty_mod.Pty.open(pty_size);
    const slave_fd = pty.slave;
    errdefer {
        pty.deinit();
        std.posix.close(slave_fd);
    }

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = terminal_cols,
        .rows = terminal_rows,
        .max_scrollback = 5,
    });
    errdefer terminal.deinit(allocator);
    terminal.width_px = @intCast(pty_size.ws_xpixel);
    terminal.height_px = @intCast(pty_size.ws_ypixel);

    var session = try SessionState.init(allocator, 0, "/bin/zsh", pty_size, "sock", colors_mod.Theme.default(), null);
    session.shell = .{
        .pty = pty,
        .child_pid = 0,
    };
    session.terminal = terminal;
    session.spawned = true;

    return .{
        .session = session,
        .slave_fd = slave_fd,
    };
}

fn testSizes(cols: u16, rows: u16) Sizes {
    return .{
        .grid = .{ .cols = cols, .rows = rows, .width_px = cols * 10, .height_px = rows * 20 },
        .full = .{ .cols = cols, .rows = rows, .width_px = cols * 10, .height_px = rows * 20 },
    };
}

fn testTerminal(session: *SessionState) !*ghostty_vt.Terminal {
    if (session.terminal) |*terminal| return terminal;
    return error.TestUnexpectedResult;
}

test "applyTerminalResize preserves DECCOLM width while layout target is unchanged" {
    const allocator = std.testing.allocator;
    const target = pty_mod.winsize{ .ws_col = 100, .ws_row = 24, .ws_xpixel = 1000, .ws_ypixel = 480 };
    var fixture = try initSpawnedTestSession(allocator, target, 80, 24);
    defer fixture.deinit(allocator);

    const terminal = try testTerminal(&fixture.session);
    terminal.modes.set(.enable_mode_3, true);

    var sessions = [_]*SessionState{&fixture.session};
    const changed = applyTerminalResize(&sessions, allocator, testSizes(100, 24), .{ .primary = 0 });

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(u16, 80), terminal.cols);
    try std.testing.expectEqual(@as(u16, 24), terminal.rows);
    try std.testing.expectEqual(@as(u16, 100), fixture.session.pty_size.ws_col);
}

test "applyTerminalResize preserves DECCOLM width on row-only layout changes" {
    const allocator = std.testing.allocator;
    const old_target = pty_mod.winsize{ .ws_col = 100, .ws_row = 24, .ws_xpixel = 1000, .ws_ypixel = 480 };
    var fixture = try initSpawnedTestSession(allocator, old_target, 80, 24);
    defer fixture.deinit(allocator);

    const terminal = try testTerminal(&fixture.session);
    terminal.modes.set(.enable_mode_3, true);
    terminal.modes.set(.in_band_size_reports, true);

    var sessions = [_]*SessionState{&fixture.session};
    const changed = applyTerminalResize(&sessions, allocator, testSizes(100, 30), .{ .primary = 0 });

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(u16, 80), terminal.cols);
    try std.testing.expectEqual(@as(u16, 30), terminal.rows);
    try std.testing.expectEqual(@as(u16, 100), fixture.session.pty_size.ws_col);
    try std.testing.expectEqual(@as(u16, 30), fixture.session.pty_size.ws_row);

    var report_buf: [64]u8 = undefined;
    const report = try formatTerminalInBandSizeReport(&report_buf, terminal);
    try std.testing.expectEqualSlices(u8, "\x1b[48;30;80;600;1000t", report);
}

test "applyTerminalResize preserves DECCOLM width on pixel-only layout changes" {
    const allocator = std.testing.allocator;
    const old_target = pty_mod.winsize{ .ws_col = 100, .ws_row = 24, .ws_xpixel = 1000, .ws_ypixel = 480 };
    var fixture = try initSpawnedTestSession(allocator, old_target, 80, 24);
    defer fixture.deinit(allocator);

    const terminal = try testTerminal(&fixture.session);
    terminal.modes.set(.enable_mode_3, true);
    terminal.modes.set(.in_band_size_reports, true);

    const sizes = Sizes{
        .grid = .{ .cols = 100, .rows = 24, .width_px = 1200, .height_px = 480 },
        .full = .{ .cols = 100, .rows = 24, .width_px = 1200, .height_px = 480 },
    };
    var sessions = [_]*SessionState{&fixture.session};
    const changed = applyTerminalResize(&sessions, allocator, sizes, .{ .primary = 0 });

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(u16, 80), terminal.cols);
    try std.testing.expectEqual(@as(u16, 24), terminal.rows);
    try std.testing.expectEqual(@as(u32, 1200), terminal.width_px);
    try std.testing.expectEqual(@as(u32, 480), terminal.height_px);
    try std.testing.expectEqual(@as(u16, 100), fixture.session.pty_size.ws_col);

    var report_buf: [64]u8 = undefined;
    const report = try formatTerminalInBandSizeReport(&report_buf, terminal);
    try std.testing.expectEqualSlices(u8, "\x1b[48;24;80;480;1200t", report);
}

test "applyTerminalResize resets DECCOLM width when layout target changes" {
    const allocator = std.testing.allocator;
    const old_target = pty_mod.winsize{ .ws_col = 100, .ws_row = 24, .ws_xpixel = 1000, .ws_ypixel = 480 };
    var fixture = try initSpawnedTestSession(allocator, old_target, 80, 24);
    defer fixture.deinit(allocator);

    const terminal = try testTerminal(&fixture.session);
    terminal.modes.set(.enable_mode_3, true);

    var sessions = [_]*SessionState{&fixture.session};
    const changed = applyTerminalResize(&sessions, allocator, testSizes(120, 24), .{ .primary = 0 });

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(u16, 120), terminal.cols);
    try std.testing.expectEqual(@as(u16, 24), terminal.rows);
    try std.testing.expectEqual(@as(u16, 120), fixture.session.pty_size.ws_col);
}

test "applyTerminalResize corrects non-DECCOLM terminal width drift" {
    const allocator = std.testing.allocator;
    const target = pty_mod.winsize{ .ws_col = 100, .ws_row = 24, .ws_xpixel = 1000, .ws_ypixel = 480 };
    var fixture = try initSpawnedTestSession(allocator, target, 80, 24);
    defer fixture.deinit(allocator);

    var sessions = [_]*SessionState{&fixture.session};
    const changed = applyTerminalResize(&sessions, allocator, testSizes(100, 24), .{ .primary = 0 });

    try std.testing.expect(changed);
    const terminal = try testTerminal(&fixture.session);
    try std.testing.expectEqual(@as(u16, 100), terminal.cols);
    try std.testing.expectEqual(@as(u16, 24), terminal.rows);
}

// A resize must publish the new content immediately: nothing may defer the
// repaint behind a settle/freeze window. Architect renders whatever the app
// draws in response to SIGWINCH, live, the way Ghostty does.
test "applyTerminalResize makes the session renderable immediately" {
    const allocator = std.testing.allocator;
    const target = pty_mod.winsize{ .ws_col = 100, .ws_row = 24, .ws_xpixel = 1000, .ws_ypixel = 480 };
    var fixture = try initSpawnedTestSession(allocator, target, 100, 24);
    defer fixture.deinit(allocator);

    const epoch_before = fixture.session.render_epoch;
    var sessions = [_]*SessionState{&fixture.session};
    const changed = applyTerminalResize(&sessions, allocator, testSizes(120, 30), .{ .primary = 0 });

    try std.testing.expect(changed);
    try std.testing.expect(fixture.session.render_epoch != epoch_before);
}

test "applyTerminalResize reports no change when the cell count already matches" {
    const allocator = std.testing.allocator;
    const target = pty_mod.winsize{ .ws_col = 100, .ws_row = 24, .ws_xpixel = 1000, .ws_ypixel = 480 };
    var fixture = try initSpawnedTestSession(allocator, target, 100, 24);
    defer fixture.deinit(allocator);

    var sessions = [_]*SessionState{&fixture.session};
    const changed = applyTerminalResize(&sessions, allocator, testSizes(100, 24), .{ .primary = 0 });

    try std.testing.expect(!changed);
    const terminal = try testTerminal(&fixture.session);
    try std.testing.expectEqual(@as(u16, 100), terminal.cols);
    try std.testing.expectEqual(@as(u16, 24), terminal.rows);
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
