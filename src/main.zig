// Main application entry: wires SDL2 rendering, ghostty-vt terminals, PTY-backed
// shells, and the grid/animation system that drives the 3×3 terminal wall UI.
const std = @import("std");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
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
const ANIMATION_DURATION_MS = 300;
const PRECOLLAPSE_PAUSE_MS = 200;
const PRECOLLAPSE_DURATION_MS = 500;
const PRECOLLAPSE_SCALE: f32 = 0.99;
const GRID_SCALE: f32 = 1.0 / 3.0;
const ATTENTION_THICKNESS: c_int = 16;
const NOTIFY_SOCKET_NAME = "architect_notify.sock";
const SCROLL_LINES_PER_TICK: isize = 3;
const DEFAULT_FONT_SIZE: c_int = 14;
const MIN_FONT_SIZE: c_int = 8;
const MAX_FONT_SIZE: c_int = 96;
const FONT_STEP: c_int = 1;
const FONT_PATH: [*:0]const u8 = "/System/Library/Fonts/SFNSMono.ttf";
const NOTIFICATION_DURATION_MS: i64 = 2500;
const NOTIFICATION_FADE_START_MS: i64 = 1500;
const NOTIFICATION_FONT_SIZE: c_int = 36;
const NOTIFICATION_BG_MAX_ALPHA: u8 = 200;
const NOTIFICATION_BORDER_MAX_ALPHA: u8 = 180;

const SessionStatus = enum {
    idle,
    running,
    awaiting_approval,
    done,
};

const ViewMode = enum {
    Grid,
    Expanding,
    Full,
    Collapsing,
    PanningLeft,
    PanningRight,
    PreCollapse,
    CancelPreCollapse,
};

const Rect = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

const AnimationState = struct {
    mode: ViewMode,
    focused_session: usize,
    previous_session: usize,
    start_time: i64,
    start_rect: Rect,
    target_rect: Rect,
    escape_press_time: ?i64,

    // Ease curve keeps both expansion and collapse feeling smooth instead of linear.
    fn easeInOutCubic(t: f32) f32 {
        if (t < 0.5) {
            return 4 * t * t * t;
        } else {
            const p = 2 * t - 2;
            return 1 + p * p * p / 2;
        }
    }

    fn interpolateRect(start: Rect, target: Rect, progress: f32) Rect {
        const eased = easeInOutCubic(progress);
        return Rect{
            .x = start.x + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.x - start.x)) * eased)),
            .y = start.y + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.y - start.y)) * eased)),
            .w = start.w + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.w - start.w)) * eased)),
            .h = start.h + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.h - start.h)) * eased)),
        };
    }

    fn getCurrentRect(self: *const AnimationState, current_time: i64) Rect {
        const elapsed = current_time - self.start_time;
        const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, ANIMATION_DURATION_MS));
        return interpolateRect(self.start_rect, self.target_rect, progress);
    }

    fn isComplete(self: *const AnimationState, current_time: i64) bool {
        const elapsed = current_time - self.start_time;
        return elapsed >= ANIMATION_DURATION_MS;
    }
};

const VtStreamType = blk: {
    const T = ghostty_vt.Terminal;
    const fn_info = @typeInfo(@TypeOf(T.vtStream)).@"fn";
    break :blk fn_info.return_type.?;
};
// ghostty-vt exposes vtStream() as a factory; we peel its return type here so
// SessionState can store the concrete stream without duplicating the signature.

const Notification = struct {
    session: usize,
    state: SessionStatus,
};

const ToastNotification = struct {
    message: [256]u8 = undefined,
    message_len: usize = 0,
    start_time: i64 = 0,
    active: bool = false,

    pub fn show(self: *ToastNotification, message: []const u8, current_time: i64) void {
        const len = @min(message.len, self.message.len - 1);
        @memcpy(self.message[0..len], message[0..len]);
        self.message[len] = 0;
        self.message_len = len;
        self.start_time = current_time;
        self.active = true;
    }

    pub fn isVisible(self: *const ToastNotification, current_time: i64) bool {
        if (!self.active) return false;
        const elapsed = current_time - self.start_time;
        return elapsed < NOTIFICATION_DURATION_MS;
    }

    pub fn getAlpha(self: *const ToastNotification, current_time: i64) u8 {
        if (!self.isVisible(current_time)) return 0;
        const elapsed = current_time - self.start_time;
        if (elapsed < NOTIFICATION_FADE_START_MS) {
            return 255;
        }
        const fade_progress = @as(f32, @floatFromInt(elapsed - NOTIFICATION_FADE_START_MS)) /
            @as(f32, @floatFromInt(NOTIFICATION_DURATION_MS - NOTIFICATION_FADE_START_MS));
        const eased_progress = fade_progress * fade_progress * (3.0 - 2.0 * fade_progress);
        const alpha = 255.0 * (1.0 - eased_progress);
        return @intFromFloat(@max(0, @min(255, alpha)));
    }
};

const NotificationQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(Notification) = .{},

    // Single-producer (notify thread) / single-consumer (render loop) queue guarded by a mutex.
    pub fn deinit(self: *NotificationQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn push(self: *NotificationQueue, allocator: std.mem.Allocator, item: Notification) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, item);
    }

    pub fn drainAll(self: *NotificationQueue) std.ArrayListUnmanaged(Notification) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const items = self.items;
        self.items = .{};
        return items;
    }
};

const SessionState = struct {
    id: usize,
    shell: ?shell_mod.Shell,
    terminal: ?ghostty_vt.Terminal,
    stream: ?VtStreamType,
    output_buf: [4096]u8,
    status: SessionStatus = .running,
    attention: bool = false,
    is_scrolled: bool = false,
    dirty: bool = true,
    cache_texture: ?*c.SDL_Texture = null,
    cache_w: c_int = 0,
    cache_h: c_int = 0,
    spawned: bool = false,
    shell_path: []const u8,
    pty_size: pty_mod.winsize,
    session_id_z: [16:0]u8,
    notify_sock_z: [:0]const u8,
    allocator: std.mem.Allocator,

    pub const InitError = shell_mod.Shell.SpawnError || MakeNonBlockingError || error{
        DivisionByZero,
        GraphemeAllocOutOfMemory,
        GraphemeMapOutOfMemory,
        HyperlinkMapOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkSetOutOfMemory,
        NeedsRehash,
        OutOfMemory,
        StringAllocOutOfMemory,
        StyleSetNeedsRehash,
        StyleSetOutOfMemory,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        id: usize,
        shell_path: []const u8,
        size: pty_mod.winsize,
        session_id_z: [:0]const u8,
        notify_sock: [:0]const u8,
    ) InitError!SessionState {
        var session_id_buf: [16:0]u8 = undefined;
        @memcpy(session_id_buf[0..session_id_z.len], session_id_z);
        session_id_buf[session_id_z.len] = 0;

        return SessionState{
            .id = id,
            .shell = null,
            .terminal = null,
            .stream = null,
            .output_buf = undefined,
            .spawned = false,
            .shell_path = shell_path,
            .pty_size = size,
            .session_id_z = session_id_buf,
            .notify_sock_z = notify_sock,
            .allocator = allocator,
        };
    }

    pub fn ensureSpawned(self: *SessionState) InitError!void {
        if (self.spawned) return;

        const shell = try shell_mod.Shell.spawn(
            self.shell_path,
            self.pty_size,
            &self.session_id_z,
            self.notify_sock_z,
        );
        errdefer {
            var s = shell;
            s.deinit();
        }

        var terminal = try ghostty_vt.Terminal.init(self.allocator, .{
            .cols = self.pty_size.ws_col,
            .rows = self.pty_size.ws_row,
        });
        errdefer terminal.deinit(self.allocator);

        try makeNonBlocking(shell.pty.master);

        self.shell = shell;
        self.terminal = terminal;
        self.spawned = true;
        self.stream = self.terminal.?.vtStream();
        self.dirty = true;

        log.debug("spawned session {d}", .{self.id});

        self.processOutput() catch {};
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        if (self.cache_texture) |tex| {
            c.SDL_DestroyTexture(tex);
        }
        if (self.spawned) {
            if (self.stream) |*stream| {
                stream.deinit();
            }
            if (self.terminal) |*terminal| {
                terminal.deinit(allocator);
            }
            if (self.shell) |*shell| {
                shell.deinit();
            }
        }
    }

    pub const ProcessOutputError = posix.ReadError || error{
        DivisionByZero,
        GraphemeAllocOutOfMemory,
        GraphemeMapOutOfMemory,
        HyperlinkMapOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkSetOutOfMemory,
        NeedsRehash,
        OutOfMemory,
        StringAllocOutOfMemory,
        StyleSetNeedsRehash,
        StyleSetOutOfMemory,
    };

    pub fn processOutput(self: *SessionState) ProcessOutputError!void {
        if (!self.spawned) return;

        const shell = &(self.shell orelse return);
        const stream = &(self.stream orelse return);

        const n = shell.read(&self.output_buf) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (n > 0) {
            try stream.nextSlice(self.output_buf[0..n]);
            self.dirty = true;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Socket listener relays external "awaiting approval / done" signals from
    // shells (or other tools) into the UI thread without blocking rendering.
    var notify_queue = NotificationQueue{};
    defer notify_queue.deinit(allocator);

    const notify_sock = try getNotifySocketPath(allocator);
    defer allocator.free(notify_sock);

    const notify_thread = try startNotifyThread(allocator, notify_sock, &notify_queue);
    notify_thread.detach();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    if (!c.TTF_Init()) {
        std.debug.print("TTF_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }
    defer c.TTF_Quit();

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

    const window = c.SDL_CreateWindow(
        "Architect - Terminal Wall",
        config.window_width,
        config.window_height,
        c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.debug.print("SDL_CreateWindow Error: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    if (config.window_x >= 0 and config.window_y >= 0) {
        _ = c.SDL_SetWindowPosition(window, config.window_x, config.window_y);
    }

    _ = c.SDL_StartTextInput(window);
    defer _ = c.SDL_StopTextInput(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer Error: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    const vsync_enabled = blk: {
        const success = c.SDL_SetRenderVSync(renderer, 1);
        if (!success) {
            std.debug.print("Warning: failed to enable vsync: {s}\n", .{c.SDL_GetError()});
            break :blk false;
        }
        break :blk true;
    };

    var font_size: c_int = config.font_size;
    var font = try font_mod.Font.init(allocator, renderer, FONT_PATH, font_size);
    defer font.deinit();

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

    const size = pty_mod.winsize{
        .ws_row = full_rows,
        .ws_col = full_cols,
        .ws_xpixel = @intCast(window_width),
        .ws_ypixel = @intCast(window_height),
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
        .escape_press_time = null,
    };

    var toast_notification = ToastNotification{};

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
                    if (focused.spawned) {
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

                    if (fontSizeShortcut(key, mod)) |direction| {
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
                    } else if (isSwitchTerminalShortcut(key, mod)) |is_next| {
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
                    } else if (gridNavShortcut(key, mod)) |direction| {
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
                            if (focused.spawned) {
                                if (focused.is_scrolled) {
                                    if (focused.terminal) |*terminal| {
                                        terminal.screens.active.pages.scroll(.{ .active = {} });
                                        focused.is_scrolled = false;
                                    }
                                }
                                var buf: [8]u8 = undefined;
                                const n = encodeKeyWithMod(key, mod, &buf);
                                if (n > 0) {
                                    if (focused.shell) |*shell| {
                                        _ = try shell.write(buf[0..n]);
                                    }
                                }
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
                    } else if (key == c.SDLK_ESCAPE and canHandleEscapePress(anim_state.mode)) {
                        const focused = &sessions[anim_state.focused_session];
                        if (focused.spawned and focused.shell != null) {
                            const esc_byte: [1]u8 = .{27};
                            _ = focused.shell.?.write(&esc_byte) catch {};
                        }

                        anim_state.escape_press_time = now;
                        std.debug.print("Escape pressed at {d}\n", .{now});
                    } else {
                        const focused = &sessions[anim_state.focused_session];
                        if (focused.spawned) {
                            if (focused.is_scrolled) {
                                if (focused.terminal) |*terminal| {
                                    terminal.screens.active.pages.scroll(.{ .active = {} });
                                    focused.is_scrolled = false;
                                }
                            }
                            var buf: [8]u8 = undefined;
                            const n = encodeKeyWithMod(key, mod, &buf);
                            if (n > 0) {
                                if (focused.shell) |*shell| {
                                    _ = try shell.write(buf[0..n]);
                                }
                            }
                        }
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    const key = event.key.key;
                    if (key == c.SDLK_ESCAPE) {
                        if (anim_state.mode == .PreCollapse) {
                            anim_state.mode = .CancelPreCollapse;
                            anim_state.start_time = now;
                            anim_state.start_rect = anim_state.getCurrentRect(now);
                            anim_state.target_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };
                            std.debug.print("PreCollapse cancelled, bouncing back\n", .{});
                        }
                        anim_state.escape_press_time = null;
                        std.debug.print("Escape released\n", .{});
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (anim_state.mode == .Grid) {
                        const mouse_x: c_int = @intFromFloat(event.button.x);
                        const mouse_y: c_int = @intFromFloat(event.button.y);
                        const grid_col = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), GRID_COLS - 1);
                        const grid_row = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), GRID_ROWS - 1);
                        const clicked_session: usize = grid_row * @as(usize, GRID_COLS) + grid_col;

                        try sessions[clicked_session].ensureSpawned();

                        sessions[clicked_session].status = .running;
                        sessions[clicked_session].attention = false;

                        const start_rect = Rect{
                            .x = @as(c_int, @intCast(grid_col)) * cell_width_pixels,
                            .y = @as(c_int, @intCast(grid_row)) * cell_height_pixels,
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
            try session.processOutput();
        }

        if (anim_state.escape_press_time) |press_time| {
            const elapsed = now - press_time;
            if (elapsed >= PRECOLLAPSE_PAUSE_MS and canStartPreCollapse(anim_state.mode)) {
                const shrink_offset_x: c_int = @intFromFloat(@as(f32, @floatFromInt(window_width)) * (1.0 - PRECOLLAPSE_SCALE) / 2.0);
                const shrink_offset_y: c_int = @intFromFloat(@as(f32, @floatFromInt(window_height)) * (1.0 - PRECOLLAPSE_SCALE) / 2.0);
                const shrink_width: c_int = @intFromFloat(@as(f32, @floatFromInt(window_width)) * PRECOLLAPSE_SCALE);
                const shrink_height: c_int = @intFromFloat(@as(f32, @floatFromInt(window_height)) * PRECOLLAPSE_SCALE);

                anim_state.mode = .PreCollapse;
                anim_state.start_time = now;
                anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };
                anim_state.target_rect = Rect{
                    .x = shrink_offset_x,
                    .y = shrink_offset_y,
                    .w = shrink_width,
                    .h = shrink_height,
                };
                // Clear escape_press_time since we've acted on it. Further animation is handled
                // by PreCollapse state which auto-transitions to Collapsing after 500ms.
                anim_state.escape_press_time = null;
                std.debug.print("PreCollapse started after pause for session: {d}\n", .{anim_state.focused_session});
            } else if (anim_state.mode == .Grid or anim_state.mode == .Collapsing) {
                anim_state.escape_press_time = null;
            }
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

        if (anim_state.mode == .PreCollapse) {
            const elapsed = now - anim_state.start_time;
            if (elapsed >= PRECOLLAPSE_DURATION_MS) {
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
                anim_state.start_rect = anim_state.getCurrentRect(now);
                anim_state.target_rect = target_rect;
                std.debug.print("PreCollapse -> Collapsing session: {d}\n", .{anim_state.focused_session});
            }
        }

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing or
            anim_state.mode == .PanningLeft or anim_state.mode == .PanningRight or
            anim_state.mode == .CancelPreCollapse)
        {
            if (anim_state.isComplete(now)) {
                anim_state.mode = switch (anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight, .CancelPreCollapse => .Full,
                    .Collapsing => .Grid,
                    else => anim_state.mode,
                };
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        try render(renderer, &sessions, allocator, cell_width_pixels, cell_height_pixels, &anim_state, now, &font, full_cols, full_rows, window_width, window_height);
        renderToastNotification(renderer, &toast_notification, now, window_width);
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
        .Full, .PanningLeft, .PanningRight, .PreCollapse, .CancelPreCollapse => anim_state.focused_session,
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
    const cols = @max(1, @divFloor(window_width, font.cell_width));
    const rows = @max(1, @divFloor(window_height, font.cell_height));
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
    const new_size = pty_mod.winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = @intCast(window_width),
        .ws_ypixel = @intCast(window_height),
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

fn getCellColor(color: ghostty_vt.Style.Color, default: c.SDL_Color) c.SDL_Color {
    return switch (color) {
        .none => default,
        .palette => |idx| get256Color(idx),
        .rgb => |rgb| c.SDL_Color{
            .r = rgb.r,
            .g = rgb.g,
            .b = rgb.b,
            .a = 255,
        },
    };
}

const RenderError = font_mod.Font.RenderGlyphError;

fn render(
    renderer: *c.SDL_Renderer,
    sessions: []SessionState,
    _: std.mem.Allocator,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    anim_state: *const AnimationState,
    current_time: i64,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    window_width: c_int,
    window_height: c_int,
) RenderError!void {
    // Central draw routine: depending on view mode, paint either the full grid
    // or the focused session with animation-aware scaling and overlays.
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);

    switch (anim_state.mode) {
        .Grid => {
            for (sessions, 0..) |*session, i| {
                const grid_row: c_int = @intCast(i / GRID_COLS);
                const grid_col: c_int = @intCast(i % GRID_COLS);

                const cell_rect = Rect{
                    .x = grid_col * cell_width_pixels,
                    .y = grid_row * cell_height_pixels,
                    .w = cell_width_pixels,
                    .h = cell_height_pixels,
                };

                try renderGridSessionCached(renderer, session, cell_rect, GRID_SCALE, i == anim_state.focused_session, true, font, term_cols, term_rows, current_time);
            }
        },
        .Full => {
            const full_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.focused_session], full_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false);
        },
        .PanningLeft, .PanningRight => {
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, ANIMATION_DURATION_MS));
            const eased = AnimationState.easeInOutCubic(progress);

            const offset = @as(c_int, @intFromFloat(@as(f32, @floatFromInt(window_width)) * eased));
            const pan_offset = if (anim_state.mode == .PanningLeft) -offset else offset;

            const prev_rect = Rect{ .x = pan_offset, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.previous_session], prev_rect, 1.0, false, false, font, term_cols, term_rows, current_time, false);

            const new_offset = if (anim_state.mode == .PanningLeft)
                window_width - offset
            else
                -window_width + offset;
            const new_rect = Rect{ .x = new_offset, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.focused_session], new_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false);
        },
        .PreCollapse => {
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(PRECOLLAPSE_DURATION_MS)));
            const eased = AnimationState.easeInOutCubic(progress);
            const anim_scale = 1.0 + (PRECOLLAPSE_SCALE - 1.0) * eased;

            const shrink_offset_x: c_int = @intFromFloat(@as(f32, @floatFromInt(window_width)) * (1.0 - anim_scale) / 2.0);
            const shrink_offset_y: c_int = @intFromFloat(@as(f32, @floatFromInt(window_height)) * (1.0 - anim_scale) / 2.0);
            const shrink_width: c_int = @intFromFloat(@as(f32, @floatFromInt(window_width)) * anim_scale);
            const shrink_height: c_int = @intFromFloat(@as(f32, @floatFromInt(window_height)) * anim_scale);

            const animating_rect = Rect{
                .x = shrink_offset_x,
                .y = shrink_offset_y,
                .w = shrink_width,
                .h = shrink_height,
            };
            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, true, font, term_cols, term_rows, current_time, false);
        },
        .CancelPreCollapse => {
            const animating_rect = anim_state.getCurrentRect(current_time);
            const elapsed = current_time - anim_state.start_time;
            const duration: i64 = ANIMATION_DURATION_MS;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(duration)));
            const eased = AnimationState.easeInOutCubic(progress);

            const start_scale: f32 = PRECOLLAPSE_SCALE;
            const end_scale: f32 = 1.0;
            const anim_scale = start_scale + (end_scale - start_scale) * eased;

            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, true, font, term_cols, term_rows, current_time, false);
        },
        .Expanding, .Collapsing => {
            const animating_rect = anim_state.getCurrentRect(current_time);
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, ANIMATION_DURATION_MS));
            const eased = AnimationState.easeInOutCubic(progress);
            const anim_scale = if (anim_state.mode == .Expanding)
                GRID_SCALE + (1.0 - GRID_SCALE) * eased
            else
                1.0 - (1.0 - GRID_SCALE) * eased;

            for (sessions, 0..) |*session, i| {
                if (i != anim_state.focused_session) {
                    const grid_row: c_int = @intCast(i / GRID_COLS);
                    const grid_col: c_int = @intCast(i % GRID_COLS);

                    const cell_rect = Rect{
                        .x = grid_col * cell_width_pixels,
                        .y = grid_row * cell_height_pixels,
                        .w = cell_width_pixels,
                        .h = cell_height_pixels,
                    };

                    try renderGridSessionCached(renderer, session, cell_rect, GRID_SCALE, false, true, font, term_cols, term_rows, current_time);
                }
            }

            const apply_effects = anim_scale < 0.999;
            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, apply_effects, font, term_cols, term_rows, current_time, false);
        },
    }
}

fn renderSession(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    apply_effects: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    current_time_ms: i64,
    is_grid_view: bool,
) RenderError!void {
    try renderSessionContent(renderer, session, rect, scale, is_focused, font, term_cols, term_rows);
    renderSessionOverlays(renderer, session, rect, is_focused, apply_effects, current_time_ms, is_grid_view);
}

fn renderSessionContent(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
) RenderError!void {
    if (!session.spawned) {
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    } else if (is_focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 60, 255);
    } else {
        _ = c.SDL_SetRenderDrawColor(renderer, 30, 30, 40, 255);
    }
    const bg_rect = c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = c.SDL_RenderFillRect(renderer, &bg_rect);

    if (!session.spawned) return;

    const terminal = session.terminal orelse {
        log.err("session {d} is spawned but terminal is null!", .{session.id});
        return;
    };
    const screen = terminal.screens.active;
    const pages = screen.pages;

    const base_cell_width = font.cell_width;
    const base_cell_height = font.cell_height;

    const cell_width_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_width)) * scale)));
    const cell_height_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_height)) * scale)));

    const padding: c_int = 8;
    const drawable_w: c_int = rect.w - padding * 2;
    const drawable_h: c_int = rect.h - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return;

    const origin_x: c_int = rect.x + padding;
    const origin_y: c_int = rect.y + padding;

    const max_cols_fit: usize = @intCast(@max(0, @divFloor(drawable_w, cell_width_actual)));
    const max_rows_fit: usize = @intCast(@max(0, @divFloor(drawable_h, cell_height_actual)));
    const visible_cols: usize = @min(@as(usize, term_cols), max_cols_fit);
    const visible_rows: usize = @min(@as(usize, term_rows), max_rows_fit);

    const default_fg = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };

    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
        var col: usize = 0;
        while (col < visible_cols) : (col += 1) {
            const list_cell = pages.getCell(if (session.is_scrolled)
                .{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }
            else
                .{ .active = .{ .x = @intCast(col), .y = @intCast(row) } }) orelse continue;

            const cell = list_cell.cell;
            const cp = cell.content.codepoint;
            if (cp == 0 or cp == ' ') continue;

            const x: c_int = origin_x + @as(c_int, @intCast(col)) * cell_width_actual;
            const y: c_int = origin_y + @as(c_int, @intCast(row)) * cell_height_actual;

            if (x < rect.x or x >= rect.x + rect.w) continue;
            if (y < rect.y or y >= rect.y + rect.h) continue;

            const style = list_cell.style();
            const fg_color = getCellColor(style.fg_color, default_fg);

            try font.renderGlyph(cp, x, y, cell_width_actual, cell_height_actual, fg_color);
        }
    }

    if (!session.is_scrolled and is_focused) {
        const cursor = screen.cursor;
        const cursor_col = cursor.x;
        const cursor_row = cursor.y;

        if (cursor_col < visible_cols and cursor_row < visible_rows) {
            const cursor_x: c_int = origin_x + @as(c_int, @intCast(cursor_col)) * cell_width_actual;
            const cursor_y: c_int = origin_y + @as(c_int, @intCast(cursor_row)) * cell_height_actual;

            if (cursor_x >= rect.x and cursor_x < rect.x + rect.w and
                cursor_y >= rect.y and cursor_y < rect.y + rect.h)
            {
                _ = c.SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
                const cursor_rect = c.SDL_FRect{
                    .x = @floatFromInt(cursor_x),
                    .y = @floatFromInt(cursor_y),
                    .w = @floatFromInt(cell_width_actual),
                    .h = @floatFromInt(cell_height_actual),
                };
                _ = c.SDL_RenderFillRect(renderer, &cursor_rect);
            }
        }
    }
}

fn renderSessionOverlays(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    is_focused: bool,
    apply_effects: bool,
    current_time_ms: i64,
    is_grid_view: bool,
) void {
    if (apply_effects) {
        applyTvOverlay(renderer, rect, is_focused);
    } else {
        if (is_focused) {
            _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, 255);
        } else {
            _ = c.SDL_SetRenderDrawColor(renderer, 60, 60, 60, 255);
        }
        const border_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderRect(renderer, &border_rect);
    }

    if (is_grid_view and session.is_scrolled) {
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 100, 200);
        const indicator_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y + rect.h - 4),
            .w = @floatFromInt(rect.w),
            .h = 4.0,
        };
        _ = c.SDL_RenderFillRect(renderer, &indicator_rect);
    }

    if (is_grid_view and session.attention) {
        // Visual signal used by Claude/Gemini approval flow: pulsing yellow for
        // awaiting_approval, solid green for done.
        const color = switch (session.status) {
            .awaiting_approval => blk: {
                const phase_ms: f32 = @floatFromInt(@mod(current_time_ms, @as(i64, 1000)));
                const pulse = 0.5 + 0.5 * std.math.sin(phase_ms / 1000.0 * 2.0 * std.math.pi);
                const base_alpha: u8 = @intFromFloat(170 + 70 * pulse);
                break :blk c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = base_alpha };
            },
            .done => c.SDL_Color{ .r = 35, .g = 209, .b = 139, .a = 230 },
            else => c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = 230 },
        };
        drawThickBorder(renderer, rect, ATTENTION_THICKNESS, color);

        const tint_color = switch (session.status) {
            .awaiting_approval => c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = 25 },
            .done => c.SDL_Color{ .r = 35, .g = 209, .b = 139, .a = 30 },
            else => c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = 25 },
        };
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, tint_color.r, tint_color.g, tint_color.b, tint_color.a);
        const tint_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &tint_rect);
    }
}

fn ensureCacheTexture(renderer: *c.SDL_Renderer, session: *SessionState, width: c_int, height: c_int) bool {
    if (session.cache_texture) |tex| {
        if (session.cache_w == width and session.cache_h == height) {
            return true;
        }
        log.debug("destroying cache for session {d} (resize)", .{session.id});
        c.SDL_DestroyTexture(tex);
        session.cache_texture = null;
    }

    log.debug("creating cache for session {d} spawned={}", .{ session.id, session.spawned });
    const tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, width, height) orelse {
        std.debug.print("Failed to create cache texture {d}x{d} for session {d}: {s}\n", .{ width, height, session.id, c.SDL_GetError() });
        return false;
    };
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    session.cache_texture = tex;
    session.cache_w = width;
    session.cache_h = height;
    session.dirty = true;
    return true;
}

fn renderGridSessionCached(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    apply_effects: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    current_time_ms: i64,
) RenderError!void {
    const can_cache = ensureCacheTexture(renderer, session, rect.w, rect.h);

    if (can_cache) {
        if (session.cache_texture) |tex| {
            if (session.dirty) {
                log.debug("rendering to cache: session={d} spawned={} focused={}", .{ session.id, session.spawned, is_focused });
                _ = c.SDL_SetRenderTarget(renderer, tex);
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
                _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
                _ = c.SDL_RenderClear(renderer);
                const local_rect = Rect{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
                try renderSessionContent(renderer, session, local_rect, scale, is_focused, font, term_cols, term_rows);
                session.dirty = false;
                _ = c.SDL_SetRenderTarget(renderer, null);
            }

            const dest_rect = c.SDL_FRect{
                .x = @floatFromInt(rect.x),
                .y = @floatFromInt(rect.y),
                .w = @floatFromInt(rect.w),
                .h = @floatFromInt(rect.h),
            };
            _ = c.SDL_RenderTexture(renderer, tex, null, &dest_rect);
            renderSessionOverlays(renderer, session, rect, is_focused, apply_effects, current_time_ms, true);
            return;
        }
    }

    // Fallback to direct rendering if cache unavailable.
    try renderSession(renderer, session, rect, scale, is_focused, apply_effects, font, term_cols, term_rows, current_time_ms, true);
}

fn applyTvOverlay(renderer: *c.SDL_Renderer, rect: Rect, is_focused: bool) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    // Subtle vignette across the panel
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 60);
    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    });

    const radius: c_int = 12;

    const border_color = if (is_focused)
        c.SDL_Color{ .r = 120, .g = 170, .b = 255, .a = 190 }
    else
        c.SDL_Color{ .r = 80, .g = 80, .b = 90, .a = 170 };

    _ = c.SDL_SetRenderDrawColor(renderer, border_color.r, border_color.g, border_color.b, border_color.a);
    drawRoundedBorder(renderer, rect, radius);
}

fn drawRoundedBorder(renderer: *c.SDL_Renderer, rect: Rect, radius: c_int) void {
    const fx = @as(f32, @floatFromInt(rect.x));
    const fy = @as(f32, @floatFromInt(rect.y));
    const fw = @as(f32, @floatFromInt(rect.w));
    const fh = @as(f32, @floatFromInt(rect.h));
    const frad = @as(f32, @floatFromInt(radius));

    // Straight edges
    _ = c.SDL_RenderLine(renderer, fx + frad, fy, fx + fw - frad - 1.0, fy);
    _ = c.SDL_RenderLine(renderer, fx + frad, fy + fh - 1.0, fx + fw - frad - 1.0, fy + fh - 1.0);
    _ = c.SDL_RenderLine(renderer, fx, fy + frad, fx, fy + fh - frad - 1.0);
    _ = c.SDL_RenderLine(renderer, fx + fw - 1.0, fy + frad, fx + fw - 1.0, fy + fh - frad - 1.0);

    // Corners (quarter circles)
    var angle: f32 = 0.0;
    const step: f32 = std.math.pi / 64.0;
    while (angle <= std.math.pi / 2.0) : (angle += step) {
        const rx = frad * std.math.cos(angle);
        const ry = frad * std.math.sin(angle);

        const centers = [_]struct { x: f32, y: f32, sx: f32, sy: f32 }{
            .{ .x = fx + frad, .y = fy + frad, .sx = -1.0, .sy = -1.0 }, // top-left
            .{ .x = fx + fw - frad - 1.0, .y = fy + frad, .sx = 1.0, .sy = -1.0 }, // top-right
            .{ .x = fx + frad, .y = fy + fh - frad - 1.0, .sx = -1.0, .sy = 1.0 }, // bottom-left
            .{ .x = fx + fw - frad - 1.0, .y = fy + fh - frad - 1.0, .sx = 1.0, .sy = 1.0 }, // bottom-right
        };

        for (centers) |cinfo| {
            _ = c.SDL_RenderPoint(renderer, cinfo.x + cinfo.sx * rx, cinfo.y + cinfo.sy * ry);
        }
    }
}

fn drawThickBorder(renderer: *c.SDL_Renderer, rect: Rect, thickness: c_int, color: c.SDL_Color) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    const radius: c_int = 12;
    var i: c_int = 0;
    while (i < thickness) : (i += 1) {
        const r = Rect{
            .x = rect.x + i,
            .y = rect.y + i,
            .w = rect.w - i * 2,
            .h = rect.h - i * 2,
        };
        drawRoundedBorder(renderer, r, radius);
    }
}

fn renderToastNotification(
    renderer: *c.SDL_Renderer,
    notification: *const ToastNotification,
    current_time: i64,
    window_width: c_int,
) void {
    if (!notification.isVisible(current_time)) return;

    const alpha = notification.getAlpha(current_time);
    if (alpha == 0) return;

    const notification_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(NOTIFICATION_FONT_SIZE)) orelse return;
    defer c.TTF_CloseFont(notification_font);

    const message_z = @as([*:0]const u8, @ptrCast(&notification.message));
    const fg_color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = alpha };
    const surface = c.TTF_RenderText_Blended(notification_font, message_z, notification.message_len, fg_color) orelse return;
    defer c.SDL_DestroySurface(surface);

    const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
    defer c.SDL_DestroyTexture(texture);

    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);

    var text_width_f: f32 = 0;
    var text_height_f: f32 = 0;
    _ = c.SDL_GetTextureSize(texture, &text_width_f, &text_height_f);

    const text_width: c_int = @intFromFloat(text_width_f);
    const text_height: c_int = @intFromFloat(text_height_f);

    const padding: c_int = 30;
    const bg_padding: c_int = 20;
    const x = @divFloor(window_width - text_width, 2);
    const y = padding;

    const bg_rect = c.SDL_FRect{
        .x = @as(f32, @floatFromInt(x - bg_padding)),
        .y = @as(f32, @floatFromInt(y - bg_padding)),
        .w = @as(f32, @floatFromInt(text_width + bg_padding * 2)),
        .h = @as(f32, @floatFromInt(text_height + bg_padding * 2)),
    };

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    const bg_alpha = @min(alpha, NOTIFICATION_BG_MAX_ALPHA);
    _ = c.SDL_SetRenderDrawColor(renderer, 20, 20, 30, bg_alpha);
    _ = c.SDL_RenderFillRect(renderer, &bg_rect);

    const border_alpha = @min(alpha, NOTIFICATION_BORDER_MAX_ALPHA);
    _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, border_alpha);
    _ = c.SDL_RenderRect(renderer, &bg_rect);

    const dest_rect = c.SDL_FRect{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .w = text_width_f,
        .h = text_height_f,
    };

    _ = c.SDL_RenderTexture(renderer, texture, null, &dest_rect);
}

const FontSizeDirection = enum { increase, decrease };

fn fontSizeShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?FontSizeDirection {
    if ((mod & c.SDL_KMOD_GUI) == 0) return null;

    const shift_held = (mod & c.SDL_KMOD_SHIFT) != 0;
    return switch (key) {
        c.SDLK_EQUALS => if (shift_held) .increase else null,
        c.SDLK_MINUS => .decrease,
        c.SDLK_KP_PLUS => .increase,
        c.SDLK_KP_MINUS => .decrease,
        else => null,
    };
}

fn isSwitchTerminalShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?bool {
    if ((mod & c.SDL_KMOD_GUI) == 0 or (mod & c.SDL_KMOD_SHIFT) == 0) return null;
    if (key == c.SDLK_RIGHTBRACKET) return true;
    if (key == c.SDLK_LEFTBRACKET) return false;
    return null;
}

const GridNavDirection = enum { up, down, left, right };

fn gridNavShortcut(key: c.SDL_Keycode, mod: c.SDL_Keymod) ?GridNavDirection {
    if ((mod & c.SDL_KMOD_GUI) == 0) return null;
    if ((mod & c.SDL_KMOD_SHIFT) != 0) return null;
    return switch (key) {
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        else => null,
    };
}

fn canHandleEscapePress(mode: ViewMode) bool {
    return mode != .Grid and mode != .Collapsing and mode != .PreCollapse and mode != .CancelPreCollapse;
}

fn canStartPreCollapse(mode: ViewMode) bool {
    return mode != .Grid and mode != .PreCollapse and mode != .Collapsing and mode != .CancelPreCollapse;
}

fn encodeKeyWithMod(key: c.SDL_Keycode, mod: c.SDL_Keymod, buf: []u8) usize {
    if (mod & c.SDL_KMOD_CTRL != 0) {
        if (key >= c.SDLK_A and key <= c.SDLK_Z) {
            buf[0] = @as(u8, @intCast(key - c.SDLK_A + 1));
            return 1;
        }
    }

    if (mod & c.SDL_KMOD_GUI != 0) {
        return switch (key) {
            c.SDLK_LEFT => blk: {
                buf[0] = 1;
                break :blk 1;
            },
            c.SDLK_RIGHT => blk: {
                buf[0] = 5;
                break :blk 1;
            },
            c.SDLK_BACKSPACE => blk: {
                buf[0] = 21;
                break :blk 1;
            },
            else => 0,
        };
    }

    if (mod & c.SDL_KMOD_ALT != 0) {
        return switch (key) {
            c.SDLK_LEFT => blk: {
                @memcpy(buf[0..2], "\x1bb");
                break :blk 2;
            },
            c.SDLK_RIGHT => blk: {
                @memcpy(buf[0..2], "\x1bf");
                break :blk 2;
            },
            c.SDLK_BACKSPACE => blk: {
                buf[0] = 23;
                break :blk 1;
            },
            else => 0,
        };
    }

    return switch (key) {
        c.SDLK_RETURN => blk: {
            buf[0] = '\r';
            break :blk 1;
        },
        c.SDLK_TAB => blk: {
            buf[0] = '\t';
            break :blk 1;
        },
        c.SDLK_BACKSPACE => blk: {
            buf[0] = 127;
            break :blk 1;
        },
        c.SDLK_ESCAPE => blk: {
            buf[0] = 27;
            break :blk 1;
        },
        c.SDLK_UP => blk: {
            @memcpy(buf[0..3], "\x1b[A");
            break :blk 3;
        },
        c.SDLK_DOWN => blk: {
            @memcpy(buf[0..3], "\x1b[B");
            break :blk 3;
        },
        c.SDLK_RIGHT => blk: {
            @memcpy(buf[0..3], "\x1b[C");
            break :blk 3;
        },
        c.SDLK_LEFT => blk: {
            @memcpy(buf[0..3], "\x1b[D");
            break :blk 3;
        },
        else => 0,
    };
}

const MakeNonBlockingError = posix.FcntlError;

fn makeNonBlocking(fd: posix.fd_t) MakeNonBlockingError!void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}

const GetNotifySocketPathError = std.mem.Allocator.Error;

fn getNotifySocketPath(allocator: std.mem.Allocator) GetNotifySocketPathError![:0]u8 {
    // Use XDG runtime dir when available; fall back to /tmp for ad-hoc runs.
    const base = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const pid = std.c.getpid();
    const socket_name = try std.fmt.allocPrint(allocator, "architect_notify_{d}.sock", .{pid});
    defer allocator.free(socket_name);
    return try std.fs.path.joinZ(allocator, &[_][]const u8{ base, socket_name });
}

const NotifyContext = struct {
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
};

const StartNotifyThreadError = std.Thread.SpawnError;

fn startNotifyThread(
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    queue: *NotificationQueue,
) StartNotifyThreadError!std.Thread {
    // Best-effort remove stale socket.
    _ = std.posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };

    const handler = struct {
        fn parseNotification(bytes: []const u8) ?Notification {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const alloc = arena.allocator();
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) return null;
            const obj = root.object;

            const state_val = obj.get("state") orelse return null;
            if (state_val != .string) return null;
            const state_str = state_val.string;
            const state = if (std.mem.eql(u8, state_str, "start"))
                SessionStatus.running
            else if (std.mem.eql(u8, state_str, "awaiting_approval"))
                SessionStatus.awaiting_approval
            else if (std.mem.eql(u8, state_str, "done"))
                SessionStatus.done
            else
                return null;

            const session_val = obj.get("session") orelse return null;
            if (session_val != .integer) return null;
            if (session_val.integer < 0) return null;

            return Notification{
                .session = @intCast(session_val.integer),
                .state = state,
            };
        }

        fn run(ctx: NotifyContext) !void {
            const addr = try std.net.Address.initUnix(ctx.socket_path);
            const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
            defer posix.close(fd);

            try posix.bind(fd, &addr.any, addr.getOsSockLen());
            try posix.listen(fd, 16);
            const sock_path = std.mem.sliceTo(ctx.socket_path, 0);
            _ = std.posix.fchmodat(posix.AT.FDCWD, sock_path, 0o600, 0) catch {};

            // Accept JSON lines from helper processes and enqueue lightweight
            // notifications for the render thread; malformed inputs are ignored.
            while (true) {
                const conn_fd = posix.accept(fd, null, null, 0) catch continue;
                defer posix.close(conn_fd);

                var buffer = std.ArrayList(u8){};
                defer buffer.deinit(ctx.allocator);

                var tmp: [512]u8 = undefined;
                while (true) {
                    const n = posix.read(conn_fd, &tmp) catch |err| switch (err) {
                        error.WouldBlock, error.ConnectionResetByPeer => break,
                        else => break,
                    };
                    if (n == 0) break;
                    if (buffer.items.len + n > 1024) break;
                    buffer.appendSlice(ctx.allocator, tmp[0..n]) catch break;
                }

                if (buffer.items.len == 0) continue;

                if (parseNotification(buffer.items)) |note| {
                    ctx.queue.push(ctx.allocator, note) catch {};
                }
            }
        }
    };

    const ctx = NotifyContext{ .allocator = allocator, .socket_path = socket_path, .queue = queue };
    return try std.Thread.spawn(.{}, handler.run, .{ctx});
}

test "encodeKeyWithMod - return key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RETURN, 0, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "encodeKeyWithMod - tab key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_TAB, 0, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\t'), buf[0]);
}

test "encodeKeyWithMod - arrow keys" {
    var buf: [8]u8 = undefined;

    const n_up = encodeKeyWithMod(c.SDLK_UP, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_up);
    try std.testing.expectEqualSlices(u8, "\x1b[A", buf[0..n_up]);

    const n_down = encodeKeyWithMod(c.SDLK_DOWN, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_down);
    try std.testing.expectEqualSlices(u8, "\x1b[B", buf[0..n_down]);

    const n_right = encodeKeyWithMod(c.SDLK_RIGHT, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_right);
    try std.testing.expectEqualSlices(u8, "\x1b[C", buf[0..n_right]);

    const n_left = encodeKeyWithMod(c.SDLK_LEFT, 0, &buf);
    try std.testing.expectEqual(@as(usize, 3), n_left);
    try std.testing.expectEqualSlices(u8, "\x1b[D", buf[0..n_left]);
}

test "encodeKeyWithMod - ctrl+a" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_A, c.SDL_KMOD_CTRL, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+left (beginning of line)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_GUI, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
}

test "encodeKeyWithMod - cmd+right (end of line)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_GUI, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 5), buf[0]);
}

test "encodeKeyWithMod - alt+left (backward word)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_LEFT, c.SDL_KMOD_ALT, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bb", buf[0..n]);
}

test "encodeKeyWithMod - alt+right (forward word)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_RIGHT, c.SDL_KMOD_ALT, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualSlices(u8, "\x1bf", buf[0..n]);
}

test "encodeKeyWithMod - cmd+backspace (delete line)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_GUI, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 21), buf[0]);
}

test "encodeKeyWithMod - alt+backspace (delete word)" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(c.SDLK_BACKSPACE, c.SDL_KMOD_ALT, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 23), buf[0]);
}

test "encodeKeyWithMod - unknown key" {
    var buf: [8]u8 = undefined;
    const n = encodeKeyWithMod(0, 0, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "fontSizeShortcut - plus/minus variants" {
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.increase, fontSizeShortcut(c.SDLK_KP_PLUS, c.SDL_KMOD_GUI).?);
    try std.testing.expectEqual(FontSizeDirection.decrease, fontSizeShortcut(c.SDLK_KP_MINUS, c.SDL_KMOD_GUI).?);
    try std.testing.expect(fontSizeShortcut(c.SDLK_EQUALS, c.SDL_KMOD_SHIFT) == null);
}

test "NotificationQueue - push and drain" {
    const allocator = std.testing.allocator;
    var queue = NotificationQueue{};
    defer queue.deinit(allocator);

    try queue.push(allocator, .{ .session = 0, .state = .running });
    try queue.push(allocator, .{ .session = 1, .state = .awaiting_approval });
    try queue.push(allocator, .{ .session = 2, .state = .done });

    var items = queue.drainAll();
    defer items.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqual(@as(usize, 0), items.items[0].session);
    try std.testing.expectEqual(SessionStatus.running, items.items[0].state);
    try std.testing.expectEqual(@as(usize, 1), items.items[1].session);
    try std.testing.expectEqual(SessionStatus.awaiting_approval, items.items[1].state);
    try std.testing.expectEqual(@as(usize, 2), items.items[2].session);
    try std.testing.expectEqual(SessionStatus.done, items.items[2].state);
}

test "get256Color - basic ANSI colors" {
    const black = get256Color(0);
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    const white = get256Color(15);
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);
}

test "get256Color - grayscale" {
    const gray = get256Color(232);
    try std.testing.expectEqual(gray.r, gray.g);
    try std.testing.expectEqual(gray.g, gray.b);
}

test "AnimationState.easeInOutCubic" {
    try std.testing.expectEqual(@as(f32, 0.0), AnimationState.easeInOutCubic(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), AnimationState.easeInOutCubic(1.0));

    const mid = AnimationState.easeInOutCubic(0.5);
    try std.testing.expect(mid > 0.4 and mid < 0.6);
}

test "AnimationState.interpolateRect" {
    const start = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const target = Rect{ .x = 100, .y = 100, .w = 200, .h = 200 };

    const at_start = AnimationState.interpolateRect(start, target, 0.0);
    try std.testing.expectEqual(start.x, at_start.x);
    try std.testing.expectEqual(start.y, at_start.y);
    try std.testing.expectEqual(start.w, at_start.w);
    try std.testing.expectEqual(start.h, at_start.h);

    const at_end = AnimationState.interpolateRect(start, target, 1.0);
    try std.testing.expectEqual(target.x, at_end.x);
    try std.testing.expectEqual(target.y, at_end.y);
    try std.testing.expectEqual(target.w, at_end.w);
    try std.testing.expectEqual(target.h, at_end.h);

    const at_mid = AnimationState.interpolateRect(start, target, 0.5);
    try std.testing.expect(at_mid.x > start.x and at_mid.x < target.x);
    try std.testing.expect(at_mid.y > start.y and at_mid.y < target.y);
}
