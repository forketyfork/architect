const std = @import("std");
const c = @import("../c.zig");
const app_state = @import("../app/app_state.zig");
const font_mod = @import("../font.zig");
const colors = @import("../colors.zig");
const font_cache = @import("../font_cache.zig");

pub const SessionUiInfo = struct {
    dead: bool,
    spawned: bool,
};

pub const UiHost = struct {
    now_ms: i64,

    window_w: c_int,
    window_h: c_int,
    ui_scale: f32,

    grid_cols: usize,
    grid_rows: usize,
    cell_w: c_int,
    cell_h: c_int,

    view_mode: app_state.ViewMode,
    focused_session: usize,
    focused_cwd: ?[]const u8,
    focused_has_foreground_process: bool,

    sessions: []const SessionUiInfo,
    theme: *const colors.Theme,
};

pub const UiAction = union(enum) {
    RestartSession: usize,
    RequestCollapseFocused: void,
    ConfirmQuit: void,
    OpenConfig: void,
    SwitchWorktree: SwitchWorktreeAction,
    CreateWorktree: CreateWorktreeAction,
    RemoveWorktree: RemoveWorktreeAction,
    DespawnSession: usize,
};

pub const SwitchWorktreeAction = struct {
    session: usize,
    path: []const u8,
};

pub const CreateWorktreeAction = struct {
    session: usize,
    base_path: []const u8,
    name: []const u8,
};

pub const RemoveWorktreeAction = struct {
    session: usize,
    path: []const u8,
};

pub const UiAssets = struct {
    ui_font: ?*font_mod.Font = null,
    font_cache: ?*font_cache.FontCache = null,
};

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
