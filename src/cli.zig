// CLI argument parser for Architect subcommands.
// Currently supports: `architect hook install|uninstall|status [tool]`
const std = @import("std");

pub const Tool = enum {
    claude,
    codex,
    gemini,

    pub fn displayName(self: Tool) []const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex",
            .gemini => "Gemini CLI",
        };
    }

    pub fn configDir(self: Tool) []const u8 {
        return switch (self) {
            .claude => ".claude",
            .codex => ".codex",
            .gemini => ".gemini",
        };
    }

    pub fn fromString(s: []const u8) ?Tool {
        if (std.mem.eql(u8, s, "claude") or std.mem.eql(u8, s, "claude-code")) {
            return .claude;
        } else if (std.mem.eql(u8, s, "codex")) {
            return .codex;
        } else if (std.mem.eql(u8, s, "gemini") or std.mem.eql(u8, s, "gemini-cli")) {
            return .gemini;
        }
        return null;
    }
};

pub const HookCommand = enum {
    install,
    uninstall,
    status,

    pub fn fromString(s: []const u8) ?HookCommand {
        if (std.mem.eql(u8, s, "install")) {
            return .install;
        } else if (std.mem.eql(u8, s, "uninstall")) {
            return .uninstall;
        } else if (std.mem.eql(u8, s, "status")) {
            return .status;
        }
        return null;
    }
};

pub const Command = union(enum) {
    hook: struct {
        action: HookCommand,
        tool: ?Tool,
    },
    help,
    version,
    gui, // No CLI args, run GUI mode
};

pub const ParseError = error{
    UnknownCommand,
    MissingHookAction,
    UnknownHookAction,
    UnknownTool,
    MissingToolArgument,
};

/// Parse command-line arguments and return the appropriate Command.
/// Returns `.gui` if no arguments are provided (normal GUI launch).
pub fn parse(args: []const []const u8) ParseError!Command {
    // Skip program name
    const cmd_args = if (args.len > 0) args[1..] else args;

    if (cmd_args.len == 0) {
        return .gui;
    }

    const first = cmd_args[0];

    // Check for help flags
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) {
        return .help;
    }

    // Check for version flags
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v") or std.mem.eql(u8, first, "version")) {
        return .version;
    }

    // Hook command
    if (std.mem.eql(u8, first, "hook")) {
        if (cmd_args.len < 2) {
            return error.MissingHookAction;
        }

        const action = HookCommand.fromString(cmd_args[1]) orelse {
            return error.UnknownHookAction;
        };

        // Status doesn't require a tool argument
        if (action == .status) {
            return .{ .hook = .{ .action = action, .tool = null } };
        }

        // Install/uninstall require a tool argument
        if (cmd_args.len < 3) {
            return error.MissingToolArgument;
        }

        const tool = Tool.fromString(cmd_args[2]) orelse {
            return error.UnknownTool;
        };

        return .{ .hook = .{ .action = action, .tool = tool } };
    }

    return error.UnknownCommand;
}

pub fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Architect - A terminal multiplexer for AI-assisted development
        \\
        \\USAGE:
        \\    architect                     Launch the GUI
        \\    architect hook <command>      Manage AI assistant hooks
        \\    architect help                Show this help message
        \\    architect version             Show version information
        \\
        \\HOOK COMMANDS:
        \\    architect hook install <tool>     Install hook for an AI tool
        \\    architect hook uninstall <tool>   Uninstall hook for an AI tool
        \\    architect hook status             Show installed hooks status
        \\
        \\SUPPORTED TOOLS:
        \\    claude, claude-code    Claude Code AI assistant
        \\    codex                  OpenAI Codex CLI
        \\    gemini, gemini-cli     Google Gemini CLI
        \\
        \\EXAMPLES:
        \\    architect hook install claude
        \\    architect hook uninstall gemini
        \\    architect hook status
        \\
    );
}

pub fn printError(err: ParseError, writer: anytype) !void {
    switch (err) {
        error.UnknownCommand => try writer.writeAll("Error: Unknown command. Use 'architect help' for usage.\n"),
        error.MissingHookAction => try writer.writeAll("Error: Missing hook action. Use: architect hook install|uninstall|status\n"),
        error.UnknownHookAction => try writer.writeAll("Error: Unknown hook action. Valid actions: install, uninstall, status\n"),
        error.UnknownTool => try writer.writeAll("Error: Unknown tool. Valid tools: claude, codex, gemini\n"),
        error.MissingToolArgument => try writer.writeAll("Error: Missing tool argument. Use: architect hook install <tool>\n"),
    }
}

test "parse - no args returns gui" {
    const result = try parse(&[_][]const u8{"architect"});
    try std.testing.expectEqual(.gui, result);
}

test "parse - help flags" {
    try std.testing.expectEqual(.help, try parse(&[_][]const u8{ "architect", "help" }));
    try std.testing.expectEqual(.help, try parse(&[_][]const u8{ "architect", "--help" }));
    try std.testing.expectEqual(.help, try parse(&[_][]const u8{ "architect", "-h" }));
}

test "parse - version flags" {
    try std.testing.expectEqual(.version, try parse(&[_][]const u8{ "architect", "version" }));
    try std.testing.expectEqual(.version, try parse(&[_][]const u8{ "architect", "--version" }));
    try std.testing.expectEqual(.version, try parse(&[_][]const u8{ "architect", "-v" }));
}

test "parse - hook install claude" {
    const result = try parse(&[_][]const u8{ "architect", "hook", "install", "claude" });
    switch (result) {
        .hook => |h| {
            try std.testing.expectEqual(.install, h.action);
            try std.testing.expectEqual(.claude, h.tool.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse - hook status" {
    const result = try parse(&[_][]const u8{ "architect", "hook", "status" });
    switch (result) {
        .hook => |h| {
            try std.testing.expectEqual(.status, h.action);
            try std.testing.expect(h.tool == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse - missing hook action" {
    const result = parse(&[_][]const u8{ "architect", "hook" });
    try std.testing.expectError(error.MissingHookAction, result);
}

test "parse - missing tool for install" {
    const result = parse(&[_][]const u8{ "architect", "hook", "install" });
    try std.testing.expectError(error.MissingToolArgument, result);
}
