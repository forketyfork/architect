const std = @import("std");

/// Child-process execution.
///
/// Zig 0.16 reduces `std.process.Child` to `kill` and `wait`, moving creation
/// to `std.process.spawn(io, ...)` and the collect-output pattern to
/// `std.process.run(gpa, io, ...)`. Both need an `io` context. Centralizing the
/// two shapes Architect actually uses keeps that change out of the call
/// sites.
///
/// `Term` mirrors `std.process.Child.Term` but is declared here with 0.16's
/// lowercase tag names, so callers' `switch` arms do not change at the
/// toolchain bump.
pub const Term = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub const RunResult = struct {
    term: Term,
    /// Caller owns this memory.
    stdout: []u8,
    /// Caller owns this memory.
    stderr: []u8,
};

pub const RunOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    max_output_bytes: usize = 4 * 1024 * 1024,
};

fn fromStdTerm(term: std.process.Child.Term) Term {
    return switch (term) {
        .Exited => |code| .{ .exited = code },
        .Signal => |sig| .{ .signal = sig },
        .Stopped => |sig| .{ .stopped = sig },
        .Unknown => |code| .{ .unknown = code },
    };
}

/// Runs `argv` to completion, collecting stdout and stderr.
pub fn run(allocator: std.mem.Allocator, options: RunOptions) !RunResult {
    var child = std.process.Child.init(options.argv, allocator);
    child.cwd = options.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    errdefer stderr_buf.deinit(allocator);

    errdefer {
        _ = child.kill() catch |kill_err| switch (kill_err) {
            error.AlreadyTerminated => _ = child.wait() catch |wait_err| {
                std.log.scoped(.proc).warn("failed to reap child after output failure: {}", .{wait_err});
            },
            else => std.log.scoped(.proc).warn("failed to stop child after output failure: {}", .{kill_err}),
        };
    }

    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, options.max_output_bytes);
    const term = try child.wait();

    const stdout_slice = try stdout_buf.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try stderr_buf.toOwnedSlice(allocator);

    return .{
        .term = fromStdTerm(term),
        .stdout = stdout_slice,
        .stderr = stderr_slice,
    };
}

/// Spawns `argv`, waits for it, and discards its output.
pub fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) !Term {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    return fromStdTerm(try child.spawnAndWait());
}

test "run collects stdout and reports a zero exit" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf hello" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "run separates stderr from stdout and reports a nonzero exit" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf out; printf err 1>&2; exit 3" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(Term{ .exited = 3 }, result.term);
}

test "run honors cwd" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "pwd" },
        .cwd = "/",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("/\n", result.stdout);
}

test "run surfaces a missing executable as an error rather than a term" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.FileNotFound, run(allocator, .{
        .argv = &.{"/nonexistent/architect-test-binary"},
    }));
}

test "spawnDetached waits for the child and returns its term" {
    const allocator = std.testing.allocator;
    const term = try spawnDetached(allocator, &.{ "/bin/sh", "-c", "exit 7" });
    try std.testing.expectEqual(Term{ .exited = 7 }, term);
}
