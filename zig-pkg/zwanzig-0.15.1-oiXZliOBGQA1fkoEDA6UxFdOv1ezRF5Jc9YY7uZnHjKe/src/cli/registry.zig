const analyzer_mod = @import("../analyzer.zig");
const DupeImportRule = @import("../rules/dupe_import.zig").DupeImportRule;
const TodoCommentRule = @import("../rules/todo_comment.zig").TodoCommentRule;
const FileAsStructRule = @import("../rules/file_as_struct.zig").FileAsStructRule;
const UnusedDeclRule = @import("../rules/unused_decl.zig").UnusedDeclRule;
const UnreachableCodeRule = @import("../rules/unreachable_code.zig").UnreachableCodeRule;
const EmptyDeferRule = @import("../rules/empty_defer.zig").EmptyDeferRule;
const EmptyErrdeferRule = @import("../rules/empty_errdefer.zig").EmptyErrdeferRule;
const ShadowedVariableRule = @import("../rules/shadowed_variable.zig").ShadowedVariableRule;
const IdentifierStyleRule = @import("../rules/identifier_style.zig").IdentifierStyleRule;
const SentinelAllocRule = @import("../rules/sentinel_alloc.zig").SentinelAllocRule;
const UnusedParameterRule = @import("../rules/unused_parameter.zig").UnusedParameterRule;
const ReturnLocalPointerRule = @import("../rules/return_local_pointer.zig").ReturnLocalPointerRule;
const DeinitLifecycleRule = @import("../rules/deinit_lifecycle.zig").DeinitLifecycleRule;
const EmptyCatchEngineChecker = @import("../checkers/empty_catch_engine.zig").EmptyCatchEngineChecker;
const OptionalUnwrapEngineChecker = @import("../checkers/optional_unwrap_engine.zig").OptionalUnwrapEngineChecker;
const SwallowedErrorChecker = @import("../checkers/swallowed_error.zig").SwallowedErrorChecker;
const UnreachableCodeChecker = @import("../checkers/unreachable_code_checker.zig").UnreachableCodeChecker;
const StoreViolationsEngineChecker = @import("../checkers/store_violations_engine.zig").StoreViolationsEngineChecker;
const StackEscapeEngineChecker = @import("../checkers/stack_escape_engine.zig").StackEscapeEngineChecker;
const DivideByZeroEngineChecker = @import("../checkers/divide_by_zero_engine.zig").DivideByZeroEngineChecker;
const SliceBoundsEngineChecker = @import("../checkers/slice_bounds_engine.zig").SliceBoundsEngineChecker;

const Analyzer = analyzer_mod.Analyzer;

pub fn registerDefaults(analyzer: *Analyzer) !void {
    try analyzer.registerRule(&DupeImportRule.rule);
    try analyzer.registerRule(&TodoCommentRule.rule);
    try analyzer.registerRule(&FileAsStructRule.rule);
    try analyzer.registerRule(&UnusedDeclRule.rule);
    try analyzer.registerRule(&UnreachableCodeRule.rule);
    try analyzer.registerRule(&EmptyDeferRule.rule);
    try analyzer.registerRule(&EmptyErrdeferRule.rule);
    try analyzer.registerRule(&ShadowedVariableRule.rule);
    try analyzer.registerRule(&IdentifierStyleRule.rule);
    try analyzer.registerRule(&SentinelAllocRule.rule);
    try analyzer.registerRule(&UnusedParameterRule.rule);
    try analyzer.registerRule(&ReturnLocalPointerRule.rule);
    try analyzer.registerRule(&DeinitLifecycleRule.rule);

    // Engine-based checkers
    try analyzer.registerChecker(&EmptyCatchEngineChecker.checker);
    try analyzer.registerChecker(&OptionalUnwrapEngineChecker.checker);
    try analyzer.registerChecker(&SwallowedErrorChecker.checker);
    try analyzer.registerChecker(&UnreachableCodeChecker.checker);
    try analyzer.registerChecker(&StoreViolationsEngineChecker.checker);
    try analyzer.registerChecker(&StackEscapeEngineChecker.checker);
    try analyzer.registerChecker(&DivideByZeroEngineChecker.checker);
    try analyzer.registerChecker(&SliceBoundsEngineChecker.checker);
}
