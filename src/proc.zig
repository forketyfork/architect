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
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signal = @intFromEnum(sig) },
        .stopped => |sig| .{ .stopped = @intFromEnum(sig) },
        .unknown => |code| .{ .unknown = code },
    };
}

/// Runs `argv` to completion, collecting stdout and stderr.
pub fn run(allocator: std.mem.Allocator, io: std.Io, options: RunOptions) !RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .stdout_limit = .limited(options.max_output_bytes),
        .stderr_limit = .limited(options.max_output_bytes),
    });
    return .{
        .term = fromStdTerm(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

/// Spawns `argv`, waits for it, and discards its output.
pub fn spawnDetached(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Term {
    _ = allocator;
    var child = try std.process.spawn(io, .{ .argv = argv });
    return fromStdTerm(try child.wait(io));
}

test "run collects stdout and reports a zero exit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const allocator = std.testing.allocator;
    const result = try run(allocator, threaded.io(), .{
        .argv = &.{ "/bin/sh", "-c", "printf hello" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("hello", result.stdout);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
}

test "run separates stderr from stdout and reports a nonzero exit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const allocator = std.testing.allocator;
    const result = try run(allocator, threaded.io(), .{
        .argv = &.{ "/bin/sh", "-c", "printf out; printf err 1>&2; exit 3" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(Term{ .exited = 3 }, result.term);
}

test "run honors cwd" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const allocator = std.testing.allocator;
    const result = try run(allocator, threaded.io(), .{
        .argv = &.{ "/bin/sh", "-c", "pwd" },
        .cwd = "/",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqualStrings("/\n", result.stdout);
}

test "run surfaces a missing executable as an error rather than a term" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const allocator = std.testing.allocator;
    try std.testing.expectError(error.FileNotFound, run(allocator, threaded.io(), .{
        .argv = &.{"/nonexistent/architect-test-binary"},
    }));
}

test "spawnDetached waits for the child and returns its term" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const allocator = std.testing.allocator;
    const term = try spawnDetached(allocator, threaded.io(), &.{ "/bin/sh", "-c", "exit 7" });
    try std.testing.expectEqual(Term{ .exited = 7 }, term);
}
