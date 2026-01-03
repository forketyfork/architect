const std = @import("std");
const c = @import("../c.zig");

pub const WindowPosition = struct { x: c_int, y: c_int };

pub const InitError = error{
    SDLInitFailed,
    TTFInitFailed,
    WindowCreationFailed,
    RendererCreationFailed,
};

pub const Platform = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    vsync_enabled: bool,
};

pub fn init(title: [*:0]const u8, width: c_int, height: c_int, position: ?WindowPosition) InitError!Platform {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }

    if (!c.TTF_Init()) {
        std.debug.print("TTF_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }

    const window = c.SDL_CreateWindow(title, width, height, c.SDL_WINDOW_RESIZABLE) orelse {
        std.debug.print("SDL_CreateWindow Error: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };

    if (position) |pos| {
        _ = c.SDL_SetWindowPosition(window, pos.x, pos.y);
    }

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer Error: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    };

    const vsync_enabled = blk: {
        const success = c.SDL_SetRenderVSync(renderer, 1);
        if (!success) {
            std.debug.print("Warning: failed to enable vsync: {s}\n", .{c.SDL_GetError()});
            break :blk false;
        }
        break :blk true;
    };

    return Platform{
        .window = window,
        .renderer = renderer,
        .vsync_enabled = vsync_enabled,
    };
}

pub fn startTextInput(window: *c.SDL_Window) void {
    _ = c.SDL_StartTextInput(window);
}

pub fn stopTextInput(window: *c.SDL_Window) void {
    _ = c.SDL_StopTextInput(window);
}

pub fn deinit(p: *Platform) void {
    c.SDL_DestroyRenderer(p.renderer);
    c.SDL_DestroyWindow(p.window);
    c.TTF_Quit();
    c.SDL_Quit();
}
