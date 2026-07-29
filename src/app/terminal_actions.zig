const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const session_state = @import("../session/state.zig");
const ui_mod = @import("../ui/mod.zig");
const c = @import("../c.zig");
const macos_clipboard = @import("../platform/macos_clipboard.zig");

const SessionState = session_state.SessionState;
const log = std.log.scoped(.terminal_actions);

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
        else => return err,
    };

    for (slices) |part| {
        if (part.len == 0) continue;
        try session.sendInput(part);
    }
}

/// Cmd+V image paste (opt-in via `[paste] image_passthrough`).
///
/// When the system clipboard holds an image, Architect reads it, writes it to a
/// temp PNG file, and pastes that file path as text into the focused terminal.
/// CLIs like Claude Code recognize an image file path and attach the image. This
/// is far more reliable than forwarding Ctrl+V and relying on the program's own
/// clipboard read, which can't materialize promised (lazily transferred)
/// Universal Clipboard data and fails on large images.
///
/// Returns true if it handled the event (an image was read and its path pasted);
/// false means there was no readable image and the caller should fall back to
/// the normal text paste. macOS only — `readClipboardImagePng` is null elsewhere.
pub fn tryPasteImagePassthrough(
    session: *SessionState,
    allocator: std.mem.Allocator,
    ui: *ui_mod.UiRoot,
    now: i64,
    session_interaction: *ui_mod.SessionInteractionComponent,
) !bool {
    if (!macos_clipboard.hasClipboardImage()) return false;

    // Detected an image but couldn't read its bytes -> let the caller fall back
    // to the normal text paste rather than swallowing the event.
    const png = macos_clipboard.readClipboardImagePng(allocator) orelse return false;
    defer allocator.free(png);

    const path = writeClipboardImageTempFile(allocator, png, session.id, now) catch |err| {
        log.warn("session {d}: failed to write clipboard image temp file: {}", .{ session.id, err });
        return false;
    };
    defer allocator.free(path);

    try pasteText(session, allocator, path, session_interaction);
    ui.showToast("Pasted image as file path", now);
    return true;
}

/// Writes clipboard image PNG bytes to a uniquely-named temp file and returns
/// the absolute path (caller owns it). The file is intentionally left on disk so
/// the CLI can read it when the message is sent; the OS reclaims the temp dir.
fn writeClipboardImageTempFile(allocator: std.mem.Allocator, png: []const u8, session_id: usize, now: i64) ![]u8 {
    const tmp_dir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const name = try std.fmt.allocPrint(allocator, "architect-paste-{d}-{d}.png", .{ now, session_id });
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ tmp_dir, name });
    errdefer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(png);

    return path;
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
