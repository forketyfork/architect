const std = @import("std");
const builtin = @import("builtin");

const is_macos = builtin.os.tag == .macos;

const log = std.log.scoped(.macos_text_input);

// External C functions from macos_text_input.m
const c = if (is_macos) struct {
    pub const TextInputCallback = *const fn ([*c]const u8, ?*anyopaque) callconv(.c) void;

    pub extern fn macos_text_input_init(nswindow: ?*anyopaque, callback: TextInputCallback, userdata: ?*anyopaque) void;
    pub extern fn macos_text_input_deinit() void;
    pub extern fn macos_text_input_focus() void;
    pub extern fn macos_text_input_unfocus() void;
    pub extern fn macos_text_input_is_focused() c_int;
} else struct {};

// Maximum size for a single text input event (4KB should be plenty for any paste)
const MAX_TEXT_SIZE = 4096;

pub const AccessibleTextInput = if (is_macos) struct {
    pending_text: ?[]u8 = null,
    allocator: std.mem.Allocator,
    nswindow: ?*anyopaque,

    // Global pointer for the callback to access
    var global_instance: ?*AccessibleTextInput = null;

    pub fn init(allocator: std.mem.Allocator, nswindow: ?*anyopaque) AccessibleTextInput {
        const self = AccessibleTextInput{
            .allocator = allocator,
            .nswindow = nswindow,
        };
        return self;
    }

    /// Must be called after init, once the struct is at its final memory location.
    /// This registers the global instance pointer for the callback.
    pub fn start(self: *AccessibleTextInput) void {
        global_instance = self;
        c.macos_text_input_init(self.nswindow, &trampolineCallback, null);
    }

    pub fn deinit(self: *AccessibleTextInput) void {
        c.macos_text_input_deinit();
        if (self.pending_text) |text| {
            self.allocator.free(text);
            self.pending_text = null;
        }
        global_instance = null;
    }

    pub fn focus(self: *AccessibleTextInput) void {
        _ = self;
        c.macos_text_input_focus();
    }

    pub fn unfocus(self: *AccessibleTextInput) void {
        _ = self;
        c.macos_text_input_unfocus();
    }

    pub fn isFocused(self: *AccessibleTextInput) bool {
        _ = self;
        return c.macos_text_input_is_focused() != 0;
    }

    /// Poll for pending text input. Returns the text and clears the pending state.
    /// Caller must free the returned slice.
    pub fn pollText(self: *AccessibleTextInput) ?[]u8 {
        const text = self.pending_text;
        self.pending_text = null;
        return text;
    }

    fn trampolineCallback(text_ptr: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
        _ = userdata;
        const instance = global_instance orelse return;
        if (text_ptr == null) return;

        const text = std.mem.sliceTo(text_ptr, 0);
        if (text.len == 0) return;

        // Free any existing pending text
        if (instance.pending_text) |old| {
            instance.allocator.free(old);
        }

        // Store the new text
        instance.pending_text = instance.allocator.dupe(u8, text) catch {
            log.err("Failed to allocate text buffer", .{});
            return;
        };
    }
} else struct {
    pub fn init(allocator: std.mem.Allocator, nswindow: ?*anyopaque) AccessibleTextInput {
        _ = allocator;
        _ = nswindow;
        return .{};
    }

    pub fn start(self: *AccessibleTextInput) void {
        _ = self;
    }

    pub fn deinit(self: *AccessibleTextInput) void {
        _ = self;
    }

    pub fn focus(self: *AccessibleTextInput) void {
        _ = self;
    }

    pub fn unfocus(self: *AccessibleTextInput) void {
        _ = self;
    }

    pub fn isFocused(self: *AccessibleTextInput) bool {
        _ = self;
        return false;
    }

    pub fn pollText(self: *AccessibleTextInput) ?[]u8 {
        _ = self;
        return null;
    }
};
