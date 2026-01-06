pub const HoldGesture = struct {
    active: bool = false,
    start_ms: i64 = 0,
    duration_ms: i64 = 700,
    consumed: bool = false,

    pub fn start(self: *HoldGesture, now: i64, duration_ms: i64) void {
        self.active = true;
        self.start_ms = now;
        self.duration_ms = duration_ms;
        self.consumed = false;
    }

    pub fn stop(self: *HoldGesture) void {
        self.active = false;
        self.consumed = false;
    }

    pub fn progress(self: *const HoldGesture, now: i64) f32 {
        if (!self.active) return 0;
        const elapsed = now - self.start_ms;
        if (elapsed <= 0) return 0;
        return @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms)));
    }

    pub fn isComplete(self: *const HoldGesture, now: i64) bool {
        if (!self.active) return false;
        return now - self.start_ms >= self.duration_ms;
    }
};
