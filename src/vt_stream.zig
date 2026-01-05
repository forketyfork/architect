const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("shell.zig");

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
            .device_status => try self.handleDeviceStatus(value.request),
            else => try self.readonly.vt(action, value),
        }
    }

    fn handleDeviceStatus(
        self: *Handler,
        req: ghostty_vt.device_status.Request,
    ) !void {
        switch (req) {
            .operating_status => {
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
                _ = try self.shell.write(resp);
            },
            else => {},
        }
    }
};

pub const StreamType = ghostty_vt.Stream(Handler);

pub fn initStream(
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    shell: *shell_mod.Shell,
) StreamType {
    return StreamType.initAlloc(alloc, Handler.init(terminal, shell));
}
