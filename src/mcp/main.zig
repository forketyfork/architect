const std = @import("std");
const control = @import("control");

const log = std.log.scoped(.mcp);
const protocol_version = "2025-11-25";
const server_name = "architect-mcp";
const server_version = "0.1.0";
const tool_name = "spawn_session";

const JsonRpcErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try run(gpa.allocator(), std.fs.File.stdin(), std.fs.File.stdout());
}

pub fn run(allocator: std.mem.Allocator, stdin_file: std.fs.File, stdout_file: std.fs.File) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var discarding_oversized_line = false;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try stdin_file.read(&chunk);
        if (n == 0) break;

        for (chunk[0..n]) |byte| {
            if (discarding_oversized_line) {
                if (byte == '\n') {
                    discarding_oversized_line = false;
                }
                continue;
            }

            if (byte == '\n') {
                if (buffer.items.len > 0) {
                    try handleMessage(allocator, stdout_file, buffer.items);
                    buffer.clearRetainingCapacity();
                }
                continue;
            }
            if (byte == '\r') continue;
            if (buffer.items.len >= control.max_message_bytes) {
                try writeJsonRpcError(allocator, stdout_file, null, .invalid_request, "message is too large");
                buffer.clearRetainingCapacity();
                discarding_oversized_line = true;
                continue;
            }
            try buffer.append(allocator, byte);
        }
    }

    if (!discarding_oversized_line and buffer.items.len > 0) {
        try handleMessage(allocator, stdout_file, buffer.items);
    }
}

fn handleMessage(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    bytes: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try writeJsonRpcError(allocator, stdout_file, null, .parse_error, "parse error");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writeJsonRpcError(allocator, stdout_file, null, .invalid_request, "request must be an object");
        return;
    }

    const object = parsed.value.object;
    const method_value = object.get("method") orelse {
        try writeJsonRpcError(allocator, stdout_file, object.get("id"), .invalid_request, "method is required");
        return;
    };
    if (method_value != .string) {
        try writeJsonRpcError(allocator, stdout_file, object.get("id"), .invalid_request, "method must be a string");
        return;
    }

    const id_value = object.get("id");
    if (id_value == null) {
        if (std.mem.eql(u8, method_value.string, "notifications/initialized")) {
            return;
        }
        return;
    }

    if (std.mem.eql(u8, method_value.string, "initialize")) {
        try writeInitializeResult(allocator, stdout_file, id_value);
    } else if (std.mem.eql(u8, method_value.string, "ping")) {
        try writeEmptyResult(allocator, stdout_file, id_value);
    } else if (std.mem.eql(u8, method_value.string, "tools/list")) {
        try writeToolsListResult(allocator, stdout_file, id_value);
    } else if (std.mem.eql(u8, method_value.string, "tools/call")) {
        try handleToolsCall(allocator, stdout_file, id_value, object.get("params"));
    } else {
        try writeJsonRpcError(allocator, stdout_file, id_value, .method_not_found, "method not found");
    }
}

fn handleToolsCall(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    id_value: ?std.json.Value,
    params_value: ?std.json.Value,
) !void {
    const params = params_value orelse {
        try writeJsonRpcError(allocator, stdout_file, id_value, .invalid_params, "params are required");
        return;
    };
    if (params != .object) {
        try writeJsonRpcError(allocator, stdout_file, id_value, .invalid_params, "params must be an object");
        return;
    }

    const name_value = params.object.get("name") orelse {
        try writeJsonRpcError(allocator, stdout_file, id_value, .invalid_params, "tool name is required");
        return;
    };
    if (name_value != .string or !std.mem.eql(u8, name_value.string, tool_name)) {
        try writeJsonRpcError(allocator, stdout_file, id_value, .invalid_params, "unknown tool");
        return;
    }

    const arguments = params.object.get("arguments") orelse {
        try writeToolFailure(allocator, stdout_file, id_value, .invalid_request, "cwd is required");
        return;
    };
    var request = control.parseSpawnRequestFromValue(allocator, arguments) catch |err| {
        try writeToolFailure(
            allocator,
            stdout_file,
            id_value,
            .invalid_request,
            control.parseErrorMessage(err),
        );
        return;
    };
    defer request.deinit(allocator);

    var response = control.connectAndSendSpawnRequest(allocator, request) catch |err| {
        var message_buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "failed to contact Architect: {}", .{err}) catch |fmt_err| blk: {
            log.debug("failed to format Architect contact error: {}", .{fmt_err});
            break :blk "failed to contact Architect";
        };
        try writeToolFailure(allocator, stdout_file, id_value, .app_not_running, message);
        return;
    };
    defer response.deinit(allocator);

    switch (response.response) {
        .success => |success| try writeToolSuccess(allocator, stdout_file, id_value, success),
        .failure => |failure| try writeToolFailure(allocator, stdout_file, id_value, failure.code, failure.message),
    }
}

fn writeInitializeResult(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    id_value: ?std.json.Value,
) !void {
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

    try writeJsonLine(stdout_file, out.written());
}

fn writeEmptyResult(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    id_value: ?std.json.Value,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try endRpcResult(&json);

    try writeJsonLine(stdout_file, out.written());
}

fn writeToolsListResult(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    id_value: ?std.json.Value,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try json.objectField("tools");
    try json.beginArray();
    try writeSpawnSessionTool(&json);
    try json.endArray();
    try endRpcResult(&json);

    try writeJsonLine(stdout_file, out.written());
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
    stdout_file: std.fs.File,
    id_value: ?std.json.Value,
    success: control.SpawnSuccess,
) !void {
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

    try writeJsonLine(stdout_file, out.written());
}

fn writeToolFailure(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    id_value: ?std.json.Value,
    code: control.SpawnErrorCode,
    message: []const u8,
) !void {
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

    try writeJsonLine(stdout_file, out.written());
}

fn writeJsonRpcError(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    id_value: ?std.json.Value,
    code: JsonRpcErrorCode,
    message: []const u8,
) !void {
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

    try writeJsonLine(stdout_file, out.written());
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

fn writeJsonLine(stdout_file: std.fs.File, bytes: []const u8) !void {
    try stdout_file.writeAll(bytes);
    try stdout_file.writeAll("\n");
}

test "tools/list exposes exactly spawn_session" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = try tmp.dir.createFile("tools-list.jsonl", .{ .truncate = true });

    const id = std.json.Value{ .integer = 1 };
    try writeToolsListResult(allocator, out, id);
    out.close();

    const input = try tmp.dir.readFileAlloc(allocator, "tools-list.jsonl", 16 * 1024);
    defer allocator.free(input);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, input, "\n"), .{});
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out = try tmp.dir.createFile("failure.jsonl", .{ .truncate = true });

    const id = std.json.Value{ .integer = 9 };
    try writeToolFailure(allocator, out, id, .invalid_cwd, "cwd does not exist");
    out.close();

    const input = try tmp.dir.readFileAlloc(allocator, "failure.jsonl", 16 * 1024);
    defer allocator.free(input);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, input, "\n"), .{});
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

test "run discards the rest of an oversized line" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var input = try tmp.dir.createFile("input.jsonl", .{ .read = true });
    defer input.close();

    const oversized = try allocator.alloc(u8, control.max_message_bytes + 10);
    defer allocator.free(oversized);
    @memset(oversized, 'x');

    try input.writeAll(oversized);
    try input.writeAll("\n");
    try input.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n");
    try input.seekTo(0);

    var out = try tmp.dir.createFile("output.jsonl", .{ .read = true });
    defer out.close();

    try run(allocator, input, out);
    try out.seekTo(0);

    const output = try out.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(output);

    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, output, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), line_count);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"message\":\"message is too large\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"tools\"") != null);
}
