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
const font_paths_mod = @import("font_paths.zig");
const config_mod = @import("config.zig");
const ui_mod = @import("ui/mod.zig");
const ghostty_vt = @import("ghostty-vt");
const c = @import("c.zig");

const log = std.log.scoped(.main);

const INITIAL_WINDOW_WIDTH = 1200;
const INITIAL_WINDOW_HEIGHT = 900;
const GRID_ROWS = 3;
const GRID_COLS = 3;
const SCROLL_LINES_PER_TICK: isize = 2;
const MAX_SCROLL_VELOCITY: f32 = 30.0;
const DEFAULT_FONT_SIZE: c_int = 14;
const MIN_FONT_SIZE: c_int = 8;
const MAX_FONT_SIZE: c_int = 96;
const FONT_STEP: c_int = 1;
const UI_FONT_SIZE: c_int = 18;
const SessionStatus = app_state.SessionStatus;
const ViewMode = app_state.ViewMode;
const Rect = app_state.Rect;
const AnimationState = app_state.AnimationState;
const NotificationQueue = notify.NotificationQueue;
const Notification = notify.Notification;
const SessionState = session_state.SessionState;
const FontSizeDirection = input.FontSizeDirection;
const GridNavDirection = input.GridNavDirection;
const CursorKind = enum { arrow, ibeam };

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
    var vsync_requested: bool = true;
    if (std.posix.getenv("ARCHITECT_NO_VSYNC") != null) {
        vsync_requested = false;
    } else if (std.posix.getenv("ARCHITECT_VSYNC")) |val| {
        if (std.ascii.eqlIgnoreCase(val, "0") or
            std.ascii.eqlIgnoreCase(val, "false") or
            std.ascii.eqlIgnoreCase(val, "no"))
        {
            vsync_requested = false;
        } else {
            vsync_requested = true;
        }
    }

    var sdl = try platform.init(
        "Architect - Terminal Wall",
        config.window_width,
        config.window_height,
        window_pos,
        vsync_requested,
    );
    defer platform.deinit(&sdl);
    platform.startTextInput(sdl.window);
    defer platform.stopTextInput(sdl.window);

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cursor| c.SDL_DestroyCursor(cursor);
    const ibeam_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT);
    defer if (ibeam_cursor) |cursor| c.SDL_DestroyCursor(cursor);
    var current_cursor: CursorKind = .arrow;
    if (arrow_cursor) |cursor| {
        _ = c.SDL_SetCursor(cursor);
    }

    const renderer = sdl.renderer;
    const vsync_enabled = sdl.vsync_enabled;

    var font_size: c_int = config.font_size;
    var window_width_points: c_int = sdl.window_w;
    var window_height_points: c_int = sdl.window_h;
    var render_width: c_int = sdl.render_w;
    var render_height: c_int = sdl.render_h;
    var scale_x = sdl.scale_x;
    var scale_y = sdl.scale_y;
    var ui_scale: f32 = @max(scale_x, scale_y);

    var font_paths = try font_paths_mod.FontPaths.init(allocator);
    defer font_paths.deinit();

    var font = try font_mod.Font.init(
        allocator,
        renderer,
        font_paths.regular.ptr,
        if (font_paths.symbol_fallback) |f| f.ptr else null,
        if (font_paths.emoji_fallback) |f| f.ptr else null,
        scaledFontSize(font_size, ui_scale),
    );
    defer font.deinit();

    var ui_font = try font_mod.Font.init(
        allocator,
        renderer,
        font_paths.regular.ptr,
        if (font_paths.symbol_fallback) |f| f.ptr else null,
        if (font_paths.emoji_fallback) |f| f.ptr else null,
        scaledFontSize(UI_FONT_SIZE, ui_scale),
    );
    defer ui_font.deinit();

    var ui = ui_mod.UiRoot.init(allocator);
    defer ui.deinit(renderer);
    ui.assets.ui_font = &ui_font;
    ui.assets.font_path = font_paths.regular;
    ui.assets.symbol_fallback_path = font_paths.symbol_fallback;
    ui.assets.emoji_fallback_path = font_paths.emoji_fallback;

    var window_x: c_int = config.window_x;
    var window_y: c_int = config.window_y;

    const initial_term_size = calculateTerminalSize(&font, render_width, render_height);
    var full_cols: u16 = initial_term_size.cols;
    var full_rows: u16 = initial_term_size.rows;

    std.debug.print("Full window terminal size: {d}x{d}\n", .{ full_cols, full_rows });

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Spawning {d} shell instances: {s}\n", .{ GRID_ROWS * GRID_COLS, shell_path });

    var cell_width_pixels = @divFloor(render_width, GRID_COLS);
    var cell_height_pixels = @divFloor(render_height, GRID_ROWS);

    const usable_width = @max(0, render_width - renderer_mod.TERMINAL_PADDING * 2);
    const usable_height = @max(0, render_height - renderer_mod.TERMINAL_PADDING * 2);

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

    const help_component = try ui_mod.help_overlay.HelpOverlayComponent.create(allocator);
    try ui.register(help_component);
    const toast_component = try ui_mod.toast.ToastComponent.init(allocator);
    try ui.register(toast_component.asComponent());
    const escape_component = try ui_mod.escape_hold.EscapeHoldComponent.init(allocator, &ui_font);
    try ui.register(escape_component.asComponent());
    const restart_component = try ui_mod.restart_buttons.RestartButtonsComponent.init(allocator);
    try ui.register(restart_component.asComponent());

    // Main loop: handle SDL input, feed PTY output into terminals, apply async
    // notifications, drive animations, and render at ~60 FPS.
    var previous_frame_ns: i128 = undefined;
    var first_frame: bool = true;
    while (running) {
        const frame_start_ns: i128 = std.time.nanoTimestamp();
        const now = std.time.milliTimestamp();
        var delta_time_s: f32 = 0.0;
        if (first_frame) {
            first_frame = false;
        } else {
            delta_time_s = @as(f32, @floatFromInt(frame_start_ns - previous_frame_ns)) / 1_000_000_000.0;
        }
        previous_frame_ns = frame_start_ns;

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            var scaled_event = scaleEventToRender(&event, scale_x, scale_y);
            var session_ui_info: [GRID_ROWS * GRID_COLS]ui_mod.SessionUiInfo = undefined;
            const ui_host = makeUiHost(
                now,
                render_width,
                render_height,
                ui_scale,
                cell_width_pixels,
                cell_height_pixels,
                &anim_state,
                &sessions,
                &session_ui_info,
            );

            const ui_consumed = ui.handleEvent(&ui_host, &scaled_event);
            if (ui_consumed) continue;

            switch (scaled_event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_MOVED => {
                    window_x = scaled_event.window.data1;
                    window_y = scaled_event.window.data2;
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    updateRenderSizes(sdl.window, &window_width_points, &window_height_points, &render_width, &render_height, &scale_x, &scale_y);
                    const prev_scale = ui_scale;
                    ui_scale = @max(scale_x, scale_y);
                    if (ui_scale != prev_scale) {
                        font.deinit();
                        ui_font.deinit();
                        font = try font_mod.Font.init(
                            allocator,
                            renderer,
                            font_paths.regular.ptr,
                            if (font_paths.symbol_fallback) |f| f.ptr else null,
                            if (font_paths.emoji_fallback) |f| f.ptr else null,
                            scaledFontSize(font_size, ui_scale),
                        );
                        ui_font = try font_mod.Font.init(
                            allocator,
                            renderer,
                            font_paths.regular.ptr,
                            if (font_paths.symbol_fallback) |f| f.ptr else null,
                            if (font_paths.emoji_fallback) |f| f.ptr else null,
                            scaledFontSize(UI_FONT_SIZE, ui_scale),
                        );
                        ui.assets.ui_font = &ui_font;
                        const new_term_size = calculateTerminalSize(&font, render_width, render_height);
                        full_cols = new_term_size.cols;
                        full_rows = new_term_size.rows;
                        applyTerminalResize(&sessions, allocator, full_cols, full_rows, render_width, render_height);
                    } else {
                        const new_term_size = calculateTerminalSize(&font, render_width, render_height);
                        full_cols = new_term_size.cols;
                        full_rows = new_term_size.rows;
                        applyTerminalResize(&sessions, allocator, full_cols, full_rows, render_width, render_height);
                    }
                    cell_width_pixels = @divFloor(render_width, GRID_COLS);
                    cell_height_pixels = @divFloor(render_height, GRID_ROWS);

                    std.debug.print("Window resized to: {d}x{d} (render {d}x{d}), terminal size: {d}x{d}\n", .{ window_width_points, window_height_points, render_width, render_height, full_cols, full_rows });

                    const updated_config = config_mod.Config{
                        .font_size = font_size,
                        .window_width = window_width_points,
                        .window_height = window_height_points,
                        .window_x = window_x,
                        .window_y = window_y,
                    };
                    updated_config.save(allocator) catch |err| {
                        std.debug.print("Failed to save config: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const focused = &sessions[anim_state.focused_session];
                    handleTextInput(focused, scaled_event.text.text) catch |err| {
                        std.debug.print("Text input failed: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_TEXT_EDITING => {
                    const focused = &sessions[anim_state.focused_session];
                    // Some macOS input methods (emoji picker) may deliver committed text via TEXT_EDITING.
                    if (scaled_event.edit.text != null and scaled_event.edit.length == 0) {
                        handleTextInput(focused, scaled_event.edit.text) catch |err| {
                            std.debug.print("Edit input failed: {}\n", .{err});
                        };
                    }
                },
                c.SDL_EVENT_KEY_DOWN => {
                    const key = scaled_event.key.key;
                    const mod = scaled_event.key.mod;
                    const is_repeat = scaled_event.key.repeat;
                    const focused = &sessions[anim_state.focused_session];

                    const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                    const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;

                    if (key == c.SDLK_C and has_gui and !has_blocking_mod) {
                        copySelectionToClipboard(focused, allocator, toast_component, now) catch |err| {
                            std.debug.print("Copy failed: {}\n", .{err});
                        };
                    } else if (key == c.SDLK_V and has_gui and !has_blocking_mod) {
                        pasteClipboardIntoSession(focused, allocator, toast_component, now) catch |err| {
                            std.debug.print("Paste failed: {}\n", .{err});
                        };
                    } else if (input.fontSizeShortcut(key, mod)) |direction| {
                        const delta: c_int = if (direction == .increase) FONT_STEP else -FONT_STEP;
                        const target_size = std.math.clamp(font_size + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);

                        if (target_size != font_size) {
                            const new_font = try font_mod.Font.init(
                                allocator,
                                renderer,
                                font_paths.regular.ptr,
                                if (font_paths.symbol_fallback) |f| f.ptr else null,
                                if (font_paths.emoji_fallback) |f| f.ptr else null,
                                scaledFontSize(target_size, ui_scale),
                            );
                            font.deinit();
                            font = new_font;
                            font_size = target_size;

                            const term_size = calculateTerminalSize(&font, render_width, render_height);
                            full_cols = term_size.cols;
                            full_rows = term_size.rows;
                            applyTerminalResize(&sessions, allocator, full_cols, full_rows, render_width, render_height);
                            std.debug.print("Font size -> {d}px, terminal size: {d}x{d}\n", .{ font_size, full_cols, full_rows });

                            const updated_config = config_mod.Config{
                                .font_size = font_size,
                                .window_width = window_width_points,
                                .window_height = window_height_points,
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
                        toast_component.show(notification_msg, now);
                    } else if (input.isSwitchTerminalShortcut(key, mod)) |is_next| {
                        if (anim_state.mode == .Full) {
                            const total_sessions = GRID_ROWS * GRID_COLS;
                            const new_session = if (is_next)
                                (anim_state.focused_session + 1) % total_sessions
                            else
                                (anim_state.focused_session + total_sessions - 1) % total_sessions;

                            try sessions[new_session].ensureSpawned();
                            sessions[anim_state.focused_session].clearSelection();
                            sessions[new_session].clearSelection();

                            anim_state.mode = if (is_next) .PanningLeft else .PanningRight;
                            anim_state.previous_session = anim_state.focused_session;
                            anim_state.focused_session = new_session;
                            anim_state.start_time = now;
                            std.debug.print("Panning to session {d} from {d}\n", .{ new_session, anim_state.previous_session });

                            var notification_buf: [64]u8 = undefined;
                            const hotkey = if (is_next) "⌘⇧]" else "⌘⇧[";
                            const notification_msg = std.fmt.bufPrint(&notification_buf, "{s}  Terminal {d}", .{ hotkey, new_session }) catch "Terminal switched";
                            toast_component.show(notification_msg, now);
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
                        const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                        anim_state.mode = .Expanding;
                        anim_state.focused_session = clicked_session;
                        anim_state.start_time = now;
                        anim_state.start_rect = start_rect;
                        anim_state.target_rect = target_rect;
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    } else {
                        if (focused.spawned and !focused.dead) {
                            try handleKeyInput(focused, key, mod, is_repeat);
                        }
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    const key = scaled_event.key.key;
                    if (key == c.SDLK_ESCAPE and input.canHandleEscapePress(anim_state.mode)) {
                        const focused = &sessions[anim_state.focused_session];
                        if (focused.spawned and !focused.dead and focused.shell != null) {
                            const esc_byte: [1]u8 = .{27};
                            _ = focused.shell.?.write(&esc_byte) catch {};
                        }
                        std.debug.print("Escape released, sent to terminal\n", .{});
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    const mouse_x: c_int = @intFromFloat(scaled_event.button.x);
                    const mouse_y: c_int = @intFromFloat(scaled_event.button.y);

                    if (anim_state.mode == .Grid) {
                        sessions[anim_state.focused_session].clearSelection();
                        const grid_col = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), GRID_COLS - 1);
                        const grid_row = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), GRID_ROWS - 1);
                        const clicked_session: usize = grid_row * @as(usize, GRID_COLS) + grid_col;

                        const cell_rect = Rect{
                            .x = @as(c_int, @intCast(grid_col)) * cell_width_pixels,
                            .y = @as(c_int, @intCast(grid_row)) * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };

                        try sessions[clicked_session].ensureSpawned();

                        sessions[clicked_session].status = .running;
                        sessions[clicked_session].attention = false;

                        const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                        anim_state.mode = .Expanding;
                        anim_state.focused_session = clicked_session;
                        anim_state.start_time = now;
                        anim_state.start_rect = cell_rect;
                        anim_state.target_rect = target_rect;
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    } else if (anim_state.mode == .Full and scaled_event.button.button == c.SDL_BUTTON_LEFT) {
                        const focused = &sessions[anim_state.focused_session];
                        if (focused.spawned) {
                            if (fullViewPinFromMouse(focused, mouse_x, mouse_y, render_width, render_height, &font, full_cols, full_rows)) |pin| {
                                beginSelection(focused, pin);
                            }
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (scaled_event.button.button == c.SDL_BUTTON_LEFT and anim_state.mode == .Full) {
                        const focused = &sessions[anim_state.focused_session];
                        endSelection(focused);
                    }
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    const mouse_x: c_int = @intFromFloat(scaled_event.motion.x);
                    const mouse_y: c_int = @intFromFloat(scaled_event.motion.y);
                    const over_ui = ui.hitTest(&ui_host, mouse_x, mouse_y);
                    var desired_cursor: CursorKind = .arrow;

                    if (anim_state.mode == .Full) {
                        const focused = &sessions[anim_state.focused_session];
                        const pin = fullViewPinFromMouse(focused, mouse_x, mouse_y, render_width, render_height, &font, full_cols, full_rows);

                        if (focused.selection_dragging) {
                            if (pin) |p| {
                                updateSelectionDrag(focused, p);
                            }
                        } else if (focused.selection_pending) {
                            if (focused.selection_anchor) |anchor| {
                                if (pin) |p| {
                                    if (!pinsEqual(anchor, p)) {
                                        startSelectionDrag(focused, p);
                                    }
                                }
                            } else {
                                focused.selection_pending = false;
                            }
                        }

                        if (!over_ui and pin != null) {
                            desired_cursor = .ibeam;
                        }
                    }

                    if (desired_cursor != current_cursor) {
                        const target_cursor = switch (desired_cursor) {
                            .arrow => arrow_cursor,
                            .ibeam => ibeam_cursor,
                        };
                        if (target_cursor) |cursor| {
                            _ = c.SDL_SetCursor(cursor);
                            current_cursor = desired_cursor;
                        }
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    const mouse_x: c_int = @intFromFloat(scaled_event.wheel.mouse_x);
                    const mouse_y: c_int = @intFromFloat(scaled_event.wheel.mouse_y);

                    const hovered_session = calculateHoveredSession(
                        mouse_x,
                        mouse_y,
                        &anim_state,
                        cell_width_pixels,
                        cell_height_pixels,
                        render_width,
                        render_height,
                    );

                    if (hovered_session) |session_idx| {
                        const raw_delta = scaled_event.wheel.y;
                        const scroll_delta = -@as(isize, @intFromFloat(raw_delta * @as(f32, @floatFromInt(SCROLL_LINES_PER_TICK))));
                        if (scroll_delta != 0) {
                            scrollSession(&sessions[session_idx], scroll_delta, now);
                            // If the wheel event originates from a touch/trackpad
                            // contact (SDL_TOUCH_MOUSEID), keep inertia suppressed
                            // until the contact is released.
                            if (scaled_event.wheel.which == c.SDL_TOUCH_MOUSEID) {
                                sessions[session_idx].scroll_inertia_allowed = false;
                            }
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
            updateScrollInertia(session, delta_time_s);
        }

        var notifications = notify_queue.drainAll();
        defer notifications.deinit(allocator);
        for (notifications.items) |note| {
            if (note.session < sessions.len) {
                var session = &sessions[note.session];
                session.status = note.state;
                const wants_attention = switch (note.state) {
                    .awaiting_approval, .done => true,
                    else => false,
                };
                const is_focused_full = anim_state.mode == .Full and anim_state.focused_session == note.session;
                session.attention = if (is_focused_full) false else wants_attention;
                std.debug.print("Session {d} status -> {s}\n", .{ note.session, @tagName(note.state) });
            }
        }

        var ui_update_info: [GRID_ROWS * GRID_COLS]ui_mod.SessionUiInfo = undefined;
        const ui_update_host = makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            &anim_state,
            &sessions,
            &ui_update_info,
        );
        ui.update(&ui_update_host);

        while (ui.popAction()) |action| switch (action) {
            .RestartSession => |idx| {
                if (idx < sessions.len) {
                    try sessions[idx].restart();
                    std.debug.print("UI requested restart: {d}\n", .{idx});
                }
            },
            .RequestCollapseFocused => {
                if (anim_state.mode == .Full) {
                    startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height);
                    std.debug.print("UI requested collapse of focused session: {d}\n", .{anim_state.focused_session});
                }
            },
        };

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing or
            anim_state.mode == .PanningLeft or anim_state.mode == .PanningRight)
        {
            if (anim_state.isComplete(now)) {
                anim_state.mode = switch (anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight => .Full,
                    .Collapsing => .Grid,
                    else => anim_state.mode,
                };
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        try renderer_mod.render(renderer, &sessions, cell_width_pixels, cell_height_pixels, GRID_COLS, &anim_state, now, &font, full_cols, full_rows, render_width, render_height, ui_scale, font_paths.regular);
        var ui_render_info: [GRID_ROWS * GRID_COLS]ui_mod.SessionUiInfo = undefined;
        const ui_render_host = makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            &anim_state,
            &sessions,
            &ui_render_info,
        );
        ui.render(&ui_render_host, renderer);
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

fn startCollapseToGrid(
    anim_state: *AnimationState,
    now: i64,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    render_width: c_int,
    render_height: c_int,
) void {
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
    anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };
    anim_state.target_rect = target_rect;
}

fn updateRenderSizes(
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

fn scaleEventToRender(event: *const c.SDL_Event, scale_x: f32, scale_y: f32) c.SDL_Event {
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
        else => {},
    }
    return e;
}

fn makeUiHost(
    now: i64,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    anim_state: *const AnimationState,
    sessions: []const SessionState,
    buffer: []ui_mod.SessionUiInfo,
) ui_mod.UiHost {
    for (sessions, 0..) |session, i| {
        buffer[i] = .{
            .dead = session.dead,
            .spawned = session.spawned,
        };
    }

    return .{
        .now_ms = now,
        .window_w = render_width,
        .window_h = render_height,
        .ui_scale = ui_scale,
        .grid_cols = GRID_COLS,
        .grid_rows = GRID_ROWS,
        .cell_w = cell_width_pixels,
        .cell_h = cell_height_pixels,
        .view_mode = anim_state.mode,
        .focused_session = anim_state.focused_session,
        .sessions = buffer[0..sessions.len],
    };
}

fn calculateHoveredSession(
    mouse_x: c_int,
    mouse_y: c_int,
    anim_state: *const AnimationState,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    render_width: c_int,
    render_height: c_int,
) ?usize {
    return switch (anim_state.mode) {
        .Grid => {
            if (mouse_x < 0 or mouse_x >= render_width or
                mouse_y < 0 or mouse_y >= render_height) return null;

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

fn scrollSession(session: *SessionState, delta: isize, now: i64) void {
    if (!session.spawned) return;

    session.last_scroll_time = now;
    session.scroll_remainder = 0.0;
    session.scroll_inertia_allowed = true;

    if (session.terminal) |*terminal| {
        var pages = &terminal.screens.active.pages;
        pages.scroll(.{ .delta_row = delta });
        session.is_scrolled = (pages.viewport != .active);
        session.dirty = true;
    }

    const sensitivity: f32 = 0.08;
    session.scroll_velocity += @as(f32, @floatFromInt(delta)) * sensitivity;
    session.scroll_velocity = std.math.clamp(session.scroll_velocity, -MAX_SCROLL_VELOCITY, MAX_SCROLL_VELOCITY);
}

fn updateScrollInertia(session: *SessionState, delta_time_s: f32) void {
    if (!session.spawned) return;
    if (!session.scroll_inertia_allowed) return;
    if (session.scroll_velocity == 0.0) return;
    if (session.last_scroll_time == 0) return;

    const decay_constant: f32 = 7.5;
    const decay_factor = std.math.exp(-decay_constant * delta_time_s);
    const velocity_threshold: f32 = 0.12;

    if (@abs(session.scroll_velocity) < velocity_threshold) {
        session.scroll_velocity = 0.0;
        session.scroll_remainder = 0.0;
        return;
    }

    const reference_fps: f32 = 60.0;

    if (session.terminal) |*terminal| {
        const scroll_amount = session.scroll_velocity * delta_time_s * reference_fps + session.scroll_remainder;
        const scroll_lines: isize = @intFromFloat(scroll_amount);

        if (scroll_lines != 0) {
            var pages = &terminal.screens.active.pages;
            pages.scroll(.{ .delta_row = scroll_lines });
            session.is_scrolled = (pages.viewport != .active);
            session.dirty = true;
        }

        session.scroll_remainder = scroll_amount - @as(f32, @floatFromInt(scroll_lines));
    }

    session.scroll_velocity *= decay_factor;
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

fn scaledFontSize(points: c_int, scale: f32) c_int {
    const scaled = std.math.round(@as(f32, @floatFromInt(points)) * scale);
    return @max(1, @as(c_int, @intFromFloat(scaled)));
}

fn applyTerminalResize(
    sessions: []SessionState,
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
            focused.scroll_velocity = 0.0;
            focused.scroll_remainder = 0.0;
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

fn fullViewPinFromMouse(
    session: *SessionState,
    mouse_x: c_int,
    mouse_y: c_int,
    render_width: c_int,
    render_height: c_int,
    font: *const font_mod.Font,
    term_cols: u16,
    term_rows: u16,
) ?ghostty_vt.Pin {
    if (!session.spawned or session.terminal == null) return null;

    const padding = renderer_mod.TERMINAL_PADDING;
    const origin_x: c_int = padding;
    const origin_y: c_int = padding;
    const drawable_w: c_int = render_width - padding * 2;
    const drawable_h: c_int = render_height - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return null;

    const cell_w: c_int = font.cell_width;
    const cell_h: c_int = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return null;

    if (mouse_x < origin_x or mouse_y < origin_y) return null;
    if (mouse_x >= origin_x + drawable_w or mouse_y >= origin_y + drawable_h) return null;

    const col = @as(u16, @intCast(@divFloor(mouse_x - origin_x, cell_w)));
    const row = @as(u16, @intCast(@divFloor(mouse_y - origin_y, cell_h)));
    if (col >= term_cols or row >= term_rows) return null;

    const point = if (session.is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = col, .y = row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = col, .y = row } };

    const terminal = session.terminal orelse return null;
    return terminal.screens.active.pages.pin(point);
}

fn beginSelection(session: *SessionState, pin: ghostty_vt.Pin) void {
    const terminal = session.terminal orelse return;
    terminal.screens.active.clearSelection();
    session.selection_anchor = pin;
    session.selection_pending = true;
    session.selection_dragging = false;
    session.dirty = true;
}

fn startSelectionDrag(session: *SessionState, pin: ghostty_vt.Pin) void {
    const terminal = session.terminal orelse return;
    const anchor = session.selection_anchor orelse return;

    session.selection_dragging = true;
    session.selection_pending = false;

    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(anchor, pin, false)) catch {};
    session.dirty = true;
}

fn updateSelectionDrag(session: *SessionState, pin: ghostty_vt.Pin) void {
    if (!session.selection_dragging) return;
    const anchor = session.selection_anchor orelse return;
    const terminal = session.terminal orelse return;
    terminal.screens.active.select(ghostty_vt.Selection.init(anchor, pin, false)) catch {};
    session.dirty = true;
}

fn endSelection(session: *SessionState) void {
    session.selection_dragging = false;
    session.selection_pending = false;
    session.selection_anchor = null;
}

fn pinsEqual(a: ghostty_vt.Pin, b: ghostty_vt.Pin) bool {
    return a.node == b.node and a.x == b.x and a.y == b.y;
}

fn handleTextInput(session: *SessionState, text_ptr: [*c]const u8) !void {
    if (!session.spawned or session.dead) return;
    if (text_ptr == null) return;

    const text = std.mem.sliceTo(text_ptr, 0);
    if (text.len == 0) return;

    if (session.is_scrolled) {
        if (session.terminal) |*terminal| {
            terminal.screens.active.pages.scroll(.{ .active = {} });
            session.is_scrolled = false;
            session.scroll_velocity = 0.0;
            session.scroll_remainder = 0.0;
        }
    }

    if (session.shell) |*shell| {
        _ = try shell.write(text);
    }
}

fn copySelectionToClipboard(
    session: *SessionState,
    allocator: std.mem.Allocator,
    toast: *ui_mod.toast.ToastComponent,
    now: i64,
) !void {
    const terminal = session.terminal orelse {
        toast.show("No terminal to copy from", now);
        return;
    };
    const screen = terminal.screens.active;
    const sel = screen.selection orelse {
        toast.show("No selection", now);
        return;
    };

    const text = try screen.selectionString(allocator, .{ .sel = sel, .trim = true });
    defer allocator.free(text);

    const clipboard_text = try allocator.allocSentinel(u8, text.len, 0);
    defer allocator.free(clipboard_text);
    @memcpy(clipboard_text[0..text.len], text);

    if (!c.SDL_SetClipboardText(clipboard_text.ptr)) {
        toast.show("Failed to copy selection", now);
        return;
    }

    toast.show("Copied selection", now);
}

fn pasteClipboardIntoSession(
    session: *SessionState,
    allocator: std.mem.Allocator,
    toast: *ui_mod.toast.ToastComponent,
    now: i64,
) !void {
    const terminal = session.terminal orelse {
        toast.show("No terminal to paste into", now);
        return;
    };
    const shell_ptr = if (session.shell) |*s| s else {
        toast.show("Shell not available", now);
        return;
    };

    const clip_ptr = c.SDL_GetClipboardText();
    defer c.SDL_free(clip_ptr);
    if (clip_ptr == null) {
        toast.show("Clipboard empty", now);
        return;
    }
    const clip = std.mem.sliceTo(clip_ptr, 0);
    if (clip.len == 0) {
        toast.show("Clipboard empty", now);
        return;
    }

    if (!ghostty_vt.input.isSafePaste(clip)) {
        toast.show("Clipboard blocked (unsafe paste)", now);
        return;
    }

    const opts = ghostty_vt.input.PasteOptions.fromTerminal(&terminal);
    const clip_buf = try allocator.dupe(u8, clip);
    defer allocator.free(clip_buf);
    const slices = ghostty_vt.input.encodePaste(clip_buf, opts);

    for (slices) |part| {
        if (part.len == 0) continue;
        _ = try shell_ptr.write(part);
    }

    toast.show("Pasted clipboard", now);
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
