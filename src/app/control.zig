const std = @import("std");
const posix = std.posix;
const atomic = std.atomic;

const log = std.log.scoped(.control);

pub const max_message_bytes: usize = 64 * 1024;
const max_cwd_bytes: usize = 4096;
const max_command_bytes: usize = 16 * 1024;
const discovery_file_name = "architect_control.json";

pub const SpawnErrorCode = enum {
    invalid_request,
    app_not_running,
    full_grid,
    invalid_cwd,
    spawn_failed,

    pub fn jsonString(self: SpawnErrorCode) []const u8 {
        return switch (self) {
            .invalid_request => "invalid_request",
            .app_not_running => "app_not_running",
            .full_grid => "full_grid",
            .invalid_cwd => "invalid_cwd",
            .spawn_failed => "spawn_failed",
        };
    }

    pub fn fromString(value: []const u8) ?SpawnErrorCode {
        if (std.mem.eql(u8, value, "invalid_request")) return .invalid_request;
        if (std.mem.eql(u8, value, "app_not_running")) return .app_not_running;
        if (std.mem.eql(u8, value, "full_grid")) return .full_grid;
        if (std.mem.eql(u8, value, "invalid_cwd")) return .invalid_cwd;
        if (std.mem.eql(u8, value, "spawn_failed")) return .spawn_failed;
        return null;
    }
};

pub const SpawnRequest = struct {
    cwd: []const u8,
    command: ?[]const u8 = null,
    display_name: ?[]const u8 = null,

    pub fn deinit(self: *SpawnRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        if (self.command) |command| allocator.free(command);
        if (self.display_name) |display_name| allocator.free(display_name);
        self.* = undefined;
    }
};

pub const SpawnSuccess = struct {
    session_id: usize,
    slot_index: usize,
};

pub const SpawnFailure = struct {
    code: SpawnErrorCode,
    message: []const u8,
};

pub const SpawnResponse = union(enum) {
    success: SpawnSuccess,
    failure: SpawnFailure,
};

pub const OwnedSpawnResponse = struct {
    response: SpawnResponse,
    owned_message: ?[]const u8 = null,

    pub fn deinit(self: *OwnedSpawnResponse, allocator: std.mem.Allocator) void {
        if (self.owned_message) |message| {
            allocator.free(message);
            self.owned_message = null;
        }
    }
};

pub const RuntimeWake = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,

    pub fn notify(self: RuntimeWake) void {
        self.callback(self.context);
    }
};

pub const SpawnCompletion = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    completed: bool = false,
    response: SpawnResponse = undefined,

    pub fn complete(self: *SpawnCompletion, response: SpawnResponse) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.response = response;
        self.completed = true;
        self.condition.signal();
    }

    pub fn wait(self: *SpawnCompletion) SpawnResponse {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (!self.completed) {
            self.condition.wait(&self.mutex);
        }
        return self.response;
    }
};

pub const PendingSpawn = struct {
    request: SpawnRequest,
    completion: *SpawnCompletion,
};

pub const SpawnQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(PendingSpawn) = .empty,

    pub fn deinit(self: *SpawnQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn push(self: *SpawnQueue, allocator: std.mem.Allocator, item: PendingSpawn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, item);
    }

    pub fn drainAll(self: *SpawnQueue) std.ArrayListUnmanaged(PendingSpawn) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const items = self.items;
        self.items = .empty;
        return items;
    }
};

pub const ParseSpawnRequestError = error{
    ExpectedObject,
    MissingCwd,
    InvalidCwd,
    InvalidCommand,
    InvalidDisplayName,
    UnknownField,
    OutOfMemory,
};

pub fn parseSpawnRequestFromValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ParseSpawnRequestError!SpawnRequest {
    if (value != .object) return error.ExpectedObject;
    const object = value.object;

    var request = SpawnRequest{
        .cwd = undefined,
    };
    var have_cwd = false;
    var have_command = false;
    var have_display_name = false;
    errdefer {
        if (have_cwd) allocator.free(request.cwd);
        if (request.command) |command| allocator.free(command);
        if (request.display_name) |display_name| allocator.free(display_name);
    }

    var iter = object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "cwd")) {
            if (have_cwd) return error.InvalidCwd;
            if (field_value != .string) return error.InvalidCwd;
            request.cwd = duplicateValidatedString(allocator, field_value.string, max_cwd_bytes, true) catch |err| switch (err) {
                error.EmptyString, error.StringTooLong, error.NulByte => return error.InvalidCwd,
                error.OutOfMemory => return error.OutOfMemory,
            };
            have_cwd = true;
            continue;
        }

        if (std.mem.eql(u8, key, "command")) {
            if (have_command) return error.InvalidCommand;
            have_command = true;
            if (field_value == .null) {
                request.command = null;
                continue;
            }
            if (field_value != .string) return error.InvalidCommand;
            request.command = duplicateValidatedString(allocator, field_value.string, max_command_bytes, true) catch |err| switch (err) {
                error.EmptyString, error.StringTooLong, error.NulByte => return error.InvalidCommand,
                error.OutOfMemory => return error.OutOfMemory,
            };
            continue;
        }

        if (std.mem.eql(u8, key, "display_name")) {
            if (have_display_name) return error.InvalidDisplayName;
            have_display_name = true;
            if (field_value == .null) {
                request.display_name = null;
                continue;
            }
            if (field_value != .string) return error.InvalidDisplayName;
            request.display_name = duplicateValidatedString(allocator, field_value.string, 512, true) catch |err| switch (err) {
                error.EmptyString, error.StringTooLong, error.NulByte => return error.InvalidDisplayName,
                error.OutOfMemory => return error.OutOfMemory,
            };
            continue;
        }

        return error.UnknownField;
    }

    if (!have_cwd) return error.MissingCwd;
    return request;
}

const DuplicateStringError = error{
    EmptyString,
    StringTooLong,
    NulByte,
    OutOfMemory,
};

fn duplicateValidatedString(
    allocator: std.mem.Allocator,
    value: []const u8,
    max_len: usize,
    reject_empty: bool,
) DuplicateStringError![]const u8 {
    if (reject_empty and value.len == 0) return error.EmptyString;
    if (value.len > max_len) return error.StringTooLong;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.NulByte;
    return try allocator.dupe(u8, value);
}

pub fn getControlSocketPath(allocator: std.mem.Allocator) ![:0]u8 {
    const base = runtimeDir();
    const pid = std.c.getpid();
    const socket_name = try std.fmt.allocPrint(allocator, "architect_control_{d}.sock", .{pid});
    defer allocator.free(socket_name);
    return try std.fs.path.joinZ(allocator, &.{ base, socket_name });
}

pub fn getControlDiscoveryPath(allocator: std.mem.Allocator) ![]u8 {
    return try std.fs.path.join(allocator, &.{ runtimeDir(), discovery_file_name });
}

fn runtimeDir() []const u8 {
    return std.posix.getenv("XDG_RUNTIME_DIR") orelse
        std.posix.getenv("TMPDIR") orelse
        "/tmp";
}

const ControlContext = struct {
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    discovery_path: []const u8,
    queue: *SpawnQueue,
    stop: *atomic.Value(bool),
    runtime_wake: ?RuntimeWake,
};

pub fn startControlThread(
    allocator: std.mem.Allocator,
    socket_path: [:0]const u8,
    discovery_path: []const u8,
    queue: *SpawnQueue,
    stop: *atomic.Value(bool),
    runtime_wake: ?RuntimeWake,
) std.Thread.SpawnError!std.Thread {
    _ = std.posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to unlink control socket: {}", .{err}),
    };

    const ctx = ControlContext{
        .allocator = allocator,
        .socket_path = socket_path,
        .discovery_path = discovery_path,
        .queue = queue,
        .stop = stop,
        .runtime_wake = runtime_wake,
    };
    return try std.Thread.spawn(.{}, controlThreadMain, .{ctx});
}

pub fn cleanupControlFiles(socket_path: [:0]const u8, discovery_path: []const u8) void {
    _ = std.posix.unlink(socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to unlink control socket during cleanup: {}", .{err}),
    };
    std.fs.deleteFileAbsolute(discovery_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("failed to delete control discovery file: {}", .{err}),
    };
}

pub fn failPending(
    queue: *SpawnQueue,
    allocator: std.mem.Allocator,
    code: SpawnErrorCode,
    message: []const u8,
) void {
    var pending = queue.drainAll();
    defer pending.deinit(allocator);
    for (pending.items) |*item| {
        item.completion.complete(.{ .failure = .{ .code = code, .message = message } });
        item.request.deinit(allocator);
    }
}

fn controlThreadMain(ctx: ControlContext) !void {
    const addr = try std.net.Address.initUnix(ctx.socket_path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(fd);

    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    try posix.listen(fd, 16);

    const sock_path = std.mem.sliceTo(ctx.socket_path, 0);
    std.posix.fchmodat(posix.AT.FDCWD, sock_path, 0o600, 0) catch |err| {
        log.warn("failed to chmod control socket: {}", .{err});
    };
    writeDiscoveryFile(ctx.allocator, ctx.discovery_path, sock_path) catch |err| {
        log.warn("failed to write control discovery file: {}", .{err});
    };

    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| blk: {
        log.warn("failed to get control socket flags: {}", .{err});
        break :blk null;
    };
    if (flags) |f| {
        var o_flags: posix.O = @bitCast(@as(u32, @intCast(f)));
        o_flags.NONBLOCK = true;
        if (posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
            log.warn("failed to set control socket non-blocking: {}", .{err});
        }
    }

    while (!ctx.stop.load(.seq_cst)) {
        const conn_fd = posix.accept(fd, null, null, 0) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms * 10);
                continue;
            },
            else => {
                log.debug("control accept error: {}", .{err});
                continue;
            },
        };
        handleControlConnection(ctx.allocator, conn_fd, ctx.queue, ctx.runtime_wake);
        posix.close(conn_fd);
    }
}

fn handleControlConnection(
    allocator: std.mem.Allocator,
    conn_fd: posix.fd_t,
    queue: *SpawnQueue,
    runtime_wake: ?RuntimeWake,
) void {
    const bytes = readLineFromFd(allocator, conn_fd, max_message_bytes) catch |err| {
        log.debug("failed to read control request: {}", .{err});
        writeControlResponse(conn_fd, .{ .failure = .{
            .code = .invalid_request,
            .message = "invalid control request",
        } }) catch |write_err| {
            log.debug("failed to write invalid control request response: {}", .{write_err});
        };
        return;
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        writeControlResponse(conn_fd, .{ .failure = .{
            .code = .invalid_request,
            .message = "request is not valid JSON",
        } }) catch |write_err| {
            log.debug("failed to write invalid JSON control response: {}", .{write_err});
        };
        return;
    };
    defer parsed.deinit();

    var request = parseSpawnRequestFromValue(allocator, parsed.value) catch |err| {
        writeControlResponse(conn_fd, .{ .failure = .{
            .code = .invalid_request,
            .message = parseErrorMessage(err),
        } }) catch |write_err| {
            log.debug("failed to write invalid spawn request response: {}", .{write_err});
        };
        return;
    };
    errdefer request.deinit(allocator);

    var completion = SpawnCompletion{};
    queue.push(allocator, .{
        .request = request,
        .completion = &completion,
    }) catch |err| {
        log.warn("failed to queue control request: {}", .{err});
        request.deinit(allocator);
        writeControlResponse(conn_fd, .{ .failure = .{
            .code = .spawn_failed,
            .message = "failed to queue spawn request",
        } }) catch |write_err| {
            log.debug("failed to write queue failure response: {}", .{write_err});
        };
        return;
    };

    if (runtime_wake) |waker| {
        waker.notify();
    }

    const response = completion.wait();
    writeControlResponse(conn_fd, response) catch |err| {
        log.debug("failed to write control response: {}", .{err});
    };
}

pub fn parseErrorMessage(err: ParseSpawnRequestError) []const u8 {
    return switch (err) {
        error.ExpectedObject => "spawn_session arguments must be an object",
        error.MissingCwd => "cwd is required",
        error.InvalidCwd => "cwd must be a non-empty string",
        error.InvalidCommand => "command must be a non-empty string when provided",
        error.InvalidDisplayName => "display_name must be a non-empty string when provided",
        error.UnknownField => "spawn_session contains an unsupported field",
        error.OutOfMemory => "out of memory while parsing spawn_session arguments",
    };
}

fn writeDiscoveryFile(allocator: std.mem.Allocator, path: []const u8, socket_path: []const u8) !void {
    const payload = try discoveryPayloadAlloc(allocator, socket_path);
    defer allocator.free(payload);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);
}

fn discoveryPayloadAlloc(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try json.beginObject();
    try json.objectField("pid");
    try json.write(std.c.getpid());
    try json.objectField("socket_path");
    try json.write(socket_path);
    try json.endObject();
    try out.writer.writeByte('\n');

    return try allocator.dupe(u8, out.written());
}

fn readLineFromFd(allocator: std.mem.Allocator, fd: posix.fd_t, max_bytes: usize) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var tmp: [512]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &tmp);
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

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try posix.write(fd, bytes[written..]);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

fn writeControlResponse(fd: posix.fd_t, response: SpawnResponse) !void {
    var buffer: [512]u8 = undefined;
    var fbs = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fbs.allocator();
    const payload = try controlResponseAlloc(allocator, response);
    try writeAllFd(fd, payload);
}

pub fn controlRequestAlloc(allocator: std.mem.Allocator, request: SpawnRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try json.beginObject();
    try json.objectField("cwd");
    try json.write(request.cwd);
    if (request.command) |command| {
        try json.objectField("command");
        try json.write(command);
    }
    if (request.display_name) |display_name| {
        try json.objectField("display_name");
        try json.write(display_name);
    }
    try json.endObject();
    try out.writer.writeByte('\n');

    return try allocator.dupe(u8, out.written());
}

pub fn controlResponseAlloc(allocator: std.mem.Allocator, response: SpawnResponse) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try json.beginObject();
    switch (response) {
        .success => |success| {
            try json.objectField("ok");
            try json.write(true);
            try json.objectField("session_id");
            try json.write(success.session_id);
            try json.objectField("slot_index");
            try json.write(success.slot_index);
        },
        .failure => |failure| {
            try json.objectField("ok");
            try json.write(false);
            try json.objectField("code");
            try json.write(failure.code.jsonString());
            try json.objectField("message");
            try json.write(failure.message);
        },
    }
    try json.endObject();
    try out.writer.writeByte('\n');

    return try allocator.dupe(u8, out.written());
}

pub fn connectAndSendSpawnRequest(
    allocator: std.mem.Allocator,
    request: SpawnRequest,
) !OwnedSpawnResponse {
    const discovery_path = try getControlDiscoveryPath(allocator);
    defer allocator.free(discovery_path);

    const discovery_file = std.fs.openFileAbsolute(discovery_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return staticFailure(.app_not_running, "Architect is not running"),
        else => return err,
    };
    defer discovery_file.close();

    const discovery = try discovery_file.readToEndAlloc(allocator, max_message_bytes);
    defer allocator.free(discovery);

    const socket_path = parseDiscoverySocketPath(allocator, discovery) catch {
        return staticFailure(.app_not_running, "Architect control discovery file is invalid");
    };
    defer allocator.free(socket_path);

    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| switch (err) {
        else => return err,
    };
    defer posix.close(fd);

    const addr = std.net.Address.initUnix(socket_path) catch {
        return staticFailure(.app_not_running, "Architect control socket path is invalid");
    };
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        return staticFailure(.app_not_running, "Architect is not accepting control requests");
    };

    const payload = try controlRequestAlloc(allocator, request);
    defer allocator.free(payload);
    try writeAllFd(fd, payload);

    const response_bytes = try readLineFromFd(allocator, fd, max_message_bytes);
    defer allocator.free(response_bytes);
    return try parseControlResponse(allocator, response_bytes);
}

fn staticFailure(code: SpawnErrorCode, message: []const u8) OwnedSpawnResponse {
    return .{
        .response = .{ .failure = .{ .code = code, .message = message } },
    };
}

fn parseDiscoverySocketPath(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDiscovery;
    const socket_value = parsed.value.object.get("socket_path") orelse return error.InvalidDiscovery;
    if (socket_value != .string or socket_value.string.len == 0) return error.InvalidDiscovery;
    return try allocator.dupe(u8, socket_value.string);
}

fn parseControlResponse(allocator: std.mem.Allocator, bytes: []const u8) !OwnedSpawnResponse {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidControlResponse;
    const object = parsed.value.object;
    const ok_value = object.get("ok") orelse return error.InvalidControlResponse;
    if (ok_value != .bool) return error.InvalidControlResponse;

    if (ok_value.bool) {
        const session_id_value = object.get("session_id") orelse return error.InvalidControlResponse;
        const slot_index_value = object.get("slot_index") orelse return error.InvalidControlResponse;
        if (session_id_value != .integer or slot_index_value != .integer) return error.InvalidControlResponse;
        if (session_id_value.integer < 0 or slot_index_value.integer < 0) return error.InvalidControlResponse;
        return .{ .response = .{ .success = .{
            .session_id = @intCast(session_id_value.integer),
            .slot_index = @intCast(slot_index_value.integer),
        } } };
    }

    const code_value = object.get("code") orelse return error.InvalidControlResponse;
    const message_value = object.get("message") orelse return error.InvalidControlResponse;
    if (code_value != .string or message_value != .string) return error.InvalidControlResponse;
    const code = SpawnErrorCode.fromString(code_value.string) orelse return error.InvalidControlResponse;
    const message = try allocator.dupe(u8, message_value.string);
    return .{
        .response = .{ .failure = .{ .code = code, .message = message } },
        .owned_message = message,
    };
}

test "parseSpawnRequestFromValue accepts cwd with optional metadata" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"cwd\":\"/tmp\",\"command\":\"pwd\",\"display_name\":\"Task\"}", .{});
    defer parsed.deinit();

    var request = try parseSpawnRequestFromValue(allocator, parsed.value);
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp", request.cwd);
    try std.testing.expectEqualStrings("pwd", request.command.?);
    try std.testing.expectEqualStrings("Task", request.display_name.?);
}

test "parseSpawnRequestFromValue rejects invalid shapes" {
    const allocator = std.testing.allocator;

    const cases = [_][]const u8{
        "{}",
        "{\"cwd\":\"\"}",
        "{\"cwd\":7}",
        "{\"cwd\":\"/tmp\",\"command\":\"\"}",
        "{\"cwd\":\"/tmp\",\"extra\":true}",
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case, .{});
        defer parsed.deinit();
        if (parseSpawnRequestFromValue(allocator, parsed.value)) |*request| {
            request.deinit(allocator);
            try std.testing.expect(false);
        } else |_| {}
    }
}

test "control response round-trips success and failure" {
    const allocator = std.testing.allocator;

    const success_payload = try controlResponseAlloc(allocator, .{ .success = .{
        .session_id = 42,
        .slot_index = 3,
    } });
    defer allocator.free(success_payload);

    var success = try parseControlResponse(allocator, success_payload);
    defer success.deinit(allocator);
    switch (success.response) {
        .success => |result| {
            try std.testing.expectEqual(@as(usize, 42), result.session_id);
            try std.testing.expectEqual(@as(usize, 3), result.slot_index);
        },
        .failure => try std.testing.expect(false),
    }

    const failure_payload = try controlResponseAlloc(allocator, .{ .failure = .{
        .code = .full_grid,
        .message = "all terminals are in use",
    } });
    defer allocator.free(failure_payload);

    var failure = try parseControlResponse(allocator, failure_payload);
    defer failure.deinit(allocator);
    switch (failure.response) {
        .failure => |result| {
            try std.testing.expectEqual(SpawnErrorCode.full_grid, result.code);
            try std.testing.expectEqualStrings("all terminals are in use", result.message);
        },
        .success => try std.testing.expect(false),
    }
}

test "SpawnQueue drains queued requests" {
    const allocator = std.testing.allocator;
    var queue = SpawnQueue{};
    defer queue.deinit(allocator);

    var completion = SpawnCompletion{};
    try queue.push(allocator, .{
        .request = .{ .cwd = try allocator.dupe(u8, "/tmp") },
        .completion = &completion,
    });

    var pending = queue.drainAll();
    defer pending.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    pending.items[0].request.deinit(allocator);

    var empty = queue.drainAll();
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}
