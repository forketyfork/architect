const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const dpi = @import("../../dpi.zig");
const primitives = @import("../../gfx/primitives.zig");
const font_cache = @import("../../font_cache.zig");
const session_state = @import("../../session/state.zig");
const text_render = @import("../text_render.zig");
const text_edit = @import("../text_edit.zig");
const diff_comment_layout = @import("diff_comment_layout.zig");
const modal_frame = @import("modal_frame.zig");
const scrollbar = @import("scrollbar.zig");
const types = @import("../types.zig");
const first_frame = @import("../first_frame_guard.zig");
const UiComponent = @import("../component.zig").UiComponent;

const log = std.log.scoped(.selection_agent_overlay);

const AgentKind = session_state.AgentKind;
const agent_count: usize = @typeInfo(AgentKind).@"enum".fields.len;
const modal_width: c_int = 760;
const modal_height: c_int = 620;
const modal_margin: c_int = 28;
const modal_radius: c_int = 14;
const padding: c_int = 28;
const title_height: c_int = 32;
const field_height: c_int = 42;
const prompt_height: c_int = 150;
const context_height: c_int = 115;
const cancel_button_width: c_int = 112;
const button_width: c_int = 132;
const button_height: c_int = 42;
const button_gap: c_int = 12;
const dropdown_item_height: c_int = 36;
const prompt_max_len: usize = 64 * 1024;
const wrap_tab_width: usize = 4;
const wrap_min_printable: u8 = 32;

const TextTexture = text_render.TextTex;

fn agentKindAt(index: usize) AgentKind {
    return @enumFromInt(index);
}

const PromptLine = struct {
    text: []const u8 = &.{},
    tex: ?*c.SDL_Texture = null,
    w: c_int = 0,
    h: c_int = 0,
    used: bool = false,
};

const ContextLine = struct {
    tex: ?*c.SDL_Texture = null,
    w: c_int = 0,
    h: c_int = 0,
};

const WrappedRangeCollector = struct {
    ranges: []diff_comment_layout.WrappedLine,
    count: usize = 0,
};

fn collectWrappedLine(context: *WrappedRangeCollector, line: diff_comment_layout.WrappedLine) void {
    if (context.count < context.ranges.len) context.ranges[context.count] = line;
    context.count += 1;
}

fn promptWrapCols(font: *c.TTF_Font, rect: geom.Rect, ui_scale: f32) usize {
    const inner = dpi.scale(10, ui_scale);
    const usable_width = @max(@as(c_int, 1), rect.w - inner * 2);
    const sample = "M";
    var char_width: c_int = 0;
    var char_height: c_int = 0;
    _ = c.TTF_GetStringSize(font, sample.ptr, sample.len, &char_width, &char_height);
    const measured_width = @max(@as(c_int, 1), char_width);
    return @max(
        @as(usize, 1),
        @as(usize, @intCast(@divFloor(usable_width, measured_width))),
    );
}

fn contextWrapCols(font: *c.TTF_Font, rect: geom.Rect, ui_scale: f32) usize {
    const inner = dpi.scale(10, ui_scale);
    const usable_width = @max(
        @as(c_int, 1),
        rect.w - inner * 2 - scrollbar.reservedWidth(ui_scale),
    );
    var char_width: c_int = 0;
    var char_height: c_int = 0;
    _ = c.TTF_GetStringSize(font, "M".ptr, 1, &char_width, &char_height);
    return @max(
        @as(usize, 1),
        @as(usize, @intCast(@divFloor(usable_width, @max(@as(c_int, 1), char_width)))),
    );
}

fn dropdownItemAt(rect: geom.Rect, item_height: c_int, item_count: usize, x: c_int, y: c_int) ?usize {
    if (item_height <= 0 or !geom.containsPoint(rect, x, y)) return null;
    const index: usize = @intCast(@divFloor(y - rect.y, item_height));
    return if (index < item_count) index else null;
}

fn contextScrollMetricsForLineCount(
    line_count: usize,
    line_height: c_int,
    inner_padding: c_int,
    viewport_height: c_int,
    offset: f32,
) scrollbar.Metrics {
    const content_height = @as(f32, @floatFromInt(line_count)) *
        @as(f32, @floatFromInt(line_height)) +
        @as(f32, @floatFromInt(inner_padding * 2));
    return scrollbar.Metrics.init(content_height, offset, @floatFromInt(viewport_height));
}

pub const SelectionAgentOverlayComponent = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    dropdown_open: bool = false,
    selected_agent: usize = 0,
    source_session_id: usize = 0,
    selected_text: ?[]const u8 = null,
    prompt: text_edit.TextInput = .{
        .separators = text_edit.prose_separators,
        .max_len = prompt_max_len,
    },
    prompt_focused: bool = true,
    cancel_hovered: bool = false,
    launch_hovered: bool = false,
    selector_hovered: bool = false,
    dropdown_hovered_agent: ?usize = null,
    context_scrollbar: scrollbar.State = .{},
    context_scroll_offset: f32 = 0,
    guard: first_frame.FirstFrameGuard = .{},

    static_generation: u64 = 0,
    static_font_size: c_int = 0,
    title_tex: ?TextTexture = null,
    label_tex: ?TextTexture = null,
    prompt_label_tex: ?TextTexture = null,
    context_label_tex: ?TextTexture = null,
    cancel_tex: ?TextTexture = null,
    launch_tex: ?TextTexture = null,
    placeholder_tex: ?TextTexture = null,
    agent_tex: [agent_count]?TextTexture = [_]?TextTexture{null} ** agent_count,

    prompt_lines: []PromptLine = &.{},
    prompt_generation: u64 = 0,
    prompt_font_size: c_int = 0,
    prompt_text_len: usize = 0,
    prompt_text_hash: u64 = 0,
    prompt_rect_width: c_int = 0,

    context_lines: []ContextLine = &.{},
    context_preview_generation: u64 = 0,
    context_preview_font_size: c_int = 0,
    context_preview_rect_width: c_int = 0,

    pub fn init(allocator: std.mem.Allocator) !*SelectionAgentOverlayComponent {
        const self = try allocator.create(SelectionAgentOverlayComponent);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn asComponent(self: *SelectionAgentOverlayComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 2100,
        };
    }

    pub fn open(self: *SelectionAgentOverlayComponent, selected_text: []const u8, session_id: usize, now_ms: i64) void {
        self.releaseSelectedText();
        self.invalidateContextPreview();
        self.selected_text = selected_text;
        self.source_session_id = session_id;
        self.selected_agent = 0;
        self.dropdown_open = false;
        self.dropdown_hovered_agent = null;
        self.prompt.clear();
        self.prompt.touch(now_ms);
        self.prompt_focused = true;
        self.cancel_hovered = false;
        self.launch_hovered = false;
        self.selector_hovered = false;
        self.context_scroll_offset = 0;
        self.context_scrollbar.hideNow();
        self.visible = true;
        self.guard.markTransition();
    }

    pub fn destroy(self: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.invalidateStaticTextures();
        self.invalidatePromptLines();
        self.invalidateContextPreview();
        self.context_scrollbar.deinit();
        self.prompt.deinit(self.allocator);
        self.releaseSelectedText();
        self.allocator.destroy(self);
    }

    fn releaseSelectedText(self: *SelectionAgentOverlayComponent) void {
        if (self.selected_text) |text| {
            self.allocator.free(text);
            self.selected_text = null;
        }
    }

    fn close(self: *SelectionAgentOverlayComponent) void {
        self.visible = false;
        self.dropdown_open = false;
        self.dropdown_hovered_agent = null;
        self.releaseSelectedText();
        self.prompt.clear();
        self.cancel_hovered = false;
        self.launch_hovered = false;
        self.selector_hovered = false;
        self.context_scrollbar.hideNow();
        self.guard.markTransition();
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *SelectionAgentOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return false;

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                if (self.dropdown_open) {
                    if (key == c.SDLK_ESCAPE) {
                        self.dropdown_open = false;
                        self.dropdown_hovered_agent = null;
                        self.prompt_focused = true;
                        return true;
                    }
                    if (key == c.SDLK_UP or key == c.SDLK_DOWN) {
                        const direction: isize = if (key == c.SDLK_UP) -1 else 1;
                        const next = @as(isize, @intCast(self.selected_agent)) + direction;
                        self.selected_agent = @intCast(@mod(next + @as(isize, agent_count), @as(isize, agent_count)));
                        self.dropdown_hovered_agent = null;
                        return true;
                    }
                    if (key == c.SDLK_RETURN or key == c.SDLK_RETURN2 or key == c.SDLK_KP_ENTER) {
                        if (self.dropdown_hovered_agent) |hovered| self.selected_agent = hovered;
                        self.dropdown_open = false;
                        self.dropdown_hovered_agent = null;
                        self.prompt_focused = true;
                        return true;
                    }
                    return true;
                }

                if (modal_frame.isDismissKey(key, mod)) {
                    self.close();
                    return true;
                }
                if (key == c.SDLK_RETURN or key == c.SDLK_RETURN2 or key == c.SDLK_KP_ENTER) {
                    if ((mod & c.SDL_KMOD_SHIFT) != 0) {
                        _ = self.prompt.insert(self.allocator, "\n", host.now_ms);
                    } else {
                        self.queueLaunch(actions);
                    }
                    return true;
                }
                const result = self.prompt.handleKey(self.allocator, key, mod, host.now_ms);
                _ = result;
                return true;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                _ = self.prompt.insert(self.allocator, std.mem.span(event.text.text), host.now_ms);
                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                if (!self.dropdown_open) {
                    const modal = self.modalRect(host);
                    const context = self.contextRect(host, modal);
                    const metrics = self.contextScrollMetrics(host, context);
                    if (metrics.isScrollable()) {
                        const scroll_step: f32 = @floatFromInt(dpi.scale(46, host.ui_scale));
                        self.context_scroll_offset = std.math.clamp(
                            metrics.offset - event.wheel.y * scroll_step,
                            0,
                            metrics.maxOffset(),
                        );
                        self.context_scrollbar.noteActivity(host.now_ms);
                    }
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const modal = self.modalRect(host);

                if (self.dropdown_open) {
                    const dropdown = self.dropdownRect(host, self.selectorRect(host, modal));
                    const item_height = dpi.scale(dropdown_item_height, host.ui_scale);
                    if (dropdownItemAt(dropdown, item_height, agent_count, mouse_x, mouse_y)) |item_idx|
                        self.selected_agent = item_idx;
                    self.dropdown_open = false;
                    self.dropdown_hovered_agent = null;
                    self.prompt_focused = true;
                    return true;
                }

                if (!geom.containsPoint(modal, mouse_x, mouse_y)) {
                    self.close();
                    return true;
                }
                if (geom.containsPoint(self.selectorRect(host, modal), mouse_x, mouse_y)) {
                    self.dropdown_open = true;
                    self.dropdown_hovered_agent = self.selected_agent;
                    self.prompt_focused = false;
                    self.context_scrollbar.endDrag(host.now_ms);
                    return true;
                }
                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    const context = self.contextRect(host, modal);
                    const metrics = self.contextScrollMetrics(host, context);
                    if (scrollbar.computeLayout(context, host.ui_scale, metrics)) |layout| {
                        switch (scrollbar.hitTest(layout, mouse_x, mouse_y)) {
                            .thumb => {
                                self.context_scrollbar.beginDrag(layout, mouse_y, host.now_ms);
                                return true;
                            },
                            .track => {
                                self.context_scroll_offset = scrollbar.offsetForTrackClick(layout, metrics, mouse_y);
                                self.context_scrollbar.noteActivity(host.now_ms);
                                return true;
                            },
                            .none => {},
                        }
                    }
                }
                if (geom.containsPoint(self.promptRect(host, modal), mouse_x, mouse_y)) {
                    self.prompt_focused = true;
                    self.prompt.touch(host.now_ms);
                    return true;
                }
                if (event.button.button == c.SDL_BUTTON_LEFT and
                    geom.containsPoint(self.cancelRect(host, modal), mouse_x, mouse_y))
                {
                    self.close();
                    return true;
                }
                if (event.button.button == c.SDL_BUTTON_LEFT and
                    geom.containsPoint(self.launchRect(host, modal), mouse_x, mouse_y))
                {
                    self.queueLaunch(actions);
                    return true;
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                const modal = self.modalRect(host);
                self.cancel_hovered = geom.containsPoint(self.cancelRect(host, modal), mouse_x, mouse_y);
                self.launch_hovered = geom.containsPoint(self.launchRect(host, modal), mouse_x, mouse_y);
                self.selector_hovered = geom.containsPoint(self.selectorRect(host, modal), mouse_x, mouse_y);
                if (self.dropdown_open) {
                    const dropdown = self.dropdownRect(host, self.selectorRect(host, modal));
                    self.dropdown_hovered_agent = dropdownItemAt(
                        dropdown,
                        dpi.scale(dropdown_item_height, host.ui_scale),
                        agent_count,
                        mouse_x,
                        mouse_y,
                    );
                    self.context_scrollbar.setHovered(false, host.now_ms);
                } else {
                    const context = self.contextRect(host, modal);
                    const metrics = self.contextScrollMetrics(host, context);
                    const layout = scrollbar.computeLayout(context, host.ui_scale, metrics);
                    if (self.context_scrollbar.dragging) {
                        if (layout) |value| {
                            self.context_scroll_offset = scrollbar.offsetForDrag(
                                &self.context_scrollbar,
                                value,
                                metrics,
                                mouse_y,
                            );
                            self.context_scrollbar.noteActivity(host.now_ms);
                        } else {
                            self.context_scrollbar.endDrag(host.now_ms);
                        }
                    }
                    const hit = if (layout) |value| scrollbar.hitTest(value, mouse_x, mouse_y) else .none;
                    self.context_scrollbar.setHovered(self.context_scrollbar.dragging or hit != .none, host.now_ms);
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT and self.context_scrollbar.dragging)
                    self.context_scrollbar.endDrag(host.now_ms);
                return true;
            },
            else => return true,
        }
    }

    fn queueLaunch(self: *SelectionAgentOverlayComponent, actions: *types.UiActionQueue) void {
        const selected_text = self.selected_text orelse return;
        const prompt = formatAgentPrompt(self.allocator, self.prompt.text(), selected_text) catch |err| {
            log.warn("failed to format selection agent prompt: {}", .{err});
            return;
        };
        const agent_command = self.allocator.dupe(u8, agentKindAt(self.selected_agent).name()) catch |err| {
            log.warn("failed to copy selection agent command: {}", .{err});
            self.allocator.free(prompt);
            return;
        };
        actions.append(.{ .LaunchAgentWithContext = .{
            .session_id = self.source_session_id,
            .agent_command = agent_command,
            .prompt = prompt,
        } }) catch |err| {
            log.warn("failed to queue selection agent launch: {}", .{err});
            self.allocator.free(agent_command);
            self.allocator.free(prompt);
            return;
        };
        self.close();
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *SelectionAgentOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return false;
        const modal = self.modalRect(host);
        return geom.containsPoint(modal, x, y) or
            (self.dropdown_open and geom.containsPoint(self.dropdownRect(host, self.selectorRect(host, modal)), x, y));
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *SelectionAgentOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.context_scrollbar.update(host.now_ms);
    }

    fn wantsFrame(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *SelectionAgentOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.visible and (self.guard.wantsFrame() or
            self.prompt_focused or
            self.context_scrollbar.wantsFrame(host.now_ms));
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *SelectionAgentOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;
        const cache = assets.font_cache orelse return;
        const modal = self.modalRect(host);
        const prompt = self.promptRect(host, modal);
        const context = self.contextRect(host, modal);

        self.ensureStaticTextures(renderer, host, cache) catch |err| {
            log.warn("failed to render selection agent overlay labels: {}", .{err});
            return;
        };
        self.ensurePromptLines(renderer, host, cache, prompt) catch |err| {
            log.warn("failed to render selection agent prompt: {}", .{err});
            return;
        };
        self.ensureContextPreview(renderer, host, cache, context) catch |err| {
            log.warn("failed to render selected terminal context preview: {}", .{err});
            return;
        };

        const modal_radius_px = dpi.scale(modal_radius, host.ui_scale);
        modal_frame.renderScrimAndPanel(renderer, host, modal, modal_radius_px);

        self.renderStaticTexture(renderer, self.title_tex, modal.x + dpi.scale(padding, host.ui_scale), modal.y + dpi.scale(padding, host.ui_scale));

        const scaled_padding = dpi.scale(padding, host.ui_scale);
        const label_x = modal.x + scaled_padding;
        const selector = self.selectorRect(host, modal);
        self.renderStaticTexture(renderer, self.label_tex, label_x, selector.y - dpi.scale(24, host.ui_scale));

        const selector_radius = dpi.scale(7, host.ui_scale);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.background.r, host.theme.background.g, host.theme.background.b, 255);
        primitives.fillRoundedRect(renderer, selector, selector_radius);
        const selector_border = if (self.selector_hovered) host.theme.accent else host.theme.foreground;
        _ = c.SDL_SetRenderDrawColor(renderer, selector_border.r, selector_border.g, selector_border.b, if (self.selector_hovered) 255 else 120);
        primitives.drawRoundedBorder(renderer, selector, selector_radius);
        if (self.agent_tex[self.selected_agent]) |agent_tex| {
            self.renderStaticTexture(renderer, agent_tex, selector.x + dpi.scale(12, host.ui_scale), selector.y + @divFloor(selector.h - agent_tex.h, 2));
        }
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.foreground.r, host.theme.foreground.g, host.theme.foreground.b, 220);
        _ = c.SDL_RenderLine(
            renderer,
            @floatFromInt(selector.x + selector.w - dpi.scale(20, host.ui_scale)),
            @floatFromInt(selector.y + dpi.scale(17, host.ui_scale)),
            @floatFromInt(selector.x + selector.w - dpi.scale(14, host.ui_scale)),
            @floatFromInt(selector.y + dpi.scale(17, host.ui_scale)),
        );
        _ = c.SDL_RenderLine(
            renderer,
            @floatFromInt(selector.x + selector.w - dpi.scale(20, host.ui_scale)),
            @floatFromInt(selector.y + dpi.scale(17, host.ui_scale)),
            @floatFromInt(selector.x + selector.w - dpi.scale(17, host.ui_scale)),
            @floatFromInt(selector.y + dpi.scale(21, host.ui_scale)),
        );

        self.renderStaticTexture(renderer, self.prompt_label_tex, prompt.x, prompt.y - dpi.scale(24, host.ui_scale));
        self.renderPrompt(renderer, host, prompt);
        self.renderStaticTexture(renderer, self.context_label_tex, context.x, context.y - dpi.scale(24, host.ui_scale));
        self.renderContextPreview(renderer, host, context);
        self.renderCancelButton(renderer, host, modal);
        self.renderLaunchButton(renderer, host, modal);

        if (self.dropdown_open) self.renderDropdown(renderer, host, self.dropdownRect(host, selector));
        self.guard.markDrawn();
    }

    fn renderPrompt(self: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect) void {
        const prompt_radius = dpi.scale(7, host.ui_scale);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.background.r, host.theme.background.g, host.theme.background.b, 255);
        primitives.fillRoundedRect(renderer, rect, prompt_radius);
        const border = if (self.prompt_focused) host.theme.accent else host.theme.foreground;
        _ = c.SDL_SetRenderDrawColor(renderer, border.r, border.g, border.b, if (self.prompt_focused) 255 else 100);
        primitives.drawRoundedBorder(renderer, rect, prompt_radius);

        const inner = dpi.scale(10, host.ui_scale);
        const text_x = rect.x + inner;
        const text_y = rect.y + inner;
        const line_h = dpi.scale(22, host.ui_scale);
        const clip = c.SDL_Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        const had_clip = c.SDL_RenderClipEnabled(renderer);
        var previous_clip: c.SDL_Rect = undefined;
        if (had_clip) _ = c.SDL_GetRenderClipRect(renderer, &previous_clip);
        _ = c.SDL_SetRenderClipRect(renderer, &clip);

        if (self.prompt.select_all) {
            // Behind the glyphs, so the highlight never hides the text.
            const sel = host.theme.accent;
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 110);
            for (self.prompt_lines, 0..) |line_data, line_index| {
                if (line_data.w == 0) continue;
                _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                    .x = @floatFromInt(text_x),
                    .y = @floatFromInt(text_y + @as(c_int, @intCast(line_index)) * line_h),
                    .w = @floatFromInt(line_data.w),
                    .h = @floatFromInt(line_h),
                });
            }
        }

        for (self.prompt_lines, 0..) |line_data, line_index| {
            if (line_data.tex) |texture| {
                _ = c.SDL_RenderTexture(renderer, texture, null, &c.SDL_FRect{
                    .x = @floatFromInt(text_x),
                    .y = @floatFromInt(text_y + @as(c_int, @intCast(line_index)) * line_h),
                    .w = @floatFromInt(line_data.w),
                    .h = @floatFromInt(line_data.h),
                });
            }
        }

        if (self.prompt.isEmpty()) {
            if (self.placeholder_tex) |placeholder| {
                _ = c.SDL_SetTextureAlphaMod(placeholder.tex, 150);
                _ = c.SDL_RenderTexture(renderer, placeholder.tex, null, &c.SDL_FRect{
                    .x = @floatFromInt(text_x),
                    .y = @floatFromInt(text_y),
                    .w = @floatFromInt(placeholder.w),
                    .h = @floatFromInt(placeholder.h),
                });
                _ = c.SDL_SetTextureAlphaMod(placeholder.tex, 255);
            }
        }

        if (self.prompt_focused and self.prompt_lines.len > 0 and self.prompt.caretVisible(host.now_ms)) {
            const last_line = self.prompt_lines[self.prompt_lines.len - 1];
            const cursor_x = text_x + last_line.w;
            const cursor_y = text_y + @as(c_int, @intCast(self.prompt_lines.len - 1)) * line_h;
            _ = c.SDL_SetRenderDrawColor(renderer, host.theme.foreground.r, host.theme.foreground.g, host.theme.foreground.b, 220);
            _ = c.SDL_RenderLine(
                renderer,
                @floatFromInt(cursor_x),
                @floatFromInt(cursor_y + dpi.scale(2, host.ui_scale)),
                @floatFromInt(cursor_x),
                @floatFromInt(cursor_y + line_h - dpi.scale(2, host.ui_scale)),
            );
        }
        _ = c.SDL_SetRenderClipRect(renderer, if (had_clip) &previous_clip else null);
    }

    fn renderContextPreview(self: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect) void {
        const context_radius = dpi.scale(7, host.ui_scale);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.background.r, host.theme.background.g, host.theme.background.b, 255);
        primitives.fillRoundedRect(renderer, rect, context_radius);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.foreground.r, host.theme.foreground.g, host.theme.foreground.b, 90);
        primitives.drawRoundedBorder(renderer, rect, context_radius);

        const inner = dpi.scale(10, host.ui_scale);
        const clip = c.SDL_Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        const had_clip = c.SDL_RenderClipEnabled(renderer);
        var previous_clip: c.SDL_Rect = undefined;
        if (had_clip) _ = c.SDL_GetRenderClipRect(renderer, &previous_clip);
        _ = c.SDL_SetRenderClipRect(renderer, &clip);
        const line_height = dpi.scale(19, host.ui_scale);
        const metrics = self.contextScrollMetrics(host, rect);
        self.context_scroll_offset = metrics.offset;
        const scroll_offset: c_int = @intFromFloat(self.context_scroll_offset);
        for (self.context_lines, 0..) |line, line_index| {
            const line_y = rect.y + inner + @as(c_int, @intCast(line_index)) * line_height - scroll_offset;
            if (line_y + line_height <= rect.y or line_y >= rect.y + rect.h) continue;
            if (line.tex) |texture| {
                _ = c.SDL_RenderTexture(renderer, texture, null, &c.SDL_FRect{
                    .x = @floatFromInt(rect.x + inner),
                    .y = @floatFromInt(line_y),
                    .w = @floatFromInt(line.w),
                    .h = @floatFromInt(line.h),
                });
            }
        }
        _ = c.SDL_SetRenderClipRect(renderer, if (had_clip) &previous_clip else null);

        if (scrollbar.computeLayout(rect, host.ui_scale, metrics)) |layout| {
            scrollbar.render(renderer, layout, host.theme.accent, &self.context_scrollbar);
            self.context_scrollbar.markDrawn();
        } else {
            self.context_scrollbar.hideNow();
        }
    }

    fn renderLaunchButton(self: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, modal: geom.Rect) void {
        const button = self.launchRect(host, modal);
        fillPanel(renderer, button, .{
            .r = host.theme.accent.r,
            .g = host.theme.accent.g,
            .b = host.theme.accent.b,
            .a = 255,
        });
        if (self.launch_hovered) {
            fillPanel(renderer, button, .{ .r = 255, .g = 255, .b = 255, .a = 30 });
        }
        if (self.launch_tex) |launch| {
            self.renderStaticTexture(renderer, launch, button.x + @divFloor(button.w - launch.w, 2), button.y + @divFloor(button.h - launch.h, 2));
        }
    }

    fn renderCancelButton(self: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, modal: geom.Rect) void {
        const button = self.cancelRect(host, modal);
        fillPanel(renderer, button, host.theme.background);
        if (self.cancel_hovered) {
            fillPanel(renderer, button, .{ .r = 255, .g = 255, .b = 255, .a = 30 });
        }
        if (self.cancel_tex) |cancel| {
            self.renderStaticTexture(renderer, cancel, button.x + @divFloor(button.w - cancel.w, 2), button.y + @divFloor(button.h - cancel.h, 2));
        }
    }

    fn renderDropdown(self: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect) void {
        const dropdown_radius = dpi.scale(7, host.ui_scale);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.background.r, host.theme.background.g, host.theme.background.b, 255);
        primitives.fillRoundedRect(renderer, rect, dropdown_radius);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 255);
        primitives.drawRoundedBorder(renderer, rect, dropdown_radius);
        const item_h = dpi.scale(dropdown_item_height, host.ui_scale);
        const highlighted = self.dropdown_hovered_agent orelse self.selected_agent;
        for (0..agent_count) |idx| {
            if (idx == highlighted) {
                const item_y = rect.y + @as(c_int, @intCast(idx)) * item_h;
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                _ = c.SDL_SetRenderDrawColor(
                    renderer,
                    host.theme.selection.r,
                    host.theme.selection.g,
                    host.theme.selection.b,
                    190,
                );
                _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                    .x = @floatFromInt(rect.x + 1),
                    .y = @floatFromInt(item_y),
                    .w = @floatFromInt(rect.w - 2),
                    .h = @floatFromInt(item_h),
                });
            }
            if (self.agent_tex[idx]) |agent| {
                self.renderStaticTexture(renderer, agent, rect.x + dpi.scale(12, host.ui_scale), rect.y + @as(c_int, @intCast(idx)) * item_h + @divFloor(item_h - agent.h, 2));
            }
        }
    }

    fn ensureStaticTextures(self: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, cache: *font_cache.FontCache) !void {
        const font_size = dpi.scale(16, host.ui_scale);
        if (self.title_tex != null and self.static_generation == cache.generation and self.static_font_size == font_size) return;

        self.invalidateStaticTextures();
        const title_fonts = try cache.get(dpi.scale(22, host.ui_scale));
        const fonts = try cache.get(font_size);
        const title_color = host.theme.foreground;
        const button_color = host.theme.background;
        self.title_tex = try text_render.makeTextTexture(self.allocator, renderer, .{ .text = title_fonts.bold orelse title_fonts.regular }, "Launch agent with this context", title_color);
        self.label_tex = try text_render.makeTextTexture(self.allocator, renderer, .{ .text = fonts.regular }, "Agent", title_color);
        self.prompt_label_tex = try text_render.makeTextTexture(self.allocator, renderer, .{ .text = fonts.regular }, "Prompt", title_color);
        self.context_label_tex = try text_render.makeTextTexture(self.allocator, renderer, .{ .text = fonts.regular }, "Selected terminal text", title_color);
        self.cancel_tex = try text_render.makeTextTexture(self.allocator, renderer, .{ .text = fonts.regular }, "Cancel", title_color);
        self.launch_tex = try text_render.makeTextTexture(self.allocator, renderer, .{ .text = fonts.regular }, "Launch", button_color);
        self.placeholder_tex = try text_render.makeTextTexture(self.allocator, renderer, .{ .text = fonts.regular }, "Describe what the agent should do...", host.theme.foreground);
        for (0..agent_count) |idx| {
            self.agent_tex[idx] = try text_render.makeTextTexture(
                self.allocator,
                renderer,
                .{ .text = fonts.regular },
                agentKindAt(idx).name(),
                title_color,
            );
        }
        self.static_generation = cache.generation;
        self.static_font_size = font_size;
    }

    fn ensurePromptLines(
        self: *SelectionAgentOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        cache: *font_cache.FontCache,
        rect: geom.Rect,
    ) !void {
        const font_size = dpi.scale(16, host.ui_scale);
        const fonts = try cache.get(font_size);
        const prompt_text = self.prompt.text();
        const text_hash = std.hash.Wyhash.hash(0, prompt_text);
        if (self.prompt_generation == cache.generation and
            self.prompt_font_size == font_size and
            self.prompt_text_len == prompt_text.len and
            self.prompt_text_hash == text_hash and
            self.prompt_rect_width == rect.w and
            self.prompt_lines.len > 0)
        {
            return;
        }
        const wrap_cols = promptWrapCols(fonts.regular, rect, host.ui_scale);

        const line_count = diff_comment_layout.wrappedLineCount(
            prompt_text,
            wrap_cols,
            wrap_tab_width,
            wrap_min_printable,
        );
        const ranges = try self.allocator.alloc(diff_comment_layout.WrappedLine, line_count);
        defer self.allocator.free(ranges);
        var collector = WrappedRangeCollector{ .ranges = ranges };
        diff_comment_layout.forEachWrappedLine(
            prompt_text,
            wrap_cols,
            wrap_tab_width,
            wrap_min_printable,
            &collector,
            collectWrappedLine,
        );

        const inner = dpi.scale(10, host.ui_scale);
        const line_height = dpi.scale(22, host.ui_scale);
        const available_height = @max(@as(c_int, 1), rect.h - inner * 2);
        const visible_line_count: usize = @max(
            @as(usize, 1),
            @as(usize, @intCast(@divFloor(available_height, line_height))),
        );
        const first_line = if (collector.count > visible_line_count)
            collector.count - visible_line_count
        else
            0;

        const old_lines = self.prompt_lines;
        self.prompt_lines = &.{};
        var lines = std.ArrayList(PromptLine).empty;
        errdefer {
            for (lines.items) |*line| destroyPromptLine(self.allocator, line);
            lines.deinit(self.allocator);
            for (old_lines) |*line| destroyPromptLine(self.allocator, line);
            if (old_lines.len > 0) self.allocator.free(old_lines);
        }

        for (ranges[first_line..collector.count]) |range| {
            const source = prompt_text[range.start..range.end];
            var prompt_line = PromptLine{};
            var reused = false;
            for (old_lines) |*old_line| {
                if (old_line.used or !std.mem.eql(u8, old_line.text, source)) continue;
                old_line.used = true;
                prompt_line = old_line.*;
                old_line.text = &.{};
                old_line.tex = null;
                prompt_line.used = false;
                reused = true;
                break;
            }
            if (!reused) {
                prompt_line.text = if (source.len == 0) &.{} else try self.allocator.dupe(u8, source);
                if (source.len > 0) {
                    const texture = text_render.makeTextTexture(
                        self.allocator,
                        renderer,
                        .{ .text = fonts.regular, .emoji = fonts.emoji },
                        source,
                        host.theme.foreground,
                    ) catch |err| blk: {
                        log.warn("failed to render prompt line: {}", .{err});
                        break :blk null;
                    };
                    if (texture) |value| {
                        prompt_line.tex = value.tex;
                        prompt_line.w = value.w;
                        prompt_line.h = value.h;
                    }
                }
            }
            try lines.append(self.allocator, prompt_line);
        }

        self.prompt_lines = try lines.toOwnedSlice(self.allocator);
        for (old_lines) |*line| destroyPromptLine(self.allocator, line);
        if (old_lines.len > 0) self.allocator.free(old_lines);
        self.prompt_generation = cache.generation;
        self.prompt_font_size = font_size;
        self.prompt_text_len = prompt_text.len;
        self.prompt_text_hash = text_hash;
        self.prompt_rect_width = rect.w;
    }

    fn ensureContextPreview(
        self: *SelectionAgentOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        cache: *font_cache.FontCache,
        rect: geom.Rect,
    ) !void {
        const font_size = dpi.scale(14, host.ui_scale);
        if (self.context_preview_generation == cache.generation and
            self.context_preview_font_size == font_size and
            self.context_preview_rect_width == rect.w and
            self.context_lines.len > 0)
        {
            return;
        }

        self.invalidateContextPreview();
        const selected_text = self.selected_text orelse return;
        const fonts = try cache.get(font_size);
        const wrap_cols = contextWrapCols(fonts.regular, rect, host.ui_scale);
        const line_count = diff_comment_layout.wrappedLineCount(
            selected_text,
            wrap_cols,
            wrap_tab_width,
            wrap_min_printable,
        );
        const ranges = try self.allocator.alloc(diff_comment_layout.WrappedLine, line_count);
        defer self.allocator.free(ranges);
        var collector = WrappedRangeCollector{ .ranges = ranges };
        diff_comment_layout.forEachWrappedLine(
            selected_text,
            wrap_cols,
            wrap_tab_width,
            wrap_min_printable,
            &collector,
            collectWrappedLine,
        );

        const context_lines = try self.allocator.alloc(ContextLine, collector.count);
        @memset(context_lines, .{});

        for (ranges[0..collector.count], 0..) |range, index| {
            const source = selected_text[range.start..range.end];
            if (source.len == 0) continue;
            const texture = text_render.makeTextTexture(
                self.allocator,
                renderer,
                .{ .text = fonts.regular, .emoji = fonts.emoji },
                source,
                host.theme.foreground,
            ) catch |err| {
                log.warn("failed to render selected context line: {}", .{err});
                continue;
            };
            context_lines[index] = .{
                .tex = texture.tex,
                .w = texture.w,
                .h = texture.h,
            };
        }
        self.context_lines = context_lines;
        self.context_preview_generation = cache.generation;
        self.context_preview_font_size = font_size;
        self.context_preview_rect_width = rect.w;

        const metrics = self.contextScrollMetrics(host, rect);
        self.context_scroll_offset = metrics.offset;
        if (metrics.isScrollable()) {
            self.context_scrollbar.noteActivity(host.now_ms);
        } else {
            self.context_scrollbar.hideNow();
        }
    }

    fn invalidateStaticTextures(self: *SelectionAgentOverlayComponent) void {
        destroyTexture(&self.title_tex);
        destroyTexture(&self.label_tex);
        destroyTexture(&self.prompt_label_tex);
        destroyTexture(&self.context_label_tex);
        destroyTexture(&self.cancel_tex);
        destroyTexture(&self.launch_tex);
        destroyTexture(&self.placeholder_tex);
        for (&self.agent_tex) |*texture| destroyTexture(texture);
        self.static_generation = 0;
        self.static_font_size = 0;
    }

    fn invalidatePromptLines(self: *SelectionAgentOverlayComponent) void {
        for (self.prompt_lines) |*line| destroyPromptLine(self.allocator, line);
        if (self.prompt_lines.len > 0) self.allocator.free(self.prompt_lines);
        self.prompt_lines = &.{};
        self.prompt_generation = 0;
        self.prompt_font_size = 0;
        self.prompt_text_len = 0;
        self.prompt_text_hash = 0;
        self.prompt_rect_width = 0;
    }

    fn invalidateContextPreview(self: *SelectionAgentOverlayComponent) void {
        for (self.context_lines) |*line| destroyContextLine(line);
        if (self.context_lines.len > 0) self.allocator.free(self.context_lines);
        self.context_lines = &.{};
        self.context_preview_generation = 0;
        self.context_preview_font_size = 0;
        self.context_preview_rect_width = 0;
    }

    fn renderStaticTexture(_: *SelectionAgentOverlayComponent, renderer: *c.SDL_Renderer, texture: ?TextTexture, x: c_int, y: c_int) void {
        const text_texture = texture orelse return;
        _ = c.SDL_RenderTexture(renderer, text_texture.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(text_texture.w),
            .h = @floatFromInt(text_texture.h),
        });
    }

    fn modalRect(_: *const SelectionAgentOverlayComponent, host: *const types.UiHost) geom.Rect {
        const margin = dpi.scale(modal_margin, host.ui_scale);
        const requested_w = dpi.scale(modal_width, host.ui_scale);
        const requested_h = dpi.scale(modal_height, host.ui_scale);
        const width = @min(requested_w, @max(1, host.window_w - margin * 2));
        const height = @min(requested_h, @max(1, host.window_h - margin * 2));
        return .{
            .x = @divFloor(host.window_w - width, 2),
            .y = @divFloor(host.window_h - height, 2),
            .w = width,
            .h = height,
        };
    }

    fn selectorRect(_: *const SelectionAgentOverlayComponent, host: *const types.UiHost, modal: geom.Rect) geom.Rect {
        const scaled_padding = dpi.scale(padding, host.ui_scale);
        const y = modal.y + scaled_padding + dpi.scale(title_height + 36, host.ui_scale);
        return .{ .x = modal.x + scaled_padding, .y = y, .w = dpi.scale(240, host.ui_scale), .h = dpi.scale(field_height, host.ui_scale) };
    }

    fn promptRect(_: *const SelectionAgentOverlayComponent, host: *const types.UiHost, modal: geom.Rect) geom.Rect {
        const scaled_padding = dpi.scale(padding, host.ui_scale);
        const selector = modal.y + scaled_padding + dpi.scale(title_height + 36, host.ui_scale);
        const y = selector + dpi.scale(field_height + 32, host.ui_scale);
        return .{ .x = modal.x + scaled_padding, .y = y, .w = modal.w - scaled_padding * 2, .h = dpi.scale(prompt_height, host.ui_scale) };
    }

    fn contextRect(self: *const SelectionAgentOverlayComponent, host: *const types.UiHost, modal: geom.Rect) geom.Rect {
        const prompt = self.promptRect(host, modal);
        return .{
            .x = prompt.x,
            .y = prompt.y + prompt.h + dpi.scale(32, host.ui_scale),
            .w = prompt.w,
            .h = dpi.scale(context_height, host.ui_scale),
        };
    }

    fn contextScrollMetrics(self: *const SelectionAgentOverlayComponent, host: *const types.UiHost, rect: geom.Rect) scrollbar.Metrics {
        return contextScrollMetricsForLineCount(
            self.context_lines.len,
            dpi.scale(19, host.ui_scale),
            dpi.scale(10, host.ui_scale),
            rect.h,
            self.context_scroll_offset,
        );
    }

    fn actionButtonRects(modal: geom.Rect, ui_scale: f32) struct { cancel: geom.Rect, launch: geom.Rect } {
        const scaled_padding = dpi.scale(padding, ui_scale);
        const button_h = dpi.scale(button_height, ui_scale);
        const launch = geom.Rect{
            .x = modal.x + modal.w - scaled_padding - dpi.scale(button_width, ui_scale),
            .y = modal.y + modal.h - scaled_padding - button_h,
            .w = dpi.scale(button_width, ui_scale),
            .h = button_h,
        };
        return .{
            .cancel = .{
                .x = launch.x - dpi.scale(button_gap, ui_scale) - dpi.scale(cancel_button_width, ui_scale),
                .y = launch.y,
                .w = dpi.scale(cancel_button_width, ui_scale),
                .h = button_h,
            },
            .launch = launch,
        };
    }

    fn cancelRect(_: *const SelectionAgentOverlayComponent, host: *const types.UiHost, modal: geom.Rect) geom.Rect {
        return actionButtonRects(modal, host.ui_scale).cancel;
    }

    fn launchRect(_: *const SelectionAgentOverlayComponent, host: *const types.UiHost, modal: geom.Rect) geom.Rect {
        return actionButtonRects(modal, host.ui_scale).launch;
    }

    fn dropdownRect(_: *const SelectionAgentOverlayComponent, host: *const types.UiHost, selector: geom.Rect) geom.Rect {
        return .{
            .x = selector.x,
            .y = selector.y + selector.h,
            .w = selector.w,
            .h = dpi.scale(dropdown_item_height * @as(c_int, @intCast(agent_count)), host.ui_scale),
        };
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *SelectionAgentOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .hitTest = hitTest,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

fn destroyTexture(texture: *?TextTexture) void {
    if (texture.*) |value| {
        c.SDL_DestroyTexture(value.tex);
        texture.* = null;
    }
}

fn fillPanel(renderer: *c.SDL_Renderer, rect: geom.Rect, color: c.SDL_Color) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    var fill = c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = c.SDL_RenderFillRect(renderer, &fill);
}

fn destroyPromptLine(allocator: std.mem.Allocator, line: *PromptLine) void {
    if (line.tex) |tex| {
        c.SDL_DestroyTexture(tex);
        line.tex = null;
    }
    if (line.text.len > 0) {
        allocator.free(line.text);
        line.text = &.{};
    }
    line.w = 0;
    line.h = 0;
    line.used = false;
}

fn destroyContextLine(line: *ContextLine) void {
    if (line.tex) |texture| c.SDL_DestroyTexture(texture);
    line.* = .{};
}

pub fn formatAgentPrompt(allocator: std.mem.Allocator, input: []const u8, selected_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\n\n<selection>\n{s}\n</selection>\n", .{ input, selected_text });
}

test "formatAgentPrompt wraps the selected terminal context in selection tags" {
    const prompt = try formatAgentPrompt(std.testing.allocator, "Fix this", "error: bad input");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("Fix this\n\n<selection>\nerror: bad input\n</selection>\n", prompt);
}

test "formatAgentPrompt preserves multiline instructions and context" {
    const prompt = try formatAgentPrompt(std.testing.allocator, "First line\nSecond line", "one\ntwo");
    defer std.testing.allocator.free(prompt);
    try std.testing.expectEqualStrings("First line\nSecond line\n\n<selection>\none\ntwo\n</selection>\n", prompt);
}

test "selection agent action buttons share a row without overlapping" {
    const buttons = SelectionAgentOverlayComponent.actionButtonRects(.{ .x = 100, .y = 50, .w = 760, .h = 620 }, 1.0);

    try std.testing.expectEqual(buttons.cancel.y, buttons.launch.y);
    try std.testing.expectEqual(buttons.cancel.h, buttons.launch.h);
    try std.testing.expectEqual(buttons.cancel.x + buttons.cancel.w + button_gap, buttons.launch.x);
}

test "selection agent dropdown resolves the hovered item" {
    const dropdown = geom.Rect{ .x = 100, .y = 200, .w = 240, .h = 108 };

    try std.testing.expectEqual(@as(?usize, 0), dropdownItemAt(dropdown, 36, 3, 120, 210));
    try std.testing.expectEqual(@as(?usize, 1), dropdownItemAt(dropdown, 36, 3, 120, 250));
    try std.testing.expectEqual(@as(?usize, 2), dropdownItemAt(dropdown, 36, 3, 120, 307));
    try std.testing.expectEqual(@as(?usize, null), dropdownItemAt(dropdown, 36, 3, 99, 210));
    try std.testing.expectEqual(@as(?usize, null), dropdownItemAt(dropdown, 36, 3, 120, 308));
}

test "selected terminal text wraps into scrollable context metrics" {
    const text = "one two three four five six seven eight nine ten";
    const line_count = diff_comment_layout.wrappedLineCount(text, 8, wrap_tab_width, wrap_min_printable);
    const metrics = contextScrollMetricsForLineCount(line_count, 19, 10, 70, 0);

    try std.testing.expect(line_count > 1);
    try std.testing.expect(metrics.isScrollable());
    try std.testing.expect(metrics.maxOffset() > 0);
}
