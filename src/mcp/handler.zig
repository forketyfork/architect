//! Transport-agnostic JSON-RPC dispatcher for the Architect MCP server.
//!
//! Both the standalone `architect-mcp` stdio binary and the optional in-app
//! SSE server feed parsed messages into `handleMessage` and write the
//! returned bytes back to their respective transports.
const std = @import("std");
const control = @import("control");

pub const protocol_version = "2025-11-25";
pub const server_name = "architect-mcp";
pub const server_version = "0.1.0";
pub const tool_name = "spawn_session";

pub const JsonRpcErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

/// Spawner indirection so the handler does not depend on a specific transport
/// to the running app. The standalone helper forwards spawns through the
/// control socket; the in-app server enqueues directly onto the runtime queue.
pub const Spawner = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, std.mem.Allocator, control.SpawnRequest) anyerror!control.OwnedSpawnResponse,

    pub fn execute(
        self: Spawner,
        allocator: std.mem.Allocator,
        request: control.SpawnRequest,
    ) anyerror!control.OwnedSpawnResponse {
        return self.callback(self.context, allocator, request);
    }
};

/// Default `Spawner` that connects to a running Architect app via the local
/// control socket. Used by the stdio `architect-mcp` binary.
pub const control_socket_spawner: Spawner = .{
    .context = null,
    .callback = controlSocketSpawn,
};

fn controlSocketSpawn(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: control.SpawnRequest,
) anyerror!control.OwnedSpawnResponse {
    return control.connectAndSendSpawnRequest(allocator, request);
}

/// Process one JSON-RPC message.
///
/// Returns owned bytes the caller must `allocator.free`, or `null` for
/// notifications and other inputs that don't require a reply.
pub fn handleMessage(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    spawner: Spawner,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return try writeJsonRpcError(allocator, null, .parse_error, "parse error");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return try writeJsonRpcError(allocator, null, .invalid_request, "request must be an object");
    }

    const object = parsed.value.object;
    const method_value = object.get("method") orelse {
        return try writeJsonRpcError(allocator, object.get("id"), .invalid_request, "method is required");
    };
    if (method_value != .string) {
        return try writeJsonRpcError(allocator, object.get("id"), .invalid_request, "method must be a string");
    }

    const id_value = object.get("id");
    if (id_value == null) {
        // Notifications and id-less requests get no response by JSON-RPC spec.
        return null;
    }

    const method = method_value.string;
    if (std.mem.eql(u8, method, "initialize")) {
        return try writeInitializeResult(allocator, id_value);
    }
    if (std.mem.eql(u8, method, "ping")) {
        return try writeEmptyResult(allocator, id_value);
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try writeToolsListResult(allocator, id_value);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return try handleToolsCall(allocator, id_value, object.get("params"), spawner);
    }

    return try writeJsonRpcError(allocator, id_value, .method_not_found, "method not found");
}

fn handleToolsCall(
    allocator: std.mem.Allocator,
    id_value: ?std.json.Value,
    params_value: ?std.json.Value,
    spawner: Spawner,
) ![]u8 {
    const params = params_value orelse {
        return try writeJsonRpcError(allocator, id_value, .invalid_params, "params are required");
    };
    if (params != .object) {
        return try writeJsonRpcError(allocator, id_value, .invalid_params, "params must be an object");
    }

    const name_value = params.object.get("name") orelse {
        return try writeJsonRpcError(allocator, id_value, .invalid_params, "tool name is required");
    };
    if (name_value != .string or !std.mem.eql(u8, name_value.string, tool_name)) {
        return try writeJsonRpcError(allocator, id_value, .invalid_params, "unknown tool");
    }

    const arguments = params.object.get("arguments") orelse {
        return try writeToolFailure(allocator, id_value, .invalid_request, "cwd is required");
    };
    var request = control.parseSpawnRequestFromValue(allocator, arguments) catch |err| {
        return try writeToolFailure(
            allocator,
            id_value,
            .invalid_request,
            control.parseErrorMessage(err),
        );
    };
    defer request.deinit(allocator);

    var response = spawner.execute(allocator, request) catch |err| {
        var message_buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "failed to contact Architect: {}", .{err}) catch
            "failed to contact Architect";
        return try writeToolFailure(allocator, id_value, .app_not_running, message);
    };
    defer response.deinit(allocator);

    return switch (response.response) {
        .success => |success| try writeToolSuccess(allocator, id_value, success),
        .failure => |failure| try writeToolFailure(allocator, id_value, failure.code, failure.message),
    };
}

fn writeInitializeResult(
    allocator: std.mem.Allocator,
    id_value: ?std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try json.objectField("protocolVersion");
    try json.write(protocol_version);
    try json.objectField("capabilities");
    try json.beginObject();
    try json.objectField("tools");
    try json.beginObject();
    try json.endObject();
    try json.endObject();
    try json.objectField("serverInfo");
    try json.beginObject();
    try json.objectField("name");
    try json.write(server_name);
    try json.objectField("version");
    try json.write(server_version);
    try json.endObject();
    try endRpcResult(&json);

    return try allocator.dupe(u8, out.written());
}

fn writeEmptyResult(
    allocator: std.mem.Allocator,
    id_value: ?std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try endRpcResult(&json);

    return try allocator.dupe(u8, out.written());
}

fn writeToolsListResult(
    allocator: std.mem.Allocator,
    id_value: ?std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try json.objectField("tools");
    try json.beginArray();
    try writeSpawnSessionTool(&json);
    try json.endArray();
    try endRpcResult(&json);

    return try allocator.dupe(u8, out.written());
}

fn writeSpawnSessionTool(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("name");
    try json.write(tool_name);
    try json.objectField("description");
    try json.write("Ask the running Architect app to create a terminal session in a working directory.");
    try json.objectField("inputSchema");
    try writeSpawnInputSchema(json);
    try json.objectField("outputSchema");
    try writeSpawnOutputSchema(json);
    try json.endObject();
}

fn writeSpawnInputSchema(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("object");
    try json.objectField("additionalProperties");
    try json.write(false);
    try json.objectField("required");
    try json.beginArray();
    try json.write("cwd");
    try json.endArray();
    try json.objectField("properties");
    try json.beginObject();

    try json.objectField("cwd");
    try json.beginObject();
    try json.objectField("type");
    try json.write("string");
    try json.objectField("description");
    try json.write("Absolute working directory for the new Architect terminal session.");
    try json.endObject();

    try json.objectField("command");
    try json.beginObject();
    try json.objectField("type");
    try json.write("string");
    try json.objectField("description");
    try json.write("Optional command text queued into the new shell. Architect appends a newline when needed.");
    try json.endObject();

    try json.objectField("display_name");
    try json.beginObject();
    try json.objectField("type");
    try json.write("string");
    try json.objectField("description");
    try json.write("Optional display label reserved for clients and future Architect UI.");
    try json.endObject();

    try json.endObject();
    try json.endObject();
}

fn writeSpawnOutputSchema(json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("type");
    try json.write("object");
    try json.objectField("required");
    try json.beginArray();
    try json.write("status");
    try json.endArray();
    try json.objectField("properties");
    try json.beginObject();

    try json.objectField("status");
    try json.beginObject();
    try json.objectField("type");
    try json.write("string");
    try json.endObject();

    try json.objectField("session_id");
    try json.beginObject();
    try json.objectField("type");
    try json.write("integer");
    try json.endObject();

    try json.objectField("slot_index");
    try json.beginObject();
    try json.objectField("type");
    try json.write("integer");
    try json.endObject();

    try json.objectField("code");
    try json.beginObject();
    try json.objectField("type");
    try json.write("string");
    try json.endObject();

    try json.objectField("message");
    try json.beginObject();
    try json.objectField("type");
    try json.write("string");
    try json.endObject();

    try json.endObject();
    try json.endObject();
}

fn writeToolSuccess(
    allocator: std.mem.Allocator,
    id_value: ?std.json.Value,
    success: control.SpawnSuccess,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    try json.print("\"Spawned Architect session {d} in slot {d}.\"", .{ success.session_id, success.slot_index });
    try json.endObject();
    try json.endArray();
    try json.objectField("structuredContent");
    try json.beginObject();
    try json.objectField("status");
    try json.write("spawned");
    try json.objectField("session_id");
    try json.write(success.session_id);
    try json.objectField("slot_index");
    try json.write(success.slot_index);
    try json.endObject();
    try json.objectField("isError");
    try json.write(false);
    try endRpcResult(&json);

    return try allocator.dupe(u8, out.written());
}

fn writeToolFailure(
    allocator: std.mem.Allocator,
    id_value: ?std.json.Value,
    code: control.SpawnErrorCode,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    try json.write(message);
    try json.endObject();
    try json.endArray();
    try json.objectField("structuredContent");
    try json.beginObject();
    try json.objectField("status");
    try json.write("error");
    try json.objectField("code");
    try json.write(code.jsonString());
    try json.objectField("message");
    try json.write(message);
    try json.endObject();
    try json.objectField("isError");
    try json.write(true);
    try endRpcResult(&json);

    return try allocator.dupe(u8, out.written());
}

fn writeJsonRpcError(
    allocator: std.mem.Allocator,
    id_value: ?std.json.Value,
    code: JsonRpcErrorCode,
    message: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    if (id_value) |id| {
        try json.write(id);
    } else {
        try json.write(null);
    }
    try json.objectField("error");
    try json.beginObject();
    try json.objectField("code");
    try json.write(@intFromEnum(code));
    try json.objectField("message");
    try json.write(message);
    try json.endObject();
    try json.endObject();

    return try allocator.dupe(u8, out.written());
}

fn beginRpcResult(json: *std.json.Stringify, id_value: ?std.json.Value) !void {
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    if (id_value) |id| {
        try json.write(id);
    } else {
        try json.write(null);
    }
    try json.objectField("result");
    try json.beginObject();
}

fn endRpcResult(json: *std.json.Stringify) !void {
    try json.endObject();
    try json.endObject();
}

fn rejectingSpawn(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: control.SpawnRequest,
) anyerror!control.OwnedSpawnResponse {
    _ = allocator;
    _ = request;
    return error.SpawnRejected;
}

const test_spawner: Spawner = .{
    .context = null,
    .callback = rejectingSpawn,
};

test "tools/list exposes exactly spawn_session" {
    const allocator = std.testing.allocator;

    const id = std.json.Value{ .integer = 1 };
    const bytes = try writeToolsListResult(allocator, id);
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const result_value = parsed.value.object.get("result") orelse return error.TestUnexpectedResult;
    const tools_value = result_value.object.get("tools") orelse return error.TestUnexpectedResult;
    const tools = tools_value.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    const name_value = tools.items[0].object.get("name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(tool_name, name_value.string);
}

test "tool failure response is an MCP tool error result" {
    const allocator = std.testing.allocator;

    const id = std.json.Value{ .integer = 9 };
    const bytes = try writeToolFailure(allocator, id, .invalid_cwd, "cwd does not exist");
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const result_value = parsed.value.object.get("result") orelse return error.TestUnexpectedResult;
    const result = result_value.object;
    const is_error = result.get("isError") orelse return error.TestUnexpectedResult;
    try std.testing.expect(is_error.bool);
    const structured_content = result.get("structuredContent") orelse return error.TestUnexpectedResult;
    const status = structured_content.object.get("status") orelse return error.TestUnexpectedResult;
    const code = structured_content.object.get("code") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", status.string);
    try std.testing.expectEqualStrings("invalid_cwd", code.string);
}

test "handleMessage returns null for notifications" {
    const allocator = std.testing.allocator;
    const bytes = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    const result = try handleMessage(allocator, bytes, test_spawner);
    try std.testing.expect(result == null);
}

test "handleMessage answers tools/list" {
    const allocator = std.testing.allocator;
    const bytes = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}";
    const result = try handleMessage(allocator, bytes, test_spawner) orelse return error.TestUnexpectedResult;
    defer allocator.free(result);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    const id_value = parsed.value.object.get("id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 7), id_value.integer);
    const result_value = parsed.value.object.get("result") orelse return error.TestUnexpectedResult;
    const tools = result_value.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
}

test "handleMessage rejects parse errors" {
    const allocator = std.testing.allocator;
    const bytes = "not json";
    const result = try handleMessage(allocator, bytes, test_spawner) orelse return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"parse error\"") != null);
}
