const std = @import("std");

/// Frame scheduling policy for the main loop. Pure: the runtime feeds in what
/// happened this iteration and gets back whether to render and how long to
/// wait. Keeping it free of SDL and clocks makes every branch unit-testable.
/// Cadence cap for frames whose only cause is terminal output. Agent TUIs
/// repaint spinners and timers many times a second in every session; 30 fps
/// is indistinguishable for that content and halves the presents versus
/// vsync pacing. Frames caused by user input, animation, or UI requests are
/// never capped.
pub const output_render_interval_ns: i128 = 33_333_333;
/// After keyboard or mouse input, output renders go out immediately so the
/// echo of a keystroke is never delayed by the cadence cap.
pub const input_priority_window_ns: i128 = 500_000_000;
pub const active_frame_ns: i128 = 16_666_667;
/// Longest the loop sleeps with nothing pending. Bounded (rather than
/// infinite) because process-exit detection via the xev loop and macOS cwd
/// polling run only when the loop wakes.
pub const idle_wait_ceiling_ns: i128 = 1_000_000_000;
pub const idle_wait_floor_ns: i128 = 1_000_000;

pub const Demand = struct {
    first_frame: bool = false,
    animating: bool = false,
    ui_wants_frame: bool = false,
    processed_event: bool = false,
    had_notifications: bool = false,
    had_control_requests: bool = false,
    session_output_dirty: bool = false,

    fn interactive(self: Demand) bool {
        return self.first_frame or self.animating or self.ui_wants_frame or
            self.processed_event or self.had_notifications or self.had_control_requests;
    }

    fn continuous(self: Demand) bool {
        return self.animating or self.ui_wants_frame;
    }
};

pub const Input = struct {
    now_ns: i128,
    demand: Demand,
    /// 0 when nothing has been presented yet.
    last_present_ns: i128,
    /// 0 when no input has been seen yet.
    last_input_ns: i128,
    vsync_enabled: bool,
    /// macOS stops handing out drawables for a covered window (see
    /// `shouldRenderFrame`); while occluded nothing renders and the loop
    /// sleeps until the expose event or the next timer deadline wakes it,
    /// instead of spinning on unmet demand.
    window_occluded: bool,
    /// Earliest wall-clock deadline of time-driven work (persistence save,
    /// synchronized-output expiry, pending session sends). Null when none.
    next_timer_deadline_ns: ?i128,
};

pub const Wait = union(enum) {
    none,
    until_ns: i128,
};

pub const Schedule = struct {
    render: bool,
    output_deferred: bool,
    wait: Wait,
};

pub fn schedule(in: Input) Schedule {
    if (in.window_occluded) {
        return .{ .render = false, .output_deferred = false, .wait = idleWait(in) };
    }

    if (in.demand.interactive()) {
        return .{
            .render = true,
            .output_deferred = false,
            .wait = if (in.demand.continuous() or !in.vsync_enabled)
                activeWait(in)
            else
                .none,
        };
    }

    if (in.demand.session_output_dirty) {
        const recent_input = in.last_input_ns != 0 and
            in.now_ns - in.last_input_ns < input_priority_window_ns;
        const due_ns = in.last_present_ns + output_render_interval_ns;
        if (recent_input or in.last_present_ns == 0 or in.now_ns >= due_ns) {
            return .{ .render = true, .output_deferred = false, .wait = idleWait(in) };
        }
        return .{
            .render = false,
            .output_deferred = true,
            .wait = .{ .until_ns = clampDeadline(in, due_ns) },
        };
    }

    return .{ .render = false, .output_deferred = false, .wait = idleWait(in) };
}

fn activeWait(in: Input) Wait {
    if (in.vsync_enabled) return .none;
    return .{ .until_ns = in.now_ns + active_frame_ns };
}

fn idleWait(in: Input) Wait {
    return .{ .until_ns = clampDeadline(in, in.now_ns + idle_wait_ceiling_ns) };
}

fn clampDeadline(in: Input, deadline_ns: i128) i128 {
    var until = deadline_ns;
    if (in.next_timer_deadline_ns) |timer| until = @min(until, timer);
    return @max(until, in.now_ns + idle_wait_floor_ns);
}

pub fn waitTimeoutMs(wait: Wait, now_ns: i128) ?c_int {
    switch (wait) {
        .none => return null,
        .until_ns => |until| {
            if (until <= now_ns) return 1;
            const remaining: u128 = @intCast(until - now_ns);
            const timeout_ms = 1 + (remaining - 1) / std.time.ns_per_ms;
            const max_ms: u128 = @intCast(std.math.maxInt(c_int));
            return @intCast(@min(timeout_ms, max_ms));
        },
    }
}

const ms: i128 = std.time.ns_per_ms;

fn base(now_ns: i128) Input {
    return .{
        .now_ns = now_ns,
        .demand = .{},
        .last_present_ns = 0,
        .last_input_ns = 0,
        .vsync_enabled = true,
        .window_occluded = false,
        .next_timer_deadline_ns = null,
    };
}

test "an occluded window never renders and waits like idle even under demand" {
    var in = base(1000 * ms);
    in.window_occluded = true;
    in.demand.first_frame = true;
    in.demand.animating = true;
    in.demand.session_output_dirty = true;
    const s = schedule(in);
    try std.testing.expect(!s.render);
    try std.testing.expectEqual(Wait{ .until_ns = 1000 * ms + idle_wait_ceiling_ns }, s.wait);
}

test "first frame renders even with no demand" {
    var in = base(1000 * ms);
    in.demand.first_frame = true;
    const s = schedule(in);
    try std.testing.expect(s.render);
}

test "nothing to do waits until the idle ceiling" {
    const s = schedule(base(1000 * ms));
    try std.testing.expect(!s.render);
    try std.testing.expectEqual(Wait{ .until_ns = 1000 * ms + idle_wait_ceiling_ns }, s.wait);
}

test "a timer deadline shortens the idle wait but never below the floor" {
    var in = base(1000 * ms);
    in.next_timer_deadline_ns = 1300 * ms;
    try std.testing.expectEqual(Wait{ .until_ns = 1300 * ms }, schedule(in).wait);

    in.next_timer_deadline_ns = 999 * ms;
    try std.testing.expectEqual(Wait{ .until_ns = 1000 * ms + idle_wait_floor_ns }, schedule(in).wait);
}

test "output-only dirtiness right after a present is deferred to the output cadence" {
    var in = base(1010 * ms);
    in.demand.session_output_dirty = true;
    in.last_present_ns = 1000 * ms;
    const s = schedule(in);
    try std.testing.expect(!s.render);
    try std.testing.expect(s.output_deferred);
    try std.testing.expectEqual(Wait{ .until_ns = 1000 * ms + output_render_interval_ns }, s.wait);
}

test "output-only dirtiness renders once the cadence interval has elapsed" {
    var in = base(1040 * ms);
    in.demand.session_output_dirty = true;
    in.last_present_ns = 1000 * ms;
    const s = schedule(in);
    try std.testing.expect(s.render);
    try std.testing.expect(!s.output_deferred);
}

test "output-only dirtiness renders immediately after recent user input" {
    var in = base(1010 * ms);
    in.demand.session_output_dirty = true;
    in.last_present_ns = 1000 * ms;
    in.last_input_ns = 900 * ms;
    try std.testing.expect(schedule(in).render);

    in.last_input_ns = 1010 * ms - input_priority_window_ns - 1;
    try std.testing.expect(!schedule(in).render);
}

test "a deferred output render still honors an earlier timer deadline" {
    var in = base(1010 * ms);
    in.demand.session_output_dirty = true;
    in.last_present_ns = 1000 * ms;
    in.next_timer_deadline_ns = 1020 * ms;
    try std.testing.expectEqual(Wait{ .until_ns = 1020 * ms }, schedule(in).wait);
}

test "interactive demand renders now and keeps active pacing" {
    var in = base(1000 * ms);
    in.demand.processed_event = true;
    try std.testing.expect(schedule(in).render);
    try std.testing.expectEqual(Wait.none, schedule(in).wait);

    in.vsync_enabled = false;
    try std.testing.expectEqual(Wait{ .until_ns = 1000 * ms + active_frame_ns }, schedule(in).wait);
}

test "animation alone renders and never defers" {
    var in = base(1005 * ms);
    in.demand.animating = true;
    in.last_present_ns = 1000 * ms;
    const s = schedule(in);
    try std.testing.expect(s.render);
    try std.testing.expect(!s.output_deferred);
}

test "waitTimeoutMs rounds up and is at least one millisecond" {
    try std.testing.expectEqual(@as(?c_int, null), waitTimeoutMs(.none, 0));
    try std.testing.expectEqual(@as(?c_int, 1), waitTimeoutMs(.{ .until_ns = 1 }, 0));
    try std.testing.expectEqual(@as(?c_int, 3), waitTimeoutMs(.{ .until_ns = 2_000_001 }, 0));
    try std.testing.expectEqual(@as(?c_int, 1), waitTimeoutMs(.{ .until_ns = 5 }, 10));
}
