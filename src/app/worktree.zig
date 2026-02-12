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

/// Clear current input line before sending command (Ctrl+U)
const clear_line_prefix = "\x15";

pub fn changeSessionDirectory(session: *SessionState, allocator: std.mem.Allocator, path: []const u8) !void {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    try command.appendSlice(allocator, clear_line_prefix ++ "cd -- ");
    try appendQuotedPath(&command, allocator, path);
    try command.append(allocator, '\n');

    try session.sendInput(command.items);
    try session.recordCwd(path);
}

/// Resolve the absolute worktree target directory for a new worktree.
/// If `config_dir` is set, expands `~` and appends `<repo-name>/<worktree-name>`.
/// Otherwise defaults to `~/.architect-worktrees/<repo-name>/<worktree-name>`.
pub fn resolveWorktreeDir(allocator: std.mem.Allocator, repo_root: []const u8, name: []const u8, config_dir: ?[]const u8) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
    const repo_name = std.fs.path.basename(repo_root);

    const base = if (config_dir) |dir|
        if (dir.len > 0 and dir[0] == '~')
            try std.fs.path.join(allocator, &.{ home, dir[1..], repo_name })
        else
            try std.fs.path.join(allocator, &.{ dir, repo_name })
    else
        try std.fs.path.join(allocator, &.{ home, ".architect-worktrees", repo_name });
    defer allocator.free(base);

    return std.fs.path.join(allocator, &.{ base, name });
}

pub fn buildCreateWorktreeCommand(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    target_path: []const u8,
    name: []const u8,
    init_command: ?[]const u8,
) ![]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(allocator);

    // cd to repo root so git worktree add runs in the right context
    try cmd.appendSlice(allocator, clear_line_prefix ++ "cd -- ");
    try appendQuotedPath(&cmd, allocator, repo_root);

    // create parent directory and add worktree
    const parent = std.fs.path.dirname(target_path) orelse target_path;
    try cmd.appendSlice(allocator, " && mkdir -p ");
    try appendQuotedPath(&cmd, allocator, parent);
    try cmd.appendSlice(allocator, " && git worktree add ");
    try appendQuotedPath(&cmd, allocator, target_path);
    try cmd.appendSlice(allocator, " -b ");
    try appendQuotedPath(&cmd, allocator, name);

    // cd into the new worktree
    try cmd.appendSlice(allocator, " && cd -- ");
    try appendQuotedPath(&cmd, allocator, target_path);

    // run init command (explicit or auto-detected)
    if (init_command) |ic| {
        try cmd.appendSlice(allocator, " && ");
        try cmd.appendSlice(allocator, ic);
    } else {
        try cmd.appendSlice(
            allocator,
            " && if [ -x script/setup ]; then script/setup;" ++
                " elif [ -x .architect-init.sh ]; then ./.architect-init.sh; fi",
        );
    }

    try cmd.append(allocator, '\n');
    return cmd.toOwnedSlice(allocator);
}

pub fn buildRemoveWorktreeCommand(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(allocator);

    try cmd.appendSlice(allocator, clear_line_prefix ++ "git worktree remove ");
    try appendQuotedPath(&cmd, allocator, path);
    try cmd.appendSlice(allocator, "\n");

    return cmd.toOwnedSlice(allocator);
}
