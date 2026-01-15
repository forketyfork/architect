const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

const c = if (is_macos) @cImport({
    @cInclude("Carbon/Carbon.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
}) else struct {};

pub const InputSourceTracker = if (is_macos) struct {
    source: ?c.TISInputSourceRef = null,
    id: ?c.CFStringRef = null,

    pub const Error = error{
        GetInputSourceFailed,
        GetInputSourceIdFailed,
        SetInputSourceFailed,
    };

    pub fn init() InputSourceTracker {
        return .{};
    }

    pub fn deinit(self: *InputSourceTracker) void {
        self.releaseSource();
        self.releaseId();
    }

    pub fn capture(self: *InputSourceTracker) Error!void {
        const source = c.TISCopyCurrentKeyboardInputSource() orelse
            return Error.GetInputSourceFailed;
        errdefer c.CFRelease(source);

        const id_raw = c.TISGetInputSourceProperty(
            source,
            c.kTISPropertyInputSourceID,
        ) orelse return Error.GetInputSourceIdFailed;

        const id_retained_any = c.CFRetain(id_raw) orelse
            return Error.GetInputSourceIdFailed;
        const id_retained = @as(c.CFStringRef, @ptrCast(id_retained_any));

        self.releaseSource();
        self.releaseId();
        self.source = source;
        self.id = id_retained;
    }

    pub fn restore(self: *InputSourceTracker) Error!void {
        if (!perContextInputEnabled()) return;

        if (try self.restoreWithAppKit()) return;

        if (self.source) |source| {
            const status = c.TISSelectInputSource(source);
            if (status != 0) return Error.SetInputSourceFailed;
        }
    }

    fn restoreWithAppKit(self: *InputSourceTracker) Error!bool {
        const id = self.id orelse return false;

        const class = c.objc_getClass("NSTextInputContext") orelse return false;
        const sel_current = c.sel_registerName("currentInputContext") orelse return false;
        const msg_send = @as(ObjcMsgSend, @ptrCast(&c.objc_msgSend));
        const context = msg_send(class, sel_current) orelse return false;

        const sel_set = c.sel_registerName("setSelectedKeyboardInputSource:") orelse return false;
        const sel_responds = c.sel_registerName("respondsToSelector:") orelse return false;
        const msg_send_bool = @as(ObjcMsgSendBool, @ptrCast(&c.objc_msgSend));
        if (msg_send_bool(context, sel_responds, sel_set) == 0) return false;

        const msg_send_set = @as(ObjcMsgSendSet, @ptrCast(&c.objc_msgSend));
        const id_ptr: ?*anyopaque = @ptrCast(@constCast(id));
        msg_send_set(context, sel_set, id_ptr);
        return true;
    }

    fn releaseSource(self: *InputSourceTracker) void {
        if (self.source) |source| {
            c.CFRelease(source);
            self.source = null;
        }
    }

    fn releaseId(self: *InputSourceTracker) void {
        if (self.id) |id| {
            c.CFRelease(id);
            self.id = null;
        }
    }

    fn perContextInputEnabled() bool {
        const domain = c.CFStringCreateWithCString(
            c.kCFAllocatorDefault,
            "com.apple.HIToolbox",
            c.kCFStringEncodingUTF8,
        ) orelse return false;
        defer c.CFRelease(domain);

        const key = c.CFStringCreateWithCString(
            c.kCFAllocatorDefault,
            "AppleGlobalTextInputProperties",
            c.kCFStringEncodingUTF8,
        ) orelse return false;
        defer c.CFRelease(key);

        const props_raw = c.CFPreferencesCopyAppValue(key, domain) orelse return false;
        defer c.CFRelease(props_raw);

        if (c.CFGetTypeID(props_raw) != c.CFDictionaryGetTypeID()) return false;
        const props: c.CFDictionaryRef = @ptrCast(props_raw);

        const subkey = c.CFStringCreateWithCString(
            c.kCFAllocatorDefault,
            "TextInputGlobalPropertyPerContextInput",
            c.kCFStringEncodingUTF8,
        ) orelse return false;
        defer c.CFRelease(subkey);

        const value_raw = c.CFDictionaryGetValue(props, subkey) orelse return false;
        const value: c.CFTypeRef = @ptrCast(value_raw);

        const type_id = c.CFGetTypeID(value);
        if (type_id == c.CFNumberGetTypeID()) {
            var number: i64 = 0;
            if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &number) == 1) {
                return number != 0;
            }
            return false;
        }

        if (type_id == c.CFBooleanGetTypeID()) {
            return c.CFBooleanGetValue(@ptrCast(value)) == 1;
        }

        return false;
    }

    const ObjcMsgSend = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const ObjcMsgSendSet = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
    const ObjcMsgSendBool = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8;
} else struct {
    pub const Error = error{};

    pub fn init() InputSourceTracker {
        return .{};
    }

    pub fn deinit(self: *InputSourceTracker) void {
        _ = self;
    }

    pub fn capture(self: *InputSourceTracker) Error!void {
        _ = self;
    }

    pub fn restore(self: *InputSourceTracker) Error!void {
        _ = self;
    }
};
