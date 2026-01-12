// Shell process wrapper: spawns a login shell connected to a PTY and provides
// minimal read/write/wait helpers for the main event loop.
const std = @import("std");
const posix = std.posix;
const pty_mod = @import("pty.zig");
const libc = @cImport({
    @cInclude("stdlib.h");
});

const log = std.log.scoped(.shell);

var warned_env_defaults: bool = false;

const DEFAULT_TERM = "xterm-256color";
const DEFAULT_COLORTERM = "truecolor";
const DEFAULT_LANG = "en_US.UTF-8";
const DEFAULT_TERM_PROGRAM = "Architect";

fn setDefaultEnv(name: [:0]const u8, value: [:0]const u8) void {
    if (posix.getenv(name) != null) return;
    if (libc.setenv(name, value, 1) != 0) {
        std.c._exit(1);
    }
}

pub const Shell = struct {
    pty: pty_mod.Pty,
    child_pid: std.c.pid_t,

    pub const SpawnError = error{
        ForkFailed,
        ExecFailed,
    } || pty_mod.Pty.Error;

    const NAME_SESSION: [:0]const u8 = "ARCHITECT_SESSION_ID\x00";
    const NAME_SOCK: [:0]const u8 = "ARCHITECT_NOTIFY_SOCK\x00";

    pub fn spawn(shell_path: []const u8, size: pty_mod.winsize, session_id: [:0]const u8, notify_sock: [:0]const u8, working_dir: ?[:0]const u8) SpawnError!Shell {
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

            // Finder launches provide a nearly empty environment; seed common
            // terminal vars so shells behave like real terminals (color, terminfo).
            setDefaultEnv("TERM", DEFAULT_TERM);
            setDefaultEnv("COLORTERM", DEFAULT_COLORTERM);
            setDefaultEnv("LANG", DEFAULT_LANG);
            setDefaultEnv("TERM_PROGRAM", DEFAULT_TERM_PROGRAM);

            // Change to specified directory or home directory before spawning shell
            if (working_dir) |dir| {
                posix.chdir(dir) catch |err| {
                    log.err("failed to chdir to requested dir: {}", .{err});
                };
            } else if (posix.getenv("HOME")) |home| {
                posix.chdir(home) catch |err| {
                    log.err("failed to chdir to HOME: {}", .{err});
                };
            }

            posix.dup2(pty_instance.slave, posix.STDIN_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDOUT_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDERR_FILENO) catch std.c._exit(1);

            const shell_path_z = @as([*:0]const u8, @ptrCast(shell_path.ptr));
            const argv = [_:null]?[*:0]const u8{ shell_path_z, null };

            _ = std.c.execve(shell_path_z, &argv, @ptrCast(std.c.environ));
            std.c._exit(1);
        }

        if (!warned_env_defaults) {
            warned_env_defaults = true;
            if (posix.getenv("TERM") == null or posix.getenv("LANG") == null) {
                log.warn("TERM/LANG missing in parent env; child shells will receive defaults ({s}, {s})", .{ DEFAULT_TERM, DEFAULT_LANG });
            }
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
        var written: usize = 0;
        var waited_ns: u64 = 0;
        const max_wait_ns: u64 = 50 * std.time.ns_per_ms;
        const backoff_ns: u64 = 1 * std.time.ns_per_ms;

        while (written < data.len) {
            const n = posix.write(self.pty.master, data[written..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // PTY is full; retry for a short bounded window so pastes
                    // complete, but avoid indefinitely stalling the UI thread.
                    if (waited_ns >= max_wait_ns) {
                        return if (written > 0) written else err;
                    }
                    std.Thread.sleep(backoff_ns);
                    waited_ns += backoff_ns;
                    continue;
                },
                else => return err,
            };
            if (n == 0) return error.WouldBlock;
            written += n;
        }

        return data.len;
    }

    pub fn wait(self: *Shell) !void {
        _ = std.c.waitpid(self.child_pid, null, 0);
    }
};
