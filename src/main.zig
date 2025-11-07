const std = @import("std");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("shell.zig");
const pty_mod = @import("pty.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const log = std.log.scoped(.main);

const WINDOW_WIDTH = 800;
const WINDOW_HEIGHT = 600;
const CELL_WIDTH = 10;
const CELL_HEIGHT = 20;
const COLS = 80;
const ROWS = 24;

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
        "Architect - Terminal",
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
    std.debug.print("Spawning shell: {s}\n", .{shell_path});

    const size = pty_mod.winsize{
        .ws_row = ROWS,
        .ws_col = COLS,
        .ws_xpixel = WINDOW_WIDTH,
        .ws_ypixel = WINDOW_HEIGHT,
    };

    var shell = try shell_mod.Shell.spawn(shell_path, size);
    defer shell.deinit();

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = size.ws_col,
        .rows = size.ws_row,
    });
    defer terminal.deinit(allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();

    try makeNonBlocking(shell.pty.master);

    var output_buf: [4096]u8 = undefined;
    var running = true;
    var last_render: i64 = 0;
    const render_interval_ms: i64 = 16;

    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    const key = event.key.keysym;
                    var buf: [8]u8 = undefined;
                    const n = try encodeKey(key, &buf);
                    if (n > 0) {
                        _ = try shell.write(buf[0..n]);
                    }
                },
                else => {},
            }
        }

        const n = shell.read(&output_buf) catch |err| {
            if (err == error.WouldBlock) {
                c.SDL_Delay(1);
                continue;
            }
            return err;
        };

        if (n > 0) {
            try stream.nextSlice(output_buf[0..n]);
        }

        const now = std.time.milliTimestamp();
        if (now - last_render >= render_interval_ms) {
            try renderTerminal(renderer, &terminal, allocator);
            c.SDL_RenderPresent(renderer);
            last_render = now;
        }

        c.SDL_Delay(1);
    }
}

fn renderTerminal(renderer: *c.SDL_Renderer, terminal: *ghostty_vt.Terminal, _: std.mem.Allocator) !void {
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);

    const screen = &terminal.screen;
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

            const x: c_int = @intCast(col * CELL_WIDTH);
            const y: c_int = @intCast(row * CELL_HEIGHT);

            _ = c.SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
            const rect = c.SDL_Rect{
                .x = x,
                .y = y,
                .w = CELL_WIDTH,
                .h = CELL_HEIGHT,
            };
            _ = c.SDL_RenderFillRect(renderer, &rect);
        }
    }
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
