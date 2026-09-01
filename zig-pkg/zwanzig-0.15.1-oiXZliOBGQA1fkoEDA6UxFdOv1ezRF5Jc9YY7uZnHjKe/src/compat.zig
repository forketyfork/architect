//! Compile-time gate for supported Zig toolchains.
//!
//! Zwanzig embeds the std.zig frontend (parser, AstGen, Zir) of the compiler
//! that builds it, and depends on unstable compiler-internal APIs. Only the
//! exact versions listed here are tested; anything else - including dev
//! builds and untested patch releases - must fail loudly at compile time.

const std = @import("std");
const builtin = @import("builtin");

pub const supported_zig_versions = [_]std.SemanticVersion{
    .{ .major = 0, .minor = 15, .patch = 2 },
    .{ .major = 0, .minor = 16, .patch = 0 },
};

comptime {
    var supported = false;
    for (supported_zig_versions) |v| {
        if (builtin.zig_version.order(v) == .eq) supported = true;
    }
    if (!supported) {
        @compileError("zwanzig does not support Zig " ++ builtin.zig_version_string ++
            "; supported versions: 0.15.2, 0.16.0 (see docs/ZIG_0_16_MIGRATION_PLAN.md)");
    }
}

pub const Frontend = enum {
    zig_0_15,
    zig_0_16,
};

pub const frontend: Frontend = switch (builtin.zig_version.minor) {
    15 => .zig_0_15,
    16 => .zig_0_16,
    else => unreachable,
};

pub const io = if (builtin.zig_version.minor == 16)
    @import("compat/zig_0_16/io.zig")
else
    @import("compat/zig_0_15/io.zig");

pub const zir = if (builtin.zig_version.minor == 16)
    @import("compat/zig_0_16/zir.zig")
else
    @import("compat/zig_0_15/zir.zig");

pub const Context = io.Context;
pub const Executor = io.Executor;
pub const Mutex = io.Mutex;
pub const EntryKind = io.EntryKind;
pub const DirectoryEntry = io.DirectoryEntry;
pub const Directory = io.Directory;
pub const OutputWriter = io.OutputWriter;
pub const TestDir = io.TestDir;

pub const TaskFn = io.TaskFn;

pub const defaultContext = io.defaultContext;
pub const initMutex = io.initMutex;
pub const lockMutex = io.lockMutex;
pub const unlockMutex = io.unlockMutex;
pub const openDir = io.openDir;
pub const closeDir = io.closeDir;
pub const nextDir = io.nextDir;
pub const readFileAlloc = io.readFileAlloc;
pub const writeFile = io.writeFile;
pub const makePath = io.makePath;
pub const deleteFile = io.deleteFile;
pub const deleteTree = io.deleteTree;
pub const stat = io.stat;
pub const timestamp = io.timestamp;

test "Executor runs submitted tasks to completion" {
    const allocator = std.testing.allocator;

    var context = try Context.init(allocator, 2);
    defer context.deinit();

    var executor = try Executor.init(&context, allocator, 2);
    defer executor.deinit();

    var completed = std.atomic.Value(usize).init(0);
    const Task = struct {
        fn run(_: usize, raw_context: *anyopaque) void {
            const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(raw_context));
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    for (0..4) |index| {
        try executor.spawn(Task.run, index, @ptrCast(&completed));
    }
    try executor.wait();

    try std.testing.expectEqual(@as(usize, 4), completed.load(.acquire));
}
