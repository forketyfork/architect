# CPU Usage Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Architect's main thread go idle whenever no pixel on screen needs to change, so the app stops averaging ~12% CPU around the clock and drops out of macOS's "using significant energy" list while agent TUIs keep running inside it.

**Architecture:** Presentation becomes change-driven end to end. Terminal output only advances a session's `render_epoch` when ghostty-vt's own dirty tracking says the visible state changed; the renderer redraws only dirty rows into the cached session texture and clears those dirty bits; the frame loop presents output-driven frames at a capped cadence (immediate only right after user input), drops the unconditional periodic re-render, and sleeps until the next real deadline instead of a fixed short idle tick. Background threads block in `poll(2)` on their fds plus a self-pipe instead of sleeping in 10 ms loops.

**Tech Stack:** Zig 0.16, SDL3 (`SDL_WaitEventTimeout`, `SDL_RenderPresent`), ghostty-vt dirty tracking (`Terminal.flags.dirty`, `Screen.dirty`, `Page.dirty`, `Row.dirty`, `Pin.isDirty()`), `poll(2)`, existing SDL wake-event plumbing (`platform.pushWakeEventFromOpaque`).

**Spec:** The "Background: investigation findings" section below (energy investigation of the live instance, 2026-09-02). There is no external spec document.

## Background: investigation findings

Measured on the daily instance (PID 35573, 5 days of uptime): 858 CPU-minutes total, 725 of them on the main thread (321 min system + 403 min user). All child agent processes together sat at 0-2.5% CPU. A 10 s `sample` of the unattended app at 06:38 split the main thread's wall time ~49% in `SDL_WaitEventTimeoutNS` and ~48% inside `SDL_RenderPresent`, nearly all of it blocked in `CAMetalLayer nextDrawable` — the signature of presenting frames continuously at tens of fps with nobody interacting.

Why the loop never idles (`src/app/runtime.zig`):

1. A frame is rendered and presented whenever `animating or any_session_dirty or ui_needs_frame or processed_event or had_notifications or had_control_requests or last_render_stale` (line ~3398). Every PTY chunk from a visible session bumps its `render_epoch` (`SessionState.processOutput`, `src/session/state.zig:655`) regardless of whether the VT model changed visibly, so `any_session_dirty` is true most of the time with 7 agent TUIs animating spinners, timers, and status lines 24/7. The app log confirmed the focused claude session forcing ~6-10 cache re-renders per second nonstop while the user was away.
2. When not idle, `computeFrameWaitDecision` (line 171) returns `.none` with vsync on: the loop is paced only by the present call.
3. `max_idle_render_gap_ns` (line 56) forces a full render + present on a periodic render floor, even with zero activity — a guaranteed 4 fps floor.
4. The idle wait is a fixed short interval (`idle_frame_ns`), i.e. 20 wakeups/s with nothing to do.
5. The notify and control socket threads busy-poll `accept()` with a 10 ms sleep each (`src/session/notify.zig:206`, `src/app/control.zig:416`) — up to ~200 wakeups/s. The PTY reader polls with a 100 ms timeout (`src/session/pty_reader.zig:10`) — another 10/s. The process had 24.7M cumulative idle wakeups (~57/s over uptime); macOS weights idle wakeups heavily in its energy-impact score.
6. Debug-level logging was on (~10 lines/s, 1.7 GB of rotated logs). Minor, user-side (`[logging].min_level`), not addressed by code in this plan.

Each full render re-rasterizes every cell of every dirty visible session into its cache texture (`renderSessionContent`: per-cell style lookup, color resolution, glyph-run shaping, one `SDL_RenderTexture` per run, per-cell background fills), composites all session textures plus UI, and presents. Ghostty avoids the equivalent cost with row-level dirty bits that the renderer consumes and clears (`src/terminal/render.zig` in ghostty: full rebuild only when `Terminal.flags.dirty`/`Screen.dirty` has any bit set, the size changed, or the viewport pin moved; otherwise only rows with `Row.dirty` or on a page with `Page.dirty` are rebuilt, and the bits are cleared afterwards). Architect never reads or clears those bits today.

Proven: CPU totals and thread attribution, the continuous-present profile, the render gate and no-sleep pacing, the 10 ms accept polls, the 100 ms reader poll, the periodic render floor, the 6-10/s cache re-renders in the log. Inferred: that agent TUI output is the dominant source of `any_session_dirty` (it correlates with the log and with how these TUIs repaint). Task 1 turns that inference into a measured baseline before anything changes.

## Global Constraints

- Zig 0.16 via `nix develop` (or direnv). Build with `zig build`, test with `zig build test`, lint with `just lint`, format with `zig fmt src/`.
- NEVER pipe `zig build test` in the success-determining call (pipes mask failures). Run it bare, check the exit code, only then grep logs.
- Every new file with tests MUST be added to the `test { _ = @import(...); }` block in `src/main.zig`; `scripts/check-test-registry.sh` (part of `just lint`) enforces this.
- No bare `catch {}` / `catch unreachable`; log or propagate every error.
- No speculative fallbacks: prefer one explicit failure over silent recovery. The periodic re-render floor being removed in Task 4 is exactly such a fallback; do not reintroduce one.
- `io: std.Io` is threaded explicitly as a field right after `allocator` or a parameter right after `allocator`. Never a module-level variable. `src/env.zig` is the only sanctioned module-level accessor.
- Do not introduce new dependencies.
- Route UI input/rendering through `UiRoot` only; UI state lives in components.
- Never render while the window is occluded; keep every present behind `shouldRenderFrame`.
- Performance numbers come only from `-Doptimize=ReleaseFast` builds (`docs/perf-debugging.md`): Debug builds carry ghostty's `slow_runtime_safety` page verification.
- Conventional commit messages. Update `docs/ARCHITECTURE.md`, `docs/perf-debugging.md`, and `CLAUDE.md` alongside code in the same PR.
- Use `.tmp/` in the repo for scratch files, never `/tmp`.

## File Structure

- **Create** `scripts/perf/cpu_probe.sh` — samples CPU% and idle wakeups/s of a PID over N seconds with `top`, prints per-thread CPU time deltas from `ps -M`. The single measurement tool every task's before/after numbers come from.
- **Create** `src/wake_pipe.zig` — `WakePipe`: a non-blocking self-pipe with `signal()`, `drain()`, `pollfd()`. Lets background threads block in `poll(2)` indefinitely yet be interrupted by stop requests and registry changes.
- **Create** `src/app/frame_schedule.zig` — pure frame-scheduling policy: given this frame's demand, the last present/input timestamps, and the next timer deadline, decide whether to render now and how long to wait. Replaces `computeFrameWaitDecision` and the `last_render_stale` floor in `runtime.zig`.
- **Modify** `src/session/notify.zig`, `src/app/control.zig` — accept loops block in `poll` on listener fd + wake pipe.
- **Modify** `src/session/pty_reader.zig` — reader polls PTY fds + wake pipe with no timeout; `register`/`retire` signal the pipe.
- **Modify** `src/app/runtime.zig` — wire wake pipes into thread start/stop; replace frame gate and wait computation with `frame_schedule`; track `last_input_ns`; compute the next timer deadline; new metrics increments.
- **Modify** `src/session/state.zig` — `processOutput` bumps `render_epoch` only when `terminalVisibleStateChanged` says so; new `VisibleSnapshot`; `clearRenderDirty`.
- **Modify** `src/render/renderer.zig` — `RenderCache.Entry` gains a `ContentKey`; `planRefresh` chooses full vs partial; `refreshSessionCacheTexture`/`renderSessionContent` support redrawing only selected rows; dirty bits cleared after refresh.
- **Modify** `src/metrics.zig`, `src/ui/components/metrics_overlay.zig` — counters for presents, loop iterations, deferred output renders, skipped epoch bumps, full/partial cache refreshes.
- **Modify** `docs/ARCHITECTURE.md` (frame-loop diagram, invariant 2, ADR-004, new ADR-016), `docs/perf-debugging.md` (probe script, energy investigation, dirty-tracking notes), `CLAUDE.md` (repo notes on dirty-bit ownership and frame scheduling).

## Suggested PR grouping

| PR | Tasks | Independently shippable? |
| --- | --- | --- |
| 1 | Task 1 | Yes — tooling + metrics, records the baseline |
| 2 | Tasks 2, 3 | Yes — thread wakeups, no rendering change |
| 3 | Task 4 | Yes — frame scheduling |
| 4 | Task 5 | Yes — change-gated render epoch |
| 5 | Task 6 | Yes — partial cache refresh |
| 6 | Task 7 | Docs consolidation + final measurements |

Each PR must include its own doc updates; Task 7 only consolidates and records final numbers.

---

### Task 1: Measurement harness, metrics counters, and baseline

**Files:**
- Create: `scripts/perf/cpu_probe.sh`
- Modify: `src/metrics.zig:3-9` (MetricKind), `src/ui/components/metrics_overlay.zig:171-180` (lines shown)
- Modify: `docs/perf-debugging.md` (new "Measuring CPU and wakeups" section)

**Interfaces:**
- Produces: `MetricKind` tags `loop_iterations`, `frame_count` (existing; counts presents), `output_render_deferrals`, `epoch_bumps_skipped`, `cache_full_refreshes`, `cache_partial_refreshes`. Later tasks call `metrics_mod.increment(.<tag>)` at the sites named in their steps.
- Produces: `scripts/perf/cpu_probe.sh <pid> [seconds]` printing one summary block (average CPU%, idle wakeups/s, per-thread CPU-time delta).

- [ ] **Step 1: Write the probe script**

```bash
#!/usr/bin/env bash
# Samples CPU% and idle wakeups/s of one process with `top`, and reports how much
# CPU time each thread accumulated over the window (via `ps -M`).
# Usage: scripts/perf/cpu_probe.sh <pid> [seconds]   (default 30 s)
set -euo pipefail

pid="${1:?usage: cpu_probe.sh <pid> [seconds]}"
seconds="${2:-30}"

if ! kill -0 "$pid" 2>/dev/null; then
    echo "pid $pid is not running" >&2
    exit 1
fi

before="$(ps -M -p "$pid" | tail -n +2 | awk '{print $NF}')"

# The first top sample reports averages since process start; skip it.
samples=$((seconds + 1))
top -l "$samples" -s 1 -pid "$pid" -stats pid,cpu,idlew \
    | awk -v pid="$pid" '
        $1 == pid { n++; if (n > 1) { cpu += $2; idlew_last = $3; if (n == 2) idlew_first = $3 } }
        END {
            if (n < 2) { print "no samples captured"; exit 1 }
            printf "samples: %d\n", n - 1
            printf "avg cpu%%: %.2f\n", cpu / (n - 1)
            printf "idle wakeups/s: %.1f\n", (idlew_last - idlew_first) / (n - 1)
        }'

after="$(ps -M -p "$pid" | tail -n +2 | awk '{print $NF}')"

echo "per-thread cpu time (mm:ss.ms) before -> after:"
paste <(echo "$before") <(echo "$after") | awk '{ printf "  %s -> %s\n", $1, $2 }'
```

`ps -M` prints one line per thread with the thread's cumulative CPU time in the last column; `top -stats idlew` prints the process's cumulative idle-wakeup count, so the difference between the first and last retained sample divided by the window gives wakeups per second.

- [ ] **Step 2: Make it executable and sanity-check against the live instance**

Run:
```bash
chmod +x scripts/perf/cpu_probe.sh
bash -n scripts/perf/cpu_probe.sh
scripts/perf/cpu_probe.sh "$(pgrep -x architect | head -1)" 10
```
Expected: a `samples: 10` block with non-zero `avg cpu%` and `idle wakeups/s`, followed by per-thread lines. If `pgrep` finds nothing, start the app (`zig build run`) and use its PID.

- [ ] **Step 3: Add the metric kinds**

In `src/metrics.zig`, replace the enum with:

```zig
pub const MetricKind = enum(u8) {
    glyph_cache_hits,
    glyph_cache_misses,
    glyph_cache_evictions,
    glyph_cache_size,
    /// Frames actually presented with SDL_RenderPresent.
    frame_count,
    /// Iterations of the main loop, presented or not.
    loop_iterations,
    /// Output-only frames postponed by the output render cadence cap.
    output_render_deferrals,
    /// processOutput calls that consumed bytes without a visible change.
    epoch_bumps_skipped,
    cache_full_refreshes,
    cache_partial_refreshes,
};
```

Because `metric_count` is derived from `@typeInfo`, `Metrics.init`, `getRate`, and the tests keep working unchanged.

- [ ] **Step 4: Show the new counters in the metrics overlay**

In `src/ui/components/metrics_overlay.zig`, next to the existing `Frames:` line (around line 178), add lines for each new counter using the same `std.fmt.bufPrint(&line_bufs[line_count], ...)` pattern:

```zig
lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Loop/s: {d:.1}  Present/s: {d:.1}", .{
    metrics_ptr.getRate(.loop_iterations, self.cached_elapsed_ms),
    fps,
}) catch |err| blk: {
    log.warn("failed to format loop rate line: {}", .{err});
    break :blk "Loop/s: ?";
};
line_count += 1;
lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Deferred/s: {d:.1}  Skipped epochs/s: {d:.1}", .{
    metrics_ptr.getRate(.output_render_deferrals, self.cached_elapsed_ms),
    metrics_ptr.getRate(.epoch_bumps_skipped, self.cached_elapsed_ms),
}) catch |err| blk: {
    log.warn("failed to format deferral line: {}", .{err});
    break :blk "Deferred/s: ?";
};
line_count += 1;
lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Cache full/s: {d:.1}  partial/s: {d:.1}", .{
    metrics_ptr.getRate(.cache_full_refreshes, self.cached_elapsed_ms),
    metrics_ptr.getRate(.cache_partial_refreshes, self.cached_elapsed_ms),
}) catch |err| blk: {
    log.warn("failed to format cache refresh line: {}", .{err});
    break :blk "Cache full/s: ?";
};
line_count += 1;
```

The overlay currently fills 7 of `max_lines = 8` slots (`metrics_overlay.zig:31`); raise `max_lines` to 11 so the three new lines fit. Increment `loop_iterations` at the top of the main loop in `src/app/runtime.zig` (right after `const now = clock.nowMillis(io);`, line ~1880): `metrics_mod.increment(.loop_iterations);`. The other counters are incremented by Tasks 4-6.

- [ ] **Step 5: Build, test, lint**

Run: `zig build && zig build test && just lint`
Expected: all pass. `just lint` runs shellcheck over `scripts/**/*.sh`; fix any warnings in the probe script.

- [ ] **Step 6: Record the baseline**

Follow `docs/perf-debugging.md` "Reproducing without manual UI interaction": build with `zig build -Doptimize=ReleaseFast`, launch an isolated-HOME instance (`HOME=/tmp/arch-ph` style short path), spawn six sessions through the control socket running `python3 scripts/perf/fake_codex.py`, and measure with `scripts/perf/cpu_probe.sh <pid> 60` twice: once in Grid view, once in Full view focused on one fake-codex session. Also probe the daily instance for 60 s. Put the three results in a new "Energy baseline (2026-09-02)" table in `docs/perf-debugging.md` under a new "Measuring CPU and wakeups" section that also documents the script. Every later task re-runs the same three probes and appends a row.

- [ ] **Step 7: Commit**

```bash
git add scripts/perf/cpu_probe.sh src/metrics.zig src/ui/components/metrics_overlay.zig src/app/runtime.zig docs/perf-debugging.md
git commit -m "feat(perf): add cpu probe script and frame-loop metrics"
```

---

### Task 2: `WakePipe` and blocking accept loops in the notify and control threads

**Files:**
- Create: `src/wake_pipe.zig`
- Modify: `src/session/notify.zig:180-266` (`run`, `startNotifyThread`), `src/app/control.zig:341-428` (`startControlThread`, `controlThreadMain`)
- Modify: `src/app/runtime.zig:1453-1590` (thread wiring)
- Modify: `src/main.zig` test registry
- Modify: `docs/ARCHITECTURE.md` line ~95 (background threads paragraph)

**Interfaces:**
- Produces: `wake_pipe.WakePipe` with `init() InitError!WakePipe`, `deinit(*WakePipe) void`, `signal(*const WakePipe) void`, `drain(*const WakePipe) void`, `pollfd(*const WakePipe) std.posix.pollfd`, `pub const poll_error_backoff_ns`.
- Produces: `notify.startNotifyThread(allocator, io, socket_path, queue, stop, wake: *const WakePipe, runtime_wake)` and `control.startControlThread(allocator, io, socket_path, discovery_path, queue, stop, wake: *const WakePipe, runtime_wake)` — same as today plus the `wake` parameter after `stop`.
- Consumed by Task 3 (PTY reader) and Task 4 (runtime wiring is done here).

- [ ] **Step 1: Write the failing WakePipe tests**

Create `src/wake_pipe.zig` with only the tests first:

```zig
const std = @import("std");
const posix = std.posix;

test "signal makes the read end readable and drain clears it" {
    var pipe = try WakePipe.init();
    defer pipe.deinit();

    var fds = [_]posix.pollfd{pipe.pollfd()};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));

    pipe.signal();
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&fds, 0));
    try std.testing.expect(fds[0].revents & posix.POLL.IN != 0);

    pipe.drain();
    fds[0].revents = 0;
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));
}

test "repeated signals coalesce into one drain" {
    var pipe = try WakePipe.init();
    defer pipe.deinit();

    var i: usize = 0;
    while (i < 100_000) : (i += 1) pipe.signal();

    pipe.drain();
    var fds = [_]posix.pollfd{pipe.pollfd()};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&fds, 0));
}
```

Register the file in `src/main.zig` (`_ = @import("wake_pipe.zig");`, alphabetical position after `vt_stream.zig`). Unix socket paths must stay under the 104-byte `sockaddr_un` limit; the relative `.tmp/...` paths used in the thread tests below are short on purpose.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile error `use of undeclared identifier 'WakePipe'`.

- [ ] **Step 3: Implement WakePipe**

Add above the tests in `src/wake_pipe.zig`:

```zig
const posix_util = @import("posix_util.zig");
const log = std.log.scoped(.wake_pipe);

/// Backoff used by every thread loop after a `poll` failure so a persistent
/// error cannot turn into a busy spin.
pub const poll_error_backoff_ns: u64 = 10 * std.time.ns_per_ms;

pub const InitError = posix_util.PipeError || posix_util.FcntlError;

/// Non-blocking self-pipe. A thread blocked in `poll` on `pollfd()` wakes up
/// when another thread calls `signal()`. The pipe never holds more than its
/// kernel buffer: a signal that finds the buffer full is already observable,
/// so `WouldBlock` on write is not an error.
pub const WakePipe = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    pub fn init() InitError!WakePipe {
        var fds: [2]posix.fd_t = undefined;
        try posix_util.pipe(&fds);
        errdefer {
            _ = std.c.close(fds[0]);
            _ = std.c.close(fds[1]);
        }
        try setNonBlocking(fds[0]);
        try setNonBlocking(fds[1]);
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: *WakePipe) void {
        _ = std.c.close(self.read_fd);
        _ = std.c.close(self.write_fd);
        self.read_fd = -1;
        self.write_fd = -1;
    }

    pub fn signal(self: *const WakePipe) void {
        const byte = [_]u8{0};
        _ = posix_util.write(self.write_fd, &byte) catch |err| switch (err) {
            error.WouldBlock => {},
            else => log.warn("failed to signal wake pipe: {}", .{err}),
        };
    }

    pub fn drain(self: *const WakePipe) void {
        var buf: [256]u8 = undefined;
        while (true) {
            const n = posix.read(self.read_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    log.warn("failed to drain wake pipe: {}", .{err});
                    return;
                },
            };
            if (n < buf.len) return;
        }
    }

    pub fn pollfd(self: *const WakePipe) posix.pollfd {
        return .{ .fd = self.read_fd, .events = posix.POLL.IN, .revents = 0 };
    }
};

fn setNonBlocking(fd: posix.fd_t) posix_util.FcntlError!void {
    const flags = try posix_util.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix_util.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}
```

Check `posix_util.WriteError` includes `WouldBlock` (it wraps `write(2)`, so `EAGAIN` must map to it); if not, add the mapping there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Write the failing thread-shutdown tests**

In `src/session/notify.zig`, next to the existing thread tests (around line 300), add:

```zig
test "notify thread stops promptly when signaled while blocked in poll" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var queue = NotificationQueue{};
    defer queue.deinit(allocator);
    var stop = std.atomic.Value(bool).init(false);
    var wake = try wake_pipe.WakePipe.init();
    defer wake.deinit();

    const sock_path = try std.fmt.allocPrintSentinel(allocator, ".tmp/notify_stop_{d}.sock", .{std.c.getpid()}, 0);
    defer allocator.free(sock_path);
    defer std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    const thread = try startNotifyThread(allocator, io, sock_path, &queue, &stop, &wake, null);

    const started = clock.nowNanos(io);
    stop.store(true, .seq_cst);
    wake.signal();
    thread.join();
    const elapsed_ns = clock.nowNanos(io) - started;
    // With the old 10 ms sleep loop this was bounded by the sleep; with poll it
    // must return as soon as the pipe byte lands. 200 ms is generous headroom.
    try std.testing.expect(elapsed_ns < 200 * std.time.ns_per_ms);
}
```

Replace the `catch {}` on `deleteFile` with `catch |err| std.debug.print("cleanup failed: {}\n", .{err})` (repo rule: no bare catch). Add the identical test to `src/app/control.zig` with `startControlThread` and a `.tmp/control_stop_<pid>.sock` / `.tmp/control_stop_<pid>.json` discovery path. Ensure `.tmp/` exists in the test (`std.Io.Dir.cwd().createDirPath(io, ".tmp")`, ignoring `PathAlreadyExists` explicitly).

- [ ] **Step 6: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile error — `startNotifyThread`/`startControlThread` take no `wake` argument yet.

- [ ] **Step 7: Rewrite the accept loops to block in poll**

In `src/session/notify.zig`, add `const wake_pipe = @import("../wake_pipe.zig");`, add `wake: *const wake_pipe.WakePipe` to `NotifyContext` and to `startNotifyThread` (parameter after `stop`), and replace the `while (!ctx.stop.load(.seq_cst))` accept loop body head with:

```zig
var fds = [_]posix.pollfd{
    .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    ctx.wake.pollfd(),
};
while (!ctx.stop.load(.seq_cst)) {
    fds[0].revents = 0;
    fds[1].revents = 0;
    _ = posix.poll(&fds, -1) catch |err| {
        log.warn("notify poll failed: {}", .{err});
        clock.sleepNanos(ctx.io, wake_pipe.poll_error_backoff_ns);
        continue;
    };
    if (fds[1].revents != 0) ctx.wake.drain();
    if (fds[0].revents == 0) continue;

    const conn_fd = posix_util.accept(fd) catch |err| switch (err) {
        error.WouldBlock => continue,
        else => {
            log.debug("accept error: {}", .{err});
            continue;
        },
    };
    // ... unchanged connection handling ...
}
```

The listener stays `O_NONBLOCK` so a spurious wakeup cannot block in `accept`. Apply the same change to `controlThreadMain` in `src/app/control.zig` (`ControlContext.wake`, `startControlThread` parameter after `stop`).

- [ ] **Step 8: Wire the pipes in the runtime**

In `src/app/runtime.zig` near line 1453:

```zig
var notify_wake = try wake_pipe.WakePipe.init();
defer notify_wake.deinit();
var control_wake = try wake_pipe.WakePipe.init();
defer control_wake.deinit();
```

Pass `&notify_wake` / `&control_wake` to the start functions and change both stop defers to signal before joining:

```zig
defer {
    notify_stop.store(true, .seq_cst);
    notify_wake.signal();
    notify_thread.join();
}
```

Note the defer order: the pipes are declared before the threads start, so their `deinit` defers run after the threads' join defers. Keep it that way.

- [ ] **Step 9: Run build, tests, lint**

Run: `zig build && zig build test && just lint`
Expected: PASS, including the two new prompt-stop tests and all pre-existing notify/control tests.

- [ ] **Step 10: Update docs**

In `docs/ARCHITECTURE.md`, the background-threads paragraph (line ~95): replace the description of the socket listeners with "block in `poll(2)` on the listening socket plus a `WakePipe` self-pipe (`src/wake_pipe.zig`); shutdown stores the stop flag and signals the pipe, so no thread ever sleeps in a fixed-interval loop". Add `wake_pipe.zig` to the module table.

- [ ] **Step 11: Commit**

```bash
git add src/wake_pipe.zig src/session/notify.zig src/app/control.zig src/app/runtime.zig src/main.zig docs/ARCHITECTURE.md
git commit -m "perf(threads): block socket listeners in poll with a wake pipe instead of 10ms sleep loops"
```

---

### Task 3: PTY reader blocks indefinitely and is woken by registry changes

**Files:**
- Modify: `src/session/pty_reader.zig:10-12, 176-200 (PtyReader), 249-303 (run)`
- Modify: `src/app/runtime.zig:1457, 1587-1600` (reader init and stop)
- Modify: `docs/ARCHITECTURE.md` line ~95 (PTY reader "~100ms timeout" wording)

**Interfaces:**
- Consumes: `wake_pipe.WakePipe` from Task 2.
- Produces: `PtyReader.init(io, wake: *const WakePipe) PtyReader`; `register`/`retire` signal the pipe. `pty_reader.start(...)` signature unchanged.

- [ ] **Step 1: Write the failing test**

In `src/session/pty_reader.zig` tests (model on the existing thread tests that use `waitForBufferBytes`):

```zig
test "registering an fd wakes a reader that is blocked with nothing to poll" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var wake = try wake_pipe.WakePipe.init();
    defer wake.deinit();
    var reader = PtyReader.init(io, &wake);
    var stop = std.atomic.Value(bool).init(false);
    var wake_pending = std.atomic.Value(bool).init(false);

    const thread = try start(io, &reader, &stop, &wake_pending, null);
    defer {
        stop.store(true, .seq_cst);
        wake.signal();
        thread.join();
    }

    // Let the reader block in poll with an empty registry.
    clock.sleepNanos(io, 20 * std.time.ns_per_ms);

    var fds: [2]posix.fd_t = undefined;
    try makeNonBlockingPipe(&fds);
    defer _ = std.c.close(fds[1]);
    const buffer = try PtyOutputBuffer.createWithCapacity(allocator, io, 64);
    defer buffer.destroy(allocator);

    reader.register(fds[0], buffer);
    _ = try posix_util.write(fds[1], "hello");

    // Old code needed the 100 ms poll timeout to notice the new fd; now the
    // register() signal must wake the reader immediately.
    try std.testing.expect(waitForBufferBytes(io, buffer, 50));

    reader.retire(fds[0]);
    _ = std.c.close(fds[0]);
}
```

Use the existing buffer destroy/free helper name from the file (check `PtyOutputBuffer` for `destroy`/`deinit`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: compile error — `PtyReader.init` takes one argument.

- [ ] **Step 3: Implement**

In `src/session/pty_reader.zig`:

```zig
const wake_pipe = @import("../wake_pipe.zig");

pub const PtyReader = struct {
    io: std.Io,
    wake: *const wake_pipe.WakePipe,
    mutex: std.Io.Mutex = .init,
    entries: [grid_layout.max_terminals]Entry = undefined,
    entry_count: usize = 0,

    pub fn init(io: std.Io, wake: *const wake_pipe.WakePipe) PtyReader {
        return .{ .io = io, .wake = wake };
    }

    pub fn register(self: *PtyReader, fd: posix.fd_t, buffer: *PtyOutputBuffer) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            std.debug.assert(self.entry_count < self.entries.len);
            self.entries[self.entry_count] = .{ .fd = fd, .buffer = buffer };
            self.entry_count += 1;
        }
        self.wake.signal();
    }

    pub fn retire(self: *PtyReader, fd: posix.fd_t) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // ... existing swap-remove ...
        }
        self.wake.signal();
    }
    // snapshotPollfds / pumpReadyFds unchanged
};
```

Rewrite `run`:

```zig
fn run(ctx: ReaderContext) void {
    // One extra slot for the wake pipe.
    var pollfds: [grid_layout.max_terminals + 1]posix.pollfd = undefined;

    while (!ctx.stop.load(.seq_cst)) {
        const snapshot = ctx.reader.snapshotPollfds(pollfds[0..grid_layout.max_terminals]);
        pollfds[snapshot.count] = ctx.reader.wake.pollfd();
        const nfds = snapshot.count + 1;

        // A full ring buffer cannot be polled (POLLIN would spin); retry
        // shortly so the consumer's drain is picked up. Otherwise block.
        const timeout_ms: i32 = if (snapshot.has_full_buffer) full_buffer_retry_ms else -1;

        const ready = posix.poll(pollfds[0..nfds], timeout_ms) catch |err| {
            log.debug("poll failed: {}", .{err});
            clock.sleepNanos(ctx.io, wake_pipe.poll_error_backoff_ns);
            continue;
        };
        if (ready == 0) continue;

        if (pollfds[snapshot.count].revents != 0) ctx.reader.wake.drain();

        if (ctx.reader.pumpReadyFds(pollfds[0..snapshot.count])) {
            if (!ctx.wake_pending.swap(true, .seq_cst)) {
                if (ctx.runtime_wake) |waker| waker.notify();
            }
        }
    }
}
```

Replace `poll_timeout_ms` with `const full_buffer_retry_ms: i32 = 2;` and delete `full_buffer_retry_ns` and `poll_error_backoff_ns`. `snapshotPollfds` takes `*[max_terminals]posix.pollfd`; change it to accept a slice `[]posix.pollfd` (assert `out.len >= max_terminals`) or pass `pollfds[0..grid_layout.max_terminals]` as an array pointer — whichever compiles cleanly.

In `src/app/runtime.zig`: create `var pty_reader_wake = try wake_pipe.WakePipe.init(); defer pty_reader_wake.deinit();` before `pty_reader_state`, pass it to `PtyReader.init(io, &pty_reader_wake)`, and add `pty_reader_wake.signal();` between `pty_reader_stop.store(true, .seq_cst);` and `pty_reader_thread.join();`. Fix the other `PtyReader.init(io)` call sites in tests (`rg -n "PtyReader.init" src/`).

- [ ] **Step 4: Run build, tests, lint**

Run: `zig build && zig build test && just lint`
Expected: PASS, including the existing reader tests (they now pass a pipe).

- [ ] **Step 5: Measure**

ReleaseFast isolated instance with no sessions spawned, `scripts/perf/cpu_probe.sh <pid> 30`. Expected: idle wakeups/s falls by roughly 210 (200 from the two 10 ms loops, 10 from the reader) compared with the Task 1 baseline. Append a row to the table in `docs/perf-debugging.md`.

- [ ] **Step 6: Update docs and commit**

`docs/ARCHITECTURE.md` line ~95: replace "polls the master fds of all spawned sessions with a ~100ms timeout" with "blocks in `poll(2)` on the master fds of all spawned sessions plus its `WakePipe`, which `register`/`retire` and shutdown signal".

```bash
git add src/session/pty_reader.zig src/app/runtime.zig docs/ARCHITECTURE.md docs/perf-debugging.md
git commit -m "perf(pty-reader): block in poll without timeout; wake on registry changes"
```

---

### Task 4: Change-driven frame scheduling

Removes the periodic re-render floor, caps output-driven presents at 30 fps unless the user typed or clicked in the last 500 ms, and sleeps until the next real deadline (up to 1 s) when idle.

**Files:**
- Create: `src/app/frame_schedule.zig`
- Modify: `src/app/runtime.zig:54-56` (constants), `:103-106, 146-191` (`FrameWaitDecision`, `computeFrameWaitDecision`, `waitForNextFrame`), `:1875-1880` (loop head), `:1908` (processed_event), `:3392-3456` (render gate, `is_idle`, wait), tests `:3713-3775`
- Modify: `src/main.zig` test registry
- Modify: `docs/ARCHITECTURE.md` (frame-loop diagram lines 151-224, invariant 2 line 112, ADR-004 line 520), `CLAUDE.md` (Repo Notes)

**Interfaces:**
- Produces (in `frame_schedule.zig`):
  ```zig
  pub const output_render_interval_ns: i128 = 33_333_333;
  pub const input_priority_window_ns: i128 = 500_000_000;
  pub const active_frame_ns: i128 = 16_666_667;
  pub const idle_wait_ceiling_ns: i128 = 1_000_000_000;
  pub const idle_wait_floor_ns: i128 = 1_000_000;
  pub const Demand = struct { first_frame: bool = false, animating: bool = false, ui_wants_frame: bool = false, processed_event: bool = false, had_notifications: bool = false, had_control_requests: bool = false, session_output_dirty: bool = false };
  pub const Input = struct { now_ns: i128, demand: Demand, last_present_ns: i128, last_input_ns: i128, vsync_enabled: bool, window_occluded: bool, next_timer_deadline_ns: ?i128 };
  pub const Wait = union(enum) { none, until_ns: i128 };
  pub const Schedule = struct { render: bool, output_deferred: bool, wait: Wait };
  pub fn schedule(in: Input) Schedule;
  pub fn waitTimeoutMs(wait: Wait, now_ns: i128) ?c_int; // null for .none, >= 1 otherwise
  ```
- Consumes: nothing from earlier tasks besides metrics tags from Task 1.

- [ ] **Step 1: Write the failing tests**

Create `src/app/frame_schedule.zig` containing only:

```zig
const std = @import("std");

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
```

Register in `src/main.zig`: `_ = @import("app/frame_schedule.zig");` (after `app/app_state.zig`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile errors for undeclared `Input`, `schedule`, `Wait`, etc.

- [ ] **Step 3: Implement the policy**

Add above the tests:

```zig
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
```

Note the interactive branch: an isolated event frame keeps today's behavior (`.none` with vsync; one extra loop iteration that then goes idle) so input handling semantics do not change in this task. Only continuous demand and the vsync-off case compute an explicit active deadline.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS for all `frame_schedule` tests.

- [ ] **Step 5: Integrate into the runtime**

In `src/app/runtime.zig`:

1. Add `const frame_schedule = @import("frame_schedule.zig");`. Delete `active_frame_ns`, `idle_frame_ns`, `max_idle_render_gap_ns`, `FrameWaitDecision`, `remainingFrameBudgetNs`, `waitTimeoutMsFromNs`, `computeFrameWaitDecision`, and their tests (`waitTimeoutMsFromNs rounds up`, the three `computeFrameWaitDecision` tests). Keep `shouldRenderFrame` and its test.
2. Change `waitForNextFrame` to take `?c_int`:
   ```zig
   fn waitForNextFrame(timeout_ms: ?c_int) ?c.SDL_Event {
       return platform.waitEventTimeout(timeout_ms orelse return null);
   }
   ```
3. Loop state before `while (running)`:
   ```zig
   var last_render_ns: i128 = 0;
   var last_input_ns: i128 = 0;
   var next_wait_timeout_ms: ?c_int = null;
   var first_frame = true;
   ```
   and `var next_event = waitForNextFrame(next_wait_timeout_ms);` at the loop head.
4. Where `processed_event = true;` is set (line ~1908), record user presence for key/text/mouse events:
   ```zig
   switch (event.type) {
       c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP, c.SDL_EVENT_TEXT_INPUT,
       c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP,
       c.SDL_EVENT_MOUSE_WHEEL, c.SDL_EVENT_MOUSE_MOTION => last_input_ns = frame_start_ns,
       else => {},
   }
   ```
   Add any of those constants missing from `src/c.zig` there first (repo rule).
5. Add a helper that computes the next timer deadline, placed near `savePersistenceIfDirty`:
   ```zig
   fn nextTimerDeadlineNs(
       now_ms: i64,
       persistence_dirty: bool,
       persistence_dirty_since_ms: i64,
       sessions: []const *SessionState,
       pending_sends: []const PendingSessionSend,
   ) ?i128 {
       var deadline_ms: ?i64 = null;
       if (persistence_dirty) {
           deadline_ms = persistence_dirty_since_ms + persistence_save_debounce_ms;
       }
       for (sessions) |session| {
           if (session.synchronizedOutputActive()) {
               const next = now_ms + session_state.synchronized_output_quiet_ms;
               deadline_ms = if (deadline_ms) |d| @min(d, next) else next;
           }
       }
       for (pending_sends) |send| {
           deadline_ms = if (deadline_ms) |d| @min(d, send.deadline_ms) else send.deadline_ms;
       }
       const ms = deadline_ms orelse return null;
       return @as(i128, ms) * std.time.ns_per_ms;
   }
   ```
   Make `synchronized_output_quiet_ms` `pub` in `src/session/state.zig`. The 1 s cwd poll and `checkAlive` waitpid poll are covered by the 1 s ceiling.
6. Replace the block from `const animating = ...` through `next_frame_wait = computeFrameWaitDecision(...)` (lines ~3392-3456) with:
   ```zig
   const animating = anim_state.mode != .Grid and anim_state.mode != .Full;
   const ui_needs_frame = ui.needsFrame(&ui_render_host);
   const window_occluded = (c.SDL_GetWindowFlags(sdl.window) & c.SDL_WINDOW_OCCLUDED) != 0;

   const plan = frame_schedule.schedule(.{
       .now_ns = frame_start_ns,
       .demand = .{
           .first_frame = first_frame,
           .animating = animating,
           .ui_wants_frame = ui_needs_frame,
           .processed_event = processed_event,
           .had_notifications = had_notifications,
           .had_control_requests = had_control_requests,
           .session_output_dirty = any_session_dirty,
       },
       .last_present_ns = last_render_ns,
       .last_input_ns = last_input_ns,
       .vsync_enabled = sdl.vsync_enabled,
       .window_occluded = window_occluded,
       .next_timer_deadline_ns = nextTimerDeadlineNs(now, persistence_dirty, persistence_dirty_since_ms, sessions, pending_sends.items),
   });
   if (plan.output_deferred) metrics_mod.increment(.output_render_deferrals);

   if (shouldRenderFrame(window_occluded, plan.render)) {
       // ... existing render block, unchanged, ending with:
       metrics_mod.increment(.frame_count);
       last_render_ns = clock.nowNanos(io);
       first_frame = false;
   }

   if (window_close_suppress_countdown > 0) {
       window_close_suppress_countdown -= 1;
   }

   const frame_end_ns: i128 = clock.nowNanos(io);
   next_wait_timeout_ms = frame_schedule.waitTimeoutMs(plan.wait, frame_end_ns);
   ```
   `first_frame` must stay true until a frame is actually presented (an occluded start must still render on first exposure).
7. Delete the `is_idle` variable and `foreground_cache`-related uses of it if any remain; `rg -n "is_idle|last_render_stale|next_frame_wait" src/app/runtime.zig` must return nothing.

- [ ] **Step 6: Audit time-dependent UI for missing `wantsFrame`**

The old periodic floor could have been masking components that change with time without requesting frames. Run:

```bash
rg -n "now_ms|current_time" src/ui/components/*.zig -l | sort > .tmp/time_users.txt
rg -n "fn wantsFrame|wantsFrame = " src/ui/components/*.zig -l | sort > .tmp/frame_requesters.txt
comm -23 .tmp/time_users.txt .tmp/frame_requesters.txt
```

For every file listed by `comm`, read how it uses time: if it renders something that changes with time (fade, marquee, countdown, blink), add a `wantsFrame` that returns true while that animation is live, following `toast.zig:71`. If it only stamps timestamps (e.g. records when something happened), no change. Record the outcome per file in the PR description. `cwd_bar.zig` and `marquee_label.zig` users are the likely candidates.

- [ ] **Step 7: Build, test, lint**

Run: `zig build && zig build test && just lint`
Expected: PASS.

- [ ] **Step 8: Manual verification (ReleaseFast, real sessions)**

- Typing in a shell echoes without perceptible lag (input priority window).
- A TUI spinner (`claude`, `codex`, or `fake_codex.py`) keeps animating smoothly; metrics overlay shows `Present/s` <= ~30 while unattended and `Deferred/s` > 0.
- Leave the app idle with an empty shell for 30 s: metrics `Loop/s` ~1 and `Present/s` 0.
- Grid <-> Full toggle, escape-hold, toasts, help overlay all animate normally.
- Cover the window fully, then uncover: it repaints on exposure.
- Resize the window and change font size (Cmd +/-): repaints immediately.
- `scripts/perf/cpu_probe.sh` on the isolated 6-session instance, Grid and Full. Append rows to the table in `docs/perf-debugging.md`.

- [ ] **Step 9: Update docs**

- `docs/ARCHITECTURE.md`: frame-loop diagram title becomes "(per frame; render only on demand, output-driven presents capped at 30 fps, idle wait up to 1 s or the next timer deadline)"; update the top box text; in invariant 2 and ADR-004 add that a session's dirtiness is a *request* for a frame that `app/frame_schedule.zig` may defer, and that there is no periodic re-render.
- `CLAUDE.md` Repo Notes: add "Frame scheduling lives in `src/app/frame_schedule.zig` (pure, unit-tested). Anything that changes pixels over time must report it (`wantsFrame`, `markDirty`, `UiAction`); there is deliberately no periodic re-render to fall back on."

- [ ] **Step 10: Commit**

```bash
git add src/app/frame_schedule.zig src/app/runtime.zig src/session/state.zig src/c.zig src/main.zig src/ui/components docs/ARCHITECTURE.md docs/perf-debugging.md CLAUDE.md
git commit -m "perf(runtime): change-driven frame scheduling; drop periodic re-render floor; cap output-driven presents"
```

---

### Task 5: Bump `render_epoch` only when the terminal's visible state changed

Uses ghostty-vt's dirty tracking as the oracle. Until Task 6, the renderer clears all dirty bits after each (full) cache refresh, so a chunk that arrives after a refresh and changes nothing visible no longer causes a present.

**Files:**
- Modify: `src/session/state.zig:626-661` (`processOutput`), new helpers next to `markDirty` (line 536), tests
- Modify: `src/render/renderer.zig:1052-1092` (`refreshSessionCacheTexture` calls `session.clearRenderDirty()` after drawing)
- Modify: `docs/ARCHITECTURE.md` ("Terminal Output Path" diagram line ~226, ADR-004), `CLAUDE.md` Repo Notes

**Interfaces:**
- Produces (in `src/session/state.zig`):
  ```zig
  pub const VisibleSnapshot = struct { ... };
  pub fn captureVisibleSnapshot(terminal: *const ghostty_vt.Terminal) VisibleSnapshot;
  pub fn terminalVisibleStateChanged(terminal: *ghostty_vt.Terminal, before: VisibleSnapshot) bool;
  pub fn anyDirtyBit(dirty: anytype) bool; // packed-struct-of-bools test
  pub fn SessionState.clearRenderDirty(self: *SessionState) void;
  ```
- Consumed by Task 6, which narrows `clearRenderDirty` to the rows it redrew.

- [ ] **Step 1: Write the failing tests**

In `src/session/state.zig`, near the existing `synchronized output` tests (~line 1028):

```zig
test "visible state change: printing marks a change, mode-only chunks do not" {
    const allocator = std.testing.allocator;
    var terminal = try ghostty_vt.Terminal.init(std.testing.io, allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer terminal.deinit(allocator);

    // Fresh terminal: nothing has been drawn, so the first print is a change.
    var before = captureVisibleSnapshot(&terminal);
    try terminal.printString("hi");
    try std.testing.expect(terminalVisibleStateChanged(&terminal, before));

    clearTerminalRenderDirty(&terminal);
    before = captureVisibleSnapshot(&terminal);
    // Toggling synchronized output and cursor visibility back and forth
    // leaves the picture identical.
    terminal.modes.set(.synchronized_output, true);
    terminal.modes.set(.synchronized_output, false);
    terminal.modes.set(.cursor_visible, false);
    terminal.modes.set(.cursor_visible, true);
    try std.testing.expect(!terminalVisibleStateChanged(&terminal, before));

    // Cursor visibility that stays flipped is a change.
    terminal.modes.set(.cursor_visible, false);
    try std.testing.expect(terminalVisibleStateChanged(&terminal, before));
}

test "visible state change: cursor movement, palette, scroll, and screen switch are changes" {
    const allocator = std.testing.allocator;
    var terminal = try ghostty_vt.Terminal.init(std.testing.io, allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 1024 });
    defer terminal.deinit(allocator);
    try terminal.printString("abc");
    clearTerminalRenderDirty(&terminal);

    var before = captureVisibleSnapshot(&terminal);
    terminal.setCursorPos(1, 1);
    try std.testing.expect(terminalVisibleStateChanged(&terminal, before));

    clearTerminalRenderDirty(&terminal);
    before = captureVisibleSnapshot(&terminal);
    terminal.flags.dirty.palette = true;
    try std.testing.expect(terminalVisibleStateChanged(&terminal, before));

    clearTerminalRenderDirty(&terminal);
    before = captureVisibleSnapshot(&terminal);
    try terminal.printString("\n\n\n\n");
    try std.testing.expect(terminalVisibleStateChanged(&terminal, before));

    clearTerminalRenderDirty(&terminal);
    before = captureVisibleSnapshot(&terminal);
    _ = try terminal.switchScreen(.alternate);
    try std.testing.expect(terminalVisibleStateChanged(&terminal, before));
}

test "clearTerminalRenderDirty resets every dirty source" {
    const allocator = std.testing.allocator;
    var terminal = try ghostty_vt.Terminal.init(std.testing.io, allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer terminal.deinit(allocator);
    try terminal.printString("x\n\n\n");
    terminal.flags.dirty.clear = true;
    terminal.screens.active.dirty.selection = true;

    clearTerminalRenderDirty(&terminal);

    try std.testing.expect(!anyDirtyBit(terminal.flags.dirty));
    try std.testing.expect(!anyDirtyBit(terminal.screens.active.dirty));
    try std.testing.expect(!anyDirtyRow(terminal.screens.active, .active));
    try std.testing.expect(!anyDirtyRow(terminal.screens.active, .viewport));
}
```

Verified against ghostty 1.3.0-dev in the zig cache: `Terminal.printString(str) !void`, `Terminal.setCursorPos(row, col) void` (1-based), `Terminal.switchScreen(key) !?*Screen`, `Screen.CursorStyle`, `Pin{ node, y, x }`, `PageList.rowIterator(direction, tl_pt, bl_pt)`, `PageList.clearDirty()`, `PageList.isDirty(pt)`. Re-check with `rg` if the ghostty dependency version in `build.zig.zon` has moved.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile errors for the undeclared helpers.

- [ ] **Step 3: Implement the helpers**

In `src/session/state.zig`, after `markDirty`:

```zig
/// True if any field of a packed struct of bools is set. Used for ghostty's
/// `Terminal.Dirty` and `Screen.Dirty`, whose field lists may grow with
/// ghostty upgrades; sizing from the type keeps this correct.
pub fn anyDirtyBit(dirty: anytype) bool {
    const T = @TypeOf(dirty);
    const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
    return @as(Int, @bitCast(dirty)) != 0;
}

const RowRegion = enum { active, viewport };

fn anyDirtyRow(screen: *ghostty_vt.Screen, region: RowRegion) bool {
    const origin: ghostty_vt.point.Point = switch (region) {
        .active => .{ .active = .{} },
        .viewport => .{ .viewport = .{} },
    };
    var it = screen.pages.rowIterator(.right_down, origin, null);
    while (it.next()) |pin| {
        if (pin.isDirty()) return true;
    }
    return false;
}

/// The non-cell state that affects what the renderer draws. Rows and cells
/// are covered by ghostty's own dirty bits; this covers everything else.
pub const VisibleSnapshot = struct {
    cursor_x: u16,
    cursor_y: u16,
    cursor_style: ghostty_vt.Screen.CursorStyle,
    cursor_visible: bool,
    active_screen: @TypeOf(@as(ghostty_vt.Terminal, undefined).screens.active_key),
    viewport_node: ?*const anyopaque,
    viewport_y: u32,
    background: ?ghostty_vt.color.RGB,
    foreground: ?ghostty_vt.color.RGB,
    cursor_color: ?ghostty_vt.color.RGB,
};

pub fn captureVisibleSnapshot(terminal: *const ghostty_vt.Terminal) VisibleSnapshot {
    const screen = terminal.screens.active;
    const viewport_pin = screen.pages.pin(.{ .viewport = .{} });
    return .{
        .cursor_x = screen.cursor.x,
        .cursor_y = screen.cursor.y,
        .cursor_style = screen.cursor.cursor_style,
        .cursor_visible = terminal.modes.get(.cursor_visible),
        .active_screen = terminal.screens.active_key,
        .viewport_node = if (viewport_pin) |p| @ptrCast(p.node) else null,
        .viewport_y = if (viewport_pin) |p| p.y else 0,
        .background = terminal.colors.background.get(),
        .foreground = terminal.colors.foreground.get(),
        .cursor_color = terminal.colors.cursor.get(),
    };
}

/// Mirrors ghostty's own renderer rule (src/terminal/render.zig): a redraw is
/// needed when any terminal- or screen-wide dirty flag is set, the viewport
/// moved, or any row in the viewport/active area is dirty. Cursor position,
/// visibility, style, and dynamic colors are compared explicitly because
/// ghostty does not mark rows dirty for them. False positives are fine;
/// a false negative would leave a stale frame on screen.
pub fn terminalVisibleStateChanged(terminal: *ghostty_vt.Terminal, before: VisibleSnapshot) bool {
    if (anyDirtyBit(terminal.flags.dirty)) return true;
    if (anyDirtyBit(terminal.screens.active.dirty)) return true;
    if (!std.meta.eql(before, captureVisibleSnapshot(terminal))) return true;
    if (anyDirtyRow(terminal.screens.active, .viewport)) return true;
    if (anyDirtyRow(terminal.screens.active, .active)) return true;
    return false;
}

fn clearTerminalRenderDirty(terminal: *ghostty_vt.Terminal) void {
    terminal.flags.dirty = .{};
    const screen = terminal.screens.active;
    screen.dirty = .{};
    inline for (.{ RowRegion.viewport, RowRegion.active }) |region| {
        const origin: ghostty_vt.point.Point = switch (region) {
            .active => .{ .active = .{} },
            .viewport => .{ .viewport = .{} },
        };
        var it = screen.pages.rowIterator(.right_down, origin, null);
        while (it.next()) |pin| {
            pin.node.data.dirty = false;
            pin.rowAndCell().row.dirty = false;
        }
    }
}

/// Called by the renderer after it has redrawn the whole session texture.
pub fn clearRenderDirty(self: *SessionState) void {
    if (self.terminal) |*terminal| clearTerminalRenderDirty(terminal);
}
```

`std.meta.eql` on `VisibleSnapshot` compares the optional RGB structs field-wise and the node pointer by address, which is what we want. If `terminal.colors.cursor` does not exist in this ghostty version, drop that field.

- [ ] **Step 4: Gate the epoch bump in `processOutput`**

Replace the body of the drain loop's tail in `processOutput` (`src/session/state.zig:650-655`):

```zig
const was_synchronized_output = self.synchronizedOutputActive();
const before = if (self.terminal) |*terminal| captureVisibleSnapshot(terminal) else null;
const icon_before = self.agent_icon;
stream.nextSlice(self.output_buf[0..n]);
if (stream.handler.hasSemanticFailure()) return error.VtSemanticFailure;
const processed_at_ms = clock.nowMillis(self.io);
self.updateSynchronizedOutputState(was_synchronized_output, processed_at_ms);

const changed = blk: {
    if (self.agent_icon != icon_before) break :blk true;
    const terminal = &(self.terminal orelse break :blk true);
    const snapshot = before orelse break :blk true;
    break :blk terminalVisibleStateChanged(terminal, snapshot);
};
if (changed) {
    self.markDirty();
} else {
    metrics_mod.increment(.epoch_bumps_skipped);
}
```

Move `scanOsc1Agent` so `icon_before` is captured before it runs (it currently runs earlier in the loop; capture `icon_before` at the top of the iteration instead). Add `const metrics_mod = @import("../metrics.zig");` to the file.

- [ ] **Step 5: Clear dirty bits after a full cache refresh**

In `src/render/renderer.zig` `refreshSessionCacheTexture`, after `renderSessionContent(...)` and the optional overlays, before the `cache_entry.cache_epoch = ...` assignments, add `session.clearRenderDirty();` and `metrics_mod.increment(.cache_full_refreshes);` (import `metrics_mod` if the file lacks it).

- [ ] **Step 6: Run build, tests, lint**

Run: `zig build && zig build test && just lint`
Expected: PASS, including the existing `state.zig` epoch tests (`checkAlive`, `expireSynchronizedOutput`, `failAndTerminate` still call `markDirty` unconditionally).

- [ ] **Step 7: Manual verification and measurement (ReleaseFast)**

- Run `vim`, `less`, `htop`, and a `claude`/`codex` session: no stale content, cursor follows correctly, alt-screen enter/exit repaints, palette-changing apps repaint.
- Select text with the mouse and hover a URL: highlights appear and disappear (these go through `markDirty` paths that are unchanged).
- Metrics overlay: `Skipped epochs/s` > 0 during an unattended agent session.
- Probe the isolated 6-session instance in Grid and Full; append rows in `docs/perf-debugging.md`.

- [ ] **Step 8: Update docs**

- `docs/ARCHITECTURE.md` "Terminal Output Path": the step "session.render_epoch += 1" becomes "render_epoch += 1 only if ghostty's dirty bits / cursor / viewport / colors changed (`terminalVisibleStateChanged`)"; ADR-004 gains a paragraph that ghostty's dirty bits are the oracle and that the renderer owns clearing them after a refresh.
- `CLAUDE.md` Repo Notes: "ghostty-vt dirty bits (`Terminal.flags.dirty`, `Screen.dirty`, `Page.dirty`, `Row.dirty`) are consumed and cleared only by the renderer after refreshing a session's cache texture. Never clear them anywhere else, and never bump `render_epoch` for output that did not change them."

- [ ] **Step 9: Commit**

```bash
git add src/session/state.zig src/render/renderer.zig docs/ARCHITECTURE.md docs/perf-debugging.md CLAUDE.md
git commit -m "perf(session): advance render_epoch only when the visible terminal state changed"
```

---

### Task 6: Row-level partial refresh of the session cache texture

When only some rows changed (spinner, status line, timer) and the viewport did not move, redraw just those rows plus the previous and current cursor rows into the existing render-target texture instead of re-rasterizing every cell.

**Files:**
- Modify: `src/render/renderer.zig:43-118` (`RenderCache.Entry`), `:389-720` (`renderSessionContent`), `:1021-1092` (`cacheNeedsRefresh`, `refreshSessionCacheTexture`), `:1104-1160` (`renderSessionCached`), tests
- Modify: `src/session/state.zig` (`clearRenderDirty` gains a rows-only variant)
- Modify: `docs/ARCHITECTURE.md` ADR-004, `docs/perf-debugging.md`

**Interfaces:**
- Produces (in `renderer.zig`):
  ```zig
  pub const ContentKey = struct {
      cursor_x: u16, cursor_y: u16, cursor_shown: bool,
      top_node: ?*const anyopaque, top_y: u32,
      active_row_offset: usize, viewing_scrollback: bool,
      visible_rows: usize, visible_cols: usize, cell_w: c_int, cell_h: c_int,
      hovered_link_start: ?ghostty_vt.Pin, hovered_link_end: ?ghostty_vt.Pin,
      dead: bool, session_bg: c.SDL_Color, session_fg: c.SDL_Color,
  };
  pub const RefreshPlan = union(enum) { full, partial: PartialRows };
  pub const PartialRows = struct { previous_cursor_row: ?usize, current_cursor_row: ?usize };
  pub fn planRefresh(previous: ?ContentKey, next: ContentKey, terminal_wide_dirty: bool, any_page_dirty: bool) RefreshPlan;
  ```
  `RenderCache.Entry` gains `content_key: ?ContentKey = null` (reset in `releaseCacheTexture` and `ensureCacheTexture`).
- Produces (in `state.zig`): `pub fn clearRenderDirtyRows(self: *SessionState) void` — clears only row bits in the active area and viewport, leaving `flags.dirty`/`screen.dirty`/page bits untouched (those force a full refresh and are cleared by `clearRenderDirty`).
- Consumes: Task 5's `anyDirtyBit`, `clearRenderDirty`.

- [ ] **Step 1: Write the failing plan tests**

In `src/render/renderer.zig` tests:

```zig
fn testKey() ContentKey {
    return .{
        .cursor_x = 3, .cursor_y = 5, .cursor_shown = true,
        .top_node = @ptrFromInt(0x1000), .top_y = 0,
        .active_row_offset = 0, .viewing_scrollback = false,
        .visible_rows = 24, .visible_cols = 80, .cell_w = 9, .cell_h = 18,
        .hovered_link_start = null, .hovered_link_end = null,
        .dead = false,
        .session_bg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .session_fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
}

test "planRefresh: no previous key or wide dirty flags force a full refresh" {
    try std.testing.expectEqual(RefreshPlan.full, planRefresh(null, testKey(), false, false));
    try std.testing.expectEqual(RefreshPlan.full, planRefresh(testKey(), testKey(), true, false));
    try std.testing.expectEqual(RefreshPlan.full, planRefresh(testKey(), testKey(), false, true));
}

test "planRefresh: viewport, size, hover, focus, or color changes force a full refresh" {
    var next = testKey();
    next.top_y = 1;
    try std.testing.expectEqual(RefreshPlan.full, planRefresh(testKey(), next, false, false));

    next = testKey();
    next.visible_cols = 79;
    try std.testing.expectEqual(RefreshPlan.full, planRefresh(testKey(), next, false, false));

    next = testKey();
    next.hovered_link_start = .{ .node = @ptrFromInt(0x1000), .x = 1, .y = 2 };
    try std.testing.expectEqual(RefreshPlan.full, planRefresh(testKey(), next, false, false));

    next = testKey();
    next.session_bg.r = 1;
    try std.testing.expectEqual(RefreshPlan.full, planRefresh(testKey(), next, false, false));
}

test "planRefresh: cursor-only movement is partial and names both cursor rows" {
    var next = testKey();
    next.cursor_y = 7;
    const plan = planRefresh(testKey(), next, false, false);
    try std.testing.expectEqual(RefreshPlan{ .partial = .{ .previous_cursor_row = 5, .current_cursor_row = 7 } }, plan);
}

test "planRefresh: hidden cursor contributes no cursor row" {
    var prev = testKey();
    prev.cursor_shown = false;
    const plan = planRefresh(prev, testKey(), false, false);
    try std.testing.expectEqual(RefreshPlan{ .partial = .{ .previous_cursor_row = null, .current_cursor_row = 5 } }, plan);
}

test "ghostty marks only the printed row dirty for an in-place rewrite and the page for a scroll" {
    const allocator = std.testing.allocator;
    var terminal = try ghostty_vt.Terminal.init(std.testing.io, allocator, .{ .cols = 10, .rows = 4, .max_scrollback_bytes = 4096 });
    defer terminal.deinit(allocator);
    try terminal.printString("a\nb\nc");
    terminal.screens.active.pages.clearDirty();

    // Rewrite row 1 in place.
    terminal.setCursorPos(2, 1);
    try terminal.printString("B");
    const pages = terminal.screens.active.pages;
    try std.testing.expect(!pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try std.testing.expect(pages.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try std.testing.expect(!pages.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));

    // Scrolling the active area dirties every row (page-level dirty).
    terminal.screens.active.pages.clearDirty();
    terminal.setCursorPos(4, 1);
    try terminal.printString("\n");
    try std.testing.expect(pages.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try std.testing.expect(pages.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
}
```

The last test pins down the ghostty semantics the partial path relies on (rows rewritten in place are row-dirty; scrolls are page-dirty, i.e. full refresh) so a ghostty upgrade that changes them fails loudly here rather than as a visual artifact. `Pin` field names: check `PageList.Pin` (`node`, `x`, `y`) in the ghostty source before finalizing the hover test.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: compile errors for `ContentKey`, `planRefresh`, `RefreshPlan`.

- [ ] **Step 3: Implement `ContentKey`, `planRefresh`, and the entry field**

In `src/render/renderer.zig` after `RenderCache`:

```zig
pub const PartialRows = struct {
    previous_cursor_row: ?usize,
    current_cursor_row: ?usize,
};

pub const RefreshPlan = union(enum) {
    full,
    partial: PartialRows,
};

/// Everything besides cell contents that determines the pixels of a session
/// texture. If any field other than the cursor position differs from the
/// key stored with the cache, the whole texture is redrawn; cursor moves
/// only redraw the old and new cursor rows.
pub const ContentKey = struct {
    cursor_x: u16,
    cursor_y: u16,
    cursor_shown: bool,
    top_node: ?*const anyopaque,
    top_y: u32,
    active_row_offset: usize,
    viewing_scrollback: bool,
    visible_rows: usize,
    visible_cols: usize,
    cell_w: c_int,
    cell_h: c_int,
    hovered_link_start: ?ghostty_vt.Pin,
    hovered_link_end: ?ghostty_vt.Pin,
    dead: bool,
    session_bg: c.SDL_Color,
    session_fg: c.SDL_Color,

    fn sameExceptCursor(a: ContentKey, b: ContentKey) bool {
        var a_nc = a;
        var b_nc = b;
        a_nc.cursor_x = 0;
        a_nc.cursor_y = 0;
        a_nc.cursor_shown = false;
        b_nc.cursor_x = 0;
        b_nc.cursor_y = 0;
        b_nc.cursor_shown = false;
        return std.meta.eql(a_nc, b_nc);
    }
};

pub fn planRefresh(previous: ?ContentKey, next: ContentKey, terminal_wide_dirty: bool, any_page_dirty: bool) RefreshPlan {
    const prev = previous orelse return .full;
    if (terminal_wide_dirty or any_page_dirty) return .full;
    if (!ContentKey.sameExceptCursor(prev, next)) return .full;
    return .{ .partial = .{
        .previous_cursor_row = if (prev.cursor_shown) @as(usize, prev.cursor_y) else null,
        .current_cursor_row = if (next.cursor_shown) @as(usize, next.cursor_y) else null,
    } };
}
```

Add `content_key: ?ContentKey = null,` to `RenderCache.Entry`; set it to `null` in `releaseCacheTexture` and in the recreate path of `ensureCacheTexture`.

- [ ] **Step 4: Run the plan tests**

Run: `zig build test`
Expected: PASS for the `planRefresh` and ghostty-semantics tests. If the ghostty-semantics test fails, stop: the dirty model differs from the one this task assumes, and the partial path must not be built on it. Report the failing assertion.

- [ ] **Step 5: Extract the content-key computation from `renderSessionContent`**

`renderSessionContent` already computes `cursor_col/row`, `should_render_cursor`, `visible_rows/cols`, `active_row_offset`, `cell_*_actual`, `session_bg/fg_color`, and the first row pin. Factor those into:

```zig
const ContentLayout = struct {
    key: ContentKey,
    origin_x: c_int,
    origin_y: c_int,
    first_row_pin: ?ghostty_vt.Pin,
};

fn computeContentLayout(
    session: *const SessionState,
    view: *const SessionViewState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    font: *const font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    is_grid_view: bool,
    theme: *const colors.Theme,
    ui_scale: f32,
) ?ContentLayout
```

returning `null` when the drawable area is empty (the existing early return). `renderSessionContent` calls it and uses the fields; nothing else changes in this step. Build and run tests to confirm no behavior change (`zig build test`).

- [ ] **Step 6: Add row selection to `renderSessionContent`**

Add a parameter `rows: RowSelection` where

```zig
const RowSelection = union(enum) {
    all,
    changed: PartialRows,
};
```

In the row loop, right after `const current_row_pin = row_pin orelse continue; row_pin = current_row_pin.down(1);`:

```zig
const source_row = row + active_row_offset;
switch (rows) {
    .all => {},
    .changed => |sel| {
        const is_cursor_row = (sel.previous_cursor_row != null and sel.previous_cursor_row.? == source_row) or
            (sel.current_cursor_row != null and sel.current_cursor_row.? == source_row);
        if (!current_row_pin.isDirty() and !is_cursor_row) continue;
        // Clear this row's strip before redrawing it.
        _ = c.SDL_SetRenderDrawColor(renderer, session_bg_color.r, session_bg_color.g, session_bg_color.b, 255);
        const strip = c.SDL_FRect{
            .x = @floatFromInt(origin_x),
            .y = @floatFromInt(origin_y + @as(c_int, @intCast(row)) * cell_height_actual),
            .w = @floatFromInt(@as(c_int, @intCast(visible_cols)) * cell_width_actual),
            .h = @floatFromInt(cell_height_actual),
        };
        _ = c.SDL_RenderFillRect(renderer, &strip);
    },
}
```

and make the whole-rect background fill at the top of the function conditional on `rows == .all`. The per-cell `source_row` computed inside the column loop becomes this hoisted value. Everything drawn by a row iteration (backgrounds, selection, underlines, box drawing, glyph runs) is confined to that row's strip, so redrawing a strip is self-contained. Add `.all` at the existing call sites (`renderSession`, the non-cached path in `renderSessionCached`).

- [ ] **Step 7: Drive the plan from `refreshSessionCacheTexture`**

Change `refreshSessionCacheTexture` to compute the layout, plan, and act:

```zig
const layout = computeContentLayout(session, view, local_rect, scale, is_focused, font, term_cols, term_rows, is_grid_view, theme, ui_scale) orelse return;
const terminal = session.terminal orelse return;
const terminal_wide_dirty = session_state.anyDirtyBit(terminal.flags.dirty) or session_state.anyDirtyBit(terminal.screens.active.dirty);
const any_page_dirty = anyPageDirty(terminal.screens.active);
// Baked overlays (wave effect) paint outside row strips, so they always
// take the full path.
const plan: RefreshPlan = if (cache_overlays) .full else planRefresh(cache_entry.content_key, layout.key, terminal_wide_dirty, any_page_dirty);

switch (plan) {
    .full => {
        _ = c.SDL_SetRenderDrawColor(renderer, theme.background.r, theme.background.g, theme.background.b, 255);
        _ = c.SDL_RenderClear(renderer);
        try renderSessionContent(renderer, session, view, local_rect, scale, is_focused, font, term_cols, term_rows, current_time_ms, is_grid_view, theme, ui_scale, show_onboarding, onboarding_displayed, .all);
        if (cache_overlays) renderSessionOverlays(...);
        session.clearRenderDirty();
        metrics_mod.increment(.cache_full_refreshes);
    },
    .partial => |sel| {
        try renderSessionContent(renderer, session, view, local_rect, scale, is_focused, font, term_cols, term_rows, current_time_ms, is_grid_view, theme, ui_scale, show_onboarding, onboarding_displayed, .{ .changed = sel });
        session.clearRenderDirtyRows();
        metrics_mod.increment(.cache_partial_refreshes);
    },
}
cache_entry.content_key = layout.key;
cache_entry.cache_epoch = session.render_epoch;
// composition/render_mode assignments unchanged
```

with

```zig
fn anyPageDirty(screen: *ghostty_vt.Screen) bool {
    var it = screen.pages.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |pin| {
        if (pin.node.data.dirty) return true;
    }
    return false;
}
```

Add `clearRenderDirtyRows` to `SessionState` (same iteration as `clearTerminalRenderDirty` but only `row.dirty = false`, no `flags`/`screen`/page resets). The onboarding hint (`renderOnboardingHint`) is drawn inside `renderSessionContent` for the first never-used session; make sure it is only drawn on the `.all` path (partial never applies to an unspawned session anyway since `renderSessionCached` returns early for those).

- [ ] **Step 8: Run build, tests, lint**

Run: `zig build && zig build test && just lint`
Expected: PASS.

- [ ] **Step 9: Manual verification (ReleaseFast) — visual artifacts hunt**

Run each scenario in both Grid and Full view and watch for leftover glyphs, missing cursor, or ghosted rows:

- `fake_codex.py` spinner: only the spinner row changes; metrics show `Cache partial/s` ~ spinner rate and `Cache full/s` ~0.
- `yes | head -10000` and `cat` of a large file: scrolling output (page dirty) takes the full path with no tearing.
- Cursor movement with arrow keys in `zsh` line editing; `vim` insert/normal mode cursor style changes (block/beam/underline) redraw the cursor row.
- Wide CJK/emoji text overwritten by ASCII in the same row (strip clear must erase the wide glyph).
- Selection drag and URL hover (full path via `screen.dirty.selection` and the hover key).
- Grid <-> Full toggle, font size change, window resize (texture recreate → full).
- `clear` and alt-screen apps (`less`, `htop`) → `flags.dirty.clear` → full.
- OSC 11 background change (`printf '\e]11;#202040\a'`) → colors in key → full.
- Session dies (`exit`) → `dead` in key → full with the dead-state rendering.

Then probe the 6-session isolated instance and the daily instance; append rows in `docs/perf-debugging.md`.

- [ ] **Step 10: Update docs and commit**

- `docs/ARCHITECTURE.md` ADR-004: replace the "Dirty-flag per cell — rejected" alternative with the current design: ghostty row/page dirty bits drive partial redraws into the persistent render-target texture; full redraws happen on wide dirty flags, page dirty, viewport moves, size/hover/focus/color changes; the renderer clears the bits it consumed.
- `docs/perf-debugging.md`: a "Dirty tracking" subsection listing the full-vs-partial rules and pointing at the ghostty-semantics test as the canary for upgrades.

```bash
git add src/render/renderer.zig src/session/state.zig docs/ARCHITECTURE.md docs/perf-debugging.md
git commit -m "perf(render): redraw only dirty rows into the session cache texture"
```

---

### Task 7: Final measurements and documentation consolidation

**Files:**
- Modify: `docs/perf-debugging.md`, `docs/ARCHITECTURE.md` (ADR-016), `CLAUDE.md`

- [ ] **Step 1: Re-run the three probes on a ReleaseFast build with all tasks merged**

Same procedure as Task 1 Step 6 (isolated 6 x `fake_codex.py` Grid, Full, and the daily instance after relaunching it on the new build; 60 s each). Fill the final row of the table in `docs/perf-debugging.md`. Also record `Present/s`, `Loop/s`, `Cache full/s`, `Cache partial/s` from the metrics overlay for the unattended Grid scenario.

- [ ] **Step 2: Write ADR-016 in `docs/ARCHITECTURE.md`**

```markdown
### ADR-016: Change-Driven Presentation

- **Decision:** A frame is presented only when something visible changed, and output-driven frames are paced at 30 fps unless the user interacted in the last 500 ms. Terminal output advances `render_epoch` only when ghostty-vt's dirty tracking (row/page/terminal/screen dirty bits, cursor, viewport, dynamic colors) reports a change; the renderer redraws only dirty rows into the persistent session texture and clears the bits it consumed. There is no periodic re-render and no fixed idle tick: the loop sleeps until the next timer deadline or 1 s, and every background thread blocks in `poll(2)` with a `WakePipe`.
- **Context:** With seven agent TUIs animating spinners around the clock, the previous "any PTY chunk = present" rule plus a periodic re-render floor and 10 ms socket polls kept the main thread at ~12% CPU for days (see docs/perf-debugging.md, "Energy baseline"), earning macOS's "using significant energy" badge.
- **Alternatives considered:**
  - *Keep the periodic floor as a safety net* — rejected: it is a speculative fallback that hides missing invalidations and costs 4 presents/s forever. Missing invalidations are bugs to fix (Task 4's audit) and the metrics overlay makes them visible.
  - *Adopt ghostty's `RenderState` wholesale* — rejected for now: it copies every viewport cell per update, and Architect's renderer walks pins directly; consuming the same dirty bits in place is cheaper and a smaller change. Revisit if the renderer moves to GPU cell buffers.
  - *Configurable output fps cap* — deferred; a constant is enough until someone needs to tune it.
- **Date:** 2026-09
```

- [ ] **Step 3: Final read-through of `CLAUDE.md` Repo Notes and `docs/ARCHITECTURE.md`**

Confirm the notes added by Tasks 2-6 are present, not duplicated, and that no text still describes the short idle tick, periodic floor, 10 ms accept polls, or 100 ms reader poll (`rg -n "periodic floor|old idle tick|10 ms|100ms" docs CLAUDE.md README.md`).

- [ ] **Step 4: Commit**

```bash
git add docs/perf-debugging.md docs/ARCHITECTURE.md CLAUDE.md
git commit -m "docs: record energy results and ADR-016 change-driven presentation"
```

---

## Deferred / explicitly out of scope

- **Mouse-motion events forcing a present.** Every SDL event still counts as `processed_event` and renders a frame. Motion only happens while the user is present, so it does not contribute to the unattended drain. A follow-up could render on events only when a component consumed them or hover state changed.
- **Process-exit latency.** With the idle wait up to 1 s, a session's shell exit is noticed up to 1 s later than today (the xev loop runs only when the frame loop wakes). Acceptable for a "[Process completed]" badge; if not, add the xev loop's backing fd to the wake sources.
- **Configurable output fps cap** and **using ghostty `RenderState`** — see ADR-016.
- **Logging volume.** `[logging].min_level = "debug"` in the user's daily config produced 1.7 GB of rotated logs. That is a config choice, not a code defect; set it to `info` for daily use.
- **`hasForegroundProcess` sysctl every 150 ms** — negligible next to rendering; leave as is.

## Risks and how the plan contains them

- **Stale frames after removing the periodic floor (Task 4).** Contained by the `wantsFrame` audit step, by keeping every existing `markDirty` call, and by the metrics overlay showing `Present/s` so a missing invalidation is diagnosable. Do not respond to a stale-frame report by re-adding a periodic render; find the missing invalidation.
- **False negatives in change detection (Task 5).** The rule is a superset of ghostty's own redraw rule plus explicit cursor/color/screen comparisons; false positives are accepted. The ghostty-semantics test in Task 6 fails loudly on an upstream dirty-model change.
- **Partial-redraw artifacts (Task 6).** Every cross-row effect (scroll, clear, selection, hover, viewport move, size, focus, colors, baked overlays) is routed to the full path by `planRefresh`; the manual checklist covers each. If an artifact is found, the fix is to add its trigger to `ContentKey` or the wide-dirty inputs, not to skip the partial path.
