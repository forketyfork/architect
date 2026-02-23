const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const xev = @import("xev");
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("../shell.zig");
const pty_mod = @import("../pty.zig");
const fs = std.fs;
const cwd_mod = if (builtin.os.tag == .macos) @import("../cwd.zig") else struct {};
const vt_stream = @import("../vt_stream.zig");
const mac = if (builtin.os.tag == .macos)
    @cImport({
        @cInclude("sys/types.h");
        @cInclude("sys/sysctl.h");
        @cInclude("sys/proc.h");
    })
else
    struct {};

pub const AgentKind = enum {
    claude,
    codex,
    gemini,

    pub fn fromComm(comm: []const u8) ?AgentKind {
        if (std.mem.eql(u8, comm, "claude")) return .claude;
        if (std.mem.eql(u8, comm, "codex")) return .codex;
        if (std.mem.eql(u8, comm, "gemini")) return .gemini;
        return null;
    }

    pub fn fromString(s: []const u8) ?AgentKind {
        return fromComm(s);
    }

    /// Returns the agent kind if any known agent name appears as a substring of path.
    /// Used with proc_pidpath results, which may contain the agent name in directory components.
    pub fn fromPath(path: []const u8) ?AgentKind {
        if (std.mem.indexOf(u8, path, "claude") != null) return .claude;
        if (std.mem.indexOf(u8, path, "codex") != null) return .codex;
        if (std.mem.indexOf(u8, path, "gemini") != null) return .gemini;
        return null;
    }

    pub fn name(self: AgentKind) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .gemini => "gemini",
        };
    }

    /// Control-byte sequence that triggers graceful exit.
    pub fn exitControlSequence(self: AgentKind) []const u8 {
        return switch (self) {
            .claude, .codex, .gemini => "\x03\x03",
        };
    }
};

const log = std.log.scoped(.session_state);

extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;
extern "c" fn ptsname(fd: posix.fd_t) ?[*:0]const u8;
/// Returns the full executable path for the given pid; available on macOS via libproc.
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

const pending_write_shrink_threshold: usize = 64 * 1024;
const session_id_buf_len: usize = 32;
var next_session_id = std.atomic.Value(usize).init(0);

pub const SessionState = struct {
    slot_index: usize,
    id: usize,
    shell: ?shell_mod.Shell,
    terminal: ?ghostty_vt.Terminal,
    stream: ?vt_stream.StreamType,
    output_buf: [4096]u8,
    render_epoch: u64 = 1,
    spawned: bool = false,
    dead: bool = false,
    shell_path: []const u8,
    pty_size: pty_mod.winsize,
    session_id_z: [session_id_buf_len:0]u8,
    notify_sock_z: [:0]const u8,
    allocator: std.mem.Allocator,
    cwd_path: ?[]const u8 = null,
    /// Subslice of cwd_path pointing to the basename. Always points within cwd_path's memory.
    /// When cwd_path is freed, this becomes invalid and must not be used.
    cwd_basename: ?[]const u8 = null,
    cwd_last_check: i64 = 0,
    /// Set to true once updateCwd observes a non-root directory. Prevents the transient `/`
    /// that the shell briefly reports during startup from polluting recent_folders.
    cwd_settled: bool = false,
    pending_write: std.ArrayListUnmanaged(u8) = .empty,
    /// Process watcher for event-driven exit detection.
    process_watcher: ?xev.Process = null,
    /// Context for disambiguating process exit callbacks. Includes its own completion struct
    /// so each process watcher has an independent completion that won't be corrupted on relaunch.
    process_wait_ctx: ?*WaitContext = null,
    /// Incremented whenever a new watcher is armed to ignore stale completions.
    process_generation: usize = 0,
    /// Last AI agent that set the terminal icon (OSC 1) during this session.
    /// Updated continuously by processOutput; used as a reliable fallback for agent detection
    /// when KERN_PROCARGS2 is restricted by the OS (macOS Sequoia and later).
    agent_icon: ?AgentKind = null,
    /// Agent type detected at quit time (macOS only). Set transiently before persistence save.
    agent_kind: ?AgentKind = null,
    /// Agent session UUID extracted from terminal output at quit time. Owned; freed in deinit.
    agent_session_id: ?[]const u8 = null,

    const WaitContext = struct {
        session: *SessionState,
        generation: usize,
        pid: posix.pid_t,
        /// Each WaitContext has its own completion to avoid corruption when relaunching.
        completion: xev.Completion = .{},
    };

    pub const InitError = shell_mod.Shell.SpawnError || MakeNonBlockingError || error{
        DivisionByZero,
        GraphemeAllocOutOfMemory,
        GraphemeMapOutOfMemory,
        HyperlinkMapOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkSetOutOfMemory,
        NeedsRehash,
        OutOfMemory,
        StringAllocOutOfMemory,
        StyleSetNeedsRehash,
        StyleSetOutOfMemory,
        SystemResources,
        SystemFdQuotaExceeded,
        InvalidArgument,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        slot_index: usize,
        shell_path: []const u8,
        size: pty_mod.winsize,
        notify_sock: [:0]const u8,
    ) InitError!SessionState {
        const session_id_buf = [_:0]u8{0} ** session_id_buf_len;

        return SessionState{
            .slot_index = slot_index,
            .id = 0,
            .shell = null,
            .terminal = null,
            .stream = null,
            .output_buf = undefined,
            .spawned = false,
            .shell_path = shell_path,
            .pty_size = size,
            .session_id_z = session_id_buf,
            .notify_sock_z = notify_sock,
            .allocator = allocator,
        };
    }

    pub fn ensureSpawned(self: *SessionState) InitError!void {
        return self.ensureSpawnedWithDir(null, null);
    }

    pub fn ensureSpawnedWithLoop(self: *SessionState, loop: *xev.Loop) InitError!void {
        return self.ensureSpawnedWithDir(null, loop);
    }

    pub fn ensureSpawnedWithDir(self: *SessionState, working_dir: ?[:0]const u8, loop_opt: ?*xev.Loop) InitError!void {
        if (self.spawned) return;

        // Bump generation to invalidate any stale callbacks from a previous shell; wrapping is intentional.
        self.process_generation +%= 1;
        self.assignNewSessionId();

        const shell = try shell_mod.Shell.spawn(
            self.shell_path,
            self.pty_size,
            &self.session_id_z,
            self.notify_sock_z,
            working_dir,
        );
        errdefer {
            var s = shell;
            s.deinit();
        }

        var terminal = try ghostty_vt.Terminal.init(self.allocator, .{
            .cols = self.pty_size.ws_col,
            .rows = self.pty_size.ws_row,
            .max_scrollback = 10_000_000,
            .default_modes = .{ .grapheme_cluster = true },
        });
        errdefer terminal.deinit(self.allocator);

        try makeNonBlocking(shell.pty.master);

        self.shell = shell;
        self.terminal = terminal;
        self.spawned = true;
        const stream = vt_stream.initStream(
            self.allocator,
            &self.terminal.?,
            &self.shell.?,
        );
        self.stream = stream;
        self.markDirty();

        if (loop_opt) |loop| {
            var process = try xev.Process.init(shell.child_pid);
            errdefer process.deinit();

            const wait_ctx = try self.allocator.create(WaitContext);
            errdefer self.allocator.destroy(wait_ctx);
            wait_ctx.* = .{
                .session = self,
                .generation = self.process_generation,
                .pid = shell.child_pid,
            };
            self.process_wait_ctx = wait_ctx;

            process.wait(
                loop,
                &wait_ctx.completion,
                WaitContext,
                wait_ctx,
                processExitCallback,
            );

            self.process_watcher = process;
        }

        log.debug("spawned session {d}", .{self.id});

        self.processOutput() catch |err| {
            log.warn("session {d}: initial output processing failed: {}", .{ self.id, err });
        };

        self.seedCwd(working_dir) catch |err| {
            log.warn("failed to record cwd for session {d}: {}", .{ self.id, err });
        };
    }

    fn assignNewSessionId(self: *SessionState) void {
        const new_id = next_session_id.fetchAdd(1, .seq_cst);
        self.id = new_id;
        const written = std.fmt.bufPrint(&self.session_id_z, "{d}", .{new_id}) catch |err| {
            log.warn("failed to format session id {d}: {}", .{ new_id, err });
            self.session_id_z[0] = 0;
            return;
        };
        self.session_id_z[written.len] = 0;
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        self.pending_write.deinit(allocator);
        self.pending_write = .empty;

        if (self.agent_session_id) |sid| {
            allocator.free(sid);
            self.agent_session_id = null;
        }
        self.agent_kind = null;

        if (self.cwd_path) |path| {
            allocator.free(path);
            self.cwd_path = null;
            self.cwd_basename = null;
        }

        if (self.process_watcher) |*watcher| {
            watcher.deinit();
            self.process_watcher = null;
        }
        if (self.process_wait_ctx) |ctx| {
            // Free unconditionally: deinit runs after the event loop stops, so
            // processExitCallback will never fire for pending completions.
            allocator.destroy(ctx);
        }
        self.process_wait_ctx = null;
        // Wrap intentionally: process_generation is a bounded counter and may overflow.
        self.process_generation +%= 1;

        if (self.spawned) {
            if (self.shell) |*shell| {
                if (!self.dead) {
                    _ = std.c.kill(shell.child_pid, std.c.SIG.TERM);
                }
                shell.deinit();
                self.shell = null;
            }
            if (self.stream) |*stream| {
                stream.deinit();
                self.stream = null;
            }
            if (self.terminal) |*terminal| {
                terminal.deinit(allocator);
                self.terminal = null;
            }

            self.spawned = false;
            self.dead = false;
            self.cwd_settled = false;
        }
    }

    pub const ProcessOutputError = posix.ReadError || posix.WriteError || error{
        DivisionByZero,
        GraphemeAllocOutOfMemory,
        GraphemeMapOutOfMemory,
        HyperlinkMapOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkSetOutOfMemory,
        NeedsRehash,
        OutOfMemory,
        OutOfSpace,
        StringAllocOutOfMemory,
        StyleSetNeedsRehash,
        StyleSetOutOfMemory,
    };

    fn processExitCallback(
        ctx_opt: ?*WaitContext,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Process.WaitError!u32,
    ) xev.CallbackAction {
        const ctx = ctx_opt orelse return .disarm;
        const self = ctx.session;

        // Ignore completions from stale watchers (after despawn/restart) or mismatched PID.
        const shell = self.shell orelse {
            const is_current = self.process_wait_ctx == ctx;
            self.allocator.destroy(ctx);
            if (is_current) self.process_wait_ctx = null;
            return .disarm;
        };
        if (ctx.generation != self.process_generation or ctx.pid != shell.child_pid) {
            const is_current = self.process_wait_ctx == ctx;
            self.allocator.destroy(ctx);
            if (is_current) self.process_wait_ctx = null;
            return .disarm;
        }

        const exit_code = r catch |err| {
            log.err("process wait error for session {d}: {}", .{ self.id, err });
            const is_current = self.process_wait_ctx == ctx;
            self.allocator.destroy(ctx);
            if (is_current) self.process_wait_ctx = null;
            return .disarm;
        };

        self.dead = true;
        self.markDirty();
        log.info("session {d} process exited with code {d}", .{ self.id, exit_code });

        const is_current = self.process_wait_ctx == ctx;
        self.allocator.destroy(ctx);
        if (is_current) self.process_wait_ctx = null;

        return .disarm;
    }

    pub fn checkAlive(self: *SessionState) void {
        if (!self.spawned or self.dead) return;

        if (self.shell) |shell| {
            var status: c_int = 0;
            const result = std.c.waitpid(shell.child_pid, &status, std.c.W.NOHANG);
            if (result > 0) {
                self.dead = true;
                self.markDirty();
                log.info("session {d} process exited", .{self.id});
            }
        }
    }

    pub fn restart(self: *SessionState) InitError!void {
        if (self.spawned and !self.dead) return;

        self.resetForRespawn();
        try self.ensureSpawned();
    }

    pub fn relaunch(self: *SessionState, working_dir: ?[:0]const u8, loop_opt: ?*xev.Loop) InitError!void {
        self.resetForRespawn();
        try self.ensureSpawnedWithDir(working_dir, loop_opt);
    }

    pub fn relaunchWithDir(self: *SessionState, working_dir: [:0]const u8, loop_opt: ?*xev.Loop) InitError!void {
        return self.relaunch(working_dir, loop_opt);
    }

    fn resetForRespawn(self: *SessionState) void {
        self.clearTerminalSelection();
        self.pending_write.clearAndFree(self.allocator);
        if (self.process_watcher) |*watcher| {
            watcher.deinit();
            self.process_watcher = null;
        }
        if (self.process_wait_ctx) |ctx| {
            if (ctx.completion.state() == .dead) {
                self.allocator.destroy(ctx);
            }
        }
        self.process_wait_ctx = null;
        // Wrap intentionally: generation just invalidates prior watchers.
        self.process_generation +%= 1;
        if (self.spawned) {
            if (self.stream) |*stream| {
                stream.deinit();
                self.stream = null;
            }
            if (self.terminal) |*terminal| {
                terminal.deinit(self.allocator);
                self.terminal = null;
            }
            if (self.shell) |*shell| {
                shell.deinit();
                self.shell = null;
            }
        }

        self.spawned = false;
        self.dead = false;
        self.cwd_settled = false;
    }

    pub fn markDirty(self: *SessionState) void {
        self.render_epoch +%= 1;
    }

    fn clearTerminalSelection(self: *SessionState) void {
        if (!self.spawned) return;
        if (self.terminal) |*terminal| {
            terminal.screens.active.clearSelection();
            self.markDirty();
        }
    }

    pub fn processOutput(self: *SessionState) ProcessOutputError!void {
        if (!self.spawned or self.dead) return;

        const shell = &(self.shell orelse return);
        const stream = &(self.stream orelse return);

        while (true) {
            const n = shell.read(&self.output_buf) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };

            if (n == 0) return;

            if (scanOsc1Agent(self.output_buf[0..n])) |kind| {
                self.agent_icon = kind;
            }
            try stream.nextSlice(self.output_buf[0..n]);
            self.markDirty();

            // Keep draining until the PTY would block to avoid frame-bounded
            // throttling of bursty output (e.g. startup logos).
        }
    }

    /// Try to flush any queued stdin data; preserves ordering relative to new input.
    pub fn flushPendingWrites(self: *SessionState) !void {
        if (self.pending_write.items.len == 0) return;
        const shell = &(self.shell orelse return);
        const buf = self.pending_write.items[0..self.pending_write.items.len];
        const wrote = shell.write(buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (wrote == buf.len) {
            self.pending_write.clearRetainingCapacity();
            maybeShrinkPendingWrite(&self.pending_write, self.allocator);
            return;
        }
        if (wrote > 0) {
            const remaining = buf[wrote..];
            std.mem.copyForwards(u8, self.pending_write.items[0..remaining.len], remaining);
            self.pending_write.items.len = remaining.len;
        }
        // If wrote == 0 and WouldBlock, keep buffer as-is for next frame.
    }

    pub fn sendInput(self: *SessionState, data: []const u8) !void {
        if (!self.spawned or self.dead) return;
        try self.flushPendingWrites();
        const shell = &(self.shell orelse return);
        const wrote = shell.write(data) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (wrote < data.len) {
            try self.pending_write.appendSlice(self.allocator, data[wrote..]);
        }
    }

    pub fn updateCwd(self: *SessionState, current_time: i64) void {
        if (builtin.os.tag != .macos) return;

        if (!self.spawned or self.dead) return;

        const shell = self.shell orelse return;

        const check_interval_ms: i64 = 1000;
        if (current_time - self.cwd_last_check < check_interval_ms) return;
        self.cwd_last_check = current_time;

        const new_path = cwd_mod.getCwd(self.allocator, shell.child_pid) catch {
            return;
        };

        if (self.cwd_path) |old_path| {
            if (std.mem.eql(u8, old_path, new_path)) {
                self.allocator.free(new_path);
                return;
            }
            self.allocator.free(old_path);
        }

        if (!self.cwd_settled and !std.mem.eql(u8, new_path, "/")) {
            self.cwd_settled = true;
        }
        self.cwd_path = new_path;
        self.cwd_basename = basenameForDisplay(new_path);
        self.markDirty();
    }

    pub fn recordCwd(self: *SessionState, path: []const u8) !void {
        try self.replaceCwdPath(path);
    }

    fn seedCwd(self: *SessionState, working_dir: ?[:0]const u8) !void {
        if (working_dir) |dir| {
            try self.replaceCwdPath(sliceToZ(dir));
            return;
        }

        if (std.posix.getenv("HOME")) |home_z| {
            try self.replaceCwdPath(std.mem.sliceTo(home_z, 0));
        }
    }

    fn replaceCwdPath(self: *SessionState, path: []const u8) !void {
        if (self.cwd_path) |old| {
            self.allocator.free(old);
        }

        self.cwd_path = try self.allocator.dupe(u8, path);
        self.cwd_basename = basenameForDisplay(self.cwd_path.?);
        self.markDirty();
    }

    /// Returns true when the PTY's foreground process group differs from the
    /// shell's PID, indicating that a child process is currently running in
    /// the terminal.
    pub fn hasForegroundProcess(self: *const SessionState) bool {
        if (!self.spawned or self.dead) return false;
        const shell = self.shell orelse return false;
        if (getForegroundPgrp(shell.child_pid)) |fg| {
            return fg != shell.child_pid;
        }
        const slave_path_z = ptsname(shell.pty.master) orelse return false;
        const slave_path = std.mem.sliceTo(slave_path_z, 0);
        const fd = posix.openZ(slave_path, .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) catch {
            return false;
        };
        defer posix.close(fd);
        const fg_pgrp = tcgetpgrp(fd);
        if (fg_pgrp < 0) return false;
        return fg_pgrp != shell.child_pid;
    }

    pub fn shellPid(self: *const SessionState) ?posix.pid_t {
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;
        return shell.child_pid;
    }

    pub fn ptyMasterFd(self: *const SessionState) ?posix.fd_t {
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;
        return shell.pty.master;
    }

    /// Copies the PTY slave path into `dest` and returns a sentinel-terminated slice.
    /// Returns null when no shell is available or when `dest` is too small.
    pub fn copyPtySlavePath(self: *const SessionState, dest: []u8) ?[:0]const u8 {
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;
        const slave_path_z = ptsname(shell.pty.master) orelse return null;
        const slave_path = std.mem.sliceTo(slave_path_z, 0);
        if (slave_path.len + 1 > dest.len) return null;
        @memcpy(dest[0..slave_path.len], slave_path);
        dest[slave_path.len] = 0;
        return dest[0..slave_path.len :0];
    }

    /// Returns the AgentKind of the foreground process if it is a known AI agent.
    /// macOS only; always returns null on other platforms.
    pub fn detectForegroundAgent(self: *const SessionState) ?AgentKind {
        if (builtin.os.tag != .macos) return null;
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;

        const fg_pgrp = blk: {
            if (getForegroundPgrp(shell.child_pid)) |fg| {
                log.debug("detectForegroundAgent: shell_pid={d} fg_pgrp_sysctl={d}", .{ shell.child_pid, fg });
                if (fg == shell.child_pid) {
                    log.debug("detectForegroundAgent: shell is foreground, no agent", .{});
                    return null;
                }
                break :blk fg;
            }
            log.debug("detectForegroundAgent: sysctl fg pgrp unavailable, falling back to tcgetpgrp", .{});
            const slave_path_z = ptsname(shell.pty.master) orelse return null;
            const slave_path = std.mem.sliceTo(slave_path_z, 0);
            const fd = posix.openZ(slave_path, .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) catch return null;
            defer posix.close(fd);
            const fg = tcgetpgrp(fd);
            log.debug("detectForegroundAgent: shell_pid={d} fg_pgrp_tcgetpgrp={d}", .{ shell.child_pid, fg });
            if (fg <= 0 or fg == shell.child_pid) return null;
            break :blk @as(posix.pid_t, @intCast(fg));
        };

        if (detectAgentByPid(fg_pgrp)) |kind| {
            log.debug("detectForegroundAgent: fg_pgrp={d} result={s} (process inspection)", .{ fg_pgrp, kind.name() });
            return kind;
        }

        // KERN_PROCARGS2 may be restricted on macOS Sequoia (returns zeroed data without
        // a special entitlement). Fall back to the icon set by the agent via OSC 1: all
        // three agents (claude, codex, gemini) emit  ESC]1;<name>BEL  when they start.
        if (self.agent_icon) |kind| {
            log.debug("detectForegroundAgent: fg_pgrp={d} result={s} (OSC 1 icon fallback)", .{ fg_pgrp, kind.name() });
            return kind;
        }

        log.debug("detectForegroundAgent: fg_pgrp={d} result=null", .{fg_pgrp});
        return null;
    }

    /// Sends SIGTERM to the foreground process group of this session's PTY.
    /// No-op if no foreground agent is detected or on non-macOS platforms.
    pub fn sendTermToForegroundPgrp(self: *SessionState) void {
        if (builtin.os.tag != .macos) return;
        if (!self.spawned or self.dead) return;
        const shell = self.shell orelse return;

        const fg_pgrp = blk: {
            if (getForegroundPgrp(shell.child_pid)) |fg| {
                if (fg == shell.child_pid) return;
                break :blk fg;
            }
            const slave_path_z = ptsname(shell.pty.master) orelse return;
            const slave_path = std.mem.sliceTo(slave_path_z, 0);
            const fd = posix.openZ(slave_path, .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) catch return;
            defer posix.close(fd);
            const fg = tcgetpgrp(fd);
            if (fg <= 0 or fg == shell.child_pid) return;
            break :blk @as(posix.pid_t, @intCast(fg));
        };

        _ = std.c.kill(-fg_pgrp, std.c.SIG.TERM);
        log.debug("sent SIGTERM to foreground pgrp {d}", .{fg_pgrp});
    }

    /// Writes the agent's graceful-exit key sequence to the PTY master fd.
    /// For all agents we send Ctrl+C twice with a short pause in between.
    /// Falls through silently on error; the caller should follow up with sendTermToForegroundPgrp
    /// if the agent does not exit within the drain window.
    pub fn sendExitCommand(self: *SessionState, agent_kind: AgentKind) void {
        self.sendDoubleCtrlC(agent_kind);
    }

    /// Same as sendExitCommand; retained as a separate API for runtime retry stages.
    pub fn sendExitCommandWithInterrupt(self: *SessionState, agent_kind: AgentKind) void {
        self.sendDoubleCtrlC(agent_kind);
    }

    fn sendDoubleCtrlC(self: *SessionState, agent_kind: AgentKind) void {
        if (!self.spawned or self.dead) return;
        const shell = self.shell orelse return;

        const sendByte = struct {
            fn write(fd: posix.fd_t, byte: u8) !void {
                const buf = [1]u8{byte};
                _ = try posix.write(fd, &buf);
            }
        }.write;

        const sequence = agent_kind.exitControlSequence();
        for (sequence, 0..) |byte, idx| {
            sendByte(shell.pty.master, byte) catch |err| {
                log.warn("sendExitCommand: write failed (ctrl-c step {d}): {}", .{ idx + 1, err });
                return;
            };
            if (idx + 1 < sequence.len) {
                std.Thread.sleep(220 * std.time.ns_per_ms);
            }
        }
        log.debug("sendExitCommand: wrote exit command for agent {s}", .{agent_kind.name()});
    }

    /// Drains PTY output into the terminal buffer for up to `timeout_ms` milliseconds,
    /// stopping early if the shell process exits. Called synchronously at quit time only.
    pub fn drainOutputForMs(self: *SessionState, timeout_ms: u64) void {
        if (!self.spawned or self.dead) return;
        const shell = &(self.shell orelse return);
        const stream = &(self.stream orelse return);

        const master_fd = shell.pty.master;

        const orig_flags = posix.fcntl(master_fd, posix.F.GETFL, 0) catch return;
        var blocking_flags: posix.O = @bitCast(@as(u32, @intCast(orig_flags)));
        blocking_flags.NONBLOCK = false;
        _ = posix.fcntl(master_fd, posix.F.SETFL, @as(u32, @bitCast(blocking_flags))) catch |err| {
            log.warn("failed to set PTY master to blocking mode: {}", .{err});
            return;
        };
        defer {
            var restore_flags: posix.O = @bitCast(@as(u32, @intCast(orig_flags)));
            restore_flags.NONBLOCK = true;
            _ = posix.fcntl(master_fd, posix.F.SETFL, @as(u32, @bitCast(restore_flags))) catch |err| {
                log.warn("failed to restore PTY master flags: {}", .{err});
            };
        }

        const start_ms = std.time.milliTimestamp();
        const deadline_ms = start_ms + @as(i64, @intCast(timeout_ms));
        var buf: [4096]u8 = undefined;
        var total_bytes: usize = 0;

        log.debug("drainOutputForMs: starting drain for up to {d}ms", .{timeout_ms});

        while (true) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms >= deadline_ms) {
                log.debug("drainOutputForMs: deadline reached after {d}ms, {d} bytes read", .{ now_ms - start_ms, total_bytes });
                break;
            }

            var status: c_int = 0;
            if (std.c.waitpid(shell.child_pid, &status, std.c.W.NOHANG) > 0) {
                log.debug("drainOutputForMs: shell exited after {d}ms, {d} bytes read", .{ now_ms - start_ms, total_bytes });
                self.dead = true;
                self.markDirty();
                break;
            }

            const remaining: i64 = deadline_ms - std.time.milliTimestamp();
            if (remaining <= 0) break;
            const poll_ms: i32 = @intCast(@min(remaining, @as(i64, 100)));

            var pfd = [_]posix.pollfd{.{
                .fd = master_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const n_ready = posix.poll(&pfd, poll_ms) catch |err| {
                log.debug("drainOutputForMs: poll error: {}", .{err});
                break;
            };
            if (n_ready == 0) continue;
            if (pfd[0].revents & posix.POLL.HUP != 0) {
                log.debug("drainOutputForMs: PTY HUP after {d}ms, {d} bytes read", .{ std.time.milliTimestamp() - start_ms, total_bytes });
                break;
            }
            if (pfd[0].revents & posix.POLL.IN == 0) continue;

            const n = posix.read(master_fd, &buf) catch |err| {
                log.debug("drainOutputForMs: read error: {}", .{err});
                break;
            };
            if (n == 0) break;

            total_bytes += n;
            stream.nextSlice(buf[0..n]) catch |err| {
                log.warn("drainOutputForMs: parse error: {}", .{err});
            };
            self.markDirty();
        }

        log.debug("drainOutputForMs: done, {d} bytes total in {d}ms", .{ total_bytes, std.time.milliTimestamp() - start_ms });
    }
};

/// Returns the AgentKind for a given PID by inspecting its process name via sysctl.
/// Falls back to KERN_PROCARGS2 for Node.js wrappers.
fn detectAgentByPid(pid: posix.pid_t) ?AgentKind {
    if (builtin.os.tag != .macos) return null;
    const mib = [_]c_int{ mac.CTL_KERN, mac.KERN_PROC, mac.KERN_PROC_PID, pid };
    var info: mac.kinfo_proc = undefined;
    var size: usize = @sizeOf(mac.kinfo_proc);
    if (mac.sysctl(@constCast(&mib), mib.len, &info, &size, null, 0) != 0) {
        log.debug("detectAgentByPid: sysctl failed for pid={d}", .{pid});
        return null;
    }
    if (size < @sizeOf(mac.kinfo_proc)) {
        log.debug("detectAgentByPid: sysctl returned incomplete struct for pid={d}", .{pid});
        return null;
    }

    const comm = std.mem.sliceTo(&info.kp_proc.p_comm, 0);
    log.debug("detectAgentByPid: pid={d} p_comm={s}", .{ pid, comm });

    if (AgentKind.fromComm(comm)) |kind| return kind;

    // Try proc_pidpath for the full executable path. More reliable than KERN_PROCARGS2 on
    // macOS Sequoia, where KERN_PROCARGS2 may return zeroed data without a special entitlement.
    // This covers bundled runtimes like claude, whose p_comm is a version string ("2.1.50")
    // but whose exec path contains "claude".
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_len = proc_pidpath(@intCast(pid), &path_buf, path_buf.len);
    if (path_len > 0) {
        const exec_path = path_buf[0..@intCast(path_len)];
        log.debug("detectAgentByPid: proc_pidpath={s}", .{exec_path});
        if (AgentKind.fromPath(exec_path)) |kind| return kind;
    }

    // Fall back to KERN_PROCARGS2 for argv[1] (Node.js wrappers where the exec path is
    // just "node" but argv[1] names the agent script). This may return zeroed data on
    // Sequoia; if so, the OSC 1 icon set by the agent is used as a fallback at the call site.
    const result = detectAgentFromArgv(pid);
    log.debug("detectAgentByPid: argv scan for p_comm={s} result={?}", .{ comm, result });
    return result;
}

/// Reads KERN_PROCARGS2 for a process and delegates to parseArgv.
fn detectAgentFromArgv(pid: posix.pid_t) ?AgentKind {
    if (builtin.os.tag != .macos) return null;
    const mib = [_]c_int{ mac.CTL_KERN, mac.KERN_PROCARGS2, pid };
    var buf: [4096]u8 = undefined;
    var size: usize = buf.len;
    if (mac.sysctl(@constCast(&mib), mib.len, &buf, &size, null, 0) != 0) return null;
    return parseArgv(buf[0..size], size);
}

/// Scans raw PTY output bytes for an OSC 1 sequence naming a known AI agent.
/// Pattern: ESC ] 1 ; <name> BEL  or  ESC ] 1 ; <name> ST (ESC \)
/// Returns the first matching AgentKind found, or null if none.
fn scanOsc1Agent(data: []const u8) ?AgentKind {
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] != 0x1b or data[i + 1] != ']' or data[i + 2] != '1' or data[i + 3] != ';') continue;
        i += 4;
        const name_start = i;
        while (i < data.len and data[i] != 0x07) : (i += 1) {
            // Also stop at ST (ESC \)
            if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') break;
        }
        const icon = data[name_start..i];
        if (AgentKind.fromComm(icon)) |kind| return kind;
    }
    return null;
}

fn basenameForDisplay(path: []const u8) []const u8 {
    if (builtin.os.tag == .macos) {
        return cwd_mod.getBasename(path);
    }
    return fs.path.basename(path);
}

fn sliceToZ(input: [:0]const u8) []const u8 {
    return std.mem.sliceTo(input, 0);
}

fn getForegroundPgrp(child_pid: posix.pid_t) ?posix.pid_t {
    if (builtin.os.tag != .macos) return null;
    const mib = [_]c_int{ mac.CTL_KERN, mac.KERN_PROC, mac.KERN_PROC_PID, child_pid };
    var info: mac.kinfo_proc = undefined;
    var size: usize = @sizeOf(mac.kinfo_proc);
    if (mac.sysctl(@constCast(&mib), mib.len, &info, &size, null, 0) != 0) return null;
    if (size < @sizeOf(mac.kinfo_proc)) return null;
    return info.kp_eproc.e_tpgid;
}

pub const MakeNonBlockingError = posix.FcntlError;

test "SessionState assigns incrementing ids" {
    const allocator = std.testing.allocator;
    next_session_id.store(0, .seq_cst);

    const size = pty_mod.winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const notify_sock: [:0]const u8 = "sock";

    var first = try SessionState.init(allocator, 0, "/bin/zsh", size, notify_sock);
    defer first.deinit(allocator);
    first.assignNewSessionId();
    try std.testing.expectEqual(@as(usize, 0), first.id);
    try std.testing.expectEqualStrings("0", std.mem.sliceTo(first.session_id_z[0..], 0));

    var second = try SessionState.init(allocator, 1, "/bin/zsh", size, notify_sock);
    defer second.deinit(allocator);
    second.assignNewSessionId();
    try std.testing.expectEqual(@as(usize, 1), second.id);
    try std.testing.expectEqualStrings("1", std.mem.sliceTo(second.session_id_z[0..], 0));
}

fn makeNonBlocking(fd: posix.fd_t) MakeNonBlockingError!void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}

fn maybeShrinkPendingWrite(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
    if (buf.items.len == 0 and buf.capacity > pending_write_shrink_threshold) {
        buf.shrinkAndFree(allocator, 0);
    }
}

test "pending write shrinks when empty and over threshold" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.ensureTotalCapacity(allocator, pending_write_shrink_threshold + 10);
    buf.items.len = pending_write_shrink_threshold + 10;
    buf.clearRetainingCapacity();

    const before = buf.capacity;
    try std.testing.expect(before > pending_write_shrink_threshold);

    maybeShrinkPendingWrite(&buf, allocator);
    try std.testing.expect(buf.capacity <= pending_write_shrink_threshold);
}

test "AgentKind.fromComm recognises known agent names" {
    try std.testing.expectEqual(AgentKind.claude, AgentKind.fromComm("claude").?);
    try std.testing.expectEqual(AgentKind.codex, AgentKind.fromComm("codex").?);
    try std.testing.expectEqual(AgentKind.gemini, AgentKind.fromComm("gemini").?);
    try std.testing.expect(AgentKind.fromComm("node") == null);
    try std.testing.expect(AgentKind.fromComm("") == null);
    try std.testing.expect(AgentKind.fromComm("python") == null);
}

test "AgentKind.fromString round-trips through name()" {
    inline for (.{ AgentKind.claude, AgentKind.codex, AgentKind.gemini }) |kind| {
        const s = kind.name();
        try std.testing.expectEqual(kind, AgentKind.fromString(s).?);
    }
}

test "AgentKind.exitControlSequence uses double ctrl-c for all agents" {
    try std.testing.expectEqualStrings("\x03\x03", AgentKind.claude.exitControlSequence());
    try std.testing.expectEqualStrings("\x03\x03", AgentKind.codex.exitControlSequence());
    try std.testing.expectEqualStrings("\x03\x03", AgentKind.gemini.exitControlSequence());
}

test "parseArgv matches agent name in argv[1] (Node.js wrapper)" {
    // Layout: [argc i32][exec_path\0][argv0\0][argv1\0]
    const build = struct {
        fn blob(argc: i32, exec: []const u8, argv0: []const u8, argv1: []const u8) [512]u8 {
            var buf = [_]u8{0} ** 512;
            std.mem.writeInt(i32, buf[0..4], argc, .little);
            var pos: usize = 4;
            @memcpy(buf[pos..][0..exec.len], exec);
            pos += exec.len;
            pos += 1; // null after exec_path
            @memcpy(buf[pos..][0..argv0.len], argv0);
            pos += argv0.len;
            pos += 1; // null after argv0
            @memcpy(buf[pos..][0..argv1.len], argv1);
            return buf;
        }
    };

    const claude_blob = build.blob(3, "/usr/local/bin/node", "node", "/usr/local/lib/node_modules/@anthropic/claude/bin/claude");
    try std.testing.expectEqual(AgentKind.claude, parseArgv(&claude_blob, claude_blob.len).?);

    const codex_blob = build.blob(2, "/usr/local/bin/node", "node", "/home/user/.npm/bin/codex");
    try std.testing.expectEqual(AgentKind.codex, parseArgv(&codex_blob, codex_blob.len).?);

    const gemini_blob = build.blob(2, "/usr/local/bin/node", "node", "/usr/local/bin/gemini-cli");
    try std.testing.expectEqual(AgentKind.gemini, parseArgv(&gemini_blob, gemini_blob.len).?);

    const unknown_blob = build.blob(2, "/usr/local/bin/node", "node", "/usr/local/bin/some-other-tool");
    try std.testing.expect(parseArgv(&unknown_blob, unknown_blob.len) == null);

    const no_argv1_blob = build.blob(1, "/usr/local/bin/node", "node", "");
    try std.testing.expect(parseArgv(&no_argv1_blob, no_argv1_blob.len) == null);
}

test "parseArgv matches agent name in exec_path (bundled runtime)" {
    // Covers bundled CLIs whose p_comm is a version string (e.g. "2.1.50") and the
    // agent name only appears in the full executable path, not in argv[1].
    const build = struct {
        fn blob(argc: i32, exec: []const u8, argv0: []const u8) [512]u8 {
            var buf = [_]u8{0} ** 512;
            std.mem.writeInt(i32, buf[0..4], argc, .little);
            var pos: usize = 4;
            @memcpy(buf[pos..][0..exec.len], exec);
            pos += exec.len;
            pos += 1;
            @memcpy(buf[pos..][0..argv0.len], argv0);
            return buf;
        }
    };

    const claude_bundled = build.blob(1, "/Users/me/.local/share/claude/2.1.50", "2.1.50");
    try std.testing.expectEqual(AgentKind.claude, parseArgv(&claude_bundled, claude_bundled.len).?);

    const codex_bundled = build.blob(1, "/Users/me/.npm-global/lib/node_modules/codex/dist/cli", "cli");
    try std.testing.expectEqual(AgentKind.codex, parseArgv(&codex_bundled, codex_bundled.len).?);

    const gemini_bundled = build.blob(1, "/Users/me/.local/bin/gemini", "gemini");
    try std.testing.expectEqual(AgentKind.gemini, parseArgv(&gemini_bundled, gemini_bundled.len).?);

    const unknown_bundled = build.blob(1, "/usr/local/bin/python3", "python3");
    try std.testing.expect(parseArgv(&unknown_bundled, unknown_bundled.len) == null);
}

/// Pure parsing logic for KERN_PROCARGS2 blobs, extracted for testability.
/// Checks exec_path first (covers bundled runtimes whose binary path names the agent),
/// then argv[1] (covers Node.js wrappers where the script path names the agent).
fn parseArgv(buf: []const u8, size: usize) ?AgentKind {
    if (size < 4) return null;
    const argc = std.mem.readInt(i32, buf[0..4], .little);
    log.debug("parseArgv: argc={d} size={d} buf[4..12]={any}", .{ argc, size, buf[4..@min(12, size)] });

    var pos: usize = 4;

    // exec_path: full path to the executable
    const exec_start = pos;
    while (pos < size and buf[pos] != 0) : (pos += 1) {}
    const exec_path = buf[exec_start..pos];
    if (pos >= size) return null;
    pos += 1;

    log.debug("parseArgv: exec_path={s}", .{exec_path});

    if (std.mem.indexOf(u8, exec_path, "claude") != null) return .claude;
    if (std.mem.indexOf(u8, exec_path, "codex") != null) return .codex;
    if (std.mem.indexOf(u8, exec_path, "gemini") != null) return .gemini;

    if (argc < 2) return null;

    // skip padding nulls after exec_path
    while (pos < size and buf[pos] == 0) : (pos += 1) {}
    // skip argv[0] (process name)
    while (pos < size and buf[pos] != 0) : (pos += 1) {}
    if (pos >= size) return null;
    pos += 1;
    if (pos >= size) return null;

    // argv[1]: script path for Node.js wrappers
    const argv1_start = pos;
    while (pos < size and buf[pos] != 0) : (pos += 1) {}
    const argv1 = buf[argv1_start..pos];

    log.debug("parseArgv: argv[1]={s}", .{argv1});

    if (std.mem.indexOf(u8, argv1, "claude") != null) return .claude;
    if (std.mem.indexOf(u8, argv1, "codex") != null) return .codex;
    if (std.mem.indexOf(u8, argv1, "gemini") != null) return .gemini;
    return null;
}
