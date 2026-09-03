const std = @import("std");

pub fn build(b: *std.Build) void {
    // GitHub's macOS runners default the deployment target to the host
    // (currently 15.x), which makes release binaries fail to start on older
    // macOS versions. Pin a lower default; callers can still override with
    // -Dtarget.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .os_version_min = .{ .semver = .{ .major = 12, .minor = 0, .patch = 0 } },
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const mcp_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const control_mod = b.createModule(.{
        .root_source_file = b.path("src/app/control.zig"),
        .target = target,
        .optimize = optimize,
    });
    const env_mod = b.createModule(.{
        .root_source_file = b.path("src/env.zig"),
        .target = target,
        .optimize = optimize,
    });
    const clock_mod = b.createModule(.{
        .root_source_file = b.path("src/clock.zig"),
        .target = target,
        .optimize = optimize,
    });
    const posix_util_mod = b.createModule(.{
        .root_source_file = b.path("src/posix_util.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wake_pipe_mod = b.createModule(.{
        .root_source_file = b.path("src/wake_pipe.zig"),
        .target = target,
        .optimize = optimize,
    });
    wake_pipe_mod.addImport("posix_util.zig", posix_util_mod);
    control_mod.addImport("../env.zig", env_mod);
    control_mod.addImport("../clock.zig", clock_mod);
    control_mod.addImport("../posix_util.zig", posix_util_mod);
    control_mod.addImport("../wake_pipe.zig", wake_pipe_mod);
    mcp_mod.addImport("control", control_mod);
    const assets_mod = b.createModule(.{
        .root_source_file = b.path("assets/terminfo.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("assets", assets_mod);

    const c_sdl = addTranslateCModule(b, exe_mod, "c_sdl", "src/c/sdl.h", target, optimize);
    const pty_header = switch (target.result.os.tag) {
        .macos => "src/c/pty_macos.h",
        .freebsd => "src/c/pty_freebsd.h",
        else => "src/c/pty_linux.h",
    };
    _ = addTranslateCModule(b, exe_mod, "c_pty", pty_header, target, optimize);
    _ = addTranslateCModule(b, exe_mod, "c_stdlib", "src/c/libc_stdlib.h", target, optimize);
    _ = addTranslateCModule(b, exe_mod, "c_time", "src/c/libc_time.h", target, optimize);

    if (target.result.os.tag == .macos) {
        _ = addTranslateCModule(b, exe_mod, "c_libproc", "src/c/libproc.h", target, optimize);
        _ = addTranslateCModule(b, exe_mod, "c_sysctl", "src/c/sysctl.h", target, optimize);
    }

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("xev", dep.module("xev"));
    }

    if (b.lazyDependency("toml", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("toml", dep.module("toml"));
    }

    const exe = b.addExecutable(.{
        .name = "architect",
        .root_module = exe_mod,
    });
    const mcp_exe = b.addExecutable(.{
        .name = "architect-mcp",
        .root_module = mcp_mod,
    });

    exe_mod.linkSystemLibrary("SDL3", .{});
    exe_mod.linkSystemLibrary("SDL3_ttf", .{});

    const framework_path: ?[]const u8 = if (target.result.os.tag == .macos)
        if (findSdkRoot(b)) |sdk_root| b.fmt("{s}/System/Library/Frameworks", .{sdk_root}) else null
    else
        null;
    addSdlPaths(b, exe_mod, c_sdl, framework_path);

    if (target.result.os.tag == .macos) {
        exe.headerpad_max_install_names = true;
        mcp_exe.headerpad_max_install_names = true;

        exe_mod.linkSystemLibrary("proc", .{});
        exe_mod.linkFramework("Carbon", .{});
        exe_mod.linkFramework("CoreFoundation", .{});
        exe_mod.linkFramework("AppKit", .{});
    }

    b.installArtifact(exe);
    b.installArtifact(mcp_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const mcp_unit_tests = b.addTest(.{
        .root_module = mcp_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_mcp_unit_tests = b.addRunArtifact(mcp_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_mcp_unit_tests.step);

    // Lint step using Zwanzig. Always build the linter with ReleaseFast: it is a
    // build-time tool and Debug-mode safety/allocator overhead makes analysis
    // multiple orders of magnitude slower on x86 Linux runners.
    const zwanzig = b.dependency("zwanzig", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const run_zwanzig = b.addRunArtifact(zwanzig.artifact("zwanzig"));
    const target_triple = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });
    run_zwanzig.addArgs(&.{ "--target", target_triple, "src" });

    const lint_step = b.step("lint", "Run Zwanzig");
    lint_step.dependOn(&run_zwanzig.step);
}

fn addTranslateCModule(
    b: *std.Build,
    exe_mod: *std.Build.Module,
    name: []const u8,
    header: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.TranslateC {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path(header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport(name, translate_c.createModule());
    return translate_c;
}

fn addSdlPaths(
    b: *std.Build,
    exe_mod: *std.Build.Module,
    translate_c: *std.Build.Step.TranslateC,
    framework_path: ?[]const u8,
) void {
    if (b.graph.environ_map.get("SDL3_INCLUDE_PATH")) |sdl3_include| {
        const include_path: std.Build.LazyPath = .{ .cwd_relative = sdl3_include };
        exe_mod.addIncludePath(include_path);
        translate_c.addIncludePath(include_path);
        const lib_path = b.fmt("{s}/../lib", .{sdl3_include});
        exe_mod.addLibraryPath(.{ .cwd_relative = lib_path });
    }
    if (b.graph.environ_map.get("SDL3_TTF_INCLUDE_PATH")) |sdl3_ttf_include| {
        const include_path: std.Build.LazyPath = .{ .cwd_relative = sdl3_ttf_include };
        exe_mod.addIncludePath(include_path);
        translate_c.addIncludePath(include_path);
        const lib_path = b.fmt("{s}/../lib", .{sdl3_ttf_include});
        exe_mod.addLibraryPath(.{ .cwd_relative = lib_path });
    }
    if (framework_path) |path| {
        const framework_lazy_path: std.Build.LazyPath = .{ .cwd_relative = path };
        exe_mod.addFrameworkPath(framework_lazy_path);
        translate_c.addFrameworkPath(framework_lazy_path);
    }
}

// Prefer the active developer selection over hardcoded SDK locations so
// macOS SDK overrides in the dev shell stay local to the environment.
fn findSdkRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdk_root| {
        return sdk_root;
    }

    if (findDeveloperDirSdkRoot(b)) |sdk_root| {
        return sdk_root;
    }

    if (findXcrunSdkRoot(b.allocator, b.graph.io)) |sdk_root| {
        return sdk_root;
    }

    const candidates = [_][]const u8{
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    };

    for (candidates) |candidate| {
        if (sdkExists(b.graph.io, candidate)) {
            return candidate;
        }
    }

    return null;
}

fn findDeveloperDirSdkRoot(b: *std.Build) ?[]const u8 {
    const developer_dir = b.graph.environ_map.get("DEVELOPER_DIR") orelse return null;
    const candidates = [_][]const u8{
        b.fmt("{s}/SDKs/MacOSX.sdk", .{developer_dir}),
        b.fmt("{s}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", .{developer_dir}),
    };

    for (candidates) |candidate| {
        if (sdkExists(b.graph.io, candidate)) {
            return candidate;
        }
    }

    return null;
}

fn findXcrunSdkRoot(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    if (trimmed.len == result.stdout.len) {
        return result.stdout;
    }

    defer allocator.free(result.stdout);
    return allocator.dupe(u8, trimmed) catch null;
}

fn sdkExists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.openDirAbsolute(io, path, .{})) |dir_const| {
        var dir = dir_const;
        dir.close(io);
        return true;
    } else |_| {
        return false;
    }
}
