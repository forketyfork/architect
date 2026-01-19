const std = @import("std");
const session_state = @import("../session/state.zig");

const SessionState = session_state.SessionState;

fn appendQuotedPath(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    try buf.append(allocator, '\'');
    for (path) |ch| switch (ch) {
        '\'' => try buf.appendSlice(allocator, "'\"'\"'"),
        else => try buf.append(allocator, ch),
    };
    try buf.append(allocator, '\'');
}

pub fn shellQuotePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try appendQuotedPath(&buf, allocator, path);
    try buf.append(allocator, ' ');

    return buf.toOwnedSlice(allocator);
}

pub fn changeSessionDirectory(session: *SessionState, allocator: std.mem.Allocator, path: []const u8) !void {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    try command.appendSlice(allocator, "cd -- ");
    try appendQuotedPath(&command, allocator, path);
    try command.append(allocator, '\n');

    try session.sendInput(command.items);
    try session.recordCwd(path);
}

pub fn buildCreateWorktreeCommand(allocator: std.mem.Allocator, base_path: []const u8, name: []const u8) ![]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(allocator);

    try cmd.appendSlice(allocator, "cd -- ");
    try appendQuotedPath(&cmd, allocator, base_path);
    try cmd.appendSlice(allocator, " && mkdir -p .architect && git worktree add ");

    const target_rel = try std.fmt.allocPrint(allocator, ".architect/{s}", .{name});
    defer allocator.free(target_rel);

    try appendQuotedPath(&cmd, allocator, target_rel);
    try cmd.appendSlice(allocator, " -b ");
    try appendQuotedPath(&cmd, allocator, name);
    try cmd.appendSlice(allocator, " && cd -- ");
    try appendQuotedPath(&cmd, allocator, target_rel);
    try cmd.appendSlice(allocator, "\n");

    return cmd.toOwnedSlice(allocator);
}

pub fn buildRemoveWorktreeCommand(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(allocator);

    try cmd.appendSlice(allocator, "git worktree remove ");
    try appendQuotedPath(&cmd, allocator, path);
    try cmd.appendSlice(allocator, "\n");

    return cmd.toOwnedSlice(allocator);
}
