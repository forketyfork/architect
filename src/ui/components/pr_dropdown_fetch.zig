const std = @import("std");
const model = @import("pr_dropdown_model.zig");

const log = std.log.scoped(.pr_dropdown);
pub const gh_output_log_preview_limit: usize = 2 * 1024;

const GhOutputPreview = struct {
    len: usize,
    consumed: usize,
};

pub fn runGhPrList(allocator: std.mem.Allocator, cwd: []const u8) model.FetchResult {
    const argv = [_][]const u8{
        "gh",      "pr",     "list",
        "--state", "open",   "--limit",
        "30",      "--json", "number,title,headRefName",
    };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            log.err("gh CLI not found while listing pull requests: cwd={s}", .{cwd});
            return model.FetchResult{
                .status = .gh_missing,
                .prs = &[_]model.PullRequest{},
                .error_message = null,
            };
        }
        log.err("failed to launch gh while listing pull requests: cwd={s} error={s}", .{ cwd, @errorName(err) });
        return buildFetchError(allocator, "Failed to launch gh: {s}", .{@errorName(err)});
    };

    var stdout_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch {
        log.err("failed to allocate gh stdout buffer: cwd={s}", .{cwd});
        _ = child.kill() catch |err| log.warn("failed to stop gh after stdout allocation failure: {}", .{err});
        return buildFetchError(allocator, "Out of memory reading gh output", .{});
    };
    defer stdout_buf.deinit(allocator);
    var stderr_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch {
        log.err("failed to allocate gh stderr buffer: cwd={s}", .{cwd});
        _ = child.kill() catch |err| log.warn("failed to stop gh after stderr allocation failure: {}", .{err});
        return buildFetchError(allocator, "Out of memory reading gh output", .{});
    };
    defer stderr_buf.deinit(allocator);

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 4 * 1024 * 1024) catch |err| {
        log.err("failed to collect gh output: cwd={s} error={s}", .{ cwd, @errorName(err) });
        _ = child.kill() catch |kill_err| log.warn("failed to stop gh after output failure: {}", .{kill_err});
        _ = child.wait() catch |wait_err| log.warn("failed to reap gh after output failure: {}", .{wait_err});
        return buildFetchError(allocator, "Failed to read gh output: {s}", .{@errorName(err)});
    };

    const term = child.wait() catch |err| {
        log.err("failed to wait for gh: cwd={s} error={s}", .{ cwd, @errorName(err) });
        return buildFetchError(allocator, "Failed to wait for gh: {s}", .{@errorName(err)});
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                const stderr_msg = std.mem.trim(u8, stderr_buf.items, " \t\r\n");
                log.err("gh pr list failed: cwd={s} exit_code={d}", .{ cwd, code });
                logGhOutputPreview("stderr", stderr_buf.items);
                if (stderr_msg.len > 0) {
                    return buildFetchError(allocator, "gh exited {d}: {s}", .{ code, stderr_msg });
                }
                return buildFetchError(allocator, "gh exited with code {d}", .{code});
            }
        },
        else => {
            log.err("gh terminated abnormally: cwd={s}", .{cwd});
            return buildFetchError(allocator, "gh terminated abnormally", .{});
        },
    }

    const result = parseGhJson(allocator, stdout_buf.items);
    if (result.status == .failed) {
        log.err("gh PR list processing failed: cwd={s} error={s}", .{
            cwd,
            result.error_message orelse "unknown parsing error",
        });
        logGhOutputPreview("stdout", stdout_buf.items);
    }
    return result;
}

fn logGhOutputPreview(comptime stream_name: []const u8, bytes: []const u8) void {
    var preview_buffer: [gh_output_log_preview_limit]u8 = undefined;
    const preview = formatGhOutputPreview(bytes, &preview_buffer);
    log.err("gh {s} output: bytes={d} preview_bytes={d} truncated={} preview={s}", .{
        stream_name,
        bytes.len,
        preview.len,
        preview.consumed < bytes.len,
        preview_buffer[0..preview.len],
    });
}

pub fn formatGhOutputPreview(bytes: []const u8, buffer: []u8) GhOutputPreview {
    const hex_digits = "0123456789abcdef";
    var output_len: usize = 0;
    var consumed: usize = 0;

    while (consumed < bytes.len) : (consumed += 1) {
        const byte = bytes[consumed];
        if (byte == '"' or byte == '\\') {
            if (buffer.len - output_len < 2) break;
            buffer[output_len] = '\\';
            buffer[output_len + 1] = byte;
            output_len += 2;
        } else if (std.ascii.isPrint(byte)) {
            if (output_len == buffer.len) break;
            buffer[output_len] = byte;
            output_len += 1;
        } else {
            if (buffer.len - output_len < 4) break;
            buffer[output_len] = '\\';
            buffer[output_len + 1] = 'x';
            buffer[output_len + 2] = hex_digits[byte >> 4];
            buffer[output_len + 3] = hex_digits[byte & 0x0f];
            output_len += 4;
        }
    }

    return .{ .len = output_len, .consumed = consumed };
}

fn buildFetchError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) model.FetchResult {
    const message = std.fmt.allocPrint(allocator, fmt, args) catch |err| blk: {
        log.warn("failed to allocate PR fetch error message: {}", .{err});
        break :blk null;
    };
    return .{
        .status = .failed,
        .prs = &[_]model.PullRequest{},
        .error_message = message,
    };
}

fn stripGhAnsiCsiSequences(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const first_escape = std.mem.indexOfScalar(u8, bytes, 0x1b) orelse return bytes;
    const cleaned = try allocator.alloc(u8, bytes.len);
    @memcpy(cleaned[0..first_escape], bytes[0..first_escape]);

    var input_index = first_escape;
    var output_index = first_escape;
    while (input_index < bytes.len) {
        if (bytes[input_index] == 0x1b and input_index + 1 < bytes.len and bytes[input_index + 1] == '[') {
            input_index += 2;
            while (input_index < bytes.len) : (input_index += 1) {
                const byte = bytes[input_index];
                if (byte >= 0x40 and byte <= 0x7e) {
                    input_index += 1;
                    break;
                }
            }
            continue;
        }

        cleaned[output_index] = bytes[input_index];
        output_index += 1;
        input_index += 1;
    }

    return cleaned[0..output_index];
}

pub fn parseGhJson(allocator: std.mem.Allocator, bytes: []const u8) model.FetchResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const json_bytes = stripGhAnsiCsiSequences(arena_alloc, bytes) catch |err| {
        log.warn("failed to normalize gh JSON output: {}", .{err});
        return buildFetchError(allocator, "Out of memory parsing gh JSON", .{});
    };
    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, json_bytes, .{}) catch {
        return buildFetchError(allocator, "Failed to parse gh JSON output", .{});
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) {
        return buildFetchError(allocator, "Unexpected gh JSON shape (expected array)", .{});
    }
    const arr = root.array;

    var prs = std.ArrayList(model.PullRequest).empty;
    var ok = false;
    defer if (!ok) {
        for (prs.items) |pr| {
            allocator.free(pr.title);
            allocator.free(pr.branch);
        }
        prs.deinit(allocator);
    };

    for (arr.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const number_val = obj.get("number") orelse continue;
        if (number_val != .integer) continue;
        if (number_val.integer <= 0 or number_val.integer > std.math.maxInt(u32)) continue;
        const title_val = obj.get("title") orelse continue;
        const branch_val = obj.get("headRefName") orelse continue;
        if (title_val != .string or branch_val != .string) continue;

        const title_copy = allocator.dupe(u8, title_val.string) catch |err| {
            log.warn("failed to copy pull request title: {}", .{err});
            continue;
        };
        const branch_copy = allocator.dupe(u8, branch_val.string) catch {
            allocator.free(title_copy);
            continue;
        };
        prs.append(allocator, .{
            .number = @intCast(number_val.integer),
            .title = title_copy,
            .branch = branch_copy,
        }) catch {
            allocator.free(title_copy);
            allocator.free(branch_copy);
            continue;
        };
    }

    const owned = prs.toOwnedSlice(allocator) catch {
        return buildFetchError(allocator, "Out of memory parsing PR list", .{});
    };
    ok = true;
    return .{ .status = .ok, .prs = owned, .error_message = null };
}

test "parseGhJson — parses a basic list" {
    const sample =
        \\[
        \\  {"number": 42, "title": "Add foo", "headRefName": "feature/foo"},
        \\  {"number": 17, "title": "Fix bar", "headRefName": "bugfix/bar"}
        \\]
    ;
    var result = parseGhJson(std.testing.allocator, sample);
    defer model.freeFetchResult(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(model.FetchStatus, .ok), result.status);
    try std.testing.expectEqual(@as(usize, 2), result.prs.len);
    try std.testing.expectEqual(@as(u32, 42), result.prs[0].number);
    try std.testing.expectEqualStrings("Add foo", result.prs[0].title);
    try std.testing.expectEqualStrings("feature/foo", result.prs[0].branch);
    try std.testing.expectEqual(@as(u32, 17), result.prs[1].number);
}

test "parseGhJson — skips malformed entries" {
    const sample =
        \\[
        \\  {"number": 1, "title": "Good", "headRefName": "main"},
        \\  {"number": "not a number", "title": "Bad", "headRefName": "x"},
        \\  {"number": 2, "title": "Also good", "headRefName": "feature"}
        \\]
    ;
    var result = parseGhJson(std.testing.allocator, sample);
    defer model.freeFetchResult(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(model.FetchStatus, .ok), result.status);
    try std.testing.expectEqual(@as(usize, 2), result.prs.len);
    try std.testing.expectEqual(@as(u32, 1), result.prs[0].number);
    try std.testing.expectEqual(@as(u32, 2), result.prs[1].number);
}

test "parseGhJson — empty list" {
    var result = parseGhJson(std.testing.allocator, "[]");
    defer model.freeFetchResult(std.testing.allocator, &result);
    try std.testing.expectEqual(@as(model.FetchStatus, .ok), result.status);
    try std.testing.expectEqual(@as(usize, 0), result.prs.len);
}

test "parseGhJson — invalid JSON yields error" {
    var result = parseGhJson(std.testing.allocator, "{ not json");
    defer model.freeFetchResult(std.testing.allocator, &result);
    try std.testing.expectEqual(@as(model.FetchStatus, .failed), result.status);
    try std.testing.expect(result.error_message != null);
}

test "parseGhJson — strips gh terminal color sequences" {
    const sample =
        "\x1b[1;37m[\x1b[m\n" ++
        "  \x1b[1;37m{\x1b[m\n" ++
        "    \x1b[1;34m\"headRefName\"\x1b[m\x1b[1;37m:\x1b[m \x1b[32m\"feature/foo\"\x1b[m\x1b[1;37m,\x1b[m\n" ++
        "    \x1b[1;34m\"number\"\x1b[m\x1b[1;37m:\x1b[m 42\x1b[1;37m,\x1b[m\n" ++
        "    \x1b[1;34m\"title\"\x1b[m\x1b[1;37m:\x1b[m \x1b[32m\"Add foo\"\x1b[m\n" ++
        "  \x1b[1;37m}\x1b[m\n" ++
        "\x1b[1;37m]\x1b[m\n";
    var result = parseGhJson(std.testing.allocator, sample);
    defer model.freeFetchResult(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(model.FetchStatus, .ok), result.status);
    try std.testing.expectEqual(@as(usize, 1), result.prs.len);
    try std.testing.expectEqual(@as(u32, 42), result.prs[0].number);
    try std.testing.expectEqualStrings("Add foo", result.prs[0].title);
    try std.testing.expectEqualStrings("feature/foo", result.prs[0].branch);
}

test "gh output preview escapes bytes and stays bounded" {
    var input: [gh_output_log_preview_limit]u8 = undefined;
    @memset(&input, 0);
    var output: [gh_output_log_preview_limit]u8 = undefined;

    const preview = formatGhOutputPreview(&input, &output);
    try std.testing.expectEqual(gh_output_log_preview_limit, preview.len);
    try std.testing.expectEqual(gh_output_log_preview_limit / 4, preview.consumed);
    try std.testing.expectEqualStrings("\\x00\\x00", output[0..8]);
}
