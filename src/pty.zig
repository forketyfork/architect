// Cross-platform (macOS/Linux) PTY helper that wraps openpty, window sizing, and
// controlling-terminal setup for spawned shells.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.pty);

// zwanzig-disable-next-line: identifier-style
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
        if (c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size)) < 0)
            return error.IoctlFailed;
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
