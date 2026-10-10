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

const std = @import("std");
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
    const MsgSendUInt = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) usize;
    const MsgSendRepType = *const fn (?*anyopaque, ?*anyopaque, usize, ?*anyopaque) callconv(.c) ?*anyopaque;

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

    fn cstrArg(s: [*:0]const u8) ?*anyopaque {
        return @ptrCast(@constCast(s));
    }

    // data = [pasteboard dataForType:[NSString stringWithUTF8String:type_name]]
    fn pasteboardData(
        pasteboard: ?*anyopaque,
        ns_string: ?*anyopaque,
        sel_string_utf8: ?*anyopaque,
        sel_data_for_type: ?*anyopaque,
        type_name: [*:0]const u8,
    ) ?*anyopaque {
        const msg_send_id = @as(MsgSendIdArg, @ptrCast(&c.objc_msgSend));
        const type_str = msg_send_id(ns_string, sel_string_utf8, cstrArg(type_name)) orelse return null;
        return msg_send_id(pasteboard, sel_data_for_type, type_str);
    }

    fn readClipboardImagePng(allocator: std.mem.Allocator) ?[]u8 {
        const ns_pasteboard = c.objc_getClass("NSPasteboard") orelse return null;
        const ns_string = c.objc_getClass("NSString") orelse return null;
        const ns_bitmap = c.objc_getClass("NSBitmapImageRep") orelse return null;
        const sel_general = c.sel_registerName("generalPasteboard") orelse return null;
        const sel_string_utf8 = c.sel_registerName("stringWithUTF8String:") orelse return null;
        const sel_data_for_type = c.sel_registerName("dataForType:") orelse return null;
        const sel_imagerep_data = c.sel_registerName("imageRepWithData:") orelse return null;
        const sel_rep_using = c.sel_registerName("representationUsingType:properties:") orelse return null;
        const sel_bytes = c.sel_registerName("bytes") orelse return null;
        const sel_length = c.sel_registerName("length") orelse return null;

        const msg_send = @as(MsgSend, @ptrCast(&c.objc_msgSend));
        const msg_send_id = @as(MsgSendIdArg, @ptrCast(&c.objc_msgSend));
        const msg_send_uint = @as(MsgSendUInt, @ptrCast(&c.objc_msgSend));
        const msg_send_rep = @as(MsgSendRepType, @ptrCast(&c.objc_msgSend));

        const pasteboard = msg_send(ns_pasteboard, sel_general) orelse return null;

        // Prefer the ready-made PNG representation — screenshots, browser copies,
        // and Universal Clipboard transfers all provide public.png directly.
        var png_data = pasteboardData(pasteboard, ns_string, sel_string_utf8, sel_data_for_type, "public.png");

        // Fallback: convert the TIFF representation to PNG via NSBitmapImageRep.
        if (png_data == null) {
            const tiff = pasteboardData(pasteboard, ns_string, sel_string_utf8, sel_data_for_type, "public.tiff") orelse return null;
            const rep = msg_send_id(ns_bitmap, sel_imagerep_data, tiff) orelse return null;
            png_data = msg_send_rep(rep, sel_rep_using, 4, null); // 4 = NSBitmapImageFileTypePNG
        }
        const png = png_data orelse return null;

        const len = msg_send_uint(png, sel_length);
        if (len == 0) return null;
        const bytes_ptr = msg_send(png, sel_bytes) orelse return null;
        const src = @as([*]const u8, @ptrCast(bytes_ptr))[0..len];
        return allocator.dupe(u8, src) catch null;
    }
} else struct {
    fn hasClipboardImage() bool {
        return false;
    }

    fn readClipboardImagePng(_: std.mem.Allocator) ?[]u8 {
        return null;
    }
};

/// Returns true if the macOS general pasteboard currently holds image data
/// NSImage can read — PNG/TIFF/JPEG/HEIC/PDF, including Universal Clipboard /
/// iPhone screenshots (modern UTIs) and image file URLs, while rejecting
/// non-image file URLs. Always false on non-macOS targets.
pub fn hasClipboardImage() bool {
    return Impl.hasClipboardImage();
}

/// Reads the macOS general pasteboard's image as PNG bytes (caller owns the
/// returned slice). Returns null when there is no image, the bytes can't be
/// materialized, or on non-macOS targets. This pulls promised (lazily
/// transferred) Universal Clipboard data, so it may briefly block on the
/// cross-device fetch — unlike hasClipboardImage(), which is metadata-only.
pub fn readClipboardImagePng(allocator: std.mem.Allocator) ?[]u8 {
    return Impl.readClipboardImagePng(allocator);
}
