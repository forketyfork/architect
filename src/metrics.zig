const std = @import("std");

pub const MetricKind = enum(u8) {
    glyph_cache_hits,
    glyph_cache_misses,
    glyph_cache_evictions,
    glyph_cache_size,
    frame_count,
};

const METRIC_COUNT = @typeInfo(MetricKind).@"enum".fields.len;

pub const Metrics = struct {
    values: [METRIC_COUNT]u64,
    prev_values: [METRIC_COUNT]u64,
    last_sample_ms: i64,

    pub fn init() Metrics {
        return .{
            .values = [_]u64{0} ** METRIC_COUNT,
            .prev_values = [_]u64{0} ** METRIC_COUNT,
            .last_sample_ms = 0,
        };
    }

    pub fn increment(self: *Metrics, kind: MetricKind) void {
        self.values[@intFromEnum(kind)] +%= 1;
    }

    pub fn set(self: *Metrics, kind: MetricKind, value: u64) void {
        self.values[@intFromEnum(kind)] = value;
    }

    pub fn get(self: *const Metrics, kind: MetricKind) u64 {
        return self.values[@intFromEnum(kind)];
    }

    /// Returns elapsed time since last sample. Call getRate() after this,
    /// then commitSample() to prepare for the next interval.
    pub fn sampleRates(self: *const Metrics, now_ms: i64) i64 {
        return now_ms - self.last_sample_ms;
    }

    /// Copies current values to prev_values for the next rate calculation.
    /// Call this AFTER getRate() to avoid zeroing the delta.
    pub fn commitSample(self: *Metrics, now_ms: i64) void {
        @memcpy(&self.prev_values, &self.values);
        self.last_sample_ms = now_ms;
    }

    pub fn getRate(self: *const Metrics, kind: MetricKind, elapsed_ms: i64) f64 {
        if (elapsed_ms <= 0) return 0.0;
        const idx = @intFromEnum(kind);
        const delta = self.values[idx] -% self.prev_values[idx];
        return @as(f64, @floatFromInt(delta)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
    }
};

pub var global: ?*Metrics = null;

pub inline fn increment(kind: MetricKind) void {
    if (global) |m| m.increment(kind);
}

pub inline fn set(kind: MetricKind, value: u64) void {
    if (global) |m| m.set(kind, value);
}

test "Metrics.increment" {
    var m = Metrics.init();
    try std.testing.expectEqual(@as(u64, 0), m.get(.glyph_cache_hits));
    m.increment(.glyph_cache_hits);
    try std.testing.expectEqual(@as(u64, 1), m.get(.glyph_cache_hits));
    m.increment(.glyph_cache_hits);
    try std.testing.expectEqual(@as(u64, 2), m.get(.glyph_cache_hits));
}

test "Metrics.set" {
    var m = Metrics.init();
    m.set(.glyph_cache_size, 42);
    try std.testing.expectEqual(@as(u64, 42), m.get(.glyph_cache_size));
    m.set(.glyph_cache_size, 100);
    try std.testing.expectEqual(@as(u64, 100), m.get(.glyph_cache_size));
}

test "Metrics.getRate" {
    var m = Metrics.init();
    m.last_sample_ms = 0;
    m.prev_values = [_]u64{0} ** METRIC_COUNT;
    m.values[@intFromEnum(MetricKind.glyph_cache_hits)] = 10;
    const rate = m.getRate(.glyph_cache_hits, 1000);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), rate, 0.001);
}

test "global metrics null check" {
    global = null;
    increment(.frame_count);
    set(.glyph_cache_size, 100);
}
