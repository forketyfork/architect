//! In-app MCP server with the legacy SSE (Server-Sent Events) transport.
//!
//! Listens on a localhost TCP port. Two endpoints:
//!
//!   GET  /sse                          → opens a `text/event-stream` and
//!                                        immediately publishes an `endpoint`
//!                                        event whose data is the URL the
//!                                        client should POST JSON-RPC requests
//!                                        to (carrying a session id).
//!   POST /messages?session_id=<id>     → JSON-RPC request body. Server
//!                                        responds 202 Accepted; the actual
//!                                        JSON-RPC response is delivered as a
//!                                        `message` SSE event on the GET
//!                                        stream associated with the session.
//!
//! Spawns one thread per accepted connection. The `tools/call spawn_session`
//! flow enqueues onto the runtime spawn queue and waits for the main loop to
//! complete it, exactly like the Unix-socket control path used by the
//! standalone `architect-mcp` helper.
const std = @import("std");
const posix = std.posix;
const atomic = std.atomic;
const handler = @import("mcp-handler");
const control = @import("control");

const log = std.log.scoped(.mcp_sse);

pub const default_host = "127.0.0.1";
pub const default_port: u16 = 39813;

const accept_idle_ns: u64 = std.time.ns_per_ms * 50;
const session_poll_ms: i32 = 250;
const max_request_bytes: usize = 64 * 1024;
const max_body_bytes: usize = 1 * 1024 * 1024;
const sse_endpoint_path = "/sse";
const messages_endpoint_path = "/messages";

pub const Options = struct {
    host: []const u8 = default_host,
    port: u16 = default_port,
};

const Session = struct {
    id: u64,
    fd: posix.fd_t,
    write_mutex: std.Thread.Mutex = .{},
    closed: bool = false,
};

const Worker = struct {
    server: *Server,
    fd: posix.fd_t,
    thread: std.Thread = undefined,
    done: atomic.Value(bool) = atomic.Value(bool).init(false),
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    queue: *control.SpawnQueue,
    runtime_wake: ?control.RuntimeWake,

    listener_fd: posix.fd_t,
    bound_port: u16,

    stop_flag: atomic.Value(bool) = atomic.Value(bool).init(false),

    mutex: std.Thread.Mutex = .{},
    sessions: std.AutoHashMap(u64, *Session),
    workers: std.ArrayListUnmanaged(*Worker) = .empty,
    next_session_id: atomic.Value(u64) = atomic.Value(u64).init(1),

    acceptor: ?std.Thread = null,

    pub fn start(
        allocator: std.mem.Allocator,
        queue: *control.SpawnQueue,
        runtime_wake: ?control.RuntimeWake,
        options: Options,
    ) !*Server {
        const listener_fd, const bound_port = try createListener(options);
        errdefer posix.close(listener_fd);

        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .queue = queue,
            .runtime_wake = runtime_wake,
            .listener_fd = listener_fd,
            .bound_port = bound_port,
            .sessions = std.AutoHashMap(u64, *Session).init(allocator),
        };

        self.acceptor = try std.Thread.spawn(.{}, acceptorMain, .{self});
        log.info("MCP SSE server listening on {s}:{d}", .{ options.host, bound_port });
        return self;
    }

    pub fn stopAndJoin(self: *Server) void {
        self.stop_flag.store(true, .seq_cst);

        // Wake the acceptor by shutting down its listener.
        posix.shutdown(self.listener_fd, .both) catch {};

        // Wake every active GET /sse worker by shutting down its socket.
        self.mutex.lock();
        var iter = self.sessions.valueIterator();
        while (iter.next()) |sess_ptr| {
            const sess = sess_ptr.*;
            sess.write_mutex.lock();
            if (!sess.closed) {
                posix.shutdown(sess.fd, .both) catch {};
            }
            sess.write_mutex.unlock();
        }
        self.mutex.unlock();

        if (self.acceptor) |t| {
            t.join();
            self.acceptor = null;
        }

        // Acceptor is gone, so no new POST workers will be spawned. Any
        // already-running POST worker may still be blocked in
        // `completion.wait` for the runtime to drain its spawn request. Fail
        // every pending entry in the shared queue so those workers unblock.
        control.failPending(self.queue, self.allocator, .app_not_running, "Architect is shutting down");

        // Drain and join all remaining workers.
        self.mutex.lock();
        var drained = self.workers;
        self.workers = .empty;
        self.mutex.unlock();

        for (drained.items) |w| {
            w.thread.join();
            self.allocator.destroy(w);
        }
        drained.deinit(self.allocator);

        // Free remaining sessions.
        var sess_iter = self.sessions.valueIterator();
        while (sess_iter.next()) |sess_ptr| {
            self.allocator.destroy(sess_ptr.*);
        }
        self.sessions.deinit();

        posix.close(self.listener_fd);
        self.allocator.destroy(self);
    }
};

fn createListener(options: Options) !struct { posix.fd_t, u16 } {
    const address = try std.net.Address.parseIp(options.host, options.port);
    const net_server = try address.listen(.{ .reuse_address = true });
    // Detach the fd from std.net.Server so we own it and can close it on
    // shutdown without going through the higher-level wrapper.
    const fd = net_server.stream.handle;
    const bound_port = net_server.listen_address.getPort();
    setFdNonBlocking(fd, "MCP SSE listener");
    return .{ fd, bound_port };
}

fn setFdNonBlocking(fd: posix.fd_t, context: []const u8) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| {
        log.warn("failed to get {s} flags: {}", .{ context, err });
        return;
    };
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    if (posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
        log.warn("failed to set {s} non-blocking: {}", .{ context, err });
    }
}

fn setFdBlocking(fd: posix.fd_t, context: []const u8) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| {
        log.warn("failed to get {s} flags: {}", .{ context, err });
        return;
    };
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = false;
    if (posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)))) |_| {} else |err| {
        log.warn("failed to set {s} blocking: {}", .{ context, err });
    }
}

fn acceptorMain(server: *Server) void {
    while (!server.stop_flag.load(.seq_cst)) {
        reapFinishedWorkers(server);

        const conn_fd = posix.accept(server.listener_fd, null, null, 0) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(accept_idle_ns);
                continue;
            },
            else => {
                if (server.stop_flag.load(.seq_cst)) break;
                log.debug("MCP SSE accept error: {}", .{err});
                continue;
            },
        };

        // Per-connection workers use blocking I/O so reads/writes are
        // straightforward; the acceptor stays non-blocking to observe stop.
        setFdBlocking(conn_fd, "MCP SSE connection");

        const worker = server.allocator.create(Worker) catch |err| {
            log.warn("failed to allocate MCP SSE worker: {}", .{err});
            posix.close(conn_fd);
            continue;
        };
        worker.* = .{ .server = server, .fd = conn_fd };

        worker.thread = std.Thread.spawn(.{}, workerMain, .{worker}) catch |err| {
            log.warn("failed to spawn MCP SSE worker: {}", .{err});
            server.allocator.destroy(worker);
            posix.close(conn_fd);
            continue;
        };

        server.mutex.lock();
        server.workers.append(server.allocator, worker) catch |err| {
            log.warn("failed to track MCP SSE worker: {}", .{err});
        };
        server.mutex.unlock();
    }
}

fn reapFinishedWorkers(server: *Server) void {
    server.mutex.lock();
    var i: usize = 0;
    while (i < server.workers.items.len) {
        const w = server.workers.items[i];
        if (w.done.load(.seq_cst)) {
            _ = server.workers.swapRemove(i);
            server.mutex.unlock();
            w.thread.join();
            server.allocator.destroy(w);
            server.mutex.lock();
            continue;
        }
        i += 1;
    }
    server.mutex.unlock();
}

fn workerMain(worker: *Worker) void {
    defer worker.done.store(true, .seq_cst);
    defer posix.close(worker.fd);
    handleConnection(worker) catch |err| {
        log.debug("MCP SSE connection error: {}", .{err});
    };
}

const Method = enum { get, post, other };

const Request = struct {
    method: Method,
    path: []const u8,
    query: []const u8,
    content_length: usize,
};

const HeadersRead = struct {
    headers_len: usize,
    total_len: usize,
};

fn handleConnection(worker: *Worker) !void {
    var arena_state = std.heap.ArenaAllocator.init(worker.server.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var header_buf: [max_request_bytes]u8 = undefined;
    const head = try readHeaders(worker.fd, &header_buf);
    const headers_bytes = header_buf[0..head.headers_len];
    const early_body = header_buf[head.headers_len..head.total_len];

    const request = parseRequest(headers_bytes) catch {
        try writeStatus(worker.fd, 400, "Bad Request");
        return;
    };

    switch (request.method) {
        .get => {
            if (std.mem.eql(u8, request.path, sse_endpoint_path)) {
                try handleSseGet(worker, arena);
                return;
            }
            try writeStatus(worker.fd, 404, "Not Found");
        },
        .post => {
            if (std.mem.eql(u8, request.path, messages_endpoint_path)) {
                try handleMessagesPost(worker, arena, request, early_body);
                return;
            }
            try writeStatus(worker.fd, 404, "Not Found");
        },
        .other => try writeStatus(worker.fd, 405, "Method Not Allowed"),
    }
}

fn readHeaders(fd: posix.fd_t, buf: []u8) !HeadersRead {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try posix.read(fd, buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
            return .{ .headers_len = idx + 4, .total_len = total };
        }
    }
    return error.HeadersTooLarge;
}

fn parseRequest(headers_bytes: []const u8) !Request {
    var line_iter = std.mem.splitSequence(u8, headers_bytes, "\r\n");
    const request_line = line_iter.next() orelse return error.InvalidRequest;

    var rl_iter = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = rl_iter.next() orelse return error.InvalidRequest;
    const target = rl_iter.next() orelse return error.InvalidRequest;
    _ = rl_iter.next() orelse return error.InvalidRequest;

    const method: Method = if (std.mem.eql(u8, method_str, "GET"))
        .get
    else if (std.mem.eql(u8, method_str, "POST"))
        .post
    else
        .other;

    const q_idx = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q_idx) |i| target[0..i] else target;
    const query = if (q_idx) |i| target[i + 1 ..] else "";

    var content_length: usize = 0;
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidRequest;
            if (content_length > max_body_bytes) return error.InvalidRequest;
        }
    }

    return .{
        .method = method,
        .path = path,
        .query = query,
        .content_length = content_length,
    };
}

fn handleSseGet(worker: *Worker, arena: std.mem.Allocator) !void {
    const session = try worker.server.allocator.create(Session);
    var session_registered = false;
    errdefer if (!session_registered) worker.server.allocator.destroy(session);

    const session_id = worker.server.next_session_id.fetchAdd(1, .seq_cst);
    session.* = .{ .id = session_id, .fd = worker.fd };

    {
        worker.server.mutex.lock();
        defer worker.server.mutex.unlock();
        try worker.server.sessions.put(session_id, session);
        session_registered = true;
    }

    defer {
        // Pull the session out of the map under the server mutex so concurrent
        // POST handlers stop finding it. Then mark it closed under the
        // session mutex so any in-flight POST that already grabbed the session
        // pointer is forced to skip its write.
        worker.server.mutex.lock();
        _ = worker.server.sessions.remove(session_id);
        worker.server.mutex.unlock();

        session.write_mutex.lock();
        session.closed = true;
        session.write_mutex.unlock();
        worker.server.allocator.destroy(session);
        // The fd is closed by workerMain's `defer posix.close(worker.fd)`.
    }

    const sse_headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "\r\n";
    try writeAll(worker.fd, sse_headers);

    const endpoint_url = try std.fmt.allocPrint(
        arena,
        "{s}?session_id={d}",
        .{ messages_endpoint_path, session_id },
    );
    {
        session.write_mutex.lock();
        defer session.write_mutex.unlock();
        try writeSseEvent(worker.fd, "endpoint", endpoint_url);
    }

    // Hold the connection open until the client disconnects or we are asked
    // to stop. We do not expect data from the client on this stream.
    while (!worker.server.stop_flag.load(.seq_cst)) {
        var fds = [_]posix.pollfd{.{ .fd = worker.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, session_poll_ms) catch |err| {
            log.debug("MCP SSE poll error: {}", .{err});
            return;
        };
        if (ready == 0) continue;

        var discard: [256]u8 = undefined;
        const n = posix.read(worker.fd, &discard) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return,
        };
        if (n == 0) return; // client closed
    }
}

fn handleMessagesPost(
    worker: *Worker,
    arena: std.mem.Allocator,
    request: Request,
    early_body: []const u8,
) !void {
    const session_id = parseSessionId(request.query) catch {
        try writeStatus(worker.fd, 400, "Bad Request");
        return;
    };

    if (request.content_length == 0 or request.content_length > max_body_bytes) {
        try writeStatus(worker.fd, 411, "Length Required");
        return;
    }

    const body = try arena.alloc(u8, request.content_length);
    var have: usize = @min(early_body.len, body.len);
    if (have > 0) @memcpy(body[0..have], early_body[0..have]);
    while (have < body.len) {
        const n = try posix.read(worker.fd, body[have..]);
        if (n == 0) return error.ConnectionClosed;
        have += n;
    }

    var spawn_ctx = AppSpawnContext{
        .allocator = worker.server.allocator,
        .queue = worker.server.queue,
        .runtime_wake = worker.server.runtime_wake,
    };
    const spawner: handler.Spawner = .{
        .context = @ptrCast(&spawn_ctx),
        .callback = appSpawn,
    };

    const maybe_response = handler.handleMessage(arena, body, spawner) catch |err| {
        log.warn("MCP SSE handleMessage failed: {}", .{err});
        try writeStatus(worker.fd, 500, "Internal Server Error");
        return;
    };

    try writeStatus(worker.fd, 202, "Accepted");

    if (maybe_response) |response_bytes| {
        // The handler returned bytes from `arena`, so no manual free is needed.
        worker.server.mutex.lock();
        const session_opt = worker.server.sessions.get(session_id);
        if (session_opt) |sess| sess.write_mutex.lock();
        worker.server.mutex.unlock();

        if (session_opt) |sess| {
            defer sess.write_mutex.unlock();
            if (!sess.closed) {
                writeSseEvent(sess.fd, "message", response_bytes) catch |err| {
                    log.debug("MCP SSE write error: {}", .{err});
                };
            }
        }
    }
}

fn parseSessionId(query: []const u8) !u64 {
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], "session_id")) {
            return try std.fmt.parseInt(u64, kv[eq + 1 ..], 10);
        }
    }
    return error.MissingSessionId;
}

const AppSpawnContext = struct {
    allocator: std.mem.Allocator,
    queue: *control.SpawnQueue,
    runtime_wake: ?control.RuntimeWake,
};

fn appSpawn(
    ctx_opaque: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: control.SpawnRequest,
) anyerror!control.OwnedSpawnResponse {
    const ctx: *AppSpawnContext = @ptrCast(@alignCast(ctx_opaque.?));

    // The runtime takes ownership of the queued request and deinits it after
    // dispatch, so we hand it a deep copy made with the runtime's allocator.
    const cloned = try cloneRequest(ctx.allocator, request);
    var queued_ok = false;
    errdefer if (!queued_ok) cleanupCloned(ctx.allocator, cloned);

    var completion = control.SpawnCompletion{};
    try ctx.queue.push(ctx.allocator, .{
        .request = cloned,
        .completion = &completion,
    });
    queued_ok = true;

    if (ctx.runtime_wake) |wake| wake.notify();

    const response = completion.wait();
    return wrapResponse(allocator, response);
}

fn cloneRequest(allocator: std.mem.Allocator, request: control.SpawnRequest) !control.SpawnRequest {
    var cloned = control.SpawnRequest{
        .cwd = try allocator.dupe(u8, request.cwd),
        .command = null,
        .display_name = null,
    };
    errdefer allocator.free(cloned.cwd);
    if (request.command) |cmd| {
        cloned.command = try allocator.dupe(u8, cmd);
    }
    errdefer if (cloned.command) |c| allocator.free(c);
    if (request.display_name) |name| {
        cloned.display_name = try allocator.dupe(u8, name);
    }
    return cloned;
}

fn cleanupCloned(allocator: std.mem.Allocator, request: control.SpawnRequest) void {
    allocator.free(request.cwd);
    if (request.command) |c| allocator.free(c);
    if (request.display_name) |n| allocator.free(n);
}

fn wrapResponse(
    allocator: std.mem.Allocator,
    response: control.SpawnResponse,
) !control.OwnedSpawnResponse {
    return switch (response) {
        .success => .{ .response = .{ .success = response.success } },
        .failure => |failure| blk: {
            const msg = try allocator.dupe(u8, failure.message);
            break :blk .{
                .response = .{ .failure = .{ .code = failure.code, .message = msg } },
                .owned_message = msg,
            };
        },
    };
}

fn writeStatus(fd: posix.fd_t, code: u16, reason: []const u8) !void {
    var buf: [256]u8 = undefined;
    const headers = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{ code, reason },
    );
    try writeAll(fd, headers);
}

fn writeSseEvent(fd: posix.fd_t, event: []const u8, data: []const u8) !void {
    var header_buf: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "event: {s}\ndata: ", .{event});
    try writeAll(fd, header);
    var start: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') {
            try writeAll(fd, data[start..i]);
            try writeAll(fd, "\ndata: ");
            start = i + 1;
        }
    }
    if (start < data.len) try writeAll(fd, data[start..]);
    try writeAll(fd, "\n\n");
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try posix.write(fd, bytes[written..]);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}

test "parseRequest extracts method, path, query, and content-length" {
    const headers =
        "POST /messages?session_id=42 HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:39813\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 17\r\n" ++
        "\r\n";
    const request = try parseRequest(headers);
    try std.testing.expectEqual(Method.post, request.method);
    try std.testing.expectEqualStrings("/messages", request.path);
    try std.testing.expectEqualStrings("session_id=42", request.query);
    try std.testing.expectEqual(@as(usize, 17), request.content_length);
}

test "parseSessionId reads from query string" {
    try std.testing.expectEqual(@as(u64, 7), try parseSessionId("session_id=7"));
    try std.testing.expectEqual(@as(u64, 9), try parseSessionId("foo=bar&session_id=9&baz=qux"));
    try std.testing.expectError(error.MissingSessionId, parseSessionId("foo=bar"));
}

test "writeSseEvent emits SSE event framing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("sse.txt", .{ .read = true });
    defer f.close();

    try writeSseEvent(f.handle, "endpoint", "/messages?session_id=1");
    try f.seekTo(0);

    const contents = try f.readToEndAlloc(allocator, 4096);
    defer allocator.free(contents);

    try std.testing.expectEqualStrings(
        "event: endpoint\ndata: /messages?session_id=1\n\n",
        contents,
    );
}

test "Server starts and shuts down cleanly" {
    const allocator = std.testing.allocator;
    var queue = control.SpawnQueue{};
    defer queue.deinit(allocator);

    const server = try Server.start(allocator, &queue, null, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    try std.testing.expect(server.bound_port != 0);
    server.stopAndJoin();
}

test "GET /sse delivers an endpoint event and POST routes through the spawner" {
    const allocator = std.testing.allocator;
    var queue = control.SpawnQueue{};
    defer queue.deinit(allocator);

    var responder_stop = atomic.Value(bool).init(false);
    const ResponderCtx = struct {
        queue: *control.SpawnQueue,
        stop: *atomic.Value(bool),
        allocator: std.mem.Allocator,

        fn run(self: @This()) void {
            while (!self.stop.load(.seq_cst)) {
                var pending = self.queue.drainAll();
                defer pending.deinit(self.allocator);
                for (pending.items) |*item| {
                    item.completion.complete(.{ .success = .{ .session_id = 1, .slot_index = 0 } });
                    item.request.deinit(self.allocator);
                }
                std.Thread.sleep(std.time.ns_per_ms * 5);
            }
        }
    };
    const responder = try std.Thread.spawn(.{}, ResponderCtx.run, .{ResponderCtx{
        .queue = &queue,
        .stop = &responder_stop,
        .allocator = allocator,
    }});
    defer {
        responder_stop.store(true, .seq_cst);
        responder.join();
    }

    const server = try Server.start(allocator, &queue, null, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer server.stopAndJoin();

    const sse_addr = try std.net.Address.parseIp("127.0.0.1", server.bound_port);
    const sse_fd = try posix.socket(sse_addr.any.family, posix.SOCK.STREAM, 0);
    defer posix.close(sse_fd);
    try posix.connect(sse_fd, &sse_addr.any, sse_addr.getOsSockLen());

    try writeAll(sse_fd, "GET /sse HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var sse_buf: [2048]u8 = undefined;
    var sse_total: usize = 0;
    while (sse_total < sse_buf.len) {
        const n = try posix.read(sse_fd, sse_buf[sse_total..]);
        if (n == 0) break;
        sse_total += n;
        if (std.mem.indexOf(u8, sse_buf[0..sse_total], "event: endpoint") != null and
            std.mem.indexOf(u8, sse_buf[0..sse_total], "\ndata: ") != null) break;
    }
    const seen = sse_buf[0..sse_total];
    try std.testing.expect(std.mem.indexOf(u8, seen, "event: endpoint") != null);

    const data_marker = "data: /messages?session_id=";
    const data_idx = std.mem.indexOf(u8, seen, data_marker) orelse return error.TestUnexpectedResult;
    const id_start = data_idx + data_marker.len;
    var id_end = id_start;
    while (id_end < seen.len and seen[id_end] != '\n') id_end += 1;
    const session_id = try std.fmt.parseInt(u64, seen[id_start..id_end], 10);

    const post_body = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/list\"}";
    var post_req_buf: [256]u8 = undefined;
    const post_req = try std.fmt.bufPrint(
        &post_req_buf,
        "POST /messages?session_id={d} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ session_id, post_body.len, post_body },
    );

    const post_fd = try posix.socket(sse_addr.any.family, posix.SOCK.STREAM, 0);
    defer posix.close(post_fd);
    try posix.connect(post_fd, &sse_addr.any, sse_addr.getOsSockLen());
    try writeAll(post_fd, post_req);

    var post_resp: [512]u8 = undefined;
    const post_n = try posix.read(post_fd, &post_resp);
    try std.testing.expect(std.mem.indexOf(u8, post_resp[0..post_n], "202") != null);

    while (sse_total < sse_buf.len) {
        const n = try posix.read(sse_fd, sse_buf[sse_total..]);
        if (n == 0) break;
        sse_total += n;
        if (std.mem.indexOf(u8, sse_buf[0..sse_total], "event: message") != null and
            std.mem.indexOf(u8, sse_buf[0..sse_total], "\"tools\"") != null) break;
    }
    const final_seen = sse_buf[0..sse_total];
    try std.testing.expect(std.mem.indexOf(u8, final_seen, "event: message") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_seen, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_seen, "\"id\":42") != null);
}
