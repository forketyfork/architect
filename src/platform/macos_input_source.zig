// zwanzig-disable: identifier-style
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

/// Hand-written bindings for the handful of Carbon/CoreFoundation/Objective-C
/// runtime symbols this file needs, verified against the real macOS SDK
/// headers (HIToolbox/TextInputSources.h, CoreFoundation's CFBase/CFString/
/// CFDictionary/CFNumber/CFPreferences.h, objc/objc.h, objc/message.h).
///
/// `@cImport`-ing Carbon/CoreFoundation.h pulls in ApplicationServices and
/// CoreServices, which under Zig 0.16's Aro-based translate-c fail to parse:
/// nested/umbrella framework headers aren't found (matches a reported
/// Accelerate/vImage regression), and ImageIO's use of Apple's Blocks syntax
/// (`(^Foo)(...)`) isn't understood by Aro's C parser at all. Hand-declaring
/// only the symbols actually used here avoids both problems; the symbols
/// themselves are decades-old, ABI-frozen APIs.
const c = if (is_macos) struct {
    pub const CFTypeID = c_ulong;
    pub const CFIndex = c_long;
    pub const Boolean = u8;
    pub const OSStatus = i32;

    // `const void*`: genuinely generic, so this stays optional-by-default;
    // any concrete opaque pointer below coerces into it implicitly.
    pub const CFTypeRef = ?*anyopaque;
    pub const CFPropertyListRef = CFTypeRef;

    const CFAllocator = opaque {};
    pub const CFAllocatorRef = *CFAllocator;
    pub extern const kCFAllocatorDefault: CFAllocatorRef;

    const CFString = opaque {};
    pub const CFStringRef = *CFString;
    pub const CFStringEncoding = u32;
    pub const kCFStringEncodingUTF8: CFStringEncoding = 0x0800_0100;
    pub extern fn CFStringCreateWithCString(alloc: CFAllocatorRef, c_str: [*:0]const u8, encoding: CFStringEncoding) callconv(.c) ?CFStringRef;

    const CFDictionary = opaque {};
    pub const CFDictionaryRef = *CFDictionary;
    pub extern fn CFDictionaryGetTypeID() callconv(.c) CFTypeID;
    pub extern fn CFDictionaryGetValue(the_dict: CFDictionaryRef, key: CFTypeRef) callconv(.c) CFTypeRef;

    pub const CFNumberType = CFIndex;
    pub const kCFNumberSInt64Type: CFNumberType = 4;
    pub extern fn CFNumberGetTypeID() callconv(.c) CFTypeID;
    pub extern fn CFNumberGetValue(number: CFTypeRef, the_type: CFNumberType, value_ptr: ?*anyopaque) callconv(.c) Boolean;

    pub extern fn CFBooleanGetTypeID() callconv(.c) CFTypeID;
    pub extern fn CFBooleanGetValue(boolean: CFTypeRef) callconv(.c) Boolean;

    pub extern fn CFGetTypeID(cf: CFTypeRef) callconv(.c) CFTypeID;
    pub extern fn CFRetain(cf: CFTypeRef) callconv(.c) CFTypeRef;
    pub extern fn CFRelease(cf: CFTypeRef) callconv(.c) void;

    pub extern fn CFPreferencesCopyAppValue(key: CFStringRef, application_id: CFStringRef) callconv(.c) CFPropertyListRef;

    // Carbon / HIToolbox text input source services (TextInputSources.h).
    const TISInputSource = opaque {};
    pub const TISInputSourceRef = *TISInputSource;
    pub extern const kTISPropertyInputSourceID: CFStringRef;
    pub extern fn TISCopyCurrentKeyboardInputSource() callconv(.c) ?TISInputSourceRef;
    pub extern fn TISGetInputSourceProperty(input_source: TISInputSourceRef, property_key: CFStringRef) callconv(.c) ?*anyopaque;
    pub extern fn TISSelectInputSource(input_source: TISInputSourceRef) callconv(.c) OSStatus;

    // Objective-C runtime (objc/objc.h, objc/message.h). `objc_msgSend`'s
    // declared signature is never called directly: existing call sites below
    // take its address and reinterpret it as the specific non-variadic
    // signature each call actually needs, the standard pattern for calling
    // objc_msgSend from non-Objective-C code.
    const objc_class = opaque {};
    pub const Class = *objc_class;
    const objc_selector = opaque {};
    pub const SEL = *objc_selector;
    pub extern fn objc_getClass(name: [*:0]const u8) callconv(.c) ?Class;
    pub extern fn sel_registerName(name: [*:0]const u8) callconv(.c) ?SEL;
    pub extern fn objc_msgSend() callconv(.c) void;
} else struct {};

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
