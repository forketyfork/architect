const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig");

const is_macos = builtin.os.tag == .macos;
const log = std.log.scoped(.sdl);

pub const WindowPosition = struct { x: c_int, y: c_int };

const window_visibility_margin: c_int = 32;

pub const InitError = error{
    SDLInitFailed,
    TTFInitFailed,
    WindowCreationFailed,
    RendererCreationFailed,
    EventRegistrationFailed,
};

pub const Platform = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    wake_event_type: u32,
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

fn windowPositionIsUsable(
    position: WindowPosition,
    window_w: c_int,
    window_h: c_int,
    display_bounds: c.SDL_Rect,
) bool {
    const margin_x: c_int = @max(0, @min(window_visibility_margin, window_w));
    const margin_y: c_int = @max(0, @min(window_visibility_margin, window_h));
    const min_x = display_bounds.x - window_w + margin_x;
    const max_x = display_bounds.x + display_bounds.w - margin_x;
    const min_y = display_bounds.y - window_h + margin_y;
    const max_y = display_bounds.y + display_bounds.h - margin_y;

    return position.x >= min_x and position.x <= max_x and
        position.y >= min_y and position.y <= max_y;
}

fn restoredWindowPosition(
    position: ?WindowPosition,
    window_w: c_int,
    window_h: c_int,
) ?WindowPosition {
    const desired = position orelse return null;
    const primary = c.SDL_GetPrimaryDisplay();
    if (primary == 0) return desired;

    var display_bounds: c.SDL_Rect = undefined;
    if (!c.SDL_GetDisplayBounds(primary, &display_bounds)) return desired;

    if (windowPositionIsUsable(desired, window_w, window_h, display_bounds)) return desired;

    log.info("saved window position is no longer visible; using default placement", .{});
    return null;
}

pub fn init(
    title: [*:0]const u8,
    width: c_int,
    height: c_int,
    position: ?WindowPosition,
    vsync_requested: bool,
) InitError!Platform {
    // Let macOS provide native scroll momentum instead of synthesizing it.
    _ = c.SDL_SetHint("SDL_MAC_SCROLL_MOMENTUM", "1");
    if (is_macos) {
        // Keep press-and-hold behavior in repeat mode instead of showing the accent picker.
        std.debug.print("Disabling SDL_HINT_MAC_PRESS_AND_HOLD\n", .{});
        _ = c.SDL_SetHint(c.SDL_HINT_MAC_PRESS_AND_HOLD, "0");
        // Prevent Cmd+W from generating SDL_QUIT, allowing us to handle it ourselves
        _ = c.SDL_SetHint(c.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }

    _ = c.SDL_EnableScreenSaver();

    if (!c.TTF_Init()) {
        std.debug.print("TTF_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }

    const restored_position = restoredWindowPosition(position, width, height);
    const window_flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = c.SDL_CreateWindow(title, width, height, window_flags) orelse {
        std.debug.print("SDL_CreateWindow Error: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };

    if (restored_position) |pos| {
        _ = c.SDL_SetWindowPosition(window, pos.x, pos.y);
    }

    // Force Metal renderer; fail if unavailable (no fallback to other drivers).
    const metal_hint_ok = c.SDL_SetHint("SDL_RENDER_DRIVER", "metal");
    if (!metal_hint_ok) {
        std.debug.print(
            "SDL_SetHint Error: failed to set SDL_RENDER_DRIVER to 'metal'; Metal renderer may be unavailable.\n",
            .{},
        );
        return error.RendererCreationFailed;
    }
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
    const wake_event_type = c.SDL_RegisterEvents(1);
    if (wake_event_type == std.math.maxInt(u32)) {
        std.debug.print("SDL_RegisterEvents Error: {s}\n", .{c.SDL_GetError()});
        return error.EventRegistrationFailed;
    }

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
        .wake_event_type = wake_event_type,
        .vsync_enabled = vsync_enabled,
        .window_w = window_w,
        .window_h = window_h,
        .render_w = render_w,
        .render_h = render_h,
        .scale_x = scale_x,
        .scale_y = scale_y,
    };
}

pub fn waitEventTimeout(timeout_ms: c_int) ?c.SDL_Event {
    if (timeout_ms <= 0) return null;

    var event = std.mem.zeroes(c.SDL_Event);
    if (!c.SDL_WaitEventTimeout(&event, timeout_ms)) return null;
    return event;
}

pub fn pushWakeEvent(platform_handle: *const Platform) void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.user.type = platform_handle.wake_event_type;
    if (!c.SDL_PushEvent(&event)) {
        log.err("failed to push runtime wake event: {s}", .{c.SDL_GetError()});
    }
}

pub fn isWakeEvent(platform_handle: *const Platform, event: *const c.SDL_Event) bool {
    return event.type == platform_handle.wake_event_type;
}

pub fn pushWakeEventFromOpaque(context: ?*anyopaque) void {
    const platform_handle = @as(*const Platform, @ptrCast(@alignCast(context orelse return)));
    pushWakeEvent(platform_handle);
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

test "window position is usable when enough of the window remains visible" {
    const bounds = c.SDL_Rect{ .x = 0, .y = 0, .w = 1920, .h = 1080 };

    try std.testing.expect(windowPositionIsUsable(.{ .x = 100, .y = 100 }, 1200, 900, bounds));
    try std.testing.expect(windowPositionIsUsable(.{ .x = -1168, .y = -868 }, 1200, 900, bounds));
    try std.testing.expect(windowPositionIsUsable(.{ .x = 1888, .y = 148 }, 1200, 900, bounds));
}

test "window position is rejected when it is entirely off display" {
    const bounds = c.SDL_Rect{ .x = 0, .y = 0, .w = 1920, .h = 1080 };

    try std.testing.expect(!windowPositionIsUsable(.{ .x = -1200, .y = 100 }, 1200, 900, bounds));
    try std.testing.expect(!windowPositionIsUsable(.{ .x = 100, .y = -900 }, 1200, 900, bounds));
}

test "window position visibility accounts for displays with negative origins" {
    const bounds = c.SDL_Rect{ .x = -1920, .y = -100, .w = 1920, .h = 1080 };

    try std.testing.expect(windowPositionIsUsable(.{ .x = -1800, .y = 0 }, 1200, 900, bounds));
    try std.testing.expect(!windowPositionIsUsable(.{ .x = 0, .y = 0 }, 1200, 900, bounds));
}

test "small windows use their dimensions as the visibility margin" {
    const bounds = c.SDL_Rect{ .x = 0, .y = 0, .w = 1920, .h = 1080 };

    try std.testing.expect(windowPositionIsUsable(.{ .x = 0, .y = 0 }, 16, 16, bounds));
    try std.testing.expect(windowPositionIsUsable(.{ .x = 1904, .y = 1064 }, 16, 16, bounds));
}
