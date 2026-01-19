const app_state = @import("../app/app_state.zig");
const ghostty_vt = @import("ghostty-vt");

pub const SessionViewState = struct {
    status: app_state.SessionStatus = .running,
    attention: bool = false,
    is_viewing_scrollback: bool = false,
    scroll_velocity: f32 = 0.0,
    scroll_remainder: f32 = 0.0,
    last_scroll_time: i64 = 0,
    scroll_inertia_allowed: bool = true,
    selection_anchor: ?ghostty_vt.Pin = null,
    selection_dragging: bool = false,
    selection_pending: bool = false,
    hovered_link_start: ?ghostty_vt.Pin = null,
    hovered_link_end: ?ghostty_vt.Pin = null,

    pub fn reset(self: *SessionViewState) void {
        self.* = .{};
    }

    pub fn clearSelection(self: *SessionViewState) void {
        self.selection_anchor = null;
        self.selection_dragging = false;
        self.selection_pending = false;
    }

    pub fn clearHover(self: *SessionViewState) void {
        self.hovered_link_start = null;
        self.hovered_link_end = null;
    }

    pub fn clearScroll(self: *SessionViewState) void {
        self.is_viewing_scrollback = false;
        self.scroll_velocity = 0.0;
        self.scroll_remainder = 0.0;
        self.last_scroll_time = 0;
        self.scroll_inertia_allowed = true;
    }
};
