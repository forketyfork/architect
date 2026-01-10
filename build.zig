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

    if (b.lazyDependency("tomlz", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("tomlz", dep.module("tomlz"));
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
}
