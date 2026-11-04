//! Per-session agent state for external orchestrators.
//!
//! The main thread is the only writer: it applies agent-hook notifications,
//! input deliveries, and session liveness. The control listener thread reads
//! the board to answer `wait_for_session` without involving the main loop, so
//! every accepted change bumps an app-wide sequence number and fires the
//! change notifier after the lock is released.
//!
//! This file is also compiled into the `architect-mcp` helper through the
//! `control` module, so it must not import app modules outside `src/app/`
//! that pull in UI or SDL code.

const std = @import("std");

pub const AgentState = enum {
    unknown,
    working,
    awaiting_approval,
    idle,
    exited,
};

pub const StateSet = std.EnumSet(AgentState);

/// Signals delivered by agent hooks over the notification socket.
pub const HookSignal = enum {
    start,
    awaiting_approval,
    done,
};

pub const Record = struct {
    session_id: usize,
    state: AgentState,
    seq: u64,
};

pub const LiveSession = struct {
    session_id: usize,
    alive: bool,
};

pub const ChangeNotifier = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,

    pub fn notify(self: ChangeNotifier) void {
        self.callback(self.context);
    }
};

/// Exited records are kept so that a wait or a send arriving shortly after a
/// session ends reports `exited` instead of `session_not_found`.
pub const max_exited_records: usize = 128;

/// Returns the state a hook signal moves the agent to, or null when the
/// signal is ignored.
pub fn stateAfterHook(current: AgentState, signal: HookSignal) ?AgentState {
    if (current == .exited) return null;
    return switch (signal) {
        .start => .working,
        .done => .idle,
        // Claude Code's Notification hook also fires as an idle reminder about
        // a minute after a turn ends. A real permission prompt can only appear
        // while the agent works, so a notification received while idle is the
        // reminder and must not make the agent look blocked.
        .awaiting_approval => if (current == .idle) null else .awaiting_approval,
    };
}

pub const WaitCondition = struct {
    until: StateSet,
    after_seq: u64 = 0,
};

pub const WaitOutcome = enum {
    pending,
    matched,
    exited,
};

pub fn evaluateWait(condition: WaitCondition, record: Record) WaitOutcome {
    const fresh = record.seq > condition.after_seq;
    if (fresh and condition.until.contains(record.state)) return .matched;
    // An exited session can never satisfy the wait later, whatever its seq.
    if (record.state == .exited) {
        return if (condition.until.contains(.exited)) .matched else .exited;
    }
    return .pending;
}

pub const Board = struct {
    mutex: std.Io.Mutex = .init,
    records: std.ArrayList(Record) = .empty,
    last_seq: u64 = 0,
    on_change: ?ChangeNotifier = null,

    pub fn deinit(self: *Board, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.* = undefined;
    }

    pub fn get(self: *Board, io: std.Io, session_id: usize) ?Record {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const idx = self.indexOf(session_id) orelse return null;
        return self.records.items[idx];
    }

    /// Starts tracking a newly spawned session. Idempotent for live sessions.
    pub fn track(self: *Board, allocator: std.mem.Allocator, io: std.Io, session_id: usize) !void {
        self.mutex.lockUncancelable(io);
        const changed = self.trackLocked(allocator, session_id);
        self.mutex.unlock(io);
        if (try changed) self.notifyChange();
    }

    pub fn applyHook(self: *Board, io: std.Io, session_id: usize, signal: HookSignal) void {
        const changed = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const idx = self.indexOf(session_id) orelse break :blk false;
            const record = &self.records.items[idx];
            const next = stateAfterHook(record.state, signal) orelse break :blk false;
            self.setLocked(record, next);
            break :blk true;
        };
        if (changed) self.notifyChange();
    }

    /// Records that input was written to the session's terminal and returns
    /// the new sequence number, or null when the session is not tracked.
    pub fn markDelivered(self: *Board, io: std.Io, session_id: usize) ?u64 {
        const seq = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const idx = self.indexOf(session_id) orelse break :blk null;
            const record = &self.records.items[idx];
            if (record.state == .exited) break :blk null;
            self.setLocked(record, .working);
            break :blk record.seq;
        };
        if (seq != null) self.notifyChange();
        return seq;
    }

    pub fn markExited(self: *Board, io: std.Io, session_id: usize) void {
        const changed = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const idx = self.indexOf(session_id) orelse break :blk false;
            const record = &self.records.items[idx];
            if (record.state == .exited) break :blk false;
            self.setLocked(record, .exited);
            self.pruneExitedLocked();
            break :blk true;
        };
        if (changed) self.notifyChange();
    }

    /// Brings the board in line with the sessions that currently exist:
    /// untracked live sessions start as `unknown`, a live session whose record
    /// says `exited` was restarted and becomes `unknown` again, and tracked
    /// sessions that are dead or gone become `exited`.
    pub fn reconcile(self: *Board, allocator: std.mem.Allocator, io: std.Io, live: []const LiveSession) !void {
        const changed = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            var changed = false;
            for (live) |session| {
                if (!session.alive) continue;
                if (try self.trackLocked(allocator, session.session_id)) changed = true;
            }
            for (self.records.items) |*record| {
                if (record.state == .exited) continue;
                if (isAlive(live, record.session_id)) continue;
                self.setLocked(record, .exited);
                changed = true;
            }
            if (changed) self.pruneExitedLocked();
            break :blk changed;
        };
        if (changed) self.notifyChange();
    }

    fn trackLocked(self: *Board, allocator: std.mem.Allocator, session_id: usize) !bool {
        if (self.indexOf(session_id)) |idx| {
            const record = &self.records.items[idx];
            if (record.state != .exited) return false;
            self.setLocked(record, .unknown);
            return true;
        }
        self.last_seq += 1;
        try self.records.append(allocator, .{
            .session_id = session_id,
            .state = .unknown,
            .seq = self.last_seq,
        });
        return true;
    }

    fn setLocked(self: *Board, record: *Record, state: AgentState) void {
        self.last_seq += 1;
        record.state = state;
        record.seq = self.last_seq;
    }

    fn pruneExitedLocked(self: *Board) void {
        var exited_count: usize = 0;
        for (self.records.items) |record| {
            if (record.state == .exited) exited_count += 1;
        }
        while (exited_count > max_exited_records) : (exited_count -= 1) {
            var oldest: ?usize = null;
            var oldest_seq: u64 = std.math.maxInt(u64);
            for (self.records.items, 0..) |record, idx| {
                if (record.state != .exited or record.seq >= oldest_seq) continue;
                oldest = idx;
                oldest_seq = record.seq;
            }
            _ = self.records.swapRemove(oldest orelse return);
        }
    }

    fn indexOf(self: *const Board, session_id: usize) ?usize {
        for (self.records.items, 0..) |record, idx| {
            if (record.session_id == session_id) return idx;
        }
        return null;
    }

    fn notifyChange(self: *const Board) void {
        if (self.on_change) |notifier| notifier.notify();
    }
};

fn isAlive(live: []const LiveSession, session_id: usize) bool {
    for (live) |session| {
        if (session.session_id == session_id) return session.alive;
    }
    return false;
}

test "hook signals drive the agent state" {
    try std.testing.expectEqual(AgentState.working, stateAfterHook(.unknown, .start).?);
    try std.testing.expectEqual(AgentState.idle, stateAfterHook(.working, .done).?);
    try std.testing.expectEqual(AgentState.awaiting_approval, stateAfterHook(.working, .awaiting_approval).?);
    try std.testing.expectEqual(AgentState.idle, stateAfterHook(.awaiting_approval, .done).?);
    try std.testing.expectEqual(@as(?AgentState, null), stateAfterHook(.exited, .done));
}

test "an approval notification while idle is an idle reminder and is ignored" {
    try std.testing.expectEqual(@as(?AgentState, null), stateAfterHook(.idle, .awaiting_approval));
}

test "evaluateWait requires a fresh matching state" {
    const until_idle = StateSet.initOne(.idle);
    const record = Record{ .session_id = 1, .state = .idle, .seq = 5 };

    try std.testing.expectEqual(WaitOutcome.matched, evaluateWait(.{ .until = until_idle }, record));
    try std.testing.expectEqual(WaitOutcome.pending, evaluateWait(.{ .until = until_idle, .after_seq = 5 }, record));
    try std.testing.expectEqual(
        WaitOutcome.pending,
        evaluateWait(.{ .until = StateSet.initOne(.awaiting_approval) }, record),
    );
}

test "evaluateWait ends every wait once the session exited" {
    const exited = Record{ .session_id = 1, .state = .exited, .seq = 3 };

    try std.testing.expectEqual(WaitOutcome.exited, evaluateWait(.{ .until = StateSet.initOne(.idle), .after_seq = 10 }, exited));
    try std.testing.expectEqual(WaitOutcome.matched, evaluateWait(.{ .until = StateSet.initOne(.exited), .after_seq = 10 }, exited));
}

test "Board tracks deliveries and hooks with increasing sequence numbers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var board = Board{};
    defer board.deinit(allocator);

    try board.track(allocator, io, 7);
    const tracked = board.get(io, 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(AgentState.unknown, tracked.state);

    const delivered_seq = board.markDelivered(io, 7) orelse return error.TestUnexpectedResult;
    try std.testing.expect(delivered_seq > tracked.seq);
    try std.testing.expectEqual(AgentState.working, board.get(io, 7).?.state);

    board.applyHook(io, 7, .done);
    const idle = board.get(io, 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(AgentState.idle, idle.state);
    try std.testing.expect(idle.seq > delivered_seq);

    board.applyHook(io, 7, .awaiting_approval);
    try std.testing.expectEqual(idle, board.get(io, 7).?);

    board.applyHook(io, 99, .done);
    try std.testing.expectEqual(@as(?Record, null), board.get(io, 99));
    try std.testing.expectEqual(@as(?u64, null), board.markDelivered(io, 99));
}

test "Board.reconcile tracks live sessions and marks missing or dead ones exited" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var board = Board{};
    defer board.deinit(allocator);

    try board.reconcile(allocator, io, &.{
        .{ .session_id = 1, .alive = true },
        .{ .session_id = 2, .alive = true },
    });
    try std.testing.expectEqual(AgentState.unknown, board.get(io, 1).?.state);
    try std.testing.expectEqual(AgentState.unknown, board.get(io, 2).?.state);

    try board.reconcile(allocator, io, &.{.{ .session_id = 1, .alive = false }});
    try std.testing.expectEqual(AgentState.exited, board.get(io, 1).?.state);
    try std.testing.expectEqual(AgentState.exited, board.get(io, 2).?.state);
    try std.testing.expectEqual(@as(?u64, null), board.markDelivered(io, 1));

    const exited_seq = (board.get(io, 1) orelse return error.TestUnexpectedResult).seq;
    try board.reconcile(allocator, io, &.{.{ .session_id = 1, .alive = true }});
    const restarted = board.get(io, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(AgentState.unknown, restarted.state);
    try std.testing.expect(restarted.seq > exited_seq);
}

test "Board.reconcile does not bump sequence numbers when nothing changed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var board = Board{};
    defer board.deinit(allocator);

    var notifications: usize = 0;
    const Counter = struct {
        fn bump(context: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    board.on_change = .{ .context = &notifications, .callback = Counter.bump };

    const live = [_]LiveSession{.{ .session_id = 3, .alive = true }};
    try board.reconcile(allocator, io, &live);
    const seq = board.last_seq;
    try board.reconcile(allocator, io, &live);

    try std.testing.expectEqual(seq, board.last_seq);
    try std.testing.expectEqual(@as(usize, 1), notifications);
}

test "Board keeps a bounded number of exited records, dropping the oldest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var board = Board{};
    defer board.deinit(allocator);

    for (0..max_exited_records + 2) |id| {
        try board.track(allocator, io, id);
        board.markExited(io, id);
    }

    try std.testing.expectEqual(max_exited_records, board.records.items.len);
    try std.testing.expectEqual(@as(?Record, null), board.get(io, 0));
    try std.testing.expectEqual(@as(?Record, null), board.get(io, 1));
    try std.testing.expectEqual(AgentState.exited, board.get(io, max_exited_records + 1).?.state);
}
