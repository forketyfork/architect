const std = @import("std");
const c = @import("../../c.zig");
const UiComponent = @import("../component.zig").UiComponent;
const types = @import("../types.zig");

pub const QuitBlockingOverlayComponent = struct {
    allocator: std.mem.Allocator,
    active: bool = false,

    const base_alpha: u8 = 145;
    const shimmer_alpha: u8 = 78;
    const shimmer_cycle_ms: i64 = 1400;
    const shimmer_width_divisor: c_int = 12;
    const shimmer_min_width: c_int = 30;
    const shimmer_gradient_steps: usize = 4;
    const shimmer_slope: f32 = -0.42;

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

        const cycle_ms = @max(shimmer_cycle_ms, 1);
        const phase_ms = @mod(host.now_ms, cycle_ms);
        const progress = @as(f32, @floatFromInt(phase_ms)) / @as(f32, @floatFromInt(cycle_ms));

        const window_rect = c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.window_w),
            .h = @floatFromInt(host.window_h),
        };
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 85, 85, 85, base_alpha);
        _ = c.SDL_RenderFillRect(renderer, &window_rect);

        const shimmer_w: c_int = @max(@divFloor(host.window_w, shimmer_width_divisor), shimmer_min_width);
        const half_total_w = @as(f32, @floatFromInt(shimmer_w)) * 0.5;
        const half_core_w = half_total_w * 0.38;
        const margin = @as(f32, @floatFromInt(@max(host.window_w, host.window_h)));

        const center_x = -margin + progress * (@as(f32, @floatFromInt(host.window_w)) + margin * 2.0);
        const center_y = -margin + progress * (@as(f32, @floatFromInt(host.window_h)) + margin * 2.0);

        const window_h: usize = @intCast(host.window_h);
        for (0..window_h) |row| {
            const y: c_int = @intCast(row);
            const y_f = @as(f32, @floatFromInt(y));
            const center = center_x + shimmer_slope * (y_f - center_y);
            drawBandRow(renderer, y, host.window_w, center, half_core_w, half_total_w);
        }
    }

    fn drawBandRow(renderer: *c.SDL_Renderer, y: c_int, window_w: c_int, center: f32, half_core_w: f32, half_total_w: f32) void {
        drawSpan(renderer, y, window_w, center - half_core_w, center + half_core_w, shimmer_alpha);

        const fade_width = half_total_w - half_core_w;
        if (fade_width <= 0) return;

        const steps_f = @as(f32, @floatFromInt(shimmer_gradient_steps));
        for (0..shimmer_gradient_steps) |step| {
            const t0 = @as(f32, @floatFromInt(step)) / steps_f;
            const t1 = @as(f32, @floatFromInt(step + 1)) / steps_f;
            const inner = half_core_w + fade_width * t0;
            const outer = half_core_w + fade_width * t1;
            const alpha_f = @as(f32, @floatFromInt(shimmer_alpha)) * (1.0 - t0) * (1.0 - t0);
            const alpha: u8 = @intFromFloat(@max(0.0, @min(alpha_f, 255.0)));
            if (alpha == 0) continue;

            drawSpan(renderer, y, window_w, center - outer, center - inner, alpha);
            drawSpan(renderer, y, window_w, center + inner, center + outer, alpha);
        }
    }

    fn drawSpan(renderer: *c.SDL_Renderer, y: c_int, window_w: c_int, left_f: f32, right_f: f32, alpha: u8) void {
        if (alpha == 0 or window_w <= 0) return;

        var left: c_int = @intFromFloat(@floor(left_f));
        var right: c_int = @intFromFloat(@ceil(right_f));
        if (right <= 0 or left >= window_w) return;

        left = std.math.clamp(left, 0, window_w);
        right = std.math.clamp(right, 0, window_w);
        const span_w = right - left;
        if (span_w <= 0) return;

        _ = c.SDL_SetRenderDrawColor(renderer, 170, 170, 170, alpha);
        const rect = c.SDL_FRect{
            .x = @floatFromInt(left),
            .y = @floatFromInt(y),
            .w = @floatFromInt(span_w),
            .h = 1,
        };
        _ = c.SDL_RenderFillRect(renderer, &rect);
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
