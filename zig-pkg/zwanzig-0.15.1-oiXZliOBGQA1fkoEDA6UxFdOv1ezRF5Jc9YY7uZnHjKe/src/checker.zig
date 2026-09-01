const std = @import("std");
const compat = @import("compat.zig");
const Source = @import("source.zig").Source;
const diagnostic_mod = @import("diagnostic.zig");
pub const Diagnostic = diagnostic_mod.Diagnostic;
pub const Severity = diagnostic_mod.Severity;
pub const Location = diagnostic_mod.Location;
pub const SourceRange = diagnostic_mod.SourceRange;
const Rule = @import("rule.zig").Rule;
const RuleError = @import("rule.zig").RuleError;
const BuildMetadata = @import("build_metadata.zig").BuildMetadata;
const cached_artifacts_mod = @import("cached_artifacts.zig");
const ids = @import("ids.zig");
const type_context_mod = @import("type_context.zig");
pub const TypeContext = type_context_mod.TypeContext;
pub const TypeInfo = type_context_mod.TypeInfo;
const config_mod = @import("config.zig");
pub const Config = config_mod.Config;
const cfg_mod = @import("cfg.zig");
pub const Cfg = cfg_mod.Cfg;
pub const CfgBuilder = cfg_mod.CfgBuilder;
pub const CfgError = cfg_mod.CfgError;
pub const CachedArtifacts = cached_artifacts_mod.CachedArtifacts;

pub const AnalysisStats = struct {
    total_runs: u64 = 0,
    widened_nodes: u64 = 0,
    widening_converged: u64 = 0,

    pub fn recordRun(self: *AnalysisStats) void {
        self.total_runs += 1;
    }

    pub fn recordWidening(self: *AnalysisStats, widened: u32, converged: u32) void {
        self.widened_nodes += widened;
        self.widening_converged += converged;
    }

    pub fn merge(self: *AnalysisStats, other: AnalysisStats) void {
        self.total_runs += other.total_runs;
        self.widened_nodes += other.widened_nodes;
        self.widening_converged += other.widening_converged;
    }
};

pub const AnalysisResult = struct {
    diagnostics: std.ArrayList(Diagnostic),
    stats: AnalysisStats,

    pub fn init() AnalysisResult {
        return .{
            .diagnostics = .empty,
            .stats = .{},
        };
    }

    pub fn deinit(self: *AnalysisResult, allocator: std.mem.Allocator) void {
        for (self.diagnostics.items) |*diag| {
            diag.deinit(allocator);
        }
        self.diagnostics.deinit(allocator);
    }
};

pub const AnalysisLimits = struct {
    max_worklist_steps: ?usize = null,
    max_states_per_point: ?u32 = null,
    use_widening: ?bool = null,
};

/// Context passed to checkers providing access to analyzer-level configuration
/// and type information.
///
/// The context provides:
/// - Build metadata (target info, build flags)
/// - Type context for ZIR-based type queries (when available)
/// - Config for resource models and other analyzer settings
///
/// Checkers can use the type context to make type-aware decisions,
/// reducing false positives and enabling more precise analysis.
pub const CheckerContext = struct {
    build_metadata: ?*const BuildMetadata,
    /// Type context for ZIR-based type queries.
    /// This is null if the caller did not provide a type context or ZIR generation failed.
    type_context: ?*TypeContext = null,
    analysis_stats: ?*AnalysisStats = null,
    analysis_limits: AnalysisLimits = .{},
    /// Config for resource models and other analyzer settings.
    config: ?*const Config = null,
    /// Cached CFG artifacts for this source (optional, not owned).
    cached_artifacts: ?*CachedArtifacts = null,
    /// Directory to dump CFG DOT files for visualization.
    /// When set, checkers write CFG DOT files to this directory.
    dump_cfg_dir: ?[]const u8 = null,
    /// Directory to dump exploded graph DOT files.
    /// Shows all (CFG node, state) pairs from the analysis.
    dump_exploded_graph_dir: ?[]const u8 = null,
    /// Directory to dump annotated CFG DOT files.
    /// Shows CFG with state information overlaid on nodes.
    dump_annotated_cfg_dir: ?[]const u8 = null,
    /// Directory to dump path trace DOT files.
    /// Shows paths to violations with state evolution.
    dump_path_trace_dir: ?[]const u8 = null,
    io_context: *compat.Context = compat.defaultContext(),

    /// Check if type information is available.
    pub fn hasTypeInfo(self: *const CheckerContext) bool {
        if (self.type_context) |ctx| {
            return ctx.isAvailable();
        }
        return false;
    }

    /// Get the type context if available.
    pub fn getTypeContext(self: *const CheckerContext) ?*TypeContext {
        return self.type_context;
    }

    /// Convenience: Get type info for a declaration by name.
    pub fn getDeclType(self: *const CheckerContext, name: []const u8) ?TypeInfo {
        const ctx = self.type_context orelse return null;
        return ctx.getDeclType(name);
    }

    /// Convenience: Check if a declaration is a function.
    pub fn isDeclFunction(self: *const CheckerContext, name: []const u8) bool {
        const ctx = self.type_context orelse return false;
        return ctx.isDeclFunction(name);
    }

    /// Convenience: Check if a declaration is a type.
    pub fn isDeclType(self: *const CheckerContext, name: []const u8) bool {
        const ctx = self.type_context orelse return false;
        return ctx.isDeclType(name);
    }

    /// Convenience: Classify an identifier.
    pub fn classifyIdentifier(self: *const CheckerContext, name: []const u8) TypeContext.IdentifierKind {
        const ctx = self.type_context orelse return .unknown;
        return ctx.classifyIdentifier(name);
    }

    /// Create a CfgBuilder pre-configured with the context's dump directory.
    /// The builder will automatically dump CFG DOT files when buildFromFn succeeds.
    pub fn createCfgBuilder(self: *const CheckerContext, allocator: std.mem.Allocator) CfgBuilder {
        var builder = CfgBuilder.init(allocator);
        builder.setDumpCfgDir(self.dump_cfg_dir);
        builder.setIoContext(self.io_context);
        builder.setTypeContext(self.type_context);
        return builder;
    }

    pub fn getOrBuildCfg(
        self: *const CheckerContext,
        allocator: std.mem.Allocator,
        source: *Source,
        fn_node: ids.AstNodeId,
    ) CfgError!?CfgHandle {
        if (self.cached_artifacts) |artifacts| {
            const fn_index = ids.astIndex(fn_node);
            if (artifacts.getCfg(fn_index)) |cfg_ptr| {
                return .{ .cfg = cfg_ptr, .owned = false, .allocator = allocator };
            }
        }

        var builder = self.createCfgBuilder(allocator);
        const cfg_opt = try builder.buildFromFn(source, fn_node);
        if (cfg_opt) |cfg_value| {
            const cfg_ptr = try allocator.create(Cfg);
            cfg_ptr.* = cfg_value;

            if (self.cached_artifacts) |artifacts| {
                const fn_index = ids.astIndex(fn_node);
                artifacts.addCfg(fn_index, cfg_ptr) catch |err| {
                    cfg_ptr.deinit();
                    allocator.destroy(cfg_ptr);
                    return err;
                };
                return .{ .cfg = cfg_ptr, .owned = false, .allocator = allocator };
            }

            return .{ .cfg = cfg_ptr, .owned = true, .allocator = allocator };
        }
        return null;
    }
};

pub const CfgHandle = struct {
    cfg: *const Cfg,
    owned: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CfgHandle) void {
        if (!self.owned) return;
        const cfg_ptr: *Cfg = @constCast(self.cfg);
        cfg_ptr.deinit();
        self.allocator.destroy(cfg_ptr);
    }
};

/// Error type for checker operations
pub const CheckerError = error{
    OutOfMemory,
    Overflow,
    InvalidCharacter,
};

/// The Checker interface defines hooks that are called during the analysis pipeline.
/// Checkers can implement one or more hooks to perform analysis at different stages.
///
/// Currently only AST-level hooks are supported. Future versions will add:
/// - CFG hooks for control-flow analysis
/// - IR hooks for dataflow analysis
pub const Checker = struct {
    /// Unique name identifying this checker
    name: []const u8,

    /// Default severity for diagnostics emitted by this checker
    default_severity: Severity = .err,

    /// Hook called after AST parsing to perform syntax-level analysis.
    /// Checkers can examine the full AST and emit diagnostics for detected issues.
    ///
    /// Parameters:
    /// - source: The parsed source file (AST is already cached)
    /// - allocator: Allocator for temporary data structures
    /// - diagnostics: List to append detected issues to
    /// - context: Optional context with analyzer configuration
    checkAstFn: ?*const fn (
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: CheckerContext,
    ) CheckerError!void = null,

    /// Invoke the AST check hook if defined.
    pub fn checkAst(
        self: *const Checker,
        source: *Source,
        allocator: std.mem.Allocator,
        diagnostics: *std.ArrayList(Diagnostic),
        context: CheckerContext,
    ) CheckerError!void {
        if (self.checkAstFn) |f| {
            try f(source, allocator, diagnostics, context);
        }
    }

    /// Returns true if this checker has any analysis hooks defined.
    pub fn hasHooks(self: *const Checker) bool {
        return self.checkAstFn != null;
    }
};

/// Manages checker registration and dispatch.
/// The CheckerManager owns the list of registered checkers and coordinates
/// running them against source files.
pub const CheckerManager = struct {
    allocator: std.mem.Allocator,
    checkers: std.ArrayList(*const Checker),

    pub fn init(allocator: std.mem.Allocator) CheckerManager {
        return .{
            .allocator = allocator,
            .checkers = .empty,
        };
    }

    pub fn deinit(self: *CheckerManager) void {
        self.checkers.deinit(self.allocator);
    }

    /// Register a checker with the manager.
    /// Checkers are run in registration order.
    pub fn registerChecker(self: *CheckerManager, checker: *const Checker) !void {
        try self.checkers.append(self.allocator, checker);
    }

    /// Get the number of registered checkers.
    pub fn checkerCount(self: *const CheckerManager) usize {
        return self.checkers.items.len;
    }

    /// Get a checker by name, or null if not found.
    pub fn getChecker(self: *const CheckerManager, name: []const u8) ?*const Checker {
        for (self.checkers.items) |checker| {
            if (std.mem.eql(u8, checker.name, name)) {
                return checker;
            }
        }
        return null;
    }

    /// Run all registered checkers' AST hooks on the given source.
    /// Checkers can be filtered by the provided filter function.
    ///
    /// Parameters:
    /// - source: The source file to analyze
    /// - diagnostics: List to collect diagnostics from all checkers
    /// - filter_fn: Optional function to filter which checkers run (returns true to run)
    /// - context: Context with analyzer configuration
    pub fn runAstChecks(
        self: *const CheckerManager,
        source: *Source,
        diagnostics: *std.ArrayList(Diagnostic),
        filter_fn: ?*const fn (name: []const u8) bool,
        context: CheckerContext,
    ) CheckerError!void {
        for (self.checkers.items) |checker| {
            const should_run = if (filter_fn) |f| f(checker.name) else true;
            if (should_run) {
                try checker.checkAst(source, self.allocator, diagnostics, context);
            }
        }
    }
};

/// Manages both native Checkers and legacy Rules with proper delegation.
/// This works by having the CheckerManager store both checkers and adapted rules,
/// and handle the delegation internally.
pub const CheckerManagerWithRules = struct {
    allocator: std.mem.Allocator,
    checkers: std.ArrayList(*const Checker),
    adapted_rules: std.ArrayList(*const Rule),

    pub fn init(allocator: std.mem.Allocator) CheckerManagerWithRules {
        return .{
            .allocator = allocator,
            .checkers = .empty,
            .adapted_rules = .empty,
        };
    }

    pub fn deinit(self: *CheckerManagerWithRules) void {
        self.checkers.deinit(self.allocator);
        self.adapted_rules.deinit(self.allocator);
    }

    /// Register a new-style Checker.
    pub fn registerChecker(self: *CheckerManagerWithRules, checker: *const Checker) !void {
        try self.checkers.append(self.allocator, checker);
    }

    /// Register a legacy Rule (will be called through the adapter path).
    pub fn registerRule(self: *CheckerManagerWithRules, rule: *const Rule) !void {
        try self.adapted_rules.append(self.allocator, rule);
    }

    /// Get the total number of registered checkers and rules.
    pub fn totalCount(self: *const CheckerManagerWithRules) usize {
        return self.checkers.items.len + self.adapted_rules.items.len;
    }

    /// Check if a checker or rule with the given name exists.
    pub fn hasCheckerOrRule(self: *const CheckerManagerWithRules, name: []const u8) bool {
        for (self.checkers.items) |checker| {
            if (std.mem.eql(u8, checker.name, name)) {
                return true;
            }
        }
        for (self.adapted_rules.items) |rule| {
            if (std.mem.eql(u8, rule.name, name)) {
                return true;
            }
        }
        return false;
    }

    /// Run all AST checks (both native checkers and adapted rules).
    /// Checkers are run first, then adapted rules.
    ///
    /// Parameters:
    /// - source: The source file to analyze
    /// - diagnostics: List to collect diagnostics
    /// - filter_fn: Optional filter (returns true to run the checker/rule)
    pub fn runAstChecks(
        self: *const CheckerManagerWithRules,
        source: *Source,
        diagnostics: *std.ArrayList(Diagnostic),
        filter_fn: ?*const fn (name: []const u8) bool,
        context: CheckerContext,
    ) CheckerError!void {
        // Run native checkers
        for (self.checkers.items) |checker| {
            const should_run = if (filter_fn) |f| f(checker.name) else true;
            if (should_run) {
                try checker.checkAst(source, self.allocator, diagnostics, context);
            }
        }

        // Run adapted rules
        for (self.adapted_rules.items) |rule| {
            const should_run = if (filter_fn) |f| f(rule.name) else true;
            if (should_run) {
                try rule.check(source, self.allocator, diagnostics);
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Checker basic creation" {
    const checker = Checker{
        .name = "test-checker",
        .default_severity = .warning,
    };

    try std.testing.expectEqualStrings("test-checker", checker.name);
    try std.testing.expectEqual(Severity.warning, checker.default_severity);
    try std.testing.expect(!checker.hasHooks());
}

test "Checker with checkAstFn" {
    const testCheckFn = struct {
        fn check(
            source: *Source,
            allocator: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
            context: CheckerContext,
        ) CheckerError!void {
            _ = source;
            _ = context;
            const diag = try Diagnostic.initAtLocation(
                allocator,
                "test.zig",
                "test-checker",
                .warning,
                "Test diagnostic",
                1,
                1,
            );
            try diagnostics.append(allocator, diag);
        }
    }.check;

    const checker = Checker{
        .name = "test-checker",
        .checkAstFn = testCheckFn,
    };

    try std.testing.expect(checker.hasHooks());

    const allocator = std.testing.allocator;
    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diag| diag.deinit(allocator);
        diagnostics.deinit(allocator);
    }

    const context = CheckerContext{ .build_metadata = null };
    try checker.checkAst(&source, allocator, &diagnostics, context);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("Test diagnostic", diagnostics.items[0].message);
}

test "CheckerManager registration and lookup" {
    const allocator = std.testing.allocator;

    const checker1 = Checker{ .name = "checker-1" };
    const checker2 = Checker{ .name = "checker-2" };

    var manager = CheckerManager.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker1);
    try manager.registerChecker(&checker2);

    try std.testing.expectEqual(@as(usize, 2), manager.checkerCount());

    const found = manager.getChecker("checker-1");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("checker-1", found.?.name);

    const not_found = manager.getChecker("nonexistent");
    try std.testing.expect(not_found == null);
}

test "CheckerManager runAstChecks" {
    const allocator = std.testing.allocator;

    var check_count: usize = 0;

    const CountingChecker = struct {
        var counter: *usize = undefined;

        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
            context: CheckerContext,
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            _ = context;
            counter.* += 1;
        }
    };
    CountingChecker.counter = &check_count;

    const checker = Checker{
        .name = "counting-checker",
        .checkAstFn = CountingChecker.checkFn,
    };

    var manager = CheckerManager.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    const context = CheckerContext{ .build_metadata = null };
    try manager.runAstChecks(&source, &diagnostics, null, context);
    try std.testing.expectEqual(@as(usize, 1), check_count);
}

test "CheckerManager runAstChecks with filter" {
    const allocator = std.testing.allocator;

    var check1_count: usize = 0;
    var check2_count: usize = 0;

    const Counter1 = struct {
        var counter: *usize = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
            context: CheckerContext,
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            _ = context;
            counter.* += 1;
        }
    };
    Counter1.counter = &check1_count;

    const Counter2 = struct {
        var counter: *usize = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
            context: CheckerContext,
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            _ = context;
            counter.* += 1;
        }
    };
    Counter2.counter = &check2_count;

    const checker1 = Checker{ .name = "checker-1", .checkAstFn = Counter1.checkFn };
    const checker2 = Checker{ .name = "checker-2", .checkAstFn = Counter2.checkFn };

    var manager = CheckerManager.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker1);
    try manager.registerChecker(&checker2);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    const FilterFn = struct {
        fn filter(name: []const u8) bool {
            return std.mem.eql(u8, name, "checker-1");
        }
    };

    const context = CheckerContext{ .build_metadata = null };
    try manager.runAstChecks(&source, &diagnostics, FilterFn.filter, context);

    try std.testing.expectEqual(@as(usize, 1), check1_count);
    try std.testing.expectEqual(@as(usize, 0), check2_count);
}

test "CheckerContext reuses cached CFGs across callers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const code: [:0]const u8 =
        \\fn foo() void {}
    ;
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    const tree = try source.ast();
    const root_decls = tree.rootDecls();
    try testing.expect(root_decls.len > 0);
    const fn_node = ids.astId(@intFromEnum(root_decls[0]));

    var artifacts = CachedArtifacts.init(allocator);
    defer artifacts.deinit();

    const context1 = CheckerContext{
        .build_metadata = null,
        .cached_artifacts = &artifacts,
    };
    const context2 = CheckerContext{
        .build_metadata = null,
        .cached_artifacts = &artifacts,
    };

    var handle1 = (context1.getOrBuildCfg(allocator, &source, fn_node) catch return) orelse return error.TestExpectedEqual;
    defer handle1.deinit();
    try testing.expect(!handle1.owned);

    var handle2 = (context2.getOrBuildCfg(allocator, &source, fn_node) catch return) orelse return error.TestExpectedEqual;
    defer handle2.deinit();
    try testing.expect(!handle2.owned);
    try testing.expect(handle1.cfg == handle2.cfg);

    try testing.expect(artifacts.getCfg(ids.astIndex(fn_node)) != null);
}

test "CheckerManagerWithRules mixed registration" {
    const allocator = std.testing.allocator;

    const checker = Checker{ .name = "native-checker" };

    const TestRule = struct {
        pub const rule: Rule = .{
            .name = "legacy-rule",
            .checkFn = check,
        };

        fn check(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) RuleError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
        }
    };

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);
    try manager.registerRule(&TestRule.rule);

    try std.testing.expectEqual(@as(usize, 2), manager.totalCount());
    try std.testing.expect(manager.hasCheckerOrRule("native-checker"));
    try std.testing.expect(manager.hasCheckerOrRule("legacy-rule"));
    try std.testing.expect(!manager.hasCheckerOrRule("nonexistent"));
}

test "CheckerManagerWithRules runAstChecks with both types" {
    const allocator = std.testing.allocator;

    var checker_ran = false;
    var rule_ran = false;

    const CheckerState = struct {
        var ran: *bool = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
            context: CheckerContext,
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            _ = context;
            ran.* = true;
        }
    };
    CheckerState.ran = &checker_ran;

    const RuleState = struct {
        var ran: *bool = undefined;
        pub const rule: Rule = .{
            .name = "legacy-rule",
            .checkFn = check,
        };

        fn check(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) RuleError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            ran.* = true;
        }
    };
    RuleState.ran = &rule_ran;

    const checker = Checker{ .name = "native-checker", .checkAstFn = CheckerState.checkFn };

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);
    try manager.registerRule(&RuleState.rule);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    const context = CheckerContext{ .build_metadata = null };
    try manager.runAstChecks(&source, &diagnostics, null, context);

    try std.testing.expect(checker_ran);
    try std.testing.expect(rule_ran);
}

test "CheckerManagerWithRules filter applies to both" {
    const allocator = std.testing.allocator;

    var checker_ran = false;
    var rule_ran = false;

    const CheckerState = struct {
        var ran: *bool = undefined;
        fn checkFn(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
            context: CheckerContext,
        ) CheckerError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            _ = context;
            ran.* = true;
        }
    };
    CheckerState.ran = &checker_ran;

    const RuleState = struct {
        var ran: *bool = undefined;
        pub const rule: Rule = .{
            .name = "legacy-rule",
            .checkFn = check,
        };

        fn check(
            source: *Source,
            alloc: std.mem.Allocator,
            diagnostics: *std.ArrayList(Diagnostic),
        ) RuleError!void {
            _ = source;
            _ = alloc;
            _ = diagnostics;
            ran.* = true;
        }
    };
    RuleState.ran = &rule_ran;

    const checker = Checker{ .name = "native-checker", .checkAstFn = CheckerState.checkFn };

    var manager = CheckerManagerWithRules.init(allocator);
    defer manager.deinit();

    try manager.registerChecker(&checker);
    try manager.registerRule(&RuleState.rule);

    const code: [:0]const u8 = "const x = 42;";
    var source = Source.init(allocator, "test.zig", code);
    defer source.deinit();

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    const FilterFn = struct {
        fn filter(name: []const u8) bool {
            return std.mem.eql(u8, name, "legacy-rule");
        }
    };

    const context = CheckerContext{ .build_metadata = null };
    try manager.runAstChecks(&source, &diagnostics, FilterFn.filter, context);

    try std.testing.expect(!checker_ran);
    try std.testing.expect(rule_ran);
}
