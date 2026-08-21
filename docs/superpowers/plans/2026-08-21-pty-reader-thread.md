# Dedicated PTY Reader Thread Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consume every session's PTY output at wire speed on a dedicated background thread, so PTY ingestion is decoupled from render pacing and chatty producers (JVM/JLine TUIs like Junie CLI) are never backpressured or held by stale DEC-2026 sync windows.

**Architecture:** A single background reader thread (evolving the existing `pty_watcher` thread) polls all spawned sessions' PTY master fds and, when readable, drains them into per-session mutex-guarded ring buffers. The main thread's `SessionState.processOutput` consumes bytes from its session's ring buffer instead of reading the fd, keeping all VT parsing and terminal-state mutation single-threaded on the main thread. Session spawn registers the fd+buffer with the reader; teardown retires it with a mutex handshake that guarantees no in-flight read survives, then closes the fd and frees the buffer.

**Tech Stack:** Zig 0.15, std.Thread, poll(2), existing SDL wake-event plumbing (`platform.pushWakeEventFromOpaque`), ghostty-vt (unchanged).

**Spec:** The "Background: root cause" section below (investigation of Junie CLI latency, 2026-08-21). There is no external spec document.

## Background: root cause

Junie CLI (JLine/Compose TUI) repaints its full screen every frame, wrapped in `ESC[?2026h … ESC[?2026l` (DEC synchronized output), written as ~150 small (~190-byte) `write()` syscalls per frame at up to ~19fps. Architect currently drains each PTY only once per frame-loop iteration and stops at the first `EWOULDBLOCK`, so:

1. Drain boundaries land *inside* a sync window ~97% of the time (the next frame's `2026h` arrives in the same drain batch as the previous frame's `2026l`).
2. `synchronizedOutputHoldsCache` (`src/render/renderer.zig:1041`) then keeps showing the stale texture — measured: hold engaged at 50–58 of ~60 render ticks/sec, actual session repaints got through at only 2–9/sec.
3. The frame-paced drain also caps ingest throughput; the kernel PTY buffer backs up and Junie's writes block 250–800 ms per frame (its own `[tui-perf] write p95=512ms` telemetry), collapsing it to ~1–2fps. The `expireSynchronizedOutput` 1000 ms force-clear (`src/session/state.zig:77`) sets the perceived ~1s/keypress latency.

Control experiment: with rendering suppressed (occluded window), the existing drain loop kept up effortlessly and Junie's writes took 2 ms — the drain being *frame-paced* is the defect, not drain speed. Ghostty is unaffected because it reads the PTY on a dedicated IO thread; with wire-speed reads a 2026 window is only open for the few ms the producer spends writing a frame, so render-time holds become one-frame rarities and the expiry timers become the safety net they were meant to be. No renderer or hold-timing changes are needed.

## Global Constraints

- Zig 0.15.2 via `nix develop` (or direnv); build with `nix develop -c zig build`, test with `nix develop -c zig build test`.
- NEVER pipe `zig build test` output in the success-determining call (pipes mask failures); run it bare, capture exit code, only then grep logs if needed.
- Every new file with tests MUST be added to the `test { _ = @import(...); }` block in `src/main.zig`; `scripts/check-test-registry.sh` (part of `just lint`) enforces this.
- No bare `catch {}` / `catch unreachable`; log or propagate every error.
- Run `zig fmt src/` on touched files before each commit.
- Conventional commit messages.
- Zig 0.15 std lib: `std.ArrayList` needs allocator per call; `std.Thread.sleep` for sleeps; prefer explicit error sets.
- Do not introduce new dependencies.
- Update `docs/ARCHITECTURE.md` in the same PR (Agent Rules #5 and Documentation Hygiene in CLAUDE.md).

## File Structure

- **Create** `src/session/pty_reader.zig` — the new module: `PtyOutputBuffer` (SPSC byte ring, mutex-guarded), `PtyReader` (fd→buffer registry + retire handshake), reader thread `start()`/`run()`, `RuntimeWake` (same shape as the one in `pty_watcher.zig`).
- **Modify** `src/session/state.zig` — `SessionState` gains `pty_reader`/`pty_buffer` fields; `init()` takes the reader; `ensureSpawnedWithDir` creates+registers the buffer; `teardown` retires+frees it; `processOutput` consumes from the buffer instead of `shell.read`.
- **Modify** `src/app/runtime.zig` — replace `pty_watcher` state/thread with `pty_reader`; delete the per-frame `updateFds` fd-list refresh; pass the reader to `SessionState.init`.
- **Delete** `src/session/pty_watcher.zig` — fully replaced.
- **Modify** `src/main.zig` — test registry: add `pty_reader.zig`, remove `pty_watcher.zig`.
- **Modify** `docs/ARCHITECTURE.md`, `docs/perf-debugging.md` — thread model and lessons learned.

**Locking rules (memorize before coding):** `PtyReader.mutex` (registry) is always taken before a `PtyOutputBuffer.mutex` (only the reader thread ever holds both). The main thread takes only buffer mutexes. Nothing blocks while holding either mutex — fds are `O_NONBLOCK` and all critical sections are bounded memcpys/reads.

---

### Task 1: `PtyOutputBuffer` — SPSC byte ring with fd pump

**Files:**
- Create: `src/session/pty_reader.zig`
- Modify: `src/main.zig:53` (test registry)
- Test: in-file `test` blocks in `src/session/pty_reader.zig`

**Interfaces:**
- Produces: `PtyOutputBuffer.create(allocator) error{OutOfMemory}!*PtyOutputBuffer`, `createWithCapacity(allocator, capacity)`, `destroy(self, allocator)`, `pumpFd(self, fd) PumpOutcome`, `consume(self, dest: []u8) usize`, `takePendingReadError(self) ?posix.ReadError`, `canAcceptBytes(self) bool`, `pub const PumpOutcome = enum { progressed, idle, full, closed }`, `pub const buffer_capacity: usize = 1 << 20`, `pub const RuntimeWake` (context+callback struct identical in shape to `pty_watcher.RuntimeWake`).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Create the file with types and failing tests**

Create `src/session/pty_reader.zig`:

```zig
const std = @import("std");
const posix = std.posix;
const atomic = std.atomic;
const grid_layout = @import("../app/grid_layout.zig");

const log = std.log.scoped(.pty_reader);

const poll_timeout_ms: i32 = 100;
const poll_error_backoff_ns: u64 = 10 * std.time.ns_per_ms;

/// Bytes buffered per session between the reader thread and the main
/// thread. Sized to match the main thread's per-frame parse budget
/// (`max_process_output_bytes_per_call` in session/state.zig) so even a
/// full buffer drains within a single frame; a full-screen TUI repaint is
/// ~30 KB, so this absorbs dozens of frames of producer burst.
pub const buffer_capacity: usize = 1 << 20;

pub const RuntimeWake = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,

    pub fn notify(self: RuntimeWake) void {
        self.callback(self.context);
    }
};

pub const PumpOutcome = enum {
    /// New bytes were appended to the ring.
    progressed,
    /// The fd had no bytes available (EWOULDBLOCK) and nothing was read.
    idle,
    /// The ring is full; the caller must stop polling this fd until the
    /// consumer frees space, or poll(2) would spin hot on POLLIN.
    full,
    /// EOF/EIO was reached or an unrecoverable read error was recorded;
    /// the fd must not be pumped again.
    closed,
};

/// Single-producer (reader thread) / single-consumer (main thread) byte
/// ring. Every field is guarded by `mutex`. Both sides hold the mutex only
/// for bounded, non-blocking work: the producer reads an O_NONBLOCK fd into
/// free ring space, the consumer memcpys out. `head` is the index of the
/// first unconsumed byte; the write position is derived as
/// `(head + len) % data.len`.
pub const PtyOutputBuffer = struct {
    mutex: std.Thread.Mutex = .{},
    data: []u8,
    head: usize = 0,
    len: usize = 0,
    /// Set once the PTY reached EOF (read() == 0) or EIO; terminal states
    /// are detected separately (xev process watcher / checkAlive), so the
    /// consumer just stops receiving bytes.
    eof: bool = false,
    /// First unrecoverable read error. Surfaced to the consumer via
    /// takePendingReadError only after all buffered bytes are drained, so
    /// no output preceding the failure is lost.
    read_error: ?posix.ReadError = null,

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*PtyOutputBuffer {
        return createWithCapacity(allocator, buffer_capacity);
    }

    pub fn createWithCapacity(allocator: std.mem.Allocator, capacity: usize) error{OutOfMemory}!*PtyOutputBuffer {
        std.debug.assert(capacity > 0);
        const self = try allocator.create(PtyOutputBuffer);
        errdefer allocator.destroy(self);
        self.* = .{ .data = try allocator.alloc(u8, capacity) };
        return self;
    }

    pub fn destroy(self: *PtyOutputBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }

    /// Reader-thread side: drain `fd` (which MUST be O_NONBLOCK) into free
    /// ring space until the fd would block, the ring fills, or the fd
    /// closes/fails.
    pub fn pumpFd(self: *PtyOutputBuffer, fd: posix.fd_t) PumpOutcome {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.eof or self.read_error != null) return .closed;

        var progressed = false;
        while (true) {
            if (self.len == self.data.len) return .full;
            const free_slice = self.contiguousFreeSlice();
            const n = posix.read(fd, free_slice) catch |err| switch (err) {
                error.WouldBlock => return if (progressed) .progressed else .idle,
                // PTYs report EIO once the slave side is gone; treat it as EOF.
                error.InputOutput => {
                    self.eof = true;
                    return .closed;
                },
                else => |other| {
                    self.read_error = other;
                    return .closed;
                },
            };
            if (n == 0) {
                self.eof = true;
                return .closed;
            }
            self.len += n;
            progressed = true;
        }
    }

    /// Main-thread side: copy up to dest.len buffered bytes out, in order.
    pub fn consume(self: *PtyOutputBuffer, dest: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var copied: usize = 0;
        while (copied < dest.len and self.len > 0) {
            const contiguous = @min(self.len, self.data.len - self.head);
            const chunk_len = @min(dest.len - copied, contiguous);
            @memcpy(dest[copied..][0..chunk_len], self.data[self.head..][0..chunk_len]);
            self.head = (self.head + chunk_len) % self.data.len;
            self.len -= chunk_len;
            copied += chunk_len;
        }
        // Reset to maximize the producer's contiguous write region.
        if (self.len == 0) self.head = 0;
        return copied;
    }

    /// Surfaces the recorded unrecoverable read error exactly once, and only
    /// after every buffered byte has been consumed.
    pub fn takePendingReadError(self: *PtyOutputBuffer) ?posix.ReadError {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len > 0) return null;
        const err = self.read_error orelse return null;
        self.read_error = null;
        return err;
    }

    /// Whether the reader thread should keep polling this buffer's fd.
    pub fn canAcceptBytes(self: *PtyOutputBuffer) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.eof and self.read_error == null and self.len < self.data.len;
    }

    /// Free region starting at the write position, up to the end of storage
    /// or up to `head` when the free space wraps. Never called on a full
    /// ring (caller checks `len == data.len` first).
    fn contiguousFreeSlice(self: *PtyOutputBuffer) []u8 {
        std.debug.assert(self.len < self.data.len);
        const tail = (self.head + self.len) % self.data.len;
        if (tail < self.head) return self.data[tail..self.head];
        return self.data[tail..];
    }
};
```

Append the tests (same file). Helper + tests:

```zig
fn makeNonBlockingPipe() ![2]posix.fd_t {
    const fds = try posix.pipe();
    const flags = try posix.fcntl(fds[0], posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fds[0], posix.F.SETFL, @as(u32, @bitCast(o_flags)));
    return fds;
}

test "PtyOutputBuffer pumps a pipe and consumes in order" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.create(allocator);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    _ = try posix.write(fds[1], "hello ");
    _ = try posix.write(fds[1], "world");

    try std.testing.expectEqual(PumpOutcome.progressed, buffer.pumpFd(fds[0]));

    var out: [64]u8 = undefined;
    const n = buffer.consume(&out);
    try std.testing.expectEqualSlices(u8, "hello world", out[0..n]);
    try std.testing.expectEqual(@as(usize, 0), buffer.consume(&out));
}

test "PtyOutputBuffer returns idle when the fd has no data" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.create(allocator);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try std.testing.expectEqual(PumpOutcome.idle, buffer.pumpFd(fds[0]));
}

test "PtyOutputBuffer wraps around a small ring without corrupting bytes" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.createWithCapacity(allocator, 8);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var out: [8]u8 = undefined;

    _ = try posix.write(fds[1], "abcdef");
    try std.testing.expectEqual(PumpOutcome.progressed, buffer.pumpFd(fds[0]));
    try std.testing.expectEqual(@as(usize, 4), buffer.consume(out[0..4]));
    try std.testing.expectEqualSlices(u8, "abcd", out[0..4]);

    // head=4, len=2; writing 5 more forces the free region to wrap.
    _ = try posix.write(fds[1], "ghijk");
    try std.testing.expectEqual(PumpOutcome.progressed, buffer.pumpFd(fds[0]));
    const n = buffer.consume(&out);
    try std.testing.expectEqualSlices(u8, "efghijk", out[0..n]);
}

test "PtyOutputBuffer reports full and resumes after the consumer drains" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.createWithCapacity(allocator, 4);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    _ = try posix.write(fds[1], "abcdef");
    try std.testing.expectEqual(PumpOutcome.full, buffer.pumpFd(fds[0]));
    try std.testing.expect(!buffer.canAcceptBytes());

    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), buffer.consume(&out));
    try std.testing.expectEqualSlices(u8, "abcd", out[0..4]);
    try std.testing.expect(buffer.canAcceptBytes());

    try std.testing.expectEqual(PumpOutcome.progressed, buffer.pumpFd(fds[0]));
    const n = buffer.consume(&out);
    try std.testing.expectEqualSlices(u8, "ef", out[0..n]);
}

test "PtyOutputBuffer records EOF when the write end closes" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.create(allocator);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);

    _ = try posix.write(fds[1], "tail");
    posix.close(fds[1]);

    // First pump drains the buffered bytes, second observes EOF.
    _ = buffer.pumpFd(fds[0]);
    try std.testing.expectEqual(PumpOutcome.closed, buffer.pumpFd(fds[0]));
    try std.testing.expect(!buffer.canAcceptBytes());

    var out: [8]u8 = undefined;
    const n = buffer.consume(&out);
    try std.testing.expectEqualSlices(u8, "tail", out[0..n]);
    try std.testing.expectEqual(@as(?posix.ReadError, null), buffer.takePendingReadError());
}

test "PtyOutputBuffer surfaces a read error only after the ring is drained" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.create(allocator);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    _ = try posix.write(fds[1], "data");
    try std.testing.expectEqual(PumpOutcome.progressed, buffer.pumpFd(fds[0]));

    // Simulate an unrecoverable read failure recorded by the producer.
    {
        buffer.mutex.lock();
        defer buffer.mutex.unlock();
        buffer.read_error = error.NotOpenForReading;
    }

    try std.testing.expectEqual(@as(?posix.ReadError, null), buffer.takePendingReadError());
    var out: [8]u8 = undefined;
    _ = buffer.consume(&out);
    try std.testing.expectEqual(@as(?posix.ReadError, error.NotOpenForReading), buffer.takePendingReadError());
    // Exactly once.
    try std.testing.expectEqual(@as(?posix.ReadError, null), buffer.takePendingReadError());
}
```

- [ ] **Step 2: Register the file in `src/main.zig` and verify the tests fail to compile/run before the implementation is complete**

In `src/main.zig`, inside the `test` block, after `_ = @import("session/notify.zig");` (line 52), add:

```zig
    _ = @import("session/pty_reader.zig");
```

(Keep `session/pty_watcher.zig` in the list for now — it is deleted in Task 4.)

If you wrote the tests before/alongside the implementation, at minimum verify the suite runs the new tests: temporarily break one expectation (e.g. expect `"HELLO world"`), run `nix develop -c zig build test`, confirm that exact test fails, then restore it. This proves the file is registered and the tests execute.

- [ ] **Step 3: Run the tests**

Run: `nix develop -c zig build test`
Expected: PASS (exit code 0, no output). Do not pipe this command.

- [ ] **Step 4: Format and commit**

```bash
zig fmt src/session/pty_reader.zig src/main.zig
git add src/session/pty_reader.zig src/main.zig
git commit -m "feat(session): add SPSC PTY output ring buffer"
```

---

### Task 2: `PtyReader` — registry, retire handshake, and reader thread

**Files:**
- Modify: `src/session/pty_reader.zig` (append below `PtyOutputBuffer`)
- Test: in-file `test` blocks

**Interfaces:**
- Consumes: `PtyOutputBuffer`, `PumpOutcome`, `RuntimeWake`, `poll_timeout_ms`, `poll_error_backoff_ns` from Task 1.
- Produces: `PtyReader` struct with `register(self, fd, buffer)`, `retire(self, fd)`, and `pub fn start(reader: *PtyReader, stop: *atomic.Value(bool), wake_pending: *atomic.Value(bool), runtime_wake: ?RuntimeWake) StartError!std.Thread` with `pub const StartError = std.Thread.SpawnError`. Task 3 calls `register`/`retire` from `SessionState`; Task 4 calls `start` from the runtime.

- [ ] **Step 1: Append the implementation**

```zig
const Entry = struct {
    fd: posix.fd_t,
    buffer: *PtyOutputBuffer,
};

/// Wake-worthy poll conditions: readable data, and terminal states that
/// still need a final drain (hang-up, error, invalid fd). pumpFd itself
/// discovers EOF/EIO on the subsequent read.
const wake_worthy_events: i16 = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;

fn isWakeWorthy(revents: i16) bool {
    return (revents & wake_worthy_events) != 0;
}

/// Registry of PTY master fds the reader thread drains into per-session
/// ring buffers. Every read of a registered fd happens while `mutex` is
/// held, so `retire` returning guarantees the reader can no longer touch
/// the fd or its buffer: the caller may then close the fd and destroy the
/// buffer. poll(2) itself runs on a snapshot outside the lock; polling an
/// fd that was concurrently retired (or even closed) only yields a
/// harmless POLLNVAL/stale event, because the pump phase re-resolves each
/// fd against the live registry under the lock before reading.
pub const PtyReader = struct {
    mutex: std.Thread.Mutex = .{},
    entries: [grid_layout.max_terminals]Entry = undefined,
    entry_count: usize = 0,

    pub fn register(self: *PtyReader, fd: posix.fd_t, buffer: *PtyOutputBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.entry_count < self.entries.len);
        self.entries[self.entry_count] = .{ .fd = fd, .buffer = buffer };
        self.entry_count += 1;
    }

    pub fn retire(self: *PtyReader, fd: posix.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.entry_count], 0..) |entry, i| {
            if (entry.fd == fd) {
                self.entries[i] = self.entries[self.entry_count - 1];
                self.entry_count -= 1;
                return;
            }
        }
    }

    /// Snapshot the fds worth polling: registered entries whose buffers can
    /// still accept bytes. Full or closed buffers are excluded so poll(2)
    /// does not spin hot on data nobody can store; they rejoin the set on a
    /// later iteration once the consumer frees space (bounded by
    /// poll_timeout_ms).
    fn snapshotPollfds(self: *PtyReader, out: *[grid_layout.max_terminals]posix.pollfd) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.entries[0..self.entry_count]) |entry| {
            if (!entry.buffer.canAcceptBytes()) continue;
            out[count] = .{ .fd = entry.fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        return count;
    }

    /// Pump every ready fd that is still registered. Holds the registry
    /// mutex across the reads — this is the other half of the `retire`
    /// contract. Returns true when any buffer received new bytes.
    fn pumpReadyFds(self: *PtyReader, pollfds: []const posix.pollfd) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var progressed = false;
        for (pollfds) |pfd| {
            if (!isWakeWorthy(pfd.revents)) continue;
            const buffer = self.bufferForFdLocked(pfd.fd) orelse continue;
            if (buffer.pumpFd(pfd.fd) == .progressed) progressed = true;
        }
        return progressed;
    }

    fn bufferForFdLocked(self: *PtyReader, fd: posix.fd_t) ?*PtyOutputBuffer {
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.fd == fd) return entry.buffer;
        }
        return null;
    }
};

const ReaderContext = struct {
    reader: *PtyReader,
    stop: *atomic.Value(bool),
    wake_pending: *atomic.Value(bool),
    runtime_wake: ?RuntimeWake,
};

pub const StartError = std.Thread.SpawnError;

/// Starts the PTY reader thread. The caller owns `reader`/`stop`/
/// `wake_pending` and joins the returned thread after setting `stop`.
/// `wake_pending` deduplicates wake notifications: the reader posts one
/// wake per main-loop frame at most; the runtime clears the flag at the
/// top of its per-frame drain.
pub fn start(
    reader: *PtyReader,
    stop: *atomic.Value(bool),
    wake_pending: *atomic.Value(bool),
    runtime_wake: ?RuntimeWake,
) StartError!std.Thread {
    const ctx = ReaderContext{
        .reader = reader,
        .stop = stop,
        .wake_pending = wake_pending,
        .runtime_wake = runtime_wake,
    };
    return try std.Thread.spawn(.{}, run, .{ctx});
}

fn run(ctx: ReaderContext) void {
    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;

    while (!ctx.stop.load(.seq_cst)) {
        const count = ctx.reader.snapshotPollfds(&pollfds);
        if (count == 0) {
            std.Thread.sleep(@as(u64, @intCast(poll_timeout_ms)) * std.time.ns_per_ms);
            continue;
        }

        const ready = posix.poll(pollfds[0..count], poll_timeout_ms) catch |err| {
            log.debug("poll failed: {}", .{err});
            std.Thread.sleep(poll_error_backoff_ns);
            continue;
        };
        if (ready == 0) continue;

        const progressed = ctx.reader.pumpReadyFds(pollfds[0..count]);
        if (progressed) {
            if (!ctx.wake_pending.swap(true, .seq_cst)) {
                if (ctx.runtime_wake) |waker| waker.notify();
            }
        }
    }
}
```

- [ ] **Step 2: Append the tests**

Bounded condition-waiting helper and tests (no fixed sleeps for success paths; sleeps only to prove absence of activity):

```zig
fn waitForCondition(comptime cond: fn (ctx: anytype) bool, ctx: anytype, timeout_ms: u64) bool {
    var waited_ms: u64 = 0;
    while (waited_ms < timeout_ms) : (waited_ms += 5) {
        if (cond(ctx)) return true;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return cond(ctx);
}

fn bufferHasBytes(buffer: *PtyOutputBuffer) bool {
    buffer.mutex.lock();
    defer buffer.mutex.unlock();
    return buffer.len > 0;
}

test "PtyReader register/retire updates the poll snapshot" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.createWithCapacity(allocator, 16);
    defer buffer.destroy(allocator);

    var reader = PtyReader{};
    reader.register(7, buffer);
    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;
    try std.testing.expectEqual(@as(usize, 1), reader.snapshotPollfds(&pollfds));
    try std.testing.expectEqual(@as(posix.fd_t, 7), pollfds[0].fd);

    reader.retire(7);
    try std.testing.expectEqual(@as(usize, 0), reader.snapshotPollfds(&pollfds));
}

test "PtyReader thread drains a pipe into the buffer and posts one wake" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.create(allocator);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var reader = PtyReader{};
    var stop = atomic.Value(bool).init(false);
    var wake_pending = atomic.Value(bool).init(false);

    const Wakes = struct {
        var count = atomic.Value(usize).init(0);
        fn bump(_: ?*anyopaque) void {
            _ = count.fetchAdd(1, .seq_cst);
        }
    };
    Wakes.count.store(0, .seq_cst);

    const thread = try start(&reader, &stop, &wake_pending, .{ .context = null, .callback = Wakes.bump });
    defer {
        stop.store(true, .seq_cst);
        thread.join();
    }

    reader.register(fds[0], buffer);
    _ = try posix.write(fds[1], "ping");

    try std.testing.expect(waitForCondition(bufferHasBytes, buffer, 2_000));
    try std.testing.expect(wake_pending.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), Wakes.count.load(.seq_cst));

    // While wake_pending stays set, further output must not post more wakes.
    _ = try posix.write(fds[1], "pong");
    std.Thread.sleep(300 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), Wakes.count.load(.seq_cst));

    // After the "frame" clears the flag, new output posts a fresh wake.
    var out: [16]u8 = undefined;
    _ = buffer.consume(&out);
    wake_pending.store(false, .seq_cst);
    _ = try posix.write(fds[1], "again");
    try std.testing.expect(waitForCondition(bufferHasBytes, buffer, 2_000));
    try std.testing.expectEqual(@as(usize, 2), Wakes.count.load(.seq_cst));
}

test "PtyReader.retire prevents any further reads of the fd" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.create(allocator);
    defer buffer.destroy(allocator);

    const fds = try makeNonBlockingPipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var reader = PtyReader{};
    var stop = atomic.Value(bool).init(false);
    var wake_pending = atomic.Value(bool).init(false);

    const thread = try start(&reader, &stop, &wake_pending, null);
    defer {
        stop.store(true, .seq_cst);
        thread.join();
    }

    reader.register(fds[0], buffer);
    _ = try posix.write(fds[1], "before");
    try std.testing.expect(waitForCondition(bufferHasBytes, buffer, 2_000));
    var out: [32]u8 = undefined;
    _ = buffer.consume(&out);

    // After retire returns, bytes written to the still-open pipe must never
    // appear in the buffer.
    reader.retire(fds[0]);
    _ = try posix.write(fds[1], "after");
    std.Thread.sleep(300 * std.time.ns_per_ms);
    try std.testing.expect(!bufferHasBytes(buffer));
}
```

Note on `waitForCondition`: Zig comptime fn parameters cannot take `anytype` context that varies per call site cleanly across these three uses — if the compiler rejects the generic form, specialize it (`fn waitForBufferBytes(buffer: *PtyOutputBuffer, timeout_ms: u64) bool`) and inline the equivalent loop where other conditions are needed. Keep the 5 ms poll / bounded deadline shape.

- [ ] **Step 3: Run the tests**

Run: `nix develop -c zig build test`
Expected: PASS. If a thread test is flaky under load, raise its deadline to 5000 ms — never remove the bound.

- [ ] **Step 4: Format and commit**

```bash
zig fmt src/session/pty_reader.zig
git add src/session/pty_reader.zig
git commit -m "feat(session): add PTY reader thread with retire handshake"
```

---

### Task 3: `SessionState` consumes from the ring buffer

**Files:**
- Modify: `src/session/state.zig` (init ~line 162, ensureSpawnedWithDir ~line 197, teardown ~line 294, processOutput ~line 583, plus new fields near `output_buf` ~line 88)
- Test: in-file `test` blocks in `src/session/state.zig`

**Interfaces:**
- Consumes: `pty_reader_mod.PtyReader.register/retire`, `PtyOutputBuffer.create/destroy/consume/takePendingReadError/pumpFd` from Tasks 1–2.
- Produces: `SessionState.init(allocator, slot_index, shell_path, size, notify_sock, theme, reader: ?*pty_reader_mod.PtyReader)` — the new 7th parameter; `SessionState.pty_buffer: ?*pty_reader_mod.PtyOutputBuffer`. Task 4 passes the runtime's reader here.

- [ ] **Step 1: Add import and fields**

Near the top of `src/session/state.zig` (next to the `vt_stream` import):

```zig
const pty_reader_mod = @import("pty_reader.zig");
```

In the `SessionState` struct fields (near `output_buf: [65536]u8,` at line ~88):

```zig
    /// Reader thread this session registers its PTY with; null in unit
    /// tests that pump the buffer manually.
    pty_reader: ?*pty_reader_mod.PtyReader,
    /// Ring buffer the reader thread fills and processOutput consumes.
    /// Created on spawn, retired+destroyed on teardown.
    pty_buffer: ?*pty_reader_mod.PtyOutputBuffer,
```

- [ ] **Step 2: Extend `init` and update every caller**

Change the signature (line ~162):

```zig
    pub fn init(
        allocator: std.mem.Allocator,
        slot_index: usize,
        shell_path: []const u8,
        size: pty_mod.winsize,
        notify_sock: [:0]const u8,
        theme: colors_mod.Theme,
        reader: ?*pty_reader_mod.PtyReader,
    ) InitError!SessionState {
```

and add to the returned struct literal:

```zig
            .pty_reader = reader,
            .pty_buffer = null,
```

Find every caller and append the argument — `null` in all tests, the real reader in the runtime (done in Task 4):

Run: `rg -n "SessionState.init\(" src/`
Update each test call site in `src/session/state.zig` (lines ~1107, 1113, 1143, 1183, 1217, and any others the search reveals) to pass `null` as the last argument. `src/app/runtime.zig:1692` is updated in Task 4 — until then the build fails, which is expected mid-task; finish Step 3 and temporarily pass `null` at `runtime.zig:1692` so this task's commit compiles standalone (Task 4 replaces it with the real reader).

- [ ] **Step 3: Create/register the buffer on spawn, retire/destroy on teardown**

In `ensureSpawnedWithDir`, directly after `self.markDirty();` (line ~236, after `self.stream = stream;`):

```zig
        const buffer = try pty_reader_mod.PtyOutputBuffer.create(self.allocator);
        errdefer {
            if (self.pty_reader) |reader| reader.retire(shell.pty.master);
            buffer.destroy(self.allocator);
            self.pty_buffer = null;
        }
        self.pty_buffer = buffer;
        if (self.pty_reader) |reader| reader.register(shell.pty.master, buffer);
```

(`InitError` already contains `OutOfMemory` — `ghostty_vt.Terminal.init` requires it; verify with `rg -n "OutOfMemory" src/session/state.zig` and add it to `InitError` if it is somehow absent.)

In `teardown` (line ~294), insert BEFORE the `if (self.shell) |*shell| {` block (line ~335), so retire runs while the fd is still open and the buffer is freed only after the reader can no longer touch it:

```zig
        if (self.pty_buffer) |buffer| {
            if (self.pty_reader) |reader| {
                if (self.shell) |shell| reader.retire(shell.pty.master);
            }
            buffer.destroy(allocator);
            self.pty_buffer = null;
        }
```

- [ ] **Step 4: Rewrite `processOutput` to consume from the buffer**

Replace the body of `processOutput` (line ~583). The parse pipeline (scanOsc1Agent, quit capture, nextSlice, sync tracking, markDirty) is unchanged — only the byte source changes:

```zig
    pub fn processOutput(self: *SessionState) ProcessOutputError!void {
        if (!shouldProcessOutput(self.spawned, self.dead, self.quit_capture_active)) return;

        const buffer = self.pty_buffer orelse return;
        const stream = &(self.stream orelse return);

        var bytes_consumed: usize = 0;
        while (shouldContinueDraining(bytes_consumed, max_process_output_bytes_per_call)) {
            const read_len = cappedReadLen(self.output_buf.len, bytes_consumed, max_process_output_bytes_per_call);
            const n = buffer.consume(self.output_buf[0..read_len]);
            if (n == 0) {
                // Surface an unrecoverable reader-thread error only after
                // all buffered output has been parsed.
                if (buffer.takePendingReadError()) |err| return err;
                return;
            }
            bytes_consumed += n;

            if (scanOsc1Agent(self.output_buf[0..n])) |kind| {
                self.agent_icon = kind;
            }
            if (self.quit_capture_active) {
                self.quit_capture.appendSlice(self.allocator, self.output_buf[0..n]) catch |err| {
                    log.warn("session {d}: quit capture append failed: {}", .{ self.id, err });
                };
            }
            const was_synchronized_output = self.synchronizedOutputActive();
            try stream.nextSlice(self.output_buf[0..n]);
            const processed_at_ms = std.time.milliTimestamp();
            self.updateSynchronizedOutputState(was_synchronized_output, processed_at_ms);
            self.markDirty();
        }
    }
```

Also update the doc comment on `max_process_output_bytes_per_call` (line ~574): it now caps bytes *consumed from the ring* per call (the kernel-side draining happens on the reader thread); the "fast producer holds the frame loop hostage" rationale still applies to parsing cost.

`Shell.read` (src/shell.zig:1115) becomes unused by non-test code once this lands; keep it — the reader pumps via `posix.read` directly and tests still exercise `Shell` with pipes. If `zig build` flags it as dead, leave it `pub` (Zig does not warn on unused pub decls).

- [ ] **Step 5: Add the integration test**

Append to `src/session/state.zig` tests. This is the regression guard for the Junie bug: a full DEC-2026-wrapped frame delivered as many small producer writes must be consumable in ONE `processOutput` call, leaving the mode OFF (under the old fd-draining architecture the drain could end mid-window; with the buffer, everything the reader pumped is visible at once):

```zig
test "processOutput consumes a chunked 2026-wrapped frame from the ring buffer in one call" {
    const allocator = std.testing.allocator;

    const size = pty_mod.winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    var session = try SessionState.init(allocator, 0, "/bin/zsh", size, test_notify_sock, colors_mod.Theme.dark, null);
    defer session.deinit(allocator);

    const pipe_fds = try posix.pipe();
    // Make the read end non-blocking, as ensureSpawnedWithDir does for PTYs.
    const flags = try posix.fcntl(pipe_fds[0], posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(pipe_fds[0], posix.F.SETFL, @as(u32, @bitCast(o_flags)));

    session.shell = .{ .pty = .{ .master = pipe_fds[0], .slave = pipe_fds[1] }, .child_pid = 0 };
    session.terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 80, .rows = 24 });
    session.stream = vt_stream.initStream(allocator, &session.terminal.?, &session.shell.?);
    session.pty_buffer = try pty_reader_mod.PtyOutputBuffer.create(allocator);
    session.spawned = true;
    // teardown() must not signal pgrp 0; a dead session skips the kill.
    session.dead = true;
    session.quit_capture_active = true; // shouldProcessOutput allows dead sessions during capture

    // A JLine-style frame: sync begin, payload split into small writes, sync end.
    _ = try posix.write(pipe_fds[1], "\x1b[?2026h\x1b[H");
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        _ = try posix.write(pipe_fds[1], "chunk-of-a-frame ");
    }
    _ = try posix.write(pipe_fds[1], "\x1b[?2026l");

    // Reader-thread stand-in: pump everything the producer wrote.
    try std.testing.expectEqual(pty_reader_mod.PumpOutcome.progressed, session.pty_buffer.?.pumpFd(pipe_fds[0]));

    try session.processOutput();

    // The complete window was parsed: synchronized output is OFF.
    try std.testing.expect(!session.terminal.?.modes.get(.synchronized_output));
}
```

Check the existing tests for the exact `test_notify_sock`/theme values used by neighboring tests (e.g. the `checkAlive` test at line ~1120 constructs sessions the same way — mirror its boilerplate exactly, including whatever it uses for `notify_sock` and `theme`). `session.deinit` frees the buffer via teardown and closes both pipe fds via `shell.deinit`/`pty.deinit` — do NOT add `defer posix.close` for them (double-close). Verify `Pty.deinit` closes only `master` (src/pty.zig:105); if so, close the slave explicitly:

```zig
    defer posix.close(pipe_fds[1]);
```

placed BEFORE the `session.deinit` defer? No — defers run LIFO; declare it AFTER `session.deinit`'s defer so the slave closes first... Simplest correct ordering: declare `defer posix.close(pipe_fds[1]);` immediately after creating the pipe and before assigning `session.shell`, and let `pty.deinit` close only the master. LIFO then closes the slave (pipe write end) after teardown, which is harmless. Do not close `pipe_fds[0]` yourself — `pty.deinit` owns it.

- [ ] **Step 6: Run the full suite**

Run: `nix develop -c zig build test`
Expected: PASS. Existing sync-output tests (lines ~984–1093) construct terminals directly and are unaffected; existing spawn-based tests (`SessionState assigns incrementing ids`, `checkAlive ...`, `despawn ...`, `resetForRespawn ...`) now allocate and free a real ring buffer per spawn — `std.testing.allocator` will catch any leak in the new create/destroy pairing.

- [ ] **Step 7: Format and commit**

```bash
zig fmt src/session/state.zig src/app/runtime.zig
git add src/session/state.zig src/app/runtime.zig
git commit -m "feat(session): route PTY output through the reader ring buffer"
```

---

### Task 4: Runtime wiring — replace the watcher with the reader

**Files:**
- Modify: `src/app/runtime.zig:18` (import), `:1433-1435` (state vars), `:1563-1575` (thread start), `:1692` (SessionState.init call), `:2592-2600` (per-frame block)
- Delete: `src/session/pty_watcher.zig`
- Modify: `src/main.zig:53` (test registry: remove pty_watcher)

**Interfaces:**
- Consumes: `pty_reader.PtyReader`, `pty_reader.start`, `SessionState.init(..., reader)` from Tasks 2–3.
- Produces: nothing new — behavioral replacement.

- [ ] **Step 1: Swap the import and state variables**

`src/app/runtime.zig:18`:

```zig
const pty_reader = @import("../session/pty_reader.zig");
```

(replacing `const pty_watcher = @import("../session/pty_watcher.zig");`)

Lines 1433–1435: replace

```zig
    var pty_watcher_stop = std.atomic.Value(bool).init(false);
    var pty_wake_pending = std.atomic.Value(bool).init(false);
    var pty_watcher_state = pty_watcher.PtyWatcher{};
```

with

```zig
    var pty_reader_stop = std.atomic.Value(bool).init(false);
    var pty_wake_pending = std.atomic.Value(bool).init(false);
    var pty_reader_state = pty_reader.PtyReader{};
```

- [ ] **Step 2: Swap the thread start (lines 1563–1575)**

```zig
    const pty_reader_thread = try pty_reader.start(
        &pty_reader_state,
        &pty_reader_stop,
        &pty_wake_pending,
        .{
            .context = &sdl,
            .callback = platform.pushWakeEventFromOpaque,
        },
    );
    defer {
        pty_reader_stop.store(true, .seq_cst);
        pty_reader_thread.join();
    }
```

Thread lifetime note: this `defer` runs at `run()` exit, i.e. AFTER the quit-teardown/quit-capture code inside the main loop — the reader keeps pumping during quit capture, which `drainQuitCaptureOutput` (line ~1352) relies on. Sessions are deinited by their own `defer` (line ~1677), also declared before this one, so session teardown (which calls `retire`) runs while the reader thread is still alive — ordering is correct because `retire` only needs the registry mutex, not a live thread, and the thread must not outlive... verify the actual defer order: the sessions-deinit defer at line ~1677 was declared EARLIER than the thread-join defer at ~1572, and defers run LIFO, so the thread joins FIRST, then sessions deinit. Both orders are safe (retire on a joined thread's registry is just a mutex'd list removal), but confirm nothing between them closes an fd while the thread still runs without calling retire — with Task 3 in place, every fd close goes through `teardown`, which retires first.

- [ ] **Step 3: Pass the reader to sessions (line ~1692)**

```zig
        sessions_storage[i] = try SessionState.init(allocator, i, shell_path, size, notify_sock, theme, &pty_reader_state);
```

(If Task 3 left a temporary `null` here, this replaces it.)

- [ ] **Step 4: Remove the per-frame fd refresh (lines 2592–2600)**

Replace

```zig
        pty_wake_pending.store(false, .seq_cst);
        var pty_fds: [grid_layout.max_terminals]posix.fd_t = undefined;
        var pty_fd_count: usize = 0;
        for (sessions) |session| {
            const pty_fd = session.ptyMasterFd() orelse continue;
            pty_fds[pty_fd_count] = pty_fd;
            pty_fd_count += 1;
        }
        pty_watcher_state.updateFds(pty_fds[0..pty_fd_count]);
```

with just

```zig
        pty_wake_pending.store(false, .seq_cst);
```

Then check whether `SessionState.ptyMasterFd` (src/session/state.zig:769) has any remaining callers (`rg -n "ptyMasterFd" src/`); if this was the only one, delete the function.

- [ ] **Step 5: Delete the watcher**

```bash
git rm src/session/pty_watcher.zig
```

Remove `_ = @import("session/pty_watcher.zig");` from `src/main.zig`. Search for stragglers: `rg -n "pty_watcher" src/ scripts/` must return nothing.

- [ ] **Step 6: Build, test, lint**

Run: `nix develop -c zig build`
Expected: clean build.

Run: `nix develop -c zig build test`
Expected: PASS.

Run: `nix develop -c just lint`
Expected: PASS (includes `scripts/check-test-registry.sh`, which verifies the registry edits).

- [ ] **Step 7: Format and commit**

```bash
zig fmt src/app/runtime.zig src/main.zig
git add -A
git commit -m "feat(runtime): drain PTYs on a dedicated reader thread"
```

---

### Task 5: Documentation, validation, and manual verification

**Files:**
- Modify: `docs/ARCHITECTURE.md` (overview line ~5, diagram nodes ~29–31, threads paragraph ~94, frame-loop diagram ~183–187, module table rows ~413–415)
- Modify: `docs/perf-debugging.md` (new subsection)
- Test: manual verification procedure below

- [ ] **Step 1: Update `docs/ARCHITECTURE.md`**

- Overview paragraph (line ~5): replace "a PTY-readability watcher" with "a PTY reader thread that drains session output into per-session ring buffers at wire speed".
- Diagram node (line ~31): `PW["session/pty_reader.zig<br/><i>Background PTY reader thread (poll + ring buffers)</i>"]`.
- Threads paragraph (line ~94): rewrite the PTY-watcher sentences to describe the new model. Replace the stale mention of `updateFds`/per-frame fd refresh and the `wake_pending` back-off with:

> The PTY reader (`session/pty_reader.zig`) polls the master fds of all spawned sessions with a ~100ms timeout and, when one becomes readable, drains it into that session's mutex-guarded ring buffer (`PtyOutputBuffer`, 1 MiB) — so producer processes are never backpressured by render pacing, and DEC-2026 sync windows close in the buffer as fast as the producer writes them. Sessions register their fd+buffer on spawn and retire it during teardown; reads happen only under the registry mutex, so `retire()` returning guarantees the reader can no longer touch the fd or buffer. The main thread's `processOutput` consumes from the buffer (VT parsing stays main-thread-only) and clears a shared `wake_pending` flag at the top of each frame; the reader posts at most one SDL wake event per frame via that flag.

- Module table (line ~413): update the `session/state.zig` row's summary (remove the stale `drainOutputForMs()` mention while there — the function no longer exists) and replace the `session/pty_watcher.zig` row with:

> | `session/pty_reader.zig` | Background thread that `poll(2)`s spawned sessions' PTY master fds and drains readable ones into per-session SPSC ring buffers; registry with retire handshake so teardown can safely close fds | `PtyReader`, `PtyOutputBuffer`, `start()`, `register()`, `retire()` | std (poll, thread) |

- Frame-loop diagram (lines ~183–187): replace "Refresh PTY watcher fd list," with "Clear PTY wake flag," (the fd list refresh no longer exists).

- [ ] **Step 2: Add the lesson to `docs/perf-debugging.md`**

Append a subsection after "Codex resize behavior":

```markdown
## Chatty small-write producers (JVM/JLine TUIs)

JLine-based TUIs (e.g. Junie CLI) repaint the full screen every frame inside
a DEC-2026 window (`ESC[?2026h … ESC[?2026l`) as ~150 small (~190-byte)
write() syscalls, up to ~19fps. Before the dedicated PTY reader thread
(2026-08), the frame-paced drain stopped at the first EWOULDBLOCK, so drain
boundaries landed mid-window ~97% of the time: the renderer's sync hold
suppressed nearly every repaint (2–9 effective fps), the kernel PTY buffer
backed up, and the producer's writes blocked 250–800 ms per frame — the
user-visible ~1s/keypress lag. Diagnostics that pinned it: the producer's
own write-latency telemetry (`[tui-perf] write p95` in ~/.junie/logs), a
PTY harness capturing chunk sizes and 2026 markers per read, and per-read
DRAIN/SYNC-HOLD debug logging in an isolated instance. Key control: with
the window occluded (rendering suppressed) the old drain kept up and writes
took 2 ms — proof the drain was render-paced, not slow. Producers that
write whole frames in one syscall (codex, claude) never exhibited this.
```

- [ ] **Step 3: Full validation**

Run each, bare, checking exit codes:

```bash
nix develop -c zig build
nix develop -c zig build test
nix develop -c just lint
zig fmt --check src/
```

Expected: all PASS.

- [ ] **Step 4: Manual verification with Junie (the original repro)**

Per `docs/perf-debugging.md`: launch an isolated instance and spawn Junie in it:

```bash
mkdir -p /tmp/arch-jn/.config/architect
printf '[window]\nx = 60\ny = 60\nwidth = 1920\nheight = 1080\n' > /tmp/arch-jn/.config/architect/persistence.toml
nix develop -c zig build -Doptimize=ReleaseFast
HOME=/tmp/arch-jn ./zig-out/bin/architect &
sleep 3
PID=$(pgrep -f zig-out/bin/architect | head -1)
printf '{"cwd": "%s", "command": "HOME=%s junie", "display_name": "junie-verify"}\n' "$PWD" "$REAL_HOME" \
  | nc -U -w 2 /tmp/arch-jn/Library/Caches/Architect/runtime/architect_control_${PID}.sock
```

Keep the window visible/frontmost (an occluded window suppresses rendering and hides the regression). Wait ~90 s so Junie's TuiPerfMonitor emits a report, then check the newest Junie log:

```bash
rg -I "tui-perf|tui-slow-frame" "$(ls -t ~/.junie/logs/log-*.log | head -1)"
```

Acceptance: `write p95` ≤ 16 ms and zero `[tui-slow-frame]` lines after startup (pre-fix baseline: `write p95=512–1024ms`, slow frames of 500–800 ms). Optionally type into the Junie session and confirm keystrokes echo instantly. Kill the instance and `rm -rf /tmp/arch-jn` afterwards.

- [ ] **Step 5: Commit docs**

```bash
git add docs/ARCHITECTURE.md docs/perf-debugging.md
git commit -m "docs: describe the PTY reader thread and JLine drain lesson"
```

---

## Explicitly out of scope (YAGNI)

- No changes to `synchronizedOutputHoldsCache` or the expiry constants (`synchronized_output_timeout_ms` etc.) — with wire-speed reads they revert to being a rarely-hit safety net. Revisit only if manual verification still shows holds.
- No renderer changes.
- No upstream JLine/Junie fix (single-write frame flushing) — worth filing separately, out of this plan.
- No lock-free SPSC ring — the mutex-guarded version's critical sections are bounded memcpys; contention is negligible at these rates.

## Self-review notes

- Spec coverage: root cause = frame-paced, EWOULDBLOCK-terminated drains → Task 1–3 move draining to a thread + ring; backpressure → 1 MiB buffer + wire-speed pump; 2026 holds → windows now close in-buffer (regression test in Task 3, acceptance test in Task 5); fd-lifetime safety (the reason the old declarative `updateFds` model could not simply gain reads) → retire handshake in Task 2, teardown ordering in Task 3.
- Type consistency: `PtyOutputBuffer.create/createWithCapacity/destroy/pumpFd/consume/takePendingReadError/canAcceptBytes`, `PumpOutcome.{progressed,idle,full,closed}`, `PtyReader.register/retire`, `pty_reader.start(reader, stop, wake_pending, runtime_wake)` — used with these exact names in Tasks 2–4.
- Known mid-plan build break: Task 3 changes `SessionState.init` arity before Task 4 wires the runtime; Task 3 Step 2 patches `runtime.zig:1692` with a temporary `null` so its commit builds green.
