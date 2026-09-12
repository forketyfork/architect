const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.cwd);

comptime {
    if (builtin.os.tag != .macos) {
        @compileError("cwd.zig: proc_pidinfo API is macOS-specific. This module should only be compiled on macOS.");
    }
}

pub const CwdError = error{
    ProcessNotFound,
    BufferTooSmall,
    SystemError,
    OutOfMemory,
};

const c = @import("c_libproc");

pub fn getCwd(allocator: std.mem.Allocator, pid: std.c.pid_t) CwdError![]const u8 {
    var cwd_path: [std.fs.max_path_bytes]u8 = undefined;

    const result = c.architect_proc_pid_cwd(
        @intCast(pid),
        &cwd_path,
        cwd_path.len,
    );

    if (result == c.ARCHITECT_PROC_CWD_BUFFER_TOO_SMALL) {
        return error.BufferTooSmall;
    }
    if (result <= 0) {
        log.warn("failed to get cwd for pid {d}", .{pid});
        return error.ProcessNotFound;
    }

    const cwd_len: usize = @intCast(result);
    if (cwd_len >= cwd_path.len) return error.SystemError;

    return allocator.dupe(u8, cwd_path[0..cwd_len]);
}

pub fn getBasename(path: []const u8) []const u8 {
    if (path.len == 0) return "";

    var i = path.len - 1;
    while (i > 0 and path[i] == '/') : (i -= 1) {}

    const end = i + 1;

    while (i > 0 and path[i] != '/') : (i -= 1) {}

    const start = if (i == 0 and path[0] != '/') 0 else i + 1;

    if (start >= end) return "/";

    return path[start..end];
}

test "getBasename - simple path" {
    try std.testing.expectEqualStrings("bar", getBasename("/foo/bar"));
    try std.testing.expectEqualStrings("baz", getBasename("/foo/bar/baz"));
}

test "getBasename - root" {
    try std.testing.expectEqualStrings("/", getBasename("/"));
}

test "getBasename - trailing slash" {
    try std.testing.expectEqualStrings("bar", getBasename("/foo/bar/"));
}

test "getBasename - no slash" {
    try std.testing.expectEqualStrings("foo", getBasename("foo"));
}

test "getBasename - empty" {
    try std.testing.expectEqualStrings("", getBasename(""));
}
