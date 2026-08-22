const std = @import("std");

pub const PullRequest = struct {
    number: u32,
    title: []const u8,
    branch: []const u8,
};

pub const FetchStatus = enum {
    idle,
    fetching,
    ok,
    failed,
    gh_missing,
};

pub const FetchResult = struct {
    status: FetchStatus,
    prs: []const PullRequest,
    error_message: ?[]const u8 = null,
};

pub fn freeFetchResult(allocator: std.mem.Allocator, result: *FetchResult) void {
    for (result.prs) |pr| {
        allocator.free(pr.title);
        allocator.free(pr.branch);
    }
    allocator.free(result.prs);
    if (result.error_message) |message| allocator.free(message);
    result.prs = &[_]PullRequest{};
    result.error_message = null;
}

pub fn shouldFetchOnRepoEntry(is_github_repo: bool, fetch_status: FetchStatus) bool {
    return is_github_repo and fetch_status == .idle;
}

pub fn prNumberForBranch(branch: ?[]const u8, prs: []const PullRequest) ?u32 {
    const current_branch = branch orelse return null;
    for (prs) |pr| {
        if (std.mem.eql(u8, pr.branch, current_branch)) return pr.number;
    }
    return null;
}

pub fn cwdChanged(prev: ?[]const u8, next: ?[]const u8) bool {
    if (prev == null and next == null) return false;
    if (prev == null or next == null) return true;
    return !std.mem.eql(u8, prev.?, next.?);
}

pub fn optionalSlicesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

pub fn fetchResultMatchesRepo(fetch_repo: []const u8, current_repo: ?[]const u8, is_github_repo: bool) bool {
    return is_github_repo and optionalSlicesEqual(fetch_repo, current_repo);
}

test "fetch results only match the focused repository" {
    try std.testing.expect(fetchResultMatchesRepo("/repo/a", "/repo/a", true));
    try std.testing.expect(!fetchResultMatchesRepo("/repo/a", "/repo/b", true));
    try std.testing.expect(!fetchResultMatchesRepo("/repo/a", null, true));
    try std.testing.expect(!fetchResultMatchesRepo("/repo/a", "/repo/a", false));
}

test "entering a GitHub repo fetches PRs for the collapsed badge" {
    try std.testing.expect(shouldFetchOnRepoEntry(true, .idle));
    try std.testing.expect(!shouldFetchOnRepoEntry(true, .fetching));
    try std.testing.expect(!shouldFetchOnRepoEntry(true, .ok));
    try std.testing.expect(!shouldFetchOnRepoEntry(false, .idle));
}

test "current PR number follows the current branch" {
    const prs = [_]PullRequest{
        .{ .number = 10, .title = "one", .branch = "feature/one" },
        .{ .number = 20, .title = "two", .branch = "feature/two" },
    };

    try std.testing.expectEqual(@as(?u32, 10), prNumberForBranch("feature/one", &prs));
    try std.testing.expectEqual(@as(?u32, 20), prNumberForBranch("feature/two", &prs));
    try std.testing.expectEqual(@as(?u32, null), prNumberForBranch("main", &prs));
    try std.testing.expectEqual(@as(?u32, null), prNumberForBranch(null, &prs));
}
