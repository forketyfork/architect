// macOS clipboard image detection.
//
// Used by the Cmd+V image-passthrough feature: when the general pasteboard
// holds image data (a screenshot, a copied PNG/TIFF, etc.), Architect forwards
// Ctrl+V to the focused terminal so a CLI like Claude Code performs its own
// inline image paste, instead of pasting clipboard text.
//
// Implemented with the same objc_msgSend interop pattern as
// platform/macos_input_source.zig. The AppKit classes (NSPasteboard, NSImage)
// are looked up by name at runtime via objc_getClass, so no AppKit headers are
// needed here — AppKit is already linked by build.zig.

const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

const Impl = if (is_macos) struct {
    const c = @cImport({
        @cInclude("objc/runtime.h");
        @cInclude("objc/message.h");
    });

    // objc_msgSend has no single C prototype; cast it per call signature.
    const MsgSend = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const MsgSendIdArg = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const MsgSendBool2Arg = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8;

    fn hasClipboardImage() bool {
        const ns_pasteboard = c.objc_getClass("NSPasteboard") orelse return false;
        const ns_image = c.objc_getClass("NSImage") orelse return false;
        const ns_array = c.objc_getClass("NSArray") orelse return false;
        const sel_general = c.sel_registerName("generalPasteboard") orelse return false;
        const sel_array_with = c.sel_registerName("arrayWithObject:") orelse return false;
        const sel_can_read = c.sel_registerName("canReadObjectForClasses:options:") orelse return false;

        const msg_send = @as(MsgSend, @ptrCast(&c.objc_msgSend));
        const msg_send_id = @as(MsgSendIdArg, @ptrCast(&c.objc_msgSend));
        const msg_send_bool2 = @as(MsgSendBool2Arg, @ptrCast(&c.objc_msgSend));

        // [NSPasteboard generalPasteboard] -> shared pasteboard (not owned by us).
        const pasteboard = msg_send(ns_pasteboard, sel_general) orelse return false;

        // classes = [NSArray arrayWithObject:[NSImage class]]. A Class doubles as
        // the `id` element; canReadObjectForClasses: wants NSPasteboardReading
        // classes, and NSImage conforms.
        const classes = msg_send_id(ns_array, sel_array_with, ns_image) orelse return false;

        // [pasteboard canReadObjectForClasses:classes options:nil] -> BOOL.
        // Unlike +[NSImage canInitWithPasteboard:] (which only matches the legacy
        // NeXT pasteboard type set), this is UTI-aware: it matches any
        // public.image-conforming type, including Universal Clipboard / iPhone
        // screenshots that declare modern UTIs, and image file URLs, while
        // rejecting non-image file URLs. It inspects declared types only, so it
        // does not pull promised (lazily transferred) Universal Clipboard bytes.
        return msg_send_bool2(pasteboard, sel_can_read, classes, null) != 0;
    }
} else struct {
    fn hasClipboardImage() bool {
        return false;
    }
};

/// Returns true if the macOS general pasteboard currently holds image data
/// NSImage can read — PNG/TIFF/JPEG/HEIC/PDF, including Universal Clipboard /
/// iPhone screenshots (modern UTIs) and image file URLs, while rejecting
/// non-image file URLs. Always false on non-macOS targets.
pub fn hasClipboardImage() bool {
    return Impl.hasClipboardImage();
}
