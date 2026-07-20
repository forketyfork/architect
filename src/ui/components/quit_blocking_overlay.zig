const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const shimmer = @import("../../gfx/shimmer.zig");
const UiComponent = @import("../component.zig").UiComponent;
const types = @import("../types.zig");

pub const QuitBlockingOverlayComponent = struct {
    allocator: std.mem.Allocator,
    active: bool = false,

    const shimmer_options = shimmer.Options{
        .base_alpha = 145,
        .band_alpha = 78,
    };

    pub fn init(allocator: std.mem.Allocator) !*QuitBlockingOverlayComponent {
        const self = try allocator.create(QuitBlockingOverlayComponent);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn asComponent(self: *QuitBlockingOverlayComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 3500,
        };
    }

    pub fn destroy(self: *QuitBlockingOverlayComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.allocator.destroy(self);
    }

    pub fn setActive(self: *QuitBlockingOverlayComponent, active: bool) void {
        self.active = active;
    }

    pub fn isActive(self: *const QuitBlockingOverlayComponent) bool {
        return self.active;
    }

    fn shouldConsumeInput(event_type: u32) bool {
        return switch (event_type) {
            c.SDL_EVENT_KEY_DOWN,
            c.SDL_EVENT_KEY_UP,
            c.SDL_EVENT_TEXT_INPUT,
            c.SDL_EVENT_TEXT_EDITING,
            c.SDL_EVENT_MOUSE_MOTION,
            c.SDL_EVENT_MOUSE_BUTTON_DOWN,
            c.SDL_EVENT_MOUSE_BUTTON_UP,
            c.SDL_EVENT_MOUSE_WHEEL,
            c.SDL_EVENT_DROP_FILE,
            => true,
            else => false,
        };
    }

    fn handleEvent(self_ptr: *anyopaque, _: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *QuitBlockingOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.active) return false;
        return shouldConsumeInput(event.type);
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn hitTest(self_ptr: *anyopaque, _: *const types.UiHost, _: c_int, _: c_int) bool {
        const self: *QuitBlockingOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.active;
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *QuitBlockingOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.active;
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *QuitBlockingOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.active) return;
        if (host.window_w <= 0 or host.window_h <= 0) return;

        shimmer.draw(renderer, geom.Rect{
            .x = 0,
            .y = 0,
            .w = host.window_w,
            .h = host.window_h,
        }, host.now_ms, shimmer_options);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .hitTest = hitTest,
        .deinit = deinit,
        .wantsFrame = wantsFrame,
    };

    fn deinit(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *QuitBlockingOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }
};

test "quit overlay consumes input only when active" {
    var component = QuitBlockingOverlayComponent{
        .allocator = std.testing.allocator,
    };
    var host = types.UiHost{
        .now_ms = 0,
        .window_w = 100,
        .window_h = 100,
        .ui_scale = 1.0,
        .grid_cols = 1,
        .grid_rows = 1,
        .cell_w = 100,
        .cell_h = 100,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Full,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = false,
        .sessions = &[_]types.SessionUiInfo{},
        .theme = undefined,
    };
    var actions = types.UiActionQueue.init(std.testing.allocator);
    defer actions.deinit();

    var key_event: c.SDL_Event = undefined;
    @memset(std.mem.asBytes(&key_event), 0);
    key_event.type = c.SDL_EVENT_KEY_DOWN;

    try std.testing.expect(!QuitBlockingOverlayComponent.handleEvent(&component, &host, &key_event, &actions));
    component.setActive(true);
    try std.testing.expect(QuitBlockingOverlayComponent.handleEvent(&component, &host, &key_event, &actions));
}

test "quit overlay wants frames only when active" {
    var component = QuitBlockingOverlayComponent{
        .allocator = std.testing.allocator,
    };
    var host = types.UiHost{
        .now_ms = 0,
        .window_w = 100,
        .window_h = 100,
        .ui_scale = 1.0,
        .grid_cols = 1,
        .grid_rows = 1,
        .cell_w = 100,
        .cell_h = 100,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Full,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = false,
        .sessions = &[_]types.SessionUiInfo{},
        .theme = undefined,
    };
    try std.testing.expect(!QuitBlockingOverlayComponent.wantsFrame(&component, &host));
    component.setActive(true);
    try std.testing.expect(QuitBlockingOverlayComponent.wantsFrame(&component, &host));
}

test "quit overlay hit test reflects active state" {
    var component = QuitBlockingOverlayComponent{
        .allocator = std.testing.allocator,
    };
    var host = types.UiHost{
        .now_ms = 0,
        .window_w = 100,
        .window_h = 100,
        .ui_scale = 1.0,
        .grid_cols = 1,
        .grid_rows = 1,
        .cell_w = 100,
        .cell_h = 100,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Full,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = false,
        .sessions = &[_]types.SessionUiInfo{},
        .theme = undefined,
    };
    try std.testing.expect(!QuitBlockingOverlayComponent.hitTest(&component, &host, 10, 10));
    component.setActive(true);
    try std.testing.expect(QuitBlockingOverlayComponent.hitTest(&component, &host, 10, 10));
}
