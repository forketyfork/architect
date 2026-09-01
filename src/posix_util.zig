const std = @import("std");

pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
} || std.posix.UnexpectedError;

pub fn fcntl(fd: std.posix.fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        const rc = std.posix.system.fcntl(fd, cmd, arg);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable,
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable,
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub fn dup2(old_fd: std.posix.fd_t, new_fd: std.posix.fd_t) !void {
    while (true) {
        switch (std.posix.errno(std.posix.system.dup2(old_fd, new_fd))) {
            .SUCCESS => return,
            .BUSY, .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL, .BADF => unreachable,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub const ForkError = error{SystemResources} || std.posix.UnexpectedError;

pub fn fork() ForkError!std.posix.pid_t {
    const rc = std.posix.system.fork();
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN, .NOMEM => return error.SystemResources,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || std.posix.UnexpectedError;

pub fn pipe(fds: *[2]std.posix.fd_t) PipeError!void {
    switch (std.posix.errno(std.posix.system.pipe(fds))) {
        .SUCCESS => return,
        .INVAL, .FAULT => unreachable,
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub const WriteError = error{
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    InvalidArgument,
    AccessDenied,
    PermissionDenied,
    BrokenPipe,
    SystemResources,
    OperationAborted,
    NotOpenForWriting,
    LockViolation,
    WouldBlock,
    ConnectionResetByPeer,
    ProcessNotFound,
    NoDevice,
    MessageTooBig,
} || std.posix.UnexpectedError;

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    SocketNotListening,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolFailure,
    BlockedByFirewall,
} || std.posix.UnexpectedError;

/// Accepts a connection on `sock` without capturing the peer address, mirroring
/// Zig 0.15.2's `std.posix.accept(sock, null, null, 0)`. `std.Io.net.Server.accept`
/// cannot be used here: it treats `EAGAIN` on a non-blocking listening socket as a
/// programmer bug and panics, but the call sites need non-blocking accept to poll
/// a stop flag alongside listening for connections.
pub fn accept(sock: std.posix.fd_t) AcceptError!std.posix.fd_t {
    while (true) {
        const rc = std.posix.system.accept(sock, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable,
            .CONNABORTED => return error.ConnectionAborted,
            .FAULT => unreachable,
            .INVAL => return error.SocketNotListening,
            .NOTSOCK => unreachable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .OPNOTSUPP => unreachable,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub fn write(fd: std.posix.fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;

    const max_count = switch (@import("builtin").os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    while (true) {
        const rc = std.posix.system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DESTADDRREQ => unreachable,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .NXIO => return error.NoDevice,
            .MSGSIZE => return error.MessageTooBig,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
