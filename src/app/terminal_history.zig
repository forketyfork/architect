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

/// Scans terminal text for the last UUID (RFC 4122 format: 8-4-4-4-12 hex chars)
/// and returns a slice into `text`. Takes the last match so that earlier UUIDs in
/// scrollback don't shadow the session ID printed by the agent just before exit.
/// Returns a slice into `text`; caller must not free it (or dupe if lifetime matters).
pub fn extractLastUuid(text: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var i: usize = 0;
    while (i < text.len) {
        if (matchUuidAt(text, i)) |uuid| {
            last = uuid;
            i += uuid.len;
        } else {
            i += 1;
        }
    }
    return last;
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn matchUuidAt(text: []const u8, start: usize) ?[]const u8 {
    // Reject matches that start mid-hex-sequence.
    if (start > 0 and isHexChar(text[start - 1])) return null;

    // UUID groups: 8-4-4-4-12 hex chars separated by dashes.
    const groups = [_]usize{ 8, 4, 4, 4, 12 };
    var pos = start;
    for (groups, 0..) |len, g| {
        if (g > 0) {
            if (pos >= text.len or text[pos] != '-') return null;
            pos += 1;
        }
        for (0..len) |_| {
            if (pos >= text.len or !isHexChar(text[pos])) return null;
            pos += 1;
        }
    }
    // Reject matches followed immediately by more hex or a dash (partial UUID / longer ID).
    if (pos < text.len and (isHexChar(text[pos]) or text[pos] == '-')) return null;
    return text[start..pos];
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

test "extractLastUuid finds a UUID in terminal output" {
    const text = "Saving session...\nTo resume, run: claude --resume 550e8400-e29b-41d4-a716-446655440000\n";
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", extractLastUuid(text).?);
}

test "extractLastUuid returns the last UUID when multiple are present" {
    const text = "old session f47ac10b-58cc-4372-a567-0e02b2c3d479\nnew session 550e8400-e29b-41d4-a716-446655440000\n";
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", extractLastUuid(text).?);
}

test "extractLastUuid returns null when no UUID present" {
    try std.testing.expect(extractLastUuid("normal terminal output without any uuid") == null);
    try std.testing.expect(extractLastUuid("") == null);
}

test "extractLastUuid does not match partial or malformed UUIDs" {
    // Too short in one group
    try std.testing.expect(extractLastUuid("550e840-e29b-41d4-a716-446655440000") == null);
    // Extra hex chars after the UUID should not match as UUID
    const text = "550e8400-e29b-41d4-a716-446655440000ff extra";
    try std.testing.expect(extractLastUuid(text) == null);
}

test "extractLastUuid handles uppercase hex" {
    const text = "session 550E8400-E29B-41D4-A716-446655440000 done";
    try std.testing.expectEqualStrings("550E8400-E29B-41D4-A716-446655440000", extractLastUuid(text).?);
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
