//! Local control channel shared by the running app and `architect-mcp`.
//!
//! Wire format: one JSON line per connection in each direction. Requests are
//! `{"op": "<op>", "arguments": {...}}`; replies are
//! `{"ok": true, "result": {...}}` or `{"ok": false, "code": "...", "message": "..."}`.
//! Operations that touch terminals are queued for the main thread; waits are
//! parked on the listener thread and answered from the agent-state board.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const atomic = std.atomic;
const clock = @import("../clock.zig");
const env = @import("../env.zig");
const posix_util = @import("../posix_util.zig");
const wake_pipe = @import("../wake_pipe.zig");
pub const agent_state = @import("agent_state.zig");

const log = std.log.scoped(.control);

pub const max_message_bytes: usize = 512 * 1024;
pub const max_text_bytes: usize = 256 * 1024;
const max_cwd_bytes: usize = 4096;
/// The command is typed into the new shell, often before its line editor has
/// put the terminal in raw mode. In canonical mode the kernel keeps at most
/// MAX_CANON (1024 on macOS) bytes per line and drops the rest, newline
/// included, so a longer command can silently never run. Leave room for the
/// newline Architect appends.
pub const max_command_bytes: usize = 1023;
const max_display_name_bytes: usize = 512;
pub const default_wait_timeout_ms: u32 = 30_000;
pub const max_wait_timeout_ms: u32 = 600_000;
pub const max_parked_waits: usize = 64;
const discovery_file_prefix = "architect_control_";
const discovery_file_suffix = ".json";
const control_request_read_timeout_ms: i64 = 2000;
const control_response_write_timeout_ms: i64 = 2000;

pub const ErrorCode = enum {
    invalid_request,
    app_not_running,
    full_grid,
    invalid_cwd,
    spawn_failed,
    session_not_found,
    instance_not_found,
    session_exited,
    session_busy,
    input_not_ready,
    input_failed,
    too_many_waiters,
    internal_error,

    pub fn jsonString(self: ErrorCode) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(value: []const u8) ?ErrorCode {
        return std.meta.stringToEnum(ErrorCode, value);
    }
};

/// Control operations. The tag names double as the MCP tool names.
pub const Op = enum {
    spawn_session,
    list_sessions,
    send_input,
    wait_for_session,
    terminate_session,

    pub fn fromString(value: []const u8) ?Op {
        return std.meta.stringToEnum(Op, value);
    }
};

pub const max_instance_id_bytes: usize = 32;

/// Identifies one running Architect app. Session ids restart at 0 in every
/// app, so a session reference is only meaningful together with the
/// instance that issued it; the pid alone could be reused after a restart.
pub const InstanceId = struct {
    buf: [max_instance_id_bytes]u8 = undefined,
    len: usize = 0,

    pub fn generate(io: std.Io) error{NoSpaceLeft}!InstanceId {
        var nonce: u64 = undefined;
        std.Io.random(io, std.mem.asBytes(&nonce));
        var id = InstanceId{};
        const written = try std.fmt.bufPrint(&id.buf, "{d}-{x:0>16}", .{ std.c.getpid(), nonce });
        id.len = written.len;
        return id;
    }

    pub fn fromSlice(value: []const u8) error{InvalidInstanceId}!InstanceId {
        if (value.len == 0 or value.len > max_instance_id_bytes) return error.InvalidInstanceId;
        for (value) |byte| {
            const valid = std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f') or byte == '-';
            if (!valid) return error.InvalidInstanceId;
        }
        var id = InstanceId{};
        @memcpy(id.buf[0..value.len], value);
        id.len = value.len;
        return id;
    }

    pub fn slice(self: *const InstanceId) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn eql(self: *const InstanceId, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }
};

pub const SpawnRequest = struct {
    cwd: []const u8,
    command: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    instance_id: ?InstanceId = null,

    pub fn deinit(self: *SpawnRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        if (self.command) |command| allocator.free(command);
        if (self.display_name) |display_name| allocator.free(display_name);
        self.* = undefined;
    }
};

pub const ListRequest = struct {
    instance_id: ?InstanceId = null,
};

pub const SendInputRequest = struct {
    instance_id: InstanceId,
    session_id: usize,
    text: []const u8,
    submit: bool = true,
    require_idle: bool = false,

    pub fn deinit(self: *SendInputRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const WaitRequest = struct {
    instance_id: InstanceId,
    session_id: usize,
    condition: agent_state.WaitCondition,
    timeout_ms: u32 = default_wait_timeout_ms,
};

pub const TerminateRequest = struct {
    instance_id: InstanceId,
    session_id: usize,
};

pub const Request = union(Op) {
    spawn_session: SpawnRequest,
    list_sessions: ListRequest,
    send_input: SendInputRequest,
    wait_for_session: WaitRequest,
    terminate_session: TerminateRequest,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .spawn_session => |*spawn| spawn.deinit(allocator),
            .send_input => |*send| send.deinit(allocator),
            .list_sessions, .wait_for_session, .terminate_session => {},
        }
        self.* = undefined;
    }

    /// The instance the request is addressed to, if it names one. Session
    /// operations always do; spawn and list may leave it to the newest app.
    pub fn targetInstance(self: *const Request) ?InstanceId {
        return switch (self.*) {
            .spawn_session => |spawn| spawn.instance_id,
            .list_sessions => |list| list.instance_id,
            .send_input => |send| send.instance_id,
            .wait_for_session => |wait| wait.instance_id,
            .terminate_session => |terminate| terminate.instance_id,
        };
    }
};

pub const SpawnResult = struct {
    status: []const u8 = "spawned",
    instance_id: []const u8,
    session_id: usize,
    slot_index: usize,
};

pub const SessionInfo = struct {
    session_id: usize,
    slot_index: usize,
    cwd: ?[]const u8,
    foreground_agent: ?[]const u8,
    agent_state: agent_state.AgentState,
    state_seq: u64,
};

pub const ListResult = struct {
    status: []const u8 = "ok",
    instance_id: []const u8,
    sessions: []const SessionInfo,
};

pub const SendResult = struct {
    status: []const u8 = "sent",
    instance_id: []const u8,
    session_id: usize,
    state_seq: u64,
    bracketed_paste: bool,
};

pub const TerminateResult = struct {
    status: []const u8 = "terminated",
    instance_id: []const u8,
    session_id: usize,
};

pub const WaitStatus = enum {
    matched,
    exited,
    timed_out,
};

pub const WaitResult = struct {
    status: WaitStatus,
    instance_id: []const u8,
    session_id: usize,
    agent_state: agent_state.AgentState,
    state_seq: u64,
};

pub const Failure = struct {
    code: ErrorCode,
    /// Static text; replies never own their failure message.
    message: []const u8,
};

pub const Reply = union(enum) {
    /// A complete reply line, owned by the allocator that serialized it.
    success: []u8,
    failure: Failure,
};

pub fn successReply(allocator: std.mem.Allocator, comptime T: type, result: T) error{OutOfMemory}!Reply {
    return .{ .success = try successPayloadAlloc(allocator, T, result) };
}

pub const Completion = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    completed: bool = false,
    reply: Reply = undefined,

    pub fn complete(self: *Completion, io: std.Io, reply: Reply) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.reply = reply;
        self.completed = true;
        self.condition.signal(io);
    }

    pub fn fail(self: *Completion, io: std.Io, code: ErrorCode, message: []const u8) void {
        self.complete(io, .{ .failure = .{ .code = code, .message = message } });
    }

    pub fn succeed(self: *Completion, allocator: std.mem.Allocator, io: std.Io, comptime T: type, result: T) void {
        const reply = successReply(allocator, T, result) catch |err| {
            log.warn("failed to serialize control reply: {}", .{err});
            self.fail(io, .internal_error, "failed to serialize the reply");
            return;
        };
        self.complete(io, reply);
    }

    pub fn wait(self: *Completion, io: std.Io) Reply {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (!self.completed) {
            self.condition.waitUncancelable(io, &self.mutex);
        }
        return self.reply;
    }
};

/// A request handed to the main thread. The main thread owns `request` and
/// must deinit it after completing.
pub const PendingRequest = struct {
    request: Request,
    completion: *Completion,
};

pub const RequestQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(PendingRequest) = .empty,
    /// Set by `closeAndFail` at shutdown. Checked under the same lock as the
    /// append, so no request can be queued after the main loop stopped
    /// draining; the listener would otherwise block on its completion forever.
    closed: bool = false,

    pub fn deinit(self: *RequestQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn push(self: *RequestQueue, allocator: std.mem.Allocator, io: std.Io, item: PendingRequest) error{ QueueClosed, OutOfMemory }!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.QueueClosed;
        try self.items.append(allocator, item);
    }

    /// Closes the queue against new requests and fails the ones still queued.
    pub fn closeAndFail(
        self: *RequestQueue,
        allocator: std.mem.Allocator,
        io: std.Io,
        code: ErrorCode,
        message: []const u8,
    ) void {
        var pending = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.closed = true;
            const items = self.items;
            self.items = .empty;
            break :blk items;
        };
        defer pending.deinit(allocator);
        for (pending.items) |*item| {
            item.completion.fail(io, code, message);
            item.request.deinit(allocator);
        }
    }

    pub fn drainAll(self: *RequestQueue, io: std.Io) std.ArrayList(PendingRequest) {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const items = self.items;
        self.items = .empty;
        return items;
    }
};

pub const ParseError = error{
    ExpectedObject,
    MissingOp,
    UnknownOp,
    InvalidArguments,
    MissingCwd,
    InvalidCwd,
    InvalidCommand,
    InvalidDisplayName,
    MissingInstanceId,
    InvalidInstanceId,
    MissingSessionId,
    InvalidSessionId,
    MissingText,
    InvalidText,
    InvalidSubmit,
    InvalidRequireIdle,
    MissingUntil,
    InvalidUntil,
    InvalidAfterSeq,
    InvalidTimeout,
    UnknownField,
    OutOfMemory,
};

pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.ExpectedObject => "control request must be a JSON object",
        error.MissingOp => "op is required",
        error.UnknownOp => "op is not a supported operation",
        error.InvalidArguments => "arguments must be an object",
        error.MissingCwd => "cwd is required",
        error.InvalidCwd => "cwd must be a non-empty string",
        error.InvalidCommand => "command must be a non-empty string of at most 1023 bytes when provided; put longer commands in a script",
        error.InvalidDisplayName => "display_name must be a non-empty string when provided",
        error.MissingInstanceId => "instance_id is required; use the instance_id returned by spawn_session or list_sessions",
        error.InvalidInstanceId => "instance_id must be an instance id returned by Architect",
        error.MissingSessionId => "session_id is required",
        error.InvalidSessionId => "session_id must be a non-negative integer",
        error.MissingText => "text is required",
        error.InvalidText => "text must be a non-empty string without NUL bytes and at most 256 KiB",
        error.InvalidSubmit => "submit must be a boolean",
        error.InvalidRequireIdle => "require_idle must be a boolean",
        error.MissingUntil => "until is required",
        error.InvalidUntil => "until must be a non-empty array of agent states (unknown, working, awaiting_approval, idle, exited)",
        error.InvalidAfterSeq => "after_seq must be a non-negative integer",
        error.InvalidTimeout => "timeout_ms must be an integer from 0 to 600000",
        error.UnknownField => "arguments contain an unsupported field",
        error.OutOfMemory => "out of memory while parsing the request",
    };
}

/// Parses a wire request `{"op": ..., "arguments": {...}}`.
pub fn parseRequest(allocator: std.mem.Allocator, value: std.json.Value) ParseError!Request {
    if (value != .object) return error.ExpectedObject;

    var op: ?Op = null;
    var arguments: ?std.json.Value = null;
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "op")) {
            if (field_value != .string) return error.UnknownOp;
            op = Op.fromString(field_value.string) orelse return error.UnknownOp;
        } else if (std.mem.eql(u8, key, "arguments")) {
            arguments = field_value;
        } else {
            return error.UnknownField;
        }
    }

    return parseArguments(allocator, op orelse return error.MissingOp, arguments);
}

/// Validates the arguments of `op`. A missing `arguments` value is treated as
/// an empty object.
pub fn parseArguments(allocator: std.mem.Allocator, op: Op, arguments: ?std.json.Value) ParseError!Request {
    const object: ?std.json.ObjectMap = if (arguments) |value| switch (value) {
        .object => |map| map,
        else => return error.InvalidArguments,
    } else null;

    return switch (op) {
        .spawn_session => .{ .spawn_session = try parseSpawnArguments(allocator, object) },
        .list_sessions => .{ .list_sessions = try parseListArguments(object) },
        .send_input => .{ .send_input = try parseSendInputArguments(allocator, object) },
        .wait_for_session => .{ .wait_for_session = try parseWaitArguments(object) },
        .terminate_session => .{ .terminate_session = try parseTerminateArguments(object) },
    };
}

fn parseSpawnArguments(allocator: std.mem.Allocator, object: ?std.json.ObjectMap) ParseError!SpawnRequest {
    const map = object orelse return error.MissingCwd;

    var cwd: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var display_name: ?[]const u8 = null;
    var instance_id: ?InstanceId = null;
    errdefer {
        if (cwd) |value| allocator.free(value);
        if (command) |value| allocator.free(value);
        if (display_name) |value| allocator.free(value);
    }

    var iter = map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "cwd")) {
            cwd = try duplicateStringField(allocator, field_value, max_cwd_bytes, error.InvalidCwd);
        } else if (std.mem.eql(u8, key, "command")) {
            if (field_value == .null) continue;
            command = try duplicateStringField(allocator, field_value, max_command_bytes, error.InvalidCommand);
        } else if (std.mem.eql(u8, key, "display_name")) {
            if (field_value == .null) continue;
            display_name = try duplicateStringField(allocator, field_value, max_display_name_bytes, error.InvalidDisplayName);
        } else if (std.mem.eql(u8, key, "instance_id")) {
            instance_id = try parseInstanceId(field_value);
        } else {
            return error.UnknownField;
        }
    }

    return .{
        .cwd = cwd orelse return error.MissingCwd,
        .command = command,
        .display_name = display_name,
        .instance_id = instance_id,
    };
}

fn parseListArguments(object: ?std.json.ObjectMap) ParseError!ListRequest {
    const map = object orelse return .{};
    var request = ListRequest{};
    var iter = map.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "instance_id")) {
            request.instance_id = try parseInstanceId(entry.value_ptr.*);
        } else {
            return error.UnknownField;
        }
    }
    return request;
}

fn parseSendInputArguments(allocator: std.mem.Allocator, object: ?std.json.ObjectMap) ParseError!SendInputRequest {
    const map = object orelse return error.MissingSessionId;

    var instance_id: ?InstanceId = null;
    var session_id: ?usize = null;
    var text: ?[]const u8 = null;
    var submit = true;
    var require_idle = false;
    errdefer if (text) |value| allocator.free(value);

    var iter = map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "instance_id")) {
            instance_id = try parseInstanceId(field_value);
        } else if (std.mem.eql(u8, key, "session_id")) {
            session_id = try parseSessionId(field_value);
        } else if (std.mem.eql(u8, key, "text")) {
            text = try duplicateStringField(allocator, field_value, max_text_bytes, error.InvalidText);
        } else if (std.mem.eql(u8, key, "submit")) {
            if (field_value != .bool) return error.InvalidSubmit;
            submit = field_value.bool;
        } else if (std.mem.eql(u8, key, "require_idle")) {
            if (field_value != .bool) return error.InvalidRequireIdle;
            require_idle = field_value.bool;
        } else {
            return error.UnknownField;
        }
    }

    return .{
        .instance_id = instance_id orelse return error.MissingInstanceId,
        .session_id = session_id orelse return error.MissingSessionId,
        .text = text orelse return error.MissingText,
        .submit = submit,
        .require_idle = require_idle,
    };
}

fn parseWaitArguments(object: ?std.json.ObjectMap) ParseError!WaitRequest {
    const map = object orelse return error.MissingSessionId;

    var instance_id: ?InstanceId = null;
    var session_id: ?usize = null;
    var until: ?agent_state.StateSet = null;
    var after_seq: u64 = 0;
    var timeout_ms: u32 = default_wait_timeout_ms;

    var iter = map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "instance_id")) {
            instance_id = try parseInstanceId(field_value);
        } else if (std.mem.eql(u8, key, "session_id")) {
            session_id = try parseSessionId(field_value);
        } else if (std.mem.eql(u8, key, "until")) {
            until = try parseStateSet(field_value);
        } else if (std.mem.eql(u8, key, "after_seq")) {
            if (field_value != .integer or field_value.integer < 0) return error.InvalidAfterSeq;
            after_seq = @intCast(field_value.integer);
        } else if (std.mem.eql(u8, key, "timeout_ms")) {
            if (field_value != .integer or field_value.integer < 0 or field_value.integer > max_wait_timeout_ms) {
                return error.InvalidTimeout;
            }
            timeout_ms = @intCast(field_value.integer);
        } else {
            return error.UnknownField;
        }
    }

    return .{
        .instance_id = instance_id orelse return error.MissingInstanceId,
        .session_id = session_id orelse return error.MissingSessionId,
        .condition = .{
            .until = until orelse return error.MissingUntil,
            .after_seq = after_seq,
        },
        .timeout_ms = timeout_ms,
    };
}

fn parseTerminateArguments(object: ?std.json.ObjectMap) ParseError!TerminateRequest {
    const map = object orelse return error.MissingSessionId;

    var instance_id: ?InstanceId = null;
    var session_id: ?usize = null;
    var iter = map.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "instance_id")) {
            instance_id = try parseInstanceId(entry.value_ptr.*);
        } else if (std.mem.eql(u8, entry.key_ptr.*, "session_id")) {
            session_id = try parseSessionId(entry.value_ptr.*);
        } else {
            return error.UnknownField;
        }
    }

    return .{
        .instance_id = instance_id orelse return error.MissingInstanceId,
        .session_id = session_id orelse return error.MissingSessionId,
    };
}

fn parseInstanceId(value: std.json.Value) ParseError!InstanceId {
    if (value != .string) return error.InvalidInstanceId;
    return InstanceId.fromSlice(value.string) catch return error.InvalidInstanceId;
}

fn parseSessionId(value: std.json.Value) ParseError!usize {
    if (value != .integer or value.integer < 0) return error.InvalidSessionId;
    return @intCast(value.integer);
}

fn parseStateSet(value: std.json.Value) ParseError!agent_state.StateSet {
    if (value != .array or value.array.items.len == 0) return error.InvalidUntil;
    var set = agent_state.StateSet.initEmpty();
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidUntil;
        const state = std.meta.stringToEnum(agent_state.AgentState, item.string) orelse return error.InvalidUntil;
        set.insert(state);
    }
    return set;
}

fn duplicateStringField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    max_len: usize,
    comptime invalid: ParseError,
) ParseError![]const u8 {
    if (value != .string) return invalid;
    const string = value.string;
    if (string.len == 0 or string.len > max_len) return invalid;
    if (std.mem.indexOfScalar(u8, string, 0) != null) return invalid;
    return try allocator.dupe(u8, string);
}

pub fn requestPayloadAlloc(allocator: std.mem.Allocator, op: Op, arguments: ?std.json.Value) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    writeRequestPayload(&out.writer, op, arguments) catch return error.OutOfMemory;
    return try allocator.dupe(u8, out.written());
}

fn writeRequestPayload(writer: *std.Io.Writer, op: Op, arguments: ?std.json.Value) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("op");
    try json.write(@tagName(op));
    try json.objectField("arguments");
    if (arguments) |value| {
        try json.write(value);
    } else {
        try json.beginObject();
        try json.endObject();
    }
    try json.endObject();
    try writer.writeByte('\n');
}

fn successPayloadAlloc(allocator: std.mem.Allocator, comptime T: type, result: T) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    writeSuccessPayload(T, &out.writer, result) catch return error.OutOfMemory;
    return try allocator.dupe(u8, out.written());
}

fn writeSuccessPayload(comptime T: type, writer: *std.Io.Writer, result: T) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("ok");
    try json.write(true);
    try json.objectField("result");
    try json.write(result);
    try json.endObject();
    try writer.writeByte('\n');
}

fn failurePayloadAlloc(allocator: std.mem.Allocator, failure: Failure) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    writeFailurePayload(&out.writer, failure) catch return error.OutOfMemory;
    return try allocator.dupe(u8, out.written());
}

fn writeFailurePayload(writer: *std.Io.Writer, failure: Failure) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("ok");
    try json.write(false);
    try json.objectField("code");
    try json.write(failure.code.jsonString());
    try json.objectField("message");
    try json.write(failure.message);
    try json.endObject();
    try writer.writeByte('\n');
}

pub fn getControlSocketPath(allocator: std.mem.Allocator, io: std.Io) ![:0]u8 {
    var base = try controlRuntimeDirAlloc(allocator, io);
    defer base.deinit(allocator);
    try ensureControlRuntimeDir(io, base);

    const pid = std.c.getpid();
    const socket_name = try std.fmt.allocPrint(allocator, "architect_control_{d}.sock", .{pid});
    defer allocator.free(socket_name);
    return try std.fs.path.joinZ(allocator, &.{ base.path, socket_name });
}

pub fn getControlDiscoveryPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var base = try controlRuntimeDirAlloc(allocator, io);
    defer base.deinit(allocator);
    try ensureControlRuntimeDir(io, base);

    const file_name = try controlDiscoveryFileNameAlloc(allocator);
    defer allocator.free(file_name);
    return try std.fs.path.join(allocator, &.{ base.path, file_name });
}

const ControlRuntimeDir = struct {
    path: []u8,
    managed: bool,

    fn deinit(self: *ControlRuntimeDir, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

fn controlRuntimeDirAlloc(allocator: std.mem.Allocator, io: std.Io) !ControlRuntimeDir {
    _ = io;
    if (env.get("XDG_RUNTIME_DIR")) |runtime_dir| {
        return .{
            .path = try allocator.dupe(u8, runtime_dir),
            .managed = false,
        };
    }

    return .{
        .path = try fallbackControlRuntimeDirAlloc(allocator),
        .managed = true,
    };
}

fn fallbackControlRuntimeDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (env.get("HOME")) |home| {
        if (builtin.os.tag == .macos) {
            return try std.fs.path.join(allocator, &.{ home, "Library", "Caches", "Architect", "runtime" });
        }
        return try std.fs.path.join(allocator, &.{ home, ".cache", "architect", "runtime" });
    }

    return try std.fmt.allocPrint(allocator, "/tmp/architect-{d}", .{std.c.getuid()});
}

fn ensureControlRuntimeDir(io: std.Io, runtime_dir: ControlRuntimeDir) !void {
    if (!runtime_dir.managed) return;

    try std.Io.Dir.cwd().createDirPath(io, runtime_dir.path);
    try std.Io.Dir.cwd().setFilePermissions(
        io,
        runtime_dir.path,
        .fromMode(0o700),
        .{},
    );
}

fn controlDiscoveryFileNameAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}{d}_{d}{s}",
        .{ discovery_file_prefix, std.c.getuid(), std.c.getpid(), discovery_file_suffix },
    );
}

fn controlDiscoveryFilePrefixAlloc(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}{d}_", .{ discovery_file_prefix, std.c.getuid() });
}

fn isOwnControlDiscoveryFileName(file_name: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, file_name, prefix) and std.mem.endsWith(u8, file_name, discovery_file_suffix);
}

pub fn cleanupControlFiles(io: std.Io, socket_path: [:0]const u8, discovery_path: []const u8) void {
    _ = std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to unlink control socket during cleanup: {}", .{err}),
    };
    std.Io.Dir.deleteFileAbsolute(io, discovery_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to delete control discovery file: {}", .{err}),
    };
}

const ControlContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: [:0]const u8,
    discovery_path: []const u8,
    instance_id: InstanceId,
    queue: *RequestQueue,
    board: *agent_state.Board,
    stop: *atomic.Value(bool),
    wake: *const wake_pipe.WakePipe,
    runtime_wake: ?RuntimeWake,
};

pub const RuntimeWake = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,

    pub fn notify(self: RuntimeWake) void {
        self.callback(self.context);
    }
};

/// Starts the listener thread. `board` changes must signal `wake` (see
/// `agent_state.Board.on_change`) so parked waits are re-evaluated.
pub fn startControlThread(
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: [:0]const u8,
    discovery_path: []const u8,
    instance_id: InstanceId,
    queue: *RequestQueue,
    board: *agent_state.Board,
    stop: *atomic.Value(bool),
    wake: *const wake_pipe.WakePipe,
    runtime_wake: ?RuntimeWake,
) std.Thread.SpawnError!std.Thread {
    _ = std.Io.Dir.cwd().deleteFile(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to unlink control socket: {}", .{err}),
    };

    const ctx = ControlContext{
        .allocator = allocator,
        .io = io,
        .socket_path = socket_path,
        .discovery_path = discovery_path,
        .instance_id = instance_id,
        .queue = queue,
        .board = board,
        .stop = stop,
        .wake = wake,
        .runtime_wake = runtime_wake,
    };
    return try std.Thread.spawn(.{}, controlThreadMain, .{ctx});
}

/// A `wait_for_session` connection held open until the board satisfies it,
/// its deadline passes, or the client goes away.
const ParkedWait = struct {
    fd: posix.fd_t,
    session_id: usize,
    condition: agent_state.WaitCondition,
    deadline_ms: i64,
    /// The client closed its sending side. On macOS a half-closed and a fully
    /// closed peer look identical (POLLIN|POLLHUP, then EOF), so the wait stays
    /// parked and a client that is really gone shows up as a failed reply write.
    request_side_closed: bool = false,
};

const ParkedEvent = enum { keep, drop };

/// Reads from a parked connection that `poll` reported. A parked client has
/// already sent its request, so EOF means it half-closed, and any data is a
/// protocol violation.
fn checkParkedConnection(wait: *ParkedWait) ParkedEvent {
    var byte: [1]u8 = undefined;
    const n = posix.read(wait.fd, &byte) catch |err| switch (err) {
        error.WouldBlock => return .keep,
        else => {
            log.debug("dropping wait for session {d}: read failed: {}", .{ wait.session_id, err });
            return .drop;
        },
    };
    if (n == 0) {
        wait.request_side_closed = true;
        return .keep;
    }
    log.debug("dropping wait for session {d}: client sent data after its request", .{wait.session_id});
    return .drop;
}

const ParkedWaits = struct {
    items: [max_parked_waits]ParkedWait = undefined,
    len: usize = 0,

    fn slice(self: *ParkedWaits) []ParkedWait {
        return self.items[0..self.len];
    }

    fn append(self: *ParkedWaits, wait: ParkedWait) error{TooManyWaiters}!void {
        if (self.len == self.items.len) return error.TooManyWaiters;
        self.items[self.len] = wait;
        self.len += 1;
    }

    fn swapRemove(self: *ParkedWaits, idx: usize) void {
        self.len -= 1;
        self.items[idx] = self.items[self.len];
    }
};

fn controlThreadMain(ctx: ControlContext) !void {
    const address = try std.Io.net.UnixAddress.init(ctx.socket_path);
    var server = try address.listen(ctx.io, .{ .kernel_backlog = 16 });
    defer server.deinit(ctx.io);

    const fd = server.socket.handle;

    const sock_path = std.mem.sliceTo(ctx.socket_path, 0);
    std.Io.Dir.cwd().setFilePermissions(ctx.io, sock_path, .fromMode(0o600), .{}) catch |err| {
        log.warn("failed to chmod control socket: {}", .{err});
    };
    writeDiscoveryFile(ctx.allocator, ctx.io, ctx.discovery_path, sock_path, ctx.instance_id.slice()) catch |err| {
        log.warn("failed to write control discovery file: {}", .{err});
    };

    setFdNonBlocking(fd, "control socket");

    var parked = ParkedWaits{};
    defer for (parked.slice()) |wait| {
        writeFailure(ctx.allocator, ctx.io, wait.fd, .{ .code = .app_not_running, .message = "Architect is shutting down" });
        _ = std.c.close(wait.fd);
    };

    var fds: [2 + max_parked_waits]posix.pollfd = undefined;
    // Parked index for each polled connection. Connections whose request side
    // is closed are not polled: they stay readable at EOF, and Linux reports
    // POLLHUP even with no events requested, so polling them would spin.
    var polled_waits: [max_parked_waits]usize = undefined;
    while (!ctx.stop.load(.seq_cst)) {
        fds[0] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
        fds[1] = ctx.wake.pollfd();
        var polled_count: usize = 0;
        for (parked.slice(), 0..) |wait, idx| {
            if (wait.request_side_closed) continue;
            fds[2 + polled_count] = .{ .fd = wait.fd, .events = posix.POLL.IN, .revents = 0 };
            polled_waits[polled_count] = idx;
            polled_count += 1;
        }

        const timeout = pollTimeoutMs(parked.slice(), clock.nowMillis(ctx.io));
        _ = posix.poll(fds[0 .. 2 + polled_count], timeout) catch |err| {
            log.warn("control poll failed: {}", .{err});
            clock.sleepNanos(ctx.io, wake_pipe.poll_error_backoff_ns);
            continue;
        };
        if (fds[1].revents != 0) ctx.wake.drain();

        // Walk backwards so swapRemove only moves entries already visited.
        var slot = polled_count;
        while (slot > 0) {
            slot -= 1;
            if (fds[2 + slot].revents == 0) continue;
            const idx = polled_waits[slot];
            switch (checkParkedConnection(&parked.items[idx])) {
                .keep => {},
                .drop => {
                    _ = std.c.close(parked.items[idx].fd);
                    parked.swapRemove(idx);
                },
            }
        }

        resolveParkedWaits(&ctx, &parked, clock.nowMillis(ctx.io));

        // Shutdown fails the queue before joining, so a request accepted now
        // could block this thread on a completion nobody will signal.
        if (ctx.stop.load(.seq_cst)) break;
        if (fds[0].revents == 0) continue;

        const conn_fd = posix_util.accept(fd) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => {
                log.debug("control accept error: {}", .{err});
                continue;
            },
        };
        setFdNonBlocking(conn_fd, "control connection");
        if (!handleControlConnection(&ctx, conn_fd, &parked)) {
            _ = std.c.close(conn_fd);
        }
    }
}

fn pollTimeoutMs(parked: []const ParkedWait, now_ms: i64) i32 {
    if (parked.len == 0) return -1;
    var earliest = parked[0].deadline_ms;
    for (parked[1..]) |wait| earliest = @min(earliest, wait.deadline_ms);
    const remaining = @max(earliest - now_ms, 0);
    return @intCast(@min(remaining, std.math.maxInt(i32)));
}

fn resolveParkedWaits(ctx: *const ControlContext, parked: *ParkedWaits, now_ms: i64) void {
    var idx = parked.len;
    while (idx > 0) {
        idx -= 1;
        const wait = parked.items[idx];
        const record = boardRecord(ctx, wait.session_id);
        const outcome = agent_state.evaluateWait(wait.condition, record);
        if (outcome == .pending and now_ms < wait.deadline_ms) continue;

        writeWaitResult(ctx, wait.fd, record, outcome);
        _ = std.c.close(wait.fd);
        parked.swapRemove(idx);
    }
}

/// The board only drops exited records, so a parked wait whose record is
/// gone is reported as exited.
fn boardRecord(ctx: *const ControlContext, session_id: usize) agent_state.Record {
    return ctx.board.get(ctx.io, session_id) orelse .{
        .session_id = session_id,
        .state = .exited,
        .seq = 0,
    };
}

fn waitStatus(outcome: agent_state.WaitOutcome) WaitStatus {
    return switch (outcome) {
        .matched => .matched,
        .exited => .exited,
        .pending => .timed_out,
    };
}

fn writeWaitResult(ctx: *const ControlContext, fd: posix.fd_t, record: agent_state.Record, outcome: agent_state.WaitOutcome) void {
    const reply = successReply(ctx.allocator, WaitResult, .{
        .status = waitStatus(outcome),
        .instance_id = ctx.instance_id.slice(),
        .session_id = record.session_id,
        .agent_state = record.state,
        .state_seq = record.seq,
    }) catch |err| {
        log.warn("failed to serialize wait reply: {}", .{err});
        writeFailure(ctx.allocator, ctx.io, fd, .{ .code = .internal_error, .message = "failed to serialize the reply" });
        return;
    };
    writeReply(ctx.allocator, ctx.io, fd, reply);
}

/// Returns true when the connection was parked and must stay open.
fn handleControlConnection(ctx: *const ControlContext, conn_fd: posix.fd_t, parked: *ParkedWaits) bool {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const bytes = readLineFromFdWithTimeout(allocator, io, conn_fd, max_message_bytes, control_request_read_timeout_ms) catch |err| {
        log.debug("failed to read control request: {}", .{err});
        writeFailure(allocator, io, conn_fd, .{ .code = .invalid_request, .message = "invalid control request" });
        return false;
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        writeFailure(allocator, io, conn_fd, .{ .code = .invalid_request, .message = "request is not valid JSON" });
        return false;
    };
    defer parsed.deinit();

    var request = parseRequest(allocator, parsed.value) catch |err| {
        writeFailure(allocator, io, conn_fd, .{ .code = .invalid_request, .message = parseErrorMessage(err) });
        return false;
    };

    // The client picked this socket from a discovery file; a stale file (or a
    // reused pid) can point it at another app, whose session ids mean
    // something else entirely.
    if (request.targetInstance()) |target| {
        if (!ctx.instance_id.eql(target.slice())) {
            request.deinit(allocator);
            writeFailure(allocator, io, conn_fd, .{
                .code = .instance_not_found,
                .message = "the request names a different Architect instance",
            });
            return false;
        }
    }

    switch (request) {
        .wait_for_session => |wait| return handleWaitRequest(ctx, conn_fd, wait, parked),
        else => {},
    }

    var completion = Completion{};
    ctx.queue.push(allocator, io, .{
        .request = request,
        .completion = &completion,
    }) catch |err| {
        request.deinit(allocator);
        switch (err) {
            error.QueueClosed => writeFailure(allocator, io, conn_fd, .{ .code = .app_not_running, .message = "Architect is shutting down" }),
            error.OutOfMemory => {
                log.warn("failed to queue control request: {}", .{err});
                writeFailure(allocator, io, conn_fd, .{ .code = .internal_error, .message = "failed to queue the request" });
            },
        }
        return false;
    };

    if (ctx.runtime_wake) |waker| {
        waker.notify();
    }

    writeReply(allocator, io, conn_fd, completion.wait(io));
    return false;
}

fn handleWaitRequest(ctx: *const ControlContext, conn_fd: posix.fd_t, wait: WaitRequest, parked: *ParkedWaits) bool {
    const record = ctx.board.get(ctx.io, wait.session_id) orelse {
        writeFailure(ctx.allocator, ctx.io, conn_fd, .{
            .code = .session_not_found,
            .message = "no Architect session has this id",
        });
        return false;
    };

    const outcome = agent_state.evaluateWait(wait.condition, record);
    if (outcome != .pending or wait.timeout_ms == 0) {
        writeWaitResult(ctx, conn_fd, record, outcome);
        return false;
    }

    parked.append(.{
        .fd = conn_fd,
        .session_id = wait.session_id,
        .condition = wait.condition,
        .deadline_ms = clock.nowMillis(ctx.io) + wait.timeout_ms,
    }) catch {
        writeFailure(ctx.allocator, ctx.io, conn_fd, .{
            .code = .too_many_waiters,
            .message = "too many wait_for_session calls are in progress",
        });
        return false;
    };
    return true;
}

fn writeReply(allocator: std.mem.Allocator, io: std.Io, fd: posix.fd_t, reply: Reply) void {
    switch (reply) {
        .success => |payload| {
            defer allocator.free(payload);
            writeAllWithTimeout(io, fd, payload, control_response_write_timeout_ms) catch |err| {
                log.debug("failed to write control reply: {}", .{err});
            };
        },
        .failure => |failure| writeFailure(allocator, io, fd, failure),
    }
}

fn writeFailure(allocator: std.mem.Allocator, io: std.Io, fd: posix.fd_t, failure: Failure) void {
    const payload = failurePayloadAlloc(allocator, failure) catch |err| {
        log.warn("failed to serialize control failure: {}", .{err});
        return;
    };
    defer allocator.free(payload);
    writeAllWithTimeout(io, fd, payload, control_response_write_timeout_ms) catch |err| {
        log.debug("failed to write control failure: {}", .{err});
    };
}

/// Writes all of `bytes` to a possibly non-blocking fd, waiting for
/// writability so a large reply is not cut off when the socket buffer fills.
fn writeAllWithTimeout(io: std.Io, fd: posix.fd_t, bytes: []const u8, timeout_ms: i64) !void {
    const deadline_ms = clock.nowMillis(io) + timeout_ms;
    var written: usize = 0;
    while (written < bytes.len) {
        const n = posix_util.write(fd, bytes[written..]) catch |err| switch (err) {
            error.WouldBlock => {
                const remaining = deadline_ms - clock.nowMillis(io);
                if (remaining <= 0) return error.TimedOut;
                var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                const ready = try posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32))));
                if (ready == 0) return error.TimedOut;
                continue;
            },
            else => return err,
        };
        written += n;
    }
}

fn setFdNonBlocking(fd: posix.fd_t, context: []const u8) void {
    const flags = posix_util.fcntl(fd, posix.F.GETFL, 0) catch |err| {
        log.warn("failed to get {s} flags: {}", .{ context, err });
        return;
    };

    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    if (posix_util.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
        log.warn("failed to set {s} non-blocking: {}", .{ context, err });
    }
}

fn writeDiscoveryFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, socket_path: []const u8, instance_id: []const u8) !void {
    const payload = try discoveryPayloadAlloc(allocator, socket_path, instance_id);
    defer allocator.free(payload);

    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidDiscoveryPath;
    const base_name = std.fs.path.basename(path);

    var dir = if (std.fs.path.isAbsolute(dir_path))
        try std.Io.Dir.openDirAbsolute(io, dir_path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var random_suffix: u64 = undefined;
    std.Io.random(io, std.mem.asBytes(&random_suffix));
    const temp_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.{x}.tmp",
        .{ base_name, random_suffix },
    );
    defer allocator.free(temp_name);

    var file = try dir.createFile(io, temp_name, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    var file_open = true;
    errdefer if (file_open) file.close(io);
    errdefer deleteTempDiscoveryFile(io, &dir, temp_name);

    try file.setPermissions(io, .fromMode(0o600));
    try file.writeStreamingAll(io, payload);
    try file.sync(io);
    file.close(io);
    file_open = false;

    try dir.rename(temp_name, dir, base_name, io);
    log.info("wrote control discovery file {s} for socket {s}", .{ path, socket_path });
}

fn deleteTempDiscoveryFile(io: std.Io, dir: *std.Io.Dir, temp_name: []const u8) void {
    dir.deleteFile(io, temp_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to delete temporary control discovery file {s}: {}", .{ temp_name, err }),
    };
}

fn discoveryPayloadAlloc(allocator: std.mem.Allocator, socket_path: []const u8, instance_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try json.beginObject();
    try json.objectField("pid");
    try json.write(std.c.getpid());
    try json.objectField("socket_path");
    try json.write(socket_path);
    try json.objectField("instance_id");
    try json.write(instance_id);
    try json.endObject();
    try out.writer.writeByte('\n');

    return try allocator.dupe(u8, out.written());
}

fn readLineFromFd(allocator: std.mem.Allocator, io: std.Io, fd: posix.fd_t, max_bytes: usize) ![]u8 {
    return try readLineFromFdWithTimeout(allocator, io, fd, max_bytes, null);
}

fn readLineFromFdWithTimeout(
    allocator: std.mem.Allocator,
    io: std.Io,
    fd: posix.fd_t,
    max_bytes: usize,
    timeout_ms: ?i64,
) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    const deadline_ms = if (timeout_ms) |ms| clock.nowMillis(io) + ms else null;
    var tmp: [512]u8 = undefined;
    while (true) {
        if (deadline_ms) |deadline| {
            const now = clock.nowMillis(io);
            if (now >= deadline) return error.TimedOut;

            const remaining_ms = deadline - now;
            const poll_timeout: i32 = @intCast(@min(remaining_ms, std.math.maxInt(i32)));
            var fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, poll_timeout);
            if (ready == 0) return error.TimedOut;
        }

        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        const n = file.readStreaming(io, &.{&tmp}) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) break;

        for (tmp[0..n]) |byte| {
            if (byte == '\n') {
                return try buffer.toOwnedSlice(allocator);
            }
            if (byte == '\r') continue;
            if (buffer.items.len >= max_bytes) return error.MessageTooLarge;
            try buffer.append(allocator, byte);
        }
    }

    if (buffer.items.len == 0) return error.EndOfStream;
    return try buffer.toOwnedSlice(allocator);
}

pub const ClientReply = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    outcome: Outcome,

    pub const Outcome = union(enum) {
        /// The `result` object; points into `parsed`.
        success: std.json.Value,
        /// `message` points into `parsed` or static memory.
        failure: Failure,
    };

    pub fn deinit(self: *ClientReply) void {
        if (self.parsed) |*parsed| parsed.deinit();
        self.* = undefined;
    }
};

/// Sends one request to the newest reachable Architect instance and returns
/// its reply. `arguments` is forwarded as-is; the app validates it again.
/// Sends one request and returns its reply. With a `target` instance id the
/// request goes to that app only; without one it goes to the newest
/// reachable app. A target that is not running is an error, never a reason
/// to fall back to another app: session ids are only unique per app.
pub fn sendRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    op: Op,
    arguments: ?std.json.Value,
    target: ?[]const u8,
) !ClientReply {
    var runtime_dir = try controlRuntimeDirAlloc(allocator, io);
    defer runtime_dir.deinit(allocator);
    return sendRequestIn(allocator, io, runtime_dir.path, op, arguments, target);
}

fn sendRequestIn(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_dir: []const u8,
    op: Op,
    arguments: ?std.json.Value,
    target: ?[]const u8,
) !ClientReply {
    var connection = connectToControlSocket(allocator, io, runtime_dir, target) catch |err| switch (err) {
        error.NoControlDiscoveryFile => return staticFailure(.app_not_running, "Architect is not running"),
        error.NoLiveControlSocket => return staticFailure(.app_not_running, "Architect is not accepting control requests"),
        error.TargetInstanceNotRunning => return staticFailure(.instance_not_found, "the Architect instance named by instance_id is not running"),
        else => return err,
    };
    defer connection.deinit(allocator);

    const payload = try requestPayloadAlloc(allocator, op, arguments);
    defer allocator.free(payload);
    try writeAllWithTimeout(io, connection.fd, payload, control_response_write_timeout_ms);

    const response_bytes = try readLineFromFd(allocator, io, connection.fd, max_message_bytes);
    defer allocator.free(response_bytes);
    return try parseClientReply(allocator, response_bytes);
}

fn staticFailure(code: ErrorCode, message: []const u8) ClientReply {
    return .{ .outcome = .{ .failure = .{ .code = code, .message = message } } };
}

fn parseClientReply(allocator: std.mem.Allocator, bytes: []const u8) !ClientReply {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidControlResponse;
    const object = parsed.value.object;
    const ok_value = object.get("ok") orelse return error.InvalidControlResponse;
    if (ok_value != .bool) return error.InvalidControlResponse;

    if (ok_value.bool) {
        const result = object.get("result") orelse return error.InvalidControlResponse;
        if (result != .object) return error.InvalidControlResponse;
        return .{ .parsed = parsed, .outcome = .{ .success = result } };
    }

    const code_value = object.get("code") orelse return error.InvalidControlResponse;
    const message_value = object.get("message") orelse return error.InvalidControlResponse;
    if (code_value != .string or message_value != .string) return error.InvalidControlResponse;
    const code = ErrorCode.fromString(code_value.string) orelse return error.InvalidControlResponse;
    return .{
        .parsed = parsed,
        .outcome = .{ .failure = .{ .code = code, .message = message_value.string } },
    };
}

const ControlConnection = struct {
    fd: posix.fd_t,
    socket_path: []const u8,

    fn deinit(self: *ControlConnection, allocator: std.mem.Allocator) void {
        _ = std.c.close(self.fd);
        allocator.free(self.socket_path);
        self.* = undefined;
    }
};

const DiscoveryCandidate = struct {
    socket_path: []const u8,
    /// Null for discovery files written by Architect versions without one.
    instance_id: ?[]const u8,
    mtime: std.Io.Timestamp,

    fn deinit(self: *DiscoveryCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.socket_path);
        if (self.instance_id) |id| allocator.free(id);
        self.* = undefined;
    }
};

const DiscoveryEntry = struct {
    socket_path: []const u8,
    instance_id: ?[]const u8,
};

fn connectToControlSocket(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_dir: []const u8,
    target: ?[]const u8,
) !ControlConnection {
    var candidates = try discoverControlCandidates(allocator, io, runtime_dir);
    defer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    if (candidates.items.len == 0) return error.NoControlDiscoveryFile;

    if (target) |wanted| {
        var idx: usize = candidates.items.len;
        while (idx > 0) {
            idx -= 1;
            const matches = if (candidates.items[idx].instance_id) |id| std.mem.eql(u8, id, wanted) else false;
            if (matches) continue;
            var removed = candidates.swapRemove(idx);
            removed.deinit(allocator);
        }
        if (candidates.items.len == 0) return error.TargetInstanceNotRunning;
    }

    while (candidates.items.len > 0) {
        const idx = newestDiscoveryCandidateIndex(candidates.items);
        const candidate = candidates.items[idx];
        const fd = connectControlSocket(io, candidate.socket_path) catch |err| {
            log.debug("failed to connect to discovered control socket {s}: {}", .{ candidate.socket_path, err });
            var removed = candidates.swapRemove(idx);
            removed.deinit(allocator);
            continue;
        };
        errdefer _ = std.c.close(fd);
        return .{
            .fd = fd,
            .socket_path = try allocator.dupe(u8, candidate.socket_path),
        };
    }

    return if (target != null) error.TargetInstanceNotRunning else error.NoLiveControlSocket;
}

fn discoverControlCandidates(allocator: std.mem.Allocator, io: std.Io, runtime_dir: []const u8) !std.ArrayList(DiscoveryCandidate) {
    var candidates: std.ArrayList(DiscoveryCandidate) = .empty;
    errdefer {
        for (candidates.items) |*candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }

    var dir = std.Io.Dir.openDirAbsolute(io, runtime_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return candidates,
        else => return err,
    };
    defer dir.close(io);

    const prefix = try controlDiscoveryFilePrefixAlloc(allocator);
    defer allocator.free(prefix);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isOwnControlDiscoveryFileName(entry.name, prefix)) continue;

        const stat = dir.statFile(io, entry.name, .{}) catch |err| {
            log.debug("failed to stat control discovery file {s}: {}", .{ entry.name, err });
            continue;
        };
        const discovery = dir.readFileAlloc(io, entry.name, allocator, .limited(max_message_bytes)) catch |err| {
            log.debug("failed to read control discovery file {s}: {}", .{ entry.name, err });
            continue;
        };
        defer allocator.free(discovery);

        const parsed_entry = parseDiscoveryEntry(allocator, discovery) catch |err| {
            log.debug("failed to parse control discovery file {s}: {}", .{ entry.name, err });
            continue;
        };

        candidates.append(allocator, .{
            .socket_path = parsed_entry.socket_path,
            .instance_id = parsed_entry.instance_id,
            .mtime = stat.mtime,
        }) catch |err| {
            allocator.free(parsed_entry.socket_path);
            if (parsed_entry.instance_id) |id| allocator.free(id);
            return err;
        };
    }

    return candidates;
}

fn newestDiscoveryCandidateIndex(candidates: []const DiscoveryCandidate) usize {
    var newest_idx: usize = 0;
    for (candidates[1..], 1..) |candidate, idx| {
        if (candidate.mtime.nanoseconds > candidates[newest_idx].mtime.nanoseconds) {
            newest_idx = idx;
        }
    }
    return newest_idx;
}

fn connectControlSocket(io: std.Io, socket_path: []const u8) !posix.fd_t {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    return stream.socket.handle;
}

fn parseDiscoveryEntry(allocator: std.mem.Allocator, bytes: []const u8) !DiscoveryEntry {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDiscovery;
    const socket_value = parsed.value.object.get("socket_path") orelse return error.InvalidDiscovery;
    if (socket_value != .string or socket_value.string.len == 0) return error.InvalidDiscovery;
    const instance_value = parsed.value.object.get("instance_id");
    if (instance_value) |value| {
        if (value != .string) return error.InvalidDiscovery;
    }

    const socket_path = try allocator.dupe(u8, socket_value.string);
    errdefer allocator.free(socket_path);
    const instance_id = if (instance_value) |value| try allocator.dupe(u8, value.string) else null;
    return .{ .socket_path = socket_path, .instance_id = instance_id };
}

fn parseRequestText(allocator: std.mem.Allocator, text: []const u8) !Request {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    return parseRequest(allocator, parsed.value);
}

test "parseRequest accepts every operation and applies defaults" {
    const allocator = std.testing.allocator;

    var spawn = try parseRequestText(allocator, "{\"op\":\"spawn_session\",\"arguments\":{\"cwd\":\"/tmp\",\"command\":\"pwd\",\"display_name\":\"Task\"}}");
    defer spawn.deinit(allocator);
    try std.testing.expectEqualStrings("/tmp", spawn.spawn_session.cwd);
    try std.testing.expectEqualStrings("pwd", spawn.spawn_session.command.?);
    try std.testing.expectEqualStrings("Task", spawn.spawn_session.display_name.?);

    var list = try parseRequestText(allocator, "{\"op\":\"list_sessions\"}");
    defer list.deinit(allocator);
    try std.testing.expect(list == .list_sessions);
    try std.testing.expectEqual(@as(?InstanceId, null), list.targetInstance());

    var targeted_list = try parseRequestText(allocator, "{\"op\":\"list_sessions\",\"arguments\":{\"instance_id\":\"42-0f\"}}");
    defer targeted_list.deinit(allocator);
    const target = targeted_list.targetInstance() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42-0f", target.slice());

    var send = try parseRequestText(allocator, "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":4,\"text\":\"hello\"}}");
    defer send.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), send.send_input.session_id);
    try std.testing.expectEqualStrings("hello", send.send_input.text);
    try std.testing.expect(send.send_input.submit);
    try std.testing.expect(!send.send_input.require_idle);

    var wait = try parseRequestText(allocator, "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":2,\"until\":[\"idle\",\"exited\"],\"after_seq\":9,\"timeout_ms\":0}}");
    defer wait.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), wait.wait_for_session.session_id);
    try std.testing.expect(wait.wait_for_session.condition.until.contains(.idle));
    try std.testing.expect(wait.wait_for_session.condition.until.contains(.exited));
    try std.testing.expect(!wait.wait_for_session.condition.until.contains(.working));
    try std.testing.expectEqual(@as(u64, 9), wait.wait_for_session.condition.after_seq);
    try std.testing.expectEqual(@as(u32, 0), wait.wait_for_session.timeout_ms);

    var default_wait = try parseRequestText(allocator, "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":2,\"until\":[\"idle\"]}}");
    defer default_wait.deinit(allocator);
    try std.testing.expectEqual(default_wait_timeout_ms, default_wait.wait_for_session.timeout_ms);
    try std.testing.expectEqual(@as(u64, 0), default_wait.wait_for_session.condition.after_seq);

    var terminate = try parseRequestText(allocator, "{\"op\":\"terminate_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":0}}");
    defer terminate.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), terminate.terminate_session.session_id);
}

test "parseRequest rejects invalid shapes with specific errors" {
    const allocator = std.testing.allocator;

    const Case = struct { text: []const u8, err: ParseError };
    const cases = [_]Case{
        .{ .text = "[]", .err = error.ExpectedObject },
        .{ .text = "{}", .err = error.MissingOp },
        .{ .text = "{\"op\":\"reboot\"}", .err = error.UnknownOp },
        .{ .text = "{\"op\":\"list_sessions\",\"extra\":1}", .err = error.UnknownField },
        .{ .text = "{\"op\":\"list_sessions\",\"arguments\":[]}", .err = error.InvalidArguments },
        .{ .text = "{\"op\":\"list_sessions\",\"arguments\":{\"x\":1}}", .err = error.UnknownField },
        .{ .text = "{\"op\":\"spawn_session\",\"arguments\":{}}", .err = error.MissingCwd },
        .{ .text = "{\"op\":\"spawn_session\",\"arguments\":{\"cwd\":\"\"}}", .err = error.InvalidCwd },
        .{ .text = "{\"op\":\"spawn_session\",\"arguments\":{\"cwd\":7}}", .err = error.InvalidCwd },
        .{ .text = "{\"op\":\"spawn_session\",\"arguments\":{\"cwd\":\"/tmp\",\"command\":\"\"}}", .err = error.InvalidCommand },
        .{ .text = "{\"op\":\"spawn_session\",\"arguments\":{\"cwd\":\"/tmp\",\"extra\":true}}", .err = error.UnknownField },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"text\":\"hi\"}}", .err = error.MissingSessionId },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":-1,\"text\":\"hi\"}}", .err = error.InvalidSessionId },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1}}", .err = error.MissingText },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"text\":\"\"}}", .err = error.InvalidText },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"text\":\"a\\u0000b\"}}", .err = error.InvalidText },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"text\":\"hi\",\"submit\":\"yes\"}}", .err = error.InvalidSubmit },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"text\":\"hi\",\"require_idle\":1}}", .err = error.InvalidRequireIdle },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1}}", .err = error.MissingUntil },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"until\":[]}}", .err = error.InvalidUntil },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"until\":[\"sleeping\"]}}", .err = error.InvalidUntil },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"until\":[\"idle\"],\"after_seq\":-2}}", .err = error.InvalidAfterSeq },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"until\":[\"idle\"],\"timeout_ms\":600001}}", .err = error.InvalidTimeout },
        .{ .text = "{\"op\":\"terminate_session\",\"arguments\":{\"instance_id\":\"1-ab\"}}", .err = error.MissingSessionId },
        .{ .text = "{\"op\":\"terminate_session\",\"arguments\":{\"session_id\":1}}", .err = error.MissingInstanceId },
        .{ .text = "{\"op\":\"send_input\",\"arguments\":{\"session_id\":1,\"text\":\"hi\"}}", .err = error.MissingInstanceId },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"session_id\":1,\"until\":[\"idle\"]}}", .err = error.MissingInstanceId },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"\",\"session_id\":1,\"until\":[\"idle\"]}}", .err = error.InvalidInstanceId },
        .{ .text = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"../x\",\"session_id\":1,\"until\":[\"idle\"]}}", .err = error.InvalidInstanceId },
        .{ .text = "{\"op\":\"list_sessions\",\"arguments\":{\"instance_id\":7}}", .err = error.InvalidInstanceId },
        .{ .text = "{\"op\":\"terminate_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"force\":true}}", .err = error.UnknownField },
    };

    for (cases) |case| {
        if (parseRequestText(allocator, case.text)) |request| {
            var owned = request;
            owned.deinit(allocator);
            std.debug.print("unexpectedly accepted: {s}\n", .{case.text});
            return error.TestUnexpectedResult;
        } else |err| {
            std.testing.expectEqual(case.err, err) catch |expect_err| {
                std.debug.print("wrong error for: {s}\n", .{case.text});
                return expect_err;
            };
        }
    }
}

test "spawn_session accepts commands up to the terminal line limit and rejects longer ones" {
    const allocator = std.testing.allocator;
    const command = try allocator.alloc(u8, max_command_bytes + 1);
    defer allocator.free(command);
    @memset(command, 'x');

    const fits = try std.fmt.allocPrint(allocator, "{{\"op\":\"spawn_session\",\"arguments\":{{\"cwd\":\"/tmp\",\"command\":\"{s}\"}}}}", .{command[0..max_command_bytes]});
    defer allocator.free(fits);
    var accepted = try parseRequestText(allocator, fits);
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(max_command_bytes, accepted.spawn_session.command.?.len);

    const too_long = try std.fmt.allocPrint(allocator, "{{\"op\":\"spawn_session\",\"arguments\":{{\"cwd\":\"/tmp\",\"command\":\"{s}\"}}}}", .{command});
    defer allocator.free(too_long);
    try std.testing.expectError(error.InvalidCommand, parseRequestText(allocator, too_long));
}

test "send_input rejects text above the size limit" {
    const allocator = std.testing.allocator;
    const text = try allocator.alloc(u8, max_text_bytes + 1);
    defer allocator.free(text);
    @memset(text, 'x');

    const request = try std.fmt.allocPrint(allocator, "{{\"op\":\"send_input\",\"arguments\":{{\"instance_id\":\"1-ab\",\"session_id\":1,\"text\":\"{s}\"}}}}", .{text});
    defer allocator.free(request);
    try std.testing.expectError(error.InvalidText, parseRequestText(allocator, request));
}

test "request payloads round-trip through parseRequest" {
    const allocator = std.testing.allocator;

    var arguments = try std.json.parseFromSlice(std.json.Value, allocator, "{\"instance_id\":\"1-ab\",\"session_id\":3,\"text\":\"line one\\nline two\",\"submit\":false}", .{});
    defer arguments.deinit();
    const payload = try requestPayloadAlloc(allocator, .send_input, arguments.value);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.endsWith(u8, payload, "\n"));

    var request = try parseRequestText(allocator, std.mem.trimEnd(u8, payload, "\n"));
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), request.send_input.session_id);
    try std.testing.expectEqualStrings("line one\nline two", request.send_input.text);
    try std.testing.expect(!request.send_input.submit);

    const list_payload = try requestPayloadAlloc(allocator, .list_sessions, null);
    defer allocator.free(list_payload);
    var list = try parseRequestText(allocator, std.mem.trimEnd(u8, list_payload, "\n"));
    defer list.deinit(allocator);
    try std.testing.expect(list == .list_sessions);
}

test "replies round-trip success results and failures" {
    const allocator = std.testing.allocator;

    const sessions = [_]SessionInfo{.{
        .session_id = 42,
        .slot_index = 3,
        .cwd = "/tmp/project",
        .foreground_agent = null,
        .agent_state = .awaiting_approval,
        .state_seq = 17,
    }};
    const reply = try successReply(allocator, ListResult, .{ .instance_id = "1-ab", .sessions = &sessions });
    defer allocator.free(reply.success);

    var success = try parseClientReply(allocator, reply.success);
    defer success.deinit();
    const result = success.outcome.success.object;
    try std.testing.expectEqualStrings("ok", result.get("status").?.string);
    const session = (result.get("sessions") orelse return error.TestUnexpectedResult).array.items[0].object;
    try std.testing.expectEqual(@as(i64, 42), session.get("session_id").?.integer);
    try std.testing.expectEqualStrings("/tmp/project", session.get("cwd").?.string);
    try std.testing.expect(session.get("foreground_agent").? == .null);
    try std.testing.expectEqualStrings("awaiting_approval", session.get("agent_state").?.string);
    try std.testing.expectEqual(@as(i64, 17), session.get("state_seq").?.integer);

    const failure_payload = try failurePayloadAlloc(allocator, .{ .code = .session_busy, .message = "agent is working" });
    defer allocator.free(failure_payload);
    var failure = try parseClientReply(allocator, failure_payload);
    defer failure.deinit();
    try std.testing.expectEqual(ErrorCode.session_busy, failure.outcome.failure.code);
    try std.testing.expectEqualStrings("agent is working", failure.outcome.failure.message);

    try std.testing.expectError(error.InvalidControlResponse, parseClientReply(allocator, "{\"ok\":true}"));
    try std.testing.expectError(error.InvalidControlResponse, parseClientReply(allocator, "{\"ok\":false,\"code\":\"nope\",\"message\":\"x\"}"));
}

test "RequestQueue drains queued requests" {
    const allocator = std.testing.allocator;
    var queue = RequestQueue{};
    defer queue.deinit(allocator);

    var completion = Completion{};
    try queue.push(allocator, std.testing.io, .{
        .request = .{ .spawn_session = .{ .cwd = try allocator.dupe(u8, "/tmp") } },
        .completion = &completion,
    });

    var pending = queue.drainAll(std.testing.io);
    defer pending.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    pending.items[0].request.deinit(allocator);

    var empty = queue.drainAll(std.testing.io);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

/// Runs a control listener on a socket under `.tmp` for tests, with the board
/// wired to the listener's wake pipe the way the runtime wires it.
const TestServer = struct {
    allocator: std.mem.Allocator,
    queue: RequestQueue = .{},
    board: agent_state.Board = .{},
    stop: std.atomic.Value(bool) = .init(false),
    wake: wake_pipe.WakePipe,
    sock_path_buf: [128]u8 = undefined,
    sock_path: [:0]const u8 = undefined,
    discovery_path: []u8 = &.{},
    instance_id: []const u8 = "1-ab",
    /// Where to publish the discovery file under its real name, so client
    /// discovery can find it. Null keeps it out of any discovery scan.
    discovery_dir: ?[]const u8 = null,
    thread: ?std.Thread = null,

    fn start(self: *TestServer, name: []const u8) !void {
        const io = std.testing.io;
        std.Io.Dir.cwd().createDirPath(io, ".tmp") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        self.sock_path = try std.fmt.bufPrintSentinel(&self.sock_path_buf, ".tmp/ctl_{s}_{d}.sock", .{ name, std.c.getpid() }, 0);
        self.discovery_path = if (self.discovery_dir) |dir|
            try std.fmt.allocPrint(self.allocator, "{s}/{s}{d}_{s}{s}", .{ dir, discovery_file_prefix, std.c.getuid(), name, discovery_file_suffix })
        else
            try std.fmt.allocPrint(self.allocator, ".tmp/ctl_{s}_{d}.json", .{ name, std.c.getpid() });
        self.board.on_change = .{ .context = &self.wake, .callback = signalWake };
        self.thread = try startControlThread(
            self.allocator,
            io,
            self.sock_path,
            self.discovery_path,
            try InstanceId.fromSlice(self.instance_id),
            &self.queue,
            &self.board,
            &self.stop,
            &self.wake,
            null,
        );
        // The listener writes the discovery file only after it is listening.
        const deadline = clock.nowMillis(io) + 5000;
        while (true) {
            std.Io.Dir.cwd().access(io, self.discovery_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    if (clock.nowMillis(io) >= deadline) return error.ListenerDidNotStart;
                    clock.sleepNanos(io, 5 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break;
        }
    }

    fn signalWake(context: ?*anyopaque) void {
        const pipe: *const wake_pipe.WakePipe = @ptrCast(@alignCast(context.?));
        pipe.signal();
    }

    fn deinit(self: *TestServer) void {
        const io = std.testing.io;
        if (self.thread) |thread| {
            self.stop.store(true, .seq_cst);
            self.wake.signal();
            thread.join();
        }
        std.Io.Dir.cwd().deleteFile(io, self.sock_path) catch |err| std.debug.print("cleanup failed: {}\n", .{err});
        std.Io.Dir.cwd().deleteFile(io, self.discovery_path) catch |err| std.debug.print("cleanup failed: {}\n", .{err});
        self.allocator.free(self.discovery_path);
        self.board.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.wake.deinit();
    }
};

/// Sends one request line and returns the reply line; used from a client thread.
fn testRoundTrip(allocator: std.mem.Allocator, sock_path: []const u8, request: []const u8) ![]u8 {
    const io = std.testing.io;
    const fd = try connectControlSocket(io, sock_path);
    defer _ = std.c.close(fd);
    try writeAllWithTimeout(io, fd, request, control_response_write_timeout_ms);
    return try readLineFromFd(allocator, io, fd, max_message_bytes);
}

const TestClient = struct {
    sock_path: []const u8,
    request: []const u8,
    reply: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *TestClient) void {
        self.reply = testRoundTrip(std.testing.allocator, self.sock_path, self.request) catch |err| {
            self.err = err;
            return;
        };
    }
};

fn expectWaitReply(reply: []const u8, status: []const u8, state: []const u8) !void {
    var parsed = try parseClientReply(std.testing.allocator, reply);
    defer parsed.deinit();
    const result = parsed.outcome.success.object;
    try std.testing.expectEqualStrings(status, result.get("status").?.string);
    try std.testing.expectEqualStrings(state, result.get("agent_state").?.string);
}

test "wait_for_session parks on the listener and resolves when the board changes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init() };
    defer server.deinit();
    try server.start("wait");

    try server.board.track(allocator, io, 5);
    const delivered_seq = server.board.markDelivered(io, 5) orelse return error.TestUnexpectedResult;

    var request_buf: [160]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "{{\"op\":\"wait_for_session\",\"arguments\":{{\"instance_id\":\"1-ab\",\"session_id\":5,\"until\":[\"idle\"],\"after_seq\":{d},\"timeout_ms\":10000}}}}\n",
        .{delivered_seq},
    );
    var client = TestClient{ .sock_path = server.sock_path, .request = request };
    const client_thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});

    // The wait must still be parked: nothing changed on the board yet.
    clock.sleepNanos(io, 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(?[]u8, null), client.reply);

    const started = clock.nowNanos(io);
    _ = server.board.applyHook(io, 5, .done);
    client_thread.join();
    const elapsed_ns = clock.nowNanos(io) - started;

    if (client.err) |err| return err;
    const reply = client.reply orelse return error.TestUnexpectedResult;
    defer allocator.free(reply);
    try expectWaitReply(reply, "matched", "idle");
    try std.testing.expect(elapsed_ns < 2 * std.time.ns_per_s);
}

test "a parked wait survives a client that half-closes after sending its request" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init() };
    defer server.deinit();
    try server.start("halfclose");
    try server.board.track(allocator, io, 6);

    const HalfCloseClient = struct {
        sock_path: []const u8,
        reply: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.reply = self.roundTrip() catch |err| {
                self.err = err;
                return;
            };
        }

        fn roundTrip(self: *@This()) ![]u8 {
            const fd = try connectControlSocket(std.testing.io, self.sock_path);
            defer _ = std.c.close(fd);
            try writeAllWithTimeout(
                std.testing.io,
                fd,
                "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":6,\"until\":[\"idle\"],\"timeout_ms\":10000}}\n",
                control_response_write_timeout_ms,
            );
            if (std.c.shutdown(fd, std.c.SHUT.WR) != 0) return error.ShutdownFailed;
            return try readLineFromFd(std.testing.allocator, std.testing.io, fd, max_message_bytes);
        }
    };

    var client = HalfCloseClient{ .sock_path = server.sock_path };
    const client_thread = try std.Thread.spawn(.{}, HalfCloseClient.run, .{&client});
    // Let the listener park the wait and observe the request-side EOF.
    clock.sleepNanos(io, 150 * std.time.ns_per_ms);
    _ = server.board.applyHook(io, 6, .done);
    client_thread.join();

    if (client.err) |err| return err;
    const reply = client.reply orelse return error.TestUnexpectedResult;
    defer allocator.free(reply);
    try expectWaitReply(reply, "matched", "idle");
}

test "wait_for_session reports timeouts, exits, and unknown sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init() };
    defer server.deinit();
    try server.start("waitend");

    try server.board.track(allocator, io, 1);

    {
        const reply = try testRoundTrip(allocator, server.sock_path, "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"until\":[\"idle\"],\"timeout_ms\":50}}\n");
        defer allocator.free(reply);
        try expectWaitReply(reply, "timed_out", "unknown");
    }
    {
        const reply = try testRoundTrip(allocator, server.sock_path, "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"until\":[\"unknown\"],\"timeout_ms\":0}}\n");
        defer allocator.free(reply);
        try expectWaitReply(reply, "matched", "unknown");
    }
    {
        var client = TestClient{
            .sock_path = server.sock_path,
            .request = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":1,\"until\":[\"idle\"],\"timeout_ms\":10000}}\n",
        };
        const client_thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
        clock.sleepNanos(io, 50 * std.time.ns_per_ms);
        server.board.markExited(io, 1);
        client_thread.join();
        if (client.err) |err| return err;
        const reply = client.reply orelse return error.TestUnexpectedResult;
        defer allocator.free(reply);
        try expectWaitReply(reply, "exited", "exited");
    }
    {
        const reply = try testRoundTrip(allocator, server.sock_path, "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":77,\"until\":[\"idle\"]}}\n");
        defer allocator.free(reply);
        var parsed = try parseClientReply(allocator, reply);
        defer parsed.deinit();
        try std.testing.expectEqual(ErrorCode.session_not_found, parsed.outcome.failure.code);
    }
}

test "main-thread operations are queued and answered with the completion's reply" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init() };
    defer server.deinit();
    try server.start("queue");

    var client = TestClient{
        .sock_path = server.sock_path,
        .request = "{\"op\":\"terminate_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":8}}\n",
    };
    const client_thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});

    const deadline = clock.nowMillis(io) + 5000;
    var pending = server.queue.drainAll(io);
    while (pending.items.len == 0 and clock.nowMillis(io) < deadline) {
        pending.deinit(allocator);
        clock.sleepNanos(io, 5 * std.time.ns_per_ms);
        pending = server.queue.drainAll(io);
    }
    defer pending.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    const item = &pending.items[0];
    try std.testing.expectEqual(@as(usize, 8), item.request.terminate_session.session_id);
    item.completion.succeed(allocator, io, TerminateResult, .{ .instance_id = "1-ab", .session_id = 8 });
    item.request.deinit(allocator);

    client_thread.join();
    if (client.err) |err| return err;
    const reply = client.reply orelse return error.TestUnexpectedResult;
    defer allocator.free(reply);
    var parsed = try parseClientReply(allocator, reply);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("terminated", parsed.outcome.success.object.get("status").?.string);
}

test "parked waits are answered when the listener shuts down" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init() };
    defer server.deinit();
    try server.start("shutdown");
    try server.board.track(allocator, io, 2);

    var client = TestClient{
        .sock_path = server.sock_path,
        .request = "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-ab\",\"session_id\":2,\"until\":[\"idle\"],\"timeout_ms\":600000}}\n",
    };
    const client_thread = try std.Thread.spawn(.{}, TestClient.run, .{&client});
    clock.sleepNanos(io, 50 * std.time.ns_per_ms);

    server.stop.store(true, .seq_cst);
    server.wake.signal();
    if (server.thread) |thread| thread.join();
    server.thread = null;
    client_thread.join();

    if (client.err) |err| return err;
    const reply = client.reply orelse return error.TestUnexpectedResult;
    defer allocator.free(reply);
    var parsed = try parseClientReply(allocator, reply);
    defer parsed.deinit();
    try std.testing.expectEqual(ErrorCode.app_not_running, parsed.outcome.failure.code);
}

test "session requests reach the instance that issued the session and never another one" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var discovery = std.testing.tmpDir(.{});
    defer discovery.cleanup();
    const discovery_dir = try discovery.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(discovery_dir);

    var first = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init(), .instance_id = "1-aa", .discovery_dir = discovery_dir };
    defer first.deinit();
    try first.start("insta");
    try first.board.track(allocator, io, 0);
    _ = first.board.applyHook(io, 0, .done);

    // Session ids restart in every app: the newer instance has a session 0 too.
    clock.sleepNanos(io, 20 * std.time.ns_per_ms);
    var second = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init(), .instance_id = "2-bb", .discovery_dir = discovery_dir };
    defer second.deinit();
    try second.start("instb");
    try second.board.track(allocator, io, 0);

    var arguments = try std.json.parseFromSlice(std.json.Value, allocator, "{\"instance_id\":\"1-aa\",\"session_id\":0,\"until\":[\"idle\"],\"timeout_ms\":0}", .{});
    defer arguments.deinit();

    {
        var reply = try sendRequestIn(allocator, io, discovery_dir, .wait_for_session, arguments.value, "1-aa");
        defer reply.deinit();
        const result = reply.outcome.success.object;
        try std.testing.expectEqualStrings("1-aa", result.get("instance_id").?.string);
        try std.testing.expectEqualStrings("idle", result.get("agent_state").?.string);
    }
    {
        // A request that reaches the wrong app is refused by that app.
        const reply = try testRoundTrip(
            allocator,
            second.sock_path,
            "{\"op\":\"wait_for_session\",\"arguments\":{\"instance_id\":\"1-aa\",\"session_id\":0,\"until\":[\"unknown\"],\"timeout_ms\":0}}\n",
        );
        defer allocator.free(reply);
        var parsed = try parseClientReply(allocator, reply);
        defer parsed.deinit();
        try std.testing.expectEqual(ErrorCode.instance_not_found, parsed.outcome.failure.code);
    }

    // The issuing app goes away but leaves its discovery file behind.
    first.stop.store(true, .seq_cst);
    first.wake.signal();
    if (first.thread) |thread| thread.join();
    first.thread = null;
    {
        var reply = try sendRequestIn(allocator, io, discovery_dir, .wait_for_session, arguments.value, "1-aa");
        defer reply.deinit();
        try std.testing.expectEqual(ErrorCode.instance_not_found, reply.outcome.failure.code);
        // Answered by the client itself, not by the other app's listener.
        try std.testing.expectEqualStrings("the Architect instance named by instance_id is not running", reply.outcome.failure.message);
    }
}

test "a request still being received when shutdown starts is refused instead of queued" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init() };
    defer server.deinit();
    try server.start("closing");

    const SlowClient = struct {
        sock_path: []const u8,
        reply: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.reply = self.roundTrip() catch |err| {
                self.err = err;
                return;
            };
        }

        fn roundTrip(self: *@This()) ![]u8 {
            const fd = try connectControlSocket(std.testing.io, self.sock_path);
            defer _ = std.c.close(fd);
            // The listener accepts and starts reading this request before
            // shutdown begins, then receives the rest after the queue closed.
            try writeAllWithTimeout(std.testing.io, fd, "{", control_response_write_timeout_ms);
            clock.sleepNanos(std.testing.io, 200 * std.time.ns_per_ms);
            try writeAllWithTimeout(std.testing.io, fd, "\"op\":\"list_sessions\"}\n", control_response_write_timeout_ms);
            return try readLineFromFd(std.testing.allocator, std.testing.io, fd, max_message_bytes);
        }
    };

    var client = SlowClient{ .sock_path = server.sock_path };
    const client_thread = try std.Thread.spawn(.{}, SlowClient.run, .{&client});
    clock.sleepNanos(io, 100 * std.time.ns_per_ms);

    // The runtime's shutdown order: stop, wake, fail the queue, then join.
    server.stop.store(true, .seq_cst);
    server.wake.signal();
    server.queue.closeAndFail(allocator, io, .app_not_running, "Architect is shutting down");
    client_thread.join();
    if (server.thread) |thread| thread.join();
    server.thread = null;

    if (client.err) |err| return err;
    const reply = client.reply orelse return error.TestUnexpectedResult;
    defer allocator.free(reply);
    var parsed = try parseClientReply(allocator, reply);
    defer parsed.deinit();
    try std.testing.expectEqual(ErrorCode.app_not_running, parsed.outcome.failure.code);

    var leftover = server.queue.drainAll(io);
    defer leftover.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), leftover.items.len);
}

test "control thread stops promptly when signaled while blocked in poll" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = TestServer{ .allocator = allocator, .wake = try wake_pipe.WakePipe.init() };
    defer server.deinit();
    try server.start("stop");

    const started = clock.nowNanos(io);
    server.stop.store(true, .seq_cst);
    server.wake.signal();
    if (server.thread) |thread| thread.join();
    server.thread = null;
    const elapsed_ns = clock.nowNanos(io) - started;
    try std.testing.expect(elapsed_ns < 200 * std.time.ns_per_ms);
}

test "control discovery file names are scoped to the current user and process" {
    const allocator = std.testing.allocator;

    const prefix = try controlDiscoveryFilePrefixAlloc(allocator);
    defer allocator.free(prefix);

    const file_name = try controlDiscoveryFileNameAlloc(allocator);
    defer allocator.free(file_name);

    try std.testing.expect(isOwnControlDiscoveryFileName(file_name, prefix));
    try std.testing.expect(!isOwnControlDiscoveryFileName("architect_control.json", prefix));
    try std.testing.expect(!isOwnControlDiscoveryFileName("not_architect_control_1_2.json", prefix));
}

test "fallback control runtime directory does not use TMPDIR" {
    const allocator = std.testing.allocator;
    env.initForTest();

    const path = try fallbackControlRuntimeDirAlloc(allocator);
    defer allocator.free(path);

    // The macOS fallback is ~/Library/Caches/Architect/runtime (capitalized),
    // the Linux one ~/.cache/architect/runtime, so match case-insensitively.
    try std.testing.expect(std.ascii.indexOfIgnoreCase(path, "architect") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "nix-shell.") == null);
}

test "newestDiscoveryCandidateIndex picks the highest mtime" {
    const candidates = [_]DiscoveryCandidate{
        .{ .socket_path = "/tmp/old.sock", .instance_id = null, .mtime = .fromNanoseconds(10) },
        .{ .socket_path = "/tmp/new.sock", .instance_id = null, .mtime = .fromNanoseconds(30) },
        .{ .socket_path = "/tmp/mid.sock", .instance_id = null, .mtime = .fromNanoseconds(20) },
    };

    try std.testing.expectEqual(@as(usize, 1), newestDiscoveryCandidateIndex(&candidates));
}
