// Shell process wrapper: spawns a login shell connected to a PTY and provides
// minimal read/write/wait helpers for the main event loop.
const std = @import("std");
const posix = std.posix;
const pty_mod = @import("pty.zig");
const libc = @cImport({
    @cInclude("stdlib.h");
});

const log = std.log.scoped(.shell);

pub const Shell = struct {
    pty: pty_mod.Pty,
    child_pid: std.c.pid_t,

    pub const SpawnError = error{
        ForkFailed,
        ExecFailed,
    } || pty_mod.Pty.Error;

    const NAME_SESSION: [:0]const u8 = "ARCHITECT_SESSION_ID\x00";
    const NAME_SOCK: [:0]const u8 = "ARCHITECT_NOTIFY_SOCK\x00";

    pub fn spawn(shell_path: []const u8, size: pty_mod.winsize, session_id: [:0]const u8, notify_sock: [:0]const u8) SpawnError!Shell {
        const pty_instance = try pty_mod.Pty.open(size);
        errdefer {
            var pty_copy = pty_instance;
            pty_copy.deinit();
        }

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // Child: claim the PTY as controlling terminal and exec the shell with
            // session metadata injected for external notification hooks.
            try pty_instance.childPreExec();

            if (libc.setenv(NAME_SESSION.ptr, session_id, 1) != 0) {
                std.c._exit(1);
            }
            if (libc.setenv(NAME_SOCK.ptr, notify_sock, 1) != 0) {
                std.c._exit(1);
            }

            posix.dup2(pty_instance.slave, posix.STDIN_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDOUT_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDERR_FILENO) catch std.c._exit(1);

            const shell_path_z = @as([*:0]const u8, @ptrCast(shell_path.ptr));
            const argv = [_:null]?[*:0]const u8{ shell_path_z, null };

            _ = std.c.execve(shell_path_z, &argv, @ptrCast(std.c.environ));
            std.c._exit(1);
        }

        posix.close(pty_instance.slave);

        return .{
            .pty = pty_instance,
            .child_pid = pid,
        };
    }

    pub fn deinit(self: *Shell) void {
        self.pty.deinit();
        self.* = undefined;
    }

    pub fn read(self: *Shell, buffer: []u8) !usize {
        return posix.read(self.pty.master, buffer);
    }

    pub fn write(self: *Shell, data: []const u8) !usize {
        return posix.write(self.pty.master, data);
    }

    pub fn wait(self: *Shell) !void {
        _ = std.c.waitpid(self.child_pid, null, 0);
    }
};
