const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const session_state = @import("../session/state.zig");

const SessionState = session_state.SessionState;
pub const AgentKind = session_state.AgentKind;
pub const prompt_marker_line = "@@ARCH_PROMPT@@";

pub fn extractSessionText(allocator: std.mem.Allocator, session: *const SessionState) ![]u8 {
    if (session.terminal) |*terminal| {
        return extractTerminalText(allocator, terminal);
    }
    return allocator.dupe(u8, "");
}

pub fn extractTerminalText(allocator: std.mem.Allocator, terminal: *const ghostty_vt.Terminal) ![]u8 {
    const dumped = try terminal.screens.active.dumpStringAllocUnwrapped(allocator, .{ .screen = .{} });
    defer allocator.free(dumped);
    return stripAnsiAlloc(allocator, dumped);
}

pub fn stripAnsiAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch != 0x1B) {
            try out.append(allocator, ch);
            i += 1;
            continue;
        }

        if (i + 1 >= input.len) {
            break;
        }

        const next = input[i + 1];
        switch (next) {
            '[' => {
                i += 2;
                while (i < input.len) : (i += 1) {
                    const b = input[i];
                    if (b >= 0x40 and b <= 0x7E) {
                        i += 1;
                        break;
                    }
                }
            },
            ']' => {
                const payload_start = i + 2;
                const payload_end_and_terminator = findOscPayloadEnd(input, payload_start) orelse break;
                const payload = input[payload_start..payload_end_and_terminator.end];
                if (isPromptOsc133(payload)) {
                    try appendPromptMarkerLine(allocator, &out);
                }
                i = payload_end_and_terminator.after_terminator;
            },
            else => {
                i += 2;
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

const OscEnd = struct {
    end: usize,
    after_terminator: usize,
};

fn findOscPayloadEnd(input: []const u8, payload_start: usize) ?OscEnd {
    var i = payload_start;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b == 0x07) {
            return .{
                .end = i,
                .after_terminator = i + 1,
            };
        }
        if (b == 0x1B and i + 1 < input.len and input[i + 1] == '\\') {
            return .{
                .end = i,
                .after_terminator = i + 2,
            };
        }
    }
    return null;
}

fn isPromptOsc133(payload: []const u8) bool {
    if (!std.mem.startsWith(u8, payload, "133;")) return false;
    if (payload.len < 5) return false;
    return switch (payload[4]) {
        // OSC 133;A marks prompt-start in shell integration protocols.
        'A' => true,
        else => false,
    };
}

fn appendPromptMarkerLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, prompt_marker_line);
    try out.append(allocator, '\n');
}

/// Scans terminal text for the last occurrence of an agent's exit-message resume prefix
/// and returns the session ID that follows it (up to the next whitespace).
/// Returns a slice into `text`; caller must not free it (or dupe if lifetime matters).
pub fn extractAgentSessionId(text: []const u8, agent_kind: AgentKind) ?[]const u8 {
    const prefix = agent_kind.resumeCommandPrefix();

    var last_id_start: ?usize = null;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_pos, prefix)) |pos| {
        last_id_start = pos + prefix.len;
        search_pos = pos + 1;
    }

    const id_start = last_id_start orelse return null;
    if (id_start >= text.len) return null;

    var end = id_start;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') break;
    }

    if (end <= id_start) return null;
    return text[id_start..end];
}

/// Builds the shell command to resume an agent session, including a trailing newline.
/// Caller owns the returned slice and must free it.
pub fn buildResumeCommand(allocator: std.mem.Allocator, agent_kind: AgentKind, session_id: []const u8) ![]u8 {
    return switch (agent_kind) {
        .claude => std.fmt.allocPrint(allocator, "claude --resume {s}\n", .{session_id}),
        .codex => std.fmt.allocPrint(allocator, "codex resume {s}\n", .{session_id}),
        .gemini => std.fmt.allocPrint(allocator, "gemini --resume {s}\n", .{session_id}),
    };
}

test "stripAnsiAlloc removes CSI and OSC sequences" {
    const allocator = std.testing.allocator;
    const input = "hello\x1b[31m red\x1b[0m world\x1b]0;title\x07!";
    const cleaned = try stripAnsiAlloc(allocator, input);
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings("hello red world!", cleaned);
}

test "stripAnsiAlloc converts OSC 133 prompt markers to marker line" {
    const allocator = std.testing.allocator;
    const input = "before\x1b]133;A\x07after";
    const cleaned = try stripAnsiAlloc(allocator, input);
    defer allocator.free(cleaned);
    try std.testing.expectEqualStrings("before\n@@ARCH_PROMPT@@\nafter", cleaned);
}

test "extractTerminalText roundtrip includes scrollback and viewport text" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 8 * 32,
    });
    defer terminal.deinit(allocator);

    try terminal.screens.active.testWriteString("one\ntwo\nthree\nfour\nfive");

    const text = try extractTerminalText(allocator, &terminal);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "five") != null);
}

test "extractAgentSessionId finds UUID after claude --resume prefix" {
    const text = "some output\nclaude --resume abc-123-def\nmore output";
    const id = extractAgentSessionId(text, .claude);
    try std.testing.expectEqualStrings("abc-123-def", id.?);
}

test "extractAgentSessionId finds UUID after codex resume prefix" {
    const text = "Saving session...\ncodex resume 550e8400-e29b-41d4-a716-446655440000\n";
    const id = extractAgentSessionId(text, .codex);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", id.?);
}

test "extractAgentSessionId finds UUID after gemini --resume prefix" {
    const text = "gemini --resume f47ac10b-58cc-4372-a567-0e02b2c3d479 exiting";
    const id = extractAgentSessionId(text, .gemini);
    try std.testing.expectEqualStrings("f47ac10b-58cc-4372-a567-0e02b2c3d479", id.?);
}

test "extractAgentSessionId returns last occurrence on multiple matches" {
    const text = "claude --resume old-id\nsome more stuff\nclaude --resume new-id\n";
    const id = extractAgentSessionId(text, .claude);
    try std.testing.expectEqualStrings("new-id", id.?);
}

test "extractAgentSessionId returns null when prefix not present" {
    const text = "normal terminal output without any resume command";
    try std.testing.expect(extractAgentSessionId(text, .claude) == null);
    try std.testing.expect(extractAgentSessionId(text, .codex) == null);
    try std.testing.expect(extractAgentSessionId(text, .gemini) == null);
}

test "buildResumeCommand produces correct commands for each agent" {
    const allocator = std.testing.allocator;
    const uuid = "550e8400-e29b-41d4-a716-446655440000";

    const claude_cmd = try buildResumeCommand(allocator, .claude, uuid);
    defer allocator.free(claude_cmd);
    try std.testing.expectEqualStrings("claude --resume 550e8400-e29b-41d4-a716-446655440000\n", claude_cmd);

    const codex_cmd = try buildResumeCommand(allocator, .codex, uuid);
    defer allocator.free(codex_cmd);
    try std.testing.expectEqualStrings("codex resume 550e8400-e29b-41d4-a716-446655440000\n", codex_cmd);

    const gemini_cmd = try buildResumeCommand(allocator, .gemini, uuid);
    defer allocator.free(gemini_cmd);
    try std.testing.expectEqualStrings("gemini --resume 550e8400-e29b-41d4-a716-446655440000\n", gemini_cmd);
}
