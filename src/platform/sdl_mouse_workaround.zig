// zwanzig-disable: identifier-style
//! WORKAROUND for an SDL bug on macOS 26+. Re-check on every SDL upgrade:
//! the `verified_sdl_version` test fails until someone does.
//!
//! On macOS 26 and later, SDL computes every mouse motion position as the
//! global mouse position minus its cached window position (`mouseMoved:` in
//! src/video/cocoa/SDL_cocoawindow.m), and button and wheel events reuse that
//! position. The cached position is only refreshed by `windowDidMove:`, which
//! converts Cocoa coordinates using the main display's height at that moment.
//! When the displays reconfigure (sleep/wake, docking, a monitor reconnecting)
//! the main display can briefly change, and a move notification taken then
//! stores a position that is off by the difference between the two displays'
//! heights. SDL refreshes its main display height afterwards but never the
//! window position, so every mouse event lands that far from the pointer until
//! the window moves again (e.g. by leaving and re-entering fullscreen).
//!
//! The fix here measures how far SDL's cached window position is from the real
//! one, read from the NSWindow the same way `windowDidMove:` does, and shifts
//! the coordinates of mouse events by that amount.
//!
//! Remove this file once SDL recomputes window positions after the main display
//! changes (`Cocoa_DisplayReconfigurationCallback` in SDL_cocoamodes.m), or once
//! `mouseMoved:` stops deriving positions from the cached window position.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig");

const log = std.log.scoped(.sdl_mouse_workaround);

const is_macos = builtin.os.tag == .macos;

/// The SDL release whose Cocoa sources this workaround was checked against,
/// in `SDL_GetVersion()` encoding.
pub const verified_sdl_version: c_int = 3_004_018;

/// How far real window-relative mouse coordinates are from the ones SDL
/// reports, in window points.
pub const Offset = struct {
    x: f32,
    y: f32,

    pub const zero: Offset = .{ .x = 0, .y = 0 };

    /// SDL subtracts its cached window origin from the global mouse position,
    /// so the correction is the cached origin minus the real one.
    pub fn between(sdl_origin: Point, real_origin: Point) Offset {
        return .{ .x = sdl_origin.x - real_origin.x, .y = sdl_origin.y - real_origin.y };
    }

    pub fn isZero(self: Offset) bool {
        return self.x == 0 and self.y == 0;
    }
};

pub const Point = struct { x: f32, y: f32 };

/// Shifts the window-relative coordinates of the mouse events SDL derives from
/// its cached window position. Drop events use window-local coordinates and are
/// left alone.
pub fn applyOffset(event: *c.SDL_Event, offset: Offset) void {
    switch (event.type) {
        c.SDL_EVENT_MOUSE_MOTION => {
            event.motion.x += offset.x;
            event.motion.y += offset.y;
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            event.button.x += offset.x;
            event.button.y += offset.y;
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            event.wheel.mouse_x += offset.x;
            event.wheel.mouse_y += offset.y;
        },
        else => {},
    }
}

fn isAffectedEvent(event_type: u32) bool {
    return switch (event_type) {
        c.SDL_EVENT_MOUSE_MOTION, c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_WHEEL => true,
        else => false,
    };
}

/// Hand-written AppKit/CoreGraphics bindings, for the same reasons given in
/// `macos_input_source.zig`.
const appkit = if (is_macos) struct {
    pub const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    pub const NSOperatingSystemVersion = extern struct { major: isize, minor: isize, patch: isize };

    pub extern fn objc_getClass(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    pub extern fn sel_registerName(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    pub extern fn objc_msgSend() callconv(.c) void;
    // x86_64 returns structs larger than 16 bytes through a hidden pointer,
    // which shifts the receiver and selector, so it needs the _stret entry
    // point. arm64 has no such variant.
    extern fn objc_msgSend_stret() callconv(.c) void;
    pub const msg_send_rect_entry = if (builtin.cpu.arch == .x86_64) &objc_msgSend_stret else &objc_msgSend;

    pub extern fn CGMainDisplayID() callconv(.c) u32;
    pub extern fn CGDisplayPixelsHigh(display: u32) callconv(.c) usize;

    pub const MsgSendId = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    pub const MsgSendRect = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect;
    pub const MsgSendRectRect = *const fn (?*anyopaque, ?*anyopaque, NSRect) callconv(.c) NSRect;
    pub const MsgSendVersionBool = *const fn (?*anyopaque, ?*anyopaque, NSOperatingSystemVersion) callconv(.c) u8;
} else struct {};

pub const MousePositionFix = if (is_macos) struct {
    nswindow: ?*anyopaque = null,
    sel_frame: ?*anyopaque = null,
    sel_content_rect: ?*anyopaque = null,
    logged_offset: Offset = Offset.zero,

    /// Inactive below macOS 26, where SDL takes mouse positions from the
    /// event's window-local location and the cached position does not matter.
    pub fn init(window: *c.SDL_Window) MousePositionFix {
        if (!sdlUsesCachedWindowPosition()) return .{};
        return initForWindow(window);
    }

    fn initForWindow(window: *c.SDL_Window) MousePositionFix {
        const props = c.SDL_GetWindowProperties(window);
        const nswindow = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse {
            log.warn("no NSWindow for the SDL window: {s}; mouse positions stay uncorrected", .{c.SDL_GetError()});
            return .{};
        };
        const sel_frame = appkit.sel_registerName("frame");
        const sel_content_rect = appkit.sel_registerName("contentRectForFrameRect:");
        if (sel_frame == null or sel_content_rect == null) {
            log.warn("failed to register NSWindow selectors; mouse positions stay uncorrected", .{});
            return .{};
        }
        return .{ .nswindow = nswindow, .sel_frame = sel_frame, .sel_content_rect = sel_content_rect };
    }

    pub fn correct(self: *MousePositionFix, window: *c.SDL_Window, event: *c.SDL_Event) void {
        if (self.nswindow == null or !isAffectedEvent(event.type)) return;
        const offset = self.currentOffset(window) orelse return;
        if (offset.x != self.logged_offset.x or offset.y != self.logged_offset.y) {
            log.info("SDL window position is off by ({d}, {d}) points; correcting mouse coordinates", .{ offset.x, offset.y });
            self.logged_offset = offset;
        }
        applyOffset(event, offset);
    }

    fn currentOffset(self: *const MousePositionFix, window: *c.SDL_Window) ?Offset {
        var sdl_x: c_int = 0;
        var sdl_y: c_int = 0;
        if (!c.SDL_GetWindowPosition(window, &sdl_x, &sdl_y)) {
            log.warn("SDL_GetWindowPosition failed: {s}", .{c.SDL_GetError()});
            return null;
        }
        const real = self.realContentOrigin();
        return Offset.between(
            .{ .x = @floatFromInt(sdl_x), .y = @floatFromInt(sdl_y) },
            real,
        );
    }

    /// The content area's top-left corner in SDL's global coordinates,
    /// computed like `windowDidMove:` but with the current main display height.
    fn realContentOrigin(self: *const MousePositionFix) Point {
        const msg_send_rect = @as(appkit.MsgSendRect, @ptrCast(appkit.msg_send_rect_entry));
        const msg_send_rect_rect = @as(appkit.MsgSendRectRect, @ptrCast(appkit.msg_send_rect_entry));
        const frame = msg_send_rect(self.nswindow, self.sel_frame);
        const content = msg_send_rect_rect(self.nswindow, self.sel_content_rect, frame);
        const main_height: f64 = @floatFromInt(appkit.CGDisplayPixelsHigh(appkit.CGMainDisplayID()));
        return .{
            .x = @floatCast(content.x),
            .y = @floatCast(main_height - content.y - content.h),
        };
    }

    /// Mirrors SDL's `@available(macOS 26.0, *)` guard in `mouseMoved:`.
    fn sdlUsesCachedWindowPosition() bool {
        const class = appkit.objc_getClass("NSProcessInfo") orelse return false;
        const sel_process_info = appkit.sel_registerName("processInfo") orelse return false;
        const sel_at_least = appkit.sel_registerName("isOperatingSystemAtLeastVersion:") orelse return false;
        const msg_send_id = @as(appkit.MsgSendId, @ptrCast(&appkit.objc_msgSend));
        const process_info = msg_send_id(class, sel_process_info) orelse return false;
        const msg_send_version = @as(appkit.MsgSendVersionBool, @ptrCast(&appkit.objc_msgSend));
        return msg_send_version(process_info, sel_at_least, .{ .major = 26, .minor = 0, .patch = 0 }) != 0;
    }
} else struct {
    pub fn init(window: *c.SDL_Window) MousePositionFix {
        _ = window;
        return .{};
    }

    pub fn correct(self: *MousePositionFix, window: *c.SDL_Window, event: *c.SDL_Event) void {
        _ = self;
        _ = window;
        _ = event;
    }
};

test "verified_sdl_version matches the linked SDL" {
    // Fails on every SDL upgrade on purpose: re-read the Cocoa sources named at
    // the top of this file, then delete the workaround or bump the constant.
    try std.testing.expectEqual(verified_sdl_version, c.SDL_GetVersion());
}

test "offset is SDL's cached window origin minus the real one" {
    // The stale state seen in practice: a 1080 pt display above a 1117 pt main
    // display, with SDL holding the position computed while the 1080 pt one was main.
    const offset = Offset.between(.{ .x = -94, .y = -1117 }, .{ .x = -94, .y = -1080 });
    try std.testing.expectEqual(@as(f32, 0), offset.x);
    try std.testing.expectEqual(@as(f32, -37), offset.y);

    // SDL reported global (-94 + 500, -1080 + 300) - (-94, -1117) = (500, 337)
    // for a pointer that is 300 pt below the window's real top edge.
    var motion: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    motion.type = c.SDL_EVENT_MOUSE_MOTION;
    motion.motion.x = 500;
    motion.motion.y = 337;
    applyOffset(&motion, offset);
    try std.testing.expectEqual(@as(f32, 500), motion.motion.x);
    try std.testing.expectEqual(@as(f32, 300), motion.motion.y);
}

test "applyOffset corrects button and wheel positions but not drops" {
    const offset: Offset = .{ .x = 3, .y = -37 };

    var button: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    button.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    button.button.x = 10;
    button.button.y = 100;
    applyOffset(&button, offset);
    try std.testing.expectEqual(@as(f32, 13), button.button.x);
    try std.testing.expectEqual(@as(f32, 63), button.button.y);

    var wheel: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    wheel.type = c.SDL_EVENT_MOUSE_WHEEL;
    wheel.wheel.mouse_x = 10;
    wheel.wheel.mouse_y = 100;
    wheel.wheel.y = 1;
    applyOffset(&wheel, offset);
    try std.testing.expectEqual(@as(f32, 13), wheel.wheel.mouse_x);
    try std.testing.expectEqual(@as(f32, 63), wheel.wheel.mouse_y);
    try std.testing.expectEqual(@as(f32, 1), wheel.wheel.y);

    var drop: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    drop.type = c.SDL_EVENT_DROP_POSITION;
    drop.drop.x = 10;
    drop.drop.y = 100;
    applyOffset(&drop, offset);
    try std.testing.expectEqual(@as(f32, 10), drop.drop.x);
    try std.testing.expectEqual(@as(f32, 100), drop.drop.y);
}

test "real content origin matches SDL's window position while SDL is in sync" {
    if (!is_macos) return error.SkipZigTest;
    // Keep the test process from showing up in the Dock or taking focus.
    _ = c.SDL_SetHint("SDL_MAC_BACKGROUND_APP", "1");
    if (!c.SDL_InitSubSystem(c.SDL_INIT_VIDEO)) return error.SkipZigTest;
    defer c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);

    const window = c.SDL_CreateWindow("mouse workaround test", 320, 200, c.SDL_WINDOW_HIDDEN) orelse
        return error.SkipZigTest;
    defer c.SDL_DestroyWindow(window);
    try std.testing.expect(c.SDL_SetWindowPosition(window, 120, 140));
    _ = c.SDL_SyncWindow(window);

    var fix = MousePositionFix.initForWindow(window);
    try std.testing.expect(fix.nswindow != null);
    const offset = fix.currentOffset(window) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Offset.zero, offset);
}
