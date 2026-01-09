const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const xev = @import("xev");
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("../shell.zig");
const pty_mod = @import("../pty.zig");
const app_state = @import("../app/app_state.zig");
const c = @import("../c.zig");
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

const PENDING_WRITE_SHRINK_THRESHOLD: usize = 64 * 1024;

pub const SessionState = struct {
    id: usize,
    shell: ?shell_mod.Shell,
    terminal: ?ghostty_vt.Terminal,
    stream: ?vt_stream.StreamType,
    output_buf: [4096]u8,
    status: app_state.SessionStatus = .running,
    attention: bool = false,
    is_scrolled: bool = false,
    dirty: bool = true,
    cache_texture: ?*c.SDL_Texture = null,
    cache_w: c_int = 0,
    cache_h: c_int = 0,
    cwd_font: ?*c.TTF_Font = null,
    cwd_basename_tex: ?*c.SDL_Texture = null,
    cwd_parent_tex: ?*c.SDL_Texture = null,
    cwd_basename_w: c_int = 0,
    cwd_basename_h: c_int = 0,
    cwd_parent_w: c_int = 0,
    cwd_parent_h: c_int = 0,
    cwd_font_size: c_int = 0,
    cwd_dirty: bool = true,
    spawned: bool = false,
    dead: bool = false,
    shell_path: []const u8,
    pty_size: pty_mod.winsize,
    session_id_z: [16:0]u8,
    notify_sock_z: [:0]const u8,
    allocator: std.mem.Allocator,
    cwd_path: ?[]const u8 = null,
    /// Subslice of cwd_path pointing to the basename. Always points within cwd_path's memory.
    /// When cwd_path is freed, this becomes invalid and must not be used.
    cwd_basename: ?[]const u8 = null,
    cwd_last_check: i64 = 0,
    scroll_velocity: f32 = 0.0,
    scroll_remainder: f32 = 0.0,
    last_scroll_time: i64 = 0,
    /// Whether custom inertia should be applied after the most recent scroll event.
    scroll_inertia_allowed: bool = true,
    /// Selection anchor for in-progress drags.
    selection_anchor: ?ghostty_vt.Pin = null,
    selection_dragging: bool = false,
    /// True while the primary button is held down and we're waiting to see if it turns into a drag.
    selection_pending: bool = false,
    /// Hovered link range (for underlining).
    hovered_link_start: ?ghostty_vt.Pin = null,
    hovered_link_end: ?ghostty_vt.Pin = null,
    pending_write: std.ArrayListUnmanaged(u8) = .empty,
    /// Process watcher for event-driven exit detection.
    process_watcher: ?xev.Process = null,
    /// Completion structure for process wait callback.
    process_completion: xev.Completion = .{},

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
        id: usize,
        shell_path: []const u8,
        size: pty_mod.winsize,
        session_id_z: [:0]const u8,
        notify_sock: [:0]const u8,
    ) InitError!SessionState {
        var session_id_buf: [16:0]u8 = undefined;
        @memcpy(session_id_buf[0..session_id_z.len], session_id_z);
        session_id_buf[session_id_z.len] = 0;

        return SessionState{
            .id = id,
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
        self.cwd_dirty = true;
        self.dirty = true;

        if (loop_opt) |loop| {
            var process = try xev.Process.init(shell.child_pid);
            errdefer process.deinit();

            process.wait(
                loop,
                &self.process_completion,
                SessionState,
                self,
                processExitCallback,
            );

            self.process_watcher = process;
        }

        log.debug("spawned session {d}", .{self.id});

        self.processOutput() catch {};
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        if (self.cache_texture) |tex| {
            c.SDL_DestroyTexture(tex);
        }
        self.pending_write.deinit(allocator);
        if (self.cwd_basename_tex) |tex| {
            c.SDL_DestroyTexture(tex);
            self.cwd_basename_tex = null;
        }
        if (self.cwd_parent_tex) |tex| {
            c.SDL_DestroyTexture(tex);
            self.cwd_parent_tex = null;
        }
        if (self.cwd_font) |font| {
            c.TTF_CloseFont(font);
        }
        if (self.cwd_path) |path| {
            allocator.free(path);
        }
        if (self.process_watcher) |*watcher| {
            watcher.deinit();
        }
        if (self.spawned) {
            if (self.stream) |*stream| {
                stream.deinit();
            }
            if (self.terminal) |*terminal| {
                terminal.deinit(allocator);
            }
            if (self.shell) |*shell| {
                shell.deinit();
            }
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
        StringAllocOutOfMemory,
        StyleSetNeedsRehash,
        StyleSetOutOfMemory,
    };

    fn processExitCallback(
        self_opt: ?*SessionState,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Process.WaitError!u32,
    ) xev.CallbackAction {
        const self = self_opt orelse return .disarm;
        const exit_code = r catch |err| {
            log.err("process wait error for session {d}: {}", .{ self.id, err });
            return .disarm;
        };

        self.dead = true;
        self.dirty = true;
        log.info("session {d} process exited with code {d}", .{ self.id, exit_code });

        return .disarm;
    }

    pub fn checkAlive(self: *SessionState) void {
        if (!self.spawned or self.dead) return;

        if (self.shell) |shell| {
            var status: c_int = 0;
            const result = std.c.waitpid(shell.child_pid, &status, std.c.W.NOHANG);
            if (result > 0) {
                self.dead = true;
                self.dirty = true;
                log.info("session {d} process exited", .{self.id});
            }
        }
    }

    pub fn restart(self: *SessionState) InitError!void {
        if (self.spawned and !self.dead) return;

        self.clearSelection();
        self.pending_write.clearAndFree(self.allocator);
        if (self.process_watcher) |*watcher| {
            watcher.deinit();
            self.process_watcher = null;
        }
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
        self.scroll_velocity = 0.0;
        self.scroll_remainder = 0.0;
        self.last_scroll_time = 0;
        try self.ensureSpawned();
    }

    pub fn clearSelection(self: *SessionState) void {
        self.selection_anchor = null;
        self.selection_dragging = false;
        self.selection_pending = false;
        if (!self.spawned) return;
        if (self.terminal) |*terminal| {
            terminal.screens.active.clearSelection();
            self.dirty = true;
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
            self.dirty = true;

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

        self.cwd_path = new_path;
        self.cwd_basename = cwd_mod.getBasename(new_path);
        self.cwd_dirty = true;
        self.dirty = true;
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

fn makeNonBlocking(fd: posix.fd_t) MakeNonBlockingError!void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}

fn maybeShrinkPendingWrite(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
    if (buf.items.len == 0 and buf.capacity > PENDING_WRITE_SHRINK_THRESHOLD) {
        buf.shrinkAndFree(allocator, 0);
    }
}

test "pending write shrinks when empty and over threshold" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.ensureTotalCapacity(allocator, PENDING_WRITE_SHRINK_THRESHOLD + 10);
    buf.items.len = PENDING_WRITE_SHRINK_THRESHOLD + 10;
    buf.clearRetainingCapacity();

    const before = buf.capacity;
    try std.testing.expect(before > PENDING_WRITE_SHRINK_THRESHOLD);

    maybeShrinkPendingWrite(&buf, allocator);
    try std.testing.expect(buf.capacity <= PENDING_WRITE_SHRINK_THRESHOLD);
}
