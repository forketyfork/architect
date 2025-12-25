const std = @import("std");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("shell.zig");
const pty_mod = @import("pty.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const log = std.log.scoped(.main);

const WINDOW_WIDTH = 1200;
const WINDOW_HEIGHT = 900;
const CELL_WIDTH = 8;
const CELL_HEIGHT = 16;
const GRID_ROWS = 3;
const GRID_COLS = 3;
const COLS = 40;
const ROWS = 12;
const ANIMATION_DURATION_MS = 300;

const ViewMode = enum {
    Grid,
    Expanding,
    Full,
    Collapsing,
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
    start_time: i64,
    start_rect: Rect,
    target_rect: Rect,

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

const SessionState = struct {
    id: usize,
    shell: shell_mod.Shell,
    terminal: ghostty_vt.Terminal,
    stream: VtStreamType,
    output_buf: [4096]u8,

    pub fn init(allocator: std.mem.Allocator, id: usize, shell_path: []const u8, size: pty_mod.winsize) !SessionState {
        const shell = try shell_mod.Shell.spawn(shell_path, size);
        errdefer {
            var s = shell;
            s.deinit();
        }

        var terminal = try ghostty_vt.Terminal.init(allocator, .{
            .cols = size.ws_col,
            .rows = size.ws_row,
        });
        errdefer terminal.deinit(allocator);

        try makeNonBlocking(shell.pty.master);

        return SessionState{
            .id = id,
            .shell = shell,
            .terminal = terminal,
            .stream = undefined,
            .output_buf = undefined,
        };
    }

    pub fn initStream(self: *SessionState) void {
        self.stream = self.terminal.vtStream();
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        self.stream.deinit();
        self.terminal.deinit(allocator);
        self.shell.deinit();
    }

    pub fn processOutput(self: *SessionState) !void {
        const n = self.shell.read(&self.output_buf) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (n > 0) {
            try self.stream.nextSlice(self.output_buf[0..n]);
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "Architect - Terminal Wall",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        c.SDL_WINDOW_SHOWN,
    ) orelse {
        std.debug.print("SDL_CreateWindow Error: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse {
        std.debug.print("SDL_CreateRenderer Error: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Spawning {d} shell instances: {s}\n", .{ GRID_ROWS * GRID_COLS, shell_path });

    const cell_width_pixels = WINDOW_WIDTH / GRID_COLS;
    const cell_height_pixels = WINDOW_HEIGHT / GRID_ROWS;

    const size = pty_mod.winsize{
        .ws_row = ROWS,
        .ws_col = COLS,
        .ws_xpixel = cell_width_pixels,
        .ws_ypixel = cell_height_pixels,
    };

    var sessions: [GRID_ROWS * GRID_COLS]SessionState = undefined;
    var init_count: usize = 0;
    errdefer {
        for (0..init_count) |i| {
            sessions[i].deinit(allocator);
        }
    }

    for (0..GRID_ROWS * GRID_COLS) |i| {
        sessions[i] = try SessionState.init(allocator, i, shell_path, size);
        init_count += 1;
    }

    for (&sessions) |*session| {
        session.initStream();
    }

    defer {
        for (&sessions) |*session| {
            session.deinit(allocator);
        }
    }

    var running = true;
    var last_render: i64 = 0;
    const render_interval_ms: i64 = 16;

    var anim_state = AnimationState{
        .mode = .Grid,
        .focused_session = 0,
        .start_time = 0,
        .start_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .target_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };

    while (running) {
        const now = std.time.milliTimestamp();

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    const key = event.key.keysym;

                    if (key.sym == c.SDLK_ESCAPE and anim_state.mode == .Full) {
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
                        anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = WINDOW_WIDTH, .h = WINDOW_HEIGHT };
                        anim_state.target_rect = target_rect;
                        std.debug.print("Collapsing session: {d}\n", .{anim_state.focused_session});
                    } else {
                        var buf: [8]u8 = undefined;
                        const n = try encodeKey(key, &buf);
                        if (n > 0) {
                            _ = try sessions[anim_state.focused_session].shell.write(buf[0..n]);
                        }
                    }
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    if (anim_state.mode == .Grid) {
                        const mouse_x = event.button.x;
                        const mouse_y = event.button.y;
                        const grid_col = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), GRID_COLS - 1);
                        const grid_row = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), GRID_ROWS - 1);
                        const clicked_session: usize = grid_row * @as(usize, GRID_COLS) + grid_col;

                        const start_rect = Rect{
                            .x = @as(c_int, @intCast(grid_col)) * cell_width_pixels,
                            .y = @as(c_int, @intCast(grid_row)) * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                        const target_rect = Rect{ .x = 0, .y = 0, .w = WINDOW_WIDTH, .h = WINDOW_HEIGHT };

                        anim_state.mode = .Expanding;
                        anim_state.focused_session = clicked_session;
                        anim_state.start_time = now;
                        anim_state.start_rect = start_rect;
                        anim_state.target_rect = target_rect;
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    }
                },
                else => {},
            }
        }

        for (&sessions) |*session| {
            try session.processOutput();
        }

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing) {
            if (anim_state.isComplete(now)) {
                anim_state.mode = if (anim_state.mode == .Expanding) .Full else .Grid;
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        if (now - last_render >= render_interval_ms) {
            try render(renderer, &sessions, allocator, cell_width_pixels, cell_height_pixels, &anim_state, now);
            c.SDL_RenderPresent(renderer);
            last_render = now;
        }

        c.SDL_Delay(1);
    }
}

fn render(
    renderer: *c.SDL_Renderer,
    sessions: []SessionState,
    _: std.mem.Allocator,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    anim_state: *const AnimationState,
    current_time: i64,
) !void {
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

                try renderSession(renderer, session, cell_rect, i == anim_state.focused_session);
            }
        },
        .Full => {
            const full_rect = Rect{ .x = 0, .y = 0, .w = WINDOW_WIDTH, .h = WINDOW_HEIGHT };
            try renderSession(renderer, &sessions[anim_state.focused_session], full_rect, true);
        },
        .Expanding, .Collapsing => {
            const animating_rect = anim_state.getCurrentRect(current_time);

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

                    try renderSession(renderer, session, cell_rect, false);
                }
            }

            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, true);
        },
    }
}

fn renderSession(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    is_focused: bool,
) !void {
    if (is_focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 60, 255);
    } else {
        _ = c.SDL_SetRenderDrawColor(renderer, 20, 20, 20, 255);
    }
    const bg_rect = c.SDL_Rect{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    };
    _ = c.SDL_RenderFillRect(renderer, &bg_rect);

    const screen = session.terminal.screens.active;
    const pages = screen.pages;

    var row: usize = 0;
    while (row < ROWS) : (row += 1) {
        var col: usize = 0;
        while (col < COLS) : (col += 1) {
            const list_cell = pages.getCell(.{ .active = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;

            const cell = list_cell.cell;
            const cp = cell.content.codepoint;
            if (cp == 0 or cp == ' ') continue;

            const x: c_int = rect.x + @as(c_int, @intCast(col * CELL_WIDTH));
            const y: c_int = rect.y + @as(c_int, @intCast(row * CELL_HEIGHT));

            _ = c.SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
            const char_rect = c.SDL_Rect{
                .x = x,
                .y = y,
                .w = CELL_WIDTH,
                .h = CELL_HEIGHT,
            };
            _ = c.SDL_RenderFillRect(renderer, &char_rect);
        }
    }

    if (is_focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, 255);
    } else {
        _ = c.SDL_SetRenderDrawColor(renderer, 60, 60, 60, 255);
    }
    const border_rect = c.SDL_Rect{
        .x = rect.x,
        .y = rect.y,
        .w = rect.w,
        .h = rect.h,
    };
    _ = c.SDL_RenderDrawRect(renderer, &border_rect);
}

fn encodeKey(key: c.SDL_Keysym, buf: []u8) !usize {
    const sym = key.sym;
    return switch (sym) {
        c.SDLK_RETURN => blk: {
            buf[0] = '\r';
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
        else => blk: {
            if (sym >= 32 and sym <= 126) {
                var char_byte: u8 = @intCast(sym);
                if (key.mod & c.KMOD_CTRL != 0) {
                    if (char_byte >= 'a' and char_byte <= 'z') {
                        char_byte = char_byte - 'a' + 1;
                    } else if (char_byte >= 'A' and char_byte <= 'Z') {
                        char_byte = char_byte - 'A' + 1;
                    }
                }
                buf[0] = char_byte;
                break :blk 1;
            }
            break :blk 0;
        },
    };
}

fn makeNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
