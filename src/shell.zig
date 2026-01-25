// Shell process wrapper: spawns a login shell connected to a PTY and provides
// minimal read/write/wait helpers for the main event loop.
const std = @import("std");
const assets = @import("assets");
const posix = std.posix;
const pty_mod = @import("pty.zig");
const libc = @cImport({
    @cInclude("stdlib.h");
});

const log = std.log.scoped(.shell);

// POSIX wait status macros (not available in std.c)
fn wifexited(status: c_int) bool {
    return (status & 0x7f) == 0;
}

fn wexitstatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

var warned_env_defaults: bool = false;
var terminfo_setup_done: bool = false;
var terminfo_available: bool = false;
var terminfo_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var terminfo_dir_z: ?[:0]const u8 = null;
var tic_path_buf: [std.fs.max_path_bytes]u8 = undefined;

const fallback_term = "xterm-256color";
const architect_term = "xterm-ghostty";
const default_colorterm = "truecolor";
const default_lang = "en_US.UTF-8";
const default_term_program = "Architect";

// Architect terminfo: xterm-256color base + 24-bit truecolor + kitty keyboard protocol
const architect_terminfo_src = assets.xterm_ghostty;

fn setDefaultEnv(name: [:0]const u8, value: [:0]const u8) void {
    if (posix.getenv(name) != null) return;
    if (libc.setenv(name, value, 1) != 0) {
        std.c._exit(1);
    }
}

fn setEnv(name: [:0]const u8, value: [:0]const u8) void {
    if (libc.setenv(name, value, 1) != 0) {
        std.c._exit(1);
    }
}

/// Ensure xterm-ghostty terminfo is compiled and available.
/// Installs to ~/.cache/architect/terminfo. Must be called from parent process before fork.
pub fn ensureTerminfoSetup() void {
    if (terminfo_setup_done) return;
    terminfo_setup_done = true;

    // Install to ~/.cache/architect/terminfo
    const home = posix.getenv("HOME") orelse {
        log.warn("HOME not set, cannot install terminfo, falling back to {s}", .{fallback_term});
        return;
    };

    const cache_dir_z = std.fmt.bufPrintZ(&terminfo_dir_buf, "{s}/.cache/architect/terminfo", .{home}) catch {
        log.warn("Failed to format terminfo cache path", .{});
        return;
    };
    const cache_dir = cache_dir_z[0..cache_dir_z.len];

    // Create cache directory structure (including parents)
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Create ~/.cache first if needed
    const dot_cache = std.fmt.bufPrint(&parent_buf, "{s}/.cache", .{home}) catch return;
    std.fs.makeDirAbsolute(dot_cache) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create .cache dir: {}", .{err});
            return;
        },
    };

    // Create ~/.cache/architect (parent of terminfo dir)
    var architect_buf: [std.fs.max_path_bytes]u8 = undefined;
    const architect_dir = std.fmt.bufPrint(&architect_buf, "{s}/.cache/architect", .{home}) catch return;
    std.fs.makeDirAbsolute(architect_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create architect cache dir: {}", .{err});
            return;
        },
    };

    // Create terminfo dir
    std.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create terminfo cache dir: {}", .{err});
            return;
        },
    };

    // Create x subdir for terminfo entries
    var x_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const x_dir = std.fmt.bufPrint(&x_dir_buf, "{s}/x", .{cache_dir}) catch return;
    std.fs.makeDirAbsolute(x_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create terminfo x dir: {}", .{err});
            return;
        },
    };

    // Write terminfo source to temp file (need null-terminated paths for execve)
    var src_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path_z = std.fmt.bufPrintZ(&src_path_buf, "{s}/xterm-ghostty.ti", .{cache_dir}) catch return;

    const src_file = std.fs.createFileAbsolute(src_path_z, .{}) catch |err| {
        log.warn("Failed to create terminfo source file: {}", .{err});
        return;
    };
    defer src_file.close();
    src_file.writeAll(architect_terminfo_src) catch |err| {
        log.warn("Failed to write terminfo source: {}", .{err});
        return;
    };

    const tic_path = findExecutableInPath("tic") orelse {
        log.warn("tic not found in PATH, falling back to {s}", .{fallback_term});
        return;
    };

    // Compile with tic
    const tic_argv = [_:null]?[*:0]const u8{
        tic_path.ptr,
        "-x",
        "-o",
        cache_dir_z.ptr,
        src_path_z.ptr,
        null,
    };

    const fork_result = std.c.fork();
    if (fork_result == 0) {
        // Child: exec tic
        _ = std.c.execve(tic_path.ptr, &tic_argv, @ptrCast(std.c.environ));
        std.c._exit(1);
    } else if (fork_result > 0) {
        // Parent: wait for tic to complete
        var status: c_int = 0;
        _ = std.c.waitpid(fork_result, &status, 0);

        if (wifexited(status) and wexitstatus(status) == 0) {
            log.info("Successfully compiled {s} terminfo to {s}", .{ architect_term, cache_dir_z });
            terminfo_dir_z = cache_dir_z;
            terminfo_available = true;
        } else {
            log.warn("tic failed to compile terminfo (status={}), falling back to {s}", .{ status, fallback_term });
        }
    } else {
        log.warn("Failed to fork for tic, falling back to {s}", .{fallback_term});
    }
}

fn findExecutableInPath(name: []const u8) ?[:0]const u8 {
    const path_env = posix.getenv("PATH") orelse return null;
    const path_env_slice = std.mem.sliceTo(path_env, 0);
    var it = std.mem.splitScalar(u8, path_env_slice, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.bufPrintZ(&tic_path_buf, "{s}/{s}", .{ dir, name }) catch |err| {
            log.warn("failed to format candidate path: {}", .{err});
            continue;
        };
        if (std.fs.cwd().statFile(candidate)) |_| {
            return candidate;
        } else |_| {}
    }
    return null;
}

pub const Shell = struct {
    pty: pty_mod.Pty,
    child_pid: std.c.pid_t,

    pub const SpawnError = error{
        ForkFailed,
        ExecFailed,
    } || pty_mod.Pty.Error;

    const name_session: [:0]const u8 = "ARCHITECT_SESSION_ID\x00";
    const name_sock: [:0]const u8 = "ARCHITECT_NOTIFY_SOCK\x00";

    pub fn spawn(shell_path: []const u8, size: pty_mod.winsize, session_id: [:0]const u8, notify_sock: [:0]const u8, working_dir: ?[:0]const u8) SpawnError!Shell {
        // Ensure terminfo is set up (parent process, before fork)
        ensureTerminfoSetup();

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

            if (libc.setenv(name_session.ptr, session_id, 1) != 0) {
                std.c._exit(1);
            }
            if (libc.setenv(name_sock.ptr, notify_sock, 1) != 0) {
                std.c._exit(1);
            }

            // Finder launches provide a nearly empty environment; seed common
            // terminal vars so shells behave like real terminals (color, terminfo).
            // Use xterm-ghostty if terminfo is available for kitty keyboard protocol support.
            if (terminfo_available) {
                if (terminfo_dir_z) |dir| {
                    // We installed to cache, set TERMINFO to point there
                    setEnv("TERMINFO", dir);
                }
                setEnv("TERM", architect_term);
            } else {
                setEnv("TERM", fallback_term);
            }
            setDefaultEnv("COLORTERM", default_colorterm);
            setDefaultEnv("LANG", default_lang);
            setDefaultEnv("TERM_PROGRAM", default_term_program);

            // Change to specified directory or home directory before spawning shell.
            // Try working_dir first, fall back to HOME.
            const target_dir = working_dir orelse posix.getenv("HOME");
            if (target_dir) |dir| {
                // zwanzig-disable: empty-catch-engine
                // Errors are intentionally ignored: we're in a forked child process where
                // logging is impractical, and chdir failure is non-fatal (shell starts in
                // the parent's cwd instead).
                posix.chdir(dir) catch {};
            }

            posix.dup2(pty_instance.slave, posix.STDIN_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDOUT_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDERR_FILENO) catch std.c._exit(1);

            const shell_path_z = @as([*:0]const u8, @ptrCast(shell_path.ptr));
            const login_flag = "-l\x00";
            const argv = [_:null]?[*:0]const u8{ shell_path_z, login_flag, null };

            _ = std.c.execve(shell_path_z, &argv, @ptrCast(std.c.environ));
            std.c._exit(1);
        }

        if (!warned_env_defaults) {
            warned_env_defaults = true;
            if (posix.getenv("TERM") == null or posix.getenv("LANG") == null) {
                log.warn("TERM/LANG missing in parent env; child shells will receive defaults ({s}, {s})", .{ fallback_term, default_lang });
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
