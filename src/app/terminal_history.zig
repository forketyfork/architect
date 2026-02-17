const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const session_state = @import("../session/state.zig");

const SessionState = session_state.SessionState;
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
