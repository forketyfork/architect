const std = @import("std");
const builtin = @import("builtin");

pub const TargetArch = enum {
    x86_64,
    aarch64,
    arm,
    riscv64,
    wasm32,
    other,

    pub fn fromString(s: []const u8) TargetArch {
        if (std.mem.eql(u8, s, "x86_64")) return .x86_64;
        if (std.mem.eql(u8, s, "aarch64")) return .aarch64;
        if (std.mem.eql(u8, s, "arm")) return .arm;
        if (std.mem.eql(u8, s, "riscv64")) return .riscv64;
        if (std.mem.eql(u8, s, "wasm32")) return .wasm32;
        return .other;
    }
};

pub const TargetOS = enum {
    linux,
    windows,
    macos,
    freestanding,
    wasi,
    other,

    pub fn fromString(s: []const u8) TargetOS {
        if (std.mem.eql(u8, s, "linux")) return .linux;
        if (std.mem.eql(u8, s, "windows")) return .windows;
        if (std.mem.eql(u8, s, "macos")) return .macos;
        if (std.mem.eql(u8, s, "darwin")) return .macos;
        if (std.mem.eql(u8, s, "freestanding")) return .freestanding;
        if (std.mem.eql(u8, s, "wasi")) return .wasi;
        return .other;
    }
};

const OptimizeMode = enum {
    debug,
    release_safe,
    release_fast,
    release_small,

    pub fn fromString(s: []const u8) ?OptimizeMode {
        if (std.mem.eql(u8, s, "Debug")) return .debug;
        if (std.mem.eql(u8, s, "ReleaseSafe")) return .release_safe;
        if (std.mem.eql(u8, s, "ReleaseFast")) return .release_fast;
        if (std.mem.eql(u8, s, "ReleaseSmall")) return .release_small;
        return null;
    }
};

pub const TargetConfig = struct {
    arch: TargetArch,
    os: TargetOS,
    abi: ?[]const u8,

    pub fn init(arch: TargetArch, os: TargetOS, abi: ?[]const u8) TargetConfig {
        return .{
            .arch = arch,
            .os = os,
            .abi = abi,
        };
    }

    pub fn fromTriple(allocator: std.mem.Allocator, triple: []const u8) !TargetConfig {
        var parts = std.mem.splitScalar(u8, triple, '-');
        const arch_str = parts.next() orelse return error.InvalidTargetTriple;
        const os_str = parts.next() orelse return error.InvalidTargetTriple;
        const abi_str = parts.next();

        const abi_copy = if (abi_str) |abi| try allocator.dupe(u8, abi) else null;

        return .{
            .arch = TargetArch.fromString(arch_str),
            .os = TargetOS.fromString(os_str),
            .abi = abi_copy,
        };
    }

    pub fn deinit(self: *TargetConfig, allocator: std.mem.Allocator) void {
        if (self.abi) |abi| {
            allocator.free(abi);
        }
    }

    pub fn isHostNative(self: *const TargetConfig) bool {
        const native = builtin.target;
        const native_arch = switch (native.cpu.arch) {
            .x86_64 => TargetArch.x86_64,
            .aarch64 => TargetArch.aarch64,
            .arm => TargetArch.arm,
            .riscv64 => TargetArch.riscv64,
            .wasm32 => TargetArch.wasm32,
            else => TargetArch.other,
        };
        const native_os = switch (native.os.tag) {
            .linux => TargetOS.linux,
            .windows => TargetOS.windows,
            .macos => TargetOS.macos,
            .freestanding => TargetOS.freestanding,
            .wasi => TargetOS.wasi,
            else => TargetOS.other,
        };
        return self.arch == native_arch and self.os == native_os;
    }

    pub fn clone(self: *const TargetConfig, allocator: std.mem.Allocator) !TargetConfig {
        const abi_copy = if (self.abi) |abi| try allocator.dupe(u8, abi) else null;
        return .{
            .arch = self.arch,
            .os = self.os,
            .abi = abi_copy,
        };
    }

    pub fn eql(self: *const TargetConfig, other: *const TargetConfig) bool {
        if (self.arch != other.arch or self.os != other.os) return false;

        if (self.abi == null and other.abi == null) return true;
        if (self.abi == null or other.abi == null) return false;

        return std.mem.eql(u8, self.abi.?, other.abi.?);
    }
};

pub const BuildMetadata = struct {
    target: TargetConfig,
    optimize_mode: ?OptimizeMode,
    root_source_file: ?[]const u8,

    pub fn init(target: TargetConfig, optimize_mode: ?OptimizeMode) BuildMetadata {
        return .{
            .target = target,
            .optimize_mode = optimize_mode,
            .root_source_file = null,
        };
    }

    pub fn deinit(self: *BuildMetadata, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        if (self.root_source_file) |file| {
            allocator.free(file);
        }
    }

    pub fn fromNative() BuildMetadata {
        const native = builtin.target;
        const arch = switch (native.cpu.arch) {
            .x86_64 => TargetArch.x86_64,
            .aarch64 => TargetArch.aarch64,
            .arm => TargetArch.arm,
            .riscv64 => TargetArch.riscv64,
            .wasm32 => TargetArch.wasm32,
            else => TargetArch.other,
        };
        const os = switch (native.os.tag) {
            .linux => TargetOS.linux,
            .windows => TargetOS.windows,
            .macos => TargetOS.macos,
            .freestanding => TargetOS.freestanding,
            .wasi => TargetOS.wasi,
            else => TargetOS.other,
        };

        return .{
            .target = TargetConfig.init(arch, os, null),
            .optimize_mode = null,
            .root_source_file = null,
        };
    }

    pub fn clone(self: *const BuildMetadata, allocator: std.mem.Allocator) !BuildMetadata {
        const target_copy = try self.target.clone(allocator);
        const root_source_copy = if (self.root_source_file) |file|
            try allocator.dupe(u8, file)
        else
            null;

        return .{
            .target = target_copy,
            .optimize_mode = self.optimize_mode,
            .root_source_file = root_source_copy,
        };
    }
};

test "TargetArch.fromString" {
    try std.testing.expectEqual(TargetArch.x86_64, TargetArch.fromString("x86_64"));
    try std.testing.expectEqual(TargetArch.aarch64, TargetArch.fromString("aarch64"));
    try std.testing.expectEqual(TargetArch.arm, TargetArch.fromString("arm"));
    try std.testing.expectEqual(TargetArch.riscv64, TargetArch.fromString("riscv64"));
    try std.testing.expectEqual(TargetArch.wasm32, TargetArch.fromString("wasm32"));
    try std.testing.expectEqual(TargetArch.other, TargetArch.fromString("unknown"));
}

test "TargetOS.fromString" {
    try std.testing.expectEqual(TargetOS.linux, TargetOS.fromString("linux"));
    try std.testing.expectEqual(TargetOS.windows, TargetOS.fromString("windows"));
    try std.testing.expectEqual(TargetOS.macos, TargetOS.fromString("macos"));
    try std.testing.expectEqual(TargetOS.macos, TargetOS.fromString("darwin"));
    try std.testing.expectEqual(TargetOS.freestanding, TargetOS.fromString("freestanding"));
    try std.testing.expectEqual(TargetOS.wasi, TargetOS.fromString("wasi"));
    try std.testing.expectEqual(TargetOS.other, TargetOS.fromString("unknown"));
}

test "OptimizeMode.fromString" {
    try std.testing.expectEqual(OptimizeMode.debug, OptimizeMode.fromString("Debug").?);
    try std.testing.expectEqual(OptimizeMode.release_safe, OptimizeMode.fromString("ReleaseSafe").?);
    try std.testing.expectEqual(OptimizeMode.release_fast, OptimizeMode.fromString("ReleaseFast").?);
    try std.testing.expectEqual(OptimizeMode.release_small, OptimizeMode.fromString("ReleaseSmall").?);
    try std.testing.expectEqual(@as(?OptimizeMode, null), OptimizeMode.fromString("unknown"));
}

test "TargetConfig.fromTriple" {
    const allocator = std.testing.allocator;

    var config = try TargetConfig.fromTriple(allocator, "x86_64-linux-gnu");
    defer config.deinit(allocator);

    try std.testing.expectEqual(TargetArch.x86_64, config.arch);
    try std.testing.expectEqual(TargetOS.linux, config.os);
    try std.testing.expect(config.abi != null);
    try std.testing.expectEqualStrings("gnu", config.abi.?);
}

test "TargetConfig.fromTriple without ABI" {
    const allocator = std.testing.allocator;

    var config = try TargetConfig.fromTriple(allocator, "aarch64-macos");
    defer config.deinit(allocator);

    try std.testing.expectEqual(TargetArch.aarch64, config.arch);
    try std.testing.expectEqual(TargetOS.macos, config.os);
    try std.testing.expectEqual(@as(?[]const u8, null), config.abi);
}

test "TargetConfig.clone" {
    const allocator = std.testing.allocator;

    var original = try TargetConfig.fromTriple(allocator, "x86_64-linux-gnu");
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(original.arch, cloned.arch);
    try std.testing.expectEqual(original.os, cloned.os);
    try std.testing.expect(cloned.abi != null);
    try std.testing.expectEqualStrings(original.abi.?, cloned.abi.?);
}

test "TargetConfig.eql" {
    const allocator = std.testing.allocator;

    var config1 = try TargetConfig.fromTriple(allocator, "x86_64-linux-gnu");
    defer config1.deinit(allocator);

    var config2 = try TargetConfig.fromTriple(allocator, "x86_64-linux-gnu");
    defer config2.deinit(allocator);

    var config3 = try TargetConfig.fromTriple(allocator, "aarch64-macos");
    defer config3.deinit(allocator);

    try std.testing.expect(config1.eql(&config2));
    try std.testing.expect(!config1.eql(&config3));
}

test "BuildMetadata.fromNative" {
    const metadata = BuildMetadata.fromNative();
    try std.testing.expect(metadata.target.isHostNative());
}

test "BuildMetadata.clone" {
    const allocator = std.testing.allocator;

    const target = try TargetConfig.fromTriple(allocator, "x86_64-linux-gnu");

    var original = BuildMetadata.init(target, .debug);
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(original.optimize_mode, cloned.optimize_mode);
    try std.testing.expect(cloned.target.eql(&original.target));
}
