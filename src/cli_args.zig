const std = @import("std");

pub const ParsedArgs = struct {
    log_dir_override: ?[]const u8 = null,
};

pub const ParseError = error{
    MissingLogDirValue,
    UnknownArgument,
};

pub const usage_text = "usage: architect [--log-dir <path>]\n";

/// Parses CLI arguments, excluding argv[0] (the executable path).
/// Returned slices borrow from `args` and are only valid as long as `args` is.
pub fn parse(args: []const []const u8) ParseError!ParsedArgs {
    var result: ParsedArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--log-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingLogDirValue;
            result.log_dir_override = args[i];
        } else {
            return error.UnknownArgument;
        }
    }
    return result;
}

test "parse with no arguments leaves log_dir_override unset" {
    const parsed = try parse(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.log_dir_override);
}

test "parse --log-dir sets log_dir_override" {
    const parsed = try parse(&.{ "--log-dir", "/tmp/architect-logs" });
    try std.testing.expectEqualStrings("/tmp/architect-logs", parsed.log_dir_override.?);
}

test "parse --log-dir without a value returns MissingLogDirValue" {
    try std.testing.expectError(error.MissingLogDirValue, parse(&.{"--log-dir"}));
}

test "parse rejects unknown arguments" {
    try std.testing.expectError(error.UnknownArgument, parse(&.{"--bogus"}));
}

test "parse takes the last --log-dir when passed multiple times" {
    const parsed = try parse(&.{ "--log-dir", "/first", "--log-dir", "/second" });
    try std.testing.expectEqualStrings("/second", parsed.log_dir_override.?);
}
