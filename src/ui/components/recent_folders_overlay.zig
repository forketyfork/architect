const std = @import("std");
const c = @import("../../c.zig");
const env = @import("../../env.zig");
const colors = @import("../../colors.zig");
const config = @import("../../config.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../../dpi.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;
const GlyphBadge = @import("glyph_badge.zig").GlyphBadge;
const flowing_line = @import("flowing_line.zig");
const search_utils = @import("search_utils.zig");
const text_edit = @import("../text_edit.zig");
const text_render = @import("../text_render.zig");
const font_cache_mod = @import("../../font_cache.zig");

const log = std.log.scoped(.recent_folders_overlay);

pub const RecentFoldersOverlayComponent = struct {
    allocator: std.mem.Allocator,
    overlay: ExpandingOverlay = ExpandingOverlay.init(1, button_margin, button_size_small, button_size_large, button_animation_duration_ms),
    first_frame: FirstFrameGuard = .{},
    badge: GlyphBadge = .{ .text = "⌘O" },

    all_folders: std.ArrayList(Folder) = .empty,
    filtered_indices: std.ArrayList(usize) = .empty,
    selected_index: usize = 0,
    hovered_entry: ?usize = null,
    escape_pressed: bool = false,
    focused_busy: bool = false,
    cache: ?*Cache = null,
    flow_animation_start_ms: i64 = 0,

    search: text_edit.TextInput = .{ .separators = text_edit.path_separators, .accepts = text_edit.isSingleLineChar },

    const button_size_small: c_int = 40;
    const button_size_large: c_int = 400;
    const button_margin: c_int = 20;
    const button_animation_duration_ms: i64 = 200;
    const line_height: c_int = 28;
    const max_display: usize = 10;
    const search_bar_height: c_int = 28;

    const title = "Recent Folders";

    const Folder = struct {
        abs_path: []const u8,
        display: []const u8,
    };

    const TextTex = search_utils.TextTex;

    const EntryTex = struct {
        hotkey: TextTex,
        path: TextTex,
        displayed_text: []const u8,
    };

    const Cache = struct {
        ui_scale: f32,
        title_font_size: c_int,
        entry_font_size: c_int,
        title: TextTex,
        entries: []EntryTex,
        theme_fg: c.SDL_Color,
        font_generation: u64,
        query_len: usize,
        filtered_count: usize,
    };

    pub fn create(allocator: std.mem.Allocator) !UiComponent {
        const comp = try allocator.create(RecentFoldersOverlayComponent);
        comp.* = .{ .allocator = allocator };
        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 1000,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.badge.deinit();
        self.destroyCache();
        self.clearFolders();
        self.all_folders.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);
        self.search.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setFolders(self: *RecentFoldersOverlayComponent, recent_folders: []const config.Persistence.RecentFolder) void {
        self.clearFolders();
        self.destroyCache();

        for (recent_folders) |folder| {
            const abs = self.allocator.dupe(u8, folder.path) catch |err| {
                log.warn("failed to dupe folder path: {}", .{err});
                continue;
            };
            const display = makeDisplayPath(self.allocator, folder.path) catch |err| {
                log.warn("failed to make display path: {}", .{err});
                self.allocator.free(abs);
                continue;
            };
            self.all_folders.append(self.allocator, .{
                .abs_path = abs,
                .display = display,
            }) catch |err| {
                log.warn("failed to append folder: {}", .{err});
                self.allocator.free(abs);
                self.allocator.free(display);
                continue;
            };
        }

        self.refilter();
    }

    fn refilter(self: *RecentFoldersOverlayComponent) void {
        self.filtered_indices.clearRetainingCapacity();
        self.destroyCache();

        const query = std.mem.trim(u8, self.search.text(), " \t");

        for (self.all_folders.items, 0..) |folder, idx| {
            if (self.filtered_indices.items.len >= max_display) break;

            if (query.len == 0 or search_utils.findCaseInsensitive(folder.display, query, 0) != null) {
                self.filtered_indices.append(self.allocator, idx) catch |err| {
                    log.warn("failed to append filtered index: {}", .{err});
                    break;
                };
            }
        }

        if (self.selected_index >= self.filtered_indices.items.len) {
            self.selected_index = if (self.filtered_indices.items.len > 0) self.filtered_indices.items.len - 1 else 0;
        }
    }

    fn filteredFolder(self: *RecentFoldersOverlayComponent, display_idx: usize) ?Folder {
        if (display_idx >= self.filtered_indices.items.len) return null;
        const source_idx = self.filtered_indices.items[display_idx];
        if (source_idx >= self.all_folders.items.len) return null;
        return self.all_folders.items[source_idx];
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (event.type == c.SDL_EVENT_KEY_UP and self.escape_pressed) {
            const key = event.key.key;
            if (key == c.SDLK_ESCAPE) {
                self.escape_pressed = false;
                return true;
            }
        }

        if (!self.pillVisible(host)) return false;

        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
                const inside = geom.containsPoint(rect, mouse_x, mouse_y);

                if (inside and self.overlay.state == .Open) {
                    if (self.entryIndexAtPoint(host, mouse_y)) |idx| {
                        if (self.filteredFolder(idx)) |folder| {
                            self.emitChangeDir(actions, host.focused_session, folder.abs_path);
                            self.closeOverlay(host.now_ms);
                        }
                        return true;
                    }
                }

                if (inside) {
                    switch (self.overlay.state) {
                        .Closed => {
                            self.overlay.startExpanding(host.now_ms);
                            self.search.touch(host.now_ms);
                        },
                        .Open => self.closeOverlay(host.now_ms),
                        else => {},
                    }
                    return true;
                }

                if (self.overlay.state == .Open and !inside) {
                    self.closeOverlay(host.now_ms);
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
                    return false;
                }
                self.hovered_entry = self.entryIndexAtPoint(host, mouse_y);
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL)) != 0;

                // Cmd+O toggles overlay
                if (has_gui and !has_blocking_mod and key == c.SDLK_O) {
                    if (self.overlay.state.isOpenOrOpening()) {
                        self.closeOverlay(host.now_ms);
                    } else {
                        self.overlay.startExpanding(host.now_ms);
                        self.search.touch(host.now_ms);
                    }
                    return true;
                }

                if (self.overlay.state.isOpenOrOpening()) {
                    // Cmd+1-9 picks an entry, so it must win over the field's
                    // own Cmd shortcuts before the input sees the key.
                    if (has_gui and !has_blocking_mod and key >= c.SDLK_1 and key <= c.SDLK_9) {
                        const digit_idx: usize = @intCast(key - c.SDLK_1);
                        if (self.filteredFolder(digit_idx)) |folder| {
                            self.emitChangeDir(actions, host.focused_session, folder.abs_path);
                            self.closeOverlay(host.now_ms);
                        }
                        return true;
                    }

                    const edit = self.search.handleKey(self.allocator, key, mod, host.now_ms);
                    if (edit.consumed) {
                        if (edit.text_changed) self.refilter();
                        return true;
                    }

                    // Arrow navigation
                    if (key == c.SDLK_UP) {
                        if (self.filtered_indices.items.len > 0) {
                            if (self.selected_index > 0) {
                                self.selected_index -= 1;
                            } else {
                                self.selected_index = self.filtered_indices.items.len - 1;
                            }
                        }
                        return true;
                    }
                    if (key == c.SDLK_DOWN) {
                        if (self.filtered_indices.items.len > 0) {
                            if (self.selected_index < self.filtered_indices.items.len - 1) {
                                self.selected_index += 1;
                            } else {
                                self.selected_index = 0;
                            }
                        }
                        return true;
                    }

                    // Enter selects current
                    if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
                        if (self.filteredFolder(self.selected_index)) |folder| {
                            self.emitChangeDir(actions, host.focused_session, folder.abs_path);
                            self.closeOverlay(host.now_ms);
                        }
                        return true;
                    }

                    // Escape closes
                    if (key == c.SDLK_ESCAPE) {
                        self.escape_pressed = true;
                        self.closeOverlay(host.now_ms);
                        return true;
                    }

                    return true;
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (self.overlay.state.isOpenOrOpening()) {
                    const text = std.mem.span(event.text.text);
                    if (self.search.insert(self.allocator, text, host.now_ms)) self.refilter();
                    return true;
                }
            },
            else => {},
        }

        return false;
    }

    fn closeOverlay(self: *RecentFoldersOverlayComponent, now_ms: i64) void {
        self.overlay.startCollapsing(now_ms);
        self.search.clear();
        self.refilter();
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.pillVisible(host)) return false;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        return geom.containsPoint(rect, x, y);
    }

    pub fn shouldShowPill(folder_count: usize, focused_busy: bool) bool {
        return folder_count > 0 and !focused_busy;
    }

    pub fn pillVisible(self: *const RecentFoldersOverlayComponent, host: *const types.UiHost) bool {
        return shouldShowPill(self.all_folders.items.len, host.focused_has_foreground_process);
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));

        const busy = host.focused_has_foreground_process;
        if (busy != self.focused_busy) {
            self.focused_busy = busy;
            if (busy) {
                self.destroyCache();
                self.hovered_entry = null;
                self.escape_pressed = false;
                if (self.overlay.state == .Open or self.overlay.state == .Expanding) {
                    self.closeOverlay(host.now_ms);
                }
            }
        }

        if (!self.pillVisible(host) and self.overlay.state.isOpenOrOpening()) {
            self.closeOverlay(host.now_ms);
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

        if (self.focused_busy) {
            self.hovered_entry = null;
            return;
        }
    }

    fn render(self_ptr: *anyopaque, ui_host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.first_frame.markDrawn();
        if (!self.pillVisible(ui_host)) return;

        const rect = self.overlay.rect(ui_host.now_ms, ui_host.window_w, ui_host.window_h, ui_host.ui_scale);
        const radius: c_int = 8;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const sel = ui_host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 245);
        primitives.fillRoundedRect(renderer, rect, radius);

        const accent = ui_host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 255);
        primitives.drawRoundedBorder(renderer, rect, radius);

        if (self.overlay.state != .Closed) {
            _ = self.ensureCache(renderer, ui_host.ui_scale, assets, ui_host.theme);
        }

        switch (self.overlay.state) {
            .Closed, .Collapsing, .Expanding => self.badge.render(self.allocator, renderer, rect, ui_host.ui_scale, assets, ui_host.theme),
            .Open => self.renderOverlay(renderer, ui_host, rect, ui_host.ui_scale, assets, ui_host.theme),
        }
    }

    fn renderOverlay(self: *RecentFoldersOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) void {
        const cache = self.ensureCache(renderer, ui_scale, assets, theme) orelse return;

        const scaled_margin: c_int = dpi.scale(button_margin, ui_scale);
        const scaled_line_height: c_int = dpi.scale(line_height, ui_scale);
        var y_offset: c_int = rect.y + scaled_margin;

        // Render title
        const title_tex = cache.title;
        const title_x = rect.x + @divFloor(rect.w - title_tex.w, 2);
        _ = c.SDL_RenderTexture(renderer, title_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(y_offset),
            .w = @floatFromInt(title_tex.w),
            .h = @floatFromInt(title_tex.h),
        });
        y_offset += title_tex.h + dpi.scale(8, ui_scale);

        // Render search bar
        const font_cache = assets.font_cache orelse return;
        const search_bar_rect = geom.Rect{
            .x = rect.x + scaled_margin,
            .y = y_offset,
            .w = rect.w - 2 * scaled_margin,
            .h = dpi.scale(search_bar_height, ui_scale),
        };
        search_utils.renderSearchBar(
            self.allocator,
            renderer,
            host,
            search_bar_rect,
            font_cache,
            &self.search,
            self.filtered_indices.items.len,
            if (self.filtered_indices.items.len > 0) self.selected_index else null,
        ) catch |err| {
            log.warn("failed to render search bar: {}", .{err});
        };
        y_offset += dpi.scale(search_bar_height, ui_scale) + dpi.scale(8, ui_scale);

        // Render entries
        const entry_font_size: c_int = dpi.scale(16, ui_scale);
        const entry_fonts = font_cache.get(entry_font_size) catch |err| blk: {
            log.warn("failed to load entry font size {d}: {}", .{ entry_font_size, err });
            break :blk null;
        };
        const query = std.mem.trim(u8, self.search.text(), " \t");

        for (cache.entries, 0..) |entry_tex, idx| {
            const is_selected = idx == self.selected_index;
            const is_hovered = if (self.hovered_entry) |h| h == idx else false;

            // Highlight background for selected or hovered
            if (is_selected or is_hovered) {
                const highlight_y = @as(f32, @floatFromInt(y_offset - dpi.scale(4, ui_scale)));
                const highlight_h = @as(f32, @floatFromInt(scaled_line_height));
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
                const alpha: u8 = if (is_selected) 60 else 40;
                _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, alpha);
                _ = c.SDL_RenderFillRect(renderer, &center_rect);

                // Fade strips
                const strips_count = 6;
                var i: usize = 0;
                while (i < strips_count) : (i += 1) {
                    const progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(strips_count));
                    const strip_w = fade_width / @as(f32, @floatFromInt(strips_count));

                    const left_alpha = @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * progress));
                    const left_strip = c.SDL_FRect{
                        .x = rect_x + @as(f32, @floatFromInt(i)) * strip_w,
                        .y = highlight_y,
                        .w = strip_w,
                        .h = highlight_h,
                    };
                    _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, left_alpha);
                    _ = c.SDL_RenderFillRect(renderer, &left_strip);

                    const right_alpha = @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * (1.0 - progress)));
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

            // Render hotkey
            _ = c.SDL_RenderTexture(renderer, entry_tex.hotkey.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + scaled_margin),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.hotkey.w),
                .h = @floatFromInt(entry_tex.hotkey.h),
            });

            // Render path (right-aligned)
            const path_x = rect.x + rect.w - scaled_margin - entry_tex.path.w;
            _ = c.SDL_RenderTexture(renderer, entry_tex.path.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(path_x),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.path.w),
                .h = @floatFromInt(entry_tex.path.h),
            });

            // Render search match highlights on path text
            if (query.len > 0 and entry_fonts != null) {
                self.renderPathHighlights(
                    renderer,
                    host,
                    entry_fonts.?,
                    path_x,
                    y_offset,
                    scaled_line_height,
                    ui_scale,
                    entry_tex.displayed_text,
                    query,
                );
            }

            // Render flowing line for selected entry
            if (is_selected) {
                const flow_y = y_offset + @divFloor(entry_tex.path.h, 2);
                flowing_line.render(renderer, self.flow_animation_start_ms, host.now_ms, rect, flow_y, ui_scale, theme);
            }

            y_offset += scaled_line_height;
        }
    }

    fn renderPathHighlights(
        _: *RecentFoldersOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        entry_fonts: *font_cache_mod.FontSet,
        path_x: c_int,
        y_offset: c_int,
        lh: c_int,
        ui_scale: f32,
        display_path: []const u8,
        query: []const u8,
    ) void {
        var pos: usize = 0;
        while (search_utils.findCaseInsensitive(display_path, query, pos)) |found| {
            const before_text = display_path[0..found];
            const match_text = display_path[found .. found + query.len];

            var before_w: c_int = 0;
            var before_h: c_int = 0;
            if (before_text.len > 0) {
                _ = c.TTF_GetStringSize(entry_fonts.regular, @ptrCast(before_text.ptr), before_text.len, &before_w, &before_h);
            }

            var match_w: c_int = 0;
            var match_h: c_int = 0;
            _ = c.TTF_GetStringSize(entry_fonts.regular, @ptrCast(match_text.ptr), match_text.len, &match_w, &match_h);

            const highlight_x = path_x + before_w;
            const highlight_y = y_offset + dpi.scale(2, ui_scale);
            const highlight_h = lh - dpi.scale(6, ui_scale);

            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 120);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                .x = @floatFromInt(highlight_x),
                .y = @floatFromInt(highlight_y),
                .w = @floatFromInt(match_w),
                .h = @floatFromInt(highlight_h),
            });

            pos = found + 1;
        }
    }

    fn emitChangeDir(_: *RecentFoldersOverlayComponent, actions: *types.UiActionQueue, session_idx: usize, abs_path: []const u8) void {
        const path_copy = actions.allocator.dupe(u8, abs_path) catch return;
        actions.append(.{ .ChangeDirectory = .{ .session = session_idx, .path = path_copy } }) catch {
            actions.allocator.free(path_copy);
        };
    }

    fn clearFolders(self: *RecentFoldersOverlayComponent) void {
        for (self.all_folders.items) |folder| {
            self.allocator.free(folder.abs_path);
            self.allocator.free(folder.display);
        }
        self.all_folders.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();
        self.hovered_entry = null;
    }

    fn entryIndexAtPoint(self: *RecentFoldersOverlayComponent, host: *const types.UiHost, y: c_int) ?usize {
        if (self.cache == null) return null;
        const cache = self.cache.?;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const scaled_margin: c_int = dpi.scale(button_margin, host.ui_scale);
        const scaled_lh: c_int = dpi.scale(line_height, host.ui_scale);
        const search_h = dpi.scale(search_bar_height, host.ui_scale) + dpi.scale(8, host.ui_scale);
        const start_y = rect.y + scaled_margin + cache.title.h + dpi.scale(8, host.ui_scale) + search_h;
        if (y < start_y) return null;
        const rel = y - start_y;
        const idx = @as(usize, @intCast(@divFloor(rel, scaled_lh)));
        if (idx >= self.filtered_indices.items.len) return null;
        return idx;
    }

    fn ensureCache(self: *RecentFoldersOverlayComponent, renderer: *c.SDL_Renderer, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) ?*Cache {
        const cache_store = assets.font_cache orelse return null;
        const title_font_size: c_int = dpi.scale(20, ui_scale);
        const entry_font_size: c_int = dpi.scale(16, ui_scale);
        const fg = theme.foreground;
        const entry_count = self.filtered_indices.items.len;

        if (self.cache) |cache| {
            if (cache.title_font_size == title_font_size and
                cache.entry_font_size == entry_font_size and
                cache.theme_fg.r == fg.r and cache.theme_fg.g == fg.g and cache.theme_fg.b == fg.b and
                cache.ui_scale == ui_scale and
                cache.entries.len == entry_count and
                cache.font_generation == cache_store.generation and
                cache.query_len == self.search.text().len and
                cache.filtered_count == entry_count)
            {
                return cache;
            }
            self.destroyCache();
        }

        const cache = self.allocator.create(Cache) catch return null;
        errdefer self.allocator.destroy(cache);

        const title_fonts = cache_store.get(title_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const entry_fonts = cache_store.get(entry_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const title_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const title_tex = self.makeTextTexture(renderer, .{ .text = title_fonts.regular }, title, title_color) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const key_color = c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 255 };
        const entry_color = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };

        const entries = self.allocator.alloc(EntryTex, entry_count) catch {
            c.SDL_DestroyTexture(title_tex.tex);
            self.allocator.destroy(cache);
            return null;
        };
        errdefer self.allocator.free(entries);

        const padding = dpi.scale(20, ui_scale);
        const overlay_width = dpi.scale(button_size_large, ui_scale);
        const hotkey_spacing = dpi.scale(10, ui_scale);

        for (0..entry_count) |idx| {
            const source_idx = self.filtered_indices.items[idx];
            var key_buf: [8]u8 = undefined;
            const digit: u8 = @as(u8, @intCast((idx + 1) % 10));
            const key_slice = std.fmt.bufPrint(&key_buf, "⌘{d}", .{digit}) catch |err| blk: {
                log.warn("failed to format hotkey: {}", .{err});
                break :blk key_buf[0..0];
            };
            const key_tex = self.makeTextTexture(renderer, .{ .text = entry_fonts.regular }, key_slice, key_color) catch {
                destroyEntryTextures(self.allocator, entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                self.allocator.destroy(cache);
                return null;
            };

            const path_slice = self.all_folders.items[source_idx].display;
            const max_path_width = overlay_width - (2 * padding) - key_tex.w - hotkey_spacing;

            var path_buf: [256]u8 = undefined;
            const truncated_path = truncateTextLeft(path_slice, entry_fonts.regular, max_path_width, &path_buf) catch |err| blk: {
                log.warn("failed to truncate path: {}", .{err});
                break :blk path_slice;
            };
            const path_tex = self.makeTextTexture(renderer, .{ .text = entry_fonts.regular, .emoji = entry_fonts.emoji }, truncated_path, entry_color) catch {
                c.SDL_DestroyTexture(key_tex.tex);
                destroyEntryTextures(self.allocator, entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                self.allocator.destroy(cache);
                return null;
            };
            const stored_text = self.allocator.dupe(u8, truncated_path) catch {
                c.SDL_DestroyTexture(path_tex.tex);
                c.SDL_DestroyTexture(key_tex.tex);
                destroyEntryTextures(self.allocator, entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                self.allocator.destroy(cache);
                return null;
            };
            entries[idx] = .{ .hotkey = key_tex, .path = path_tex, .displayed_text = stored_text };
        }

        cache.* = .{
            .ui_scale = ui_scale,
            .title_font_size = title_font_size,
            .entry_font_size = entry_font_size,
            .title = title_tex,
            .entries = entries,
            .theme_fg = fg,
            .font_generation = cache_store.generation,
            .query_len = self.search.text().len,
            .filtered_count = entry_count,
        };

        self.cache = cache;

        const scaled_lh: c_int = dpi.scale(line_height, ui_scale);
        const scaled_padding: c_int = dpi.scale(2 * button_margin, ui_scale);
        const search_h = dpi.scale(search_bar_height, ui_scale) + dpi.scale(8, ui_scale);
        const content_height = scaled_padding + title_tex.h + dpi.scale(8, ui_scale) + search_h + @as(c_int, @intCast(entry_count)) * scaled_lh;
        self.overlay.setContentHeight(content_height);

        return cache;
    }

    fn destroyCache(self: *RecentFoldersOverlayComponent) void {
        if (self.cache) |cache| {
            c.SDL_DestroyTexture(cache.title.tex);
            destroyEntryTextures(self.allocator, cache.entries);
            self.allocator.free(cache.entries);
            self.allocator.destroy(cache);
            self.cache = null;
        }
    }

    fn makeDisplayPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const home = env.get("HOME");
        if (home) |h| {
            if (std.mem.startsWith(u8, path, h)) {
                const suffix = path[h.len..];
                if (suffix.len == 0) return try allocator.dupe(u8, "~");
                if (suffix[0] == '/') {
                    var result = try allocator.alloc(u8, 1 + suffix.len);
                    result[0] = '~';
                    @memcpy(result[1..], suffix);
                    return result;
                }
            }
        }
        return try allocator.dupe(u8, path);
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

    /// Entry paths are user data and can contain emoji, so they go through the
    /// emoji-aware renderer; `fonts.emoji` is null only for static labels.
    fn makeTextTexture(
        self: *RecentFoldersOverlayComponent,
        renderer: *c.SDL_Renderer,
        fonts: text_render.LineFonts,
        text: []const u8,
        color: c.SDL_Color,
    ) !TextTex {
        return text_render.makeTextTexture(self.allocator, renderer, fonts, text, color);
    }

    fn destroyEntryTextures(allocator: std.mem.Allocator, entries: []EntryTex) void {
        for (entries) |entry| {
            c.SDL_DestroyTexture(entry.hotkey.tex);
            c.SDL_DestroyTexture(entry.path.tex);
            allocator.free(entry.displayed_text);
        }
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        deinit(self_ptr, renderer);
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.isAnimating() or self.first_frame.wantsFrame() or self.overlay.state == .Open;
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

// --- Tests ---

const testing = std.testing;

fn testTheme() colors.Theme {
    const base = c.SDL_Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    return .{
        .background = base,
        .foreground = base,
        .selection = base,
        .accent = base,
        .palette = [_]c.SDL_Color{base} ** 16,
    };
}

fn testHost(now_ms: i64, theme: *const colors.Theme) types.UiHost {
    return .{
        .now_ms = now_ms,
        .window_w = 1200,
        .window_h = 800,
        .window_focused = true,
        .ui_scale = 1.0,
        .grid_cols = 2,
        .grid_rows = 2,
        .cell_w = 8,
        .cell_h = 16,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Grid,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = false,
        .sessions = &.{},
        .theme = theme,
    };
}

fn keyEvent(key: c.SDL_Keycode, mod: c.SDL_Keymod) c.SDL_Event {
    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = key;
    event.key.mod = mod;
    return event;
}

fn textEvent(text: [*c]const u8) c.SDL_Event {
    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = text;
    return event;
}

const TestComponent = struct {
    comp: RecentFoldersOverlayComponent,
    actions: types.UiActionQueue,
    theme: colors.Theme,

    fn init() TestComponent {
        return .{
            .comp = .{ .allocator = testing.allocator },
            .actions = types.UiActionQueue.init(testing.allocator),
            .theme = testTheme(),
        };
    }

    fn deinit(self: *TestComponent) void {
        self.comp.clearFolders();
        self.comp.all_folders.deinit(testing.allocator);
        self.comp.filtered_indices.deinit(testing.allocator);
        self.comp.search.deinit(testing.allocator);
        self.actions.deinit();
    }

    fn sendWithBusy(self: *TestComponent, event: c.SDL_Event, now_ms: i64, focused_busy: bool) bool {
        var host = testHost(now_ms, &self.theme);
        host.focused_has_foreground_process = focused_busy;
        var ev = event;
        return RecentFoldersOverlayComponent.handleEvent(&self.comp, &host, &ev, &self.actions);
    }

    fn send(self: *TestComponent, event: c.SDL_Event, now_ms: i64) bool {
        return self.sendWithBusy(event, now_ms, false);
    }
};

fn addTestFolder(t: *TestComponent) void {
    const folders = [_]config.Persistence.RecentFolder{
        .{ .path = "/tmp/architect-test-folder", .count = 1 },
    };
    t.comp.setFolders(&folders);
}

test "Cmd+Backspace clears the search query and Alt+Backspace drops one segment" {
    var t = TestComponent.init();
    defer t.deinit();

    addTestFolder(&t);
    t.comp.overlay.state = .Open;
    try t.comp.search.buf.appendSlice(testing.allocator, "dev/github/architect");

    try testing.expect(t.send(keyEvent(c.SDLK_BACKSPACE, c.SDL_KMOD_ALT), 0));
    try testing.expectEqualStrings("dev/github/", t.comp.search.text());

    // The separator run is consumed with the next word, so a second press
    // makes progress instead of stalling on the slash.
    try testing.expect(t.send(keyEvent(c.SDLK_BACKSPACE, c.SDL_KMOD_ALT), 0));
    try testing.expectEqualStrings("dev/", t.comp.search.text());

    try testing.expect(t.send(keyEvent(c.SDLK_BACKSPACE, c.SDL_KMOD_GUI), 0));
    try testing.expectEqualStrings("", t.comp.search.text());
}

test "plain Backspace still deletes a single character" {
    var t = TestComponent.init();
    defer t.deinit();

    addTestFolder(&t);
    t.comp.overlay.state = .Open;
    try t.comp.search.buf.appendSlice(testing.allocator, "arch");

    try testing.expect(t.send(keyEvent(c.SDLK_BACKSPACE, 0), 0));
    try testing.expectEqualStrings("arc", t.comp.search.text());
}

test "keys typed during the expand animation reach the search query" {
    var t = TestComponent.init();
    defer t.deinit();

    // Cmd+O starts the expand; the overlay is .Expanding, not .Open, for the
    // whole animation, and must already own the keyboard.
    addTestFolder(&t);
    try testing.expect(t.send(keyEvent(c.SDLK_O, c.SDL_KMOD_GUI), 0));
    try testing.expectEqual(ExpandingOverlay.State.Expanding, t.comp.overlay.state);

    try testing.expect(t.send(textEvent("a"), 10));
    try testing.expect(t.send(textEvent("r"), 20));
    try testing.expectEqualStrings("ar", t.comp.search.text());

    try testing.expect(t.send(keyEvent(c.SDLK_BACKSPACE, 0), 30));
    try testing.expectEqualStrings("a", t.comp.search.text());
}

test "Cmd+O during the expand animation closes the overlay" {
    var t = TestComponent.init();
    defer t.deinit();

    addTestFolder(&t);
    try testing.expect(t.send(keyEvent(c.SDLK_O, c.SDL_KMOD_GUI), 0));
    try testing.expect(t.send(keyEvent(c.SDLK_O, c.SDL_KMOD_GUI), 50));
    try testing.expectEqual(ExpandingOverlay.State.Collapsing, t.comp.overlay.state);
}

test "closed overlay ignores typing so it reaches the terminal" {
    var t = TestComponent.init();
    defer t.deinit();

    try testing.expect(!t.send(textEvent("a"), 0));
    try testing.expect(!t.send(keyEvent(c.SDLK_BACKSPACE, 0), 0));
    try testing.expectEqualStrings("", t.comp.search.text());
}

test "Cmd+A selects the query and the next keystroke replaces it" {
    var t = TestComponent.init();
    defer t.deinit();

    addTestFolder(&t);
    t.comp.overlay.state = .Open;
    try t.comp.search.buf.appendSlice(testing.allocator, "arch");

    try testing.expect(t.send(keyEvent(c.SDLK_A, c.SDL_KMOD_GUI), 0));
    try testing.expect(t.comp.search.select_all);

    try testing.expect(t.send(textEvent("z"), 10));
    try testing.expectEqualStrings("z", t.comp.search.text());
    try testing.expect(!t.comp.search.select_all);
}

test "Cmd+1-9 picks an entry instead of reaching the text field" {
    var t = TestComponent.init();
    defer t.deinit();

    const folders = [_]config.Persistence.RecentFolder{
        .{ .path = "/tmp/architect-test-alpha", .count = 1 },
        .{ .path = "/tmp/architect-test-beta", .count = 1 },
    };
    t.comp.setFolders(&folders);
    t.comp.overlay.state = .Open;

    // Cmd+2 is a quick-select, not a text-field shortcut.
    try testing.expect(t.send(keyEvent(c.SDLK_2, c.SDL_KMOD_GUI), 0));
    const action = t.actions.pop() orelse return error.NoActionQueued;
    try testing.expect(action == .ChangeDirectory);
    defer testing.allocator.free(action.ChangeDirectory.path);
    try testing.expectEqualStrings("/tmp/architect-test-beta", action.ChangeDirectory.path);
}

test "the caret blinks while the picker is open" {
    var t = TestComponent.init();
    defer t.deinit();

    // Opening resets the blink so the caret is solid on the first frame.
    addTestFolder(&t);
    try testing.expect(t.send(keyEvent(c.SDLK_O, c.SDL_KMOD_GUI), 1000));
    try testing.expect(t.comp.search.caretVisible(1000));
    try testing.expect(!t.comp.search.caretVisible(1600));
    try testing.expect(t.comp.search.caretVisible(2100));
}

test "recent folders pill is hidden while the focused shell is busy" {
    try testing.expect(RecentFoldersOverlayComponent.shouldShowPill(1, false));
    try testing.expect(!RecentFoldersOverlayComponent.shouldShowPill(1, true));
    try testing.expect(!RecentFoldersOverlayComponent.shouldShowPill(0, false));
}

test "open recent folders picker does not consume input while the focused shell is busy" {
    var t = TestComponent.init();
    defer t.deinit();

    addTestFolder(&t);
    t.comp.overlay.state = .Open;
    try t.comp.search.buf.appendSlice(testing.allocator, "before");

    try testing.expect(!t.sendWithBusy(textEvent("x"), 0, true));
    try testing.expectEqualStrings("before", t.comp.search.text());

    try testing.expect(!t.sendWithBusy(keyEvent(c.SDLK_BACKSPACE, 0), 0, true));
    try testing.expectEqualStrings("before", t.comp.search.text());
}
