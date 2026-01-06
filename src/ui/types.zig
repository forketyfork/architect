const std = @import("std");
const c = @import("../c.zig");
const app_state = @import("../app/app_state.zig");

pub const SessionUiInfo = struct {
    dead: bool,
    spawned: bool,
};

pub const UiHost = struct {
    now_ms: i64,

    window_w: c_int,
    window_h: c_int,

    grid_cols: usize,
    grid_rows: usize,
    cell_w: c_int,
    cell_h: c_int,

    view_mode: app_state.ViewMode,
    focused_session: usize,

    sessions: []const SessionUiInfo,
};

pub const UiAction = union(enum) {
    RestartSession: usize,
    RequestCollapseFocused: void,
};

pub const UiAssets = struct {};

pub const UiActionQueue = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(UiAction) = .{},

    pub fn init(allocator: std.mem.Allocator) UiActionQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *UiActionQueue) void {
        self.list.deinit(self.allocator);
    }

    pub fn append(self: *UiActionQueue, action: UiAction) std.mem.Allocator.Error!void {
        try self.list.append(self.allocator, action);
    }

    pub fn pop(self: *UiActionQueue) ?UiAction {
        if (self.list.items.len == 0) return null;
        return self.list.orderedRemove(0);
    }
};
