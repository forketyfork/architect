const std = @import("std");
const posix = std.posix;
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

const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
});

pub fn getCwd(allocator: std.mem.Allocator, pid: std.c.pid_t) CwdError![]const u8 {
    var vnode_info: c.struct_proc_vnodepathinfo = undefined;

    const result = c.proc_pidinfo(
        @intCast(pid),
        c.PROC_PIDVNODEPATHINFO,
        0,
        &vnode_info,
        @sizeOf(c.struct_proc_vnodepathinfo),
    );

    if (result <= 0) {
        log.warn("failed to get cwd for pid {d}", .{pid});
        return error.ProcessNotFound;
    }

    const cwd_path = std.mem.sliceTo(&vnode_info.pvi_cdir.vip_path, 0);

    if (cwd_path.len == 0) {
        return error.ProcessNotFound;
    }

    return allocator.dupe(u8, cwd_path);
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
