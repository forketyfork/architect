const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const log_level = b.option(std.log.Level, "log-level", "Set log level") orelse .info;
    const version = readPackageVersion(b);
    const main_source = if (builtin.zig_version.minor == 16)
        b.path("src/main_0_16.zig")
    else
        b.path("src/main.zig");

    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);
    options.addOption([]const u8, "version", version);

    const public_module = b.addModule("zwanzig", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = main_source,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addOptions("build_options", options);

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "zwanzig",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // Create a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the analyzer");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = main_source,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", options);

    // Create unit tests (tests embedded in source files)
    const tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Create fixture tests
    const fixture_test_module = b.createModule(.{
        .root_source_file = b.path("test/fixture_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_test_module.addImport("src", public_module);

    const fixture_tests = b.addTest(.{
        .root_module = fixture_test_module,
    });

    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    const fixture_test_step = b.step("test-fixtures", "Run fixture-based tests");
    fixture_test_step.dependOn(&run_fixture_tests.step);

    // Also run fixture tests as part of the main test step
    test_step.dependOn(&run_fixture_tests.step);

    // Check fixtures compile (validates that all fixtures are valid Zig code)
    const check_fixtures_step = b.step("check-fixtures", "Verify all test fixtures compile");
    addFixtureChecks(b, check_fixtures_step, target, optimize);
}

fn readPackageVersion(b: *std.Build) []const u8 {
    const zon_path = "build.zig.zon";
    const zon_contents: [:0]u8 = if (builtin.zig_version.minor == 16)
        std.Io.Dir.cwd().readFileAllocOptions(
            b.graph.io,
            zon_path,
            b.allocator,
            std.Io.Limit.limited(1024 * 1024),
            .of(u8),
            0,
        ) catch |err| {
            std.debug.panic("failed to read {s}: {s}", .{ zon_path, @errorName(err) });
        }
    else
        std.fs.cwd().readFileAllocOptions(
            b.allocator,
            zon_path,
            1024 * 1024,
            null,
            .of(u8),
            0,
        ) catch |err| {
            std.debug.panic("failed to read {s}: {s}", .{ zon_path, @errorName(err) });
        };

    defer b.allocator.free(zon_contents);

    const PackageMetadata = struct {
        version: []const u8,
    };

    const parsed = if (builtin.zig_version.minor == 16)
        std.zon.parse.fromSliceAlloc(
            PackageMetadata,
            b.allocator,
            zon_contents,
            null,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.panic("failed to parse {s}: {s}", .{ zon_path, @errorName(err) });
        }
    else
        std.zon.parse.fromSlice(
            PackageMetadata,
            b.allocator,
            zon_contents,
            null,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.panic("failed to parse {s}: {s}", .{ zon_path, @errorName(err) });
        };
    defer std.zon.parse.free(b.allocator, parsed);

    return b.allocator.dupe(u8, parsed.version) catch {
        std.debug.panic("failed to allocate package version", .{});
    };
}

fn addFixtureCheck(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dir_path: []const u8,
    entry_name: []const u8,
) void {
    const full_path = b.allocator.alloc(u8, dir_path.len + 1 + entry_name.len) catch return;
    @memcpy(full_path[0..dir_path.len], dir_path);
    full_path[dir_path.len] = '/';
    @memcpy(full_path[dir_path.len + 1 ..], entry_name);

    const check_module = b.createModule(.{
        .root_source_file = b.path(full_path),
        .target = target,
        .optimize = optimize,
    });

    const check = b.addObject(.{
        .name = entry_name,
        .root_module = check_module,
    });

    step.dependOn(&check.step);
}

fn addFixtureChecks(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    addFixtureCheck(b, step, target, optimize, "test/fixtures/frontend_matrix", "shared.zig");
    addFixtureCheck(
        b,
        step,
        target,
        optimize,
        "test/fixtures/frontend_matrix",
        if (builtin.zig_version.minor == 16) "zig_0_16.zig" else "zig_0_15.zig",
    );

    const fixture_dirs = [_][]const u8{
        "test/fixtures/empty_catch",
        "test/fixtures/dupe_import",
        "test/fixtures/todo_comment",
        "test/fixtures/empty_errdefer",
        "test/fixtures/empty_defer",
        "test/fixtures/unreachable_code",
        "test/fixtures/file_as_struct",
        "test/fixtures/unused_decl",
    };

    for (fixture_dirs) |dir_path| {
        if (builtin.zig_version.minor == 16) {
            var dir = std.Io.Dir.cwd().openDir(b.graph.io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(b.graph.io);

            var iter = dir.iterate();
            while (iter.next(b.graph.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                addFixtureCheck(b, step, target, optimize, dir_path, entry.name);
            }
        } else {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
            defer dir.close();

            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                addFixtureCheck(b, step, target, optimize, dir_path, entry.name);
            }
        }
    }
}
