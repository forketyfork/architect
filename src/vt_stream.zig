const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("shell.zig");

const log = std.log.scoped(.vt_stream);

const ReadonlyHandler = @typeInfo(@TypeOf(ghostty_vt.Terminal.vtHandler)).@"fn".return_type.?;
const color_operation_value = ghostty_vt.StreamAction.Value(.color_operation);

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
            .color_operation => try self.handleColorOperation(value),
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

    fn handleColorOperation(self: *Handler, op: color_operation_value) !void {
        var it = op.requests.constIterator(0);
        while (it.next()) |request| {
            switch (request.*) {
                .set => |set| self.applyColorSet(set.target, set.color),
                .reset => |target| self.applyColorReset(target),
                .reset_palette => {
                    if (self.terminal.colors.palette.mask.count() > 0) {
                        self.terminal.flags.dirty.palette = true;
                    }
                    self.terminal.colors.palette.resetAll();
                },
                .query => |target| {
                    const color = self.colorForQuery(target) orelse continue;
                    var buf: [64]u8 = undefined;
                    const resp = try formatOscColorQueryResponse(&buf, target, color, op.terminator);
                    _ = try self.shell.write(resp);
                },
                .reset_special => {},
            }
        }
    }

    fn applyColorSet(
        self: *Handler,
        target: ghostty_vt.osc.color.Target,
        color: ghostty_vt.color.RGB,
    ) void {
        switch (target) {
            .palette => |index| {
                self.terminal.flags.dirty.palette = true;
                self.terminal.colors.palette.set(index, color);
            },
            .dynamic => |dynamic| switch (dynamic) {
                .foreground => self.terminal.colors.foreground.set(color),
                .background => self.terminal.colors.background.set(color),
                .cursor => self.terminal.colors.cursor.set(color),
                else => {},
            },
            .special => {},
        }
    }

    fn applyColorReset(self: *Handler, target: ghostty_vt.osc.color.Target) void {
        switch (target) {
            .palette => |index| {
                self.terminal.flags.dirty.palette = true;
                self.terminal.colors.palette.reset(index);
            },
            .dynamic => |dynamic| switch (dynamic) {
                .foreground => self.terminal.colors.foreground.reset(),
                .background => self.terminal.colors.background.reset(),
                .cursor => self.terminal.colors.cursor.reset(),
                else => {},
            },
            .special => {},
        }
    }

    fn colorForQuery(
        self: *Handler,
        target: ghostty_vt.osc.color.Target,
    ) ?ghostty_vt.color.RGB {
        return switch (target) {
            .palette => |index| self.terminal.colors.palette.current[index],
            .dynamic => |dynamic| switch (dynamic) {
                .foreground => self.terminal.colors.foreground.get(),
                .background => self.terminal.colors.background.get(),
                .cursor => self.terminal.colors.cursor.get() orelse self.terminal.colors.foreground.get(),
                else => null,
            },
            .special => null,
        };
    }
};

/// Format kitty keyboard query response. Exposed for testing.
fn formatKittyQueryResponse(buf: []u8, flags: u5) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[?{d}u", .{flags});
}

fn formatOscColorQueryResponse(
    buf: []u8,
    target: ghostty_vt.osc.color.Target,
    color: ghostty_vt.color.RGB,
    terminator: ghostty_vt.osc.Terminator,
) error{NoSpaceLeft}![]u8 {
    const red = @as(u16, color.r) * 257;
    const green = @as(u16, color.g) * 257;
    const blue = @as(u16, color.b) * 257;

    return switch (target) {
        .palette => |index| std.fmt.bufPrint(
            buf,
            "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}{s}",
            .{ index, red, green, blue, terminator.string() },
        ),
        .dynamic => |dynamic| std.fmt.bufPrint(
            buf,
            "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}{s}",
            .{ @intFromEnum(dynamic), red, green, blue, terminator.string() },
        ),
        .special => unreachable,
    };
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

test "formatOscColorQueryResponse formats dynamic queries with the input terminator" {
    var buf: [64]u8 = undefined;
    const resp = try formatOscColorQueryResponse(
        &buf,
        .{ .dynamic = .foreground },
        .{ .r = 0xab, .g = 0xcd, .b = 0xef },
        .bel,
    );
    try std.testing.expectEqualSlices(u8, "\x1b]10;rgb:abab/cdcd/efef\x07", resp);
}

test "stream answers OSC 10 and OSC 11 color queries" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 80,
        .rows = 24,
        .colors = .{
            .background = .init(.{ .r = 0x12, .g = 0x34, .b = 0x56 }),
            .foreground = .init(.{ .r = 0xab, .g = 0xcd, .b = 0xef }),
            .cursor = .unset,
            .palette = .default,
        },
    });
    defer terminal.deinit(allocator);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    var shell = shell_mod.Shell{
        .pty = .{
            .master = pipe_fds[1],
            .slave = pipe_fds[0],
        },
        .child_pid = 0,
    };

    var stream = initStream(allocator, &terminal, &shell);
    defer stream.deinit();

    var buf: [128]u8 = undefined;

    try stream.nextSlice("\x1b]10;?\x07");
    const fg_len = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualSlices(u8, "\x1b]10;rgb:abab/cdcd/efef\x07", buf[0..fg_len]);

    try stream.nextSlice("\x1b]11;?\x1b\\");
    const bg_len = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualSlices(u8, "\x1b]11;rgb:1212/3434/5656\x1b\\", buf[0..bg_len]);
}

test "stream answers OSC 4 palette queries with the current terminal palette" {
    const allocator = std.testing.allocator;

    var palette = ghostty_vt.color.default;
    palette[17] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 80,
        .rows = 24,
        .colors = .{
            .background = .init(.{ .r = 0x12, .g = 0x34, .b = 0x56 }),
            .foreground = .init(.{ .r = 0xab, .g = 0xcd, .b = 0xef }),
            .cursor = .unset,
            .palette = .init(palette),
        },
    });
    defer terminal.deinit(allocator);

    const pipe_fds = try std.posix.pipe();
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);

    var shell = shell_mod.Shell{
        .pty = .{
            .master = pipe_fds[1],
            .slave = pipe_fds[0],
        },
        .child_pid = 0,
    };

    var stream = initStream(allocator, &terminal, &shell);
    defer stream.deinit();

    var buf: [128]u8 = undefined;

    try stream.nextSlice("\x1b]4;17;?\x07");
    const len = try std.posix.read(pipe_fds[0], &buf);
    try std.testing.expectEqualSlices(u8, "\x1b]4;17;rgb:1212/3434/5656\x07", buf[0..len]);
}

pub const StreamType = ghostty_vt.Stream(Handler);

pub fn initStream(
    alloc: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    shell: *shell_mod.Shell,
) StreamType {
    return StreamType.initAlloc(alloc, Handler.init(terminal, shell));
}
