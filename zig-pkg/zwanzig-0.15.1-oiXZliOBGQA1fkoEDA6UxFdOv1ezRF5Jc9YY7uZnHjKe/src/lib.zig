pub const source = @import("source.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const rule = @import("rule.zig");
pub const checker = @import("checker.zig");
pub const config = @import("config.zig");
pub const analyzer = @import("analyzer.zig");
pub const rule_filter = @import("rule_filter.zig");
pub const compat = @import("compat.zig");

comptime {
    _ = @import("compat.zig");
}

pub const Source = source.Source;
pub const Diagnostic = diagnostic.Diagnostic;
pub const Severity = diagnostic.Severity;
pub const Rule = rule.Rule;
pub const Checker = checker.Checker;
pub const Analyzer = analyzer.Analyzer;
pub const RuleFilter = rule_filter.RuleFilter;

pub const rules = struct {
    pub const dupe_import = @import("rules/dupe_import.zig");
    pub const todo_comment = @import("rules/todo_comment.zig");
    pub const empty_errdefer = @import("rules/empty_errdefer.zig");
    pub const empty_defer = @import("rules/empty_defer.zig");
    pub const unreachable_code = @import("rules/unreachable_code.zig");
    pub const file_as_struct = @import("rules/file_as_struct.zig");
    pub const unused_decl = @import("rules/unused_decl.zig");
    pub const shadowed_variable = @import("rules/shadowed_variable.zig");
    pub const identifier_style = @import("rules/identifier_style.zig");
    pub const sentinel_alloc = @import("rules/sentinel_alloc.zig");
    pub const unused_parameter = @import("rules/unused_parameter.zig");
    pub const return_local_pointer = @import("rules/return_local_pointer.zig");
    pub const deinit_lifecycle = @import("rules/deinit_lifecycle.zig");
};

pub const checkers = struct {
    pub const unreachable_code_checker = @import("checkers/unreachable_code_checker.zig");
    pub const store_violations_engine = @import("checkers/store_violations_engine.zig");
    pub const optional_unwrap_engine = @import("checkers/optional_unwrap_engine.zig");
    pub const stack_escape_engine = @import("checkers/stack_escape_engine.zig");
    pub const divide_by_zero_engine = @import("checkers/divide_by_zero_engine.zig");
    pub const slice_bounds_engine = @import("checkers/slice_bounds_engine.zig");
};
