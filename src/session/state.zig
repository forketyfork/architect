const std = @import("std");
const posix = std.posix;
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("../shell.zig");
const pty_mod = @import("../pty.zig");
const app_state = @import("../app/app_state.zig");
const c = @import("../c.zig");

const log = std.log.scoped(.session_state);

const VtStreamType = blk: {
    const T = ghostty_vt.Terminal;
    const fn_info = @typeInfo(@TypeOf(T.vtStream)).@"fn";
    break :blk fn_info.return_type.?;
};

pub const SessionState = struct {
    id: usize,
    shell: ?shell_mod.Shell,
    terminal: ?ghostty_vt.Terminal,
    stream: ?VtStreamType,
    output_buf: [4096]u8,
    status: app_state.SessionStatus = .running,
    attention: bool = false,
    is_scrolled: bool = false,
    dirty: bool = true,
    cache_texture: ?*c.SDL_Texture = null,
    cache_w: c_int = 0,
    cache_h: c_int = 0,
    spawned: bool = false,
    shell_path: []const u8,
    pty_size: pty_mod.winsize,
    session_id_z: [16:0]u8,
    notify_sock_z: [:0]const u8,
    allocator: std.mem.Allocator,

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
        self.stream = self.terminal.?.vtStream();
        self.dirty = true;

        log.debug("spawned session {d}", .{self.id});

        self.processOutput() catch {};
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        if (self.cache_texture) |tex| {
            c.SDL_DestroyTexture(tex);
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

    pub const ProcessOutputError = posix.ReadError || error{
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

    pub fn processOutput(self: *SessionState) ProcessOutputError!void {
        if (!self.spawned) return;

        const shell = &(self.shell orelse return);
        const stream = &(self.stream orelse return);

        const n = shell.read(&self.output_buf) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (n > 0) {
            try stream.nextSlice(self.output_buf[0..n]);
            self.dirty = true;
        }
    }
};

pub const MakeNonBlockingError = posix.FcntlError;

fn makeNonBlocking(fd: posix.fd_t) MakeNonBlockingError!void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}
