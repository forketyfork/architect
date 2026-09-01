const std = @import("std");
const compat = @import("compat.zig");
const Rule = @import("rule.zig").Rule;
const Diagnostic = @import("rule.zig").Diagnostic;
const Source = @import("source.zig").Source;
const RuleFilter = @import("rule_filter.zig").RuleFilter;
const checker_mod = @import("checker.zig");
const Checker = checker_mod.Checker;
const CheckerManagerWithRules = checker_mod.CheckerManagerWithRules;
const TypeContext = checker_mod.TypeContext;
const Config = checker_mod.Config;
pub const AnalysisResult = checker_mod.AnalysisResult;
pub const AnalysisStats = checker_mod.AnalysisStats;
const BuildMetadata = @import("build_metadata.zig").BuildMetadata;
const cache_mod = @import("cache.zig");
const Cache = cache_mod.Cache;
const CacheKey = cache_mod.CacheKey;
const cached_artifacts_mod = @import("cached_artifacts.zig");
const CachedArtifacts = cached_artifacts_mod.CachedArtifacts;
const ConsoleFormatter = @import("formatters/console.zig").ConsoleFormatter;
const SarifFormatter = @import("formatters/sarif.zig").SarifFormatter;
const log = std.log.scoped(.analyzer);
const diagnostic_mod = @import("diagnostic.zig");
const suppression = @import("suppression.zig");
const project_unused_decl = @import("project_unused_decl.zig");

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    checker_manager: CheckerManagerWithRules,
    diagnostics: std.ArrayList(Diagnostic),
    rule_filter: RuleFilter,
    tool_version: []const u8 = "unknown",
    build_metadata: ?BuildMetadata = null,
    cache: ?Cache = null,
    use_cache: bool = false,
    analysis_stats: checker_mod.AnalysisStats = .{},
    max_worklist_steps: ?usize = null,
    max_states_per_point: ?u32 = null,
    use_widening: ?bool = null,
    config: ?Config = null,
    dump_cfg_dir: ?[]const u8 = null,
    dump_exploded_graph_dir: ?[]const u8 = null,
    dump_annotated_cfg_dir: ?[]const u8 = null,
    dump_path_trace_dir: ?[]const u8 = null,
    io_context: ?*compat.Context = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return Analyzer{
            .allocator = allocator,
            .checker_manager = CheckerManagerWithRules.init(allocator),
            .diagnostics = .empty,
            .rule_filter = .none,
        };
    }

    pub fn initWithContext(allocator: std.mem.Allocator, io_context: *compat.Context) Analyzer {
        var analyzer = init(allocator);
        analyzer.io_context = io_context;
        return analyzer;
    }

    pub fn setIoContext(self: *Analyzer, io_context: *compat.Context) void {
        self.io_context = io_context;
    }

    pub fn getIoContext(self: *Analyzer) *compat.Context {
        return self.io_context orelse compat.defaultContext();
    }

    pub fn deinit(self: *Analyzer) void {
        self.checker_manager.deinit();
        for (self.diagnostics.items) |*diag| {
            diag.deinit(self.allocator);
        }
        self.diagnostics.deinit(self.allocator);
        if (self.build_metadata) |*meta| {
            var meta_mut = meta.*;
            meta_mut.deinit(self.allocator);
        }
        if (self.cache) |*c| {
            c.deinit();
        }
    }

    /// Enable incremental caching.
    pub fn enableCache(self: *Analyzer) !void {
        self.use_cache = true;
        if (self.cache == null) {
            self.cache = try Cache.init(self.allocator, self.getIoContext());
        }
    }

    /// Register a legacy Rule with the analyzer.
    /// The rule will be wrapped and run through the CheckerManager.
    pub fn registerRule(self: *Analyzer, rule: *const Rule) !void {
        try self.checker_manager.registerRule(rule);
    }

    /// Register a new-style Checker with the analyzer.
    pub fn registerChecker(self: *Analyzer, chkr: *const Checker) !void {
        try self.checker_manager.registerChecker(chkr);
    }

    pub fn setRuleFilter(self: *Analyzer, filter: RuleFilter) void {
        self.rule_filter = filter;
    }

    pub fn setToolVersion(self: *Analyzer, version: []const u8) void {
        self.tool_version = version;
    }

    pub fn setBuildMetadata(self: *Analyzer, metadata: BuildMetadata) !void {
        if (self.build_metadata) |*meta| {
            var meta_mut = meta.*;
            meta_mut.deinit(self.allocator);
        }
        self.build_metadata = try metadata.clone(self.allocator);
    }

    pub fn setMaxWorklistSteps(self: *Analyzer, steps: usize) void {
        self.max_worklist_steps = steps;
    }

    pub fn setMaxStatesPerPoint(self: *Analyzer, max: u32) void {
        self.max_states_per_point = max;
    }

    pub fn setUseWidening(self: *Analyzer, use_w: bool) void {
        self.use_widening = use_w;
    }

    pub fn setDumpCfgDir(self: *Analyzer, dir: []const u8) void {
        self.dump_cfg_dir = dir;
    }

    pub fn setDumpExplodedGraphDir(self: *Analyzer, dir: []const u8) void {
        self.dump_exploded_graph_dir = dir;
    }

    pub fn setDumpAnnotatedCfgDir(self: *Analyzer, dir: []const u8) void {
        self.dump_annotated_cfg_dir = dir;
    }

    pub fn setDumpPathTraceDir(self: *Analyzer, dir: []const u8) void {
        self.dump_path_trace_dir = dir;
    }

    /// Set the config for resource models and other settings.
    pub fn setConfig(self: *Analyzer, cfg: Config) void {
        self.config = cfg;
    }

    /// Get the config if set.
    pub fn getConfig(self: *const Analyzer) ?*const Config {
        if (self.config) |*cfg| {
            return cfg;
        }
        return null;
    }

    pub fn getBuildMetadata(self: *const Analyzer) ?*const BuildMetadata {
        if (self.build_metadata) |*meta| {
            return meta;
        }
        return null;
    }

    pub fn logAnalysisStats(self: *const Analyzer) void {
        if (self.analysis_stats.widened_nodes > 0 or self.analysis_stats.widening_converged > 0) {
            log.info("widening: {d} node(s) widened, {d} converged across {d} engine run(s)", .{
                self.analysis_stats.widened_nodes,
                self.analysis_stats.widening_converged,
                self.analysis_stats.total_runs,
            });
        }
    }

    pub fn isRuleEnabled(self: *const Analyzer, rule_name: []const u8) bool {
        switch (self.rule_filter) {
            .none => return true,
            .allowlist => |list| {
                return containsRuleName(list, rule_name);
            },
            .blocklist => |list| {
                for (list) |blocked| {
                    if (std.mem.eql(u8, rule_name, blocked)) {
                        return false;
                    }
                }
                return true;
            },
        }
    }

    fn containsRuleName(list: []const []const u8, rule_name: []const u8) bool {
        for (list) |item| {
            if (std.mem.eql(u8, rule_name, item)) return true;
        }
        return false;
    }

    fn ruleNameLess(a: []const u8, b: []const u8) bool {
        const min_len = if (a.len < b.len) a.len else b.len;
        var i: usize = 0;
        while (i < min_len) : (i += 1) {
            if (a[i] < b[i]) return true;
            if (a[i] > b[i]) return false;
        }
        return a.len < b.len;
    }

    fn sortRuleNames(names: [][]const u8) void {
        var i: usize = 0;
        while (i < names.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < names.len) : (j += 1) {
                if (ruleNameLess(names[j], names[i])) {
                    const tmp = names[i];
                    names[i] = names[j];
                    names[j] = tmp;
                }
            }
        }
    }

    pub fn shouldRunProjectUnusedDecls(self: *const Analyzer) bool {
        return self.isRuleEnabled("unused-decl");
    }

    pub fn analyzeProjectUnusedDecls(self: *Analyzer, files: []const []const u8) !void {
        if (!self.shouldRunProjectUnusedDecls()) return;
        try project_unused_decl.analyze(self.getIoContext(), self.allocator, files, &self.diagnostics);
        std.mem.sort(Diagnostic, self.diagnostics.items, {}, Diagnostic.lessThan);
    }

    pub fn analyzeFile(self: *Analyzer, file_path: []const u8) !void {
        var result = try self.analyzeFileResult(file_path);
        errdefer result.deinit(self.allocator);
        try self.mergeResult(&result);
    }

    pub fn mergeResult(self: *Analyzer, result: *AnalysisResult) !void {
        self.analysis_stats.merge(result.stats);
        // Reserve capacity upfront so append can't fail mid-way.
        // This prevents use-after-free on error: if ensureUnusedCapacity fails,
        // we haven't moved any diagnostics yet, so errdefer in analyzeFile
        // can safely free result's diagnostics.
        try self.diagnostics.ensureUnusedCapacity(self.allocator, result.diagnostics.items.len);
        for (result.diagnostics.items) |diag| {
            self.diagnostics.appendAssumeCapacity(diag);
        }
        // Only free the backing array, not the diagnostics (now owned by self)
        result.diagnostics.deinit(self.allocator);
        result.diagnostics = .empty;
    }

    /// Analyze a single file and return an isolated AnalysisResult.
    /// This method does not mutate any shared state in the Analyzer,
    /// making it safe to call in parallel (once thread-safety is added).
    pub fn analyzeFileResult(self: *Analyzer, file_path: []const u8) !AnalysisResult {
        return self.analyzeFileResultWithScratchAllocator(file_path, self.allocator);
    }

    /// Analyze a single file using a scratch allocator for temporary data.
    /// The scratch_allocator is used for heavy temporary allocations (file content,
    /// AST parsing, etc.) while self.allocator is used for persistent data like
    /// diagnostic strings. This enables efficient parallel analysis by allowing
    /// each worker thread to use its own arena allocator for scratch memory.
    pub fn analyzeFileResultWithScratchAllocator(
        self: *Analyzer,
        file_path: []const u8,
        scratch_allocator: std.mem.Allocator,
    ) !AnalysisResult {
        log.debug("analyzeResult: start {s}", .{file_path});

        const max_size = 10 * 1024 * 1024;
        // Sentinel needed for Source.init; free accounts for sentinel byte below
        // zwanzig-disable-next-line: sentinel-alloc
        const content = try compat.readFileAlloc(self.getIoContext(), scratch_allocator, file_path, max_size);
        defer scratch_allocator.free(content.ptr[0 .. content.len + 1]);

        var source = Source.init(scratch_allocator, file_path, content);
        defer source.deinit();
        const type_info_available = source.hasTypeInfo();

        var cached_artifacts: ?CachedArtifacts = null;
        defer if (cached_artifacts) |*ca| ca.deinit();

        var cache_key: ?CacheKey = null;
        var enabled_rules_buf: std.ArrayList([]const u8) = .empty;
        defer enabled_rules_buf.deinit(scratch_allocator);

        if (self.use_cache) {
            for (self.checker_manager.checkers.items) |chkr| {
                if (self.isRuleEnabled(chkr.name)) {
                    try enabled_rules_buf.append(scratch_allocator, chkr.name);
                }
            }
            for (self.checker_manager.adapted_rules.items) |rule| {
                if (self.isRuleEnabled(rule.name)) {
                    try enabled_rules_buf.append(scratch_allocator, rule.name);
                }
            }

            sortRuleNames(enabled_rules_buf.items);
            const key = CacheKey.init(
                content,
                self.getBuildMetadata(),
                self.tool_version,
                type_info_available,
                enabled_rules_buf.items,
            );
            cache_key = key;
            if (self.cache) |*c| {
                if (try c.get(key)) |cached_data| {
                    defer self.allocator.free(cached_data);
                    log.debug("analyzeResult: cache hit {s}, loading artifacts", .{file_path});

                    cached_artifacts = CachedArtifacts.deserialize(scratch_allocator, cached_data) catch |err| blk: {
                        log.debug("analyzeResult: failed to deserialize cached artifacts: {}", .{err});
                        break :blk null;
                    };
                }
            }
        }

        if (cached_artifacts == null) {
            cached_artifacts = CachedArtifacts.init(scratch_allocator);
            if (cached_artifacts) |*artifacts| {
                artifacts.had_type_info = type_info_available;
            }
        }

        // Initialize result early so we can use its stats field
        var result = AnalysisResult.init();
        errdefer result.deinit(self.allocator);

        // Use a temporary list for diagnostics created with scratch allocator
        var scratch_diagnostics: std.ArrayList(Diagnostic) = .empty;
        defer {
            // Free diagnostic messages before freeing the list
            for (scratch_diagnostics.items) |*diag| {
                diag.deinit(scratch_allocator);
            }
            scratch_diagnostics.deinit(scratch_allocator);
        }

        if (cached_artifacts) |*artifacts| {
            try self.runChecksOnSource(&source, scratch_allocator, artifacts, &scratch_diagnostics, &result.stats);
        }

        try filterDiagnosticsWithSuppressions(scratch_allocator, content, &scratch_diagnostics);

        // Transfer diagnostics from scratch allocator to persistent allocator
        for (scratch_diagnostics.items) |diag| {
            const cloned = try diag.clone(self.allocator);
            try result.diagnostics.append(self.allocator, cloned);
        }

        if (self.use_cache and cache_key != null) {
            if (self.cache) |*c| {
                if (cached_artifacts) |*artifacts| {
                    const serialized = artifacts.serialize(scratch_allocator) catch |err| {
                        log.debug("analyzeResult: failed to serialize artifacts: {}", .{err});
                        return result;
                    };
                    defer scratch_allocator.free(serialized);

                    c.put(cache_key.?, serialized) catch |err| {
                        log.debug("analyzeResult: failed to cache artifacts: {}", .{err});
                    };
                }
            }
        }

        log.debug("analyzeResult: done {s}", .{file_path});
        return result;
    }

    /// Filter suppressed diagnostics in a standalone list.
    fn filterDiagnosticsWithSuppressions(
        allocator: std.mem.Allocator,
        content: [:0]const u8,
        diagnostics: *std.ArrayList(Diagnostic),
    ) !void {
        var sup_map = try suppression.parseSuppressions(allocator, content);
        defer sup_map.deinit();

        var write_index: usize = 0;
        for (diagnostics.items) |*diag| {
            if (!sup_map.isSuppressed(diag.range.start.line, diag.rule_id)) {
                diagnostics.items[write_index] = diag.*;
                write_index += 1;
            } else {
                diag.deinit(allocator);
            }
        }
        diagnostics.shrinkRetainingCapacity(write_index);
    }

    /// Internal method to run checks on a source with the analyzer's filter.
    /// Accepts explicit diagnostics and stats parameters for isolation.
    /// The scratch_allocator is used for temporary allocations during analysis.
    fn runChecksOnSource(
        self: *Analyzer,
        source: *Source,
        scratch_allocator: std.mem.Allocator,
        cached_artifacts: *CachedArtifacts,
        diagnostics: *std.ArrayList(Diagnostic),
        analysis_stats: *checker_mod.AnalysisStats,
    ) !void {
        var type_ctx = TypeContext.init(scratch_allocator, source);
        defer type_ctx.deinit();
        log.debug("type context: created for {s}, available={}", .{
            source.getFilePath(),
            type_ctx.isAvailable(),
        });

        const context = checker_mod.CheckerContext{
            .build_metadata = self.getBuildMetadata(),
            .type_context = &type_ctx,
            .analysis_stats = analysis_stats,
            .analysis_limits = .{
                .max_worklist_steps = self.max_worklist_steps,
                .max_states_per_point = self.max_states_per_point,
                .use_widening = self.use_widening,
            },
            .config = self.getConfig(),
            .cached_artifacts = cached_artifacts,
            .dump_cfg_dir = self.dump_cfg_dir,
            .dump_exploded_graph_dir = self.dump_exploded_graph_dir,
            .dump_annotated_cfg_dir = self.dump_annotated_cfg_dir,
            .dump_path_trace_dir = self.dump_path_trace_dir,
            .io_context = self.getIoContext(),
        };

        // Run native checkers
        for (self.checker_manager.checkers.items) |chkr| {
            if (self.isRuleEnabled(chkr.name)) {
                log.debug("checker: start {s} ({s})", .{ source.getFilePath(), chkr.name });
                try chkr.checkAst(source, scratch_allocator, diagnostics, context);
                log.debug("checker: done {s} ({s})", .{ source.getFilePath(), chkr.name });
            }
        }

        // Run adapted rules
        for (self.checker_manager.adapted_rules.items) |rule| {
            if (self.isRuleEnabled(rule.name)) {
                log.debug("rule: start {s} ({s})", .{ source.getFilePath(), rule.name });
                try rule.check(source, scratch_allocator, diagnostics);
                log.debug("rule: done {s} ({s})", .{ source.getFilePath(), rule.name });
            }
        }
    }

    pub const OutputFormat = enum {
        text,
        json,
        sarif,
    };

    pub fn printResults(self: *Analyzer, format: OutputFormat) !void {
        var stdout: compat.OutputWriter = undefined;
        stdout.init(self.getIoContext(), false);
        defer stdout.deinit();
        const writer = stdout.writer();

        switch (format) {
            .json => try self.printJsonResults(writer),
            .text => {
                var formatter = ConsoleFormatter.init(self.allocator, self.getIoContext());
                try formatter.write(writer, self.diagnostics.items);
            },
            .sarif => {
                var formatter = SarifFormatter.init(
                    self.allocator,
                    &self.checker_manager,
                    self.tool_version,
                    self.diagnostics.items,
                );
                try formatter.write(writer);
            },
        }
        try stdout.flush();
    }

    fn printJsonResults(self: *Analyzer, writer: *std.Io.Writer) !void {
        var alloc_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer alloc_writer.deinit();

        var jw: std.json.Stringify = .{
            .writer = &alloc_writer.writer,
            .options = .{ .whitespace = .indent_2 },
        };

        try jw.beginObject();
        try jw.objectField("diagnostics");
        try jw.beginArray();
        for (self.diagnostics.items) |diag| {
            try diag.writeJsonValue(&jw);
        }
        try jw.endArray();
        try jw.objectField("total");
        try jw.write(self.diagnostics.items.len);
        try jw.endObject();

        try writer.writeAll(alloc_writer.written());
        try writer.writeByte('\n');
    }

    pub fn hasDiagnostics(self: *Analyzer) bool {
        return self.diagnostics.items.len > 0;
    }

    /// Get the total number of registered checkers and rules.
    pub fn totalCheckerCount(self: *const Analyzer) usize {
        return self.checker_manager.totalCount();
    }
};

test "Analyzer JSON output format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const diagnostic = diagnostic_mod;
    const Location = diagnostic.Location;
    const SourceRange = diagnostic.SourceRange;

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const diag1 = try Diagnostic.init(
        allocator,
        "test1.zig",
        "test-rule",
        .err,
        "Test error",
        SourceRange.init(Location.init(1, 1), Location.init(1, 5)),
    );

    const diag2 = try Diagnostic.init(
        allocator,
        "test2.zig",
        "other-rule",
        .warning,
        "Test warning",
        SourceRange.init(Location.init(2, 3), Location.init(2, 8)),
    );

    try analyzer.diagnostics.append(allocator, diag1);
    try analyzer.diagnostics.append(allocator, diag2);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try analyzer.printJsonResults(&writer);

    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "\"diagnostics\":") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"total\": 2") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test1.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test2.zig") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test-rule") != null);
    try testing.expect(std.mem.indexOf(u8, output, "other-rule") != null);
}

test "Analyzer.isRuleEnabled: no filter" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.isRuleEnabled("empty-catch"));
    try std.testing.expect(analyzer.isRuleEnabled("any-rule"));
}

test "Analyzer.isRuleEnabled: allowlist" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const allowlist = [_][]const u8{ "empty-catch", "unused-var" };
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });

    try std.testing.expect(analyzer.isRuleEnabled("empty-catch"));
    try std.testing.expect(analyzer.isRuleEnabled("unused-var"));
    try std.testing.expect(!analyzer.isRuleEnabled("other-rule"));
}

test "Analyzer.isRuleEnabled: blocklist" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const blocklist = [_][]const u8{ "empty-catch", "unused-var" };
    analyzer.setRuleFilter(.{ .blocklist = &blocklist });

    try std.testing.expect(!analyzer.isRuleEnabled("empty-catch"));
    try std.testing.expect(!analyzer.isRuleEnabled("unused-var"));
    try std.testing.expect(analyzer.isRuleEnabled("other-rule"));
}

test "Analyzer.shouldRunProjectUnusedDecls follows rule filter" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    try std.testing.expect(analyzer.shouldRunProjectUnusedDecls());

    const allowlist = [_][]const u8{"todo"};
    analyzer.setRuleFilter(.{ .allowlist = &allowlist });
    try std.testing.expect(!analyzer.shouldRunProjectUnusedDecls());

    const project_allowlist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .allowlist = &project_allowlist });
    try std.testing.expect(analyzer.shouldRunProjectUnusedDecls());

    const blocklist = [_][]const u8{"unused-decl"};
    analyzer.setRuleFilter(.{ .blocklist = &blocklist });
    try std.testing.expect(!analyzer.shouldRunProjectUnusedDecls());
}

test "Analyzer text output format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const diagnostic = diagnostic_mod;
    const Location = diagnostic.Location;
    const SourceRange = diagnostic.SourceRange;

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const diag = try Diagnostic.init(
        allocator,
        "test.zig",
        "test-rule",
        .err,
        "Test error",
        SourceRange.init(Location.init(1, 1), Location.init(1, 5)),
    );

    try analyzer.diagnostics.append(allocator, diag);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var formatter = ConsoleFormatter.init(allocator, analyzer.getIoContext());
    try formatter.write(&writer, analyzer.diagnostics.items);

    const output = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, output, "Found 1 issue(s):") != null);
    try testing.expect(std.mem.indexOf(u8, output, "test.zig:1:1") != null);
}

test "Analyzer SARIF output format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const diagnostic = diagnostic_mod;
    const Location = diagnostic.Location;
    const SourceRange = diagnostic.SourceRange;

    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();

    const diag1 = try Diagnostic.init(
        allocator,
        "test1.zig",
        "test-rule",
        .err,
        "Test error",
        SourceRange.init(Location.init(1, 1), Location.init(1, 5)),
    );

    const diag2 = try Diagnostic.init(
        allocator,
        "test2.zig",
        "other-rule",
        .warning,
        "Test warning",
        SourceRange.init(Location.init(2, 3), Location.init(2, 8)),
    );

    try analyzer.diagnostics.append(allocator, diag1);
    try analyzer.diagnostics.append(allocator, diag2);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var formatter = SarifFormatter.init(allocator, &analyzer.checker_manager, analyzer.tool_version, analyzer.diagnostics.items);
    try formatter.write(&output.writer);

    const result = output.written();
    try testing.expect(std.mem.indexOf(u8, result, "\"version\": \"2.1.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"$schema\":") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"runs\":") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"tool\":") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"driver\":") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\": \"Zwanzig\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"rules\":") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"results\":") != null);
    try testing.expect(std.mem.indexOf(u8, result, "test1.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result, "test2.zig") != null);
    try testing.expect(std.mem.indexOf(u8, result, "test-rule") != null);
    try testing.expect(std.mem.indexOf(u8, result, "other-rule") != null);
}

test "Analyzer cache enabled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var io_context = try compat.Context.init(allocator, 1);
    defer io_context.deinit();
    try compat.makePath(&io_context, ".zwanzig-cache");
    defer compat.deleteTree(&io_context, ".zwanzig-cache") catch |err| {
        log.warn("failed to clean up test directory: {}", .{err});
    };

    var analyzer = Analyzer.initWithContext(allocator, &io_context);
    defer analyzer.deinit();

    try analyzer.enableCache();
    try testing.expect(analyzer.use_cache);
    try testing.expect(analyzer.cache != null);
}

test "Analyzer cache hit still produces diagnostics" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const DupeImportRule = @import("rules/dupe_import.zig").DupeImportRule;

    var io_context = try compat.Context.init(allocator, 1);
    defer io_context.deinit();
    var tmp_dir = compat.TestDir.init();
    defer tmp_dir.cleanup();

    // File with duplicate imports to trigger a diagnostic
    const test_file_content =
        \\const std = @import("std");
        \\const std2 = @import("std");
    ;
    try tmp_dir.writeFile("test.zig", test_file_content);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_file_path = try std.fmt.bufPrint(&path_buf, "{s}/test.zig", .{tmp_dir.path()});

    var first_run_diag_count: usize = 0;

    // First run - populates cache
    {
        var analyzer1 = Analyzer.initWithContext(allocator, &io_context);
        defer analyzer1.deinit();
        try analyzer1.enableCache();
        try analyzer1.registerRule(&DupeImportRule.rule);

        try analyzer1.analyzeFile(test_file_path);
        first_run_diag_count = analyzer1.diagnostics.items.len;
        try testing.expect(first_run_diag_count > 0);
    }

    // Second run - should hit cache but still produce same diagnostics
    {
        var analyzer2 = Analyzer.initWithContext(allocator, &io_context);
        defer analyzer2.deinit();
        try analyzer2.enableCache();
        try analyzer2.registerRule(&DupeImportRule.rule);

        try analyzer2.analyzeFile(test_file_path);
        try testing.expectEqual(first_run_diag_count, analyzer2.diagnostics.items.len);
    }
}
