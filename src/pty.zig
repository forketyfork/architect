// Cross-platform (macOS/Linux) PTY helper that wraps openpty, window sizing, and
// controlling-terminal setup for spawned shells.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.pty);

extern "c" fn ttyname(fd: posix.fd_t) ?[*:0]const u8;

// zwanzig-disable: identifier-style
pub const winsize = extern struct {
    ws_row: u16 = 24,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

pub const Pty = switch (builtin.os.tag) {
    .macos, .linux => PosixPty,
    else => @compileError("Unsupported platform for PTY"),
};

pub const Mode = packed struct {
    canonical: bool = true,
    echo: bool = true,
};

const PosixPty = struct {
    pub const Error = OpenError || GetModeError || SetSizeError || ChildPreExecError;

    pub const Fd = posix.fd_t;

    const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
    const TIOCSWINSZ = if (builtin.os.tag == .macos) 2148037735 else c.TIOCSWINSZ;
    const TIOCGWINSZ = if (builtin.os.tag == .macos) 1074295912 else c.TIOCGWINSZ;
    extern "c" fn setsid() std.c.pid_t;
    const c = switch (builtin.os.tag) {
        .macos => @cImport({
            @cInclude("sys/ioctl.h");
            @cInclude("util.h");
        }),
        .freebsd => @cImport({
            @cInclude("termios.h");
            @cInclude("libutil.h");
        }),
        else => @cImport({
            @cInclude("sys/ioctl.h");
            @cInclude("pty.h");
        }),
    };

    master: Fd,
    slave: Fd,
    slave_path: [std.fs.max_path_bytes]u8,
    slave_path_len: usize,

    pub const OpenError = error{OpenptyFailed};

    pub fn open(size: winsize) OpenError!Pty {
        var size_copy = size;

        // openpty gives us a connected master/slave pair with the requested
        // window size; we mark the master CLOEXEC to avoid leaking into children.
        var master_fd: Fd = undefined;
        var slave_fd: Fd = undefined;
        if (c.openpty(
            &master_fd,
            &slave_fd,
            null,
            null,
            @ptrCast(&size_copy),
        ) < 0)
            return error.OpenptyFailed;
        errdefer {
            _ = posix.system.close(master_fd);
            _ = posix.system.close(slave_fd);
        }

        const slave_path_z = ttyname(slave_fd) orelse return error.OpenptyFailed;
        const slave_path_slice = std.mem.sliceTo(slave_path_z, 0);
        if (slave_path_slice.len > std.fs.max_path_bytes) return error.OpenptyFailed;
        var slave_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(slave_path_buf[0..slave_path_slice.len], slave_path_slice);

        cloexec: {
            const flags = std.posix.fcntl(master_fd, std.posix.F.GETFD, 0) catch |err| {
                log.warn("error getting flags for master fd err={}", .{err});
                break :cloexec;
            };

            _ = std.posix.fcntl(
                master_fd,
                std.posix.F.SETFD,
                flags | std.posix.FD_CLOEXEC,
            ) catch |err| {
                log.warn("error setting CLOEXEC on master fd err={}", .{err});
                break :cloexec;
            };
        }

        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0)
            return error.OpenptyFailed;
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0)
            return error.OpenptyFailed;

        return .{
            .master = master_fd,
            .slave = slave_fd,
            .slave_path = slave_path_buf,
            .slave_path_len = slave_path_slice.len,
        };
    }

    pub fn deinit(self: *Pty) void {
        _ = posix.system.close(self.master);
        self.* = undefined;
    }

    pub const GetModeError = error{GetModeFailed};

    pub fn getMode(self: Pty) GetModeError!Mode {
        var attrs: c.termios = undefined;
        if (c.tcgetattr(self.master, &attrs) != 0)
            return error.GetModeFailed;

        return .{
            .canonical = (attrs.c_lflag & c.ICANON) != 0,
            .echo = (attrs.c_lflag & c.ECHO) != 0,
        };
    }

    pub const SetSizeError = error{IoctlFailed};

    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        var size_copy = size;
        log.debug("set PTY winsize rows={d} cols={d} pixels={d}x{d} slave_path={s}", .{
            size.ws_row,
            size.ws_col,
            size.ws_xpixel,
            size.ws_ypixel,
            self.slave_path[0..self.slave_path_len],
        });

        if (setSizeOnFd(self.master, &size_copy)) {
            log.debug("set PTY winsize via master succeeded", .{});
            return;
        }
        log.debug("set PTY winsize via master failed; trying slave fd", .{});
        if (self.setSizeOnSlave(&size_copy)) {
            log.debug("set PTY winsize via slave succeeded", .{});
            return;
        }
        log.debug("set PTY winsize via slave failed", .{});
        return error.IoctlFailed;
    }

    fn setSizeOnSlave(self: *Pty, size: *winsize) bool {
        if (self.slave_path_len == 0) return false;
        const slave_fd = posix.open(self.slave_path[0..self.slave_path_len], .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) catch {
            return false;
        };
        defer posix.close(slave_fd);
        return setSizeOnFd(slave_fd, size);
    }

    fn setSizeOnFd(fd: Fd, size: *winsize) bool {
        return c.ioctl(fd, TIOCSWINSZ, @intFromPtr(size)) == 0;
    }

    fn getSizeOnFd(fd: Fd, size: *winsize) bool {
        return c.ioctl(fd, TIOCGWINSZ, @intFromPtr(size)) == 0;
    }

    pub const ChildPreExecError = error{ ProcessGroupFailed, SetControllingTerminalFailed };

    pub fn childPreExec(self: Pty) ChildPreExecError!void {
        // Reset inherited handlers that can interfere with child shells and
        // make this process the session leader before binding the slave as the
        // controlling terminal.
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.ABRT, &sa, null);
        posix.sigaction(posix.SIG.ALRM, &sa, null);
        posix.sigaction(posix.SIG.BUS, &sa, null);
        posix.sigaction(posix.SIG.CHLD, &sa, null);
        posix.sigaction(posix.SIG.FPE, &sa, null);
        posix.sigaction(posix.SIG.HUP, &sa, null);
        posix.sigaction(posix.SIG.ILL, &sa, null);
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.PIPE, &sa, null);
        posix.sigaction(posix.SIG.SEGV, &sa, null);
        posix.sigaction(posix.SIG.TRAP, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        posix.sigaction(posix.SIG.QUIT, &sa, null);
        posix.sigaction(posix.SIG.WINCH, &sa, null);

        if (setsid() < 0) return error.ProcessGroupFailed;

        switch (posix.errno(c.ioctl(self.slave, TIOCSCTTY, @as(c_ulong, 0)))) {
            .SUCCESS => {},
            else => |err| {
                log.err("error setting controlling terminal errno={}", .{err});
                return error.SetControllingTerminalFailed;
            },
        }
    }
};

test "setSize updates slave winsize" {
    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 800, .ws_ypixel = 600 });
    defer pty.deinit();
    defer posix.close(pty.slave);
    try std.testing.expect(pty.slave_path_len > 0);

    try pty.setSize(.{ .ws_row = 40, .ws_col = 120, .ws_xpixel = 1200, .ws_ypixel = 800 });

    var actual: winsize = undefined;
    try std.testing.expect(PosixPty.getSizeOnFd(pty.slave, &actual));
    try std.testing.expectEqual(@as(u16, 40), actual.ws_row);
    try std.testing.expectEqual(@as(u16, 120), actual.ws_col);
}
