const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("../shell.zig");
const pty_mod = @import("../pty.zig");
const app_state = @import("../app/app_state.zig");
const c = @import("../c.zig");
const cwd_mod = if (builtin.os.tag == .macos) @import("../cwd.zig") else struct {};
const vt_stream = @import("../vt_stream.zig");

const log = std.log.scoped(.session_state);

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
        if (self.spawned) return;

        const shell = try shell_mod.Shell.spawn(
            self.shell_path,
            self.pty_size,
            &self.session_id_z,
            self.notify_sock_z,
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

        log.debug("spawned session {d}", .{self.id});

        self.processOutput() catch {};
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        if (self.cache_texture) |tex| {
            c.SDL_DestroyTexture(tex);
        }
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
};

pub const MakeNonBlockingError = posix.FcntlError;

fn makeNonBlocking(fd: posix.fd_t) MakeNonBlockingError!void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}
