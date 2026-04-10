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
    });
    const assets_mod = b.createModule(.{
        .root_source_file = b.path("assets/terminfo.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("assets", assets_mod);

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

    exe.linkSystemLibrary("SDL3");
    exe.linkSystemLibrary("SDL3_ttf");
    exe.linkLibC();

    if (target.result.os.tag == .macos) {
        exe.linkSystemLibrary("proc");
        exe.linkFramework("Carbon");
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("AppKit");

        if (findSdkRoot(b)) |sdk_root| {
            const framework_path = b.fmt("{s}/System/Library/Frameworks", .{sdk_root});
            exe.addFrameworkPath(.{ .cwd_relative = framework_path });
        }
    }

    if (std.posix.getenv("SDL3_INCLUDE_PATH")) |sdl3_include| {
        exe.addIncludePath(.{ .cwd_relative = sdl3_include });
        const lib_path = b.fmt("{s}/../lib", .{sdl3_include});
        exe.addLibraryPath(.{ .cwd_relative = lib_path });
    }
    if (std.posix.getenv("SDL3_TTF_INCLUDE_PATH")) |sdl3_ttf_include| {
        exe.addIncludePath(.{ .cwd_relative = sdl3_ttf_include });
        const ttf_lib_path = b.fmt("{s}/../lib", .{sdl3_ttf_include});
        exe.addLibraryPath(.{ .cwd_relative = ttf_lib_path });
    }

    b.installArtifact(exe);

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

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Lint step using zwanzig
    if (b.lazyDependency("zwanzig", .{
        .target = target,
        .optimize = optimize,
    })) |zw| {
        const zw_exe = zw.artifact("zwanzig");
        const lint_run = b.addRunArtifact(zw_exe);
        lint_run.addArgs(&.{"src"});
        const lint_step = b.step("lint", "Run zwanzig linter");
        lint_step.dependOn(&lint_run.step);
    }
}

// Prefer the active developer selection over hardcoded SDK locations so
// macOS SDK overrides in the dev shell stay local to the environment.
fn findSdkRoot(b: *std.Build) ?[]const u8 {
    if (std.posix.getenv("SDKROOT")) |sdk_root| {
        return sdk_root;
    }

    if (findDeveloperDirSdkRoot(b)) |sdk_root| {
        return sdk_root;
    }

    if (findXcrunSdkRoot(b.allocator)) |sdk_root| {
        return sdk_root;
    }

    const candidates = [_][]const u8{
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    };

    for (candidates) |candidate| {
        if (sdkExists(candidate)) {
            return candidate;
        }
    }

    return null;
}

fn findDeveloperDirSdkRoot(b: *std.Build) ?[]const u8 {
    const developer_dir = std.posix.getenv("DEVELOPER_DIR") orelse return null;
    const candidates = [_][]const u8{
        b.fmt("{s}/SDKs/MacOSX.sdk", .{developer_dir}),
        b.fmt("{s}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", .{developer_dir}),
    };

    for (candidates) |candidate| {
        if (sdkExists(candidate)) {
            return candidate;
        }
    }

    return null;
}

fn findXcrunSdkRoot(allocator: std.mem.Allocator) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return null;
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
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

fn sdkExists(path: []const u8) bool {
    if (std.fs.openDirAbsolute(path, .{})) |dir_const| {
        var dir = dir_const;
        dir.close();
        return true;
    } else |_| {
        return false;
    }
}
