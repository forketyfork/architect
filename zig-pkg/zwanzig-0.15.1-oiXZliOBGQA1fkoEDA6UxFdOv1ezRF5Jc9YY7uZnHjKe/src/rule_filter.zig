pub const RuleFilter = union(enum) {
    none,
    allowlist: []const []const u8,
    blocklist: []const []const u8,
};
