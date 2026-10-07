const input = @import("../input/mapper.zig");
const session_state = @import("../session/state.zig");
const c = @import("../c.zig");
const std = @import("std");
const app_state = @import("app_state.zig");

const SessionState = session_state.SessionState;

pub const KeyTarget = struct {
    session_id: usize,
    process_generation: usize,
    key: c.SDL_Keycode,

    pub fn matches(self: KeyTarget, session: *const SessionState) bool {
        return session.id == self.session_id and session.process_generation == self.process_generation;
    }
};

pub const TerminalKeyPresses = struct {
    pressed: [c.SDL_SCANCODE_COUNT]?KeyTarget = @splat(null),

    pub fn beginPress(self: *TerminalKeyPresses, event: *const c.SDL_Event) void {
        if (!event.key.repeat) _ = self.take(event.key.scancode);
    }

    pub fn get(self: *const TerminalKeyPresses, scancode: c.SDL_Scancode) ?KeyTarget {
        const index = scancodeIndex(scancode) orelse return null;
        return self.pressed[index];
    }

    pub fn take(self: *TerminalKeyPresses, scancode: c.SDL_Scancode) ?KeyTarget {
        const index = scancodeIndex(scancode) orelse return null;
        const target = self.pressed[index];
        self.pressed[index] = null;
        return target;
    }

    pub fn handlePress(self: *TerminalKeyPresses, focused: *SessionState, event: *const c.SDL_Event) !void {
        if (event.key.repeat) return;
        if (try handleKeyInput(focused, event.key.key, event.key.mod, .press)) {
            if (scancodeIndex(event.key.scancode)) |index| {
                self.pressed[index] = .{ .session_id = focused.id, .process_generation = focused.process_generation, .key = event.key.key };
            }
        }
    }

    fn scancodeIndex(scancode: c.SDL_Scancode) ?usize {
        if (scancode <= c.SDL_SCANCODE_UNKNOWN or scancode >= c.SDL_SCANCODE_COUNT) return null;
        return @intCast(scancode);
    }
};

pub const DeferredEscape = struct {
    mod: c.SDL_Keymod = 0,
    target: ?KeyTarget = null,

    pub fn observePress(self: *DeferredEscape, key: c.SDL_Keycode, mod: c.SDL_Keymod, repeat: bool) void {
        if (key == c.SDLK_ESCAPE and !repeat) {
            self.mod = mod;
            self.target = null;
        }
    }

    pub fn arm(self: *DeferredEscape, session: *const SessionState) void {
        self.target = .{ .session_id = session.id, .process_generation = session.process_generation, .key = c.SDLK_ESCAPE };
    }

    pub fn take(self: *DeferredEscape) ?KeyTarget {
        const target = self.target;
        self.target = null;
        return target;
    }

    pub fn release(self: *DeferredEscape, sessions: []const *SessionState, mode: app_state.ViewMode) !void {
        const target = self.take() orelse return;
        if (!self.shouldSend(mode)) return;
        try sendToTarget(sessions, target, self.mod, .press);
        try sendToTarget(sessions, target, self.mod, .release);
    }

    pub fn shouldSend(self: DeferredEscape, mode: app_state.ViewMode) bool {
        return input.canHandleEscapePress(mode) or
            (self.mod & (c.SDL_KMOD_SHIFT | c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_GUI)) != 0;
    }
};

test "deferred escape retains press modifiers until release" {
    var escape: DeferredEscape = .{};
    escape.observePress(c.SDLK_ESCAPE, c.SDL_KMOD_SHIFT, false);
    escape.observePress(c.SDLK_LSHIFT, 0, false);
    escape.observePress(c.SDLK_ESCAPE, 0, true);
    try std.testing.expectEqual(@as(c.SDL_Keymod, c.SDL_KMOD_SHIFT), escape.mod);
    escape.observePress(c.SDLK_ESCAPE, 0, false);
    try std.testing.expectEqual(@as(c.SDL_Keymod, 0), escape.mod);
}

test "modified escape reaches the terminal in grid and transition modes" {
    var escape: DeferredEscape = .{};
    for ([_]app_state.ViewMode{ .Grid, .Collapsing, .GridResizing }) |mode| {
        try std.testing.expect(!escape.shouldSend(mode));
        for ([_]c.SDL_Keymod{ c.SDL_KMOD_SHIFT, c.SDL_KMOD_CTRL, c.SDL_KMOD_ALT, c.SDL_KMOD_GUI }) |mod| {
            escape.observePress(c.SDLK_ESCAPE, mod, false);
            try std.testing.expect(escape.shouldSend(mode));
        }
        escape.observePress(c.SDLK_ESCAPE, 0, false);
    }
}

pub fn isModifierKey(key: c.SDL_Keycode) bool {
    return key == c.SDLK_LSHIFT or key == c.SDLK_RSHIFT or
        key == c.SDLK_LCTRL or key == c.SDLK_RCTRL or
        key == c.SDLK_LALT or key == c.SDLK_RALT or
        key == c.SDLK_LGUI or key == c.SDLK_RGUI;
}

pub fn sendToTarget(sessions: []const *SessionState, target: KeyTarget, mod: c.SDL_Keymod, action: input.KeyAction) !void {
    for (sessions) |session| {
        if (target.matches(session)) {
            _ = try handleKeyInput(session, target.key, mod, action);
            return;
        }
    }
}

pub fn handleKeyInput(focused: *SessionState, key: c.SDL_Keycode, mod: c.SDL_Keymod, action: input.KeyAction) !bool {
    if (!focused.spawned or focused.dead or focused.shell == null) return false;
    var options: input.KeyEncodingOptions = if (focused.terminal) |*terminal|
        .fromTerminal(terminal)
    else
        .default;
    options.macos_option_as_alt = .true;

    var buf: [64]u8 = undefined;
    const n = try input.encodeKeyEvent(key, mod, action, options, &buf);
    if (n > 0) {
        try focused.sendInput(buf[0..n]);
    }
    return n > 0;
}

const KeyInputTestSession = struct {
    session: SessionState,
    pipe_fds: [2]std.posix.fd_t,

    fn init(id: usize, kitty_flags: []const u8) !KeyInputTestSession {
        const posix_util = @import("../posix_util.zig");
        var self: KeyInputTestSession = .{ .session = undefined, .pipe_fds = undefined };
        try posix_util.pipe(&self.pipe_fds);
        errdefer _ = std.c.close(self.pipe_fds[0]);
        errdefer _ = std.c.close(self.pipe_fds[1]);
        _ = try posix_util.fcntl(self.pipe_fds[0], std.posix.F.SETFL, @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        self.session.id = id;
        self.session.process_generation = 1;
        self.session.spawned = true;
        self.session.dead = false;
        self.session.allocator = std.testing.allocator;
        self.session.io = std.testing.io;
        self.session.pending_write = .empty;
        self.session.shell = .{ .io = std.testing.io, .pty = .{ .master = self.pipe_fds[1], .slave = self.pipe_fds[0] }, .child_pid = -1 };
        var terminal = try @import("ghostty-vt").Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 10, .rows = 3 });
        {
            var stream = terminal.vtStream();
            defer stream.deinit();
            stream.nextSlice(kitty_flags);
        }
        self.session.terminal = terminal;
        return self;
    }

    fn deinit(self: *KeyInputTestSession) void {
        if (self.session.terminal) |*terminal| terminal.deinit(std.testing.allocator);
        self.session.pending_write.deinit(std.testing.allocator);
        _ = std.c.close(self.pipe_fds[0]);
        _ = std.c.close(self.pipe_fds[1]);
    }

    fn expectOutput(self: *KeyInputTestSession, expected: []const u8) !void {
        var buf: [256]u8 = undefined;
        const n = std.c.read(self.pipe_fds[0], &buf, buf.len);
        if (expected.len == 0) {
            try std.testing.expectEqual(@as(isize, -1), n);
            try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(n));
        } else {
            if (n < 0) return error.PipeReadFailed;
            try std.testing.expectEqualSlices(u8, expected, buf[0..@intCast(n)]);
        }
    }
};

test "terminal key ownership preserves repeats and releases across focus changes" {
    var original = try KeyInputTestSession.init(7, "\x1b[>3u");
    defer original.deinit();
    var other = try KeyInputTestSession.init(8, "\x1b[>3u");
    defer other.deinit();
    const sessions = [_]*SessionState{ &other.session, &original.session };
    const cases = [_]struct { key: c.SDL_Keycode, scancode: c.SDL_Scancode, expected: []const u8 }{
        .{ .key = c.SDLK_LEFT, .scancode = c.SDL_SCANCODE_LEFT, .expected = "\x1b[1;2:1D\x1b[1;2:2D\x1b[1;1:3D" },
        .{ .key = c.SDLK_ESCAPE, .scancode = c.SDL_SCANCODE_ESCAPE, .expected = "\x1b[27;2u\x1b[27;2:2u\x1b[27;1:3u" },
    };
    for (cases) |case| {
        var keys: TerminalKeyPresses = .{};
        var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_KEY_DOWN;
        event.key.key = case.key;
        event.key.scancode = case.scancode;
        event.key.mod = c.SDL_KMOD_LSHIFT;
        keys.beginPress(&event);
        try keys.handlePress(&original.session, &event);
        event.key.repeat = true;
        keys.beginPress(&event);
        const repeated = keys.get(event.key.scancode) orelse return error.TestUnexpectedResult;
        try sendToTarget(&sessions, repeated, event.key.mod, .repeat);
        const released = keys.take(event.key.scancode) orelse return error.TestUnexpectedResult;
        try sendToTarget(&sessions, released, 0, .release);
        try original.expectOutput(case.expected);
        try other.expectOutput("");
        try std.testing.expect(keys.take(event.key.scancode) == null);
    }
}

test "app-consumed and text presses do not produce terminal releases" {
    var fixture = try KeyInputTestSession.init(7, "\x1b[>3u");
    defer fixture.deinit();
    var keys: TerminalKeyPresses = .{};
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.key.key = c.SDLK_LEFT;
    event.key.scancode = c.SDL_SCANCODE_LEFT;
    keys.beginPress(&event);
    try keys.handlePress(&fixture.session, &event);
    try fixture.expectOutput("\x1b[1;1:1D");
    // A new press consumed by the app must invalidate any previous ownership.
    keys.beginPress(&event);
    try std.testing.expect(keys.take(event.key.scancode) == null);
    event.key.repeat = true;
    try keys.handlePress(&fixture.session, &event);
    event.key.repeat = false;
    event.key.key = c.SDLK_A;
    try keys.handlePress(&fixture.session, &event);
    try std.testing.expect(keys.take(event.key.scancode) == null);
    try fixture.expectOutput("");
    try std.testing.expect(keys.take(c.SDL_SCANCODE_UNKNOWN) == null);
    try std.testing.expect(keys.take(c.SDL_SCANCODE_COUNT) == null);
}

test "key events cannot reach a restarted or removed session" {
    var fixture = try KeyInputTestSession.init(7, "\x1b[>3u");
    defer fixture.deinit();
    const sessions = [_]*SessionState{&fixture.session};
    const target: KeyTarget = .{ .session_id = fixture.session.id, .process_generation = fixture.session.process_generation, .key = c.SDLK_LEFT };
    fixture.session.process_generation += 1;
    try sendToTarget(&sessions, target, 0, .release);
    try sendToTarget(&.{}, target, 0, .repeat);
    try fixture.expectOutput("");
}

test "plain escape sends a deferred press release pair only for a short tap" {
    for ([_][]const u8{ "", "\x1b[>3u" }) |flags| {
        var fixture = try KeyInputTestSession.init(7, flags);
        defer fixture.deinit();
        const sessions = [_]*SessionState{&fixture.session};
        var escape: DeferredEscape = .{};
        escape.observePress(c.SDLK_ESCAPE, 0, false);
        escape.arm(&fixture.session);
        try escape.release(&sessions, .Full);
        const expected = if (flags.len == 0) "\x1b" else "\x1b[27u\x1b[27;1:3u";
        try fixture.expectOutput(expected);
        try escape.release(&sessions, .Full);
        escape.arm(&fixture.session);
        _ = escape.take();
        try escape.release(&sessions, .Full);
        escape.arm(&fixture.session);
        try escape.release(&sessions, .Grid);
        try fixture.expectOutput("");
    }
}
