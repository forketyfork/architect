const std = @import("std");
const posix = std.posix;
const atomic = std.atomic;
const grid_layout = @import("../app/grid_layout.zig");

const log = std.log.scoped(.pty_reader);

const poll_timeout_ms: i32 = 100;
const full_buffer_retry_ns: u64 = 2 * std.time.ns_per_ms;
const poll_error_backoff_ns: u64 = 10 * std.time.ns_per_ms;

/// Bytes buffered per session between the reader thread and the main
/// thread. This absorbs producer bursts without making VT parsing
/// unbounded on the main thread.
pub const buffer_capacity: usize = 1 << 20;

pub const RuntimeWake = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,

    pub fn notify(self: RuntimeWake) void {
        self.callback(self.context);
    }
};

pub const PumpOutcome = enum {
    progressed,
    idle,
    full,
    closed,
};

/// Single-producer (reader thread) / single-consumer (main thread) byte
/// ring. Every field is guarded by `mutex`. Both sides hold the mutex only
/// for bounded, non-blocking work: the producer reads an O_NONBLOCK fd into
/// free ring space, and the consumer copies bytes out.
pub const PtyOutputBuffer = struct {
    const PollState = enum {
        ready,
        full,
        closed,
    };

    mutex: std.Thread.Mutex = .{},
    data: []u8,
    head: usize = 0,
    len: usize = 0,
    eof: bool = false,
    read_error: ?posix.ReadError = null,

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*PtyOutputBuffer {
        return createWithCapacity(allocator, buffer_capacity);
    }

    pub fn createWithCapacity(
        allocator: std.mem.Allocator,
        capacity: usize,
    ) error{OutOfMemory}!*PtyOutputBuffer {
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

    /// Reader-thread side: drain `fd` into free ring space until the fd
    /// would block, the ring fills, or the fd closes/fails.
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

    /// Main-thread side: copy up to `dest.len` buffered bytes out, in order.
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
        if (self.len == 0) self.head = 0;
        return copied;
    }

    /// Surface the first unrecoverable read error once all buffered bytes are
    /// drained, so output preceding the failure is not lost.
    pub fn takePendingReadError(self: *PtyOutputBuffer) ?posix.ReadError {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len > 0) return null;
        const err = self.read_error orelse return null;
        self.read_error = null;
        return err;
    }

    pub fn canAcceptBytes(self: *PtyOutputBuffer) bool {
        return self.pollState() == .ready;
    }

    fn pollState(self: *PtyOutputBuffer) PollState {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.eof or self.read_error != null) return .closed;
        if (self.len == self.data.len) return .full;
        return .ready;
    }

    fn contiguousFreeSlice(self: *PtyOutputBuffer) []u8 {
        std.debug.assert(self.len < self.data.len);
        const tail = (self.head + self.len) % self.data.len;
        if (tail < self.head) return self.data[tail..self.head];
        return self.data[tail..];
    }
};

const Entry = struct {
    fd: posix.fd_t,
    buffer: *PtyOutputBuffer,
};

const PollSnapshot = struct {
    count: usize,
    has_full_buffer: bool,
};

const wake_worthy_events: i16 = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;

fn isWakeWorthy(revents: i16) bool {
    return (revents & wake_worthy_events) != 0;
}

/// Registry of PTY master fds drained into per-session ring buffers. Every
/// read of a registered fd happens while `mutex` is held, so `retire`
/// returning guarantees the reader can no longer touch the fd or buffer.
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

    /// Snapshot pollable fds and report whether a zero-length snapshot was
    /// caused by full buffers. Closed buffers do not need a short retry.
    fn snapshotPollfds(
        self: *PtyReader,
        out: *[grid_layout.max_terminals]posix.pollfd,
    ) PollSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var has_full_buffer = false;
        for (self.entries[0..self.entry_count]) |entry| {
            switch (entry.buffer.pollState()) {
                .ready => {
                    out[count] = .{ .fd = entry.fd, .events = posix.POLL.IN, .revents = 0 };
                    count += 1;
                },
                .full => has_full_buffer = true,
                .closed => {},
            }
        }
        return .{ .count = count, .has_full_buffer = has_full_buffer };
    }

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
        const snapshot = ctx.reader.snapshotPollfds(&pollfds);
        if (snapshot.count == 0) {
            const retry_ns = if (snapshot.has_full_buffer)
                full_buffer_retry_ns
            else
                @as(u64, @intCast(poll_timeout_ms)) * std.time.ns_per_ms;
            std.Thread.sleep(retry_ns);
            continue;
        }

        const ready = posix.poll(pollfds[0..snapshot.count], poll_timeout_ms) catch |err| {
            log.debug("poll failed: {}", .{err});
            std.Thread.sleep(poll_error_backoff_ns);
            continue;
        };
        if (ready == 0) continue;

        if (ctx.reader.pumpReadyFds(pollfds[0..snapshot.count])) {
            if (!ctx.wake_pending.swap(true, .seq_cst)) {
                if (ctx.runtime_wake) |waker| waker.notify();
            }
        }
    }
}

fn makeNonBlockingPipe() ![2]posix.fd_t {
    const fds = try posix.pipe();
    const flags = try posix.fcntl(fds[0], posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fds[0], posix.F.SETFL, @as(u32, @bitCast(o_flags)));
    return fds;
}

fn waitForBufferBytes(buffer: *PtyOutputBuffer, timeout_ms: u64) bool {
    var waited_ms: u64 = 0;
    while (waited_ms < timeout_ms) : (waited_ms += 5) {
        if (bufferHasBytes(buffer)) return true;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return bufferHasBytes(buffer);
}

fn bufferHasBytes(buffer: *PtyOutputBuffer) bool {
    buffer.mutex.lock();
    defer buffer.mutex.unlock();
    return buffer.len > 0;
}

fn incrementWakeCount(context: ?*anyopaque) void {
    const count: *atomic.Value(usize) = @ptrCast(@alignCast(context.?));
    _ = count.fetchAdd(1, .seq_cst);
}

test "isWakeWorthy fires for readable, hangup, error, and invalid fds" {
    try std.testing.expect(isWakeWorthy(posix.POLL.IN));
    try std.testing.expect(isWakeWorthy(posix.POLL.HUP));
    try std.testing.expect(isWakeWorthy(posix.POLL.ERR));
    try std.testing.expect(isWakeWorthy(posix.POLL.NVAL));
    try std.testing.expect(!isWakeWorthy(posix.POLL.OUT));
    try std.testing.expect(!isWakeWorthy(0));
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

    {
        buffer.mutex.lock();
        defer buffer.mutex.unlock();
        buffer.read_error = error.NotOpenForReading;
    }

    try std.testing.expectEqual(@as(?posix.ReadError, null), buffer.takePendingReadError());
    var out: [8]u8 = undefined;
    _ = buffer.consume(&out);
    try std.testing.expectEqual(@as(?posix.ReadError, error.NotOpenForReading), buffer.takePendingReadError());
    try std.testing.expectEqual(@as(?posix.ReadError, null), buffer.takePendingReadError());
}

test "PtyReader register/retire updates the poll snapshot" {
    const allocator = std.testing.allocator;
    const buffer = try PtyOutputBuffer.createWithCapacity(allocator, 16);
    defer buffer.destroy(allocator);

    var reader = PtyReader{};
    reader.register(7, buffer);
    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;
    try std.testing.expectEqual(@as(usize, 1), reader.snapshotPollfds(&pollfds).count);
    try std.testing.expectEqual(@as(posix.fd_t, 7), pollfds[0].fd);

    reader.retire(7);
    try std.testing.expectEqual(@as(usize, 0), reader.snapshotPollfds(&pollfds).count);
}

test "PtyReader snapshot distinguishes full and closed buffers" {
    const allocator = std.testing.allocator;
    const full_buffer = try PtyOutputBuffer.createWithCapacity(allocator, 4);
    defer full_buffer.destroy(allocator);
    const closed_buffer = try PtyOutputBuffer.createWithCapacity(allocator, 4);
    defer closed_buffer.destroy(allocator);

    full_buffer.mutex.lock();
    full_buffer.len = full_buffer.data.len;
    full_buffer.mutex.unlock();
    closed_buffer.mutex.lock();
    closed_buffer.eof = true;
    closed_buffer.mutex.unlock();

    var reader = PtyReader{};
    reader.register(7, full_buffer);
    reader.register(8, closed_buffer);
    var pollfds: [grid_layout.max_terminals]posix.pollfd = undefined;

    var snapshot = reader.snapshotPollfds(&pollfds);
    try std.testing.expectEqual(@as(usize, 0), snapshot.count);
    try std.testing.expect(snapshot.has_full_buffer);

    var drain: [1]u8 = undefined;
    _ = full_buffer.consume(&drain);
    snapshot = reader.snapshotPollfds(&pollfds);
    try std.testing.expectEqual(@as(usize, 1), snapshot.count);
    try std.testing.expect(!snapshot.has_full_buffer);
    try std.testing.expectEqual(@as(posix.fd_t, 7), pollfds[0].fd);
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
    var wake_count = atomic.Value(usize).init(0);

    const thread = try start(&reader, &stop, &wake_pending, .{
        .context = &wake_count,
        .callback = incrementWakeCount,
    });
    defer {
        stop.store(true, .seq_cst);
        thread.join();
    }

    reader.register(fds[0], buffer);
    _ = try posix.write(fds[1], "ping");

    try std.testing.expect(waitForBufferBytes(buffer, 2_000));
    try std.testing.expect(wake_pending.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), wake_count.load(.seq_cst));

    _ = try posix.write(fds[1], "pong");
    std.Thread.sleep(300 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), wake_count.load(.seq_cst));

    var out: [16]u8 = undefined;
    _ = buffer.consume(&out);
    wake_pending.store(false, .seq_cst);
    _ = try posix.write(fds[1], "again");
    try std.testing.expect(waitForBufferBytes(buffer, 2_000));
    try std.testing.expectEqual(@as(usize, 2), wake_count.load(.seq_cst));
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
    try std.testing.expect(waitForBufferBytes(buffer, 2_000));
    var out: [32]u8 = undefined;
    _ = buffer.consume(&out);

    reader.retire(fds[0]);
    _ = try posix.write(fds[1], "after");
    std.Thread.sleep(300 * std.time.ns_per_ms);
    try std.testing.expect(!bufferHasBytes(buffer));
}
