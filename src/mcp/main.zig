const std = @import("std");
const control = @import("control");
const handler = @import("mcp-handler");

const log = std.log.scoped(.mcp);

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
                    try processMessage(allocator, stdout_file, buffer.items);
                    buffer.clearRetainingCapacity();
                }
                continue;
            }
            if (byte == '\r') continue;
            if (buffer.items.len >= control.max_message_bytes) {
                try writeRawJsonRpcParseTooLarge(allocator, stdout_file);
                buffer.clearRetainingCapacity();
                discarding_oversized_line = true;
                continue;
            }
            try buffer.append(allocator, byte);
        }
    }

    if (!discarding_oversized_line and buffer.items.len > 0) {
        try processMessage(allocator, stdout_file, buffer.items);
    }
}

fn processMessage(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    bytes: []const u8,
) !void {
    const maybe_response = handler.handleMessage(allocator, bytes, handler.control_socket_spawner) catch |err| {
        log.warn("failed to handle MCP message: {}", .{err});
        return;
    };
    if (maybe_response) |response_bytes| {
        defer allocator.free(response_bytes);
        try writeJsonLine(stdout_file, response_bytes);
    }
}

fn writeJsonLine(stdout_file: std.fs.File, bytes: []const u8) !void {
    try stdout_file.writeAll(bytes);
    try stdout_file.writeAll("\n");
}

fn writeRawJsonRpcParseTooLarge(allocator: std.mem.Allocator, stdout_file: std.fs.File) !void {
    // Hand-format an invalid_request error since we never managed to parse the
    // oversized line into a JSON object.
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":-32600,\"message\":\"message is too large\"}}}}",
        .{},
    );
    defer allocator.free(payload);
    try writeJsonLine(stdout_file, payload);
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
