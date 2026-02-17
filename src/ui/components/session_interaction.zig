const std = @import("std");
const c = @import("../../c.zig");
const ghostty_vt = @import("ghostty-vt");
const input = @import("../../input/mapper.zig");
const open_url = @import("../../os/open.zig");
const geom = @import("../../geom.zig");
const renderer_mod = @import("../../render/renderer.zig");
const session_state = @import("../../session/state.zig");
const url_matcher = @import("../../url_matcher.zig");
const font_mod = @import("../../font.zig");
const app_state = @import("../../app/app_state.zig");
const types = @import("../types.zig");
const scrollbar = @import("scrollbar.zig");
const view_state = @import("../session_view_state.zig");
const UiComponent = @import("../component.zig").UiComponent;

const log = std.log.scoped(.session_interaction);

const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;

const scroll_lines_per_tick: isize = 1;
const max_scroll_velocity: f32 = 30.0;
pub const wave_total_ms: i64 = 400;
pub const wave_row_anim_ms: i64 = 150;
pub const wave_amplitude: f32 = 0.08;
pub const wave_strip_height: i64 = 8;

const CursorKind = enum { arrow, ibeam, pointer };

pub const SessionInteractionComponent = struct {
    allocator: std.mem.Allocator,
    sessions: []*SessionState,
    views: []SessionViewState,
    font: *font_mod.Font,
    arrow_cursor: ?*c.SDL_Cursor = null,
    ibeam_cursor: ?*c.SDL_Cursor = null,
    pointer_cursor: ?*c.SDL_Cursor = null,
    current_cursor: CursorKind = .arrow,
    last_update_ms: i64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        sessions: []*SessionState,
        font: *font_mod.Font,
    ) !*SessionInteractionComponent {
        const self = try allocator.create(SessionInteractionComponent);
        errdefer allocator.destroy(self);

        const views = try allocator.alloc(SessionViewState, sessions.len);
        for (views) |*view| {
            view.* = .{};
        }
        errdefer allocator.free(views);

        self.* = .{
            .allocator = allocator,
            .sessions = sessions,
            .views = views,
            .font = font,
        };

        self.arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
        self.ibeam_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT);
        self.pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
        if (self.arrow_cursor) |cursor| {
            _ = c.SDL_SetCursor(cursor);
            self.current_cursor = .arrow;
        }

        return self;
    }

    pub fn asComponent(self: *SessionInteractionComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = -100,
        };
    }

    pub fn destroy(self: *SessionInteractionComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        for (self.views) |*view| {
            view.terminal_scrollbar.deinit();
        }
        if (self.arrow_cursor) |cursor| {
            c.SDL_DestroyCursor(cursor);
        }
        if (self.ibeam_cursor) |cursor| {
            c.SDL_DestroyCursor(cursor);
        }
        if (self.pointer_cursor) |cursor| {
            c.SDL_DestroyCursor(cursor);
        }
        self.allocator.free(self.views);
        self.allocator.destroy(self);
    }

    pub fn viewSlice(self: *SessionInteractionComponent) []SessionViewState {
        return self.views;
    }

    pub fn resetView(self: *SessionInteractionComponent, idx: usize) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        self.views[idx].reset();
        self.sessions[idx].markDirty();
    }

    pub fn clearSelection(self: *SessionInteractionComponent, idx: usize) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        view.clearSelection();
        view.clearHover();
        if (self.sessions[idx].terminal) |*terminal| {
            terminal.screens.active.clearSelection();
        }
        self.sessions[idx].markDirty();
    }

    pub fn setStatus(self: *SessionInteractionComponent, idx: usize, status: app_state.SessionStatus) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        if (view.status == status) return;
        view.status = status;
        self.sessions[idx].markDirty();
    }

    pub fn setAttention(self: *SessionInteractionComponent, idx: usize, attention: bool, now_ms: i64) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        if (attention) {
            view.wave_start_time = now_ms;
            view.attention = true;
            self.sessions[idx].markDirty();
        } else {
            if (!view.attention) return;
            view.attention = false;
            self.sessions[idx].markDirty();
        }
    }

    pub fn resetScrollIfNeeded(self: *SessionInteractionComponent, idx: usize) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        if (!view.is_viewing_scrollback) return;

        if (self.sessions[idx].terminal) |*terminal| {
            terminal.screens.active.pages.scroll(.{ .active = {} });
            view.clearScroll();
            self.sessions[idx].markDirty();
        }
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));

        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                if (event.button.button == c.SDL_BUTTON_LEFT and
                    self.handleTerminalScrollbarMouseDown(host, mouse_x, mouse_y))
                {
                    return true;
                }

                if (host.view_mode == .Grid) {
                    const grid_col_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, host.cell_w))), host.grid_cols - 1);
                    const grid_row_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, host.cell_h))), host.grid_rows - 1);
                    const clicked_session: usize = grid_row_idx * host.grid_cols + grid_col_idx;
                    if (clicked_session >= self.sessions.len) return false;

                    actions.append(.{ .FocusSession = clicked_session }) catch |err| {
                        log.warn("failed to queue focus action for session {d}: {}", .{ clicked_session, err });
                    };
                    return true;
                }

                if (host.view_mode == .Full and event.button.button == c.SDL_BUTTON_LEFT) {
                    const focused_idx = host.focused_session;
                    if (focused_idx >= self.sessions.len) return false;
                    const focused = self.sessions[focused_idx];
                    const view = &self.views[focused_idx];

                    if (focused.spawned and focused.terminal != null) {
                        if (fullViewPinFromMouse(focused, view, mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows)) |pin| {
                            const clicks = event.button.clicks;
                            if (clicks >= 3) {
                                selectLine(focused, view, pin);
                            } else if (clicks == 2) {
                                selectWord(focused, view, pin);
                            } else {
                                const mod = c.SDL_GetModState();
                                const cmd_held = (mod & c.SDL_KMOD_GUI) != 0;
                                if (cmd_held) {
                                    if (getLinkAtPin(self.allocator, &focused.terminal.?, pin, view.is_viewing_scrollback)) |uri| {
                                        defer self.allocator.free(uri);
                                        open_url.openUrl(self.allocator, uri) catch |err| {
                                            log.err("failed to open URL: {}", .{err});
                                        };
                                    } else {
                                        beginSelection(focused, view, pin);
                                    }
                                } else {
                                    beginSelection(focused, view, pin);
                                }
                            }
                            return true;
                        }
                    }
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT and self.finishTerminalScrollbarDrag(host.now_ms)) {
                    return true;
                }
                if (host.view_mode == .Full and event.button.button == c.SDL_BUTTON_LEFT) {
                    const focused_idx = host.focused_session;
                    if (focused_idx >= self.views.len) return false;
                    endSelection(&self.views[focused_idx]);
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);

                var desired_cursor: CursorKind = .arrow;
                const dragging_scrollbar = self.handleTerminalScrollbarDrag(host, mouse_x, mouse_y);
                const over_scrollbar = self.updateTerminalScrollbarHover(host, mouse_x, mouse_y) or dragging_scrollbar;

                if (!dragging_scrollbar and host.view_mode == .Full) {
                    const focused_idx = host.focused_session;
                    if (focused_idx < self.sessions.len) {
                        var focused = self.sessions[focused_idx];
                        const view = &self.views[focused_idx];
                        const pin = fullViewPinFromMouse(focused, view, mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows);

                        if (view.selection_dragging) {
                            if (pin) |p| {
                                updateSelectionDrag(focused, view, p);
                            }

                            const edge_threshold: c_int = 50;
                            const scroll_speed: isize = 1;
                            if (mouse_y < edge_threshold) {
                                scrollSession(focused, view, -scroll_speed, host.now_ms);
                            } else if (mouse_y > host.window_h - edge_threshold) {
                                scrollSession(focused, view, scroll_speed, host.now_ms);
                            }
                        } else if (view.selection_pending) {
                            if (view.selection_anchor) |anchor| {
                                if (pin) |p| {
                                    if (!pinsEqual(anchor, p)) {
                                        startSelectionDrag(focused, view, p);
                                    }
                                }
                            } else {
                                view.selection_pending = false;
                            }
                        }

                        if (!host.mouse_over_ui and pin != null and focused.terminal != null) {
                            const mod = c.SDL_GetModState();
                            const cmd_held = (mod & c.SDL_KMOD_GUI) != 0;

                            if (cmd_held) {
                                if (getLinkMatchAtPin(self.allocator, &focused.terminal.?, pin.?, view.is_viewing_scrollback)) |link_match| {
                                    desired_cursor = .pointer;
                                    view.hovered_link_start = link_match.start_pin;
                                    view.hovered_link_end = link_match.end_pin;
                                    self.allocator.free(link_match.url);
                                    focused.markDirty();
                                } else {
                                    desired_cursor = .ibeam;
                                    if (view.hovered_link_start != null) {
                                        view.clearHover();
                                        focused.markDirty();
                                    }
                                }
                            } else {
                                desired_cursor = .ibeam;
                                if (view.hovered_link_start != null) {
                                    view.clearHover();
                                    focused.markDirty();
                                }
                            }
                        } else {
                            if (view.hovered_link_start != null) {
                                view.clearHover();
                                focused.markDirty();
                            }
                        }
                    }
                }

                if (over_scrollbar) {
                    desired_cursor = .pointer;
                }
                self.updateCursor(desired_cursor);
                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const mouse_x: c_int = @intFromFloat(event.wheel.mouse_x);
                const mouse_y: c_int = @intFromFloat(event.wheel.mouse_y);

                const hovered_session = calculateHoveredSession(
                    mouse_x,
                    mouse_y,
                    host,
                );
                if (hovered_session) |session_idx| {
                    if (session_idx >= self.sessions.len) return false;
                    var session = self.sessions[session_idx];
                    const view = &self.views[session_idx];
                    const ticks_per_notch: isize = scroll_lines_per_tick;
                    const wheel_ticks: isize = if (event.wheel.integer_y != 0)
                        @as(isize, @intCast(event.wheel.integer_y)) * ticks_per_notch
                    else
                        @as(isize, @intFromFloat(event.wheel.y * @as(f32, @floatFromInt(scroll_lines_per_tick))));
                    const scroll_delta = -wheel_ticks;
                    if (scroll_delta != 0) {
                        const terminal_opt = session.terminal;
                        const should_forward = blk: {
                            if (host.view_mode != .Full) break :blk false;
                            if (view.is_viewing_scrollback) break :blk false;
                            const terminal = terminal_opt orelse break :blk false;
                            const mouse_tracking = terminal.modes.get(.mouse_event_normal) or
                                terminal.modes.get(.mouse_event_button) or
                                terminal.modes.get(.mouse_event_any) or
                                terminal.modes.get(.mouse_event_x10);
                            break :blk mouse_tracking;
                        };

                        var forwarded = false;
                        if (should_forward) {
                            if (terminal_opt) |terminal| {
                                if (fullViewCellFromMouse(mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows)) |cell| {
                                    forwarded = true;
                                    const sgr_format = terminal.modes.get(.mouse_format_sgr);
                                    const direction: input.MouseScrollDirection = if (scroll_delta < 0) .up else .down;
                                    const count = @abs(scroll_delta);
                                    var buf: [32]u8 = undefined;
                                    var i: usize = 0;
                                    while (i < count) : (i += 1) {
                                        const n = input.encodeMouseScroll(direction, cell.col, cell.row, sgr_format, &buf);
                                        if (n > 0) {
                                            session.sendInput(buf[0..n]) catch |err| {
                                                log.warn("session {d}: failed to send mouse scroll: {}", .{ session_idx, err });
                                            };
                                        }
                                    }
                                }
                            }
                        }

                        if (!forwarded) {
                            scrollSession(session, view, scroll_delta, host.now_ms);
                            if (event.wheel.which == c.SDL_TOUCH_MOUSEID) {
                                view.scroll_inertia_allowed = false;
                            }
                        }
                    }
                }
                return true;
            },
            else => {},
        }

        return false;
    }

    fn hitTest(_: *anyopaque, _: *const types.UiHost, _: c_int, _: c_int) bool {
        return false;
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));
        if (self.last_update_ms == 0) {
            self.last_update_ms = host.now_ms;
            return;
        }
        const delta_ms = host.now_ms - self.last_update_ms;
        self.last_update_ms = host.now_ms;
        if (delta_ms <= 0) return;

        const delta_time_s: f32 = @as(f32, @floatFromInt(delta_ms)) / 1000.0;
        for (self.sessions, 0..) |session, idx| {
            const view = &self.views[idx];
            updateScrollInertia(session, view, delta_time_s, host.now_ms);
            view.terminal_scrollbar.update(host.now_ms);
            if (view.wave_start_time > 0) {
                const wave_elapsed = host.now_ms - view.wave_start_time;
                if (wave_elapsed >= wave_total_ms) {
                    view.wave_start_time = 0;
                    session.markDirty();
                }
            }
        }
    }

    fn wantsFrame(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));
        for (self.views) |view| {
            if (view.scroll_velocity != 0.0) return true;
            if (view.wave_start_time > 0 and (host.now_ms - view.wave_start_time) < wave_total_ms) return true;
            if (view.terminal_scrollbar.wantsFrame(host.now_ms)) return true;
        }
        return false;
    }

    const ScrollbarContext = struct {
        session: *SessionState,
        view: *SessionViewState,
        metrics: scrollbar.Metrics,
        layout: scrollbar.Layout,
    };

    fn finishTerminalScrollbarDrag(self: *SessionInteractionComponent, now_ms: i64) bool {
        var handled = false;
        for (self.views) |*view| {
            if (view.terminal_scrollbar.dragging) {
                view.terminal_scrollbar.endDrag(now_ms);
                handled = true;
            }
        }
        return handled;
    }

    fn handleTerminalScrollbarMouseDown(self: *SessionInteractionComponent, host: *const types.UiHost, mouse_x: c_int, mouse_y: c_int) bool {
        const hovered_session = calculateHoveredSession(mouse_x, mouse_y, host) orelse return false;
        const ctx = self.terminalScrollbarContext(host, hovered_session) orelse return false;

        switch (scrollbar.hitTest(ctx.layout, mouse_x, mouse_y)) {
            .thumb => {
                ctx.view.terminal_scrollbar.beginDrag(ctx.layout, mouse_y, host.now_ms);
                ctx.session.markDirty();
                return true;
            },
            .track => {
                const target_offset = scrollbar.offsetForTrackClick(ctx.layout, ctx.metrics, mouse_y);
                self.applyTerminalScrollbarOffset(ctx, target_offset, host.now_ms);
                return true;
            },
            .none => return false,
        }
    }

    fn handleTerminalScrollbarDrag(self: *SessionInteractionComponent, host: *const types.UiHost, _: c_int, mouse_y: c_int) bool {
        for (self.views, 0..) |*view, idx| {
            if (!view.terminal_scrollbar.dragging) continue;
            if (self.terminalScrollbarContext(host, idx)) |ctx| {
                const target_offset = scrollbar.offsetForDrag(&view.terminal_scrollbar, ctx.layout, ctx.metrics, mouse_y);
                self.applyTerminalScrollbarOffset(ctx, target_offset, host.now_ms);
            } else {
                view.terminal_scrollbar.endDrag(host.now_ms);
            }
            return true;
        }
        return false;
    }

    fn updateTerminalScrollbarHover(self: *SessionInteractionComponent, host: *const types.UiHost, mouse_x: c_int, mouse_y: c_int) bool {
        const hovered_session = calculateHoveredSession(mouse_x, mouse_y, host);
        var over_scrollbar = false;

        for (self.views, 0..) |*view, idx| {
            if (view.terminal_scrollbar.dragging) {
                view.terminal_scrollbar.setHovered(true, host.now_ms);
                over_scrollbar = true;
                continue;
            }

            if (hovered_session != null and hovered_session.? == idx) {
                if (self.terminalScrollbarContext(host, idx)) |ctx| {
                    const hovered = scrollbar.hitTest(ctx.layout, mouse_x, mouse_y) != .none;
                    view.terminal_scrollbar.setHovered(hovered, host.now_ms);
                    if (hovered) {
                        over_scrollbar = true;
                    }
                } else {
                    view.terminal_scrollbar.setHovered(false, host.now_ms);
                }
                continue;
            }

            view.terminal_scrollbar.setHovered(false, host.now_ms);
        }

        return over_scrollbar;
    }

    fn terminalScrollbarContext(self: *SessionInteractionComponent, host: *const types.UiHost, session_idx: usize) ?ScrollbarContext {
        if (session_idx >= self.sessions.len or session_idx >= self.views.len) return null;
        const session = self.sessions[session_idx];
        if (!session.spawned) return null;
        const terminal = session.terminal orelse return null;
        const session_rect = sessionRectForIndex(host, session_idx) orelse return null;
        const content_rect = terminalContentRect(session_rect) orelse return null;
        const bar = terminal.screens.active.pages.scrollbar();
        const metrics = scrollbar.Metrics.init(
            @as(f32, @floatFromInt(bar.total)),
            @as(f32, @floatFromInt(bar.offset)),
            @as(f32, @floatFromInt(bar.len)),
        );
        const layout = scrollbar.computeLayout(content_rect, host.ui_scale, metrics) orelse return null;
        return .{
            .session = session,
            .view = &self.views[session_idx],
            .metrics = metrics,
            .layout = layout,
        };
    }

    fn applyTerminalScrollbarOffset(_: *SessionInteractionComponent, ctx: ScrollbarContext, raw_offset: f32, now_ms: i64) void {
        const clamped_offset = std.math.clamp(raw_offset, 0.0, ctx.metrics.maxOffset());
        if (ctx.session.terminal) |*terminal| {
            var pages = &terminal.screens.active.pages;
            const target_row: usize = @intFromFloat(std.math.round(clamped_offset));
            pages.scroll(.{ .row = target_row });
            ctx.view.is_viewing_scrollback = (pages.viewport != .active);
            ctx.view.scroll_velocity = 0.0;
            ctx.view.scroll_remainder = 0.0;
            ctx.view.scroll_inertia_allowed = false;
            ctx.view.last_scroll_time = now_ms;
            ctx.view.terminal_scrollbar.noteActivity(now_ms);
            ctx.session.markDirty();
        }
    }

    fn updateCursor(self: *SessionInteractionComponent, desired: CursorKind) void {
        if (desired == self.current_cursor) return;
        const target_cursor = switch (desired) {
            .arrow => self.arrow_cursor,
            .ibeam => self.ibeam_cursor,
            .pointer => self.pointer_cursor,
        };
        if (target_cursor) |cursor| {
            _ = c.SDL_SetCursor(cursor);
            self.current_cursor = desired;
        }
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = null,
        .hitTest = hitTest,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

const CellPosition = struct { col: u16, row: u16 };

fn fullViewCellFromMouse(
    mouse_x: c_int,
    mouse_y: c_int,
    render_width: c_int,
    render_height: c_int,
    font: *const font_mod.Font,
    term_cols: u16,
    term_rows: u16,
) ?CellPosition {
    const padding = renderer_mod.terminal_padding;
    const origin_x: c_int = padding;
    const origin_y: c_int = padding;
    const drawable_w: c_int = render_width - padding * 2;
    const drawable_h: c_int = render_height - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return null;

    const cell_w: c_int = font.cell_width;
    const cell_h: c_int = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return null;

    if (mouse_x < origin_x or mouse_y < origin_y) return null;
    if (mouse_x >= origin_x + drawable_w or mouse_y >= origin_y + drawable_h) return null;

    const col = @as(u16, @intCast(@divFloor(mouse_x - origin_x, cell_w)));
    const row = @as(u16, @intCast(@divFloor(mouse_y - origin_y, cell_h)));
    if (col >= term_cols or row >= term_rows) return null;

    return .{ .col = col, .row = row };
}

fn fullViewPinFromMouse(
    session: *SessionState,
    view: *SessionViewState,
    mouse_x: c_int,
    mouse_y: c_int,
    render_width: c_int,
    render_height: c_int,
    font: *const font_mod.Font,
    term_cols: u16,
    term_rows: u16,
) ?ghostty_vt.Pin {
    if (!session.spawned or session.terminal == null) return null;

    const padding = renderer_mod.terminal_padding;
    const origin_x: c_int = padding;
    const origin_y: c_int = padding;
    const drawable_w: c_int = render_width - padding * 2;
    const drawable_h: c_int = render_height - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return null;

    const cell_w: c_int = font.cell_width;
    const cell_h: c_int = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return null;

    if (mouse_x < origin_x or mouse_y < origin_y) return null;
    if (mouse_x >= origin_x + drawable_w or mouse_y >= origin_y + drawable_h) return null;

    const col = @as(u16, @intCast(@divFloor(mouse_x - origin_x, cell_w)));
    const row = @as(u16, @intCast(@divFloor(mouse_y - origin_y, cell_h)));
    if (col >= term_cols or row >= term_rows) return null;

    const point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = col, .y = row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = col, .y = row } };

    const terminal = session.terminal orelse return null;
    return terminal.screens.active.pages.pin(point);
}

fn beginSelection(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = session.terminal orelse return;
    terminal.screens.active.clearSelection();
    view.selection_anchor = pin;
    view.selection_pending = true;
    view.selection_dragging = false;
    session.markDirty();
}

fn startSelectionDrag(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = session.terminal orelse return;
    const anchor = view.selection_anchor orelse return;

    view.selection_dragging = true;
    view.selection_pending = false;

    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(anchor, pin, false)) catch |err| {
        log.warn("session {d}: failed to start selection: {}", .{ session.id, err });
    };
    session.markDirty();
}

fn updateSelectionDrag(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    if (!view.selection_dragging) return;
    const anchor = view.selection_anchor orelse return;
    const terminal = session.terminal orelse return;
    terminal.screens.active.select(ghostty_vt.Selection.init(anchor, pin, false)) catch |err| {
        log.warn("session {d}: failed to update selection: {}", .{ session.id, err });
    };
    session.markDirty();
}

fn endSelection(view: *SessionViewState) void {
    view.selection_dragging = false;
    view.selection_pending = false;
    view.selection_anchor = null;
}

fn pinsEqual(a: ghostty_vt.Pin, b: ghostty_vt.Pin) bool {
    return a.node == b.node and a.x == b.x and a.y == b.y;
}

fn isWordCharacter(codepoint: u21) bool {
    if (codepoint > 127) return false;
    const ch: u8 = @intCast(codepoint);
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn selectWord(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = &(session.terminal orelse return);
    const page = &pin.node.data;
    const max_col: u16 = @intCast(page.size.cols - 1);

    const pin_point = if (view.is_viewing_scrollback)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point = pin_point orelse return;
    const click_x = if (view.is_viewing_scrollback) point.viewport.x else point.active.x;
    const click_y = if (view.is_viewing_scrollback) point.viewport.y else point.active.y;

    const clicked_cell = terminal.screens.active.pages.getCell(
        if (view.is_viewing_scrollback)
            ghostty_vt.point.Point{ .viewport = .{ .x = click_x, .y = click_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = click_x, .y = click_y } },
    ) orelse return;
    const clicked_cp = clicked_cell.cell.content.codepoint;
    if (!isWordCharacter(clicked_cp)) return;

    var start_x = click_x;
    while (start_x > 0) {
        const prev_x = start_x - 1;
        const prev_cell = terminal.screens.active.pages.getCell(
            if (view.is_viewing_scrollback)
                ghostty_vt.point.Point{ .viewport = .{ .x = prev_x, .y = click_y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = prev_x, .y = click_y } },
        ) orelse break;
        if (!isWordCharacter(prev_cell.cell.content.codepoint)) break;
        start_x = prev_x;
    }

    var end_x = click_x;
    while (end_x < max_col) {
        const next_x = end_x + 1;
        const next_cell = terminal.screens.active.pages.getCell(
            if (view.is_viewing_scrollback)
                ghostty_vt.point.Point{ .viewport = .{ .x = next_x, .y = click_y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = next_x, .y = click_y } },
        ) orelse break;
        if (!isWordCharacter(next_cell.cell.content.codepoint)) break;
        end_x = next_x;
    }

    const start_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = start_x, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = start_x, .y = click_y } };
    const end_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = end_x, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = end_x, .y = click_y } };

    const start_pin = terminal.screens.active.pages.pin(start_point) orelse return;
    const end_pin = terminal.screens.active.pages.pin(end_point) orelse return;

    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(start_pin, end_pin, false)) catch |err| {
        log.err("failed to select word: {}", .{err});
        return;
    };
    session.markDirty();
}

fn selectLine(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = &(session.terminal orelse return);
    const page = &pin.node.data;
    const max_col: u16 = @intCast(page.size.cols - 1);

    const pin_point = if (view.is_viewing_scrollback)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point = pin_point orelse return;
    const click_y = if (view.is_viewing_scrollback) point.viewport.y else point.active.y;

    const start_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = 0, .y = click_y } };
    const end_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = max_col, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = max_col, .y = click_y } };

    const start_pin = terminal.screens.active.pages.pin(start_point) orelse return;
    const end_pin = terminal.screens.active.pages.pin(end_point) orelse return;

    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(start_pin, end_pin, false)) catch |err| {
        log.err("failed to select line: {}", .{err});
        return;
    };
    session.markDirty();
}

const LinkMatch = struct {
    url: []u8,
    start_pin: ghostty_vt.Pin,
    end_pin: ghostty_vt.Pin,
};

fn getLinkMatchAtPin(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, pin: ghostty_vt.Pin, is_viewing_scrollback: bool) ?LinkMatch {
    const page = &pin.node.data;
    const row_and_cell = pin.rowAndCell();
    const cell = row_and_cell.cell;

    if (page.lookupHyperlink(cell)) |hyperlink_id| {
        const entry = page.hyperlink_set.get(page.memory, hyperlink_id);
        const url = allocator.dupe(u8, entry.uri.slice(page.memory)) catch return null;
        return LinkMatch{
            .url = url,
            .start_pin = pin,
            .end_pin = pin,
        };
    }

    const pin_point = if (is_viewing_scrollback)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point_or_null = pin_point orelse return null;
    const start_y_orig = if (is_viewing_scrollback) point_or_null.viewport.y else point_or_null.active.y;

    var start_y = start_y_orig;
    var current_row = row_and_cell.row;

    while (current_row.wrap_continuation and start_y > 0) {
        start_y -= 1;
        const prev_point = if (is_viewing_scrollback)
            ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = start_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = 0, .y = start_y } };
        const prev_pin = terminal.screens.active.pages.pin(prev_point) orelse break;
        current_row = prev_pin.rowAndCell().row;
    }

    var end_y = start_y_orig;
    current_row = row_and_cell.row;
    const max_y: u16 = @intCast(page.size.rows - 1);

    while (current_row.wrap and end_y < max_y) {
        end_y += 1;
        const next_point = if (is_viewing_scrollback)
            ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = end_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = 0, .y = end_y } };
        const next_pin = terminal.screens.active.pages.pin(next_point) orelse break;
        current_row = next_pin.rowAndCell().row;
    }

    const max_x: u16 = @intCast(page.size.cols - 1);
    const row_start_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = start_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = 0, .y = start_y } };
    const row_end_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = max_x, .y = end_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = max_x, .y = end_y } };
    const row_start_pin = terminal.screens.active.pages.pin(row_start_point) orelse return null;
    const row_end_pin = terminal.screens.active.pages.pin(row_end_point) orelse return null;

    const selection = ghostty_vt.Selection.init(row_start_pin, row_end_pin, false);
    const row_text = terminal.screens.active.selectionString(allocator, .{
        .sel = selection,
        .trim = false,
    }) catch return null;
    defer allocator.free(row_text);

    var cell_to_byte: std.ArrayList(usize) = .empty;
    defer cell_to_byte.deinit(allocator);

    var byte_pos: usize = 0;
    var cell_idx: usize = 0;
    var y = start_y;
    while (y <= end_y) : (y += 1) {
        var x: u16 = 0;
        while (x < page.size.cols) : (x += 1) {
            const point = if (is_viewing_scrollback)
                ghostty_vt.point.Point{ .viewport = .{ .x = x, .y = y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = x, .y = y } };
            const list_cell = terminal.screens.active.pages.getCell(point) orelse {
                cell_to_byte.append(allocator, byte_pos) catch return null;
                cell_idx += 1;
                continue;
            };

            cell_to_byte.append(allocator, byte_pos) catch return null;

            const list_cell_cell = list_cell.cell;
            const cp = list_cell_cell.content.codepoint;
            const encoded_len: usize = blk: {
                if (cp != 0 and cp != ' ') {
                    var utf8_buf: [4]u8 = undefined;
                    break :blk std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                }
                break :blk 1;
            };

            if (list_cell_cell.wide == .wide) {
                byte_pos += encoded_len;
                if (x + 1 < page.size.cols) {
                    x += 1;
                    const char_start_pos = cell_to_byte.items[cell_to_byte.items.len - 1];
                    cell_to_byte.append(allocator, char_start_pos) catch return null;
                    cell_idx += 1;
                }
            } else {
                byte_pos += encoded_len;
            }
            cell_idx += 1;
        }
        if (y < end_y) {
            byte_pos += 1;
        }
    }

    const pin_x = if (is_viewing_scrollback) point_or_null.viewport.x else point_or_null.active.x;
    const click_cell_idx = (start_y_orig - start_y) * page.size.cols + pin_x;
    if (click_cell_idx >= cell_to_byte.items.len) return null;
    const click_byte_pos = cell_to_byte.items[click_cell_idx];

    const url_match = url_matcher.findUrlMatchAtPosition(row_text, click_byte_pos) orelse return null;

    var start_cell_idx: usize = 0;
    for (cell_to_byte.items, 0..) |byte, idx| {
        if (byte >= url_match.start) {
            start_cell_idx = idx;
            break;
        }
    }

    var end_cell_idx: usize = cell_to_byte.items.len - 1;
    for (cell_to_byte.items, 0..) |byte, idx| {
        if (byte >= url_match.end) {
            end_cell_idx = if (idx > 0) idx - 1 else 0;
            break;
        }
    }

    const start_row = start_y + @as(u16, @intCast(start_cell_idx / page.size.cols));
    const start_col: u16 = @intCast(start_cell_idx % page.size.cols);
    const end_row = start_y + @as(u16, @intCast(end_cell_idx / page.size.cols));
    const end_col: u16 = @intCast(end_cell_idx % page.size.cols);

    const link_start_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = start_col, .y = start_row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = start_col, .y = start_row } };
    const link_end_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = end_col, .y = end_row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = end_col, .y = end_row } };
    const link_start_pin = terminal.screens.active.pages.pin(link_start_point) orelse return null;
    const link_end_pin = terminal.screens.active.pages.pin(link_end_point) orelse return null;

    const url = allocator.dupe(u8, url_match.url) catch return null;

    return LinkMatch{
        .url = url,
        .start_pin = link_start_pin,
        .end_pin = link_end_pin,
    };
}

fn getLinkAtPin(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, pin: ghostty_vt.Pin, is_viewing_scrollback: bool) ?[]u8 {
    if (getLinkMatchAtPin(allocator, terminal, pin, is_viewing_scrollback)) |match| {
        return match.url;
    }
    return null;
}

fn scrollSession(session: *SessionState, view: *SessionViewState, delta: isize, now: i64) void {
    if (!session.spawned) return;

    view.last_scroll_time = now;
    view.scroll_remainder = 0.0;
    view.scroll_inertia_allowed = true;

    if (session.terminal) |*terminal| {
        var pages = &terminal.screens.active.pages;
        pages.scroll(.{ .delta_row = delta });
        view.is_viewing_scrollback = (pages.viewport != .active);
        view.terminal_scrollbar.noteActivity(now);
        session.markDirty();
    }

    const sensitivity: f32 = 0.08;
    view.scroll_velocity += @as(f32, @floatFromInt(delta)) * sensitivity;
    view.scroll_velocity = std.math.clamp(view.scroll_velocity, -max_scroll_velocity, max_scroll_velocity);
}

fn updateScrollInertia(session: *SessionState, view: *SessionViewState, delta_time_s: f32, now_ms: i64) void {
    if (!session.spawned) return;
    if (!view.scroll_inertia_allowed) return;
    if (view.scroll_velocity == 0.0) return;
    if (view.last_scroll_time == 0) return;

    const decay_constant: f32 = 7.5;
    const decay_factor = std.math.exp(-decay_constant * delta_time_s);
    const velocity_threshold: f32 = 0.12;

    if (@abs(view.scroll_velocity) < velocity_threshold) {
        view.scroll_velocity = 0.0;
        view.scroll_remainder = 0.0;
        return;
    }

    const reference_fps: f32 = 60.0;

    if (session.terminal) |*terminal| {
        const scroll_amount = view.scroll_velocity * delta_time_s * reference_fps + view.scroll_remainder;
        const scroll_lines: isize = @intFromFloat(scroll_amount);

        if (scroll_lines != 0) {
            var pages = &terminal.screens.active.pages;
            pages.scroll(.{ .delta_row = scroll_lines });
            view.is_viewing_scrollback = (pages.viewport != .active);
            view.terminal_scrollbar.noteActivity(now_ms);
            session.markDirty();
        }

        view.scroll_remainder = scroll_amount - @as(f32, @floatFromInt(scroll_lines));
    }

    view.scroll_velocity *= decay_factor;
}

fn calculateHoveredSession(
    mouse_x: c_int,
    mouse_y: c_int,
    host: *const types.UiHost,
) ?usize {
    return switch (host.view_mode) {
        .Grid, .GridResizing => {
            if (mouse_x < 0 or mouse_x >= host.window_w or
                mouse_y < 0 or mouse_y >= host.window_h) return null;

            const grid_col_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, host.cell_w))), host.grid_cols - 1);
            const grid_row_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, host.cell_h))), host.grid_rows - 1);
            return grid_row_idx * host.grid_cols + grid_col_idx;
        },
        .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => host.focused_session,
        .Expanding, .Collapsing => {
            const rect = host.animating_rect orelse return host.focused_session;
            if (mouse_x >= rect.x and mouse_x < rect.x + rect.w and
                mouse_y >= rect.y and mouse_y < rect.y + rect.h)
            {
                return host.focused_session;
            }
            return null;
        },
    };
}

fn sessionRectForIndex(host: *const types.UiHost, idx: usize) ?geom.Rect {
    return switch (host.view_mode) {
        .Grid, .GridResizing => {
            const max_slots = host.grid_cols * host.grid_rows;
            if (idx >= max_slots) return null;
            const grid_col: c_int = @intCast(idx % host.grid_cols);
            const grid_row: c_int = @intCast(idx / host.grid_cols);
            return .{
                .x = grid_col * host.cell_w,
                .y = grid_row * host.cell_h,
                .w = host.cell_w,
                .h = host.cell_h,
            };
        },
        .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => {
            if (idx != host.focused_session) return null;
            return .{ .x = 0, .y = 0, .w = host.window_w, .h = host.window_h };
        },
        .Expanding, .Collapsing => {
            if (idx != host.focused_session) return null;
            return host.animating_rect orelse geom.Rect{ .x = 0, .y = 0, .w = host.window_w, .h = host.window_h };
        },
    };
}

fn terminalContentRect(session_rect: geom.Rect) ?geom.Rect {
    const padding = renderer_mod.terminal_padding;
    const w = session_rect.w - padding * 2;
    const h = session_rect.h - padding * 2;
    if (w <= 0 or h <= 0) return null;
    return .{
        .x = session_rect.x + padding,
        .y = session_rect.y + padding,
        .w = w,
        .h = h,
    };
}
