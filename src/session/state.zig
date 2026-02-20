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

const log = std.log.scoped(.session_state);

extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;
extern "c" fn ptsname(fd: posix.fd_t) ?[*:0]const u8;

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
            if (ctx.completion.state() == .dead) {
                allocator.destroy(ctx);
            }
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
};

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
