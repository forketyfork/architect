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
//! The fix here compares SDL's cached window position with the real one, read
//! from the NSWindow the same way `windowDidMove:` does, and when they differ
//! posts `NSWindowDidMoveNotification` so SDL's own `windowDidMove:` recomputes
//! the position with the current main display height. Repairing the cache,
//! rather than shifting event coordinates afterwards, keeps every SDL path
//! consistent: positions SDL already takes from window-local coordinates, and
//! the focus and clamping checks SDL runs before it queues an event.
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

/// How far SDL's cached window origin is from the real one, in window points.
pub const Offset = struct {
    x: f32,
    y: f32,

    pub const zero: Offset = .{ .x = 0, .y = 0 };

    pub fn between(sdl_origin: Point, real_origin: Point) Offset {
        return .{ .x = sdl_origin.x - real_origin.x, .y = sdl_origin.y - real_origin.y };
    }

    pub fn isZero(self: Offset) bool {
        return self.x == 0 and self.y == 0;
    }
};

pub const Point = struct { x: f32, y: f32 };

/// Events after which SDL's cached window position may have gone stale:
/// display reconfigurations and the window moves they cause.
pub fn mayStaleWindowPosition(event_type: u32) bool {
    return (event_type >= c.SDL_EVENT_DISPLAY_FIRST and event_type <= c.SDL_EVENT_DISPLAY_LAST) or
        event_type == c.SDL_EVENT_WINDOW_MOVED or
        event_type == c.SDL_EVENT_WINDOW_DISPLAY_CHANGED;
}

/// Hand-written AppKit/CoreGraphics bindings, for the same reasons given in
/// `macos_input_source.zig`.
const appkit = if (is_macos) struct {
    pub const NSPoint = extern struct { x: f64, y: f64 };
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

    pub extern const NSWindowDidMoveNotification: ?*anyopaque;

    pub extern fn CGMainDisplayID() callconv(.c) u32;
    pub extern fn CGDisplayPixelsHigh(display: u32) callconv(.c) usize;

    pub const MsgSendId = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    pub const MsgSendPost = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
    pub const MsgSendRect = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect;
    pub const MsgSendRectRect = *const fn (?*anyopaque, ?*anyopaque, NSRect) callconv(.c) NSRect;
    pub const MsgSendVersionBool = *const fn (?*anyopaque, ?*anyopaque, NSOperatingSystemVersion) callconv(.c) u8;

    pub fn sel(name: [*:0]const u8) ?*anyopaque {
        return sel_registerName(name);
    }

    pub fn msgSendId(receiver: ?*anyopaque, selector: ?*anyopaque) ?*anyopaque {
        return @as(MsgSendId, @ptrCast(&objc_msgSend))(receiver, selector);
    }
} else struct {};

pub const WindowPositionRepair = if (is_macos) struct {
    nswindow: ?*anyopaque = null,
    sel_frame: ?*anyopaque = null,
    sel_content_rect: ?*anyopaque = null,
    sel_post: ?*anyopaque = null,
    notification_center: ?*anyopaque = null,

    /// Inactive below macOS 26, where SDL takes mouse positions from the
    /// event's window-local location and the cached position does not matter.
    pub fn init(window: *c.SDL_Window) WindowPositionRepair {
        if (!sdlUsesCachedWindowPosition()) return .{};
        return initForWindow(window);
    }

    fn initForWindow(window: *c.SDL_Window) WindowPositionRepair {
        const props = c.SDL_GetWindowProperties(window);
        const nswindow = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse {
            log.warn("no NSWindow for the SDL window: {s}; stale window positions stay unrepaired", .{c.SDL_GetError()});
            return .{};
        };
        const center_class = appkit.objc_getClass("NSNotificationCenter");
        const sel_default_center = appkit.sel("defaultCenter");
        const sel_frame = appkit.sel("frame");
        const sel_content_rect = appkit.sel("contentRectForFrameRect:");
        const sel_post = appkit.sel("postNotificationName:object:");
        if (center_class == null or sel_default_center == null or sel_frame == null or sel_content_rect == null or sel_post == null) {
            log.warn("failed to look up AppKit classes or selectors; stale window positions stay unrepaired", .{});
            return .{};
        }
        const center = appkit.msgSendId(center_class, sel_default_center) orelse {
            log.warn("no default NSNotificationCenter; stale window positions stay unrepaired", .{});
            return .{};
        };
        return .{
            .nswindow = nswindow,
            .sel_frame = sel_frame,
            .sel_content_rect = sel_content_rect,
            .sel_post = sel_post,
            .notification_center = center,
        };
    }

    /// Re-syncs SDL's cached window position when it differs from the real one.
    /// Call it before SDL pumps new input, so the events it generates afterwards
    /// start from a correct origin.
    pub fn check(self: *const WindowPositionRepair, window: *c.SDL_Window) void {
        if (self.nswindow == null) return;
        const stale = self.currentOffset(window) orelse return;
        if (stale.isZero()) return;

        // SDL listens for this notification as the window's delegate (or as an
        // explicit observer) and recomputes window->x/y in `windowDidMove:`.
        @as(appkit.MsgSendPost, @ptrCast(&appkit.objc_msgSend))(self.notification_center, self.sel_post, appkit.NSWindowDidMoveNotification, self.nswindow);

        const remaining = self.currentOffset(window) orelse return;
        if (remaining.isZero()) {
            log.info("SDL window position was off by ({d}, {d}) points; re-synced it", .{ stale.x, stale.y });
        } else {
            // Expected while a fullscreen transition runs: SDL ignores moves
            // until the transition ends and then recomputes the position itself.
            log.debug("SDL window position is off by ({d}, {d}) points and did not re-sync", .{ remaining.x, remaining.y });
        }
    }

    fn currentOffset(self: *const WindowPositionRepair, window: *c.SDL_Window) ?Offset {
        var sdl_x: c_int = 0;
        var sdl_y: c_int = 0;
        if (!c.SDL_GetWindowPosition(window, &sdl_x, &sdl_y)) {
            log.warn("SDL_GetWindowPosition failed: {s}", .{c.SDL_GetError()});
            return null;
        }
        return Offset.between(
            .{ .x = @floatFromInt(sdl_x), .y = @floatFromInt(sdl_y) },
            self.realContentOrigin(),
        );
    }

    /// The content area's top-left corner in SDL's global coordinates,
    /// computed like `windowDidMove:` but with the current main display height.
    fn realContentOrigin(self: *const WindowPositionRepair) Point {
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
        const sel_process_info = appkit.sel("processInfo") orelse return false;
        const sel_at_least = appkit.sel("isOperatingSystemAtLeastVersion:") orelse return false;
        const process_info = appkit.msgSendId(class, sel_process_info) orelse return false;
        const msg_send_version = @as(appkit.MsgSendVersionBool, @ptrCast(&appkit.objc_msgSend));
        return msg_send_version(process_info, sel_at_least, .{ .major = 26, .minor = 0, .patch = 0 }) != 0;
    }
} else struct {
    pub fn init(window: *c.SDL_Window) WindowPositionRepair {
        _ = window;
        return .{};
    }

    pub fn check(self: *const WindowPositionRepair, window: *c.SDL_Window) void {
        _ = self;
        _ = window;
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
    try std.testing.expect(!offset.isZero());
}

test "display reconfigurations and window moves trigger a position check" {
    try std.testing.expect(mayStaleWindowPosition(c.SDL_EVENT_DISPLAY_ADDED));
    try std.testing.expect(mayStaleWindowPosition(c.SDL_EVENT_DISPLAY_REMOVED));
    try std.testing.expect(mayStaleWindowPosition(c.SDL_EVENT_DISPLAY_MOVED));
    try std.testing.expect(mayStaleWindowPosition(c.SDL_EVENT_WINDOW_MOVED));
    try std.testing.expect(mayStaleWindowPosition(c.SDL_EVENT_WINDOW_DISPLAY_CHANGED));
    try std.testing.expect(!mayStaleWindowPosition(c.SDL_EVENT_MOUSE_MOTION));
    try std.testing.expect(!mayStaleWindowPosition(c.SDL_EVENT_WINDOW_RESIZED));
}

/// A hidden SDL window for tests, with SDL video initialized in the background
/// so the test process neither shows up in the Dock nor takes focus.
const TestWindow = if (is_macos) struct {
    window: *c.SDL_Window,

    fn create() !TestWindow {
        _ = c.SDL_SetHint("SDL_MAC_BACKGROUND_APP", "1");
        if (!c.SDL_InitSubSystem(c.SDL_INIT_VIDEO)) return error.SkipZigTest;
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
        const window = c.SDL_CreateWindow("mouse workaround test", 320, 200, c.SDL_WINDOW_HIDDEN) orelse
            return error.SkipZigTest;
        try std.testing.expect(c.SDL_SetWindowPosition(window, 120, 140));
        _ = c.SDL_SyncWindow(window);
        return .{ .window = window };
    }

    fn destroy(self: TestWindow) void {
        c.SDL_DestroyWindow(self.window);
        c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    }

    /// Moves the NSWindow while SDL's delegate is detached, so SDL never sees
    /// the move: the same stale cache a mis-converted move notification leaves.
    fn moveBehindSdlsBack(self: TestWindow, repair: *const WindowPositionRepair, dx: f64, dy: f64) !void {
        const sel_delegate = appkit.sel("delegate");
        const sel_set_delegate = appkit.sel("setDelegate:");
        const sel_set_frame_origin = appkit.sel("setFrameOrigin:");
        const delegate = appkit.msgSendId(repair.nswindow, sel_delegate) orelse return error.TestUnexpectedResult;

        const MsgSendSetId = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
        const MsgSendSetPoint = *const fn (?*anyopaque, ?*anyopaque, appkit.NSPoint) callconv(.c) void;
        const set_delegate = @as(MsgSendSetId, @ptrCast(&appkit.objc_msgSend));
        const set_origin = @as(MsgSendSetPoint, @ptrCast(&appkit.objc_msgSend));
        const frame = @as(appkit.MsgSendRect, @ptrCast(appkit.msg_send_rect_entry))(repair.nswindow, repair.sel_frame);

        set_delegate(repair.nswindow, sel_set_delegate, null);
        set_origin(repair.nswindow, sel_set_frame_origin, .{ .x = frame.x + dx, .y = frame.y + dy });
        set_delegate(repair.nswindow, sel_set_delegate, delegate);
        _ = self;
    }
} else struct {};

test "real content origin matches SDL's window position while SDL is in sync" {
    if (!is_macos) return error.SkipZigTest;
    const test_window = try TestWindow.create();
    defer test_window.destroy();

    const repair = WindowPositionRepair.initForWindow(test_window.window);
    try std.testing.expect(repair.nswindow != null);
    const offset = repair.currentOffset(test_window.window) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Offset.zero, offset);
}

test "check re-syncs a window position SDL missed" {
    if (!is_macos) return error.SkipZigTest;
    const test_window = try TestWindow.create();
    defer test_window.destroy();

    const repair = WindowPositionRepair.initForWindow(test_window.window);
    try std.testing.expect(repair.nswindow != null);

    // Cocoa's y axis points up, so moving the frame up by 37 pt leaves SDL's
    // cached top edge 37 pt below the real one.
    try test_window.moveBehindSdlsBack(&repair, 0, 37);
    const stale = repair.currentOffset(test_window.window) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Offset{ .x = 0, .y = 37 }, stale);

    repair.check(test_window.window);
    const after = repair.currentOffset(test_window.window) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Offset.zero, after);
}
