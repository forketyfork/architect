const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const HelpOverlayComponent = @import("help_overlay.zig").HelpOverlayComponent;
const WorktreeOverlayComponent = @import("worktree_overlay.zig").WorktreeOverlayComponent;
const RecentFoldersOverlayComponent = @import("recent_folders_overlay.zig").RecentFoldersOverlayComponent;
const PRDropdownComponent = @import("pr_dropdown.zig").PRDropdownComponent;

const dpi = @import("../../dpi.zig");
const easing = @import("../../anim/easing.zig");
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

const pill_count: usize = 4;
const pill_size: c_int = 40;
const pill_margin: c_int = 20;
const pill_spacing: c_int = 20;
const pill_animation_duration_ms: i64 = 200;

const PillKind = enum(usize) {
    pull_request,
    worktree,
    recent_folders,
    help,
};

const layout_order = [_]PillKind{ .help, .recent_folders, .worktree, .pull_request };

const AnimationPhase = enum {
    idle,
    reflow,
    entrance,
};

const PillLayout = struct {
    current_x: [pill_count]c_int = [_]c_int{0} ** pill_count,
    start_x: [pill_count]c_int = [_]c_int{0} ** pill_count,
    target_x: [pill_count]c_int = [_]c_int{0} ** pill_count,
    visible: [pill_count]bool = [_]bool{false} ** pill_count,
    entering: [pill_count]bool = [_]bool{false} ** pill_count,
    start_time: i64 = 0,
    initialized: bool = false,
    animating: bool = false,
    phase: AnimationPhase = .idle,

    fn update(self: *PillLayout, now_ms: i64, window_w: c_int, ui_scale: f32, visible: [pill_count]bool) bool {
        const animation_completed = if (self.initialized) self.advance(now_ms) else false;

        const targets = self.calculateTargets(window_w, ui_scale, visible);
        if (!self.initialized) {
            self.current_x = targets;
            self.start_x = targets;
            self.target_x = targets;
            self.visible = visible;
            self.initialized = true;
            return false;
        }

        const membership_changed = !std.mem.eql(bool, self.visible[0..], visible[0..]);
        var target_changed = false;
        for (0..pill_count) |idx| {
            if (visible[idx] and self.target_x[idx] != targets[idx]) {
                target_changed = true;
                break;
            }
        }

        if (!membership_changed and !target_changed) return animation_completed;

        self.start_x = self.current_x;
        self.target_x = targets;
        const entrance_x = window_w + dpi.scale(pill_size, ui_scale);
        for (0..pill_count) |idx| {
            const was_entering = self.entering[idx];
            const stage = visible[idx] and (was_entering or !self.visible[idx]);
            self.entering[idx] = stage;
            if (stage and !was_entering) {
                self.start_x[idx] = entrance_x;
                self.current_x[idx] = entrance_x;
            }
        }
        self.visible = visible;
        self.start_time = now_ms;
        self.animating = true;
        self.phase = .reflow;
        return membership_changed;
    }

    fn calculateTargets(self: *const PillLayout, window_w: c_int, ui_scale: f32, visible: [pill_count]bool) [pill_count]c_int {
        var targets = self.current_x;
        const margin = dpi.scale(pill_margin, ui_scale);
        const size = dpi.scale(pill_size, ui_scale);
        const spacing = dpi.scale(pill_spacing, ui_scale);

        var right_edge = window_w - margin;

        for (layout_order) |pill| {
            const idx: usize = @intFromEnum(pill);
            if (!visible[idx]) continue;
            targets[idx] = right_edge - size;
            right_edge = targets[idx] - spacing;
        }

        return targets;
    }

    fn advance(self: *PillLayout, now_ms: i64) bool {
        if (!self.animating) return false;

        const elapsed = now_ms - self.start_time;
        switch (self.phase) {
            .idle => return false,
            .reflow => {
                if (elapsed >= pill_animation_duration_ms) {
                    for (0..pill_count) |idx| {
                        if (!self.entering[idx]) self.current_x[idx] = self.target_x[idx];
                    }

                    if (self.hasEnteringPills()) {
                        self.phase = .entrance;
                        self.start_time += pill_animation_duration_ms;
                        return self.advance(now_ms);
                    }

                    return self.finishAnimation();
                }

                self.applyEasedPositions(now_ms, false);
            },
            .entrance => {
                if (elapsed >= pill_animation_duration_ms) return self.finishAnimation();
                self.applyEasedPositions(now_ms, true);
            },
        }
        return false;
    }

    fn hasEnteringPills(self: *const PillLayout) bool {
        for (self.entering) |entering| {
            if (entering) return true;
        }
        return false;
    }

    fn applyEasedPositions(self: *PillLayout, now_ms: i64, entering_only: bool) void {
        const elapsed = now_ms - self.start_time;
        const clamped_elapsed: i64 = @max(@as(i64, 0), elapsed);
        const progress: f32 = @min(
            @as(f32, 1.0),
            @as(f32, @floatFromInt(clamped_elapsed)) / @as(f32, @floatFromInt(pill_animation_duration_ms)),
        );
        const eased = easing.easeInOutCubic(progress);

        for (0..pill_count) |idx| {
            if (self.entering[idx] != entering_only) continue;
            const distance = self.target_x[idx] - self.start_x[idx];
            self.current_x[idx] = self.start_x[idx] + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(distance)) * eased));
        }
    }

    fn finishAnimation(self: *PillLayout) bool {
        self.current_x = self.target_x;
        self.entering = [_]bool{false} ** pill_count;
        self.animating = false;
        self.phase = .idle;
        return true;
    }

    fn currentX(self: *const PillLayout, pill: PillKind) c_int {
        return self.current_x[@intFromEnum(pill)];
    }

    fn pillInteractive(self: *const PillLayout, pill: PillKind) bool {
        const idx = @intFromEnum(pill);
        return self.visible[idx] and !self.entering[idx];
    }

    fn isEntering(self: *const PillLayout, pill: PillKind) bool {
        return self.entering[@intFromEnum(pill)];
    }
};

pub const PillGroupComponent = struct {
    allocator: std.mem.Allocator,
    help: *HelpOverlayComponent,
    recent_folders: *RecentFoldersOverlayComponent,
    worktree: *WorktreeOverlayComponent,
    pr_dropdown: *PRDropdownComponent,
    layout: PillLayout = .{},
    first_frame: FirstFrameGuard = .{},
    last_help_state: ExpandingOverlay.State = .Closed,
    last_recent_folders_state: ExpandingOverlay.State = .Closed,
    last_worktree_state: ExpandingOverlay.State = .Closed,
    last_pr_state: ExpandingOverlay.State = .Closed,
    pointer_blocked: bool = false,

    pub const component_z_index: i32 = 1001;

    pub fn create(
        allocator: std.mem.Allocator,
        help: *HelpOverlayComponent,
        recent_folders: *RecentFoldersOverlayComponent,
        worktree: *WorktreeOverlayComponent,
        pr_dropdown: *PRDropdownComponent,
    ) !UiComponent {
        const comp = try allocator.create(PillGroupComponent);
        comp.* = .{
            .allocator = allocator,
            .help = help,
            .recent_folders = recent_folders,
            .worktree = worktree,
            .pr_dropdown = pr_dropdown,
        };

        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = component_z_index,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        self.allocator.destroy(self);
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));

        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                if (self.containsEnteringPill(host, mouse_x, mouse_y)) {
                    self.pointer_blocked = true;
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (self.pointer_blocked) {
                    self.pointer_blocked = false;
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (self.pointer_blocked) return true;
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                return self.containsEnteringPill(host, mouse_x, mouse_y);
            },
            else => {},
        }

        return false;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        return self.containsEnteringPill(host, x, y);
    }

    fn containsEnteringPill(self: *const PillGroupComponent, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const scaled_pill_size = dpi.scale(pill_size, host.ui_scale);
        const scaled_pill_margin = dpi.scale(pill_margin, host.ui_scale);

        for (layout_order) |pill| {
            if (!self.layout.isEntering(pill)) continue;
            const rect = geom.Rect{
                .x = self.layout.currentX(pill),
                .y = scaled_pill_margin,
                .w = scaled_pill_size,
                .h = scaled_pill_size,
            };
            if (geom.containsPoint(rect, x, y)) return true;
        }

        return false;
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));

        const help_state = self.help.overlay.state;
        const recent_folders_state = self.recent_folders.overlay.state;
        const worktree_state = self.worktree.overlay.state;
        const pr_state = self.pr_dropdown.overlay.state;

        const help_started_expanding = self.last_help_state != .Expanding and help_state == .Expanding;
        const recent_folders_started_expanding = self.last_recent_folders_state != .Expanding and recent_folders_state == .Expanding;
        const worktree_started_expanding = self.last_worktree_state != .Expanding and worktree_state == .Expanding;
        const pr_started_expanding = self.last_pr_state != .Expanding and pr_state == .Expanding;

        // When one overlay starts expanding, collapse the others
        if (help_started_expanding) {
            if (recent_folders_state.isOpenOrOpening()) {
                self.recent_folders.overlay.startCollapsing(host.now_ms);
            }
            if (worktree_state.isOpenOrOpening()) {
                self.worktree.overlay.startCollapsing(host.now_ms);
            }
            if (pr_state == .Open or pr_state == .Expanding) {
                self.pr_dropdown.overlay.startCollapsing(host.now_ms);
            }
        }

        if (recent_folders_started_expanding) {
            if (help_state.isOpenOrOpening()) {
                self.help.overlay.startCollapsing(host.now_ms);
            }
            if (worktree_state.isOpenOrOpening()) {
                self.worktree.overlay.startCollapsing(host.now_ms);
            }
            if (pr_state == .Open or pr_state == .Expanding) {
                self.pr_dropdown.overlay.startCollapsing(host.now_ms);
            }
        }

        if (worktree_started_expanding) {
            if (help_state.isOpenOrOpening()) {
                self.help.overlay.startCollapsing(host.now_ms);
            }
            if (recent_folders_state.isOpenOrOpening()) {
                self.recent_folders.overlay.startCollapsing(host.now_ms);
            }
            if (pr_state == .Open or pr_state == .Expanding) {
                self.pr_dropdown.overlay.startCollapsing(host.now_ms);
            }
        }

        if (pr_started_expanding) {
            if (help_state == .Open or help_state == .Expanding) {
                self.help.overlay.startCollapsing(host.now_ms);
            }
            if (recent_folders_state == .Open or recent_folders_state == .Expanding) {
                self.recent_folders.overlay.startCollapsing(host.now_ms);
            }
            if (worktree_state == .Open or worktree_state == .Expanding) {
                self.worktree.overlay.startCollapsing(host.now_ms);
            }
        }

        const visible = [pill_count]bool{
            self.pr_dropdown.pillVisible(host),
            self.worktree.pillVisible(host),
            self.recent_folders.pillVisible(host),
            true,
        };
        if (self.layout.update(host.now_ms, host.window_w, host.ui_scale, visible)) {
            self.first_frame.markTransition();
        }
        self.applyLayout();

        self.last_help_state = help_state;
        self.last_recent_folders_state = recent_folders_state;
        self.last_worktree_state = worktree_state;
        self.last_pr_state = pr_state;
    }

    fn applyLayout(self: *PillGroupComponent) void {
        self.pr_dropdown.overlay.setLayoutX(self.layout.currentX(.pull_request));
        self.pr_dropdown.setPillInteractive(self.layout.pillInteractive(.pull_request));
        self.worktree.overlay.setLayoutX(self.layout.currentX(.worktree));
        self.worktree.setPillInteractive(self.layout.pillInteractive(.worktree));
        self.recent_folders.overlay.setLayoutX(self.layout.currentX(.recent_folders));
        self.recent_folders.setPillInteractive(self.layout.pillInteractive(.recent_folders));
        self.help.overlay.setLayoutX(self.layout.currentX(.help));
    }

    fn render(self_ptr: *anyopaque, _: *const types.UiHost, _: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        self.first_frame.markDrawn();
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        return self.layout.animating or self.first_frame.wantsFrame();
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        deinit(self_ptr, renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

test "pill layout packs visible pills against the right edge" {
    var layout: PillLayout = .{};
    const all_visible = [pill_count]bool{ true, true, true, true };
    _ = layout.update(0, 800, 1.0, all_visible);

    try std.testing.expectEqual(@as(c_int, 560), layout.currentX(.pull_request));
    try std.testing.expectEqual(@as(c_int, 620), layout.currentX(.worktree));
    try std.testing.expectEqual(@as(c_int, 680), layout.currentX(.recent_folders));
    try std.testing.expectEqual(@as(c_int, 740), layout.currentX(.help));

    const without_worktree = [pill_count]bool{ true, false, true, true };
    try std.testing.expect(layout.update(1, 800, 1.0, without_worktree));
    try std.testing.expectEqual(@as(c_int, 620), layout.target_x[@intFromEnum(PillKind.pull_request)]);
    try std.testing.expectEqual(@as(c_int, 680), layout.target_x[@intFromEnum(PillKind.recent_folders)]);
}

test "pill layout eases remaining pills into new positions" {
    var layout: PillLayout = .{};
    const all_visible = [pill_count]bool{ true, true, true, true };
    _ = layout.update(0, 800, 1.0, all_visible);

    const without_worktree = [pill_count]bool{ true, false, true, true };
    _ = layout.update(0, 800, 1.0, without_worktree);
    _ = layout.update(100, 800, 1.0, without_worktree);
    try std.testing.expectEqual(@as(c_int, 590), layout.currentX(.pull_request));
    try std.testing.expect(layout.animating);

    _ = layout.update(200, 800, 1.0, without_worktree);
    try std.testing.expectEqual(@as(c_int, 620), layout.currentX(.pull_request));
    try std.testing.expect(!layout.animating);
}

test "pill layout reports when easing reaches its final position" {
    var layout: PillLayout = .{};
    const all_visible = [pill_count]bool{ true, true, true, true };
    _ = layout.update(0, 800, 1.0, all_visible);

    const without_worktree = [pill_count]bool{ true, false, true, true };
    _ = layout.update(0, 800, 1.0, without_worktree);
    try std.testing.expect(layout.animating);

    try std.testing.expect(layout.update(pill_animation_duration_ms, 800, 1.0, without_worktree));
    try std.testing.expectEqual(@as(c_int, 620), layout.currentX(.pull_request));
    try std.testing.expect(!layout.animating);
}

test "pill layout eases a newly available pill into the compact row" {
    var layout: PillLayout = .{};
    const only_help = [pill_count]bool{ false, false, false, true };
    _ = layout.update(0, 800, 1.0, only_help);

    const pull_request_and_help = [pill_count]bool{ true, false, false, true };
    _ = layout.update(0, 800, 1.0, pull_request_and_help);
    _ = layout.update(100, 800, 1.0, pull_request_and_help);

    try std.testing.expectEqual(@as(c_int, 840), layout.currentX(.pull_request));
    try std.testing.expectEqual(@as(c_int, 740), layout.currentX(.help));

    _ = layout.update(200, 800, 1.0, pull_request_and_help);
    try std.testing.expectEqual(@as(c_int, 840), layout.currentX(.pull_request));

    _ = layout.update(300, 800, 1.0, pull_request_and_help);
    try std.testing.expectEqual(@as(c_int, 760), layout.currentX(.pull_request));

    _ = layout.update(400, 800, 1.0, pull_request_and_help);
    try std.testing.expectEqual(@as(c_int, 680), layout.currentX(.pull_request));
}

test "pill layout stages a newly available pill outside the occupied row" {
    var layout: PillLayout = .{};
    const pull_request_and_help = [pill_count]bool{ true, false, false, true };
    _ = layout.update(0, 800, 1.0, pull_request_and_help);

    const with_recent_folders = [pill_count]bool{ true, false, true, true };
    _ = layout.update(0, 800, 1.0, with_recent_folders);
    _ = layout.update(100, 800, 1.0, with_recent_folders);

    try std.testing.expectEqual(@as(c_int, 840), layout.currentX(.recent_folders));
    try std.testing.expectEqual(@as(c_int, 650), layout.currentX(.pull_request));

    _ = layout.update(200, 800, 1.0, with_recent_folders);
    try std.testing.expectEqual(@as(c_int, 840), layout.currentX(.recent_folders));
    try std.testing.expectEqual(@as(c_int, 620), layout.currentX(.pull_request));

    _ = layout.update(300, 800, 1.0, with_recent_folders);
    try std.testing.expectEqual(@as(c_int, 760), layout.currentX(.recent_folders));

    _ = layout.update(400, 800, 1.0, with_recent_folders);
    try std.testing.expectEqual(@as(c_int, 680), layout.currentX(.recent_folders));
    try std.testing.expectEqual(@as(c_int, 620), layout.currentX(.pull_request));
}

test "pill layout disables hit targets while positions are moving" {
    var layout: PillLayout = .{};
    const all_visible = [pill_count]bool{ true, true, true, true };
    _ = layout.update(0, 800, 1.0, all_visible);

    const without_worktree = [pill_count]bool{ true, false, true, true };
    _ = layout.update(0, 800, 1.0, without_worktree);
    try std.testing.expect(layout.pillInteractive(.pull_request));
    try std.testing.expect(layout.pillInteractive(.recent_folders));
    try std.testing.expect(layout.pillInteractive(.help));

    _ = layout.update(pill_animation_duration_ms, 800, 1.0, without_worktree);
    try std.testing.expect(layout.pillInteractive(.pull_request));
    try std.testing.expect(layout.pillInteractive(.recent_folders));
    try std.testing.expect(layout.pillInteractive(.help));

    const with_worktree = [pill_count]bool{ true, true, true, true };
    _ = layout.update(pill_animation_duration_ms, 800, 1.0, with_worktree);
    try std.testing.expect(!layout.pillInteractive(.worktree));
    try std.testing.expect(layout.pillInteractive(.pull_request));
    try std.testing.expect(layout.pillInteractive(.recent_folders));

    _ = layout.update(pill_animation_duration_ms + 50, 800, 1.0, with_worktree);
    try std.testing.expect(!layout.pillInteractive(.worktree));
    _ = layout.update(pill_animation_duration_ms * 3, 800, 1.0, with_worktree);
    try std.testing.expect(layout.pillInteractive(.worktree));
}

test "pill layout preserves an entrance position across a second layout change" {
    var layout: PillLayout = .{};
    const only_help = [pill_count]bool{ false, false, false, true };
    _ = layout.update(0, 800, 1.0, only_help);

    const with_pull_request = [pill_count]bool{ true, false, false, true };
    _ = layout.update(0, 800, 1.0, with_pull_request);
    _ = layout.update(250, 800, 1.0, with_pull_request);
    const position_before_second_change = layout.currentX(.pull_request);
    try std.testing.expect(position_before_second_change < 840);

    const with_recent_folders = [pill_count]bool{ true, false, true, true };
    _ = layout.update(250, 800, 1.0, with_recent_folders);
    try std.testing.expectEqual(position_before_second_change, layout.currentX(.pull_request));
    try std.testing.expect(!layout.pillInteractive(.pull_request));
}

test "pill group blocks clicks on entering pills" {
    var group = PillGroupComponent{
        .allocator = std.testing.allocator,
        .help = undefined,
        .recent_folders = undefined,
        .worktree = undefined,
        .pr_dropdown = undefined,
    };
    group.layout.initialized = true;
    group.layout.visible = [pill_count]bool{ true, false, false, true };
    group.layout.entering = [pill_count]bool{ true, false, false, false };
    group.layout.current_x = [pill_count]c_int{ 760, 0, 0, 740 };

    var host: types.UiHost = undefined;
    host.ui_scale = 1.0;
    var actions = types.UiActionQueue.init(std.testing.allocator);
    defer actions.deinit();

    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.x = 770;
    event.button.y = 30;
    try std.testing.expect(PillGroupComponent.handleEvent(&group, &host, &event, &actions));
    try std.testing.expect(group.pointer_blocked);

    group.layout.entering = [_]bool{false} ** pill_count;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.x = 500;
    event.button.y = 500;
    try std.testing.expect(PillGroupComponent.handleEvent(&group, &host, &event, &actions));
    try std.testing.expect(!group.pointer_blocked);
}
