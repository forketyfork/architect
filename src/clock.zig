const std = @import("std");

/// Wall-clock and elapsed-time reads.
///
/// Zig 0.16 removes `std.time.timestamp`, `std.time.milliTimestamp`,
/// `std.time.nanoTimestamp`, and `std.Thread.sleep`, replacing them with
/// `std.Io` clock operations that need an `io` context. Centralizing
/// the reads here keeps that context change out of 27 scattered call sites.
///
/// All three reads use the real (wall) clock, matching what the `std.time`
/// functions did. `nowNanos` is used for frame pacing, which would be better
/// served by a monotonic clock, but switching it is a behavior change and is
/// deliberately out of scope for the toolchain migration.
pub fn nowSeconds() i64 {
    return std.time.timestamp();
}

pub fn nowMillis() i64 {
    return std.time.milliTimestamp();
}

pub fn nowNanos() i128 {
    return std.time.nanoTimestamp();
}

pub fn sleepNanos(nanoseconds: u64) void {
    std.Thread.sleep(nanoseconds);
}

test "the three clock reads agree on the same instant" {
    const secs = nowSeconds();
    const millis = nowMillis();
    const nanos = nowNanos();

    // All three read the same wall clock, so they must agree once scaled
    // down to seconds. A one-second tolerance absorbs a tick landing
    // between the reads.
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(secs)),
        @as(f64, @floatFromInt(@divTrunc(millis, std.time.ms_per_s))),
        1.0,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(secs)),
        @as(f64, @floatFromInt(@divTrunc(nanos, std.time.ns_per_s))),
        1.0,
    );
}

test "nowSeconds returns a plausible wall-clock time" {
    // 2026-01-01T00:00:00Z. Guards against a clock source that returns
    // uptime or zero instead of Unix time.
    try std.testing.expect(nowSeconds() > 1_767_225_600);
}

test "sleepNanos advances the monotonic reading by at least the requested span" {
    const requested_ns: u64 = 5 * std.time.ns_per_ms;
    const before = nowNanos();
    sleepNanos(requested_ns);
    const elapsed = nowNanos() - before;
    try std.testing.expect(elapsed >= requested_ns);
}
