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
    /// window logical size in points
    window_w: c_int,
    window_h: c_int,
    /// render output size in pixels
    render_w: c_int,
    render_h: c_int,
    /// scale factor render_pixels / window_points (per axis)
    scale_x: f32,
    scale_y: f32,
};

pub fn init(
    title: [*:0]const u8,
    width: c_int,
    height: c_int,
    position: ?WindowPosition,
    vsync_requested: bool,
) InitError!Platform {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }

    if (!c.TTF_Init()) {
        std.debug.print("TTF_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }

    const window_flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = c.SDL_CreateWindow(title, width, height, window_flags) orelse {
        std.debug.print("SDL_CreateWindow Error: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };

    if (position) |pos| {
        _ = c.SDL_SetWindowPosition(window, pos.x, pos.y);
    }

    // Force Metal renderer; fail if unavailable (no fallback to other drivers).
    _ = c.SDL_SetHint("SDL_RENDER_DRIVER", "metal");
    const renderer = c.SDL_CreateRenderer(window, "metal") orelse {
        std.debug.print("SDL_CreateRenderer Error: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    };

    if (c.SDL_GetRendererName(renderer)) |name| {
        if (!std.mem.eql(u8, std.mem.sliceTo(name, 0), "metal")) {
            std.debug.print("Renderer mismatch: expected metal, got {s}\n", .{name});
            return error.RendererCreationFailed;
        }
    }

    const vsync_enabled = blk: {
        const success = c.SDL_SetRenderVSync(renderer, if (vsync_requested) 1 else 0);
        if (!success and vsync_requested) {
            std.debug.print("Warning: failed to enable vsync: {s}\n", .{c.SDL_GetError()});
            break :blk false;
        }
        break :blk vsync_requested and success;
    };

    var window_w: c_int = 0;
    var window_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &window_w, &window_h);
    var render_w: c_int = 0;
    var render_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &render_w, &render_h);
    const scale_x: f32 = if (window_w != 0) @as(f32, @floatFromInt(render_w)) / @as(f32, @floatFromInt(window_w)) else 1.0;
    const scale_y: f32 = if (window_h != 0) @as(f32, @floatFromInt(render_h)) / @as(f32, @floatFromInt(window_h)) else 1.0;

    return Platform{
        .window = window,
        .renderer = renderer,
        .vsync_enabled = vsync_enabled,
        .window_w = window_w,
        .window_h = window_h,
        .render_w = render_w,
        .render_h = render_h,
        .scale_x = scale_x,
        .scale_y = scale_y,
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
