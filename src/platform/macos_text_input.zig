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
    pending_text: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    nswindow: ?*anyopaque,

    // Global pointer for the callback to access
    var global_instance: ?*AccessibleTextInput = null;

    pub fn init(allocator: std.mem.Allocator, nswindow: ?*anyopaque) AccessibleTextInput {
        return .{
            .pending_text = .empty,
            .allocator = allocator,
            .nswindow = nswindow,
        };
    }

    /// Must be called after init, once the struct is at its final memory location.
    /// This registers the global instance pointer for the callback.
    pub fn start(self: *AccessibleTextInput) void {
        global_instance = self;
        c.macos_text_input_init(self.nswindow, &trampolineCallback, null);
    }

    pub fn deinit(self: *AccessibleTextInput) void {
        c.macos_text_input_deinit();
        self.pending_text.deinit(self.allocator);
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
        if (self.pending_text.items.len == 0) return null;
        const text = self.pending_text.toOwnedSlice(self.allocator) catch {
            log.err("Failed to convert pending text to owned slice", .{});
            self.pending_text.clearRetainingCapacity();
            return null;
        };
        return text;
    }

    fn trampolineCallback(text_ptr: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
        _ = userdata;
        const instance = global_instance orelse return;
        if (text_ptr == null) return;

        const text = std.mem.sliceTo(text_ptr, 0);
        if (text.len == 0) return;

        // Append to pending text buffer (preserves earlier chunks)
        instance.pending_text.appendSlice(instance.allocator, text) catch {
            log.err("Failed to append to text buffer", .{});
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
