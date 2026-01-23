// Main application entry: wires SDL3 rendering, ghostty-vt terminals, PTY-backed
// shells, and the grid/animation system that drives the 3×3 terminal wall UI.
const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const app_state = @import("app_state.zig");
const grid_layout = @import("grid_layout.zig");
const grid_nav = @import("grid_nav.zig");
const input_keys = @import("input_keys.zig");
const input_text = @import("input_text.zig");
const layout = @import("layout.zig");
const terminal_actions = @import("terminal_actions.zig");
const ui_host = @import("ui_host.zig");
const worktree = @import("worktree.zig");
const notify = @import("../session/notify.zig");
const session_state = @import("../session/state.zig");
const view_state = @import("../ui/session_view_state.zig");
const platform = @import("../platform/sdl.zig");
const macos_input = @import("../platform/macos_input_source.zig");
const input = @import("../input/mapper.zig");
const renderer_mod = @import("../render/renderer.zig");
const pty_mod = @import("../pty.zig");
const font_mod = @import("../font.zig");
const font_paths_mod = @import("../font_paths.zig");
const config_mod = @import("../config.zig");
const colors_mod = @import("../colors.zig");
const ui_mod = @import("../ui/mod.zig");
const font_cache_mod = @import("../font_cache.zig");
const c = @import("../c.zig");
const metrics_mod = @import("../metrics.zig");
const open_url = @import("../os/open.zig");

const log = std.log.scoped(.runtime);

const INITIAL_WINDOW_WIDTH = 1200;
const INITIAL_WINDOW_HEIGHT = 900;
const DEFAULT_FONT_SIZE: c_int = 14;
const MIN_FONT_SIZE: c_int = 8;
const MAX_FONT_SIZE: c_int = 96;
const FONT_STEP: c_int = 1;
const UI_FONT_SIZE: c_int = 18;
const ACTIVE_FRAME_NS: i128 = 16_666_667;
const IDLE_FRAME_NS: i128 = 50_000_000;
const MAX_IDLE_RENDER_GAP_NS: i128 = 250_000_000;
const FOREGROUND_PROCESS_CACHE_MS: i64 = 150;
const Rect = app_state.Rect;
const AnimationState = app_state.AnimationState;
const NotificationQueue = notify.NotificationQueue;
const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;
const GridLayout = grid_layout.GridLayout;
const SessionMove = grid_layout.SessionMove;

const ForegroundProcessCache = struct {
    session_idx: ?usize = null,
    last_check_ms: i64 = 0,
    value: bool = false,

    fn get(self: *ForegroundProcessCache, now_ms: i64, focused_session: usize, sessions: []const *SessionState) bool {
        if (self.session_idx != focused_session) {
            self.session_idx = focused_session;
            self.last_check_ms = 0;
        }
        if (self.last_check_ms == 0 or now_ms < self.last_check_ms or
            now_ms - self.last_check_ms >= FOREGROUND_PROCESS_CACHE_MS)
        {
            self.value = sessions[focused_session].hasForegroundProcess();
            self.last_check_ms = now_ms;
        }
        return self.value;
    }
};

fn countForegroundProcesses(sessions: []const *SessionState) usize {
    var total: usize = 0;
    for (sessions) |session| {
        if (session.hasForegroundProcess()) {
            total += 1;
        }
    }
    return total;
}

fn countSpawnedSessions(sessions: []const *SessionState) usize {
    var count: usize = 0;
    for (sessions) |session| {
        if (session.spawned) count += 1;
    }
    return count;
}

fn highestSpawnedIndex(sessions: []const *SessionState) ?usize {
    var idx: usize = sessions.len;
    while (idx > 0) {
        idx -= 1;
        if (sessions[idx].spawned) return idx;
    }
    return null;
}

fn adjustedRenderHeightForMode(mode: app_state.ViewMode, render_height: c_int, ui_scale: f32, grid_rows: usize) c_int {
    return switch (mode) {
        .Grid, .Expanding, .Collapsing, .GridResizing => blk: {
            const cell_height = @divFloor(render_height, @as(c_int, @intCast(grid_rows)));
            const can_render_bar = cell_height >= ui_mod.cwd_bar.minCellHeight(ui_scale);
            const per_cell_reserve: c_int = if (can_render_bar) ui_mod.cwd_bar.reservedHeight(ui_scale) else 0;
            const total_reserve: c_int = per_cell_reserve * @as(c_int, @intCast(grid_rows));
            const adjusted: c_int = render_height - total_reserve;
            break :blk if (adjusted > 0) adjusted else 0;
        },
        else => render_height,
    };
}

fn applyTerminalLayout(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    font: *font_mod.Font,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    mode: app_state.ViewMode,
    grid_cols: usize,
    grid_rows: usize,
    grid_font_scale: f32,
    full_cols: *u16,
    full_rows: *u16,
) void {
    const term_render_height = adjustedRenderHeightForMode(mode, render_height, ui_scale, grid_rows);
    const term_size = layout.calculateTerminalSizeForMode(font, render_width, term_render_height, mode, grid_font_scale, grid_cols, grid_rows);
    full_cols.* = term_size.cols;
    full_rows.* = term_size.rows;
    layout.applyTerminalResize(sessions, allocator, full_cols.*, full_rows.*, render_width, term_render_height);
}

const SessionIndexSnapshot = struct {
    session_id: usize,
    index: usize,
};

/// Collect indices for spawned sessions to preserve their pre-compaction positions.
fn collectSessionIndexSnapshots(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !std.ArrayList(SessionIndexSnapshot) {
    var snapshots = std.ArrayList(SessionIndexSnapshot).empty;
    for (sessions, 0..) |session, idx| {
        if (session.spawned) {
            try snapshots.append(allocator, .{ .session_id = session.id, .index = idx });
        }
    }
    return snapshots;
}

fn findSnapshotIndex(snapshots: []const SessionIndexSnapshot, session_id: usize) ?usize {
    for (snapshots) |snapshot| {
        if (snapshot.session_id == session_id) return snapshot.index;
    }
    return null;
}

const SessionMoves = struct {
    list: std.ArrayList(SessionMove),
    moved: bool,
};

/// Collect session moves using the current indices as both old and new positions.
fn collectSessionMovesCurrent(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !std.ArrayList(SessionMove) {
    var moves = std.ArrayList(SessionMove).empty;
    for (sessions, 0..) |session, idx| {
        if (session.spawned) {
            try moves.append(allocator, .{ .session_idx = idx, .old_index = idx });
        }
    }
    return moves;
}

/// Collect session moves using snapshot indices as old positions, returning whether any moved.
fn collectSessionMovesFromSnapshots(
    sessions: []const *SessionState,
    snapshots: []const SessionIndexSnapshot,
    allocator: std.mem.Allocator,
) !SessionMoves {
    var moves = std.ArrayList(SessionMove).empty;
    var moved = false;
    for (sessions, 0..) |session, idx| {
        if (!session.spawned) continue;
        const old_index = findSnapshotIndex(snapshots, session.id);
        if (old_index) |old_idx| {
            if (old_idx != idx) moved = true;
        } else {
            moved = true;
        }
        try moves.append(allocator, .{ .session_idx = idx, .old_index = old_index });
    }
    return .{ .list = moves, .moved = moved };
}

fn findNextFreeSlotAfter(
    sessions: []const *SessionState,
    grid_capacity: usize,
    start_idx: usize,
) ?usize {
    if (grid_capacity == 0) return null;

    var offset: usize = 1;
    while (offset <= grid_capacity) : (offset += 1) {
        const idx = (start_idx + offset) % grid_capacity;
        if (idx >= sessions.len) continue;
        if (!sessions[idx].spawned) {
            return idx;
        }
    }
    return null;
}

fn findSessionIndexById(sessions: []const *SessionState, session_id: usize) ?usize {
    for (sessions, 0..) |session, idx| {
        if (session.spawned and session.id == session_id) return idx;
    }
    return null;
}

fn compactSessions(
    sessions: []*SessionState,
    views: []SessionViewState,
    render_cache: *renderer_mod.RenderCache,
    anim_state: *AnimationState,
) void {
    const focused_id: ?usize = if (anim_state.focused_session < sessions.len and sessions[anim_state.focused_session].spawned)
        sessions[anim_state.focused_session].id
    else
        null;
    const previous_id: ?usize = if (anim_state.previous_session < sessions.len and sessions[anim_state.previous_session].spawned)
        sessions[anim_state.previous_session].id
    else
        null;

    var write_idx: usize = 0;
    var idx: usize = 0;
    while (idx < sessions.len) : (idx += 1) {
        if (!sessions[idx].spawned) continue;
        if (write_idx != idx) {
            std.mem.swap(*SessionState, &sessions[write_idx], &sessions[idx]);
            std.mem.swap(SessionViewState, &views[write_idx], &views[idx]);
            std.mem.swap(renderer_mod.RenderCache.Entry, &render_cache.entries[write_idx], &render_cache.entries[idx]);
        }
        write_idx += 1;
    }

    for (sessions, 0..) |session, slot_idx| {
        session.slot_index = slot_idx;
    }

    if (focused_id) |id| {
        if (findSessionIndexById(sessions, id)) |new_idx| {
            anim_state.focused_session = new_idx;
        }
    }
    if (previous_id) |id| {
        if (findSessionIndexById(sessions, id)) |new_idx| {
            anim_state.previous_session = new_idx;
        }
    }
}

const WorkingDir = struct {
    cwd_z: ?[:0]const u8,
    buf: ?[]u8,

    fn init(allocator: std.mem.Allocator, cwd_path: ?[]const u8) WorkingDir {
        var buf: ?[]u8 = null;
        const cwd_z: ?[:0]const u8 = if (cwd_path) |path| blk: {
            const owned = allocator.alloc(u8, path.len + 1) catch break :blk null;
            @memcpy(owned[0..path.len], path);
            owned[path.len] = 0;
            buf = owned;
            break :blk owned[0..path.len :0];
        } else null;

        return .{
            .cwd_z = cwd_z,
            .buf = buf,
        };
    }

    fn deinit(self: *WorkingDir, allocator: std.mem.Allocator) void {
        if (self.buf) |buf| allocator.free(buf);
    }
};

fn initSharedFont(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    cache: *font_cache_mod.FontCache,
    size: c_int,
) font_mod.Font.InitError!font_mod.Font {
    const faces = cache.get(size) catch |err| switch (err) {
        error.FontUnavailable => return error.FontLoadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return font_mod.Font.initFromFaces(allocator, renderer, .{
        .regular = faces.regular,
        .bold = faces.bold,
        .italic = faces.italic,
        .bold_italic = faces.bold_italic,
        .symbol = faces.symbol,
        .emoji = faces.emoji,
    });
}

fn handleQuitRequest(
    sessions: []const *SessionState,
    confirm: *ui_mod.quit_confirm.QuitConfirmComponent,
) bool {
    const running_processes = countForegroundProcesses(sessions);
    if (running_processes > 0) {
        confirm.show(running_processes);
        return false;
    }
    return true;
}

pub fn run() !void {
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
    defer persistence.deinit(allocator);
    persistence.font_size = std.math.clamp(persistence.font_size, MIN_FONT_SIZE, MAX_FONT_SIZE);

    const theme = colors_mod.Theme.fromConfig(config.theme);

    // Dynamic grid layout - starts with 1x1 and grows as terminals are added
    var grid = try GridLayout.init(allocator);
    defer grid.deinit();

    // Load persisted terminals to determine initial grid size
    const restored_paths = if (builtin.os.tag == .macos) persistence.terminal_paths.items else &[_][]const u8{};
    const restored_limit = @min(restored_paths.len, grid_layout.MAX_TERMINALS);
    const restored_slice = restored_paths[0..restored_limit];

    // Calculate initial grid size based on restored terminals
    const initial_terminal_count: usize = if (restored_slice.len > 0) restored_slice.len else 1;
    const initial_dims = GridLayout.calculateDimensions(initial_terminal_count);
    grid.cols = initial_dims.cols;
    grid.rows = initial_dims.rows;

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
    var text_input_active = true;
    var input_source_tracker = macos_input.InputSourceTracker.init();
    defer input_source_tracker.deinit();
    if (builtin.os.tag == .macos) {
        input_source_tracker.capture() catch |err| {
            log.warn("Failed to capture input source: {}", .{err});
        };
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

    var shared_font_cache = font_cache_mod.FontCache.init(allocator);
    defer shared_font_cache.deinit();
    shared_font_cache.setPaths(
        font_paths.regular,
        font_paths.bold,
        font_paths.italic,
        font_paths.bold_italic,
        font_paths.symbol_fallback,
        font_paths.emoji_fallback,
    );

    var metrics_storage: metrics_mod.Metrics = metrics_mod.Metrics.init();
    const metrics_ptr: ?*metrics_mod.Metrics = if (config.metrics.enabled) &metrics_storage else null;
    metrics_mod.global = metrics_ptr;

    var font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(font_size, ui_scale));
    defer font.deinit();
    font.metrics = metrics_ptr;

    var ui_font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(UI_FONT_SIZE, ui_scale));
    defer ui_font.deinit();

    var ui = ui_mod.UiRoot.init(allocator);
    defer ui.deinit(renderer);
    ui.assets.ui_font = &ui_font;
    ui.assets.font_cache = &shared_font_cache;

    var window_x: c_int = persistence.window.x;
    var window_y: c_int = persistence.window.y;

    const initial_term_render_height = adjustedRenderHeightForMode(.Grid, render_height, ui_scale, grid.rows);
    const initial_term_size = layout.calculateTerminalSizeForMode(&font, render_width, initial_term_render_height, .Grid, config.grid.font_scale, grid.cols, grid.rows);
    var full_cols: u16 = initial_term_size.cols;
    var full_rows: u16 = initial_term_size.rows;

    std.debug.print("Grid cell terminal size: {d}x{d}\n", .{ full_cols, full_rows });

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Starting with {d}x{d} grid: {s}\n", .{ grid.cols, grid.rows, shell_path });

    var cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
    var cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));

    const usable_width = @max(0, render_width - renderer_mod.TERMINAL_PADDING * 2);
    const usable_height = @max(0, initial_term_render_height - renderer_mod.TERMINAL_PADDING * 2);

    const size = pty_mod.winsize{
        .ws_row = full_rows,
        .ws_col = full_cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    // Allocate max possible sessions to avoid reallocation
    const sessions_storage = try allocator.alloc(SessionState, grid_layout.MAX_TERMINALS);
    const sessions = try allocator.alloc(*SessionState, grid_layout.MAX_TERMINALS);
    var init_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < init_count) : (i += 1) {
            sessions_storage[i].deinit(allocator);
        }
        allocator.free(sessions_storage);
        allocator.free(sessions);
    }

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Initialize all session slots
    for (0..grid_layout.MAX_TERMINALS) |i| {
        sessions_storage[i] = try SessionState.init(allocator, i, shell_path, size, notify_sock);
        sessions[i] = &sessions_storage[i];
        init_count += 1;
    }

    // Restore persisted terminals
    for (restored_slice, 0..) |path, new_idx| {
        if (new_idx >= sessions.len or path.len == 0) continue;
        const dir_buf = allocZ(allocator, path) catch |err| blk: {
            std.debug.print("Failed to restore terminal {d}: {}\n", .{ new_idx, err });
            break :blk null;
        };
        defer if (dir_buf) |buf| allocator.free(buf);
        if (dir_buf) |buf| {
            const dir: [:0]const u8 = buf[0..path.len :0];
            sessions[new_idx].ensureSpawnedWithDir(dir, &loop) catch |err| {
                std.debug.print("Failed to spawn restored terminal {d}: {}\n", .{ new_idx, err });
            };
        }
    }

    // Always spawn at least the first terminal
    try sessions[0].ensureSpawnedWithLoop(&loop);

    init_count = sessions.len;

    const session_ui_info = try allocator.alloc(ui_mod.SessionUiInfo, grid_layout.MAX_TERMINALS);
    defer allocator.free(session_ui_info);

    var render_cache = try renderer_mod.RenderCache.init(allocator, grid_layout.MAX_TERMINALS);
    defer render_cache.deinit();

    var foreground_cache = ForegroundProcessCache{};

    var running = true;

    const initial_mode: app_state.ViewMode = if (countSpawnedSessions(sessions) == 1) .Full else .Grid;
    var anim_state = AnimationState{
        .mode = initial_mode,
        .focused_session = 0,
        .previous_session = 0,
        .start_time = 0,
        .start_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .target_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
    var ime_composition = input_text.ImeComposition{};
    var last_focused_session: usize = anim_state.focused_session;
    var relaunch_trace_frames: u8 = 0;
    var window_close_suppress_countdown: u8 = 0;

    const session_interaction_component = try ui_mod.SessionInteractionComponent.init(allocator, sessions, &font);
    try ui.register(session_interaction_component.asComponent());

    const worktree_comp_ptr = try allocator.create(ui_mod.worktree_overlay.WorktreeOverlayComponent);
    worktree_comp_ptr.* = .{ .allocator = allocator };
    const worktree_component = ui_mod.UiComponent{
        .ptr = worktree_comp_ptr,
        .vtable = &ui_mod.worktree_overlay.WorktreeOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(worktree_component);

    const help_comp_ptr = try allocator.create(ui_mod.help_overlay.HelpOverlayComponent);
    help_comp_ptr.* = .{ .allocator = allocator };
    const help_component = ui_mod.UiComponent{
        .ptr = help_comp_ptr,
        .vtable = &ui_mod.help_overlay.HelpOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(help_component);

    const pill_group_component = try ui_mod.pill_group.PillGroupComponent.create(allocator, help_comp_ptr, worktree_comp_ptr);
    try ui.register(pill_group_component);
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
    const cwd_bar_component = try ui_mod.cwd_bar.CwdBarComponent.init(allocator);
    try ui.register(cwd_bar_component.asComponent());
    const metrics_overlay_component = try ui_mod.metrics_overlay.MetricsOverlayComponent.init(allocator);
    try ui.register(metrics_overlay_component.asComponent());

    // Main loop: handle SDL input, feed PTY output into terminals, apply async
    // notifications, drive animations, and render at ~60 FPS.
    var last_render_ns: i128 = 0;
    while (running) {
        const frame_start_ns: i128 = std.time.nanoTimestamp();
        const now = std.time.milliTimestamp();
        if (relaunch_trace_frames > 0) {
            log.info("frame trace start mode={s} grid_resizing={} grid={d}x{d}", .{
                @tagName(anim_state.mode),
                grid.is_resizing,
                grid.cols,
                grid.rows,
            });
        }

        var event: c.SDL_Event = undefined;
        var processed_event = false;
        while (c.SDL_PollEvent(&event)) {
            if (anim_state.focused_session != last_focused_session) {
                const previous_session = last_focused_session;
                input_text.clearImeComposition(sessions[previous_session], &ime_composition) catch |err| {
                    std.debug.print("Failed to clear IME composition: {}\n", .{err});
                };
                ime_composition.reset();
                last_focused_session = anim_state.focused_session;
            }
            processed_event = true;
            var scaled_event = layout.scaleEventToRender(&event, scale_x, scale_y);
            if (builtin.os.tag == .macos and scaled_event.type == c.SDL_EVENT_KEY_DOWN) {
                const key = scaled_event.key.key;
                const mod = scaled_event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                if (has_gui and !has_blocking_mod and key == c.SDLK_W) {
                    // Use 2 frames to cover the delay between Cmd+W and SDL delivering a close request.
                    // A single frame is not always enough to suppress the close in the next loop.
                    window_close_suppress_countdown = 2;
                }
            }
            const focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
            const host_snapshot = ui_host.makeUiHost(
                now,
                render_width,
                render_height,
                ui_scale,
                cell_width_pixels,
                cell_height_pixels,
                grid.cols,
                grid.rows,
                full_cols,
                full_rows,
                &anim_state,
                sessions,
                session_ui_info,
                focused_has_foreground_process,
                &theme,
            );
            var event_ui_host = host_snapshot;
            ui_host.applyMouseContext(&ui, &event_ui_host, &scaled_event);

            const ui_consumed = ui.handleEvent(&event_ui_host, &scaled_event);
            if (ui_consumed) continue;

            switch (scaled_event.type) {
                c.SDL_EVENT_QUIT => {
                    if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                        running = false;
                    }
                },
                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (builtin.os.tag == .macos and window_close_suppress_countdown > 0) {
                        // Reset immediately so we only suppress this close request.
                        window_close_suppress_countdown = 0;
                        continue;
                    }
                    if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                        running = false;
                    }
                },
                c.SDL_EVENT_WINDOW_DESTROYED => {
                    running = false;
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
                    layout.updateRenderSizes(sdl.window, &window_width_points, &window_height_points, &render_width, &render_height, &scale_x, &scale_y);
                    const prev_scale = ui_scale;
                    ui_scale = @max(scale_x, scale_y);
                    if (ui_scale != prev_scale) {
                        font.deinit();
                        ui_font.deinit();
                        font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(font_size, ui_scale));
                        font.metrics = metrics_ptr;
                        ui_font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(UI_FONT_SIZE, ui_scale));
                        ui.assets.ui_font = &ui_font;
                        const term_render_height = adjustedRenderHeightForMode(anim_state.mode, render_height, ui_scale, grid.rows);
                        const new_term_size = layout.calculateTerminalSizeForMode(&font, render_width, term_render_height, anim_state.mode, config.grid.font_scale, grid.cols, grid.rows);
                        full_cols = new_term_size.cols;
                        full_rows = new_term_size.rows;
                        layout.applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, term_render_height);
                    } else {
                        const term_render_height = adjustedRenderHeightForMode(anim_state.mode, render_height, ui_scale, grid.rows);
                        const new_term_size = layout.calculateTerminalSizeForMode(&font, render_width, term_render_height, anim_state.mode, config.grid.font_scale, grid.cols, grid.rows);
                        full_cols = new_term_size.cols;
                        full_rows = new_term_size.rows;
                        layout.applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, term_render_height);
                    }
                    cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                    cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));

                    std.debug.print("Window resized to: {d}x{d} (render {d}x{d}), terminal size: {d}x{d}\n", .{ window_width_points, window_height_points, render_width, render_height, full_cols, full_rows });

                    persistence.window.width = window_width_points;
                    persistence.window.height = window_height_points;
                    persistence.window.x = window_x;
                    persistence.window.y = window_y;
                    persistence.save(allocator) catch |err| {
                        std.debug.print("Failed to save persistence: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    if (builtin.os.tag == .macos) {
                        if (text_input_active) {
                            platform.stopTextInput(sdl.window);
                            text_input_active = false;
                        }
                    }
                    ime_composition.reset();
                },
                c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                    if (builtin.os.tag == .macos) {
                        input_source_tracker.restore() catch |err| {
                            log.warn("Failed to restore input source: {}", .{err});
                        };
                        // Reset text input so macOS restores the per-document input source.
                        if (text_input_active) {
                            platform.stopTextInput(sdl.window);
                        }
                        platform.startTextInput(sdl.window);
                        text_input_active = true;
                    }
                },
                c.SDL_EVENT_KEYMAP_CHANGED => {
                    if (builtin.os.tag == .macos) {
                        input_source_tracker.capture() catch |err| {
                            log.warn("Failed to capture input source: {}", .{err});
                        };
                    }
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const focused = sessions[anim_state.focused_session];
                    input_text.handleTextInput(focused, &ime_composition, scaled_event.text.text, session_interaction_component) catch |err| {
                        std.debug.print("Text input failed: {}\n", .{err});
                    };
                    if (anim_state.mode == .Grid) {
                        session_interaction_component.setAttention(anim_state.focused_session, false);
                    }
                },
                c.SDL_EVENT_TEXT_EDITING => {
                    const focused = sessions[anim_state.focused_session];
                    input_text.handleTextEditing(
                        focused,
                        &ime_composition,
                        scaled_event.edit.text,
                        scaled_event.edit.start,
                        scaled_event.edit.length,
                        session_interaction_component,
                    ) catch |err| {
                        std.debug.print("Edit input failed: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_DROP_FILE => {
                    const drop_path_ptr = scaled_event.drop.data;
                    if (drop_path_ptr == null) continue;
                    const drop_path = std.mem.span(drop_path_ptr.?);
                    if (drop_path.len == 0) continue;

                    const mouse_x: c_int = @intFromFloat(scaled_event.drop.x);
                    const mouse_y: c_int = @intFromFloat(scaled_event.drop.y);

                    const hovered_session = layout.calculateHoveredSession(
                        mouse_x,
                        mouse_y,
                        &anim_state,
                        cell_width_pixels,
                        cell_height_pixels,
                        render_width,
                        render_height,
                        grid.cols,
                        grid.rows,
                    ) orelse continue;

                    var session = sessions[hovered_session];
                    try session.ensureSpawnedWithLoop(&loop);

                    const escaped = worktree.shellQuotePath(allocator, drop_path) catch |err| {
                        std.debug.print("Failed to escape dropped path: {}\n", .{err});
                        continue;
                    };
                    defer allocator.free(escaped);

                    terminal_actions.pasteText(session, allocator, escaped, session_interaction_component) catch |err| switch (err) {
                        error.NoTerminal => ui.showToast("No terminal to paste into", now),
                        error.NoShell => ui.showToast("Shell not available", now),
                        else => std.debug.print("Failed to paste dropped path: {}\n", .{err}),
                    };
                },
                c.SDL_EVENT_KEY_DOWN => {
                    const key = scaled_event.key.key;
                    const mod = scaled_event.key.mod;
                    const focused = sessions[anim_state.focused_session];

                    const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                    const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                    const terminal_shortcut: ?usize = if (worktree_comp_ptr.overlay.state == .Closed)
                        input.terminalSwitchShortcut(key, mod, grid.cols * grid.rows)
                    else
                        null;

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
                        const session = sessions[session_idx];

                        if (!session.spawned) {
                            log.info("close requested on unspawned session idx={d} mode={s}", .{ session_idx, @tagName(anim_state.mode) });
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
                            const spawned_count = countSpawnedSessions(sessions);
                            log.info("close requested idx={d} spawned_count={d} mode={s}", .{
                                session_idx,
                                spawned_count,
                                @tagName(anim_state.mode),
                            });
                            if (spawned_count == 1) {
                                var working_dir = WorkingDir.init(allocator, session.cwd_path);
                                defer working_dir.deinit(allocator);

                                log.info("relaunching last session idx={d} grid_resizing={}", .{
                                    session_idx,
                                    grid.is_resizing,
                                });
                                relaunch_trace_frames = 120;
                                try session.relaunch(working_dir.cwd_z, &loop);
                                session_interaction_component.resetView(session_idx);
                                session_interaction_component.setStatus(session_idx, .running);
                                session_interaction_component.setAttention(session_idx, false);
                                session.markDirty();
                                grid.cancelResize();
                                log.info("relaunch complete idx={d} spawned={} dead={}", .{
                                    session_idx,
                                    session.spawned,
                                    session.dead,
                                });
                                anim_state.mode = .Full;
                                continue;
                            }

                            // If in full view, collapse to grid first
                            if (anim_state.mode == .Full) {
                                if (animations_enabled) {
                                    grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                                } else {
                                    anim_state.mode = .Grid;
                                }
                            }

                            var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
                            defer if (old_positions) |*snapshots| {
                                snapshots.deinit(allocator);
                            };
                            if (animations_enabled and anim_state.mode == .Grid) {
                                old_positions = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
                                    std.debug.print("Failed to snapshot session positions: {}\n", .{err});
                                    break :blk null;
                                };
                            }

                            // Close the terminal
                            session.deinit(allocator);
                            session_interaction_component.resetView(session_idx);
                            session.markDirty();

                            compactSessions(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state);

                            // Count remaining spawned sessions after closing
                            const remaining_count = countSpawnedSessions(sessions);
                            const max_spawned_idx = highestSpawnedIndex(sessions);
                            const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

                            // Don't shrink below 1 terminal
                            if (remaining_count == 0) {
                                // Re-spawn a fresh terminal in slot 0
                                try sessions[0].ensureSpawnedWithLoop(&loop);
                                anim_state.focused_session = 0;
                                grid.cols = 1;
                                grid.rows = 1;
                                cell_width_pixels = render_width;
                                cell_height_pixels = render_height;
                                anim_state.mode = .Full;
                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, anim_state.mode, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                            } else if (remaining_count == 1) {
                                // Only 1 terminal remains - go directly to Full mode, no resize animation
                                grid.cols = 1;
                                grid.rows = 1;
                                cell_width_pixels = render_width;
                                cell_height_pixels = render_height;
                                if (!sessions[anim_state.focused_session].spawned) {
                                    for (sessions, 0..) |s, idx| {
                                        if (s.spawned) {
                                            anim_state.focused_session = idx;
                                            break;
                                        }
                                    }
                                }
                                anim_state.mode = .Full;
                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, anim_state.mode, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                            } else {
                                const new_dims = GridLayout.calculateDimensions(required_slots);
                                const should_shrink = new_dims.cols < grid.cols or new_dims.rows < grid.rows;

                                if (should_shrink) {
                                    const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                                    const grid_will_resize = new_dims.cols != grid.cols or new_dims.rows != grid.rows;
                                    if (can_animate_reflow) {
                                        if (old_positions) |snapshots| {
                                            var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                                break :blk null;
                                            };
                                            if (move_result) |*moves| {
                                                defer moves.list.deinit(allocator);
                                                if (grid_will_resize or moves.moved) {
                                                    grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                        std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                                    };
                                                    anim_state.mode = .GridResizing;
                                                } else {
                                                    grid.cols = new_dims.cols;
                                                    grid.rows = new_dims.rows;
                                                }
                                            } else {
                                                grid.cols = new_dims.cols;
                                                grid.rows = new_dims.rows;
                                            }
                                        } else {
                                            grid.cols = new_dims.cols;
                                            grid.rows = new_dims.rows;
                                        }
                                    } else {
                                        grid.cols = new_dims.cols;
                                        grid.rows = new_dims.rows;
                                    }

                                    cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                                    cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                                    applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, anim_state.mode, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);

                                    // Update focus to a valid session
                                    if (!sessions[anim_state.focused_session].spawned) {
                                        var new_focus: usize = 0;
                                        for (sessions, 0..) |s, idx| {
                                            if (s.spawned) {
                                                new_focus = idx;
                                                break;
                                            }
                                        }
                                        anim_state.focused_session = new_focus;
                                    }

                                    std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ grid.cols, grid.rows, remaining_count });
                                } else {
                                    const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                                    if (can_animate_reflow) {
                                        if (old_positions) |snapshots| {
                                            var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                                break :blk null;
                                            };
                                            if (move_result) |*moves| {
                                                defer moves.list.deinit(allocator);
                                                if (moves.moved) {
                                                    grid.startResize(grid.cols, grid.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                        std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                                                    };
                                                    anim_state.mode = .GridResizing;
                                                }
                                            }
                                        }
                                    }
                                    // Grid doesn't need to shrink, just update focus if needed
                                    if (!sessions[anim_state.focused_session].spawned) {
                                        // Find the next spawned session
                                        var new_focus: usize = 0;
                                        for (sessions, 0..) |s, idx| {
                                            if (s.spawned) {
                                                new_focus = idx;
                                                break;
                                            }
                                        }
                                        anim_state.focused_session = new_focus;
                                    }
                                }
                            }
                        }
                        continue;
                    }

                    if (key == c.SDLK_K and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘K", now);
                        terminal_actions.clearTerminal(focused);
                        ui.showToast("Cleared terminal", now);
                    } else if (key == c.SDLK_C and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘C", now);
                        terminal_actions.copySelectionToClipboard(focused, allocator, &ui, now) catch |err| {
                            std.debug.print("Copy failed: {}\n", .{err});
                        };
                    } else if (key == c.SDLK_V and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘V", now);
                        terminal_actions.pasteClipboardIntoSession(focused, allocator, &ui, now, session_interaction_component) catch |err| {
                            std.debug.print("Paste failed: {}\n", .{err});
                        };
                    } else if (input.fontSizeShortcut(key, mod)) |direction| {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(if (direction == .increase) "⌘+" else "⌘-", now);
                        const delta: c_int = if (direction == .increase) FONT_STEP else -FONT_STEP;
                        const target_size = std.math.clamp(font_size + delta, MIN_FONT_SIZE, MAX_FONT_SIZE);

                        if (target_size != font_size) {
                            const new_font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(target_size, ui_scale));
                            font.deinit();
                            font = new_font;
                            font.metrics = metrics_ptr;
                            font_size = target_size;

                            const term_render_height = adjustedRenderHeightForMode(anim_state.mode, render_height, ui_scale, grid.rows);
                            const term_size = layout.calculateTerminalSizeForMode(&font, render_width, term_render_height, anim_state.mode, config.grid.font_scale, grid.cols, grid.rows);
                            full_cols = term_size.cols;
                            full_rows = term_size.rows;
                            layout.applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, term_render_height);
                            std.debug.print("Font size -> {d}px, terminal size: {d}x{d}\n", .{ font_size, full_cols, full_rows });

                            persistence.font_size = font_size;
                            persistence.save(allocator) catch |err| {
                                std.debug.print("Failed to save persistence: {}\n", .{err});
                            };
                        }

                        var notification_buf: [64]u8 = undefined;
                        const notification_msg = std.fmt.bufPrint(&notification_buf, "Font size: {d}pt", .{font_size}) catch "Font size changed";
                        ui.showToast(notification_msg, now);
                    } else if (key == c.SDLK_N and has_gui and !has_blocking_mod and (anim_state.mode == .Full or anim_state.mode == .Grid)) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘N", now);

                        // Count currently spawned sessions
                        const spawned_count = countSpawnedSessions(sessions);

                        // Check if we need to expand the grid
                        if (grid.needsExpansion(spawned_count)) {
                            // Calculate new grid dimensions
                            const new_dims = GridLayout.calculateDimensions(spawned_count + 1);
                            if (new_dims.cols * new_dims.rows > grid_layout.MAX_TERMINALS) {
                                ui.showToast("Maximum terminals reached", now);
                                continue;
                            }

                            // Get working directory from focused session
                            var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                            defer working_dir.deinit(allocator);

                            const new_capacity = new_dims.cols * new_dims.rows;
                            const new_idx = findNextFreeSlotAfter(sessions, new_capacity, anim_state.focused_session) orelse {
                                ui.showToast("All terminals in use", now);
                                continue;
                            };

                            // Collect active sessions for animation
                            var moves = collectSessionMovesCurrent(sessions, allocator) catch |err| {
                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                continue;
                            };
                            defer moves.deinit(allocator);

                            // Update grid dimensions and start animation
                            if (animations_enabled) {
                                grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.items) catch |err| {
                                    std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                };
                                anim_state.mode = .GridResizing;
                            } else {
                                grid.cols = new_dims.cols;
                                grid.rows = new_dims.rows;
                            }

                            // Spawn new terminal
                            try sessions[new_idx].ensureSpawnedWithDir(working_dir.cwd_z, &loop);
                            session_interaction_component.setStatus(new_idx, .running);
                            session_interaction_component.setAttention(new_idx, false);

                            // Update cell dimensions for new grid
                            cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                            cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                            applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, anim_state.mode, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);

                            session_interaction_component.clearSelection(anim_state.focused_session);
                            session_interaction_component.clearSelection(new_idx);

                            anim_state.previous_session = anim_state.focused_session;
                            anim_state.focused_session = new_idx;

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, new_idx, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);
                            std.debug.print("Grid expanded to {d}x{d}, new terminal at index {d}\n", .{ grid.cols, grid.rows, new_idx });
                        } else {
                            // Grid has space, find next free slot
                            const target_idx: ?usize = if (!focused.spawned)
                                anim_state.focused_session
                            else
                                findNextFreeSlotAfter(sessions, grid.capacity(), anim_state.focused_session);

                            if (target_idx) |next_free_idx| {
                                var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                                defer working_dir.deinit(allocator);

                                try sessions[next_free_idx].ensureSpawnedWithDir(working_dir.cwd_z, &loop);
                                session_interaction_component.setStatus(next_free_idx, .running);
                                session_interaction_component.setAttention(next_free_idx, false);

                                session_interaction_component.clearSelection(anim_state.focused_session);
                                session_interaction_component.clearSelection(next_free_idx);

                                anim_state.previous_session = anim_state.focused_session;
                                anim_state.focused_session = next_free_idx;

                                const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                                const notification_buf = try allocator.alloc(u8, buf_size);
                                defer allocator.free(notification_buf);
                                const notification_msg = try grid_nav.formatGridNotification(notification_buf, next_free_idx, grid.cols, grid.rows);
                                ui.showToast(notification_msg, now);
                            } else {
                                ui.showToast("All terminals in use", now);
                            }
                        }
                    } else if (terminal_shortcut) |idx| {
                        const hotkey_label = input.terminalHotkeyLabel(idx) orelse "⌘?";
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(hotkey_label, now);

                        if (anim_state.mode == .Grid) {
                            try sessions[idx].ensureSpawnedWithLoop(&loop);
                            session_interaction_component.setStatus(idx, .running);
                            session_interaction_component.setAttention(idx, false);

                            const grid_row: c_int = @intCast(idx / grid.cols);
                            const grid_col: c_int = @intCast(idx % grid.cols);
                            const start_rect = Rect{
                                .x = grid_col * cell_width_pixels,
                                .y = grid_row * cell_height_pixels,
                                .w = cell_width_pixels,
                                .h = cell_height_pixels,
                            };
                            const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                            anim_state.focused_session = idx;
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
                                anim_state.previous_session = idx;
                            }
                            std.debug.print("Expanding session via hotkey: {d}\n", .{idx});
                        } else if (anim_state.mode == .Full and idx != anim_state.focused_session) {
                            try sessions[idx].ensureSpawnedWithLoop(&loop);
                            session_interaction_component.clearSelection(anim_state.focused_session);
                            session_interaction_component.clearSelection(idx);
                            session_interaction_component.setStatus(idx, .running);
                            session_interaction_component.setAttention(idx, false);
                            anim_state.focused_session = idx;

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, idx, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);
                            std.debug.print("Switched to session via hotkey: {d}\n", .{idx});
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
                            try grid_nav.navigateGrid(&anim_state, sessions, session_interaction_component, direction, now, true, false, grid.cols, grid.rows, &loop);
                            const new_session = anim_state.focused_session;
                            sessions[new_session].markDirty();
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
                            try grid_nav.navigateGrid(&anim_state, sessions, session_interaction_component, direction, now, true, animations_enabled, grid.cols, grid.rows, &loop);

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, anim_state.focused_session, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);

                            std.debug.print("Full mode grid nav to session {d}\n", .{anim_state.focused_session});
                        } else {
                            if (focused.spawned and !focused.dead) {
                                session_interaction_component.resetScrollIfNeeded(anim_state.focused_session);
                                try input_keys.handleKeyInput(focused, key, mod);
                            }
                        }
                    } else if (key == c.SDLK_RETURN and (mod & c.SDL_KMOD_GUI) != 0 and anim_state.mode == .Grid) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘↵", now);
                        if (countSpawnedSessions(sessions) == 1) {
                            continue;
                        }
                        const clicked_session = anim_state.focused_session;
                        try sessions[clicked_session].ensureSpawnedWithLoop(&loop);

                        session_interaction_component.setStatus(clicked_session, .running);
                        session_interaction_component.setAttention(clicked_session, false);

                        const grid_row: c_int = @intCast(clicked_session / grid.cols);
                        const grid_col: c_int = @intCast(clicked_session % grid.cols);
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
                    } else if (focused.spawned and !focused.dead and !input_keys.isModifierKey(key)) {
                        session_interaction_component.resetScrollIfNeeded(anim_state.focused_session);
                        if (anim_state.mode == .Grid) {
                            session_interaction_component.setAttention(anim_state.focused_session, false);
                        }
                        try input_keys.handleKeyInput(focused, key, mod);
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    const key = scaled_event.key.key;
                    if (key == c.SDLK_ESCAPE and input.canHandleEscapePress(anim_state.mode)) {
                        const focused = sessions[anim_state.focused_session];
                        if (focused.spawned and !focused.dead and focused.shell != null) {
                            const esc_byte: [1]u8 = .{27};
                            _ = focused.shell.?.write(&esc_byte) catch |err| {
                                log.warn("session {d}: failed to send escape key: {}", .{ anim_state.focused_session, err });
                            };
                        }
                        std.debug.print("Escape released, sent to terminal\n", .{});
                    }
                },
                else => {},
            }
        }

        if (!running) break;

        loop.run(.no_wait) catch |err| {
            log.err("xev loop run failed: {}", .{err});
            return err;
        };
        if (relaunch_trace_frames > 0) {
            log.info("frame trace after xev run", .{});
        }

        for (sessions) |session| {
            if (relaunch_trace_frames > 0 and session.spawned) {
                log.info("frame trace before process session idx={d} id={d}", .{ session.slot_index, session.id });
            }
            session.checkAlive();
            session.processOutput() catch |err| {
                log.err("session {d}: process output failed: {}", .{ session.id, err });
                return err;
            };
            session.flushPendingWrites() catch |err| {
                log.err("session {d}: flush pending writes failed: {}", .{ session.id, err });
                return err;
            };
            session.updateCwd(now);
            if (relaunch_trace_frames > 0 and session.spawned) {
                log.info("frame trace after process session idx={d} id={d}", .{ session.slot_index, session.id });
            }
        }
        const any_session_dirty = render_cache.anyDirty(sessions);

        var notifications = notify_queue.drainAll();
        defer notifications.deinit(allocator);
        const had_notifications = notifications.items.len > 0;
        for (notifications.items) |note| {
            const session_idx = findSessionIndexById(sessions, note.session) orelse continue;
            session_interaction_component.setStatus(session_idx, note.state);
            const wants_attention = switch (note.state) {
                .awaiting_approval, .done => true,
                else => false,
            };
            const is_focused_full = anim_state.mode == .Full and anim_state.focused_session == session_idx;
            session_interaction_component.setAttention(session_idx, if (is_focused_full) false else wants_attention);
            std.debug.print("Session {d} (slot {d}) status -> {s}\n", .{ note.session, session_idx, @tagName(note.state) });
        }

        var focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
        const ui_update_host = ui_host.makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid.cols,
            grid.rows,
            full_cols,
            full_rows,
            &anim_state,
            sessions,
            session_ui_info,
            focused_has_foreground_process,
            &theme,
        );
        ui.update(&ui_update_host);

        ui_action_loop: while (ui.popAction()) |action| switch (action) {
            .RestartSession => |idx| {
                if (idx < sessions.len) {
                    try sessions[idx].restart();
                    session_interaction_component.resetView(idx);
                    std.debug.print("UI requested restart: {d}\n", .{idx});
                }
            },
            .FocusSession => |idx| {
                if (anim_state.mode != .Grid) continue;
                if (idx >= sessions.len) continue;

                session_interaction_component.clearSelection(anim_state.focused_session);
                try sessions[idx].ensureSpawnedWithLoop(&loop);
                session_interaction_component.setStatus(idx, .running);
                session_interaction_component.setAttention(idx, false);

                const grid_row: c_int = @intCast(idx / grid.cols);
                const grid_col: c_int = @intCast(idx % grid.cols);
                const cell_rect = Rect{
                    .x = grid_col * cell_width_pixels,
                    .y = grid_row * cell_height_pixels,
                    .w = cell_width_pixels,
                    .h = cell_height_pixels,
                };
                const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                anim_state.focused_session = idx;
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
                    anim_state.previous_session = idx;
                }
                std.debug.print("Expanding session: {d}\n", .{idx});
            },
            .DespawnSession => |idx| {
                if (idx < sessions.len) {
                    if (anim_state.mode == .Full and anim_state.focused_session == idx) {
                        if (animations_enabled) {
                            grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                        } else {
                            anim_state.mode = .Grid;
                        }
                    }
                    log.info("ui despawn requested idx={d} mode={s} spawned_count={d}", .{
                        idx,
                        @tagName(anim_state.mode),
                        countSpawnedSessions(sessions),
                    });
                    var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
                    defer if (old_positions) |*snapshots| {
                        snapshots.deinit(allocator);
                    };
                    if (animations_enabled and anim_state.mode == .Grid) {
                        old_positions = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
                            std.debug.print("Failed to snapshot session positions: {}\n", .{err});
                            break :blk null;
                        };
                    }
                    sessions[idx].deinit(allocator);
                    session_interaction_component.resetView(idx);
                    sessions[idx].markDirty();
                    compactSessions(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state);
                    std.debug.print("UI requested despawn: {d}\n", .{idx});

                    // Handle grid contraction
                    const remaining_count = countSpawnedSessions(sessions);
                    const max_spawned_idx = highestSpawnedIndex(sessions);
                    const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

                    if (remaining_count == 0) {
                        // Re-spawn a fresh terminal in slot 0
                        sessions[0].ensureSpawnedWithLoop(&loop) catch |err| {
                            std.debug.print("Failed to respawn terminal: {}\n", .{err});
                        };
                        anim_state.focused_session = 0;
                        grid.cols = 1;
                        grid.rows = 1;
                        cell_width_pixels = render_width;
                        cell_height_pixels = render_height;
                        anim_state.mode = .Full;
                        applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, anim_state.mode, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                    } else if (remaining_count == 1) {
                        // Only 1 terminal remains - go directly to Full mode, no resize animation
                        grid.cols = 1;
                        grid.rows = 1;
                        cell_width_pixels = render_width;
                        cell_height_pixels = render_height;
                        if (!sessions[anim_state.focused_session].spawned) {
                            for (sessions, 0..) |s, i| {
                                if (s.spawned) {
                                    anim_state.focused_session = i;
                                    break;
                                }
                            }
                        }
                        anim_state.mode = .Full;
                        applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, anim_state.mode, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                    } else {
                        const new_dims = GridLayout.calculateDimensions(required_slots);
                        const should_shrink = new_dims.cols < grid.cols or new_dims.rows < grid.rows;
                        if (should_shrink) {
                            const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                            const grid_will_resize = new_dims.cols != grid.cols or new_dims.rows != grid.rows;
                            if (can_animate_reflow) {
                                if (old_positions) |snapshots| {
                                    var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                        std.debug.print("Failed to collect session moves: {}\n", .{err});
                                        break :blk null;
                                    };
                                    if (move_result) |*moves| {
                                        defer moves.list.deinit(allocator);
                                        if (grid_will_resize or moves.moved) {
                                            grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                            };
                                            anim_state.mode = .GridResizing;
                                        } else {
                                            grid.cols = new_dims.cols;
                                            grid.rows = new_dims.rows;
                                        }
                                    } else {
                                        grid.cols = new_dims.cols;
                                        grid.rows = new_dims.rows;
                                    }
                                } else {
                                    grid.cols = new_dims.cols;
                                    grid.rows = new_dims.rows;
                                }
                            } else {
                                grid.cols = new_dims.cols;
                                grid.rows = new_dims.rows;
                            }

                            cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                            cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                            applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, anim_state.mode, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);

                            if (!sessions[anim_state.focused_session].spawned) {
                                var new_focus: usize = 0;
                                for (sessions, 0..) |s, i| {
                                    if (s.spawned) {
                                        new_focus = i;
                                        break;
                                    }
                                }
                                anim_state.focused_session = new_focus;
                            }
                            std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ grid.cols, grid.rows, remaining_count });
                        } else {
                            const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                            if (can_animate_reflow) {
                                if (old_positions) |snapshots| {
                                    var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                        std.debug.print("Failed to collect session moves: {}\n", .{err});
                                        break :blk null;
                                    };
                                    if (move_result) |*moves| {
                                        defer moves.list.deinit(allocator);
                                        if (moves.moved) {
                                            grid.startResize(grid.cols, grid.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                                            };
                                            anim_state.mode = .GridResizing;
                                        }
                                    }
                                }
                            }
                            if (!sessions[anim_state.focused_session].spawned) {
                                var new_focus: usize = 0;
                                for (sessions, 0..) |s, i| {
                                    if (s.spawned) {
                                        new_focus = i;
                                        break;
                                    }
                                }
                                anim_state.focused_session = new_focus;
                            }
                        }
                    }
                }
            },
            .RequestCollapseFocused => {
                if (anim_state.mode == .Full) {
                    const spawned_count = countSpawnedSessions(sessions);
                    if (spawned_count == 1) {
                        std.debug.print("UI requested collapse ignored (single terminal)\n", .{});
                    } else if (animations_enabled) {
                        grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                    } else {
                        const grid_row: c_int = @intCast(anim_state.focused_session / grid.cols);
                        const grid_col: c_int = @intCast(anim_state.focused_session % grid.cols);
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
            .SwitchWorktree => |switch_action| {
                defer allocator.free(switch_action.path);
                if (switch_action.session >= sessions.len) continue;

                var session = sessions[switch_action.session];
                if (session.hasForegroundProcess()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }

                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                worktree.changeSessionDirectory(session, allocator, switch_action.path) catch |err| {
                    std.debug.print("Failed to change directory for session {d}: {}\n", .{ switch_action.session, err });
                    ui.showToast("Could not switch worktree", now);
                    continue;
                };

                session_interaction_component.setStatus(switch_action.session, .running);
                session_interaction_component.setAttention(switch_action.session, false);
                ui.showToast("Switched worktree", now);
            },
            .CreateWorktree => |create_action| {
                defer allocator.free(create_action.base_path);
                defer allocator.free(create_action.name);
                if (create_action.session >= sessions.len) continue;
                var session = sessions[create_action.session];

                if (session.hasForegroundProcess()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                const command = worktree.buildCreateWorktreeCommand(allocator, create_action.base_path, create_action.name) catch |err| {
                    std.debug.print("Failed to build worktree command: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send worktree command: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };

                // Update cwd to the new worktree path for UI purposes.
                const new_path = std.fs.path.join(allocator, &.{ create_action.base_path, ".architect", create_action.name }) catch null;
                if (new_path) |abs| {
                    session.recordCwd(abs) catch |err| {
                        log.warn("session {d}: failed to record cwd: {}", .{ create_action.session, err });
                    };
                    allocator.free(abs);
                }

                session_interaction_component.setStatus(create_action.session, .running);
                session_interaction_component.setAttention(create_action.session, false);
                ui.showToast("Creating worktree…", now);
            },
            .RemoveWorktree => |remove_action| {
                defer allocator.free(remove_action.path);
                if (remove_action.session >= sessions.len) continue;
                var session = sessions[remove_action.session];

                if (session.hasForegroundProcess()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                for (sessions, 0..) |other_session, idx| {
                    if (idx == remove_action.session) continue;
                    if (!other_session.spawned or other_session.dead) continue;

                    const other_cwd = other_session.cwd_path orelse continue;
                    if (std.mem.eql(u8, other_cwd, remove_action.path)) {
                        ui.showToast("Worktree in use by another session", now);
                        continue :ui_action_loop;
                    }
                    if (std.mem.startsWith(u8, other_cwd, remove_action.path)) {
                        const suffix = other_cwd[remove_action.path.len..];
                        if (suffix.len > 0 and suffix[0] == '/') {
                            ui.showToast("Worktree in use by another session", now);
                            continue :ui_action_loop;
                        }
                    }
                }

                const command = worktree.buildRemoveWorktreeCommand(allocator, remove_action.path) catch |err| {
                    std.debug.print("Failed to build remove worktree command: {}\n", .{err});
                    ui.showToast("Could not remove worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send remove worktree command: {}\n", .{err});
                    ui.showToast("Could not remove worktree", now);
                    continue;
                };

                session_interaction_component.setStatus(remove_action.session, .running);
                session_interaction_component.setAttention(remove_action.session, false);
                ui.showToast("Removing worktree…", now);
            },
            .ToggleMetrics => {
                if (config.metrics.enabled) {
                    metrics_overlay_component.toggle();
                    if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘⇧M", now);
                } else {
                    ui.showToast("Metrics disabled in config", now);
                }
            },
        };

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing or
            anim_state.mode == .PanningLeft or anim_state.mode == .PanningRight or
            anim_state.mode == .PanningUp or anim_state.mode == .PanningDown)
        {
            if (anim_state.isComplete(now)) {
                const previous_mode = anim_state.mode;
                const next_mode = switch (anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => .Full,
                    .Collapsing => .Grid,
                    else => anim_state.mode,
                };
                anim_state.mode = next_mode;
                if (previous_mode == .Collapsing and next_mode == .Grid and anim_state.focused_session < sessions.len) {
                    sessions[anim_state.focused_session].markDirty();
                }
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        // Handle grid resize animation completion
        if (anim_state.mode == .GridResizing) {
            if (grid.updateResize(now)) {
                anim_state.mode = .Grid;
                // Mark all sessions dirty to refresh render cache
                for (sessions) |session| {
                    session.markDirty();
                }
                std.debug.print("Grid resize complete: {d}x{d}\n", .{ grid.cols, grid.rows });
            }
        }

        const desired_font_scale = layout.gridFontScaleForMode(anim_state.mode, config.grid.font_scale);
        if (desired_font_scale != current_grid_font_scale) {
            const term_render_height = adjustedRenderHeightForMode(anim_state.mode, render_height, ui_scale, grid.rows);
            const term_size = layout.calculateTerminalSizeForMode(&font, render_width, term_render_height, anim_state.mode, config.grid.font_scale, grid.cols, grid.rows);
            full_cols = term_size.cols;
            full_rows = term_size.rows;
            layout.applyTerminalResize(sessions, allocator, full_cols, full_rows, render_width, term_render_height);
            current_grid_font_scale = desired_font_scale;
            std.debug.print("Adjusted terminal size for view mode {s}: scale={d:.2} size={d}x{d}\n", .{
                @tagName(anim_state.mode),
                desired_font_scale,
                full_cols,
                full_rows,
            });
        }

        focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
        const ui_render_host = ui_host.makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid.cols,
            grid.rows,
            full_cols,
            full_rows,
            &anim_state,
            sessions,
            session_ui_info,
            focused_has_foreground_process,
            &theme,
        );

        const animating = anim_state.mode != .Grid and anim_state.mode != .Full;
        const ui_needs_frame = ui.needsFrame(&ui_render_host);
        const last_render_stale = last_render_ns == 0 or (frame_start_ns - last_render_ns) >= MAX_IDLE_RENDER_GAP_NS;
        const should_render = animating or any_session_dirty or ui_needs_frame or processed_event or had_notifications or last_render_stale;

        if (should_render) {
            if (relaunch_trace_frames > 0) {
                log.info("frame trace before render", .{});
            }
            renderer_mod.render(
                renderer,
                &render_cache,
                sessions,
                session_interaction_component.viewSlice(),
                cell_width_pixels,
                cell_height_pixels,
                grid.cols,
                grid.rows,
                &anim_state,
                now,
                &font,
                full_cols,
                full_rows,
                render_width,
                render_height,
                &theme,
                config.grid.font_scale,
                &grid,
            ) catch |err| {
                log.err("render failed: {}", .{err});
                return err;
            };
            ui.render(&ui_render_host, renderer);
            _ = c.SDL_RenderPresent(renderer);
            if (relaunch_trace_frames > 0) {
                log.info("frame trace after render", .{});
            }
            metrics_mod.increment(.frame_count);
            last_render_ns = std.time.nanoTimestamp();
        }

        if (relaunch_trace_frames > 0) {
            relaunch_trace_frames -= 1;
        }

        const is_idle = !animating and !any_session_dirty and !ui_needs_frame and !processed_event and !had_notifications;
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

        if (window_close_suppress_countdown > 0) {
            window_close_suppress_countdown -= 1;
        }
    }

    if (builtin.os.tag == .macos) {
        const now = std.time.milliTimestamp();
        for (sessions) |session| {
            session.updateCwd(now);
        }

        persistence.clearTerminalPaths(allocator);
        for (sessions, 0..) |session, idx| {
            if (!session.spawned or session.dead) continue;
            if (session.cwd_path) |path| {
                if (path.len == 0) continue;
                persistence.appendTerminalPath(allocator, path) catch |err| {
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
