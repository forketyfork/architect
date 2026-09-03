const std = @import("std");
const builtin = @import("builtin");
const env = @import("../../env.zig");
const model = @import("pr_dropdown_model.zig");
const proc = @import("../../proc.zig");

const log = std.log.scoped(.pr_dropdown);
pub const gh_output_log_preview_limit: usize = 2 * 1024;

const ResolveExecutableError = std.Io.Dir.AccessError || std.Io.Dir.RealPathFileAllocError;
const known_gh_paths: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "/opt/homebrew/bin/gh", "/usr/local/bin/gh" }
else
    &.{};

const GhOutputPreview = struct {
    len: usize,
    consumed: usize,
};

pub fn runGhPrList(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) model.FetchResult {
    const gh_path = resolveGhPath(allocator, io) catch |err| {
        log.err("failed to locate gh while listing pull requests: cwd={s} error={s}", .{ cwd, @errorName(err) });
        return buildFetchError(allocator, "Failed to locate gh: {s}", .{@errorName(err)});
    } orelse {
        log.err("gh CLI not found in PATH or known locations while listing pull requests: cwd={s}", .{cwd});
        return model.FetchResult{
            .status = .gh_missing,
            .prs = &[_]model.PullRequest{},
            .error_message = null,
        };
    };
    defer allocator.free(gh_path);

    log.debug("using gh CLI at {s} while listing pull requests: cwd={s}", .{ gh_path, cwd });

    const argv = [_][]const u8{
        gh_path,   "pr",     "list",
        "--state", "open",   "--limit",
        "30",      "--json", "number,title,headRefName",
    };
    const result = proc.run(allocator, io, .{
        .argv = &argv,
        .cwd = cwd,
    }) catch |err| {
        if (err == error.FileNotFound) {
            log.err("gh CLI disappeared while listing pull requests: path={s} cwd={s}", .{ gh_path, cwd });
            return model.FetchResult{
                .status = .gh_missing,
                .prs = &[_]model.PullRequest{},
                .error_message = null,
            };
        }
        log.err("failed to launch gh while listing pull requests: cwd={s} error={s}", .{ cwd, @errorName(err) });
        return buildFetchError(allocator, "Failed to launch gh: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                const stderr_msg = std.mem.trim(u8, result.stderr, " \t\r\n");
                log.err("gh pr list failed: cwd={s} exit_code={d}", .{ cwd, code });
                logGhOutputPreview("stderr", result.stderr);
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

    const fetch_result = parseGhJson(allocator, result.stdout);
    if (fetch_result.status == .failed) {
        log.err("gh PR list processing failed: cwd={s} error={s}", .{
            cwd,
            fetch_result.error_message orelse "unknown parsing error",
        });
        logGhOutputPreview("stdout", result.stdout);
    }
    return fetch_result;
}

fn resolveGhPath(allocator: std.mem.Allocator, io: std.Io) ResolveExecutableError!?[]u8 {
    const path_env = env.get("PATH");
    return resolveExecutablePath(
        allocator,
        io,
        if (path_env) |path| std.mem.sliceTo(path, 0) else "",
        "gh",
        known_gh_paths,
    );
}

fn resolveExecutablePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path_env: []const u8,
    name: []const u8,
    known_paths: []const []const u8,
) ResolveExecutableError!?[]u8 {
    var path_it = std.mem.splitScalar(u8, path_env, ':');
    while (path_it.next()) |directory| {
        if (directory.len == 0) continue;

        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        if (std.Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| {
            defer allocator.free(candidate);
            return try canonicalizeExecutablePath(allocator, io, candidate);
        } else |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => allocator.free(candidate),
            else => {
                allocator.free(candidate);
                return err;
            },
        }
    }

    for (known_paths) |candidate| {
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
            else => return err,
        };
        return @as(?[]u8, try canonicalizeExecutablePath(allocator, io, candidate));
    }

    return null;
}

fn canonicalizeExecutablePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate: []const u8,
) ResolveExecutableError![]u8 {
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator);
    defer allocator.free(canonical);
    return try allocator.dupe(u8, canonical);
}

test "gh resolver finds an executable in PATH" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "gh", .{ .permissions = .fromMode(0o755) });
    file.close(io);
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const expected = try std.fs.path.join(allocator, &.{ directory, "gh" });
    defer allocator.free(expected);

    const resolved = try resolveExecutablePath(allocator, io, directory, "gh", &.{});
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expectEqualStrings(expected, resolved.?);
}

test "gh resolver canonicalizes relative PATH entries" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "gh", .{ .permissions = .fromMode(0o755) });
    file.close(io);
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const current_directory = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(current_directory);
    const relative_directory = try std.fs.path.relative(allocator, current_directory, null, current_directory, directory);
    defer allocator.free(relative_directory);
    const expected = try std.fs.path.join(allocator, &.{ directory, "gh" });
    defer allocator.free(expected);

    const resolved = try resolveExecutablePath(allocator, io, relative_directory, "gh", &.{});
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expect(std.fs.path.isAbsolute(resolved.?));
    try std.testing.expectEqualStrings(expected, resolved.?);
}

test "gh resolver finds a known location when PATH omits it" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "gh", .{ .permissions = .fromMode(0o755) });
    file.close(io);
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    try tmp.dir.createDir(io, "empty-path", .default_dir);
    const path_directory = try tmp.dir.realPathFileAlloc(io, "empty-path", allocator);
    defer allocator.free(path_directory);
    const expected = try std.fs.path.join(allocator, &.{ directory, "gh" });
    defer allocator.free(expected);
    const known_paths = [_][]const u8{expected};

    const resolved = try resolveExecutablePath(allocator, io, path_directory, "gh", &known_paths);
    try std.testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    try std.testing.expectEqualStrings(expected, resolved.?);
}

test "gh resolver reports no executable when PATH and known locations are empty" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const missing = try std.fs.path.join(allocator, &.{ directory, "missing-gh" });
    defer allocator.free(missing);
    const known_paths = [_][]const u8{missing};

    const resolved = try resolveExecutablePath(allocator, io, "", "gh", &known_paths);
    try std.testing.expectEqual(@as(?[]u8, null), resolved);
}

test "gh resolver skips inaccessible PATH and known candidates" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var path_tmp = std.testing.tmpDir(.{});
    defer path_tmp.cleanup();
    var path_file = try path_tmp.dir.createFile(io, "gh", .{ .permissions = .fromMode(0o644) });
    path_file.close(io);
    const path_directory = try path_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path_directory);
    const inaccessible_path = try std.fs.path.join(allocator, &.{ path_directory, "gh" });
    defer allocator.free(inaccessible_path);

    var fallback_tmp = std.testing.tmpDir(.{});
    defer fallback_tmp.cleanup();
    var fallback_file = try fallback_tmp.dir.createFile(io, "gh", .{ .permissions = .fromMode(0o755) });
    fallback_file.close(io);
    const fallback_directory = try fallback_tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(fallback_directory);
    const fallback_path = try std.fs.path.join(allocator, &.{ fallback_directory, "gh" });
    defer allocator.free(fallback_path);
    const fallback_only = [_][]const u8{fallback_path};

    const from_path = try resolveExecutablePath(allocator, io, path_directory, "gh", &fallback_only);
    try std.testing.expect(from_path != null);
    defer allocator.free(from_path.?);
    try std.testing.expectEqualStrings(fallback_path, from_path.?);

    const known_paths = [_][]const u8{ inaccessible_path, fallback_path };
    const from_known_paths = try resolveExecutablePath(allocator, io, "", "gh", &known_paths);
    try std.testing.expect(from_known_paths != null);
    defer allocator.free(from_known_paths.?);
    try std.testing.expectEqualStrings(fallback_path, from_known_paths.?);
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
