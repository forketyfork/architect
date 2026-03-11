const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const posix = std.posix;
const time_c = @cImport({
    @cInclude("time.h");
});

pub const active_log_filename = "architect.log";
pub const default_max_file_size_bytes: u64 = 10 * 1024 * 1024;

pub const InitOptions = struct {
    min_level: std.log.Level = .info,
    max_file_size_bytes: u64 = default_max_file_size_bytes,
    directory_override: ?[]const u8 = null,
};

const LoggerState = struct {
    mutex: std.Thread.Mutex = .{},
    initialized: bool = false,
    allocator: ?std.mem.Allocator = null,
    directory_path: ?[]u8 = null,
    file: ?fs.File = null,
    current_size: u64 = 0,
    min_level: std.log.Level = .info,
    max_file_size_bytes: u64 = default_max_file_size_bytes,
};

var state: LoggerState = .{};

fn logLevelLabel(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
}

fn normalizeMaxFileSize(bytes: u64) u64 {
    if (bytes == 0) return default_max_file_size_bytes;
    return bytes;
}

fn isEnabled(min_level: std.log.Level, level: std.log.Level) bool {
    return @intFromEnum(level) <= @intFromEnum(min_level);
}

fn defaultLogDirectoryPath(allocator: std.mem.Allocator) ![]u8 {
    const home = posix.getenv("HOME") orelse return error.HomeNotFound;
    if (builtin.os.tag == .macos) {
        return fs.path.join(allocator, &[_][]const u8{ home, "Library", "Logs", "Architect" });
    }
    return fs.path.join(allocator, &[_][]const u8{ home, ".local", "state", "architect", "logs" });
}

fn buildPath(path_buf: []u8, directory_path: []const u8, basename: []const u8) ![]const u8 {
    return std.fmt.bufPrint(path_buf, "{s}/{s}", .{ directory_path, basename });
}

fn timestampToLocalIso8601(timestamp_secs: i64, output: []u8) ![]const u8 {
    var ts: time_c.time_t = @intCast(timestamp_secs);
    var local_tm: time_c.struct_tm = undefined;
    if (time_c.localtime_r(&ts, &local_tm) == null) return error.TimeConversionFailed;

    var raw_buf: [40]u8 = undefined;
    const written = time_c.strftime(&raw_buf, raw_buf.len, "%Y-%m-%dT%H:%M:%S%z", &local_tm);
    if (written == 0) return error.TimeFormatFailed;

    const raw = raw_buf[0..written];
    if (raw.len < 5) return error.InvalidTimezoneOffset;

    const tz = raw[raw.len - 5 ..];
    const tz_sign = tz[0];
    if (tz_sign != '+' and tz_sign != '-') return error.InvalidTimezoneOffset;
    if (!std.ascii.isDigit(tz[1]) or !std.ascii.isDigit(tz[2]) or
        !std.ascii.isDigit(tz[3]) or !std.ascii.isDigit(tz[4]))
    {
        return error.InvalidTimezoneOffset;
    }

    return std.fmt.bufPrint(output, "{s}{c}{c}{c}:{c}{c}", .{
        raw[0 .. raw.len - 5],
        tz[0],
        tz[1],
        tz[2],
        tz[3],
        tz[4],
    });
}

fn rotationSuffix(timestamp_secs: i64, output: []u8) ![]const u8 {
    const seconds_u64: u64 = if (timestamp_secs < 0) 0 else @intCast(timestamp_secs);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds_u64 };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();
    return std.fmt.bufPrint(output, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month,
        day,
        hour,
        minute,
        second,
    });
}

fn writeEscapedMessage(writer: *std.Io.Writer, message: []const u8) !void {
    for (message) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n', '\r', '\t' => try writer.writeByte(' '),
            else => {
                if (ch < 0x20) {
                    try writer.writeByte('?');
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

fn openActiveLogFile(directory_path: []const u8) !struct { file: fs.File, size: u64 } {
    var active_path_buf: [fs.max_path_bytes]u8 = undefined;
    const active_path = try buildPath(&active_path_buf, directory_path, active_log_filename);
    const file = try fs.createFileAbsolute(active_path, .{
        .truncate = false,
        .read = true,
    });
    const size = try file.getEndPos();
    try file.seekTo(size);
    return .{
        .file = file,
        .size = size,
    };
}

fn rotateLocked(s: *LoggerState) !void {
    const directory_path = s.directory_path orelse return error.LoggerNotInitialized;
    const existing_file = s.file orelse return error.LoggerNotInitialized;
    existing_file.close();
    s.file = null;

    var active_path_buf: [fs.max_path_bytes]u8 = undefined;
    const active_path = try buildPath(&active_path_buf, directory_path, active_log_filename);
    const now_secs = std.time.timestamp();
    var suffix_buf: [32]u8 = undefined;
    const suffix = try rotationSuffix(now_secs, &suffix_buf);

    var archive_name_buf: [128]u8 = undefined;
    var archive_path_buf: [fs.max_path_bytes]u8 = undefined;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const archive_name = if (attempt == 0)
            try std.fmt.bufPrint(&archive_name_buf, "architect-{s}.log", .{suffix})
        else
            try std.fmt.bufPrint(&archive_name_buf, "architect-{s}-{d}.log", .{ suffix, attempt });
        const archive_path = try buildPath(&archive_path_buf, directory_path, archive_name);
        fs.renameAbsolute(active_path, archive_path) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            error.FileNotFound => break,
            else => return err,
        };
        break;
    }

    const active = try openActiveLogFile(directory_path);
    s.file = active.file;
    s.current_size = active.size;
}

fn ensureCapacityLocked(s: *LoggerState, incoming_bytes: usize) !void {
    const incoming_u64: u64 = @intCast(incoming_bytes);
    if (s.current_size + incoming_u64 <= s.max_file_size_bytes) return;
    try rotateLocked(s);
}

fn writeRecordLocked(
    s: *LoggerState,
    comptime level: std.log.Level,
    scope_name: []const u8,
    message: []const u8,
    extra_data: ?[]const u8,
    force_write: bool,
) !void {
    if (!s.initialized) return error.LoggerNotInitialized;
    if (!force_write and !isEnabled(s.min_level, level)) return;

    var timestamp_buf: [32]u8 = undefined;
    const timestamp = try timestampToLocalIso8601(std.time.timestamp(), &timestamp_buf);

    var line_buf: [8192]u8 = undefined;
    const line = blk: {
        var writer = std.Io.Writer.fixed(&line_buf);
        writer.print("{s} level={s} scope={s} msg=\"", .{ timestamp, logLevelLabel(level), scope_name }) catch |err| switch (err) {
            error.WriteFailed => break :blk "1970-01-01T00:00:00Z level=ERROR scope=logging msg=\"failed to format log line\"\n",
            else => return err,
        };
        writeEscapedMessage(&writer, message) catch |err| switch (err) {
            error.WriteFailed => {},
            else => return err,
        };
        writer.writeByte('"') catch |err| switch (err) {
            error.WriteFailed => {},
            else => return err,
        };
        if (extra_data) |extra| {
            writer.writeByte(' ') catch |err| switch (err) {
                error.WriteFailed => {},
                else => return err,
            };
            writer.writeAll(extra) catch |err| switch (err) {
                error.WriteFailed => {},
                else => return err,
            };
        }
        writer.writeByte('\n') catch |err| switch (err) {
            error.WriteFailed => {},
            else => return err,
        };
        break :blk writer.buffered();
    };

    try ensureCapacityLocked(s, line.len);
    const log_file = s.file orelse return error.LoggerNotInitialized;
    try log_file.writeAll(line);
    s.current_size += line.len;
}

fn writeEventLocked(
    s: *LoggerState,
    scope_name: []const u8,
    message: []const u8,
    event_name: []const u8,
    extra_data: ?[]const u8,
) !void {
    var event_buf: [512]u8 = undefined;
    const extra_fields = if (extra_data) |extra|
        try std.fmt.bufPrint(&event_buf, "event={s} {s}", .{ event_name, extra })
    else
        try std.fmt.bufPrint(&event_buf, "event={s}", .{event_name});
    try writeRecordLocked(s, .info, scope_name, message, extra_fields, true);
}

fn emitLoggingInternalError(err: anyerror) void {
    var stderr_buf: [128]u8 = undefined;
    var stderr_writer = std.debug.lockStderrWriter(&stderr_buf);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr_writer.print("file logging failed: {}\n", .{err}) catch return;
}

pub fn init(allocator: std.mem.Allocator, options: InitOptions) !void {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (state.initialized) return;

    const directory_path = if (options.directory_override) |override|
        try allocator.dupe(u8, override)
    else
        try defaultLogDirectoryPath(allocator);
    errdefer allocator.free(directory_path);

    try fs.cwd().makePath(directory_path);

    const active = try openActiveLogFile(directory_path);

    state.allocator = allocator;
    state.directory_path = directory_path;
    state.file = active.file;
    state.current_size = active.size;
    state.min_level = options.min_level;
    state.max_file_size_bytes = normalizeMaxFileSize(options.max_file_size_bytes);
    state.initialized = true;
}

pub fn deinit() void {
    state.mutex.lock();
    defer state.mutex.unlock();

    if (!state.initialized) return;

    if (state.file) |file| {
        file.sync() catch |err| {
            emitLoggingInternalError(err);
        };
        file.close();
    }

    if (state.directory_path) |path| {
        if (state.allocator) |allocator| {
            allocator.free(path);
        }
    }

    state.initialized = false;
    state.allocator = null;
    state.directory_path = null;
    state.file = null;
    state.current_size = 0;
    state.min_level = .info;
    state.max_file_size_bytes = default_max_file_size_bytes;
}

pub fn isInitialized() bool {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.initialized;
}

pub fn writeStartupMarker() !void {
    state.mutex.lock();
    defer state.mutex.unlock();
    try writeEventLocked(&state, "runtime", "architect startup", "startup", null);
}

pub fn writeShutdownMarker() !void {
    state.mutex.lock();
    defer state.mutex.unlock();
    try writeEventLocked(&state, "runtime", "architect shutdown", "shutdown", null);
}

pub fn writeEvent(
    scope_name: []const u8,
    message: []const u8,
    event_name: []const u8,
    extra_data: ?[]const u8,
) !void {
    state.mutex.lock();
    defer state.mutex.unlock();
    try writeEventLocked(&state, scope_name, message, event_name, extra_data);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var should_fallback_to_stderr = false;
    {
        state.mutex.lock();
        defer state.mutex.unlock();

        if (!state.initialized) {
            should_fallback_to_stderr = true;
        } else if (!isEnabled(state.min_level, level)) {
            return;
        } else {
            var message_buf: [4096]u8 = undefined;
            const message = std.fmt.bufPrint(&message_buf, format, args) catch |err| blk: {
                emitLoggingInternalError(err);
                break :blk "message exceeded 4096-byte logging buffer";
            };
            writeRecordLocked(&state, level, @tagName(scope), message, null, false) catch |err| {
                emitLoggingInternalError(err);
                should_fallback_to_stderr = true;
            };
        }
    }

    if (should_fallback_to_stderr) {
        std.log.defaultLog(level, scope, format, args);
    }
}

fn activeLogPathAlloc(allocator: std.mem.Allocator, directory_path: []const u8) ![]u8 {
    return fs.path.join(allocator, &[_][]const u8{ directory_path, active_log_filename });
}

fn readActiveLogAlloc(allocator: std.mem.Allocator, directory_path: []const u8) ![]u8 {
    const active_path = try activeLogPathAlloc(allocator, directory_path);
    defer allocator.free(active_path);
    const file = try fs.openFileAbsolute(active_path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 4 * 1024 * 1024);
}

test "timestampToLocalIso8601 includes local timezone offset" {
    var output: [32]u8 = undefined;
    const ts = try timestampToLocalIso8601(0, &output);
    try std.testing.expectEqual(@as(usize, 25), ts.len);
    try std.testing.expectEqual(@as(u8, '-'), ts[4]);
    try std.testing.expectEqual(@as(u8, '-'), ts[7]);
    try std.testing.expectEqual(@as(u8, 'T'), ts[10]);
    try std.testing.expectEqual(@as(u8, ':'), ts[13]);
    try std.testing.expectEqual(@as(u8, ':'), ts[16]);
    try std.testing.expect(ts[19] == '+' or ts[19] == '-');
    try std.testing.expectEqual(@as(u8, ':'), ts[22]);
}

test "logFn respects minimum level filtering" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try init(allocator, .{
        .directory_override = tmp_path,
        .min_level = .warn,
        .max_file_size_bytes = 1024 * 1024,
    });
    defer deinit();

    logFn(.info, .logging_test, "info message should be filtered", .{});
    logFn(.warn, .logging_test, "warn message should be written", .{});

    const contents = try readActiveLogAlloc(allocator, tmp_path);
    defer allocator.free(contents);

    try std.testing.expect(!std.mem.containsAtLeast(u8, contents, 1, "info message should be filtered"));
    try std.testing.expect(std.mem.containsAtLeast(u8, contents, 1, "warn message should be written"));
}

test "log line includes timestamp, level, scope, and message fields" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try init(allocator, .{
        .directory_override = tmp_path,
        .min_level = .debug,
    });
    defer deinit();

    logFn(.info, .runtime, "hello structured log", .{});

    const contents = try readActiveLogAlloc(allocator, tmp_path);
    defer allocator.free(contents);

    const line = std.mem.trim(u8, contents, "\n");
    try std.testing.expect(line.len > 32);
    try std.testing.expectEqual(@as(u8, '-'), line[4]);
    try std.testing.expectEqual(@as(u8, '-'), line[7]);
    try std.testing.expectEqual(@as(u8, 'T'), line[10]);
    try std.testing.expectEqual(@as(u8, ':'), line[13]);
    try std.testing.expectEqual(@as(u8, ':'), line[16]);
    try std.testing.expect(line[19] == '+' or line[19] == '-');
    try std.testing.expectEqual(@as(u8, ':'), line[22]);
    try std.testing.expect(std.mem.containsAtLeast(u8, line, 1, "level=INFO"));
    try std.testing.expect(std.mem.containsAtLeast(u8, line, 1, "scope=runtime"));
    try std.testing.expect(std.mem.containsAtLeast(u8, line, 1, "msg=\"hello structured log\""));
}

test "rotation archives old file once size limit is exceeded" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try init(allocator, .{
        .directory_override = tmp_path,
        .min_level = .debug,
        .max_file_size_bytes = 256,
    });
    defer deinit();

    var idx: usize = 0;
    while (idx < 20) : (idx += 1) {
        logFn(.info, .rotation_test, "rotation line {d} abcdefghijklmnopqrstuvwxyz", .{idx});
    }

    var dir = try fs.openDirAbsolute(tmp_path, .{ .iterate = true });
    defer dir.close();
    var iterator = dir.iterate();

    var active_found = false;
    var archive_count: usize = 0;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, active_log_filename)) {
            active_found = true;
            continue;
        }
        if (std.mem.startsWith(u8, entry.name, "architect-")) {
            archive_count += 1;
        }
    }

    try std.testing.expect(active_found);
    try std.testing.expect(archive_count > 0);
}

test "startup, shutdown, and explicit events are emitted with info level" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try init(allocator, .{
        .directory_override = tmp_path,
        .min_level = .err,
    });
    defer deinit();

    try writeStartupMarker();
    try writeEvent("runtime", "entered full view", "view_enter_full", "from=Grid to=Full");
    try writeShutdownMarker();

    const contents = try readActiveLogAlloc(allocator, tmp_path);
    defer allocator.free(contents);

    var event_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.containsAtLeast(u8, line, 1, "event=")) {
            event_lines += 1;
            try std.testing.expect(std.mem.containsAtLeast(u8, line, 1, "level=INFO"));
        }
    }
    try std.testing.expect(std.mem.containsAtLeast(u8, contents, 1, "event=view_enter_full from=Grid to=Full"));
    try std.testing.expectEqual(@as(usize, 3), event_lines);
}
