// Hook manager for installing/uninstalling Architect hooks for AI assistants.
// Supports Claude Code, Codex, and Gemini CLI.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

const Tool = cli.Tool;

pub const HookError = error{
    HomeNotFound,
    ScriptNotFound,
    CopyFailed,
    ConfigReadFailed,
    ConfigWriteFailed,
    JsonParseFailed,
    OutOfMemory,
    InvalidPath,
    HookSkipped,
};

const ScriptInfo = struct {
    name: []const u8,
    dest_name: []const u8,
};

fn writeJsonToFile(file: std.fs.File, value: std.json.Value) !void {
    var write_buffer: [4096]u8 = undefined;
    var file_writer = std.fs.File.Writer.init(file, &write_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

fn getScriptsForTool(tool: Tool) []const ScriptInfo {
    return switch (tool) {
        .claude, .codex => &[_]ScriptInfo{
            .{ .name = "architect_notify.py", .dest_name = "architect_notify.py" },
        },
        .gemini => &[_]ScriptInfo{
            .{ .name = "architect_notify.py", .dest_name = "architect_notify.py" },
            .{ .name = "architect_hook_gemini.py", .dest_name = "architect_hook.py" },
        },
    };
}

fn getHomeDir() ?[]const u8 {
    return std.posix.getenv("HOME");
}

fn findScriptsDir(allocator: std.mem.Allocator) !?[]u8 {
    // Try relative to executable first (for installed binaries)
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch null;
    if (exe_path) |path| {
        if (std.fs.path.dirname(path)) |exe_dir| {
            // Check ../share/architect/scripts (standard install location)
            const share_path = try std.fs.path.join(allocator, &.{ exe_dir, "..", "share", "architect", "scripts" });
            defer allocator.free(share_path);
            var resolve_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.cwd().realpath(share_path, &resolve_buf)) |p| {
                return try allocator.dupe(u8, p);
            } else |_| {}

            // Check ../scripts (development layout)
            const dev_path = try std.fs.path.join(allocator, &.{ exe_dir, "..", "scripts" });
            defer allocator.free(dev_path);
            if (std.fs.cwd().realpath(dev_path, &resolve_buf)) |p| {
                return try allocator.dupe(u8, p);
            } else |_| {}
        }
    }

    // Try current working directory's scripts folder (for running from source)
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.cwd().realpath("scripts", &cwd_buf)) |p| {
        return try allocator.dupe(u8, p);
    } else |_| {}

    return null;
}

/// Copy a file from src_path to dest_path and make it executable.
fn copyScriptFile(src_path: []const u8, dest_path: []const u8) !void {
    // Read source file
    const src_file = std.fs.openFileAbsolute(src_path, .{}) catch return error.ScriptNotFound;
    defer src_file.close();

    const content = src_file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return error.CopyFailed;
    defer std.heap.page_allocator.free(content);

    // Create destination directory if needed
    const dest_dir = std.fs.path.dirname(dest_path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.CopyFailed,
    };

    // Write destination file
    const dest_file = std.fs.createFileAbsolute(dest_path, .{ .mode = 0o755 }) catch return error.CopyFailed;
    defer dest_file.close();

    dest_file.writeAll(content) catch return error.CopyFailed;
}

/// Remove a file if it exists.
fn removeFile(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

/// Check if a file exists.
fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

// ============================================================================
// JSON Configuration Handling
// ============================================================================

/// Install Claude Code hooks by updating settings.json
fn installClaudeHooks(allocator: std.mem.Allocator, config_path: []const u8, script_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read existing file or start with empty object
    var content: []u8 = &.{};
    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            // Create directory if needed
            const dir_path = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
            std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return error.ConfigWriteFailed,
            };
            break :blk null;
        },
        else => return error.ConfigReadFailed,
    };

    if (file) |f| {
        defer f.close();
        content = f.readToEndAlloc(alloc, 10 * 1024 * 1024) catch return error.ConfigReadFailed;
    }

    // Parse existing JSON or create empty object
    var root: std.json.Value = undefined;
    if (content.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return error.JsonParseFailed;
        root = parsed.value;
    } else {
        root = .{ .object = std.json.ObjectMap.init(alloc) };
    }

    if (root != .object) return error.JsonParseFailed;

    // Build hook configuration
    const stop_cmd = try std.fmt.allocPrint(alloc, "python3 {s} done || true", .{script_path});
    const notif_cmd = try std.fmt.allocPrint(alloc, "python3 {s} awaiting_approval || true", .{script_path});

    // Create hooks structure
    var hooks: std.json.ObjectMap = undefined;
    if (root.object.getPtr("hooks")) |existing| {
        if (existing.* == .object) {
            hooks = existing.object;
        } else {
            hooks = std.json.ObjectMap.init(alloc);
        }
    } else {
        hooks = std.json.ObjectMap.init(alloc);
    }

    // Stop hook
    var stop_hook = std.json.ObjectMap.init(alloc);
    try stop_hook.put("type", .{ .string = "command" });
    try stop_hook.put("command", .{ .string = stop_cmd });

    var stop_hooks_array = std.json.Array.init(alloc);
    try stop_hooks_array.append(.{ .object = stop_hook });

    var stop_obj = std.json.ObjectMap.init(alloc);
    try stop_obj.put("hooks", .{ .array = stop_hooks_array });

    var stop_array = std.json.Array.init(alloc);
    try stop_array.append(.{ .object = stop_obj });
    try hooks.put("Stop", .{ .array = stop_array });

    // Notification hook
    var notif_hook = std.json.ObjectMap.init(alloc);
    try notif_hook.put("type", .{ .string = "command" });
    try notif_hook.put("command", .{ .string = notif_cmd });

    var notif_hooks_array = std.json.Array.init(alloc);
    try notif_hooks_array.append(.{ .object = notif_hook });

    var notif_obj = std.json.ObjectMap.init(alloc);
    try notif_obj.put("hooks", .{ .array = notif_hooks_array });

    var notif_array = std.json.Array.init(alloc);
    try notif_array.append(.{ .object = notif_obj });
    try hooks.put("Notification", .{ .array = notif_array });

    try root.object.put("hooks", .{ .object = hooks });

    // Write back
    const out_file = std.fs.createFileAbsolute(config_path, .{}) catch return error.ConfigWriteFailed;
    defer out_file.close();

    writeJsonToFile(out_file, root) catch return error.ConfigWriteFailed;
}

fn uninstallClaudeHooks(allocator: std.mem.Allocator, config_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch return;
    if (content.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return;
    var root = parsed.value;

    if (root != .object) return;

    if (root.object.getPtr("hooks")) |hooks| {
        if (hooks.* == .object) {
            _ = hooks.object.fetchSwapRemove("Stop");
            _ = hooks.object.fetchSwapRemove("Notification");

            if (hooks.object.count() == 0) {
                _ = root.object.fetchSwapRemove("hooks");
            }
        }
    }

    const out_file = std.fs.createFileAbsolute(config_path, .{}) catch return;
    defer out_file.close();

    writeJsonToFile(out_file, root) catch return;
}

// ============================================================================
// Codex Hook Configuration (TOML)
// ============================================================================

fn installCodexHooks(allocator: std.mem.Allocator, config_path: []const u8, script_path: []const u8) !void {
    // Read existing config if present
    var content: []u8 = &.{};
    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Create new config file
            const dir_path = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
            std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return error.ConfigWriteFailed,
            };
            const new_file = std.fs.createFileAbsolute(config_path, .{}) catch return error.ConfigWriteFailed;
            defer new_file.close();
            const notify_line = try std.fmt.allocPrint(allocator, "notify = [\"python3\", \"{s}\"]\n", .{script_path});
            defer allocator.free(notify_line);
            new_file.writeAll(notify_line) catch return error.ConfigWriteFailed;
            return;
        },
        else => return error.ConfigReadFailed,
    };
    defer file.close();

    content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.ConfigReadFailed;
    defer allocator.free(content);

    // Check if notify is already configured with architect
    if (std.mem.indexOf(u8, content, "notify") != null and std.mem.indexOf(u8, content, "architect") != null) {
        // Replace existing architect notify line
        var new_content = std.ArrayList(u8){};
        defer new_content.deinit(allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) {
                try new_content.append(allocator, '\n');
            }
            first = false;

            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "notify") and std.mem.indexOf(u8, line, "architect") != null) {
                try new_content.appendSlice(allocator, "notify = [\"python3\", \"");
                try new_content.appendSlice(allocator, script_path);
                try new_content.appendSlice(allocator, "\"]");
            } else {
                try new_content.appendSlice(allocator, line);
            }
        }

        const out_file = std.fs.createFileAbsolute(config_path, .{}) catch return error.ConfigWriteFailed;
        defer out_file.close();
        out_file.writeAll(new_content.items) catch return error.ConfigWriteFailed;
    } else if (std.mem.indexOf(u8, content, "notify")) |_| {
        // There's a different notify config - don't overwrite it
        return error.HookSkipped;
    } else {
        // Append notify line
        const out_file = std.fs.createFileAbsolute(config_path, .{ .truncate = false }) catch return error.ConfigWriteFailed;
        defer out_file.close();
        out_file.seekFromEnd(0) catch return error.ConfigWriteFailed;

        // Add newline if content doesn't end with one
        if (content.len > 0 and content[content.len - 1] != '\n') {
            out_file.writeAll("\n") catch return error.ConfigWriteFailed;
        }

        const notify_line = std.fmt.allocPrint(allocator, "notify = [\"python3\", \"{s}\"]\n", .{script_path}) catch return error.OutOfMemory;
        defer allocator.free(notify_line);
        out_file.writeAll(notify_line) catch return error.ConfigWriteFailed;
    }
}

fn uninstallCodexHooks(allocator: std.mem.Allocator, config_path: []const u8) !void {
    const file = std.fs.openFileAbsolute(config_path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    var new_content = std.ArrayList(u8){};
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        // Skip lines containing notify and architect
        if (std.mem.indexOf(u8, line, "notify") != null and std.mem.indexOf(u8, line, "architect") != null) {
            continue;
        }
        if (!first) {
            new_content.append(allocator, '\n') catch return;
        }
        first = false;
        new_content.appendSlice(allocator, line) catch return;
    }

    const out_file = std.fs.createFileAbsolute(config_path, .{}) catch return;
    defer out_file.close();
    out_file.writeAll(new_content.items) catch return;
}

// ============================================================================
// Gemini Hook Configuration
// ============================================================================

fn installGeminiHooks(allocator: std.mem.Allocator, config_path: []const u8, script_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read existing file or start with empty object
    var content: []u8 = &.{};
    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const dir_path = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
            std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return error.ConfigWriteFailed,
            };
            break :blk null;
        },
        else => return error.ConfigReadFailed,
    };

    if (file) |f| {
        defer f.close();
        content = f.readToEndAlloc(alloc, 10 * 1024 * 1024) catch return error.ConfigReadFailed;
    }

    var root: std.json.Value = undefined;
    if (content.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return error.JsonParseFailed;
        root = parsed.value;
    } else {
        root = .{ .object = std.json.ObjectMap.init(alloc) };
    }

    if (root != .object) return error.JsonParseFailed;

    // Build commands
    const after_cmd = try std.fmt.allocPrint(alloc, "python3 {s} done || true", .{script_path});
    const notif_cmd = try std.fmt.allocPrint(alloc, "python3 {s} awaiting_approval || true", .{script_path});

    // Create hooks structure
    var hooks: std.json.ObjectMap = undefined;
    if (root.object.getPtr("hooks")) |existing| {
        if (existing.* == .object) {
            hooks = existing.object;
        } else {
            hooks = std.json.ObjectMap.init(alloc);
        }
    } else {
        hooks = std.json.ObjectMap.init(alloc);
    }

    // AfterAgent hook
    var after_hook = std.json.ObjectMap.init(alloc);
    try after_hook.put("name", .{ .string = "architect-completion" });
    try after_hook.put("type", .{ .string = "command" });
    try after_hook.put("command", .{ .string = after_cmd });
    try after_hook.put("description", .{ .string = "Notify Architect when task completes" });

    var after_hooks_array = std.json.Array.init(alloc);
    try after_hooks_array.append(.{ .object = after_hook });

    var after_obj = std.json.ObjectMap.init(alloc);
    try after_obj.put("matcher", .{ .string = "*" });
    try after_obj.put("hooks", .{ .array = after_hooks_array });

    var after_array = std.json.Array.init(alloc);
    try after_array.append(.{ .object = after_obj });
    try hooks.put("AfterAgent", .{ .array = after_array });

    // Notification hook
    var notif_hook = std.json.ObjectMap.init(alloc);
    try notif_hook.put("name", .{ .string = "architect-approval" });
    try notif_hook.put("type", .{ .string = "command" });
    try notif_hook.put("command", .{ .string = notif_cmd });
    try notif_hook.put("description", .{ .string = "Notify Architect when waiting for approval" });

    var notif_hooks_array = std.json.Array.init(alloc);
    try notif_hooks_array.append(.{ .object = notif_hook });

    var notif_obj = std.json.ObjectMap.init(alloc);
    try notif_obj.put("matcher", .{ .string = "*" });
    try notif_obj.put("hooks", .{ .array = notif_hooks_array });

    var notif_array = std.json.Array.init(alloc);
    try notif_array.append(.{ .object = notif_obj });
    try hooks.put("Notification", .{ .array = notif_array });

    try root.object.put("hooks", .{ .object = hooks });

    // Ensure tools.enableHooks is set
    var tools: std.json.ObjectMap = undefined;
    if (root.object.getPtr("tools")) |existing| {
        if (existing.* == .object) {
            tools = existing.object;
        } else {
            tools = std.json.ObjectMap.init(alloc);
        }
    } else {
        tools = std.json.ObjectMap.init(alloc);
    }
    try tools.put("enableHooks", .{ .bool = true });
    try root.object.put("tools", .{ .object = tools });

    // Write back
    const out_file = std.fs.createFileAbsolute(config_path, .{}) catch return error.ConfigWriteFailed;
    defer out_file.close();

    writeJsonToFile(out_file, root) catch return error.ConfigWriteFailed;
}

fn uninstallGeminiHooks(allocator: std.mem.Allocator, config_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(alloc, 10 * 1024 * 1024) catch return;
    if (content.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch return;
    var root = parsed.value;

    if (root != .object) return;

    if (root.object.getPtr("hooks")) |hooks| {
        if (hooks.* == .object) {
            _ = hooks.object.fetchSwapRemove("AfterAgent");
            _ = hooks.object.fetchSwapRemove("Notification");

            if (hooks.object.count() == 0) {
                _ = root.object.fetchSwapRemove("hooks");
            }
        }
    }

    // Remove tools.enableHooks
    if (root.object.getPtr("tools")) |tools| {
        if (tools.* == .object) {
            _ = tools.object.fetchSwapRemove("enableHooks");
            if (tools.object.count() == 0) {
                _ = root.object.fetchSwapRemove("tools");
            }
        }
    }

    const out_file = std.fs.createFileAbsolute(config_path, .{}) catch return;
    defer out_file.close();

    writeJsonToFile(out_file, root) catch return;
}

// ============================================================================
// Public API
// ============================================================================

pub fn install(allocator: std.mem.Allocator, tool: Tool, writer: anytype) !void {
    const home = getHomeDir() orelse {
        try writer.writeAll("Error: HOME environment variable not set\n");
        return;
    };

    const scripts_dir = try findScriptsDir(allocator) orelse {
        try writer.writeAll("Error: Could not find Architect scripts directory\n");
        try writer.writeAll("Make sure you're running from the Architect installation or source directory.\n");
        return;
    };
    defer allocator.free(scripts_dir);

    try writer.print("Installing Architect hook for {s}...\n", .{tool.displayName()});

    // Build destination directory path
    const dest_dir = try std.fs.path.join(allocator, &.{ home, tool.configDir() });
    defer allocator.free(dest_dir);

    // Copy scripts
    const scripts = getScriptsForTool(tool);
    for (scripts) |script| {
        const src_path = try std.fs.path.join(allocator, &.{ scripts_dir, script.name });
        defer allocator.free(src_path);

        const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, script.dest_name });
        defer allocator.free(dest_path);

        copyScriptFile(src_path, dest_path) catch |err| {
            try writer.print("Error copying {s}: {}\n", .{ script.name, err });
            return;
        };

        try writer.print("  Copied {s} -> {s}\n", .{ script.name, dest_path });
    }

    // Get the main script path for config
    const main_script_path = try std.fs.path.join(allocator, &.{ dest_dir, "architect_notify.py" });
    defer allocator.free(main_script_path);

    // Update tool configuration
    switch (tool) {
        .claude => {
            const config_path = try std.fs.path.join(allocator, &.{ dest_dir, "settings.json" });
            defer allocator.free(config_path);

            installClaudeHooks(allocator, config_path, main_script_path) catch |err| {
                try writer.print("Error updating {s}: {}\n", .{ config_path, err });
                return;
            };

            try writer.print("  Updated {s}\n", .{config_path});
        },
        .codex => {
            const config_path = try std.fs.path.join(allocator, &.{ dest_dir, "config.toml" });
            defer allocator.free(config_path);

            installCodexHooks(allocator, config_path, main_script_path) catch |err| {
                if (err == error.HookSkipped) {
                    try writer.print("\nSkipped: {s} already contains a 'notify' setting.\n", .{config_path});
                    try writer.writeAll("Please manually add the Architect notifier to your existing notify configuration:\n");
                    try writer.print("  notify = [\"python3\", \"{s}\"]\n", .{main_script_path});
                    return;
                }
                try writer.print("Error updating {s}: {}\n", .{ config_path, err });
                return;
            };

            try writer.print("  Updated {s}\n", .{config_path});
        },
        .gemini => {
            const hook_script_path = try std.fs.path.join(allocator, &.{ dest_dir, "architect_hook.py" });
            defer allocator.free(hook_script_path);

            const config_path = try std.fs.path.join(allocator, &.{ dest_dir, "settings.json" });
            defer allocator.free(config_path);

            installGeminiHooks(allocator, config_path, hook_script_path) catch |err| {
                try writer.print("Error updating {s}: {}\n", .{ config_path, err });
                return;
            };

            try writer.print("  Updated {s}\n", .{config_path});
        },
    }

    try writer.print("\nHook installed! {s} sessions will now show Architect status indicators.\n", .{tool.displayName()});
}

pub fn uninstall(allocator: std.mem.Allocator, tool: Tool, writer: anytype) !void {
    const home = getHomeDir() orelse {
        try writer.writeAll("Error: HOME environment variable not set\n");
        return;
    };

    try writer.print("Uninstalling Architect hook for {s}...\n", .{tool.displayName()});

    // Build destination directory path
    const dest_dir = try std.fs.path.join(allocator, &.{ home, tool.configDir() });
    defer allocator.free(dest_dir);

    // Remove scripts
    const scripts = getScriptsForTool(tool);
    for (scripts) |script| {
        const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, script.dest_name });
        defer allocator.free(dest_path);

        if (fileExists(dest_path)) {
            removeFile(dest_path);
            try writer.print("  Removed {s}\n", .{dest_path});
        }
    }

    // Update tool configuration
    switch (tool) {
        .claude => {
            const config_path = try std.fs.path.join(allocator, &.{ dest_dir, "settings.json" });
            defer allocator.free(config_path);

            uninstallClaudeHooks(allocator, config_path) catch {};
            try writer.print("  Cleaned {s}\n", .{config_path});
        },
        .codex => {
            const config_path = try std.fs.path.join(allocator, &.{ dest_dir, "config.toml" });
            defer allocator.free(config_path);

            uninstallCodexHooks(allocator, config_path) catch {};
            try writer.print("  Cleaned {s}\n", .{config_path});
        },
        .gemini => {
            const config_path = try std.fs.path.join(allocator, &.{ dest_dir, "settings.json" });
            defer allocator.free(config_path);

            uninstallGeminiHooks(allocator, config_path) catch {};
            try writer.print("  Cleaned {s}\n", .{config_path});
        },
    }

    try writer.print("\nHook uninstalled.\n", .{});
}

pub fn status(allocator: std.mem.Allocator, writer: anytype) !void {
    const home = getHomeDir() orelse {
        try writer.writeAll("Error: HOME environment variable not set\n");
        return;
    };

    try writer.writeAll("Architect Hook Status:\n\n");

    const tools = [_]Tool{ .claude, .codex, .gemini };

    for (tools) |tool| {
        const dest_dir = try std.fs.path.join(allocator, &.{ home, tool.configDir() });
        defer allocator.free(dest_dir);

        const script_path = try std.fs.path.join(allocator, &.{ dest_dir, "architect_notify.py" });
        defer allocator.free(script_path);

        const installed = fileExists(script_path);

        if (installed) {
            try writer.print("  [x] {s: <15} {s}/\n", .{ tool.displayName(), dest_dir });
        } else {
            try writer.print("  [ ] {s: <15} Not installed\n", .{tool.displayName()});
        }
    }

    try writer.writeAll("\nUse 'architect hook install <tool>' to install a hook.\n");
}
