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
    const MsgSendBoolArg = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u8;

    fn hasClipboardImage() bool {
        const ns_pasteboard = c.objc_getClass("NSPasteboard") orelse return false;
        const ns_image = c.objc_getClass("NSImage") orelse return false;
        const sel_general = c.sel_registerName("generalPasteboard") orelse return false;
        const sel_can = c.sel_registerName("canInitWithPasteboard:") orelse return false;

        // [NSPasteboard generalPasteboard] -> shared pasteboard (not owned by us).
        const msg_send = @as(MsgSend, @ptrCast(&c.objc_msgSend));
        const pasteboard = msg_send(ns_pasteboard, sel_general) orelse return false;

        // +[NSImage canInitWithPasteboard:pasteboard] -> BOOL.
        const msg_send_bool = @as(MsgSendBoolArg, @ptrCast(&c.objc_msgSend));
        return msg_send_bool(ns_image, sel_can, pasteboard) != 0;
    }
} else struct {
    fn hasClipboardImage() bool {
        return false;
    }
};

/// Returns true if the macOS general pasteboard currently holds image data
/// (PNG/TIFF/PDF) that NSImage could read. Always false on non-macOS targets.
pub fn hasClipboardImage() bool {
    return Impl.hasClipboardImage();
}
