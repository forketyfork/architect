//! Main-thread handlers for the control operations that read or write
//! terminal sessions on behalf of external orchestrators (`list_sessions`,
//! `send_input`), plus the glue that feeds session liveness and agent-hook
//! signals into the agent-state board read by the control listener.

const std = @import("std");
const app_state = @import("app_state.zig");
const control = @import("control.zig");
const agent_state = @import("agent_state.zig");
const session_state = @import("../session/state.zig");
const terminal_actions = @import("terminal_actions.zig");

const SessionState = session_state.SessionState;
const log = std.log.scoped(.agent_control);

pub fn hookSignal(status: app_state.SessionStatus) ?agent_state.HookSignal {
    return switch (status) {
        .running => .start,
        .awaiting_approval => .awaiting_approval,
        .done => .done,
        .idle => null,
    };
}

/// Feeds the current session liveness into the board. `scratch` is reused
/// across frames so steady-state reconciliation does not allocate.
pub fn reconcileBoard(
    allocator: std.mem.Allocator,
    io: std.Io,
    board: *agent_state.Board,
    sessions: []const *SessionState,
    scratch: *std.ArrayList(agent_state.LiveSession),
) void {
    scratch.clearRetainingCapacity();
    for (sessions) |session| {
        if (!session.spawned) continue;
        scratch.append(allocator, .{ .session_id = session.id, .alive = !session.dead }) catch |err| {
            log.warn("failed to collect live sessions for the agent board: {}", .{err});
            return;
        };
    }
    board.reconcile(allocator, io, scratch.items) catch |err| {
        log.warn("failed to reconcile the agent board: {}", .{err});
    };
}

pub fn listSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: []const *SessionState,
    board: *agent_state.Board,
    completion: *control.Completion,
) void {
    var infos: std.ArrayList(control.SessionInfo) = .empty;
    defer infos.deinit(allocator);

    for (sessions) |session| {
        if (!session.spawned) continue;
        const record = trackedRecord(allocator, io, board, session.id) orelse {
            completion.fail(io, .internal_error, "failed to track the session's agent state");
            return;
        };
        const agent = session.detectForegroundAgent();
        infos.append(allocator, .{
            .session_id = session.id,
            .slot_index = session.slot_index,
            .cwd = session.cwd_path,
            .foreground_agent = if (agent) |kind| kind.name() else null,
            .agent_state = record.state,
            .state_seq = record.seq,
        }) catch |err| {
            log.warn("failed to collect session info: {}", .{err});
            completion.fail(io, .internal_error, "out of memory while listing sessions");
            return;
        };
    }

    completion.succeed(allocator, io, control.ListResult, .{ .sessions = infos.items });
}

/// Writes the request's text into the session and completes the request.
/// Returns the slot index of the session that received input.
pub fn sendInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: []const *SessionState,
    board: *agent_state.Board,
    request: control.SendInputRequest,
    completion: *control.Completion,
) ?usize {
    const session = findSpawnedSession(sessions, request.session_id) orelse {
        if (board.get(io, request.session_id)) |record| {
            if (record.state == .exited) {
                completion.fail(io, .session_exited, "the session has exited");
                return null;
            }
        }
        completion.fail(io, .session_not_found, "no Architect session has this id");
        return null;
    };
    if (session.dead) {
        completion.fail(io, .session_exited, "the session has exited");
        return null;
    }

    const record = trackedRecord(allocator, io, board, session.id) orelse {
        completion.fail(io, .internal_error, "failed to track the session's agent state");
        return null;
    };
    if (request.require_idle and record.state != .idle) {
        completion.fail(io, .session_busy, "the agent is not idle");
        return null;
    }

    const payload = terminal_actions.buildInputPayload(allocator, session, request.text, request.submit) catch |err| {
        switch (err) {
            error.BracketedPasteUnavailable => completion.fail(
                io,
                .input_not_ready,
                "the terminal has not enabled bracketed paste, so multi-line text would be submitted line by line",
            ),
            error.NoShell, error.NoTerminal => completion.fail(io, .input_not_ready, "the terminal is not ready for input"),
            error.OutOfMemory => completion.fail(io, .internal_error, "out of memory while encoding the input"),
        }
        return null;
    };
    defer allocator.free(payload.bytes);

    session.sendInput(payload.bytes) catch |err| {
        log.warn("failed to send input to session {d}: {}", .{ session.id, err });
        completion.fail(io, .input_failed, "failed to write to the terminal");
        return null;
    };

    const seq = board.markDelivered(io, session.id) orelse {
        completion.fail(io, .internal_error, "the session's agent state disappeared during delivery");
        return null;
    };
    completion.succeed(allocator, io, control.SendResult, .{
        .session_id = session.id,
        .state_seq = seq,
        .bracketed_paste = payload.bracketed,
    });
    return session.slot_index;
}

fn findSpawnedSession(sessions: []const *SessionState, session_id: usize) ?*SessionState {
    for (sessions) |session| {
        if (session.spawned and session.id == session_id) return session;
    }
    return null;
}

/// Sessions spawned earlier in the current frame are not reconciled yet;
/// track them on demand so their first request sees a record.
fn trackedRecord(allocator: std.mem.Allocator, io: std.Io, board: *agent_state.Board, session_id: usize) ?agent_state.Record {
    if (board.get(io, session_id)) |record| return record;
    board.track(allocator, io, session_id) catch |err| {
        log.warn("failed to track session {d}: {}", .{ session_id, err });
        return null;
    };
    return board.get(io, session_id);
}

const TestSession = struct {
    const ghostty_vt = @import("ghostty-vt");
    const posix_util = @import("../posix_util.zig");
    const shell_mod = @import("../shell.zig");

    session: SessionState,
    pipe_fds: [2]std.posix.fd_t,

    /// A pipe stands in for the PTY so the test can read exactly what was
    /// written; the terminal only decides whether bracketed paste is on.
    fn init(self: *TestSession, id: usize, bracketed_paste: bool) !void {
        const allocator = std.testing.allocator;
        try posix_util.pipe(&self.pipe_fds);
        self.session = undefined;
        self.session.id = id;
        self.session.slot_index = 0;
        self.session.spawned = true;
        self.session.dead = false;
        self.session.cwd_path = null;
        self.session.shell = shell_mod.Shell{
            .io = std.testing.io,
            .pty = .{ .master = self.pipe_fds[1], .slave = self.pipe_fds[0] },
            .child_pid = -1,
        };
        self.session.pending_write = .empty;
        self.session.allocator = allocator;
        self.session.io = std.testing.io;
        var terminal = try ghostty_vt.Terminal.init(std.testing.io, allocator, .{ .cols = 20, .rows = 4 });
        terminal.modes.set(.bracketed_paste, bracketed_paste);
        self.session.terminal = terminal;
    }

    fn deinit(self: *TestSession) void {
        if (self.session.terminal) |*terminal| terminal.deinit(std.testing.allocator);
        self.session.pending_write.deinit(std.testing.allocator);
        _ = std.c.close(self.pipe_fds[0]);
        _ = std.c.close(self.pipe_fds[1]);
    }

    fn readWritten(self: *TestSession, buf: []u8) ![]u8 {
        const n = try std.posix.read(self.pipe_fds[0], buf);
        return buf[0..n];
    }
};

fn expectFailure(completion: *control.Completion, code: control.ErrorCode) !void {
    const reply = completion.wait(std.testing.io);
    switch (reply) {
        .failure => |failure| try std.testing.expectEqual(code, failure.code),
        .success => |payload| {
            std.testing.allocator.free(payload);
            return error.TestUnexpectedResult;
        },
    }
}

test "sendInput pastes and submits text, then marks the agent working" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var test_session: TestSession = undefined;
    try test_session.init(3, true);
    defer test_session.deinit();
    const sessions = [_]*SessionState{&test_session.session};

    var board = agent_state.Board{};
    defer board.deinit(allocator);
    try board.track(allocator, io, 3);
    board.applyHook(io, 3, .done);
    const idle_seq = (board.get(io, 3) orelse return error.TestUnexpectedResult).seq;

    var completion = control.Completion{};
    const slot = sendInput(allocator, io, &sessions, &board, .{
        .session_id = 3,
        .text = "review this\nplease",
        .require_idle = true,
    }, &completion);
    try std.testing.expectEqual(@as(?usize, 0), slot);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[200~review this\nplease\x1b[201~\r", try test_session.readWritten(&buf));

    const record = board.get(io, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(agent_state.AgentState.working, record.state);
    try std.testing.expect(record.seq > idle_seq);

    const reply = completion.wait(io);
    defer allocator.free(reply.success);
    try std.testing.expect(std.mem.indexOf(u8, reply.success, "\"bracketed_paste\":true") != null);
}

test "sendInput with require_idle refuses a working agent and writes nothing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var test_session: TestSession = undefined;
    try test_session.init(4, true);
    defer test_session.deinit();
    const sessions = [_]*SessionState{&test_session.session};

    var board = agent_state.Board{};
    defer board.deinit(allocator);
    try board.track(allocator, io, 4);
    _ = board.markDelivered(io, 4);

    var completion = control.Completion{};
    try std.testing.expectEqual(@as(?usize, null), sendInput(allocator, io, &sessions, &board, .{
        .session_id = 4,
        .text = "second message",
        .require_idle = true,
    }, &completion));
    try expectFailure(&completion, .session_busy);
    try std.testing.expectEqual(@as(usize, 0), test_session.session.pending_write.items.len);
}

test "sendInput reports missing, exited, and not-ready sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var test_session: TestSession = undefined;
    try test_session.init(5, false);
    defer test_session.deinit();
    const sessions = [_]*SessionState{&test_session.session};

    var board = agent_state.Board{};
    defer board.deinit(allocator);

    var not_ready = control.Completion{};
    _ = sendInput(allocator, io, &sessions, &board, .{ .session_id = 5, .text = "one\ntwo" }, &not_ready);
    try expectFailure(&not_ready, .input_not_ready);

    var missing = control.Completion{};
    _ = sendInput(allocator, io, &sessions, &board, .{ .session_id = 99, .text = "hi" }, &missing);
    try expectFailure(&missing, .session_not_found);

    try board.track(allocator, io, 42);
    board.markExited(io, 42);
    var gone = control.Completion{};
    _ = sendInput(allocator, io, &sessions, &board, .{ .session_id = 42, .text = "hi" }, &gone);
    try expectFailure(&gone, .session_exited);

    test_session.session.dead = true;
    var dead = control.Completion{};
    _ = sendInput(allocator, io, &sessions, &board, .{ .session_id = 5, .text = "hi" }, &dead);
    try expectFailure(&dead, .session_exited);
}

test "reconcileBoard marks dead sessions exited" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var test_session: TestSession = undefined;
    try test_session.init(6, true);
    defer test_session.deinit();
    const sessions = [_]*SessionState{&test_session.session};

    var board = agent_state.Board{};
    defer board.deinit(allocator);
    var scratch: std.ArrayList(agent_state.LiveSession) = .empty;
    defer scratch.deinit(allocator);

    reconcileBoard(allocator, io, &board, &sessions, &scratch);
    try std.testing.expectEqual(agent_state.AgentState.unknown, board.get(io, 6).?.state);

    test_session.session.dead = true;
    reconcileBoard(allocator, io, &board, &sessions, &scratch);
    try std.testing.expectEqual(agent_state.AgentState.exited, board.get(io, 6).?.state);
}

test "hookSignal maps notification states to agent hook signals" {
    try std.testing.expectEqual(agent_state.HookSignal.start, hookSignal(.running).?);
    try std.testing.expectEqual(agent_state.HookSignal.awaiting_approval, hookSignal(.awaiting_approval).?);
    try std.testing.expectEqual(agent_state.HookSignal.done, hookSignal(.done).?);
    try std.testing.expectEqual(@as(?agent_state.HookSignal, null), hookSignal(.idle));
}
