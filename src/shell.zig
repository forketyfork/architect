const std = @import("std");
const posix = std.posix;
const pty_mod = @import("pty.zig");

pub const Shell = struct {
    pty: pty_mod.Pty,
    child_pid: std.c.pid_t,

    pub const SpawnError = error{
        ForkFailed,
        ExecFailed,
    } || pty_mod.Pty.Error;

    pub fn spawn(shell_path: []const u8, size: pty_mod.winsize) SpawnError!Shell {
        const pty_instance = try pty_mod.Pty.open(size);
        errdefer {
            var pty_copy = pty_instance;
            pty_copy.deinit();
        }

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            try pty_instance.childPreExec();

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
