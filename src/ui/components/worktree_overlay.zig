const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;
const button = @import("button.zig");

pub const WorktreeOverlayComponent = struct {
    allocator: std.mem.Allocator,
    overlay: ExpandingOverlay = ExpandingOverlay.init(1, BUTTON_MARGIN, BUTTON_SIZE_SMALL, BUTTON_SIZE_LARGE, BUTTON_ANIMATION_DURATION_MS),
    first_frame: FirstFrameGuard = .{},

    worktrees: std.ArrayList(Worktree) = .{},
    last_cwd: ?[]const u8 = null,
    display_base: ?[]const u8 = null,
    needs_refresh: bool = true,
    available: bool = false,
    focused_busy: bool = false,
    hovered_entry: ?usize = null,
    hovered_remove_btn: ?usize = null,
    creating: bool = false,
    confirming_removal: bool = false,
    pending_removal_index: ?usize = null,
    pending_removal_path: ?[]const u8 = null,
    escape_pressed: bool = false,
    create_input: std.ArrayList(u8) = .empty,
    create_error: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    cache: ?*Cache = null,
    flow_animation_start_ms: i64 = 0,
    cursor_blink_start_ms: i64 = 0,

    const BUTTON_SIZE_SMALL: c_int = 40;
    const BUTTON_SIZE_LARGE: c_int = 480;
    const BUTTON_MARGIN: c_int = 20;
    const BUTTON_ANIMATION_DURATION_MS: i64 = 200;
    const MAX_WORKTREES: usize = 9;
    const MAX_NON_ROOT_WORKTREES: usize = 8;
    const MODAL_WIDTH: c_int = 520;
    const MODAL_HEIGHT: c_int = 220;
    const MODAL_RADIUS: c_int = 12;
    const MODAL_PADDING: c_int = 24;
    const BUTTON_WIDTH: c_int = 136;
    const BUTTON_HEIGHT: c_int = 40;
    const BUTTON_GAP: c_int = 12;

    const TITLE = "Git Worktrees";
    const NEW_WORKTREE_LABEL = "New worktree…";
    const REPOSITORY_ROOT_LABEL = "[repository root]";

    const Worktree = struct {
        abs_path: []const u8,
        display: []const u8,
    };

    const TextTex = struct {
        tex: *c.SDL_Texture,
        w: c_int,
        h: c_int,
    };

    const EntryTex = struct {
        hotkey: TextTex,
        path: TextTex,
    };

    const Cache = struct {
        ui_scale: f32,
        title_font_size: c_int,
        entry_font_size: c_int,
        title: TextTex,
        entries: []EntryTex,
        theme_fg: c.SDL_Color,
        key_color: c.SDL_Color,
        title_color: c.SDL_Color,
        entry_color: c.SDL_Color,
        title_fonts: FontWithFallbacks,
        entry_fonts: FontWithFallbacks,
    };

    const FontWithFallbacks = struct {
        main: *c.TTF_Font,
        symbol: ?*c.TTF_Font,
        emoji: ?*c.TTF_Font,
    };

    pub fn create(allocator: std.mem.Allocator) !UiComponent {
        const comp = try allocator.create(WorktreeOverlayComponent);
        comp.* = .{ .allocator = allocator };
        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 1000,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *WorktreeOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.destroyCache();
        self.clearWorktrees();
        self.clearCreateInput();
        if (self.last_cwd) |cwd| self.allocator.free(cwd);
        if (self.display_base) |base| self.allocator.free(base);
        if (self.last_error) |err| self.allocator.free(err);
        if (self.pending_removal_path) |path| self.allocator.free(path);
        self.worktrees.deinit(self.allocator);
        self.create_input.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *WorktreeOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (event.type == c.SDL_EVENT_KEY_UP and self.escape_pressed) {
            const key = event.key.key;
            if (key == c.SDLK_ESCAPE) {
                self.escape_pressed = false;
                return true;
            }
        }

        if (!self.available) return false;

        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (self.creating) {
                    const handled = self.handleCreateModalClick(host, event, actions);
                    if (handled) return true;
                }
                if (self.confirming_removal) {
                    const handled = self.handleRemoveModalClick(host, event, actions);
                    if (handled) return true;
                }
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
                const inside = geom.containsPoint(rect, mouse_x, mouse_y);
                if (inside and self.overlay.state == .Open) {
                    if (self.removeButtonIndexAtPoint(host, mouse_x, mouse_y)) |idx| {
                        const wt_idx = idx - 1;
                        self.startRemoveModal(wt_idx);
                        return true;
                    }
                    if (self.entryIndexAtPoint(host, mouse_y)) |idx| {
                        if (idx == 0) {
                            self.startCreateModal(host);
                        } else {
                            const wt_idx = idx - 1;
                            self.emitSwitch(actions, host.focused_session, self.worktrees.items[wt_idx].abs_path);
                            self.overlay.startCollapsing(host.now_ms);
                        }
                        return true;
                    }
                }

                if (inside) {
                    switch (self.overlay.state) {
                        .Closed => {
                            self.needs_refresh = true;
                            self.overlay.startExpanding(host.now_ms);
                        },
                        .Open => self.overlay.startCollapsing(host.now_ms),
                        else => {},
                    }
                    return true;
                }

                if (self.overlay.state == .Open and !inside) {
                    self.overlay.startCollapsing(host.now_ms);
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (self.overlay.state != .Open) return false;
                const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                const inside = geom.containsPoint(rect, mouse_x, mouse_y);
                if (!inside) {
                    self.hovered_entry = null;
                    self.hovered_remove_btn = null;
                    return false;
                }
                self.hovered_remove_btn = self.removeButtonIndexAtPoint(host, mouse_x, mouse_y);
                self.hovered_entry = self.entryIndexAtPoint(host, mouse_y);
            },
            c.SDL_EVENT_KEY_DOWN => {
                if (self.creating) {
                    const handled = self.handleCreateModalKey(event, host, actions);
                    if (handled) return true;
                }
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL)) != 0;

                if (has_gui and !has_blocking_mod and key == c.SDLK_T) {
                    if (self.overlay.state == .Open) {
                        self.overlay.startCollapsing(host.now_ms);
                    } else {
                        self.needs_refresh = true;
                        self.overlay.startExpanding(host.now_ms);
                    }
                    return true;
                }

                if (self.overlay.state == .Open and has_gui and !has_blocking_mod) {
                    if (key == c.SDLK_0) {
                        self.startCreateModal(host);
                        return true;
                    }
                    if (key >= c.SDLK_1 and key <= c.SDLK_9) {
                        const digit_idx: usize = @intCast(key - c.SDLK_1);
                        if (digit_idx < self.worktrees.items.len) {
                            self.emitSwitch(actions, host.focused_session, self.worktrees.items[digit_idx].abs_path);
                            self.overlay.startCollapsing(host.now_ms);
                            return true;
                        }
                    }
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (!self.creating) return false;
                const text = std.mem.span(event.text.text);
                self.appendCreateText(text, host.now_ms);
                return true;
            },
            else => {},
        }

        return false;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *WorktreeOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.available) return false;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        return geom.containsPoint(rect, x, y);
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *WorktreeOverlayComponent = @ptrCast(@alignCast(self_ptr));

        const busy = host.focused_has_foreground_process;
        if (busy != self.focused_busy) {
            self.focused_busy = busy;
            if (busy) {
                self.available = false;
                self.destroyCache();
                self.hovered_entry = null;
                self.creating = false;
                self.escape_pressed = false;
                self.clearCreateInput();
                if (self.overlay.state == .Open or self.overlay.state == .Expanding) {
                    self.overlay.startCollapsing(host.now_ms);
                }
            } else {
                self.needs_refresh = true;
            }
        }

        if (self.overlay.isAnimating() and self.overlay.isComplete(host.now_ms)) {
            self.overlay.state = switch (self.overlay.state) {
                .Expanding => .Open,
                .Collapsing => .Closed,
                else => self.overlay.state,
            };
            if (self.overlay.state == .Open) {
                self.first_frame.markTransition();
                self.flow_animation_start_ms = host.now_ms;
            }
            if (self.overlay.state == .Closed) {
                self.hovered_entry = null;
                self.flow_animation_start_ms = 0;
            }
        }

        if (self.focused_busy and !self.creating) {
            self.hovered_entry = null;
            return;
        }

        const host_cwd = host.focused_cwd;
        const cwd_changed = !pathsEqual(self.last_cwd, host_cwd);
        if (cwd_changed) {
            self.needs_refresh = true;
            self.setLastCwd(host_cwd);
        }

        if (self.needs_refresh) {
            if (host_cwd) |cwd| {
                self.refreshWorktrees(cwd);
            } else {
                self.available = false;
                self.clearWorktrees();
            }
            self.needs_refresh = false;
        }

        if (!self.available and self.overlay.state == .Open) {
            self.overlay.startCollapsing(host.now_ms);
        }
    }

    fn render(self_ptr: *anyopaque, ui_host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *WorktreeOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.available and !self.creating and !self.confirming_removal) return;

        if (self.creating) {
            _ = self.ensureCache(renderer, ui_host.ui_scale, assets, ui_host.theme);
            self.renderCreateModal(renderer, ui_host, assets, ui_host.theme);
            self.first_frame.markDrawn();
            return;
        }

        if (self.confirming_removal) {
            _ = self.ensureCache(renderer, ui_host.ui_scale, assets, ui_host.theme);
            self.renderRemoveModal(renderer, ui_host, assets, ui_host.theme);
            self.first_frame.markDrawn();
            return;
        }

        const rect = self.overlay.rect(ui_host.now_ms, ui_host.window_w, ui_host.window_h, ui_host.ui_scale);
        const radius: c_int = 8;

        if (!self.creating) {
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            const sel = ui_host.theme.selection;
            _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 245);
            const bg_rect = c.SDL_FRect{
                .x = @floatFromInt(rect.x),
                .y = @floatFromInt(rect.y),
                .w = @floatFromInt(rect.w),
                .h = @floatFromInt(rect.h),
            };
            _ = c.SDL_RenderFillRect(renderer, &bg_rect);

            const accent = ui_host.theme.accent;
            _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 255);
            primitives.drawRoundedBorder(renderer, rect, radius);

            if (self.overlay.state != .Closed) {
                _ = self.ensureCache(renderer, ui_host.ui_scale, assets, ui_host.theme);
            }
        } else {
            _ = self.ensureCache(renderer, ui_host.ui_scale, assets, ui_host.theme);
        }

        switch (self.overlay.state) {
            .Closed, .Collapsing, .Expanding => self.renderGlyph(renderer, rect, ui_host.ui_scale, assets, ui_host.theme),
            .Open => self.renderOverlay(renderer, ui_host, rect, ui_host.ui_scale, assets, ui_host.theme),
        }
    }

    fn renderGlyph(_: *WorktreeOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const @import("../../colors.zig").Theme) void {
        const font_path = assets.font_path orelse return;
        const font_size = dpi.scale(@max(12, @min(20, @divFloor(rect.h, 2))), ui_scale);
        const fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, font_size) catch return;
        defer closeFontWithFallbacks(fonts);

        const glyph = "⌘T";
        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const surface = c.TTF_RenderText_Blended(fonts.main, glyph.ptr, @intCast(glyph.len), fg_color) orelse return;
        defer c.SDL_DestroySurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(texture);

        var text_width_f: f32 = 0;
        var text_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &text_width_f, &text_height_f);

        const text_x = rect.x + @divFloor(rect.w - @as(c_int, @intFromFloat(text_width_f)), 2);
        const text_y = rect.y + @divFloor(rect.h - @as(c_int, @intFromFloat(text_height_f)), 2);

        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(text_x),
            .y = @floatFromInt(text_y),
            .w = text_width_f,
            .h = text_height_f,
        };
        _ = c.SDL_RenderTexture(renderer, texture, null, &dest_rect);
    }

    fn renderOverlay(self: *WorktreeOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const @import("../../colors.zig").Theme) void {
        const cache = self.ensureCache(renderer, ui_scale, assets, theme) orelse return;

        const padding: c_int = dpi.scale(20, ui_scale);
        const line_height: c_int = dpi.scale(28, ui_scale);
        const trailing_gutter: c_int = dpi.scale(32, ui_scale);
        var y_offset: c_int = rect.y + padding;

        const title_tex = cache.title;
        const title_x = rect.x + @divFloor(rect.w - title_tex.w, 2);
        _ = c.SDL_RenderTexture(renderer, title_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(y_offset),
            .w = @floatFromInt(title_tex.w),
            .h = @floatFromInt(title_tex.h),
        });
        y_offset += title_tex.h + line_height;

        const current_idx = self.findCurrentWorktreeIndex(host.focused_cwd);

        for (cache.entries, 0..) |entry_tex, idx| {
            if (self.hovered_entry) |hover_idx| {
                if (hover_idx == idx) {
                    const highlight_y = @as(f32, @floatFromInt(y_offset - dpi.scale(4, ui_scale)));
                    const highlight_h = @as(f32, @floatFromInt(line_height));
                    const fade_width: f32 = @as(f32, @floatFromInt(dpi.scale(40, ui_scale)));
                    const rect_x: f32 = @floatFromInt(rect.x);
                    const rect_w: f32 = @floatFromInt(rect.w);

                    const center_rect = c.SDL_FRect{
                        .x = rect_x + fade_width,
                        .y = highlight_y,
                        .w = rect_w - 2.0 * fade_width,
                        .h = highlight_h,
                    };

                    const acc = theme.accent;
                    _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 40);
                    _ = c.SDL_RenderFillRect(renderer, &center_rect);

                    const strips_count = 6;
                    var i: usize = 0;
                    while (i < strips_count) : (i += 1) {
                        const progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(strips_count));
                        const strip_w = fade_width / @as(f32, @floatFromInt(strips_count));

                        const left_alpha = @as(u8, @intFromFloat(40.0 * progress));
                        const left_strip = c.SDL_FRect{
                            .x = rect_x + @as(f32, @floatFromInt(i)) * strip_w,
                            .y = highlight_y,
                            .w = strip_w,
                            .h = highlight_h,
                        };
                        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, left_alpha);
                        _ = c.SDL_RenderFillRect(renderer, &left_strip);

                        const right_alpha = @as(u8, @intFromFloat(40.0 * (1.0 - progress)));
                        const right_strip = c.SDL_FRect{
                            .x = rect_x + rect_w - fade_width + @as(f32, @floatFromInt(i)) * strip_w,
                            .y = highlight_y,
                            .w = strip_w,
                            .h = highlight_h,
                        };
                        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, right_alpha);
                        _ = c.SDL_RenderFillRect(renderer, &right_strip);
                    }
                }
            }

            _ = c.SDL_RenderTexture(renderer, entry_tex.hotkey.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + padding),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.hotkey.w),
                .h = @floatFromInt(entry_tex.hotkey.h),
            });

            const path_x_offset = trailing_gutter;
            _ = c.SDL_RenderTexture(renderer, entry_tex.path.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + rect.w - padding - entry_tex.path.w - path_x_offset),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.path.w),
                .h = @floatFromInt(entry_tex.path.h),
            });

            if (self.entryHasRemoveButton(idx)) {
                if (self.removeButtonRect(host, idx)) |btn_rect| {
                    const is_hovered = if (self.hovered_remove_btn) |h| h == idx else false;
                    const btn_alpha: u8 = if (is_hovered) 255 else 160;
                    _ = c.SDL_SetRenderDrawColor(renderer, theme.foreground.r, theme.foreground.g, theme.foreground.b, btn_alpha);

                    const cross_size: c_int = @divFloor(btn_rect.w * 6, 10);
                    const cross_x = btn_rect.x + @divFloor(btn_rect.w - cross_size, 2);
                    const cross_y = btn_rect.y + @divFloor(btn_rect.h - cross_size, 2);

                    const x1: f32 = @floatFromInt(cross_x);
                    const y1: f32 = @floatFromInt(cross_y);
                    const x2: f32 = @floatFromInt(cross_x + cross_size);
                    const y2: f32 = @floatFromInt(cross_y + cross_size);

                    _ = c.SDL_RenderLine(renderer, x1, y1, x2, y2);
                    _ = c.SDL_RenderLine(renderer, x2, y1, x1, y2);

                    if (is_hovered) {
                        const BOLD_LINE_OFFSET: f32 = 1.0;
                        _ = c.SDL_RenderLine(renderer, x1 + BOLD_LINE_OFFSET, y1, x2 + BOLD_LINE_OFFSET, y2);
                        _ = c.SDL_RenderLine(renderer, x2 + BOLD_LINE_OFFSET, y1, x1 + BOLD_LINE_OFFSET, y2);
                        _ = c.SDL_RenderLine(renderer, x1, y1 + BOLD_LINE_OFFSET, x2, y2 + BOLD_LINE_OFFSET);
                        _ = c.SDL_RenderLine(renderer, x2, y1 + BOLD_LINE_OFFSET, x1, y2 + BOLD_LINE_OFFSET);
                    }
                }
            }

            if (current_idx) |current| {
                if (current == idx and idx > 0) {
                    const flow_y = y_offset + @divFloor(entry_tex.path.h, 2);
                    self.renderFlowingLine(renderer, host, rect, flow_y, ui_scale, theme);
                }
            }

            y_offset += line_height;
        }

        if (self.creating) {
            self.renderCreateModal(renderer, host, assets, host.theme);
            self.first_frame.markDrawn();
            return;
        }

        self.first_frame.markDrawn();
    }

    fn findCurrentWorktreeIndex(self: *WorktreeOverlayComponent, cwd_opt: ?[]const u8) ?usize {
        const cwd = cwd_opt orelse return null;

        var best_match: ?usize = null;
        var best_match_len: usize = 0;

        for (self.worktrees.items, 0..) |wt, i| {
            if (std.mem.eql(u8, wt.abs_path, cwd)) {
                if (wt.abs_path.len > best_match_len) {
                    best_match = i + 1;
                    best_match_len = wt.abs_path.len;
                }
            } else if (std.mem.startsWith(u8, cwd, wt.abs_path)) {
                const suffix = cwd[wt.abs_path.len..];
                if (suffix.len > 0 and suffix[0] == '/') {
                    if (wt.abs_path.len > best_match_len) {
                        best_match = i + 1;
                        best_match_len = wt.abs_path.len;
                    }
                }
            }
        }

        return best_match;
    }

    fn renderFlowingLine(self: *WorktreeOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect, y: c_int, ui_scale: f32, theme: *const @import("../../colors.zig").Theme) void {
        if (self.flow_animation_start_ms == 0) {
            self.flow_animation_start_ms = host.now_ms;
        }

        const elapsed_ms = host.now_ms - self.flow_animation_start_ms;
        const time: f32 = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;

        const padding: c_int = dpi.scale(20, ui_scale);
        const start_x: f32 = @floatFromInt(rect.x + padding);
        const end_x: f32 = @floatFromInt(rect.x + rect.w - padding);
        const width = end_x - start_x;
        const base_y: f32 = @floatFromInt(y);

        const num_points: usize = @as(usize, @intFromFloat(width / 3.0));
        const point_spacing = width / @as(f32, @floatFromInt(num_points - 1));

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

        const flow_speed = 0.5;
        const flow_offset = time * flow_speed;

        const accent = theme.accent;

        const diffusion_layers = 9;
        var layer: usize = 0;
        while (layer < diffusion_layers) : (layer += 1) {
            const layer_f: f32 = @floatFromInt(layer);
            const center: f32 = @as(f32, @floatFromInt(diffusion_layers - 1)) / 2.0;
            const layer_offset = (layer_f - center) * 1.2;
            const dist_from_center = @abs(layer_f - center);
            const layer_alpha_mult = 1.0 - (dist_from_center / (center + 1.0));

            var prev_x: f32 = start_x;
            var prev_y: f32 = base_y + layer_offset;

            for (0..num_points) |i| {
                const x = start_x + @as(f32, @floatFromInt(i)) * point_spacing;
                const normalized_x = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_points - 1)));

                const wave1 = @sin((normalized_x * 8.0 + flow_offset) * std.math.pi);
                const wave2 = @sin((normalized_x * 13.0 - flow_offset * 1.3) * std.math.pi) * 0.6;
                const wave3 = @cos((normalized_x * 21.0 + flow_offset * 0.7) * std.math.pi) * 0.4;
                const wave4 = @sin((normalized_x * 34.0 - flow_offset * 0.5) * std.math.pi) * 0.3;

                const combined_wave = (wave1 + wave2 + wave3 + wave4) / 2.3;
                const amplitude: f32 = @as(f32, @floatFromInt(dpi.scale(3, ui_scale)));
                const y_val = base_y + combined_wave * amplitude + layer_offset;

                if (i > 0) {
                    const segment_progress = @abs(@sin((normalized_x * 5.0 - flow_offset * 2.0) * std.math.pi));
                    const alpha_base: f32 = 100.0;
                    const alpha_var: f32 = 40.0;
                    const base_alpha = alpha_base + segment_progress * alpha_var;
                    const final_alpha = base_alpha * layer_alpha_mult * 0.4;
                    const alpha: u8 = @intFromFloat(@min(255.0, final_alpha));

                    _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, alpha);
                    _ = c.SDL_RenderLine(renderer, prev_x, prev_y, x, y_val);
                }

                prev_x = x;
                prev_y = y_val;
            }
        }
    }

    fn emitSwitch(_: *WorktreeOverlayComponent, actions: *types.UiActionQueue, session_idx: usize, abs_path: []const u8) void {
        const path_copy = actions.allocator.dupe(u8, abs_path) catch return;
        actions.append(.{ .SwitchWorktree = .{ .session = session_idx, .path = path_copy } }) catch {
            actions.allocator.free(path_copy);
        };
    }

    fn emitCreate(_: *WorktreeOverlayComponent, actions: *types.UiActionQueue, session_idx: usize, base_path: []const u8, name: []const u8) void {
        const base_copy = actions.allocator.dupe(u8, base_path) catch return;
        const name_copy = actions.allocator.dupe(u8, name) catch {
            actions.allocator.free(base_copy);
            return;
        };
        actions.append(.{ .CreateWorktree = .{ .session = session_idx, .base_path = base_copy, .name = name_copy } }) catch {
            actions.allocator.free(base_copy);
            actions.allocator.free(name_copy);
        };
    }

    fn emitRemove(_: *WorktreeOverlayComponent, actions: *types.UiActionQueue, session_idx: usize, abs_path: []const u8) void {
        const path_copy = actions.allocator.dupe(u8, abs_path) catch return;
        actions.append(.{ .RemoveWorktree = .{ .session = session_idx, .path = path_copy } }) catch {
            actions.allocator.free(path_copy);
        };
    }

    fn refreshWorktrees(self: *WorktreeOverlayComponent, cwd: []const u8) void {
        self.available = false;
        self.clearWorktrees();
        self.clearDisplayBase();
        self.destroyCache();
        self.clearError();
        self.hovered_entry = null;
        self.clearCreateInput();
        self.creating = false;
        self.escape_pressed = false;

        self.setDisplayBase(cwd);

        _ = self.collectFromGitMetadata(cwd);
        self.sortWorktrees();
        self.available = self.worktrees.items.len > 0;
        if (!self.available and self.last_error == null) {
            self.setError("No worktrees found");
        }
    }

    fn sortWorktrees(self: *WorktreeOverlayComponent) void {
        if (self.worktrees.items.len == 0) return;

        var root_idx: ?usize = null;
        for (self.worktrees.items, 0..) |wt, i| {
            if (std.mem.eql(u8, wt.display, REPOSITORY_ROOT_LABEL)) {
                root_idx = i;
                break;
            }
        }

        if (root_idx) |idx| {
            if (idx != 0) {
                const root = self.worktrees.items[idx];
                var i = idx;
                while (i > 0) : (i -= 1) {
                    self.worktrees.items[i] = self.worktrees.items[i - 1];
                }
                self.worktrees.items[0] = root;
            }
        }

        if (self.worktrees.items.len > 1) {
            const Context = struct {
                pub fn lessThan(_: @This(), a: Worktree, b: Worktree) bool {
                    return std.mem.order(u8, a.display, b.display) == .lt;
                }
            };
            std.mem.sort(Worktree, self.worktrees.items[1..], Context{}, Context.lessThan);
        }

        if (self.worktrees.items.len > MAX_WORKTREES) {
            for (self.worktrees.items[MAX_WORKTREES..]) |wt| {
                self.allocator.free(wt.abs_path);
                self.allocator.free(wt.display);
            }
            self.worktrees.items.len = MAX_WORKTREES;
        }
    }

    fn makeDisplayPath(self: *WorktreeOverlayComponent, base: []const u8, abs: []const u8) ![]const u8 {
        const rel = std.fs.path.relative(self.allocator, base, abs) catch {
            return self.allocator.dupe(u8, abs);
        };
        if (rel.len == 0) return self.allocator.dupe(u8, REPOSITORY_ROOT_LABEL);
        return rel;
    }

    fn ensureCache(self: *WorktreeOverlayComponent, renderer: *c.SDL_Renderer, ui_scale: f32, assets: *types.UiAssets, theme: *const @import("../../colors.zig").Theme) ?*Cache {
        const font_path = assets.font_path orelse return null;
        const title_font_size: c_int = dpi.scale(20, ui_scale);
        const entry_font_size: c_int = dpi.scale(16, ui_scale);
        const fg = theme.foreground;
        const entry_count = self.entryCount();

        if (self.cache) |cache| {
            if (cache.title_font_size == title_font_size and cache.entry_font_size == entry_font_size and cache.theme_fg.r == fg.r and cache.theme_fg.g == fg.g and cache.theme_fg.b == fg.b and cache.ui_scale == ui_scale and cache.entries.len == entry_count) {
                return cache;
            }
            self.destroyCache();
        }

        const cache = self.allocator.create(Cache) catch return null;
        errdefer self.allocator.destroy(cache);

        const title_fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, title_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };
        errdefer closeFontWithFallbacks(title_fonts);

        const entry_fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, entry_font_size) catch {
            closeFontWithFallbacks(title_fonts);
            self.allocator.destroy(cache);
            return null;
        };
        errdefer closeFontWithFallbacks(entry_fonts);

        const title_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const title_tex = makeTextTexture(renderer, title_fonts.main, TITLE, title_color) catch {
            closeFontWithFallbacks(entry_fonts);
            closeFontWithFallbacks(title_fonts);
            self.allocator.destroy(cache);
            return null;
        };

        const key_color = c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 255 };
        const entry_color = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };

        const entries = self.allocator.alloc(EntryTex, entry_count) catch {
            c.SDL_DestroyTexture(title_tex.tex);
            closeFontWithFallbacks(entry_fonts);
            closeFontWithFallbacks(title_fonts);
            self.allocator.destroy(cache);
            return null;
        };
        errdefer self.allocator.free(entries);

        const padding = dpi.scale(20, ui_scale);
        const overlay_width = dpi.scale(BUTTON_SIZE_LARGE, ui_scale);
        const hotkey_spacing = dpi.scale(10, ui_scale);
        const trailing_gutter = dpi.scale(32, ui_scale);

        for (0..entry_count) |idx| {
            var key_buf: [8]u8 = undefined;
            const digit: u8 = @as(u8, @intCast(idx % 10));
            const key_slice = std.fmt.bufPrint(&key_buf, "⌘{d}", .{digit}) catch key_buf[0..0];
            const key_tex = makeTextTexture(renderer, entry_fonts.main, key_slice, key_color) catch {
                destroyEntryTextures(entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                closeFontWithFallbacks(entry_fonts);
                closeFontWithFallbacks(title_fonts);
                self.allocator.destroy(cache);
                return null;
            };

            const path_slice = if (idx == 0) NEW_WORKTREE_LABEL else self.worktrees.items[idx - 1].display;
            const max_path_width = overlay_width - (2 * padding) - key_tex.w - hotkey_spacing - trailing_gutter;

            var path_buf: [256]u8 = undefined;
            const truncated_path = truncateTextLeft(path_slice, entry_fonts.main, max_path_width, &path_buf) catch path_slice;
            const path_tex = makeTextTexture(renderer, entry_fonts.main, truncated_path, entry_color) catch {
                c.SDL_DestroyTexture(key_tex.tex);
                destroyEntryTextures(entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                closeFontWithFallbacks(entry_fonts);
                closeFontWithFallbacks(title_fonts);
                self.allocator.destroy(cache);
                return null;
            };
            entries[idx] = .{ .hotkey = key_tex, .path = path_tex };
        }

        cache.* = .{
            .ui_scale = ui_scale,
            .title_font_size = title_font_size,
            .entry_font_size = entry_font_size,
            .title = title_tex,
            .entries = entries,
            .theme_fg = fg,
            .key_color = key_color,
            .title_color = title_color,
            .entry_color = entry_color,
            .title_fonts = title_fonts,
            .entry_fonts = entry_fonts,
        };

        self.cache = cache;

        const line_height: c_int = 28;
        const content_height = (2 * 20) + title_tex.h + line_height + @as(c_int, @intCast(entry_count)) * line_height;
        self.overlay.setContentHeight(content_height);

        return cache;
    }

    fn destroyCache(self: *WorktreeOverlayComponent) void {
        if (self.cache) |cache| {
            c.SDL_DestroyTexture(cache.title.tex);
            destroyEntryTextures(cache.entries);
            self.allocator.free(cache.entries);
            closeFontWithFallbacks(cache.entry_fonts);
            closeFontWithFallbacks(cache.title_fonts);
            self.allocator.destroy(cache);
            self.cache = null;
        }
    }

    fn clearWorktrees(self: *WorktreeOverlayComponent) void {
        for (self.worktrees.items) |wt| {
            self.allocator.free(wt.abs_path);
            self.allocator.free(wt.display);
        }
        self.worktrees.clearRetainingCapacity();
        self.hovered_entry = null;
        self.hovered_remove_btn = null;
        if (self.pending_removal_path) |path| {
            self.allocator.free(path);
            self.pending_removal_path = null;
        }
        self.pending_removal_index = null;
        self.confirming_removal = false;
    }

    fn clearDisplayBase(self: *WorktreeOverlayComponent) void {
        if (self.display_base) |base| {
            self.allocator.free(base);
            self.display_base = null;
        }
    }

    fn setLastCwd(self: *WorktreeOverlayComponent, cwd_opt: ?[]const u8) void {
        if (self.last_cwd) |old| self.allocator.free(old);
        self.last_cwd = if (cwd_opt) |cwd| self.allocator.dupe(u8, cwd) catch null else null;
    }

    fn clearError(self: *WorktreeOverlayComponent) void {
        if (self.last_error) |msg| {
            self.allocator.free(msg);
            self.last_error = null;
        }
    }

    fn setDisplayBase(self: *WorktreeOverlayComponent, base: []const u8) void {
        self.clearDisplayBase();
        self.display_base = self.allocator.dupe(u8, base) catch null;
    }

    fn setError(self: *WorktreeOverlayComponent, msg: []const u8) void {
        self.clearError();
        self.last_error = self.allocator.dupe(u8, msg) catch null;
    }

    fn pathsEqual(a_opt: ?[]const u8, b_opt: ?[]const u8) bool {
        if (a_opt == null and b_opt == null) return true;
        if (a_opt == null or b_opt == null) return false;
        const a = a_opt.?;
        const b = b_opt.?;
        return std.mem.eql(u8, a, b);
    }

    fn truncateTextLeft(text: []const u8, font: *c.TTF_Font, max_width: c_int, buf: []u8) ![]const u8 {
        const ellipsis = "...";
        var text_w: c_int = 0;
        var text_h: c_int = 0;
        _ = c.TTF_GetStringSize(font, text.ptr, text.len, &text_w, &text_h);

        if (text_w <= max_width) {
            if (text.len >= buf.len) return error.TextTooLong;
            @memcpy(buf[0..text.len], text);
            return buf[0..text.len];
        }

        var ellipsis_w: c_int = 0;
        var ellipsis_h: c_int = 0;
        _ = c.TTF_GetStringSize(font, ellipsis.ptr, ellipsis.len, &ellipsis_w, &ellipsis_h);

        var byte_offset: usize = 0;
        while (byte_offset < text.len) {
            const remaining = text[byte_offset..];
            const test_len = ellipsis.len + remaining.len;
            if (test_len >= buf.len) {
                byte_offset += 1;
                continue;
            }

            @memcpy(buf[0..ellipsis.len], ellipsis);
            @memcpy(buf[ellipsis.len..test_len], remaining);

            var test_w: c_int = 0;
            var test_h: c_int = 0;
            _ = c.TTF_GetStringSize(font, buf.ptr, test_len, &test_w, &test_h);

            if (test_w <= max_width) {
                return buf[0..test_len];
            }

            byte_offset += 1;
        }

        if (ellipsis.len < buf.len) {
            @memcpy(buf[0..ellipsis.len], ellipsis);
            return buf[0..ellipsis.len];
        }

        return text[0..@min(text.len, buf.len)];
    }

    fn makeTextTexture(
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
    ) !TextTex {
        var buf: [256]u8 = undefined;
        if (text.len >= buf.len) return error.TextTooLong;
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), text.len, color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &w, &h);
        _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
        return TextTex{
            .tex = tex,
            .w = @intFromFloat(w),
            .h = @intFromFloat(h),
        };
    }

    fn destroyEntryTextures(entries: []EntryTex) void {
        for (entries) |entry| {
            c.SDL_DestroyTexture(entry.hotkey.tex);
            c.SDL_DestroyTexture(entry.path.tex);
        }
    }

    const ModalLayout = struct {
        modal: c.SDL_FRect,
        input: c.SDL_FRect,
        confirm: c.SDL_FRect,
        cancel: c.SDL_FRect,
    };

    fn createModalLayout(self: *WorktreeOverlayComponent, host: *const types.UiHost) ModalLayout {
        _ = self;
        const modal_w: c_int = dpi.scale(MODAL_WIDTH, host.ui_scale);
        const modal_h: c_int = dpi.scale(MODAL_HEIGHT, host.ui_scale);
        const modal_x = @divFloor(host.window_w - modal_w, 2);
        const modal_y = @divFloor(host.window_h - modal_h, 2);
        const padding: c_int = dpi.scale(MODAL_PADDING, host.ui_scale);

        const input_h: c_int = dpi.scale(34, host.ui_scale);
        const button_h: c_int = dpi.scale(BUTTON_HEIGHT, host.ui_scale);
        const button_w: c_int = dpi.scale(BUTTON_WIDTH, host.ui_scale);
        const button_gap: c_int = dpi.scale(BUTTON_GAP, host.ui_scale);
        const button_y = modal_y + modal_h - padding - button_h;
        const cancel_x = modal_x + modal_w - padding - button_w;
        const confirm_x = cancel_x - button_gap - button_w;

        const input_y = modal_y + padding + dpi.scale(32, host.ui_scale);
        const input_w = modal_w - 2 * padding;

        return ModalLayout{
            .modal = c.SDL_FRect{
                .x = @floatFromInt(modal_x),
                .y = @floatFromInt(modal_y),
                .w = @floatFromInt(modal_w),
                .h = @floatFromInt(modal_h),
            },
            .input = c.SDL_FRect{
                .x = @floatFromInt(modal_x + padding),
                .y = @floatFromInt(input_y),
                .w = @floatFromInt(input_w),
                .h = @floatFromInt(input_h),
            },
            .confirm = c.SDL_FRect{
                .x = @floatFromInt(confirm_x),
                .y = @floatFromInt(button_y),
                .w = @floatFromInt(button_w),
                .h = @floatFromInt(button_h),
            },
            .cancel = c.SDL_FRect{
                .x = @floatFromInt(cancel_x),
                .y = @floatFromInt(button_y),
                .w = @floatFromInt(button_w),
                .h = @floatFromInt(button_h),
            },
        };
    }

    fn startCreateModal(self: *WorktreeOverlayComponent, host: *const types.UiHost) void {
        self.creating = true;
        self.escape_pressed = false;
        self.clearCreateInput();
        self.overlay.startCollapsing(host.now_ms);
        self.cursor_blink_start_ms = host.now_ms;
    }

    fn startRemoveModal(self: *WorktreeOverlayComponent, wt_idx: usize) void {
        if (wt_idx >= self.worktrees.items.len) return;
        const worktree = self.worktrees.items[wt_idx];
        self.confirming_removal = true;
        self.pending_removal_index = wt_idx;
        if (self.pending_removal_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.pending_removal_path = self.allocator.dupe(u8, worktree.abs_path) catch null;
        self.escape_pressed = false;
    }

    fn clearCreateInput(self: *WorktreeOverlayComponent) void {
        self.create_input.clearAndFree(self.allocator);
        if (self.create_error) |err| {
            self.allocator.free(err);
            self.create_error = null;
        }
    }

    fn clearPendingRemoval(self: *WorktreeOverlayComponent) void {
        self.confirming_removal = false;
        self.pending_removal_index = null;
        if (self.pending_removal_path) |path| {
            self.allocator.free(path);
            self.pending_removal_path = null;
        }
    }

    fn setCreateError(self: *WorktreeOverlayComponent, msg: []const u8) void {
        if (self.create_error) |err| self.allocator.free(err);
        self.create_error = self.allocator.dupe(u8, msg) catch null;
    }

    fn isValidNameChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '_';
    }

    fn appendCreateText(self: *WorktreeOverlayComponent, text: []const u8, now_ms: i64) void {
        const MAX_LEN: usize = 64;
        for (text) |ch| {
            if (self.create_input.items.len >= MAX_LEN) break;
            if (isValidNameChar(ch)) {
                _ = self.create_input.append(self.allocator, ch) catch {};
                self.cursor_blink_start_ms = now_ms;
            }
        }
    }

    fn handleCreateModalKey(self: *WorktreeOverlayComponent, event: *const c.SDL_Event, host: *const types.UiHost, actions: *types.UiActionQueue) bool {
        const key = event.key.key;
        const mod = event.key.mod;
        const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
        const has_alt = (mod & c.SDL_KMOD_ALT) != 0;

        switch (key) {
            c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                if (self.create_input.items.len == 0) {
                    self.setCreateError("Name required");
                    return true;
                }
                const base = self.display_base orelse {
                    self.setCreateError("No git root found");
                    return true;
                };
                self.emitCreate(actions, host.focused_session, base, self.create_input.items);
                self.overlay.startCollapsing(host.now_ms);
                self.creating = false;
                self.escape_pressed = false;
                self.clearCreateInput();
                return true;
            },
            c.SDLK_ESCAPE => {
                self.escape_pressed = true;
                self.creating = false;
                self.clearCreateInput();
                return true;
            },
            c.SDLK_BACKSPACE => {
                self.cursor_blink_start_ms = host.now_ms;
                if (has_gui) {
                    self.create_input.clearRetainingCapacity();
                } else if (has_alt) {
                    self.deleteLastWord();
                } else {
                    if (self.create_input.items.len > 0) {
                        self.create_input.items.len -= 1;
                    }
                }
                return true;
            },
            else => return false,
        }
    }

    fn deleteLastWord(self: *WorktreeOverlayComponent) void {
        if (self.create_input.items.len == 0) return;

        var i = self.create_input.items.len;
        while (i > 0 and (self.create_input.items[i - 1] == '-' or self.create_input.items[i - 1] == '_')) {
            i -= 1;
        }

        while (i > 0 and self.create_input.items[i - 1] != '-' and self.create_input.items[i - 1] != '_') {
            i -= 1;
        }

        self.create_input.items.len = i;
    }

    fn handleCreateModalClick(self: *WorktreeOverlayComponent, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        if (!self.creating or self.cache == null) return false;
        const layout = self.createModalLayout(host);
        const x: f32 = event.button.x;
        const y: f32 = event.button.y;

        const inConfirm = x >= layout.confirm.x and x <= layout.confirm.x + layout.confirm.w and
            y >= layout.confirm.y and y <= layout.confirm.y + layout.confirm.h;
        const inCancel = x >= layout.cancel.x and x <= layout.cancel.x + layout.cancel.w and
            y >= layout.cancel.y and y <= layout.cancel.y + layout.cancel.h;

        if (inConfirm) {
            var fake_event: c.SDL_Event = undefined;
            fake_event.type = c.SDL_EVENT_KEY_DOWN;
            fake_event.key.key = c.SDLK_RETURN;
            fake_event.key.mod = 0;
            _ = self.handleCreateModalKey(&fake_event, host, actions);
            return true;
        }
        if (inCancel) {
            self.creating = false;
            self.escape_pressed = false;
            self.clearCreateInput();
            return true;
        }

        const inModal = x >= layout.modal.x and x <= layout.modal.x + layout.modal.w and
            y >= layout.modal.y and y <= layout.modal.y + layout.modal.h;
        if (inModal) {
            return true;
        }

        self.creating = false;
        self.escape_pressed = false;
        self.clearCreateInput();
        return true;
    }

    fn handleRemoveModalClick(self: *WorktreeOverlayComponent, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        if (!self.confirming_removal or self.cache == null) return false;
        const layout = self.createModalLayout(host);
        const x: f32 = event.button.x;
        const y: f32 = event.button.y;

        const inConfirm = x >= layout.confirm.x and x <= layout.confirm.x + layout.confirm.w and
            y >= layout.confirm.y and y <= layout.confirm.y + layout.confirm.h;
        const inCancel = x >= layout.cancel.x and x <= layout.cancel.x + layout.cancel.w and
            y >= layout.cancel.y and y <= layout.cancel.y + layout.cancel.h;

        if (inConfirm) {
            if (self.pending_removal_path) |path| {
                self.emitRemove(actions, host.focused_session, path);
            }
            self.clearPendingRemoval();
            return true;
        }
        if (inCancel) {
            self.clearPendingRemoval();
            return true;
        }

        const inModal = x >= layout.modal.x and x <= layout.modal.x + layout.modal.w and
            y >= layout.modal.y and y <= layout.modal.y + layout.modal.h;
        if (inModal) {
            return true;
        }

        self.clearPendingRemoval();
        return true;
    }

    fn renderCreateModal(self: *WorktreeOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, _: *types.UiAssets, theme: *const @import("../../colors.zig").Theme) void {
        const cache = self.cache orelse return;
        const layout = self.createModalLayout(host);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 170);
        const backdrop = c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.window_w),
            .h = @floatFromInt(host.window_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &backdrop);

        // Modal background
        const sel = theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 235);
        _ = c.SDL_RenderFillRect(renderer, &layout.modal);
        _ = c.SDL_SetRenderDrawColor(renderer, theme.accent.r, theme.accent.g, theme.accent.b, 255);
        primitives.drawRoundedBorder(renderer, geom.Rect{
            .x = @intFromFloat(layout.modal.x),
            .y = @intFromFloat(layout.modal.y),
            .w = @intFromFloat(layout.modal.w),
            .h = @intFromFloat(layout.modal.h),
        }, MODAL_RADIUS);

        const title_color = c.SDL_Color{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b, .a = 255 };
        const title_tex = makeTextTexture(renderer, cache.title_fonts.main, "Create worktree", title_color) catch null;
        if (title_tex) |tex| {
            defer c.SDL_DestroyTexture(tex.tex);
            const title_x = layout.modal.x + (layout.modal.w - @as(f32, @floatFromInt(tex.w))) / 2.0;
            const title_y = layout.modal.y + @as(f32, @floatFromInt(dpi.scale(10, host.ui_scale)));
            _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                .x = title_x,
                .y = title_y,
                .w = @floatFromInt(tex.w),
                .h = @floatFromInt(tex.h),
            });
        }

        // Input box
        _ = c.SDL_SetRenderDrawColor(renderer, 20, 23, 28, 255);
        _ = c.SDL_RenderFillRect(renderer, &layout.input);
        _ = c.SDL_SetRenderDrawColor(renderer, 70, 76, 86, 255);
        primitives.drawRoundedBorder(renderer, geom.Rect{
            .x = @intFromFloat(layout.input.x),
            .y = @intFromFloat(layout.input.y),
            .w = @intFromFloat(layout.input.w),
            .h = @intFromFloat(layout.input.h),
        }, 6);

        const input_text = if (self.create_input.items.len == 0) "name" else self.create_input.items;
        const placeholder = self.create_input.items.len == 0;
        const input_color = if (placeholder) c.SDL_Color{ .r = 140, .g = 148, .b = 161, .a = 255 } else c.SDL_Color{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b, .a = 255 };
        const input_tex = makeTextTexture(renderer, cache.entry_fonts.main, input_text, input_color) catch null;
        const input_pad: f32 = @floatFromInt(dpi.scale(8, host.ui_scale));
        var text_width: f32 = 0;
        var text_height: f32 = 0;
        if (input_tex) |tex| {
            defer c.SDL_DestroyTexture(tex.tex);
            text_width = @floatFromInt(tex.w);
            text_height = @floatFromInt(tex.h);
            _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                .x = layout.input.x + input_pad,
                .y = layout.input.y + input_pad,
                .w = text_width,
                .h = text_height,
            });
        }

        const elapsed_ms = host.now_ms - self.cursor_blink_start_ms;
        const blink_period_ms: i64 = 1000;
        const blink_phase = @mod(elapsed_ms, blink_period_ms);
        if (blink_phase < blink_period_ms / 2) {
            const cursor_x = layout.input.x + input_pad + (if (placeholder) 0.0 else text_width + 2.0);
            const cursor_y = layout.input.y + input_pad;
            const cursor_h = if (text_height > 0) text_height else @as(f32, @floatFromInt(dpi.scale(16, host.ui_scale)));
            _ = c.SDL_SetRenderDrawColor(renderer, theme.foreground.r, theme.foreground.g, theme.foreground.b, 255);
            _ = c.SDL_RenderLine(renderer, cursor_x, cursor_y, cursor_x, cursor_y + cursor_h);
        }

        // Buttons
        button.renderButton(renderer, cache.entry_fonts.main, layout.confirm, "Confirm", .primary, theme, host.ui_scale);
        button.renderButton(renderer, cache.entry_fonts.main, layout.cancel, "Cancel", .default, theme, host.ui_scale);

        // Error message
        if (self.create_error) |err| {
            const err_tex = makeTextTexture(renderer, cache.entry_fonts.main, err, c.SDL_Color{ .r = 255, .g = 99, .b = 99, .a = 255 }) catch null;
            if (err_tex) |tex| {
                defer c.SDL_DestroyTexture(tex.tex);
                const err_x = layout.input.x;
                const err_y = layout.input.y + layout.input.h + @as(f32, @floatFromInt(dpi.scale(8, host.ui_scale)));
                _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                    .x = err_x,
                    .y = err_y,
                    .w = @floatFromInt(tex.w),
                    .h = @floatFromInt(tex.h),
                });
            }
        }
    }

    fn renderRemoveModal(self: *WorktreeOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, _: *types.UiAssets, theme: *const @import("../../colors.zig").Theme) void {
        const cache = self.cache orelse return;
        const layout = self.createModalLayout(host);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 170);
        const backdrop = c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.window_w),
            .h = @floatFromInt(host.window_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &backdrop);

        const sel = theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 240);
        _ = c.SDL_RenderFillRect(renderer, &layout.modal);
        _ = c.SDL_SetRenderDrawColor(renderer, theme.accent.r, theme.accent.g, theme.accent.b, 255);
        primitives.drawRoundedBorder(renderer, geom.Rect{
            .x = @intFromFloat(layout.modal.x),
            .y = @intFromFloat(layout.modal.y),
            .w = @intFromFloat(layout.modal.w),
            .h = @intFromFloat(layout.modal.h),
        }, MODAL_RADIUS);

        const title_color = c.SDL_Color{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b, .a = 255 };
        const title_tex = makeTextTexture(renderer, cache.title_fonts.main, "Remove worktree", title_color) catch null;
        if (title_tex) |tex| {
            defer c.SDL_DestroyTexture(tex.tex);
            const title_x = layout.modal.x + (layout.modal.w - @as(f32, @floatFromInt(tex.w))) / 2.0;
            const title_y = layout.modal.y + @as(f32, @floatFromInt(dpi.scale(10, host.ui_scale)));
            _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                .x = title_x,
                .y = title_y,
                .w = @floatFromInt(tex.w),
                .h = @floatFromInt(tex.h),
            });
        }

        if (self.pending_removal_index) |wt_idx| {
            if (wt_idx < self.worktrees.items.len) {
                const worktree = self.worktrees.items[wt_idx];
                const message_y = layout.modal.y + @as(f32, @floatFromInt(dpi.scale(50, host.ui_scale)));
                const message_color = c.SDL_Color{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b, .a = 200 };
                const message_tex = makeTextTexture(renderer, cache.entry_fonts.main, worktree.display, message_color) catch null;
                if (message_tex) |tex| {
                    defer c.SDL_DestroyTexture(tex.tex);
                    const message_x = layout.modal.x + (layout.modal.w - @as(f32, @floatFromInt(tex.w))) / 2.0;
                    _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                        .x = message_x,
                        .y = message_y,
                        .w = @floatFromInt(tex.w),
                        .h = @floatFromInt(tex.h),
                    });
                }
            }
        }

        button.renderButton(renderer, cache.entry_fonts.main, layout.confirm, "Remove", .danger, theme, host.ui_scale);
        button.renderButton(renderer, cache.entry_fonts.main, layout.cancel, "Cancel", .default, theme, host.ui_scale);
    }

    fn entryCount(self: *WorktreeOverlayComponent) usize {
        return self.worktrees.items.len + 1; // +1 for "New worktree…"
    }

    fn entryIndexAtPoint(self: *WorktreeOverlayComponent, host: *const types.UiHost, y: c_int) ?usize {
        if (self.cache == null) return null;
        const cache = self.cache.?;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const padding: c_int = dpi.scale(20, host.ui_scale);
        const line_height: c_int = dpi.scale(28, host.ui_scale);
        const start_y = rect.y + padding + cache.title.h + line_height;
        if (y < start_y) return null;
        const rel = y - start_y;
        const idx = @as(usize, @intCast(@divFloor(rel, line_height)));
        if (idx >= self.entryCount()) return null;
        return idx;
    }

    fn entryIsRepositoryRoot(self: *WorktreeOverlayComponent, entry_idx: usize) bool {
        if (entry_idx == 0) return false;
        const wt_idx = entry_idx - 1;
        if (wt_idx >= self.worktrees.items.len) return false;
        const base = self.display_base orelse return false;
        return std.mem.eql(u8, self.worktrees.items[wt_idx].abs_path, base);
    }

    fn entryHasRemoveButton(self: *WorktreeOverlayComponent, entry_idx: usize) bool {
        if (entry_idx == 0) return false;
        if (entry_idx - 1 >= self.worktrees.items.len) return false;
        return !self.entryIsRepositoryRoot(entry_idx);
    }

    fn removeButtonRect(self: *WorktreeOverlayComponent, host: *const types.UiHost, entry_idx: usize) ?geom.Rect {
        if (!self.entryHasRemoveButton(entry_idx)) return null;
        if (self.cache == null) return null;
        const cache = self.cache.?;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const padding: c_int = dpi.scale(20, host.ui_scale);
        const line_height: c_int = dpi.scale(28, host.ui_scale);
        const start_y = rect.y + padding + cache.title.h + line_height;
        const entry_y = start_y + @as(c_int, @intCast(entry_idx)) * line_height;

        const button_size: c_int = dpi.scale(16, host.ui_scale);
        const button_x = rect.x + rect.w - padding - button_size - dpi.scale(8, host.ui_scale);
        const entry_tex = cache.entries[entry_idx];
        const button_y = entry_y + @divFloor(entry_tex.path.h - button_size, 2);

        return geom.Rect{
            .x = button_x,
            .y = button_y,
            .w = button_size,
            .h = button_size,
        };
    }

    fn removeButtonIndexAtPoint(self: *WorktreeOverlayComponent, host: *const types.UiHost, x: c_int, y: c_int) ?usize {
        if (self.overlay.state != .Open) return null;
        const entry_idx = self.entryIndexAtPoint(host, y) orelse return null;
        if (!self.entryHasRemoveButton(entry_idx)) return null;
        const button_rect = self.removeButtonRect(host, entry_idx) orelse return null;
        if (geom.containsPoint(button_rect, x, y)) {
            return entry_idx;
        }
        return null;
    }

    const GitContext = struct {
        gitdir: []const u8,
        commondir: []const u8,
        allocator: std.mem.Allocator,

        fn deinit(self: *GitContext) void {
            self.allocator.free(self.gitdir);
            self.allocator.free(self.commondir);
        }
    };

    fn collectFromGitMetadata(self: *WorktreeOverlayComponent, cwd: []const u8) bool {
        const ctx_opt = self.findGitContext(cwd) catch {
            return false;
        };
        var ctx_storage: GitContext = undefined;
        const ctx = ctx_opt orelse return false;
        ctx_storage = ctx;
        defer ctx_storage.deinit();

        const main_worktree = std.fs.path.dirname(ctx.commondir) orelse ctx.commondir;
        self.setDisplayBase(main_worktree);

        _ = self.appendWorktree(main_worktree);

        const worktrees_dir_buf = std.fs.path.join(self.allocator, &.{ ctx.commondir, "worktrees" }) catch {
            return self.worktrees.items.len > 0;
        };
        defer self.allocator.free(worktrees_dir_buf);

        var dir = std.fs.openDirAbsolute(worktrees_dir_buf, .{ .iterate = true }) catch {
            return self.worktrees.items.len > 0;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (iterator.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const wt_file = std.fs.path.join(self.allocator, &.{ worktrees_dir_buf, entry.name, "worktree" }) catch continue;
            defer self.allocator.free(wt_file);
            const path = self.readTrimmedFile(wt_file) catch {
                const gitdir_file = std.fs.path.join(self.allocator, &.{ worktrees_dir_buf, entry.name, "gitdir" }) catch continue;
                defer self.allocator.free(gitdir_file);
                const gitdir_path = self.readTrimmedFile(gitdir_file) catch continue;
                defer self.allocator.free(gitdir_path);
                const derived = deriveWorktreePathFromGitdir(gitdir_path);
                const duped = self.allocator.dupe(u8, derived) catch continue;
                defer self.allocator.free(duped);
                _ = self.appendWorktree(duped);
                continue;
            };
            defer self.allocator.free(path);
            _ = self.appendWorktree(path);
        }

        return self.worktrees.items.len > 0;
    }

    fn readTrimmedFile(self: *WorktreeOverlayComponent, path: []const u8) ![]const u8 {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(self.allocator, 4096);
        return std.mem.trim(u8, contents, " \t\r\n");
    }

    fn findGitContext(self: *WorktreeOverlayComponent, cwd: []const u8) !?GitContext {
        var current = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(current);

        while (true) {
            const candidate = std.fs.path.join(self.allocator, &.{ current, ".git" }) catch break;
            defer self.allocator.free(candidate);

            if (std.fs.openDirAbsolute(candidate, .{})) |dir| {
                var owned_dir = dir;
                owned_dir.close();
                const gitdir = try self.allocator.dupe(u8, candidate);
                const commondir = try self.resolveCommonDir(gitdir);
                self.allocator.free(current);
                return GitContext{ .gitdir = gitdir, .commondir = commondir, .allocator = self.allocator };
            } else |_| {
                // .git file case
                if (std.fs.openFileAbsolute(candidate, .{})) |file| {
                    defer file.close();
                    const gitdir_line = self.readTrimmedFile(candidate) catch {
                        break;
                    };
                    defer self.allocator.free(gitdir_line);
                    if (!std.mem.startsWith(u8, gitdir_line, "gitdir:")) {
                        break;
                    }
                    const path_part = std.mem.trim(u8, gitdir_line["gitdir:".len..], " \t");
                    const base_dir = std.fs.path.dirname(candidate) orelse ".";
                    const resolved = std.fs.path.resolve(self.allocator, &.{ base_dir, path_part }) catch break;
                    const commondir = try self.resolveCommonDir(resolved);
                    self.allocator.free(current);
                    return GitContext{ .gitdir = resolved, .commondir = commondir, .allocator = self.allocator };
                } else |_| {}
            }

            // climb up
            const parent = std.fs.path.dirname(current) orelse break;
            const parent_copy = try self.allocator.dupe(u8, parent);
            self.allocator.free(current);
            current = parent_copy;
        }

        self.allocator.free(current);
        return null;
    }

    fn resolveCommonDir(self: *WorktreeOverlayComponent, gitdir: []const u8) ![]const u8 {
        const commondir_path = std.fs.path.join(self.allocator, &.{ gitdir, "commondir" }) catch {
            return self.allocator.dupe(u8, gitdir);
        };
        defer self.allocator.free(commondir_path);

        const commondir_rel = self.readTrimmedFile(commondir_path) catch {
            return self.allocator.dupe(u8, gitdir);
        };
        defer self.allocator.free(commondir_rel);

        if (commondir_rel.len == 0) {
            return self.allocator.dupe(u8, gitdir);
        }

        if (std.fs.path.isAbsolute(commondir_rel)) {
            return self.allocator.dupe(u8, commondir_rel);
        }

        return std.fs.path.resolve(self.allocator, &.{ gitdir, commondir_rel });
    }

    fn appendWorktree(self: *WorktreeOverlayComponent, abs_path: []const u8) bool {
        for (self.worktrees.items) |existing| {
            if (std.mem.eql(u8, existing.abs_path, abs_path)) return false;
        }
        const abs = self.allocator.dupe(u8, abs_path) catch return false;
        const base = self.display_base orelse abs_path;
        const display = self.makeDisplayPath(base, abs) catch {
            self.allocator.free(abs);
            return false;
        };
        self.worktrees.append(self.allocator, .{
            .abs_path = abs,
            .display = display,
        }) catch {
            self.allocator.free(abs);
            self.allocator.free(display);
            return false;
        };
        return true;
    }

    fn deriveWorktreePathFromGitdir(gitdir_path: []const u8) []const u8 {
        const suffix = "/.git";
        if (std.mem.endsWith(u8, gitdir_path, suffix)) {
            return gitdir_path[0 .. gitdir_path.len - suffix.len];
        }
        return std.fs.path.dirname(gitdir_path) orelse gitdir_path;
    }

    fn openFontWithFallbacks(
        font_path: [:0]const u8,
        symbol_path: ?[:0]const u8,
        emoji_path: ?[:0]const u8,
        size: c_int,
    ) !FontWithFallbacks {
        const main = c.TTF_OpenFont(font_path.ptr, @floatFromInt(size)) orelse return error.FontUnavailable;
        errdefer c.TTF_CloseFont(main);

        var symbol: ?*c.TTF_Font = null;
        if (symbol_path) |path| {
            symbol = c.TTF_OpenFont(path.ptr, @floatFromInt(size));
            if (symbol) |s| {
                if (!c.TTF_AddFallbackFont(main, s)) {
                    c.TTF_CloseFont(s);
                    symbol = null;
                }
            }
        }

        var emoji: ?*c.TTF_Font = null;
        if (emoji_path) |path| {
            emoji = c.TTF_OpenFont(path.ptr, @floatFromInt(size));
            if (emoji) |e| {
                if (!c.TTF_AddFallbackFont(main, e)) {
                    c.TTF_CloseFont(e);
                    emoji = null;
                }
            }
        }

        return FontWithFallbacks{
            .main = main,
            .symbol = symbol,
            .emoji = emoji,
        };
    }

    fn closeFontWithFallbacks(fonts: FontWithFallbacks) void {
        if (fonts.symbol) |s| c.TTF_CloseFont(s);
        if (fonts.emoji) |e| c.TTF_CloseFont(e);
        c.TTF_CloseFont(fonts.main);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        deinit(self_ptr, renderer);
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *WorktreeOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.isAnimating() or self.first_frame.wantsFrame() or self.overlay.state == .Open or self.creating;
    }

    pub const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};
