const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("shell.zig");

const log = std.log.scoped(.vt_stream);

const ReadonlyHandler = @typeInfo(@TypeOf(ghostty_vt.Terminal.vtHandler)).@"fn".return_type.?;

/// Stream handler that keeps terminal state in sync (via the built-in
/// readonly handler) but also answers basic device-status queries so
/// interactive TUI apps (e.g. codex CLI) don't stall waiting for a
/// cursor position response.
pub const Handler = struct {
    terminal: *ghostty_vt.Terminal,
    shell: *shell_mod.Shell,
    readonly: ReadonlyHandler,

    pub fn init(terminal: *ghostty_vt.Terminal, shell: *shell_mod.Shell) Handler {
        return .{
            .terminal = terminal,
            .shell = shell,
            .readonly = terminal.vtHandler(),
        };
    }

    pub fn deinit(self: *Handler) void {
        self.readonly.deinit();
    }

    pub fn vt(
        self: *Handler,
        comptime action: ghostty_vt.StreamAction.Tag,
        value: ghostty_vt.StreamAction.Value(action),
    ) !void {
        switch (action) {
            .device_attributes => try self.handleDeviceAttributes(value),
            .device_status => try self.handleDeviceStatus(value.request),
            .kitty_keyboard_query => try self.handleKittyKeyboardQuery(),
            .kitty_keyboard_push => {
                log.debug("kitty_keyboard_push: flags={d}", .{value.flags.int()});
                try self.readonly.vt(action, value);
                log.debug("kitty_keyboard: current={d}", .{self.terminal.screens.active.kitty_keyboard.current().int()});
            },
            .kitty_keyboard_pop => {
                log.debug("kitty_keyboard_pop: n={d}", .{value});
                try self.readonly.vt(action, value);
                log.debug("kitty_keyboard: current={d}", .{self.terminal.screens.active.kitty_keyboard.current().int()});
            },
            .kitty_keyboard_set => {
                log.debug("kitty_keyboard_set: flags={d}", .{value.flags.int()});
                try self.readonly.vt(action, value);
                log.debug("kitty_keyboard: current={d}", .{self.terminal.screens.active.kitty_keyboard.current().int()});
            },
            .kitty_keyboard_set_or => {
                log.debug("kitty_keyboard_set_or: flags={d}", .{value.flags.int()});
                try self.readonly.vt(action, value);
                log.debug("kitty_keyboard: current={d}", .{self.terminal.screens.active.kitty_keyboard.current().int()});
            },
            .kitty_keyboard_set_not => {
                log.debug("kitty_keyboard_set_not: flags={d}", .{value.flags.int()});
                try self.readonly.vt(action, value);
                log.debug("kitty_keyboard: current={d}", .{self.terminal.screens.active.kitty_keyboard.current().int()});
            },
            else => try self.readonly.vt(action, value),
        }
    }

    fn handleDeviceAttributes(self: *Handler, req: ghostty_vt.DeviceAttributeReq) !void {
        switch (req) {
            .primary => {
                // Identify as VT220 with color support
                // 62 = VT220, 22 = Color text
                log.debug("device_attributes: primary -> VT220 with color", .{});
                _ = try self.shell.write("\x1b[?62;22c");
            },
            .secondary => {
                // Secondary DA: terminal type, firmware version, ROM cartridge
                log.debug("device_attributes: secondary", .{});
                _ = try self.shell.write("\x1b[>1;10;0c");
            },
            else => {
                log.debug("device_attributes: unhandled req={}", .{req});
            },
        }
    }

    fn handleDeviceStatus(
        self: *Handler,
        req: ghostty_vt.device_status.Request,
    ) !void {
        switch (req) {
            .operating_status => {
                log.debug("device_status: operating_status -> OK", .{});
                _ = try self.shell.write("\x1b[0n");
            },
            .cursor_position => {
                const pos: struct { x: usize, y: usize } = if (self.terminal.modes.get(.origin)) .{
                    .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
                    .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
                } else .{
                    .x = self.terminal.screens.active.cursor.x,
                    .y = self.terminal.screens.active.cursor.y,
                };

                var buf: [32]u8 = undefined;
                const resp = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ pos.y + 1, pos.x + 1 });
                log.debug("device_status: cursor_position -> {d};{d}", .{ pos.y + 1, pos.x + 1 });
                _ = try self.shell.write(resp);
            },
            else => {},
        }
    }

    fn handleKittyKeyboardQuery(self: *Handler) !void {
        const flags = self.terminal.screens.active.kitty_keyboard.current();
        log.debug("kitty_keyboard_query: responding with flags={d}", .{flags.int()});
        var buf: [16]u8 = undefined;
        const resp = try formatKittyQueryResponse(&buf, flags.int());
        _ = try self.shell.write(resp);
    }
};

/// Format kitty keyboard query response. Exposed for testing.
fn formatKittyQueryResponse(buf: []u8, flags: u5) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[?{d}u", .{flags});
}

test "formatKittyQueryResponse - disabled (flags=0)" {
    var buf: [16]u8 = undefined;
    const resp = try formatKittyQueryResponse(&buf, 0);
    try std.testing.expectEqualSlices(u8, "\x1b[?0u", resp);
}

test "formatKittyQueryResponse - disambiguate only (flags=1)" {
    var buf: [16]u8 = undefined;
    const resp = try formatKittyQueryResponse(&buf, 1);
    try std.testing.expectEqualSlices(u8, "\x1b[?1u", resp);
}

test "formatKittyQueryResponse - all flags (flags=31)" {
    var buf: [16]u8 = undefined;
    const resp = try formatKittyQueryResponse(&buf, 31);
    try std.testing.expectEqualSlices(u8, "\x1b[?31u", resp);
}

pub const StreamType = ghostty_vt.Stream(Handler);

pub fn initStream(
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    shell: *shell_mod.Shell,
) StreamType {
    return StreamType.initAlloc(alloc, Handler.init(terminal, shell));
}
