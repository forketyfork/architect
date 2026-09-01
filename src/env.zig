const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag == .windows) {
        @compileError("env.zig is POSIX-only; Architect does not support Windows");
    }
}

/// Process environment access.
///
/// Zig 0.16 removes `std.posix.getenv`, and `std.Io` exposes no environment
/// surface, so environment reads cannot travel with the `io` context the way
/// filesystem and clock reads do. Because the environment is process-global
/// and immutable for Architect's lifetime — exactly what `std.posix.getenv`
/// already assumed — it lives here instead of being threaded through every
/// caller as a second context.
///
/// This is the only sanctioned module-level accessor in the codebase. The
/// `io` context is never stored this way.
var process_environ: ?std.process.Environ = null;

/// Must be called exactly once, from `main`, before any thread is spawned.
pub fn init(environ: std.process.Environ) void {
    std.debug.assert(process_environ == null);
    process_environ = environ;
}

pub fn get(key: []const u8) ?[:0]const u8 {
    const environ = process_environ orelse
        @panic("env.get called before env.init; main must call env.init first");
    return environ.getPosix(key);
}

fn initForTest() void {
    if (process_environ == null) {
        process_environ = std.testing.environ;
    }
}

test "get returns a value for a variable the process always has" {
    initForTest();
    // PATH is guaranteed present in every shell Architect is launched from,
    // including the CI runners and the Nix dev shell.
    const path = get("PATH");
    try std.testing.expect(path != null);
    try std.testing.expect(path.?.len > 0);
}

test "get returns null for a variable that is not set" {
    initForTest();
    try std.testing.expectEqual(@as(?[:0]const u8, null), get("ARCHITECT_DEFINITELY_NOT_SET_9f3a1c"));
}
