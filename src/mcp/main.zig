const std = @import("std");
const control = @import("control");
const env = @import("../env.zig");

const log = std.log.scoped(.mcp);
const protocol_version = "2025-11-25";
const server_name = "architect-mcp";
const server_version = "0.1.0";

const JsonRpcErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

pub fn main(init: std.process.Init) !void {
    env.init(init.minimal.environ);
    try run(init.gpa, init.io, std.Io.File.stdin(), std.Io.File.stdout());
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, stdin_file: std.Io.File, stdout_file: std.Io.File) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var discarding_oversized_line = false;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = stdin_file.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
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
                    try handleMessage(allocator, io, stdout_file, buffer.items);
                    buffer.clearRetainingCapacity();
                }
                continue;
            }
            if (byte == '\r') continue;
            if (buffer.items.len >= control.max_message_bytes) {
                try writeJsonRpcError(allocator, io, stdout_file, null, .invalid_request, "message is too large");
                buffer.clearRetainingCapacity();
                discarding_oversized_line = true;
                continue;
            }
            try buffer.append(allocator, byte);
        }
    }

    if (!discarding_oversized_line and buffer.items.len > 0) {
        try handleMessage(allocator, io, stdout_file, buffer.items);
    }
}

fn handleMessage(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    bytes: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try writeJsonRpcError(allocator, io, stdout_file, null, .parse_error, "parse error");
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writeJsonRpcError(allocator, io, stdout_file, null, .invalid_request, "request must be an object");
        return;
    }

    const object = parsed.value.object;
    const method_value = object.get("method") orelse {
        try writeJsonRpcError(allocator, io, stdout_file, object.get("id"), .invalid_request, "method is required");
        return;
    };
    if (method_value != .string) {
        try writeJsonRpcError(allocator, io, stdout_file, object.get("id"), .invalid_request, "method must be a string");
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
        try writeInitializeResult(allocator, io, stdout_file, id_value);
    } else if (std.mem.eql(u8, method_value.string, "ping")) {
        try writeEmptyResult(allocator, io, stdout_file, id_value);
    } else if (std.mem.eql(u8, method_value.string, "tools/list")) {
        try writeToolsListResult(allocator, io, stdout_file, id_value);
    } else if (std.mem.eql(u8, method_value.string, "tools/call")) {
        try handleToolsCall(allocator, io, stdout_file, id_value, object.get("params"));
    } else {
        try writeJsonRpcError(allocator, io, stdout_file, id_value, .method_not_found, "method not found");
    }
}

fn handleToolsCall(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    id_value: ?std.json.Value,
    params_value: ?std.json.Value,
) !void {
    const params = params_value orelse {
        try writeJsonRpcError(allocator, io, stdout_file, id_value, .invalid_params, "params are required");
        return;
    };
    if (params != .object) {
        try writeJsonRpcError(allocator, io, stdout_file, id_value, .invalid_params, "params must be an object");
        return;
    }

    const name_value = params.object.get("name") orelse {
        try writeJsonRpcError(allocator, io, stdout_file, id_value, .invalid_params, "tool name is required");
        return;
    };
    const op = if (name_value == .string) control.Op.fromString(name_value.string) else null;
    if (op == null) {
        try writeJsonRpcError(allocator, io, stdout_file, id_value, .invalid_params, "unknown tool");
        return;
    }

    const arguments = params.object.get("arguments");
    var request = control.parseArguments(allocator, op.?, arguments) catch |err| {
        try writeToolFailure(allocator, io, stdout_file, id_value, .invalid_request, control.parseErrorMessage(err));
        return;
    };
    const target = request.targetInstance();
    request.deinit(allocator);

    var reply = control.sendRequest(allocator, io, op.?, arguments, if (target) |*id| id.slice() else null) catch |err| {
        var message_buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "failed to contact Architect: {}", .{err}) catch |fmt_err| blk: {
            log.debug("failed to format Architect contact error: {}", .{fmt_err});
            break :blk "failed to contact Architect";
        };
        try writeToolFailure(allocator, io, stdout_file, id_value, .app_not_running, message);
        return;
    };
    defer reply.deinit();

    switch (reply.outcome) {
        .success => |result| try writeToolSuccess(allocator, io, stdout_file, id_value, result),
        .failure => |failure| try writeToolFailure(allocator, io, stdout_file, id_value, failure.code, failure.message),
    }
}

fn writeInitializeResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
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

    try writeJsonLine(io, stdout_file, out.written());
}

fn writeEmptyResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    id_value: ?std.json.Value,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try endRpcResult(&json);

    try writeJsonLine(io, stdout_file, out.written());
}

fn writeToolsListResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    id_value: ?std.json.Value,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try beginRpcResult(&json, id_value);
    try json.objectField("tools");
    try json.beginArray();
    for (tools) |tool| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(@tagName(tool.op));
        try json.objectField("description");
        try json.write(tool.description);
        try json.objectField("inputSchema");
        try json.print("{s}", .{tool.input_schema});
        try json.objectField("outputSchema");
        try json.print("{s}", .{tool.output_schema});
        try json.endObject();
    }
    try json.endArray();
    try endRpcResult(&json);

    try writeJsonLine(io, stdout_file, out.written());
}

const Tool = struct {
    op: control.Op,
    description: []const u8,
    input_schema: []const u8,
    output_schema: []const u8,
};

const instance_id_schema =
    \\{"type":"string","description":"Architect instance that owns the session, as returned by spawn_session or list_sessions. Session ids are only unique within one instance."}
;

const session_id_schema =
    \\{"type":"integer","minimum":0,"description":"Architect session id returned by spawn_session or list_sessions."}
;

const agent_state_schema =
    \\{"type":"string","enum":["unknown","working","awaiting_approval","idle","exited"]}
;

/// Failures share the success schema's `status` field, so every output schema
/// also allows the error fields.
const error_properties =
    \\"code":{"type":"string"},"message":{"type":"string"}
;

/// Tool schemas are written into a single JSON-RPC line, so the multiline
/// literals used for readability must not contribute newlines.
fn oneLine(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var buf: [text.len]u8 = undefined;
        var len: usize = 0;
        for (text) |byte| {
            if (byte == '\n') continue;
            buf[len] = byte;
            len += 1;
        }
        const final = buf[0..len].*;
        return &final;
    }
}

const tools = [_]Tool{
    .{
        .op = .spawn_session,
        .description = "Ask the running Architect app to create a terminal session in a working directory.",
        .input_schema = oneLine(
            \\{"type":"object","additionalProperties":false,"required":["cwd"],"properties":{
            \\"cwd":{"type":"string","description":"Absolute working directory for the new Architect terminal session."},
            \\"command":{"type":"string","maxLength":1023,"description":"Optional command text typed into the new shell; Architect appends a newline. At most 1023 bytes, the terminal line limit; put longer commands in a script."},
            \\"display_name":{"type":"string","description":"Optional display label reserved for clients and future Architect UI."},
            \\"instance_id":{"type":"string","description":"Optional Architect instance to spawn in; defaults to the newest running instance."}}}
        ),
        .output_schema = oneLine(
            \\{"type":"object","required":["status"],"properties":{"status":{"type":"string"},
            \\"instance_id":{"type":"string"},"session_id":{"type":"integer"},"slot_index":{"type":"integer"},
        ++ error_properties ++ "}}"),
    },
    .{
        .op = .list_sessions,
        .description = "List the running Architect terminal sessions with their working directory, foreground agent, " ++
            "and agent state (driven by the agent hooks installed with `architect hook`).",
        .input_schema =
        \\{"type":"object","additionalProperties":false,"properties":{"instance_id":{"type":"string","description":"Optional Architect instance to list; defaults to the newest running instance."}}}
        ,
        .output_schema = oneLine(
            \\{"type":"object","required":["status"],"properties":{"status":{"type":"string"},"instance_id":{"type":"string"},
            \\"sessions":{"type":"array","items":{"type":"object","properties":{
            \\"session_id":{"type":"integer"},"slot_index":{"type":"integer"},
            \\"cwd":{"type":["string","null"]},"foreground_agent":{"type":["string","null"]},
            \\"agent_state":
        ++ agent_state_schema ++
            \\,"state_seq":{"type":"integer"}}}},
        ++ error_properties ++ "}}"),
    },
    .{
        .op = .send_input,
        .description = "Type text into an Architect session as a paste, then press Enter unless submit is false. " ++
            "Use require_idle to deliver only when the agent finished its turn; the check and the write are atomic.",
        .input_schema = oneLine(
            \\{"type":"object","additionalProperties":false,"required":["instance_id","session_id","text"],"properties":{
            \\"instance_id":
        ++ instance_id_schema ++
            \\,"session_id":
        ++ session_id_schema ++
            \\,"text":{"type":"string","minLength":1,"description":"Text to paste. Control characters are stripped like a user paste."},
            \\"submit":{"type":"boolean","default":true,"description":"Press Enter after the text."},
            \\"require_idle":{"type":"boolean","default":false,"description":"Fail with session_busy unless the agent state is idle."}}}
        ),
        .output_schema = oneLine(
            \\{"type":"object","required":["status"],"properties":{"status":{"type":"string"},
            \\"instance_id":{"type":"string"},"session_id":{"type":"integer"},"state_seq":{"type":"integer"},"bracketed_paste":{"type":"boolean"},
        ++ error_properties ++ "}}"),
    },
    .{
        .op = .wait_for_session,
        .description = "Block until an Architect session's agent state is one of `until` with a state_seq greater than " ++
            "after_seq, the session exits, or timeout_ms passes. timeout_ms 0 returns the current state. " ++
            "The helper answers one call at a time, so run one helper per concurrent waiter.",
        .input_schema = oneLine(
            \\{"type":"object","additionalProperties":false,"required":["instance_id","session_id","until"],"properties":{
            \\"instance_id":
        ++ instance_id_schema ++
            \\,"session_id":
        ++ session_id_schema ++
            \\,"until":{"type":"array","minItems":1,"items":
        ++ agent_state_schema ++
            \\},"after_seq":{"type":"integer","minimum":0,"default":0,"description":"Only states recorded after this sequence number match."},
            \\"timeout_ms":{"type":"integer","minimum":0,"maximum":600000,"default":30000}}}
        ),
        .output_schema = oneLine(
            \\{"type":"object","required":["status"],"properties":{"status":{"type":"string","enum":["matched","exited","timed_out","error"]},
            \\"instance_id":{"type":"string"},"session_id":{"type":"integer"},"agent_state":
        ++ agent_state_schema ++
            \\,"state_seq":{"type":"integer"},
        ++ error_properties ++ "}}"),
    },
    .{
        .op = .terminate_session,
        .description = "Close an Architect terminal session like closing its tile: the shell is terminated and the agent receives SIGHUP.",
        .input_schema =
        \\{"type":"object","additionalProperties":false,"required":["instance_id","session_id"],"properties":{"instance_id":
        ++ instance_id_schema ++ ",\"session_id\":" ++ session_id_schema ++ "}}",
        .output_schema =
        \\{"type":"object","required":["status"],"properties":{"status":{"type":"string"},"instance_id":{"type":"string"},"session_id":{"type":"integer"},
        ++ error_properties ++ "}}",
    },
};

fn writeToolSuccess(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    id_value: ?std.json.Value,
    result: std.json.Value,
) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    defer allocator.free(text);

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
    try json.write(text);
    try json.endObject();
    try json.endArray();
    try json.objectField("structuredContent");
    try json.write(result);
    try json.objectField("isError");
    try json.write(false);
    try endRpcResult(&json);

    try writeJsonLine(io, stdout_file, out.written());
}

fn writeToolFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
    id_value: ?std.json.Value,
    code: control.ErrorCode,
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

    try writeJsonLine(io, stdout_file, out.written());
}

fn writeJsonRpcError(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout_file: std.Io.File,
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

    try writeJsonLine(io, stdout_file, out.written());
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

fn writeJsonLine(io: std.Io, stdout_file: std.Io.File, bytes: []const u8) !void {
    try stdout_file.writeStreamingAll(io, bytes);
    try stdout_file.writeStreamingAll(io, "\n");
}

test "tools/list exposes every control operation with valid schemas on one line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try tmp.dir.createFile(io, "tools-list.jsonl", .{ .truncate = true });

    const id = std.json.Value{ .integer = 1 };
    try writeToolsListResult(allocator, io, out, id);
    out.close(io);

    const input = try tmp.dir.readFileAlloc(io, "tools-list.jsonl", allocator, .limited(64 * 1024));
    defer allocator.free(input);
    const line = std.mem.trimEnd(u8, input, "\n");
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const result_value = parsed.value.object.get("result") orelse return error.TestUnexpectedResult;
    const tools_value = result_value.object.get("tools") orelse return error.TestUnexpectedResult;
    const listed = tools_value.array.items;
    const ops = std.enums.values(control.Op);
    try std.testing.expectEqual(ops.len, listed.len);
    for (ops, listed) |op, tool| {
        try std.testing.expectEqualStrings(@tagName(op), tool.object.get("name").?.string);
        const input_schema = tool.object.get("inputSchema") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("object", input_schema.object.get("type").?.string);
        const output_schema = tool.object.get("outputSchema") orelse return error.TestUnexpectedResult;
        try std.testing.expect(output_schema.object.get("properties").?.object.get("code") != null);
        // Session ids are only unique per app, so operations on an existing
        // session must name the instance that owns it.
        const required = (input_schema.object.get("required") orelse std.json.Value{ .array = .init(allocator) }).array.items;
        var requires_instance = false;
        for (required) |field| {
            if (std.mem.eql(u8, field.string, "instance_id")) requires_instance = true;
        }
        const session_op = switch (op) {
            .send_input, .wait_for_session, .terminate_session => true,
            .spawn_session, .list_sessions => false,
        };
        try std.testing.expectEqual(session_op, requires_instance);
        try std.testing.expect(input_schema.object.get("properties").?.object.get("instance_id") != null);
    }
}

test "tool failure response is an MCP tool error result" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try tmp.dir.createFile(io, "failure.jsonl", .{ .truncate = true });

    const id = std.json.Value{ .integer = 9 };
    try writeToolFailure(allocator, io, out, id, .invalid_cwd, "cwd does not exist");
    out.close(io);

    const input = try tmp.dir.readFileAlloc(io, "failure.jsonl", allocator, .limited(16 * 1024));
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

test "tools/call returns an app-not-running result without aborting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const runtime_dir_name = try std.fmt.allocPrint(allocator, ".tmp/mcp_runtime_{d}", .{std.c.getpid()});
    defer allocator.free(runtime_dir_name);
    std.Io.Dir.cwd().createDirPath(io, runtime_dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteDir(io, runtime_dir_name) catch |err| {
        std.debug.print("cleanup failed: {}\n", .{err});
    };

    const runtime_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, runtime_dir_name, allocator);
    defer allocator.free(runtime_dir);

    var environ_map = std.process.Environ.Map.init(allocator);
    defer environ_map.deinit();
    try environ_map.put("XDG_RUNTIME_DIR", runtime_dir);
    const environ_block = try environ_map.createPosixBlock(allocator, .{});
    defer environ_block.deinit(allocator);
    const environ: std.process.Environ = .{ .block = environ_block };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const empty_args: []const [*:0]const u8 = &.{};
    const init: std.process.Init = .{
        .minimal = .{
            .environ = environ,
            .args = .{ .vector = empty_args },
        },
        .arena = &arena,
        .gpa = allocator,
        .io = io,
        .environ_map = &environ_map,
        .preopens = .empty,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const input = try tmp.dir.createFile(io, "input.jsonl", .{});
        defer input.close(io);
        try input.writeStreamingAll(
            io,
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"spawn_session\",\"arguments\":{\"cwd\":\"/tmp\"}}}\n",
        );
    }

    const input = try tmp.dir.openFile(io, "input.jsonl", .{});
    defer input.close(io);
    const output = try tmp.dir.createFile(io, "output.jsonl", .{});
    defer output.close(io);

    const saved_stdin = std.c.dup(0);
    if (saved_stdin < 0) return error.Unexpected;
    const saved_stdout = std.c.dup(1);
    if (saved_stdout < 0) {
        _ = std.c.close(saved_stdin);
        return error.Unexpected;
    }
    defer {
        if (std.c.dup2(saved_stdin, 0) < 0) std.debug.print("failed to restore stdin\n", .{});
        if (std.c.dup2(saved_stdout, 1) < 0) std.debug.print("failed to restore stdout\n", .{});
        _ = std.c.close(saved_stdin);
        _ = std.c.close(saved_stdout);
    }

    if (std.c.dup2(input.handle, 0) < 0) return error.Unexpected;
    if (std.c.dup2(output.handle, 1) < 0) return error.Unexpected;
    try main(init);
    if (std.c.dup2(saved_stdin, 0) < 0) return error.Unexpected;
    if (std.c.dup2(saved_stdout, 1) < 0) return error.Unexpected;

    const response = try tmp.dir.readFileAlloc(io, "output.jsonl", allocator, .limited(16 * 1024));
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.trim(u8, response, "\n"), .{});
    defer parsed.deinit();

    const result_value = parsed.value.object.get("result") orelse return error.TestUnexpectedResult;
    const result = result_value.object;
    const is_error = result.get("isError") orelse return error.TestUnexpectedResult;
    try std.testing.expect(is_error.bool);
    const structured_content = result.get("structuredContent") orelse return error.TestUnexpectedResult;
    const code = structured_content.object.get("code") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("app_not_running", code.string);
}

test "run discards the rest of an oversized line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const oversized = try allocator.alloc(u8, control.max_message_bytes + 10);
    defer allocator.free(oversized);
    @memset(oversized, 'x');

    {
        const input_writer = try tmp.dir.createFile(io, "input.jsonl", .{});
        defer input_writer.close(io);
        try input_writer.writeStreamingAll(io, oversized);
        try input_writer.writeStreamingAll(io, "\n");
        try input_writer.writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n");
    }
    const input = try tmp.dir.openFile(io, "input.jsonl", .{});
    defer input.close(io);

    {
        const out = try tmp.dir.createFile(io, "output.jsonl", .{});
        defer out.close(io);
        try run(allocator, io, input, out);
    }

    const output = try tmp.dir.readFileAlloc(io, "output.jsonl", allocator, .limited(64 * 1024));
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
