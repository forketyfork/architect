const std = @import("std");
const Source = @import("source.zig").Source;
const diagnostic_mod = @import("diagnostic.zig");
pub const Diagnostic = diagnostic_mod.Diagnostic;
pub const Severity = diagnostic_mod.Severity;
pub const Location = diagnostic_mod.Location;
pub const SourceRange = diagnostic_mod.SourceRange;

pub const RuleError = error{
    OutOfMemory,
    Overflow,
    InvalidCharacter,
};

/// Base interface that all rules must implement
pub const Rule = struct {
    name: []const u8,
    default_severity: Severity = .err,
    checkFn: *const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void,

    pub fn check(
        self: *const Rule,
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
    ) RuleError!void {
        try self.checkFn(source, allocator, diagnostics);
    }
};
