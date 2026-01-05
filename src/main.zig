// Main application entry: wires SDL2 rendering, ghostty-vt terminals, PTY-backed
// shells, and the grid/animation system that drives the 3×3 terminal wall UI.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const app_state = @import("app/app_state.zig");
const notify = @import("session/notify.zig");
const session_state = @import("session/state.zig");
const platform = @import("platform/sdl.zig");
const input = @import("input/mapper.zig");
const renderer_mod = @import("render/renderer.zig");
const shell_mod = @import("shell.zig");
const pty_mod = @import("pty.zig");
const font_mod = @import("font.zig");
const config_mod = @import("config.zig");
const c = @import("c.zig");

const log = std.log.scoped(.main);

const INITIAL_WINDOW_WIDTH = 1200;
const INITIAL_WINDOW_HEIGHT = 900;
const GRID_ROWS = 3;
const GRID_COLS = 3;
const SCROLL_LINES_PER_TICK: isize = 3;
const DEFAULT_FONT_SIZE: c_int = 14;
const MIN_FONT_SIZE: c_int = 8;
const MAX_FONT_SIZE: c_int = 96;
const FONT_STEP: c_int = 1;
const UI_FONT_SIZE: c_int = 18;
const FONT_PATH: [*:0]const u8 = "/System/Library/Fonts/SFNSMono.ttf";
const SessionStatus = app_state.SessionStatus;
const ViewMode = app_state.ViewMode;
const Rect = app_state.Rect;
const AnimationState = app_state.AnimationState;
const ToastNotification = app_state.ToastNotification;
const HelpButtonAnimation = app_state.HelpButtonAnimation;
const EscapeIndicator = app_state.EscapeIndicator;
const NotificationQueue = notify.NotificationQueue;
const Notification = notify.Notification;
const SessionState = session_state.SessionState;
const FontSizeDirection = input.FontSizeDirection;
const GridNavDirection = input.GridNavDirection;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Socket listener relays external "awaiting approval / done" signals from
    // shells (or other tools) into the UI thread without blocking rendering.
    var notify_queue = NotificationQueue{};
    defer notify_queue.deinit(allocator);

    const notify_sock = try notify.getNotifySocketPath(allocator);
    defer allocator.free(notify_sock);

    const notify_thread = try notify.startNotifyThread(allocator, notify_sock, &notify_queue);
    notify_thread.detach();

    const config = config_mod.Config.load(allocator) catch |err| blk: {
        if (err == error.ConfigNotFound) {
            std.debug.print("Config not found, using defaults\n", .{});
        } else {
            std.debug.print("Failed to load config: {}, using defaults\n", .{err});
        }
        break :blk config_mod.Config{
            .font_size = DEFAULT_FONT_SIZE,
            .window_width = INITIAL_WINDOW_WIDTH,
            .window_height = INITIAL_WINDOW_HEIGHT,
            .window_x = -1,
            .window_y = -1,
        };
    };

    const window_pos = if (config.window_x >= 0 and config.window_y >= 0)
        platform.WindowPosition{ .x = config.window_x, .y = config.window_y }
    else
        null;
    var sdl = try platform.init("Architect - Terminal Wall", config.window_width, config.window_height, window_pos);
    defer platform.deinit(&sdl);
    platform.startTextInput(sdl.window);
    defer platform.stopTextInput(sdl.window);

    const renderer = sdl.renderer;
    const vsync_enabled = sdl.vsync_enabled;

    var font_size: c_int = config.font_size;
    var font = try font_mod.Font.init(allocator, renderer, FONT_PATH, font_size);
    defer font.deinit();

    var ui_font = try font_mod.Font.init(allocator, renderer, FONT_PATH, UI_FONT_SIZE);
    defer ui_font.deinit();

    var window_width: c_int = config.window_width;
    var window_height: c_int = config.window_height;
    var window_x: c_int = config.window_x;
    var window_y: c_int = config.window_y;

    const initial_term_size = calculateTerminalSize(&font, window_width, window_height);
    var full_cols: u16 = initial_term_size.cols;
    var full_rows: u16 = initial_term_size.rows;

    std.debug.print("Full window terminal size: {d}x{d}\n", .{ full_cols, full_rows });

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Spawning {d} shell instances: {s}\n", .{ GRID_ROWS * GRID_COLS, shell_path });

    var cell_width_pixels = @divFloor(window_width, GRID_COLS);
    var cell_height_pixels = @divFloor(window_height, GRID_ROWS);

    const usable_width = @max(0, window_width - renderer_mod.TERMINAL_PADDING * 2);
    const usable_height = @max(0, window_height - renderer_mod.TERMINAL_PADDING * 2);

    const size = pty_mod.winsize{
        .ws_row = full_rows,
        .ws_col = full_cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    var sessions: [GRID_ROWS * GRID_COLS]SessionState = undefined;
    var init_count: usize = 0;
    errdefer {
        for (0..init_count) |i| {
            sessions[i].deinit(allocator);
        }
    }

    for (0..GRID_ROWS * GRID_COLS) |i| {
        var session_buf: [16]u8 = undefined;
        const session_z = try std.fmt.bufPrintZ(&session_buf, "{d}", .{i});
        sessions[i] = try SessionState.init(allocator, i, shell_path, size, session_z, notify_sock);
        init_count += 1;
    }

    try sessions[0].ensureSpawned();

    defer {
        for (&sessions) |*session| {
            session.deinit(allocator);
        }
    }

    var running = true;

    var anim_state = AnimationState{
        .mode = .Grid,
        .focused_session = 0,
        .previous_session = 0,
        .start_time = 0,
        .start_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .target_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };

    var toast_notification = ToastNotification{};
    var help_button = HelpButtonAnimation{};
    var escape_indicator = EscapeIndicator{};

    // Main loop: handle SDL input, feed PTY output into terminals, apply async
    // notifications, drive animations, and render at ~60 FPS.
    while (running) {
        const frame_start_ns: i128 = std.time.nanoTimestamp();
        const now = std.time.milliTimestamp();

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_MOVED => {
                    window_x = event.window.data1;
                    window_y = event.window.data2;
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    window_width = @intCast(event.window.data1);
                    window_height = @intCast(event.window.data2);
                    cell_width_pixels = @divFloor(window_width, GRID_COLS);
                    cell_height_pixels = @divFloor(window_height, GRID_ROWS);

                    const new_term_size = calculateTerminalSize(&font, window_width, window_height);
                    full_cols = new_term_size.cols;
                    full_rows = new_term_size.rows;
                    applyTerminalResize(&sessions, allocator, full_cols, full_rows, window_width, window_height);

                    std.debug.print("Window resized to: {d}x{d}, terminal size: {d}x{d}\n", .{ window_width, window_height, full_cols, full_rows });

                    const updated_config = config_mod.Config{
                        .font_size = font_size,
                        .window_width = window_width,
                        .window_height = window_height,
                        .window_x = window_x,
                        .window_y = window_y,
                    };
                    updated_config.save(allocator) catch |err| {
                        std.debug.print("Failed to save config: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const focused = &sessions[anim_state.focused_session];
                    if (focused.spawned and !focused.dead) {
                        if (focused.is_scrolled) {
                            if (focused.terminal) |*terminal| {
                                terminal.screens.active.pages.scroll(.{ .active = {} });
                                focused.is_scrolled = false;
                            }
                        }
                        const text = std.mem.sliceTo(event.text.text, 0);
                        if (focused.shell) |*shell| {
                            _ = try shell.write(text);
                        }
                    }
                },
                c.SDL_EVENT_KEY_DOWN => {
                    const key = event.key.key;
                    const mod = event.key.mod;
                    const is_repeat = event.key.repeat;

                    if (input.fontSizeShortcut(key, mod)) |direction| {
                        const delta: c_int = if (direction == .increase) FONT_STEP else -FONT_STEP;
                        const target_size = std.math.clamp(font_size + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);

                        if (target_size != font_size) {
                            const new_font = try font_mod.Font.init(allocator, renderer, FONT_PATH, target_size);
                            font.deinit();
                            font = new_font;
                            font_size = target_size;

                            const term_size = calculateTerminalSize(&font, window_width, window_height);
                            full_cols = term_size.cols;
                            full_rows = term_size.rows;
                            applyTerminalResize(&sessions, allocator, full_cols, full_rows, window_width, window_height);
                            std.debug.print("Font size -> {d}px, terminal size: {d}x{d}\n", .{ font_size, full_cols, full_rows });

                            const updated_config = config_mod.Config{
                                .font_size = font_size,
                                .window_width = window_width,
                                .window_height = window_height,
                                .window_x = window_x,
                                .window_y = window_y,
                            };
                            updated_config.save(allocator) catch |err| {
                                std.debug.print("Failed to save config: {}\n", .{err});
                            };
                        }

                        var notification_buf: [64]u8 = undefined;
                        const hotkey = if (direction == .increase) "⌘⇧+" else "⌘⇧-";
                        const notification_msg = std.fmt.bufPrint(&notification_buf, "{s}  Font size: {d}pt", .{ hotkey, font_size }) catch "Font size changed";
                        toast_notification.show(notification_msg, now);
                    } else if (input.isSwitchTerminalShortcut(key, mod)) |is_next| {
                        if (anim_state.mode == .Full) {
                            const total_sessions = GRID_ROWS * GRID_COLS;
                            const new_session = if (is_next)
                                (anim_state.focused_session + 1) % total_sessions
                            else
                                (anim_state.focused_session + total_sessions - 1) % total_sessions;

                            try sessions[new_session].ensureSpawned();

                            anim_state.mode = if (is_next) .PanningLeft else .PanningRight;
                            anim_state.previous_session = anim_state.focused_session;
                            anim_state.focused_session = new_session;
                            anim_state.start_time = now;
                            std.debug.print("Panning to session {d} from {d}\n", .{ new_session, anim_state.previous_session });

                            var notification_buf: [64]u8 = undefined;
                            const hotkey = if (is_next) "⌘⇧]" else "⌘⇧[";
                            const notification_msg = std.fmt.bufPrint(&notification_buf, "{s}  Terminal {d}", .{ hotkey, new_session }) catch "Terminal switched";
                            toast_notification.show(notification_msg, now);
                        }
                    } else if (input.gridNavShortcut(key, mod)) |direction| {
                        if (anim_state.mode == .Grid) {
                            const current_row: usize = anim_state.focused_session / GRID_COLS;
                            const current_col: usize = anim_state.focused_session % GRID_COLS;
                            var new_row: usize = current_row;
                            var new_col: usize = current_col;

                            switch (direction) {
                                .up => {
                                    if (current_row > 0) {
                                        new_row = current_row - 1;
                                    }
                                },
                                .down => {
                                    if (current_row < GRID_ROWS - 1) {
                                        new_row = current_row + 1;
                                    }
                                },
                                .left => {
                                    if (current_col > 0) {
                                        new_col = current_col - 1;
                                    }
                                },
                                .right => {
                                    if (current_col < GRID_COLS - 1) {
                                        new_col = current_col + 1;
                                    }
                                },
                            }

                            const new_session = new_row * GRID_COLS + new_col;
                            if (new_session != anim_state.focused_session) {
                                sessions[anim_state.focused_session].dirty = true;
                                sessions[new_session].dirty = true;
                                anim_state.focused_session = new_session;
                                std.debug.print("Grid nav to session {d}\n", .{new_session});
                            }
                        } else {
                            const focused = &sessions[anim_state.focused_session];
                            if (focused.spawned and !focused.dead) {
                                try handleKeyInput(focused, key, mod, is_repeat);
                            }
                        }
                    } else if (key == c.SDLK_RETURN and (mod & c.SDL_KMOD_GUI) != 0 and anim_state.mode == .Grid) {
                        const clicked_session = anim_state.focused_session;
                        try sessions[clicked_session].ensureSpawned();

                        sessions[clicked_session].status = .running;
                        sessions[clicked_session].attention = false;

                        const grid_row: c_int = @intCast(clicked_session / GRID_COLS);
                        const grid_col: c_int = @intCast(clicked_session % GRID_COLS);
                        const start_rect = Rect{
                            .x = grid_col * cell_width_pixels,
                            .y = grid_row * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                        const target_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };

                        anim_state.mode = .Expanding;
                        anim_state.focused_session = clicked_session;
                        anim_state.start_time = now;
                        anim_state.start_rect = start_rect;
                        anim_state.target_rect = target_rect;
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    } else if (key == c.SDLK_ESCAPE and input.canHandleEscapePress(anim_state.mode) and !is_repeat) {
                        escape_indicator.start(now);
                        std.debug.print("Escape pressed at {d}\n", .{now});
                    } else {
                        const focused = &sessions[anim_state.focused_session];
                        if (focused.spawned and !focused.dead) {
                            try handleKeyInput(focused, key, mod, is_repeat);
                        }
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    const key = event.key.key;
                    if (key == c.SDLK_ESCAPE) {
                        const was_complete = escape_indicator.isComplete(now);
                        const was_consumed = escape_indicator.consumed;
                        escape_indicator.stop();

                        if (!was_complete and !was_consumed and input.canHandleEscapePress(anim_state.mode)) {
                            const focused = &sessions[anim_state.focused_session];
                            if (focused.spawned and !focused.dead and focused.shell != null) {
                                const esc_byte: [1]u8 = .{27};
                                _ = focused.shell.?.write(&esc_byte) catch {};
                            }
                            std.debug.print("Escape released quickly, sent to terminal\n", .{});
                        } else {
                            std.debug.print("Escape released after hold or consumed by UI\n", .{});
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    const mouse_x: c_int = @intFromFloat(event.button.x);
                    const mouse_y: c_int = @intFromFloat(event.button.y);

                    const help_rect = help_button.getRect(now, window_width, window_height);
                    const clicked_help = renderer_mod.isPointInRect(mouse_x, mouse_y, help_rect);

                    if (clicked_help) {
                        if (help_button.state == .Closed) {
                            help_button.startExpanding(now);
                            std.debug.print("Opening help overlay\n", .{});
                        } else if (help_button.state == .Open) {
                            help_button.startCollapsing(now);
                            std.debug.print("Closing help overlay\n", .{});
                        }
                    } else if (help_button.state == .Open and !clicked_help) {
                        help_button.startCollapsing(now);
                        std.debug.print("Closing help overlay (clicked outside)\n", .{});
                    } else if (anim_state.mode == .Grid) {
                        const grid_col = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), GRID_COLS - 1);
                        const grid_row = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), GRID_ROWS - 1);
                        const clicked_session: usize = grid_row * @as(usize, GRID_COLS) + grid_col;

                        const cell_rect = Rect{
                            .x = @as(c_int, @intCast(grid_col)) * cell_width_pixels,
                            .y = @as(c_int, @intCast(grid_row)) * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };

                        var clicked_restart = false;
                        if (sessions[clicked_session].dead) {
                            const restart_rect = renderer_mod.getRestartButtonRect(cell_rect);
                            clicked_restart = renderer_mod.isPointInRect(mouse_x, mouse_y, restart_rect);
                        }

                        if (clicked_restart) {
                            try sessions[clicked_session].restart();
                            std.debug.print("Restarted session: {d}\n", .{clicked_session});
                        } else {
                            try sessions[clicked_session].ensureSpawned();

                            sessions[clicked_session].status = .running;
                            sessions[clicked_session].attention = false;

                            const target_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };

                            anim_state.mode = .Expanding;
                            anim_state.focused_session = clicked_session;
                            anim_state.start_time = now;
                            anim_state.start_rect = cell_rect;
                            anim_state.target_rect = target_rect;
                            std.debug.print("Expanding session: {d}\n", .{clicked_session});
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    const mouse_x: c_int = @intFromFloat(event.wheel.mouse_x);
                    const mouse_y: c_int = @intFromFloat(event.wheel.mouse_y);

                    const hovered_session = calculateHoveredSession(
                        mouse_x,
                        mouse_y,
                        &anim_state,
                        cell_width_pixels,
                        cell_height_pixels,
                        window_width,
                        window_height,
                    );

                    if (hovered_session) |session_idx| {
                        const raw_delta = event.wheel.y;
                        const scroll_delta = -@as(isize, @intFromFloat(raw_delta * @as(f32, @floatFromInt(SCROLL_LINES_PER_TICK))));
                        if (scroll_delta != 0) {
                            scrollSession(&sessions[session_idx], scroll_delta);
                        }
                    }
                },
                else => {},
            }
        }

        for (&sessions) |*session| {
            session.checkAlive();
            try session.processOutput();
            session.updateCwd(now);
        }

        if (escape_indicator.isComplete(now) and anim_state.mode == .Full) {
            const grid_row: c_int = @intCast(anim_state.focused_session / GRID_COLS);
            const grid_col: c_int = @intCast(anim_state.focused_session % GRID_COLS);
            const target_rect = Rect{
                .x = grid_col * cell_width_pixels,
                .y = grid_row * cell_height_pixels,
                .w = cell_width_pixels,
                .h = cell_height_pixels,
            };

            anim_state.mode = .Collapsing;
            anim_state.start_time = now;
            anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };
            anim_state.target_rect = target_rect;
            escape_indicator.consume();
            std.debug.print("Escape hold complete, collapsing session: {d}\n", .{anim_state.focused_session});
        }

        var notifications = notify_queue.drainAll();
        defer notifications.deinit(allocator);
        for (notifications.items) |note| {
            if (note.session < sessions.len) {
                var session = &sessions[note.session];
                session.status = note.state;
                session.attention = switch (note.state) {
                    .awaiting_approval, .done => true,
                    else => false,
                };
                std.debug.print("Session {d} status -> {s}\n", .{ note.session, @tagName(note.state) });
            }
        }

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing or
            anim_state.mode == .PanningLeft or anim_state.mode == .PanningRight)
        {
            if (anim_state.isComplete(now)) {
                const prev_mode = anim_state.mode;
                anim_state.mode = switch (anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight => .Full,
                    .Collapsing => .Grid,
                    else => anim_state.mode,
                };
                if (prev_mode == .Collapsing and anim_state.mode == .Grid) {
                    escape_indicator.stop();
                }
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        if (help_button.isAnimating() and help_button.isComplete(now)) {
            help_button.state = switch (help_button.state) {
                .Expanding => .Open,
                .Collapsing => .Closed,
                else => help_button.state,
            };
            std.debug.print("Help button animation complete, new state: {s}\n", .{@tagName(help_button.state)});
        }

        try renderer_mod.render(renderer, &sessions, cell_width_pixels, cell_height_pixels, GRID_COLS, &anim_state, now, &font, full_cols, full_rows, window_width, window_height);
        renderer_mod.renderToastNotification(renderer, &toast_notification, now, window_width);
        renderer_mod.renderHelpButton(renderer, &help_button, now, window_width, window_height);
        renderer_mod.renderEscapeIndicator(renderer, &escape_indicator, now, &ui_font);
        _ = c.SDL_RenderPresent(renderer);

        if (!vsync_enabled) {
            const target_frame_ns: i128 = 16_666_667;
            const frame_end_ns: i128 = std.time.nanoTimestamp();
            const frame_ns = frame_end_ns - frame_start_ns;
            if (frame_ns < target_frame_ns) {
                std.Thread.sleep(@intCast(target_frame_ns - frame_ns));
            }
        }
    }
}

fn calculateHoveredSession(
    mouse_x: c_int,
    mouse_y: c_int,
    anim_state: *const AnimationState,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    window_width: c_int,
    window_height: c_int,
) ?usize {
    return switch (anim_state.mode) {
        .Grid => {
            if (mouse_x < 0 or mouse_x >= window_width or
                mouse_y < 0 or mouse_y >= window_height) return null;

            const grid_col = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), GRID_COLS - 1);
            const grid_row = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), GRID_ROWS - 1);
            return grid_row * GRID_COLS + grid_col;
        },
        .Full, .PanningLeft, .PanningRight => anim_state.focused_session,
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

fn scrollSession(session: *SessionState, delta: isize) void {
    if (!session.spawned) return;
    if (session.terminal) |*terminal| {
        var pages = &terminal.screens.active.pages;
        pages.scroll(.{ .delta_row = delta });

        session.is_scrolled = (pages.viewport != .active);
        session.dirty = true;
    }
}

fn calculateTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int) struct { cols: u16, rows: u16 } {
    const padding = renderer_mod.TERMINAL_PADDING * 2;
    const usable_w = @max(0, window_width - padding);
    const usable_h = @max(0, window_height - padding);
    const cols = @max(1, @divFloor(usable_w, font.cell_width));
    const rows = @max(1, @divFloor(usable_h, font.cell_height));
    return .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
    };
}

fn applyTerminalResize(
    sessions: []SessionState,
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    window_width: c_int,
    window_height: c_int,
) void {
    const usable_width = @max(0, window_width - renderer_mod.TERMINAL_PADDING * 2);
    const usable_height = @max(0, window_height - renderer_mod.TERMINAL_PADDING * 2);

    const new_size = pty_mod.winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    for (sessions) |*session| {
        session.pty_size = new_size;
        if (session.spawned) {
            if (session.shell) |*shell| {
                shell.pty.setSize(new_size) catch |err| {
                    std.debug.print("Failed to resize PTY for session {d}: {}\n", .{ session.id, err });
                };
            }
            if (session.terminal) |*terminal| {
                terminal.resize(allocator, cols, rows) catch |err| {
                    std.debug.print("Failed to resize terminal for session {d}: {}\n", .{ session.id, err });
                };
            }
            session.dirty = true;
        }
    }
}

fn handleKeyInput(focused: *SessionState, key: c.SDL_Keycode, mod: c.SDL_Keymod, is_repeat: bool) !void {
    if (key == c.SDLK_ESCAPE) return;

    if (focused.is_scrolled) {
        if (focused.terminal) |*terminal| {
            terminal.screens.active.pages.scroll(.{ .active = {} });
            focused.is_scrolled = false;
        }
    }
    var buf: [8]u8 = undefined;
    const n = input.encodeKeyWithMod(key, mod, &buf);
    if (n > 0) {
        if (focused.shell) |*shell| {
            _ = try shell.write(buf[0..n]);
        }
    } else if (is_repeat and builtin.os.tag == .macos) {
        if (input.keyToChar(key, mod)) |ch| {
            buf[0] = ch;
            if (focused.shell) |*shell| {
                _ = try shell.write(buf[0..1]);
            }
        }
    }
}

const ansi_colors = [_]c.SDL_Color{
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 205, .g = 49, .b = 49, .a = 255 },
    .{ .r = 13, .g = 188, .b = 121, .a = 255 },
    .{ .r = 229, .g = 229, .b = 16, .a = 255 },
    .{ .r = 36, .g = 114, .b = 200, .a = 255 },
    .{ .r = 188, .g = 63, .b = 188, .a = 255 },
    .{ .r = 17, .g = 168, .b = 205, .a = 255 },
    .{ .r = 229, .g = 229, .b = 229, .a = 255 },
    .{ .r = 102, .g = 102, .b = 102, .a = 255 },
    .{ .r = 241, .g = 76, .b = 76, .a = 255 },
    .{ .r = 35, .g = 209, .b = 139, .a = 255 },
    .{ .r = 245, .g = 245, .b = 67, .a = 255 },
    .{ .r = 59, .g = 142, .b = 234, .a = 255 },
    .{ .r = 214, .g = 112, .b = 214, .a = 255 },
    .{ .r = 41, .g = 184, .b = 219, .a = 255 },
    .{ .r = 255, .g = 255, .b = 255, .a = 255 },
};

fn get256Color(idx: u8) c.SDL_Color {
    if (idx < 16) {
        return ansi_colors[idx];
    } else if (idx < 232) {
        const color_idx = idx - 16;
        const r = (color_idx / 36) * 51;
        const g = ((color_idx % 36) / 6) * 51;
        const b = (color_idx % 6) * 51;
        return .{ .r = @intCast(r), .g = @intCast(g), .b = @intCast(b), .a = 255 };
    } else {
        const gray = 8 + (idx - 232) * 10;
        return .{ .r = @intCast(gray), .g = @intCast(gray), .b = @intCast(gray), .a = 255 };
    }
}
