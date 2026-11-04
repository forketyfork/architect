const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const session_state = @import("../session/state.zig");
const ui_mod = @import("../ui/mod.zig");
const c = @import("../c.zig");

const SessionState = session_state.SessionState;
const log = std.log.scoped(.terminal_actions);

pub const SubmittedPasteError = error{
    NoShell,
    NoTerminal,
    BracketedPasteUnavailable,
    OutOfMemory,
};

pub fn isSubmittedPasteReady(session: *const SessionState) bool {
    if (session.shell == null) return false;
    const terminal = session.terminal orelse return false;
    return ghostty_vt.input.PasteOptions.fromTerminal(&terminal).bracketed;
}

pub fn buildSubmittedPaste(
    allocator: std.mem.Allocator,
    session: *const SessionState,
    text: []const u8,
) SubmittedPasteError![]u8 {
    if (session.shell == null) return error.NoShell;
    const terminal = session.terminal orelse return error.NoTerminal;
    return buildSubmittedPastePayload(
        allocator,
        text,
        ghostty_vt.input.PasteOptions.fromTerminal(&terminal),
    );
}

fn buildSubmittedPastePayload(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: ghostty_vt.input.PasteOptions,
) SubmittedPasteError![]u8 {
    if (!options.bracketed) return error.BracketedPasteUnavailable;
    return buildInputPayloadWithOptions(allocator, text, true, options);
}

/// One canonical-mode line, leaving room for the Enter that submits it.
pub const max_unbracketed_input_bytes: usize = 1023;

pub const InputPayload = struct {
    bytes: []u8,
    bracketed: bool,
};

/// Encodes text an external client types into a session: a paste (sanitized by
/// ghostty's paste encoder) followed by Enter when `submit` is set. Without
/// bracketed paste the receiving program may still be in canonical mode, where
/// every newline submits a separate line and macOS keeps at most MAX_CANON
/// (1024) bytes per line, so only one line that fits is accepted.
pub fn buildInputPayload(
    allocator: std.mem.Allocator,
    session: *const SessionState,
    text: []const u8,
    submit: bool,
) SubmittedPasteError!InputPayload {
    if (session.shell == null) return error.NoShell;
    const terminal = session.terminal orelse return error.NoTerminal;
    const options = ghostty_vt.input.PasteOptions.fromTerminal(&terminal);
    return .{
        .bytes = try buildInputPayloadWithOptions(allocator, text, submit, options),
        .bracketed = options.bracketed,
    };
}

fn buildInputPayloadWithOptions(
    allocator: std.mem.Allocator,
    text: []const u8,
    submit: bool,
    options: ghostty_vt.input.PasteOptions,
) SubmittedPasteError![]u8 {
    // CR submits a line just like LF does, so either would execute part of an
    // unsubmitted draft or split a submitted message into several lines.
    if (!options.bracketed and
        (std.mem.indexOfAny(u8, text, "\r\n") != null or text.len > max_unbracketed_input_bytes))
    {
        return error.BracketedPasteUnavailable;
    }

    var mutable_text: ?[]u8 = null;
    defer if (mutable_text) |owned| allocator.free(owned);
    const parts = ghostty_vt.input.encodePaste(text, options) catch |err| switch (err) {
        error.MutableRequired => blk: {
            const owned = try allocator.dupe(u8, text);
            mutable_text = owned;
            break :blk ghostty_vt.input.encodePaste(owned, options);
        },
    };

    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(allocator);
    try payload.ensureTotalCapacity(allocator, text.len + 13);
    for (parts) |part| try payload.appendSlice(allocator, part);
    if (submit) try payload.append(allocator, '\r');
    return payload.toOwnedSlice(allocator);
}

pub fn pasteText(
    session: *SessionState,
    allocator: std.mem.Allocator,
    text: []const u8,
    session_interaction: *ui_mod.SessionInteractionComponent,
) !void {
    if (text.len == 0) return;

    session_interaction.resetScrollIfNeeded(session.slot_index);

    const terminal = session.terminal orelse return error.NoTerminal;
    if (session.shell == null) return error.NoShell;

    const opts = ghostty_vt.input.PasteOptions.fromTerminal(&terminal);
    const slices = ghostty_vt.input.encodePaste(text, opts) catch |err| switch (err) {
        error.MutableRequired => blk: {
            const buf = try allocator.dupe(u8, text);
            defer allocator.free(buf);
            break :blk ghostty_vt.input.encodePaste(buf, opts);
        },
    };

    for (slices) |part| {
        if (part.len == 0) continue;
        try session.sendInput(part);
    }
}

pub fn clearTerminal(session: *SessionState) void {
    const terminal_ptr = session.terminal orelse return;
    var terminal = terminal_ptr;

    if (terminal.screens.active_key == .alternate) return;

    terminal.screens.active.clearSelection();
    terminal.eraseDisplay(ghostty_vt.EraseDisplay.scrollback, false);
    terminal.eraseDisplay(ghostty_vt.EraseDisplay.complete, false);
    session.markDirty();

    session.sendInput(&[_]u8{0x0C}) catch |err| {
        log.warn("session {d}: failed to send clear redraw: {}", .{ session.id, err });
    };
}

pub fn copySelectionToClipboard(
    session: *SessionState,
    allocator: std.mem.Allocator,
    ui: *ui_mod.UiRoot,
    now: i64,
) !void {
    const terminal = session.terminal orelse {
        ui.showToast("No terminal to copy from", now);
        return;
    };
    const screen = terminal.screens.active;
    const sel = screen.selection orelse {
        ui.showToast("No selection", now);
        return;
    };

    const text = try screen.selectionString(allocator, .{ .sel = sel, .trim = true });
    defer allocator.free(text);

    const clipboard_buf = try allocator.alloc(u8, text.len + 1);
    defer allocator.free(clipboard_buf);
    @memcpy(clipboard_buf[0..text.len], text);
    clipboard_buf[text.len] = 0;

    if (!c.SDL_SetClipboardText(clipboard_buf.ptr)) {
        ui.showToast("Failed to copy selection", now);
        return;
    }

    ui.showToast("Copied selection", now);
}

pub fn pasteClipboardIntoSession(
    session: *SessionState,
    allocator: std.mem.Allocator,
    ui: *ui_mod.UiRoot,
    now: i64,
    session_interaction: *ui_mod.SessionInteractionComponent,
) !void {
    const clip_ptr = c.SDL_GetClipboardText();
    defer c.SDL_free(clip_ptr);
    if (clip_ptr == null) {
        ui.showToast("Clipboard empty", now);
        return;
    }
    const clip = std.mem.sliceTo(clip_ptr, 0);
    if (clip.len == 0) {
        ui.showToast("Clipboard empty", now);
        return;
    }

    pasteText(session, allocator, clip, session_interaction) catch |err| switch (err) {
        error.NoTerminal => {
            ui.showToast("No terminal to paste into", now);
            return;
        },
        error.NoShell => {
            ui.showToast("Shell not available", now);
            return;
        },
        else => return err,
    };

    ui.showToast("Pasted clipboard", now);
}

test "submitted paste preserves multiline text and appends Enter" {
    const payload = try buildSubmittedPastePayload(
        std.testing.allocator,
        "first\nsecond",
        .{ .bracketed = true },
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings("\x1b[200~first\nsecond\x1b[201~\r", payload);
}

test "submitted paste supports prompts larger than command argument limits" {
    const prompt = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(prompt);
    @memset(prompt, 'x');

    const payload = try buildSubmittedPastePayload(
        std.testing.allocator,
        prompt,
        .{ .bracketed = true },
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqual(prompt.len + 13, payload.len);
    try std.testing.expectEqualStrings("\x1b[200~", payload[0..6]);
    try std.testing.expectEqualStrings("\x1b[201~\r", payload[payload.len - 7 ..]);
}

test "submitted paste requires bracketed paste mode" {
    try std.testing.expectError(
        error.BracketedPasteUnavailable,
        buildSubmittedPastePayload(
            std.testing.allocator,
            "first\nsecond",
            .{ .bracketed = false },
        ),
    );
}

test "input payload pastes without Enter when submit is false" {
    const payload = try buildInputPayloadWithOptions(std.testing.allocator, "draft", false, .{ .bracketed = true });
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings("\x1b[200~draft\x1b[201~", payload);
}

test "input payload strips an embedded bracketed-paste terminator" {
    const payload = try buildInputPayloadWithOptions(std.testing.allocator, "a\x1b[201~rm -rf ~\r", true, .{ .bracketed = true });
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.startsWith(u8, payload, "\x1b[200~"));
    try std.testing.expect(std.mem.endsWith(u8, payload, "\x1b[201~\r"));
    const body = payload[6 .. payload.len - 7];
    try std.testing.expect(std.mem.indexOfScalar(u8, body, 0x1b) == null);
}

test "input payload without bracketed paste accepts one line and rejects several" {
    const payload = try buildInputPayloadWithOptions(std.testing.allocator, "echo ok", true, .{ .bracketed = false });
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings("echo ok\r", payload);

    try std.testing.expectError(
        error.BracketedPasteUnavailable,
        buildInputPayloadWithOptions(std.testing.allocator, "one\ntwo", true, .{ .bracketed = false }),
    );
}

test "input payload without bracketed paste rejects carriage returns in both submit modes" {
    for ([_]bool{ false, true }) |submit| {
        try std.testing.expectError(
            error.BracketedPasteUnavailable,
            buildInputPayloadWithOptions(std.testing.allocator, "echo one\recho two", submit, .{ .bracketed = false }),
        );
    }
}

test "input payload without bracketed paste rejects a line longer than one canonical-mode line" {
    const allocator = std.testing.allocator;
    const line = try allocator.alloc(u8, max_unbracketed_input_bytes + 1);
    defer allocator.free(line);
    @memset(line, 'x');

    const fits = try buildInputPayloadWithOptions(allocator, line[0..max_unbracketed_input_bytes], true, .{ .bracketed = false });
    defer allocator.free(fits);
    try std.testing.expectEqual(max_unbracketed_input_bytes + 1, fits.len);

    try std.testing.expectError(
        error.BracketedPasteUnavailable,
        buildInputPayloadWithOptions(allocator, line, true, .{ .bracketed = false }),
    );
    const bracketed = try buildInputPayloadWithOptions(allocator, line, true, .{ .bracketed = true });
    defer allocator.free(bracketed);
    try std.testing.expectEqual(line.len + 13, bracketed.len);
}
