const std = @import("std");
const session_state = @import("../session/state.zig");
const ui_mod = @import("../ui/mod.zig");

const SessionState = session_state.SessionState;

pub const ImeComposition = struct {
    codepoints: usize = 0,

    pub fn reset(self: *ImeComposition) void {
        self.codepoints = 0;
    }
};

const log = std.log.scoped(.input_text);

pub fn countImeCodepoints(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch |err| blk: {
        log.warn("failed to count UTF-8 codepoints: {}", .{err});
        break :blk text.len;
    };
}

fn sendDeleteInput(session: *SessionState, count: usize) !void {
    if (count == 0) return;

    var buf: [16]u8 = undefined;
    @memset(buf[0..], 0x7f);

    var remaining: usize = count;
    while (remaining > 0) {
        const chunk: usize = @min(remaining, buf.len);
        try session.sendInput(buf[0..chunk]);
        remaining -= chunk;
    }
}

pub fn clearImeComposition(session: *SessionState, ime: *ImeComposition) !void {
    if (ime.codepoints == 0) return;
    if (!session.spawned or session.dead) {
        ime.codepoints = 0;
        return;
    }

    try sendDeleteInput(session, ime.codepoints);
    ime.codepoints = 0;
}

pub fn handleTextEditing(
    session: *SessionState,
    ime: *ImeComposition,
    text_ptr: [*c]const u8,
    start: c_int,
    length: c_int,
    session_interaction: *ui_mod.SessionInteractionComponent,
) !void {
    if (!session.spawned or session.dead) return;
    if (text_ptr == null) return;

    const text = std.mem.sliceTo(text_ptr, 0);
    if (text.len == 0) {
        if (ime.codepoints == 0) return;
        session_interaction.resetScrollIfNeeded(session.slot_index);
        try clearImeComposition(session, ime);
        return;
    }

    session_interaction.resetScrollIfNeeded(session.slot_index);
    const is_committed_text = length == 0 and start == 0;
    if (is_committed_text) {
        try clearImeComposition(session, ime);
        try session.sendInput(text);
        return;
    }

    try clearImeComposition(session, ime);
    try session.sendInput(text);
    ime.codepoints = countImeCodepoints(text);
}

pub fn handleTextInput(
    session: *SessionState,
    ime: *ImeComposition,
    text_ptr: [*c]const u8,
    session_interaction: *ui_mod.SessionInteractionComponent,
) !void {
    if (!session.spawned or session.dead) return;
    if (text_ptr == null) return;

    const text = std.mem.sliceTo(text_ptr, 0);
    if (text.len == 0) return;

    session_interaction.resetScrollIfNeeded(session.slot_index);
    try clearImeComposition(session, ime);
    try session.sendInput(text);
}
