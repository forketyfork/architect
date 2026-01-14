// Main application entry: wires SDL2 rendering, ghostty-vt terminals, PTY-backed
// shells, and the grid/animation system that drives the 3×3 terminal wall UI.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const xev = @import("xev");
const app_state = @import("app/app_state.zig");
const notify = @import("session/notify.zig");
const session_state = @import("session/state.zig");
const vt_stream = @import("vt_stream.zig");
const platform = @import("platform/sdl.zig");
const input = @import("input/mapper.zig");
const renderer_mod = @import("render/renderer.zig");
const shell_mod = @import("shell.zig");
const pty_mod = @import("pty.zig");
const font_mod = @import("font.zig");
const font_paths_mod = @import("font_paths.zig");
const config_mod = @import("config.zig");
const colors_mod = @import("colors.zig");
const ui_mod = @import("ui/mod.zig");
const ghostty_vt = @import("ghostty-vt");
const c = @import("c.zig");
const open_url = @import("os/open.zig");
const url_matcher = @import("url_matcher.zig");

const log = std.log.scoped(.main);

const INITIAL_WINDOW_WIDTH = 1200;
const INITIAL_WINDOW_HEIGHT = 900;
const SCROLL_LINES_PER_TICK: isize = 1;
const MAX_SCROLL_VELOCITY: f32 = 30.0;
const DEFAULT_FONT_SIZE: c_int = 14;
const MIN_FONT_SIZE: c_int = 8;
const MAX_FONT_SIZE: c_int = 96;
const FONT_STEP: c_int = 1;
const UI_FONT_SIZE: c_int = 18;
const ACTIVE_FRAME_NS: i128 = 16_666_667;
const IDLE_FRAME_NS: i128 = 50_000_000;
const MAX_IDLE_RENDER_GAP_NS: i128 = 250_000_000;
const SessionStatus = app_state.SessionStatus;
const ViewMode = app_state.ViewMode;
const Rect = app_state.Rect;
const AnimationState = app_state.AnimationState;
const NotificationQueue = notify.NotificationQueue;
const Notification = notify.Notification;
const SessionState = session_state.SessionState;
const FontSizeDirection = input.FontSizeDirection;
const GridNavDirection = input.GridNavDirection;
const CursorKind = enum { arrow, ibeam, pointer };

fn countForegroundProcesses(sessions: []const SessionState) usize {
    var total: usize = 0;
    for (sessions) |*session| {
        if (session.hasForegroundProcess()) {
            total += 1;
        }
    }
    return total;
}

fn findNextFreeSession(sessions: []const SessionState, current_idx: usize) ?usize {
    const start_idx = current_idx + 1;
    var idx = start_idx;
    while (idx < sessions.len) : (idx += 1) {
        if (!sessions[idx].spawned) {
            return idx;
        }
    }
    idx = 0;
    while (idx < start_idx) : (idx += 1) {
        if (!sessions[idx].spawned) {
            return idx;
        }
    }
    return null;
}

fn handleQuitRequest(
    sessions: []const SessionState,
    confirm: *ui_mod.quit_confirm.QuitConfirmComponent,
) bool {
    const running_processes = countForegroundProcesses(sessions);
    if (running_processes > 0) {
        confirm.show(running_processes);
        return false;
    }
    return true;
}

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

    var notify_stop = std.atomic.Value(bool).init(false);
    const notify_thread = try notify.startNotifyThread(allocator, notify_sock, &notify_queue, &notify_stop);
    defer {
        notify_stop.store(true, .seq_cst);
        notify_thread.join();
    }

    var config = config_mod.Config.load(allocator) catch |err| blk: {
        if (err == error.ConfigNotFound) {
            std.debug.print("Config not found, creating default config file\n", .{});
            config_mod.Config.createDefaultConfigFile(allocator) catch |create_err| {
                std.debug.print("Failed to create default config: {}\n", .{create_err});
            };
        } else {
            std.debug.print("Failed to load config: {}, using defaults\n", .{err});
        }
        break :blk config_mod.Config{
            .font = .{ .size = DEFAULT_FONT_SIZE },
            .window = .{
                .width = INITIAL_WINDOW_WIDTH,
                .height = INITIAL_WINDOW_HEIGHT,
            },
            .grid = .{
                .rows = config_mod.DEFAULT_GRID_ROWS,
                .cols = config_mod.DEFAULT_GRID_COLS,
            },
        };
    };
    defer config.deinit(allocator);

    var persistence = config_mod.Persistence.load(allocator) catch |err| blk: {
        std.debug.print("Failed to load persistence: {}, using defaults\n", .{err});
        var fallback = config_mod.Persistence.init(allocator);
        fallback.font_size = config.font.size;
        fallback.window = config.window;
        break :blk fallback;
    };
    defer persistence.deinit();
    persistence.font_size = std.math.clamp(persistence.font_size, MIN_FONT_SIZE, MAX_FONT_SIZE);

    const theme = colors_mod.Theme.fromConfig(config.theme);

    const grid_rows: usize = @intCast(config.grid.rows);
    const grid_cols: usize = @intCast(config.grid.cols);
    const grid_count: usize = grid_rows * grid_cols;
    const pruned_terminals = persistence.pruneTerminals(allocator, grid_cols, grid_rows) catch |err| blk: {
        std.debug.print("Failed to prune persisted terminals: {}\n", .{err});
        break :blk false;
    };
    if (pruned_terminals) {
        persistence.save(allocator) catch |err| {
            std.debug.print("Failed to save pruned persistence: {}\n", .{err});
        };
    }
    var restored_terminals = if (builtin.os.tag == .macos)
        persistence.collectTerminalEntries(allocator, grid_cols, grid_rows) catch |err| blk: {
            std.debug.print("Failed to collect persisted terminals: {}\n", .{err});
            break :blk std.ArrayList(config_mod.Persistence.TerminalEntry).empty;
        }
    else
        std.ArrayList(config_mod.Persistence.TerminalEntry).empty;
    defer restored_terminals.deinit(allocator);
    var current_grid_font_scale: f32 = config.grid.font_scale;
    const animations_enabled = config.ui.enable_animations;

    const window_pos = if (persistence.window.x >= 0 and persistence.window.y >= 0)
        platform.WindowPosition{ .x = persistence.window.x, .y = persistence.window.y }
    else
        null;

    var sdl = try platform.init(
        "ARCHITECT",
        persistence.window.width,
        persistence.window.height,
        window_pos,
        config.rendering.vsync,
    );
    defer platform.deinit(&sdl);
    platform.startTextInput(sdl.window);
    defer platform.stopTextInput(sdl.window);

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cursor| c.SDL_DestroyCursor(cursor);
    const ibeam_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT);
    defer if (ibeam_cursor) |cursor| c.SDL_DestroyCursor(cursor);
    const pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    defer if (pointer_cursor) |cursor| c.SDL_DestroyCursor(cursor);
    var current_cursor: CursorKind = .arrow;
    if (arrow_cursor) |cursor| {
        _ = c.SDL_SetCursor(cursor);
    }

    const renderer = sdl.renderer;

    var font_size: c_int = persistence.font_size;
    var window_width_points: c_int = sdl.window_w;
    var window_height_points: c_int = sdl.window_h;
    var render_width: c_int = sdl.render_w;
    var render_height: c_int = sdl.render_h;
    var scale_x = sdl.scale_x;
    var scale_y = sdl.scale_y;
    var ui_scale: f32 = @max(scale_x, scale_y);

    var font_paths = try font_paths_mod.FontPaths.init(allocator, config.font.family);
    defer font_paths.deinit();

    var font = try font_mod.Font.init(
        allocator,
        renderer,
        font_paths.regular.ptr,
        font_paths.bold.ptr,
        font_paths.italic.ptr,
        font_paths.bold_italic.ptr,
        if (font_paths.symbol_fallback) |f| f.ptr else null,
        if (font_paths.emoji_fallback) |f| f.ptr else null,
        scaledFontSize(font_size, ui_scale),
    );
    defer font.deinit();

    var ui_font = try font_mod.Font.init(
        allocator,
        renderer,
        font_paths.regular.ptr,
        font_paths.bold.ptr,
        font_paths.italic.ptr,
        font_paths.bold_italic.ptr,
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

    var window_x: c_int = persistence.window.x;
    var window_y: c_int = persistence.window.y;

    const initial_term_size = calculateTerminalSize(&font, render_width, render_height, current_grid_font_scale);
    var full_cols: u16 = initial_term_size.cols;
    var full_rows: u16 = initial_term_size.rows;

    std.debug.print("Full window terminal size: {d}x{d}\n", .{ full_cols, full_rows });

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Spawning {d} shell instances ({d}x{d} grid): {s}\n", .{ grid_count, grid_cols, grid_rows, shell_path });

    var cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid_cols)));
    var cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid_rows)));

    const usable_width = @max(0, render_width - renderer_mod.TERMINAL_PADDING * 2);
    const usable_height = @max(0, render_height - renderer_mod.TERMINAL_PADDING * 2);

    const size = pty_mod.winsize{
        .ws_row = full_rows,
        .ws_col = full_cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    const sessions = try allocator.alloc(SessionState, grid_count);
    var init_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < init_count) : (i += 1) {
            sessions[i].deinit(allocator);
        }
        allocator.free(sessions);
    }

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    for (0..grid_count) |i| {
        var session_buf: [16]u8 = undefined;
        const session_z = try std.fmt.bufPrintZ(&session_buf, "{d}", .{i});
        sessions[i] = try SessionState.init(allocator, i, shell_path, size, session_z, notify_sock);
        init_count += 1;
    }

    for (restored_terminals.items) |entry| {
        if (entry.index >= sessions.len or entry.path.len == 0) continue;
        const dir_buf = allocZ(allocator, entry.path) catch |err| blk: {
            std.debug.print("Failed to restore terminal {d}: {}\n", .{ entry.index, err });
            break :blk null;
        };
        defer if (dir_buf) |buf| allocator.free(buf);
        if (dir_buf) |buf| {
            const dir: [:0]const u8 = buf[0..entry.path.len :0];
            sessions[entry.index].ensureSpawnedWithDir(dir, &loop) catch |err| {
                std.debug.print("Failed to spawn restored terminal {d}: {}\n", .{ entry.index, err });
            };
        }
    }

    try sessions[0].ensureSpawnedWithLoop(&loop);

    init_count = sessions.len;

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
    ui.toast_component = toast_component;
    const escape_component = try ui_mod.escape_hold.EscapeHoldComponent.init(allocator, &ui_font);
    try ui.register(escape_component.asComponent());
    const hotkey_component = try ui_mod.hotkey_indicator.HotkeyIndicatorComponent.init(allocator, &ui_font);
    try ui.register(hotkey_component.asComponent());
    ui.hotkey_component = hotkey_component;
    const restart_component = try ui_mod.restart_buttons.RestartButtonsComponent.init(allocator);
    try ui.register(restart_component.asComponent());
    const quit_confirm_component = try ui_mod.quit_confirm.QuitConfirmComponent.init(allocator);
    try ui.register(quit_confirm_component.asComponent());
    const confirm_dialog_component = try ui_mod.confirm_dialog.ConfirmDialogComponent.init(allocator);
    try ui.register(confirm_dialog_component.asComponent());
    const global_shortcuts_component = try ui_mod.global_shortcuts.GlobalShortcutsComponent.create(allocator);
    try ui.register(global_shortcuts_component);

    // Main loop: handle SDL input, feed PTY output into terminals, apply async
    // notifications, drive animations, and render at ~60 FPS.
    var previous_frame_ns: i128 = undefined;
    var first_frame: bool = true;
    var last_render_ns: i128 = 0;
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
        var processed_event = false;
        while (c.SDL_PollEvent(&event)) {
            processed_event = true;
            var scaled_event = scaleEventToRender(&event, scale_x, scale_y);
            const session_ui_info = try allocator.alloc(ui_mod.SessionUiInfo, grid_count);
            defer allocator.free(session_ui_info);
            const ui_host = makeUiHost(
                now,
                render_width,
                render_height,
                ui_scale,
                cell_width_pixels,
                cell_height_pixels,
                grid_cols,
                grid_rows,
                &anim_state,
                sessions,
                session_ui_info,
                &theme,
            );

            const ui_consumed = ui.handleEvent(&ui_host, &scaled_event);
            if (ui_consumed) continue;

            switch (scaled_event.type) {
                c.SDL_EVENT_QUIT => {
                    if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                        running = false;
                    }
                },
                c.SDL_EVENT_WINDOW_MOVED => {
                    window_x = scaled_event.window.data1;
                    window_y = scaled_event.window.data2;

                    persistence.window.x = window_x;
                    persistence.window.y = window_y;
                    persistence.save(allocator) catch |err| {
                        std.debug.print("Failed to save persistence: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    updateRenderSizes(sdl.window, &window_width_points, &window_height_points, &render_width, &render_height, &scale_x, &scale_y);
                    const prev_scale = ui_scale;
                    ui_scale = @max(scale_x, scale_y);
                    const desired_font_scale = gridFontScaleForMode(anim_state.mode, config.grid.font_scale);
                    if (ui_scale != prev_scale) {
                        font.deinit();
                        ui_font.deinit();
                        font = try font_mod.Font.init(
                            allocator,
                            renderer,
                            font_paths.regular.ptr,
                            font_paths.bold.ptr,
                            font_paths.italic.ptr,
                            font_paths.bold_italic.ptr,
                            if (font_paths.symbol_fallback) |f| f.ptr else null,
                            if (font_paths.emoji_fallback) |f| f.ptr else null,
                            scaledFontSize(font_size, ui_scale),
                        );
                        ui_font = try font_mod.Font.init(
                            allocator,
                            renderer,
                            font_paths.regular.ptr,
                            font_paths.bold.ptr,
                            font_paths.italic.ptr,
                            font_paths.bold_italic.ptr,
                            if (font_paths.symbol_fallback) |f| f.ptr else null,
                            if (font_paths.emoji_fallback) |f| f.ptr else null,
                            scaledFontSize(UI_FONT_SIZE, ui_scale),
                        );
                        ui.assets.ui_font = &ui_font;
                        const new_term_size = calculateTerminalSize(&font, render_width, render_height, desired_font_scale);
                        full_cols = new_term_size.cols;
                        full_rows = new_term_size.rows;
                        applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, render_height);
                    } else {
                        const new_term_size = calculateTerminalSize(&font, render_width, render_height, desired_font_scale);
                        full_cols = new_term_size.cols;
                        full_rows = new_term_size.rows;
                        applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, render_height);
                    }
                    cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid_cols)));
                    cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid_rows)));

                    std.debug.print("Window resized to: {d}x{d} (render {d}x{d}), terminal size: {d}x{d}\n", .{ window_width_points, window_height_points, render_width, render_height, full_cols, full_rows });

                    persistence.window.width = window_width_points;
                    persistence.window.height = window_height_points;
                    persistence.window.x = window_x;
                    persistence.window.y = window_y;
                    persistence.save(allocator) catch |err| {
                        std.debug.print("Failed to save persistence: {}\n", .{err});
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
                c.SDL_EVENT_DROP_FILE => {
                    const drop_path_ptr = scaled_event.drop.data;
                    if (drop_path_ptr == null) continue;
                    const drop_path = std.mem.span(drop_path_ptr.?);
                    if (drop_path.len == 0) continue;

                    const mouse_x: c_int = @intFromFloat(scaled_event.drop.x);
                    const mouse_y: c_int = @intFromFloat(scaled_event.drop.y);

                    const hovered_session = calculateHoveredSession(
                        mouse_x,
                        mouse_y,
                        &anim_state,
                        cell_width_pixels,
                        cell_height_pixels,
                        render_width,
                        render_height,
                        grid_cols,
                        grid_rows,
                    ) orelse continue;

                    var session = &sessions[hovered_session];
                    try session.ensureSpawnedWithLoop(&loop);

                    const escaped = shellQuotePath(allocator, drop_path) catch |err| {
                        std.debug.print("Failed to escape dropped path: {}\n", .{err});
                        continue;
                    };
                    defer allocator.free(escaped);

                    pasteText(session, allocator, escaped) catch |err| switch (err) {
                        error.NoTerminal => ui.showToast("No terminal to paste into", now),
                        error.NoShell => ui.showToast("Shell not available", now),
                        else => std.debug.print("Failed to paste dropped path: {}\n", .{err}),
                    };
                },
                c.SDL_EVENT_KEY_DOWN => {
                    const key = scaled_event.key.key;
                    const mod = scaled_event.key.mod;
                    const focused = &sessions[anim_state.focused_session];

                    const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                    const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;

                    if (has_gui and !has_blocking_mod and key == c.SDLK_Q) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘Q", now);
                        if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                            running = false;
                        }
                        continue;
                    }

                    if (has_gui and !has_blocking_mod and key == c.SDLK_W) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘W", now);
                        const session_idx = anim_state.focused_session;
                        const session = &sessions[session_idx];

                        if (!session.spawned) {
                            continue;
                        }

                        if (session.hasForegroundProcess()) {
                            confirm_dialog_component.show(
                                "Delete Terminal?",
                                "A process is running. Delete anyway?",
                                "Delete",
                                "Cancel",
                                .{ .DespawnSession = session_idx },
                            );
                        } else {
                            if (anim_state.mode == .Full) {
                                if (animations_enabled) {
                                    startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid_cols);
                                } else {
                                    anim_state.mode = .Grid;
                                }
                            }
                            session.deinit(allocator);
                            session.dirty = true;
                        }
                        continue;
                    }

                    if (key == c.SDLK_K and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘K", now);
                        clearTerminal(focused);
                        ui.showToast("Cleared terminal", now);
                    } else if (key == c.SDLK_C and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘C", now);
                        copySelectionToClipboard(focused, allocator, &ui, now) catch |err| {
                            std.debug.print("Copy failed: {}\n", .{err});
                        };
                    } else if (key == c.SDLK_V and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘V", now);
                        pasteClipboardIntoSession(focused, allocator, &ui, now) catch |err| {
                            std.debug.print("Paste failed: {}\n", .{err});
                        };
                    } else if (input.fontSizeShortcut(key, mod)) |direction| {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(if (direction == .increase) "⌘+" else "⌘-", now);
                        const delta: c_int = if (direction == .increase) FONT_STEP else -FONT_STEP;
                        const target_size = std.math.clamp(font_size + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);

                        if (target_size != font_size) {
                            const new_font = try font_mod.Font.init(
                                allocator,
                                renderer,
                                font_paths.regular.ptr,
                                font_paths.bold.ptr,
                                font_paths.italic.ptr,
                                font_paths.bold_italic.ptr,
                                if (font_paths.symbol_fallback) |f| f.ptr else null,
                                if (font_paths.emoji_fallback) |f| f.ptr else null,
                                scaledFontSize(target_size, ui_scale),
                            );
                            font.deinit();
                            font = new_font;
                            font_size = target_size;

                            const desired_font_scale = gridFontScaleForMode(anim_state.mode, config.grid.font_scale);
                            const term_size = calculateTerminalSize(&font, render_width, render_height, desired_font_scale);
                            full_cols = term_size.cols;
                            full_rows = term_size.rows;
                            applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, render_height);
                            std.debug.print("Font size -> {d}px, terminal size: {d}x{d}\n", .{ font_size, full_cols, full_rows });

                            persistence.font_size = font_size;
                            persistence.save(allocator) catch |err| {
                                std.debug.print("Failed to save persistence: {}\n", .{err});
                            };
                        }

                        var notification_buf: [64]u8 = undefined;
                        const notification_msg = std.fmt.bufPrint(&notification_buf, "Font size: {d}pt", .{font_size}) catch "Font size changed";
                        ui.showToast(notification_msg, now);
                    } else if ((key == c.SDLK_T or key == c.SDLK_N) and has_gui and !has_blocking_mod and anim_state.mode == .Full) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(if (key == c.SDLK_T) "⌘T" else "⌘N", now);
                        if (findNextFreeSession(sessions, anim_state.focused_session)) |next_free_idx| {
                            const cwd_path = focused.cwd_path;
                            var cwd_buf: ?[]u8 = null;
                            const cwd_z: ?[:0]const u8 = if (cwd_path) |path| blk: {
                                const buf = allocator.alloc(u8, path.len + 1) catch break :blk null;
                                @memcpy(buf[0..path.len], path);
                                buf[path.len] = 0;
                                cwd_buf = buf;
                                break :blk buf[0..path.len :0];
                            } else null;

                            defer if (cwd_buf) |buf| allocator.free(buf);

                            try sessions[next_free_idx].ensureSpawnedWithDir(cwd_z, &loop);
                            sessions[next_free_idx].status = .running;
                            sessions[next_free_idx].attention = false;

                            sessions[anim_state.focused_session].clearSelection();
                            sessions[next_free_idx].clearSelection();

                            anim_state.previous_session = anim_state.focused_session;
                            anim_state.focused_session = next_free_idx;

                            const buf_size = gridNotificationBufferSize(grid_cols, grid_rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try formatGridNotification(notification_buf, next_free_idx, grid_cols, grid_rows);
                            ui.showToast(notification_msg, now);
                        } else {
                            ui.showToast("All terminals in use", now);
                        }
                    } else if (input.gridNavShortcut(key, mod)) |direction| {
                        if (anim_state.mode == .Grid) {
                            if (config.ui.show_hotkey_feedback) {
                                const arrow = switch (direction) {
                                    .up => "⌘↑",
                                    .down => "⌘↓",
                                    .left => "⌘←",
                                    .right => "⌘→",
                                };
                                ui.showHotkey(arrow, now);
                            }
                            try navigateGrid(&anim_state, sessions, direction, now, true, false, grid_cols, grid_rows, &loop);
                            const new_session = anim_state.focused_session;
                            sessions[new_session].dirty = true;
                            std.debug.print("Grid nav to session {d} (with wrapping)\n", .{new_session});
                        } else if (anim_state.mode == .Full) {
                            if (config.ui.show_hotkey_feedback) {
                                const arrow = switch (direction) {
                                    .up => "⌘↑",
                                    .down => "⌘↓",
                                    .left => "⌘←",
                                    .right => "⌘→",
                                };
                                ui.showHotkey(arrow, now);
                            }
                            try navigateGrid(&anim_state, sessions, direction, now, true, animations_enabled, grid_cols, grid_rows, &loop);

                            const buf_size = gridNotificationBufferSize(grid_cols, grid_rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try formatGridNotification(notification_buf, anim_state.focused_session, grid_cols, grid_rows);
                            ui.showToast(notification_msg, now);

                            std.debug.print("Full mode grid nav to session {d}\n", .{anim_state.focused_session});
                        } else {
                            if (focused.spawned and !focused.dead) {
                                try handleKeyInput(focused, key, mod);
                            }
                        }
                    } else if (key == c.SDLK_RETURN and (mod & c.SDL_KMOD_GUI) != 0 and anim_state.mode == .Grid) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘↵", now);
                        const clicked_session = anim_state.focused_session;
                        try sessions[clicked_session].ensureSpawnedWithLoop(&loop);

                        sessions[clicked_session].status = .running;
                        sessions[clicked_session].attention = false;

                        const grid_row: c_int = @intCast(clicked_session / grid_cols);
                        const grid_col: c_int = @intCast(clicked_session % grid_cols);
                        const start_rect = Rect{
                            .x = grid_col * cell_width_pixels,
                            .y = grid_row * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                        const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                        anim_state.focused_session = clicked_session;
                        if (animations_enabled) {
                            anim_state.mode = .Expanding;
                            anim_state.start_time = now;
                            anim_state.start_rect = start_rect;
                            anim_state.target_rect = target_rect;
                        } else {
                            anim_state.mode = .Full;
                            anim_state.start_time = now;
                            anim_state.start_rect = target_rect;
                            anim_state.target_rect = target_rect;
                            anim_state.previous_session = clicked_session;
                        }
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    } else if (focused.spawned and !focused.dead and !isModifierKey(key)) {
                        try handleKeyInput(focused, key, mod);
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
                        const grid_col_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), grid_cols - 1);
                        const grid_row_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), grid_rows - 1);
                        const clicked_session: usize = grid_row_idx * grid_cols + grid_col_idx;

                        const cell_rect = Rect{
                            .x = @as(c_int, @intCast(grid_col_idx)) * cell_width_pixels,
                            .y = @as(c_int, @intCast(grid_row_idx)) * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };

                        try sessions[clicked_session].ensureSpawnedWithLoop(&loop);

                        sessions[clicked_session].status = .running;
                        sessions[clicked_session].attention = false;

                        const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                        anim_state.focused_session = clicked_session;
                        if (animations_enabled) {
                            anim_state.mode = .Expanding;
                            anim_state.start_time = now;
                            anim_state.start_rect = cell_rect;
                            anim_state.target_rect = target_rect;
                        } else {
                            anim_state.mode = .Full;
                            anim_state.start_time = now;
                            anim_state.start_rect = target_rect;
                            anim_state.target_rect = target_rect;
                            anim_state.previous_session = clicked_session;
                        }
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    } else if (anim_state.mode == .Full and scaled_event.button.button == c.SDL_BUTTON_LEFT) {
                        const focused = &sessions[anim_state.focused_session];
                        if (focused.spawned and focused.terminal != null) {
                            if (fullViewPinFromMouse(focused, mouse_x, mouse_y, render_width, render_height, &font, full_cols, full_rows)) |pin| {
                                const clicks = scaled_event.button.clicks;

                                if (clicks >= 3) {
                                    // Triple-click: select entire line
                                    selectLine(focused, pin, focused.is_scrolled);
                                } else if (clicks == 2) {
                                    // Double-click: select word
                                    selectWord(focused, pin, focused.is_scrolled);
                                } else {
                                    // Single-click: begin drag selection or open link
                                    const mod = c.SDL_GetModState();
                                    const cmd_held = (mod & c.SDL_KMOD_GUI) != 0;

                                    if (cmd_held) {
                                        if (getLinkAtPin(allocator, &focused.terminal.?, pin, focused.is_scrolled)) |uri| {
                                            defer allocator.free(uri);
                                            open_url.openUrl(allocator, uri) catch |err| {
                                                log.err("Failed to open URL: {}", .{err});
                                            };
                                        } else {
                                            beginSelection(focused, pin);
                                        }
                                    } else {
                                        beginSelection(focused, pin);
                                    }
                                }
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

                            const edge_threshold: c_int = 50;
                            const scroll_speed: isize = 1;

                            if (mouse_y < edge_threshold) {
                                scrollSession(focused, -scroll_speed, now);
                            } else if (mouse_y > render_height - edge_threshold) {
                                scrollSession(focused, scroll_speed, now);
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

                        if (!over_ui and pin != null and focused.terminal != null) {
                            const mod = c.SDL_GetModState();
                            const cmd_held = (mod & c.SDL_KMOD_GUI) != 0;

                            if (cmd_held) {
                                if (getLinkMatchAtPin(allocator, &focused.terminal.?, pin.?, focused.is_scrolled)) |link_match| {
                                    desired_cursor = .pointer;
                                    focused.hovered_link_start = link_match.start_pin;
                                    focused.hovered_link_end = link_match.end_pin;
                                    allocator.free(link_match.url);
                                    focused.dirty = true;
                                } else {
                                    desired_cursor = .ibeam;
                                    focused.hovered_link_start = null;
                                    focused.hovered_link_end = null;
                                    focused.dirty = true;
                                }
                            } else {
                                desired_cursor = .ibeam;
                                if (focused.hovered_link_start != null) {
                                    focused.hovered_link_start = null;
                                    focused.hovered_link_end = null;
                                    focused.dirty = true;
                                }
                            }
                        } else {
                            if (focused.hovered_link_start != null) {
                                focused.hovered_link_start = null;
                                focused.hovered_link_end = null;
                                focused.dirty = true;
                            }
                        }
                    }

                    if (desired_cursor != current_cursor) {
                        const target_cursor = switch (desired_cursor) {
                            .arrow => arrow_cursor,
                            .ibeam => ibeam_cursor,
                            .pointer => pointer_cursor,
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
                        grid_cols,
                        grid_rows,
                    );

                    if (hovered_session) |session_idx| {
                        const ticks_per_notch: isize = SCROLL_LINES_PER_TICK;
                        const wheel_ticks: isize = if (scaled_event.wheel.integer_y != 0)
                            @as(isize, @intCast(scaled_event.wheel.integer_y)) * ticks_per_notch
                        else
                            @as(isize, @intFromFloat(scaled_event.wheel.y * @as(f32, @floatFromInt(SCROLL_LINES_PER_TICK))));
                        const scroll_delta = -wheel_ticks;
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

        try loop.run(.no_wait);

        var any_session_dirty = false;
        var has_scroll_inertia = false;
        for (sessions) |*session| {
            session.checkAlive();
            try session.processOutput();
            try session.flushPendingWrites();
            session.updateCwd(now);
            updateScrollInertia(session, delta_time_s);
            any_session_dirty = any_session_dirty or session.dirty;
            has_scroll_inertia = has_scroll_inertia or (session.scroll_velocity != 0.0);
        }

        var notifications = notify_queue.drainAll();
        defer notifications.deinit(allocator);
        const had_notifications = notifications.items.len > 0;
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

        const ui_update_info = try allocator.alloc(ui_mod.SessionUiInfo, grid_count);
        defer allocator.free(ui_update_info);
        const ui_update_host = makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid_cols,
            grid_rows,
            &anim_state,
            sessions,
            ui_update_info,
            &theme,
        );
        ui.update(&ui_update_host);

        while (ui.popAction()) |action| switch (action) {
            .RestartSession => |idx| {
                if (idx < sessions.len) {
                    try sessions[idx].restart();
                    std.debug.print("UI requested restart: {d}\n", .{idx});
                }
            },
            .DespawnSession => |idx| {
                if (idx < sessions.len) {
                    if (anim_state.mode == .Full and anim_state.focused_session == idx) {
                        if (animations_enabled) {
                            startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid_cols);
                        } else {
                            anim_state.mode = .Grid;
                        }
                    }
                    sessions[idx].deinit(allocator);
                    sessions[idx].dirty = true;
                    std.debug.print("UI requested despawn: {d}\n", .{idx});
                }
            },
            .RequestCollapseFocused => {
                if (anim_state.mode == .Full) {
                    if (animations_enabled) {
                        startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid_cols);
                    } else {
                        const grid_row: c_int = @intCast(anim_state.focused_session / grid_cols);
                        const grid_col: c_int = @intCast(anim_state.focused_session % grid_cols);
                        anim_state.mode = .Grid;
                        anim_state.start_time = now;
                        anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };
                        anim_state.target_rect = Rect{
                            .x = grid_col * cell_width_pixels,
                            .y = grid_row * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                    }
                    std.debug.print("UI requested collapse of focused session: {d}\n", .{anim_state.focused_session});
                }
            },
            .ConfirmQuit => {
                running = false;
            },
            .OpenConfig => {
                if (config_mod.Config.getConfigPath(allocator)) |config_path| {
                    defer allocator.free(config_path);
                    if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘,", now);

                    const result = switch (builtin.os.tag) {
                        .macos => blk: {
                            var child = std.process.Child.init(&.{ "open", "-t", config_path }, allocator);
                            break :blk child.spawn();
                        },
                        else => open_url.openUrl(allocator, config_path),
                    };
                    result catch |err| {
                        std.debug.print("Failed to open config file: {}\n", .{err});
                    };
                    ui.showToast("Opening config file", now);
                } else |err| {
                    std.debug.print("Failed to get config path: {}\n", .{err});
                }
            },
        };

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing or
            anim_state.mode == .PanningLeft or anim_state.mode == .PanningRight or
            anim_state.mode == .PanningUp or anim_state.mode == .PanningDown)
        {
            if (anim_state.isComplete(now)) {
                anim_state.mode = switch (anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => .Full,
                    .Collapsing => .Grid,
                    else => anim_state.mode,
                };
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        const desired_font_scale = gridFontScaleForMode(anim_state.mode, config.grid.font_scale);
        if (desired_font_scale != current_grid_font_scale) {
            const term_size = calculateTerminalSize(&font, render_width, render_height, desired_font_scale);
            full_cols = term_size.cols;
            full_rows = term_size.rows;
            applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, render_height);
            current_grid_font_scale = desired_font_scale;
            std.debug.print("Adjusted terminal size for view mode {s}: scale={d:.2} size={d}x{d}\n", .{
                @tagName(anim_state.mode),
                desired_font_scale,
                full_cols,
                full_rows,
            });
        }

        const ui_render_info = try allocator.alloc(ui_mod.SessionUiInfo, grid_count);
        defer allocator.free(ui_render_info);
        const ui_render_host = makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid_cols,
            grid_rows,
            &anim_state,
            sessions,
            ui_render_info,
            &theme,
        );

        const animating = anim_state.mode != .Grid and anim_state.mode != .Full;
        const ui_needs_frame = ui.needsFrame(&ui_render_host);
        const last_render_stale = last_render_ns == 0 or (frame_start_ns - last_render_ns) >= MAX_IDLE_RENDER_GAP_NS;
        const should_render = animating or any_session_dirty or ui_needs_frame or processed_event or had_notifications or last_render_stale;

        if (should_render) {
            try renderer_mod.render(renderer, sessions, cell_width_pixels, cell_height_pixels, grid_cols, grid_rows, &anim_state, now, &font, full_cols, full_rows, render_width, render_height, ui_scale, font_paths.regular, &theme, config.grid.font_scale);
            ui.render(&ui_render_host, renderer);
            _ = c.SDL_RenderPresent(renderer);
            last_render_ns = std.time.nanoTimestamp();
        }

        const is_idle = !animating and !any_session_dirty and !ui_needs_frame and !processed_event and !had_notifications and !has_scroll_inertia;
        // When vsync is enabled and we're active, let vsync handle frame pacing.
        // When idle, always throttle to save power regardless of vsync.
        const needs_throttle = is_idle or !sdl.vsync_enabled;
        if (needs_throttle) {
            const target_frame_ns: i128 = if (is_idle) IDLE_FRAME_NS else ACTIVE_FRAME_NS;
            const frame_end_ns: i128 = std.time.nanoTimestamp();
            const frame_ns = frame_end_ns - frame_start_ns;
            if (frame_ns < target_frame_ns) {
                const sleep_ns: u64 = @intCast(target_frame_ns - frame_ns);
                std.Thread.sleep(sleep_ns);
            }
        }
    }

    if (builtin.os.tag == .macos) {
        persistence.clearTerminals();
        for (sessions, 0..) |session, idx| {
            if (!session.spawned or session.dead) continue;
            if (session.cwd_path) |path| {
                if (path.len == 0) continue;
                persistence.setTerminal(allocator, idx, grid_cols, path) catch |err| {
                    std.debug.print("Failed to persist terminal {d}: {}\n", .{ idx, err });
                };
            }
        }
    }

    persistence.save(allocator) catch |err| {
        std.debug.print("Failed to save persistence: {}\n", .{err});
    };
}

fn allocZ(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, data.len + 1);
    @memcpy(buf[0..data.len], data);
    buf[data.len] = 0;
    return buf;
}

fn startCollapseToGrid(
    anim_state: *AnimationState,
    now: i64,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    render_width: c_int,
    render_height: c_int,
    grid_cols: usize,
) void {
    const grid_row: c_int = @intCast(anim_state.focused_session / grid_cols);
    const grid_col: c_int = @intCast(anim_state.focused_session % grid_cols);
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

fn gridNotificationBufferSize(grid_cols: usize, grid_rows: usize) usize {
    const block_bytes = 3;
    const spaces_between_cols = 3;
    return grid_rows * grid_cols * block_bytes + grid_rows * (grid_cols - 1) * spaces_between_cols + (grid_rows - 1);
}

fn formatGridNotification(buf: []u8, focused_session: usize, grid_cols: usize, grid_rows: usize) ![]const u8 {
    const row = focused_session / grid_cols;
    const col = focused_session % grid_cols;

    var offset: usize = 0;
    for (0..grid_rows) |r| {
        for (0..grid_cols) |col_idx| {
            const block = if (r == row and col_idx == col) "■" else "□";
            if (offset + block.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[offset..][0..block.len], block);
            offset += block.len;

            if (col_idx < grid_cols - 1) {
                const spaces_between_cols = 3;
                if (offset + spaces_between_cols > buf.len) return error.BufferTooSmall;
                buf[offset] = ' ';
                offset += 1;
                buf[offset] = ' ';
                offset += 1;
                buf[offset] = ' ';
                offset += 1;
            }
        }
        if (r < grid_rows - 1) {
            if (offset + 1 > buf.len) return error.BufferTooSmall;
            buf[offset] = '\n';
            offset += 1;
        }
    }
    return buf[0..offset];
}

fn navigateGrid(
    anim_state: *AnimationState,
    sessions: []SessionState,
    direction: input.GridNavDirection,
    now: i64,
    enable_wrapping: bool,
    show_animation: bool,
    grid_cols: usize,
    grid_rows: usize,
    loop: *xev.Loop,
) !void {
    const current_row: usize = anim_state.focused_session / grid_cols;
    const current_col: usize = anim_state.focused_session % grid_cols;
    var new_row: usize = current_row;
    var new_col: usize = current_col;
    var animation_mode: ?ViewMode = null;
    var is_wrapping = false;

    switch (direction) {
        .up => {
            if (current_row > 0) {
                new_row = current_row - 1;
            } else if (enable_wrapping) {
                new_row = grid_rows - 1;
                is_wrapping = true;
            }
            if (show_animation and new_row != current_row) {
                animation_mode = if (is_wrapping) .PanningUp else .PanningDown;
            }
        },
        .down => {
            if (current_row < grid_rows - 1) {
                new_row = current_row + 1;
            } else if (enable_wrapping) {
                new_row = 0;
                is_wrapping = true;
            }
            if (show_animation and new_row != current_row) {
                animation_mode = if (is_wrapping) .PanningDown else .PanningUp;
            }
        },
        .left => {
            if (current_col > 0) {
                new_col = current_col - 1;
            } else if (enable_wrapping) {
                new_col = grid_cols - 1;
                is_wrapping = true;
            }
            if (show_animation and new_col != current_col) {
                animation_mode = if (is_wrapping) .PanningLeft else .PanningRight;
            }
        },
        .right => {
            if (current_col < grid_cols - 1) {
                new_col = current_col + 1;
            } else if (enable_wrapping) {
                new_col = 0;
                is_wrapping = true;
            }
            if (show_animation and new_col != current_col) {
                animation_mode = if (is_wrapping) .PanningRight else .PanningLeft;
            }
        },
    }

    const new_session: usize = new_row * grid_cols + new_col;
    if (new_session != anim_state.focused_session) {
        if (anim_state.mode == .Full) {
            try sessions[new_session].ensureSpawnedWithLoop(loop);
        } else if (show_animation) {
            try sessions[new_session].ensureSpawnedWithLoop(loop);
        }
        sessions[anim_state.focused_session].clearSelection();
        sessions[new_session].clearSelection();

        if (animation_mode) |mode| {
            anim_state.mode = mode;
            anim_state.previous_session = anim_state.focused_session;
            anim_state.focused_session = new_session;
            anim_state.start_time = now;
        } else {
            anim_state.focused_session = new_session;
        }
    }
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
        c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT, c.SDL_EVENT_DROP_POSITION => {
            e.drop.x *= scale_x;
            e.drop.y *= scale_y;
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
    grid_cols: usize,
    grid_rows: usize,
    anim_state: *const AnimationState,
    sessions: []const SessionState,
    buffer: []ui_mod.SessionUiInfo,
    theme: *const colors_mod.Theme,
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
        .grid_cols = grid_cols,
        .grid_rows = grid_rows,
        .cell_w = cell_width_pixels,
        .cell_h = cell_height_pixels,
        .view_mode = anim_state.mode,
        .focused_session = anim_state.focused_session,
        .sessions = buffer[0..sessions.len],
        .theme = theme,
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
    grid_cols: usize,
    grid_rows: usize,
) ?usize {
    return switch (anim_state.mode) {
        .Grid => {
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

fn calculateTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int, grid_font_scale: f32) struct { cols: u16, rows: u16 } {
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

fn scaledFontSize(points: c_int, scale: f32) c_int {
    const scaled = std.math.round(@as(f32, @floatFromInt(points)) * scale);
    return @max(1, @as(c_int, @intFromFloat(scaled)));
}

fn gridFontScaleForMode(mode: app_state.ViewMode, grid_font_scale: f32) f32 {
    return switch (mode) {
        .Grid, .Expanding, .Collapsing => grid_font_scale,
        else => 1.0,
    };
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

            session.dirty = true;
        }
    }
}

fn isModifierKey(key: c.SDL_Keycode) bool {
    return key == c.SDLK_LSHIFT or key == c.SDLK_RSHIFT or
        key == c.SDLK_LCTRL or key == c.SDLK_RCTRL or
        key == c.SDLK_LALT or key == c.SDLK_RALT or
        key == c.SDLK_LGUI or key == c.SDLK_RGUI;
}

fn handleKeyInput(focused: *SessionState, key: c.SDL_Keycode, mod: c.SDL_Keymod) !void {
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
        try focused.sendInput(buf[0..n]);
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

/// Returns true if the codepoint is considered part of a word (alphanumeric or underscore).
/// Only ASCII characters are considered; non-ASCII codepoints return false.
fn isWordCharacter(codepoint: u21) bool {
    if (codepoint > 127) return false;
    const ch: u8 = @intCast(codepoint);
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Select the word at the given pin position. A word is a contiguous sequence of
/// word characters (alphanumeric and underscore).
fn selectWord(session: *SessionState, pin: ghostty_vt.Pin, is_scrolled: bool) void {
    const terminal = &(session.terminal orelse return);
    const page = &pin.node.data;
    const max_col: u16 = @intCast(page.size.cols - 1);

    // Get the point from the pin
    const pin_point = if (is_scrolled)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point = pin_point orelse return;
    const click_x = if (is_scrolled) point.viewport.x else point.active.x;
    const click_y = if (is_scrolled) point.viewport.y else point.active.y;

    // Check if clicked cell is a word character
    const clicked_cell = terminal.screens.active.pages.getCell(
        if (is_scrolled)
            ghostty_vt.point.Point{ .viewport = .{ .x = click_x, .y = click_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = click_x, .y = click_y } },
    ) orelse return;
    const clicked_cp = clicked_cell.cell.content.codepoint;
    if (!isWordCharacter(clicked_cp)) return;

    // Find word start by scanning left
    var start_x = click_x;
    while (start_x > 0) {
        const prev_x = start_x - 1;
        const prev_cell = terminal.screens.active.pages.getCell(
            if (is_scrolled)
                ghostty_vt.point.Point{ .viewport = .{ .x = prev_x, .y = click_y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = prev_x, .y = click_y } },
        ) orelse break;
        if (!isWordCharacter(prev_cell.cell.content.codepoint)) break;
        start_x = prev_x;
    }

    // Find word end by scanning right
    var end_x = click_x;
    while (end_x < max_col) {
        const next_x = end_x + 1;
        const next_cell = terminal.screens.active.pages.getCell(
            if (is_scrolled)
                ghostty_vt.point.Point{ .viewport = .{ .x = next_x, .y = click_y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = next_x, .y = click_y } },
        ) orelse break;
        if (!isWordCharacter(next_cell.cell.content.codepoint)) break;
        end_x = next_x;
    }

    // Create pins for the word boundaries
    const start_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = start_x, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = start_x, .y = click_y } };
    const end_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = end_x, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = end_x, .y = click_y } };

    const start_pin = terminal.screens.active.pages.pin(start_point) orelse return;
    const end_pin = terminal.screens.active.pages.pin(end_point) orelse return;

    // Apply the selection
    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(start_pin, end_pin, false)) catch |err| {
        log.err("failed to select word: {}", .{err});
        return;
    };
    session.dirty = true;
}

/// Select the entire line at the given pin position.
fn selectLine(session: *SessionState, pin: ghostty_vt.Pin, is_scrolled: bool) void {
    const terminal = &(session.terminal orelse return);
    const page = &pin.node.data;
    const max_col: u16 = @intCast(page.size.cols - 1);

    // Get the point from the pin
    const pin_point = if (is_scrolled)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point = pin_point orelse return;
    const click_y = if (is_scrolled) point.viewport.y else point.active.y;

    // Create pins for line start (x=0) and line end (x=max_col)
    const start_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = 0, .y = click_y } };
    const end_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = max_col, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = max_col, .y = click_y } };

    const start_pin = terminal.screens.active.pages.pin(start_point) orelse return;
    const end_pin = terminal.screens.active.pages.pin(end_point) orelse return;

    // Apply the selection
    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(start_pin, end_pin, false)) catch |err| {
        log.err("failed to select line: {}", .{err});
        return;
    };
    session.dirty = true;
}

const LinkMatch = struct {
    url: []u8,
    start_pin: ghostty_vt.Pin,
    end_pin: ghostty_vt.Pin,
};

fn getLinkMatchAtPin(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, pin: ghostty_vt.Pin, is_scrolled: bool) ?LinkMatch {
    const page = &pin.node.data;
    const row_and_cell = pin.rowAndCell();
    const cell = row_and_cell.cell;

    if (page.lookupHyperlink(cell)) |hyperlink_id| {
        const entry = page.hyperlink_set.get(page.memory, hyperlink_id);
        const url = allocator.dupe(u8, entry.uri.slice(page.memory)) catch return null;
        return LinkMatch{
            .url = url,
            .start_pin = pin,
            .end_pin = pin,
        };
    }

    const pin_point = if (is_scrolled)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point_or_null = pin_point orelse return null;
    const start_y_orig = if (is_scrolled) point_or_null.viewport.y else point_or_null.active.y;

    var start_y = start_y_orig;
    var current_row = row_and_cell.row;

    while (current_row.wrap_continuation and start_y > 0) {
        start_y -= 1;
        const prev_point = if (is_scrolled)
            ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = start_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = 0, .y = start_y } };
        const prev_pin = terminal.screens.active.pages.pin(prev_point) orelse break;
        current_row = prev_pin.rowAndCell().row;
    }

    var end_y = start_y_orig;
    current_row = row_and_cell.row;
    const max_y: u16 = @intCast(page.size.rows - 1);

    while (current_row.wrap and end_y < max_y) {
        end_y += 1;
        const next_point = if (is_scrolled)
            ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = end_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = 0, .y = end_y } };
        const next_pin = terminal.screens.active.pages.pin(next_point) orelse break;
        current_row = next_pin.rowAndCell().row;
    }

    const max_x: u16 = @intCast(page.size.cols - 1);
    const row_start_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = start_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = 0, .y = start_y } };
    const row_end_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = max_x, .y = end_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = max_x, .y = end_y } };
    const row_start_pin = terminal.screens.active.pages.pin(row_start_point) orelse return null;
    const row_end_pin = terminal.screens.active.pages.pin(row_end_point) orelse return null;

    const selection = ghostty_vt.Selection.init(row_start_pin, row_end_pin, false);
    const row_text = terminal.screens.active.selectionString(allocator, .{
        .sel = selection,
        .trim = false,
    }) catch return null;
    defer allocator.free(row_text);

    var cell_to_byte: std.ArrayList(usize) = .empty;
    defer cell_to_byte.deinit(allocator);

    var byte_pos: usize = 0;
    var cell_idx: usize = 0;
    var y = start_y;
    while (y <= end_y) : (y += 1) {
        var x: u16 = 0;
        while (x < page.size.cols) : (x += 1) {
            const point = if (is_scrolled)
                ghostty_vt.point.Point{ .viewport = .{ .x = x, .y = y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = x, .y = y } };
            const list_cell = terminal.screens.active.pages.getCell(point) orelse {
                cell_to_byte.append(allocator, byte_pos) catch return null;
                cell_idx += 1;
                continue;
            };

            cell_to_byte.append(allocator, byte_pos) catch return null;

            const list_cell_cell = list_cell.cell;
            const cp = list_cell_cell.content.codepoint;
            const encoded_len: usize = blk: {
                if (cp != 0 and cp != ' ') {
                    var utf8_buf: [4]u8 = undefined;
                    break :blk std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                }
                break :blk 1;
            };

            if (list_cell_cell.wide == .wide) {
                // Wide character (takes 2 cells, but emitted as one sequence in text).
                byte_pos += encoded_len;

                // If possible, handle the second cell of the wide character now
                // so we map it to the same byte position (start of char).
                if (x + 1 < page.size.cols) {
                    x += 1;
                    // Map the second half to the START of the character.
                    // The previous append was for the start of the character.
                    // We need to retrieve that value.
                    const char_start_pos = cell_to_byte.items[cell_to_byte.items.len - 1];
                    cell_to_byte.append(allocator, char_start_pos) catch return null;
                    cell_idx += 1;
                }
            } else {
                // Narrow character
                byte_pos += encoded_len;
            }
            cell_idx += 1;
        }
        if (y < end_y) {
            byte_pos += 1;
        }
    }

    const pin_x = if (is_scrolled) point_or_null.viewport.x else point_or_null.active.x;
    const click_cell_idx = (start_y_orig - start_y) * page.size.cols + pin_x;
    if (click_cell_idx >= cell_to_byte.items.len) return null;
    const click_byte_pos = cell_to_byte.items[click_cell_idx];

    const url_match = url_matcher.findUrlMatchAtPosition(row_text, click_byte_pos) orelse return null;

    var start_cell_idx: usize = 0;
    for (cell_to_byte.items, 0..) |byte, idx| {
        if (byte >= url_match.start) {
            start_cell_idx = idx;
            break;
        }
    }

    var end_cell_idx: usize = cell_to_byte.items.len - 1;
    for (cell_to_byte.items, 0..) |byte, idx| {
        if (byte >= url_match.end) {
            end_cell_idx = if (idx > 0) idx - 1 else 0;
            break;
        }
    }

    const start_row = start_y + @as(u16, @intCast(start_cell_idx / page.size.cols));
    const start_col: u16 = @intCast(start_cell_idx % page.size.cols);
    const end_row = start_y + @as(u16, @intCast(end_cell_idx / page.size.cols));
    const end_col: u16 = @intCast(end_cell_idx % page.size.cols);

    const link_start_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = start_col, .y = start_row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = start_col, .y = start_row } };
    const link_end_point = if (is_scrolled)
        ghostty_vt.point.Point{ .viewport = .{ .x = end_col, .y = end_row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = end_col, .y = end_row } };
    const link_start_pin = terminal.screens.active.pages.pin(link_start_point) orelse return null;
    const link_end_pin = terminal.screens.active.pages.pin(link_end_point) orelse return null;

    const url = allocator.dupe(u8, url_match.url) catch return null;

    return LinkMatch{
        .url = url,
        .start_pin = link_start_pin,
        .end_pin = link_end_pin,
    };
}

fn getLinkAtPin(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, pin: ghostty_vt.Pin, is_scrolled: bool) ?[]u8 {
    if (getLinkMatchAtPin(allocator, terminal, pin, is_scrolled)) |match| {
        return match.url;
    }
    return null;
}

fn resetScrollIfNeeded(session: *SessionState) void {
    if (!session.is_scrolled) return;

    if (session.terminal) |*terminal| {
        terminal.screens.active.pages.scroll(.{ .active = {} });
        session.is_scrolled = false;
        session.scroll_velocity = 0.0;
        session.scroll_remainder = 0.0;
    }
}

fn shellQuotePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '\'');
    for (path) |ch| switch (ch) {
        '\'' => try buf.appendSlice(allocator, "'\"'\"'"),
        else => try buf.append(allocator, ch),
    };
    try buf.append(allocator, '\'');
    try buf.append(allocator, ' ');

    return buf.toOwnedSlice(allocator);
}

fn pasteText(session: *SessionState, allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;

    resetScrollIfNeeded(session);

    const terminal = session.terminal orelse return error.NoTerminal;
    if (session.shell == null) return error.NoShell;

    const opts = ghostty_vt.input.PasteOptions.fromTerminal(&terminal);
    const slices = ghostty_vt.input.encodePaste(text, opts) catch |err| switch (err) {
        error.MutableRequired => blk: {
            const buf = try allocator.dupe(u8, text);
            defer allocator.free(buf);
            break :blk ghostty_vt.input.encodePaste(buf, opts);
        },
        else => return err,
    };

    for (slices) |part| {
        if (part.len == 0) continue;
        try session.sendInput(part);
    }
}

fn handleTextInput(session: *SessionState, text_ptr: [*c]const u8) !void {
    if (!session.spawned or session.dead) return;
    if (text_ptr == null) return;

    const text = std.mem.sliceTo(text_ptr, 0);
    if (text.len == 0) return;

    resetScrollIfNeeded(session);
    try session.sendInput(text);
}

fn clearTerminal(session: *SessionState) void {
    const terminal_ptr = session.terminal orelse return;
    var terminal = terminal_ptr;

    // Match Ghostty behavior: avoid clearing alt screen to not disrupt full-screen apps.
    if (terminal.screens.active_key == .alternate) return;

    terminal.screens.active.clearSelection();
    terminal.eraseDisplay(ghostty_vt.EraseDisplay.scrollback, false);
    terminal.eraseDisplay(ghostty_vt.EraseDisplay.complete, false);
    session.dirty = true;

    // Trigger shell redraw like Ghostty (FF) so the prompt is repainted at top.
    session.sendInput(&[_]u8{0x0C}) catch {};
}

fn copySelectionToClipboard(
    session: *SessionState,
    allocator: std.mem.Allocator,
    ui: *ui_mod.UiRoot,
    now: i64,
) !void {
    const terminal = session.terminal orelse {
        ui.showToast("No terminal to copy from", now);
        return;
    };
    const screen = terminal.screens.active;
    const sel = screen.selection orelse {
        ui.showToast("No selection", now);
        return;
    };

    const text = try screen.selectionString(allocator, .{ .sel = sel, .trim = true });
    defer allocator.free(text);

    const clipboard_text = try allocator.allocSentinel(u8, text.len, 0);
    defer allocator.free(clipboard_text);
    @memcpy(clipboard_text[0..text.len], text);

    if (!c.SDL_SetClipboardText(clipboard_text.ptr)) {
        ui.showToast("Failed to copy selection", now);
        return;
    }

    ui.showToast("Copied selection", now);
}

fn pasteClipboardIntoSession(
    session: *SessionState,
    allocator: std.mem.Allocator,
    ui: *ui_mod.UiRoot,
    now: i64,
) !void {
    const clip_ptr = c.SDL_GetClipboardText();
    defer c.SDL_free(clip_ptr);
    if (clip_ptr == null) {
        ui.showToast("Clipboard empty", now);
        return;
    }
    const clip = std.mem.sliceTo(clip_ptr, 0);
    if (clip.len == 0) {
        ui.showToast("Clipboard empty", now);
        return;
    }

    pasteText(session, allocator, clip) catch |err| switch (err) {
        error.NoTerminal => {
            ui.showToast("No terminal to paste into", now);
            return;
        },
        error.NoShell => {
            ui.showToast("Shell not available", now);
            return;
        },
        else => return err,
    };

    ui.showToast("Pasted clipboard", now);
}
