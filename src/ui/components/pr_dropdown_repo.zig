const std = @import("std");

/// Walk upward from `cwd` looking for a `.git` directory (or `.git` file for worktrees).
/// Returns a newly-allocated absolute path to the directory containing `.git`.
pub fn findRepoRoot(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        const dot_git = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(dot_git);

        var found = false;
        if (std.Io.Dir.openDirAbsolute(io, dot_git, .{})) |dir_const| {
            var dir = dir_const;
            dir.close(io);
            found = true;
        } else |_| {
            if (std.Io.Dir.openFileAbsolute(io, dot_git, .{})) |file| {
                file.close(io);
                found = true;
            } else |_| {}
        }
        if (found) return current;

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }
        const parent_copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = parent_copy;
    }
}

/// Look at the git config and decide whether `[remote "origin"]` points at github.com.
/// Resolves `.git` files (worktrees) so it finds the main repo's config.
pub fn detectGithubOrigin(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) !bool {
    const cfg_path = try resolveConfigPath(allocator, io, repo_root);
    defer allocator.free(cfg_path);

    const file = std.Io.Dir.openFileAbsolute(io, cfg_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, cfg_path, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);

    return originUrlIsGithub(bytes);
}

fn resolveConfigPath(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) ![]u8 {
    const dot_git = try std.fs.path.join(allocator, &.{ repo_root, ".git" });
    defer allocator.free(dot_git);

    if (std.Io.Dir.openDirAbsolute(io, dot_git, .{})) |dir_const| {
        var dir = dir_const;
        dir.close(io);
        return std.fs.path.join(allocator, &.{ dot_git, "config" });
    } else |_| {}

    const file = std.Io.Dir.openFileAbsolute(io, dot_git, .{}) catch {
        return std.fs.path.join(allocator, &.{ dot_git, "config" });
    };
    defer file.close(io);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, dot_git, allocator, .limited(4096));
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) {
        return std.fs.path.join(allocator, &.{ dot_git, "config" });
    }
    const gitdir_rel = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
    const gitdir_abs = if (std.fs.path.isAbsolute(gitdir_rel))
        try allocator.dupe(u8, gitdir_rel)
    else
        try std.fs.path.resolve(allocator, &.{ repo_root, gitdir_rel });
    defer allocator.free(gitdir_abs);

    // For a worktree, gitdir is `<main>/.git/worktrees/<name>`. The config lives
    // at `<main>/.git/config`. Read `commondir` to find the main gitdir.
    const commondir_path = try std.fs.path.join(allocator, &.{ gitdir_abs, "commondir" });
    defer allocator.free(commondir_path);
    if (std.Io.Dir.openFileAbsolute(io, commondir_path, .{})) |cf| {
        defer cf.close(io);
        const cb = try std.Io.Dir.cwd().readFileAlloc(io, commondir_path, allocator, .limited(4096));
        defer allocator.free(cb);
        const ct = std.mem.trim(u8, cb, " \t\r\n");
        if (ct.len > 0) {
            if (std.fs.path.isAbsolute(ct)) {
                return std.fs.path.join(allocator, &.{ ct, "config" });
            }
            return std.fs.path.resolve(allocator, &.{ gitdir_abs, ct, "config" });
        }
    } else |_| {}
    return std.fs.path.join(allocator, &.{ gitdir_abs, "config" });
}

pub fn originUrlIsGithub(config_bytes: []const u8) bool {
    var in_origin_section = false;
    var line_iter = std.mem.splitScalar(u8, config_bytes, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == ';' or line[0] == '#') continue;

        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            const inside = line[1 .. line.len - 1];
            in_origin_section = sectionMatchesOrigin(inside);
            continue;
        }

        if (!in_origin_section) continue;
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "url")) continue;
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\"");
        if (urlPointsToGithub(value)) return true;
    }
    return false;
}

fn sectionMatchesOrigin(section: []const u8) bool {
    const trimmed = std.mem.trim(u8, section, " \t");
    if (!std.mem.startsWith(u8, trimmed, "remote")) return false;
    const rest = std.mem.trim(u8, trimmed["remote".len..], " \t");
    if (rest.len < 2) return false;
    const first = rest[0];
    const last = rest[rest.len - 1];
    if (!((first == '"' and last == '"') or (first == '\'' and last == '\''))) return false;
    const name = rest[1 .. rest.len - 1];
    return std.mem.eql(u8, name, "origin");
}

fn urlPointsToGithub(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "github.com") != null;
}

/// Read HEAD and return the current branch name (or null if detached HEAD).
/// Handles both regular repos and worktrees.
pub fn readCurrentBranch(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) !?[]u8 {
    const head_path = try resolveHeadPath(allocator, io, repo_root);
    defer allocator.free(head_path);

    const file = std.Io.Dir.openFileAbsolute(io, head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096));
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const branch = trimmed[prefix.len..];
    if (branch.len == 0) return null;
    return try allocator.dupe(u8, branch);
}

fn resolveHeadPath(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) ![]u8 {
    const dot_git = try std.fs.path.join(allocator, &.{ repo_root, ".git" });
    defer allocator.free(dot_git);

    if (std.Io.Dir.openDirAbsolute(io, dot_git, .{})) |dir_const| {
        var dir = dir_const;
        dir.close(io);
        return std.fs.path.join(allocator, &.{ dot_git, "HEAD" });
    } else |_| {}

    const file = std.Io.Dir.openFileAbsolute(io, dot_git, .{}) catch {
        return std.fs.path.join(allocator, &.{ dot_git, "HEAD" });
    };
    defer file.close(io);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, dot_git, allocator, .limited(4096));
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) {
        return std.fs.path.join(allocator, &.{ dot_git, "HEAD" });
    }
    const gitdir_rel = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
    if (std.fs.path.isAbsolute(gitdir_rel)) {
        return std.fs.path.join(allocator, &.{ gitdir_rel, "HEAD" });
    }
    return std.fs.path.resolve(allocator, &.{ repo_root, gitdir_rel, "HEAD" });
}

test "originUrlIsGithub — https origin matches" {
    const cfg =
        \\[core]
        \\    bare = false
        \\[remote "origin"]
        \\    url = https://github.com/foo/bar.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    ;
    try std.testing.expect(originUrlIsGithub(cfg));
}

test "originUrlIsGithub — ssh origin matches" {
    const cfg =
        \\[remote "origin"]
        \\    url = git@github.com:foo/bar.git
    ;
    try std.testing.expect(originUrlIsGithub(cfg));
}

test "originUrlIsGithub — non-github origin returns false" {
    const cfg =
        \\[remote "origin"]
        \\    url = https://gitlab.com/foo/bar.git
    ;
    try std.testing.expect(!originUrlIsGithub(cfg));
}

test "originUrlIsGithub — github URL only in non-origin remote returns false" {
    const cfg =
        \\[remote "upstream"]
        \\    url = https://github.com/foo/bar.git
        \\[remote "origin"]
        \\    url = https://gitlab.com/foo/bar.git
    ;
    try std.testing.expect(!originUrlIsGithub(cfg));
}

test "originUrlIsGithub — comments and blank lines are tolerated" {
    const cfg =
        \\# my config
        \\
        \\[remote "origin"]
        \\    ; comment
        \\    url = https://github.com/foo/bar.git
    ;
    try std.testing.expect(originUrlIsGithub(cfg));
}
