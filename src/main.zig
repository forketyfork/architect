const std = @import("std");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("shell.zig");
const pty_mod = @import("pty.zig");
const font_mod = @import("font.zig");
const c = @import("c.zig");

const log = std.log.scoped(.main);

const WINDOW_WIDTH = 1200;
const WINDOW_HEIGHT = 900;
const GRID_ROWS = 3;
const GRID_COLS = 3;
const ANIMATION_DURATION_MS = 300;
const GRID_SCALE: f32 = 1.0 / 3.0;

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

    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "1");

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    if (c.TTF_Init() != 0) {
        std.debug.print("TTF_Init Error: {s}\n", .{c.TTF_GetError()});
        return error.TTFInitFailed;
    }
    defer c.TTF_Quit();

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

    var font = try font_mod.Font.init(allocator, renderer, "/System/Library/Fonts/SFNSMono.ttf", 14);
    defer font.deinit();

    const full_cols = @as(u16, @intCast(@divFloor(WINDOW_WIDTH, font.cell_width)));
    const full_rows = @as(u16, @intCast(@divFloor(WINDOW_HEIGHT, font.cell_height)));

    std.debug.print("Full window terminal size: {d}x{d}\n", .{ full_cols, full_rows });

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Spawning {d} shell instances: {s}\n", .{ GRID_ROWS * GRID_COLS, shell_path });

    const cell_width_pixels = WINDOW_WIDTH / GRID_COLS;
    const cell_height_pixels = WINDOW_HEIGHT / GRID_ROWS;

    const size = pty_mod.winsize{
        .ws_row = full_rows,
        .ws_col = full_cols,
        .ws_xpixel = WINDOW_WIDTH,
        .ws_ypixel = WINDOW_HEIGHT,
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
            try render(renderer, &sessions, allocator, cell_width_pixels, cell_height_pixels, &anim_state, now, &font, full_cols, full_rows);
            c.SDL_RenderPresent(renderer);
            last_render = now;
        }

        c.SDL_Delay(1);
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

                try renderSession(renderer, session, cell_rect, GRID_SCALE, i == anim_state.focused_session, font, term_cols, term_rows);
            }
        },
        .Full => {
            const full_rect = Rect{ .x = 0, .y = 0, .w = WINDOW_WIDTH, .h = WINDOW_HEIGHT };
            try renderSession(renderer, &sessions[anim_state.focused_session], full_rect, 1.0, true, font, term_cols, term_rows);
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

                    try renderSession(renderer, session, cell_rect, GRID_SCALE, false, font, term_cols, term_rows);
                }
            }

            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, font, term_cols, term_rows);
        },
    }
}

fn renderSession(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
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

    const base_cell_width = font.cell_width;
    const base_cell_height = font.cell_height;

    const cell_width_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_width)) * scale)));
    const cell_height_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_height)) * scale)));

    const origin_x: c_int = rect.x;
    const origin_y: c_int = rect.y;

    const default_fg = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };

    var row: usize = 0;
    while (row < term_rows) : (row += 1) {
        var col: usize = 0;
        while (col < term_cols) : (col += 1) {
            const list_cell = pages.getCell(.{ .active = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;

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
