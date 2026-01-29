const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const config = @import("../../config.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;
const flowing_line = @import("flowing_line.zig");

const log = std.log.scoped(.recent_folders_overlay);

pub const RecentFoldersOverlayComponent = struct {
    allocator: std.mem.Allocator,
    overlay: ExpandingOverlay = ExpandingOverlay.init(1, button_margin, button_size_small, button_size_large, button_animation_duration_ms),
    first_frame: FirstFrameGuard = .{},

    folders: std.ArrayList(Folder) = .{},
    selected_index: usize = 0,
    hovered_entry: ?usize = null,
    escape_pressed: bool = false,
    focused_busy: bool = false,
    cache: ?*Cache = null,
    flow_animation_start_ms: i64 = 0,

    const button_size_small: c_int = 40;
    const button_size_large: c_int = 400;
    const button_margin: c_int = 20;
    const button_animation_duration_ms: i64 = 200;
    const max_folders: usize = 10;

    const title = "Recent Folders";

    const Folder = struct {
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
        font_generation: u64,
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
        self.destroyCache();
        self.clearFolders();
        self.folders.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setFolders(self: *RecentFoldersOverlayComponent, recent_folders: []const config.Persistence.RecentFolder) void {
        self.clearFolders();
        self.destroyCache();

        for (recent_folders) |folder| {
            if (self.folders.items.len >= max_folders) break;
            const abs = self.allocator.dupe(u8, folder.path) catch |err| {
                log.warn("failed to dupe folder path: {}", .{err});
                continue;
            };
            const display = makeDisplayPath(self.allocator, folder.path) catch |err| {
                log.warn("failed to make display path: {}", .{err});
                self.allocator.free(abs);
                continue;
            };
            self.folders.append(self.allocator, .{
                .abs_path = abs,
                .display = display,
            }) catch |err| {
                log.warn("failed to append folder: {}", .{err});
                self.allocator.free(abs);
                self.allocator.free(display);
                continue;
            };
        }

        if (self.selected_index >= self.folders.items.len) {
            self.selected_index = if (self.folders.items.len > 0) self.folders.items.len - 1 else 0;
        }
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

        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
                const inside = geom.containsPoint(rect, mouse_x, mouse_y);

                if (inside and self.overlay.state == .Open) {
                    if (self.entryIndexAtPoint(host, mouse_y)) |idx| {
                        if (idx < self.folders.items.len) {
                            self.emitChangeDir(actions, host.focused_session, self.folders.items[idx].abs_path);
                            self.overlay.startCollapsing(host.now_ms);
                        }
                        return true;
                    }
                }

                if (inside) {
                    switch (self.overlay.state) {
                        .Closed => {
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
                    if (self.overlay.state == .Open) {
                        self.overlay.startCollapsing(host.now_ms);
                    } else {
                        self.overlay.startExpanding(host.now_ms);
                    }
                    return true;
                }

                if (self.overlay.state == .Open) {
                    // Arrow navigation
                    if (key == c.SDLK_UP) {
                        if (self.folders.items.len > 0) {
                            if (self.selected_index > 0) {
                                self.selected_index -= 1;
                            } else {
                                self.selected_index = self.folders.items.len - 1;
                            }
                        }
                        return true;
                    }
                    if (key == c.SDLK_DOWN) {
                        if (self.folders.items.len > 0) {
                            if (self.selected_index < self.folders.items.len - 1) {
                                self.selected_index += 1;
                            } else {
                                self.selected_index = 0;
                            }
                        }
                        return true;
                    }

                    // Enter selects current
                    if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
                        if (self.selected_index < self.folders.items.len) {
                            self.emitChangeDir(actions, host.focused_session, self.folders.items[self.selected_index].abs_path);
                            self.overlay.startCollapsing(host.now_ms);
                        }
                        return true;
                    }

                    // Escape closes
                    if (key == c.SDLK_ESCAPE) {
                        self.escape_pressed = true;
                        self.overlay.startCollapsing(host.now_ms);
                        return true;
                    }

                    // Cmd+1-9 for quick selection
                    if (has_gui and !has_blocking_mod) {
                        if (key >= c.SDLK_1 and key <= c.SDLK_9) {
                            const digit_idx: usize = @intCast(key - c.SDLK_1);
                            if (digit_idx < self.folders.items.len) {
                                self.emitChangeDir(actions, host.focused_session, self.folders.items[digit_idx].abs_path);
                                self.overlay.startCollapsing(host.now_ms);
                                return true;
                            }
                        }
                    }
                }
            },
            else => {},
        }

        return false;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        return geom.containsPoint(rect, x, y);
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
                    self.overlay.startCollapsing(host.now_ms);
                }
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

        if (self.focused_busy) {
            self.hovered_entry = null;
            return;
        }
    }

    fn render(self_ptr: *anyopaque, ui_host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *RecentFoldersOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (self.folders.items.len == 0) return;

        const rect = self.overlay.rect(ui_host.now_ms, ui_host.window_w, ui_host.window_h, ui_host.ui_scale);
        const radius: c_int = 8;

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

        switch (self.overlay.state) {
            .Closed, .Collapsing, .Expanding => self.renderGlyph(renderer, rect, ui_host.ui_scale, assets, ui_host.theme),
            .Open => self.renderOverlay(renderer, ui_host, rect, ui_host.ui_scale, assets, ui_host.theme),
        }

        self.first_frame.markDrawn();
    }

    fn renderGlyph(_: *RecentFoldersOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) void {
        const cache = assets.font_cache orelse return;
        const font_size = dpi.scale(@max(12, @min(20, @divFloor(rect.h, 2))), ui_scale);
        const fonts = cache.get(font_size) catch return;

        const glyph = "⌘O";
        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const surface = c.TTF_RenderText_Blended(fonts.regular, glyph.ptr, @intCast(glyph.len), fg_color) orelse return;
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

    fn renderOverlay(self: *RecentFoldersOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) void {
        const cache = self.ensureCache(renderer, ui_scale, assets, theme) orelse return;

        const padding: c_int = dpi.scale(20, ui_scale);
        const line_height: c_int = dpi.scale(28, ui_scale);
        var y_offset: c_int = rect.y + padding;

        // Render title
        const title_tex = cache.title;
        const title_x = rect.x + @divFloor(rect.w - title_tex.w, 2);
        _ = c.SDL_RenderTexture(renderer, title_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(y_offset),
            .w = @floatFromInt(title_tex.w),
            .h = @floatFromInt(title_tex.h),
        });
        y_offset += title_tex.h + line_height;

        // Render entries
        for (cache.entries, 0..) |entry_tex, idx| {
            const is_selected = idx == self.selected_index;
            const is_hovered = if (self.hovered_entry) |h| h == idx else false;

            // Highlight background for selected or hovered
            if (is_selected or is_hovered) {
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
                .x = @floatFromInt(rect.x + padding),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.hotkey.w),
                .h = @floatFromInt(entry_tex.hotkey.h),
            });

            // Render path (right-aligned)
            _ = c.SDL_RenderTexture(renderer, entry_tex.path.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + rect.w - padding - entry_tex.path.w),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.path.w),
                .h = @floatFromInt(entry_tex.path.h),
            });

            // Render flowing line for selected entry
            if (is_selected) {
                const flow_y = y_offset + @divFloor(entry_tex.path.h, 2);
                flowing_line.render(renderer, self.flow_animation_start_ms, host.now_ms, rect, flow_y, ui_scale, theme);
            }

            y_offset += line_height;
        }
    }

    fn emitChangeDir(_: *RecentFoldersOverlayComponent, actions: *types.UiActionQueue, session_idx: usize, abs_path: []const u8) void {
        const path_copy = actions.allocator.dupe(u8, abs_path) catch return;
        actions.append(.{ .ChangeDirectory = .{ .session = session_idx, .path = path_copy } }) catch {
            actions.allocator.free(path_copy);
        };
    }

    fn clearFolders(self: *RecentFoldersOverlayComponent) void {
        for (self.folders.items) |folder| {
            self.allocator.free(folder.abs_path);
            self.allocator.free(folder.display);
        }
        self.folders.clearRetainingCapacity();
        self.hovered_entry = null;
    }

    fn entryIndexAtPoint(self: *RecentFoldersOverlayComponent, host: *const types.UiHost, y: c_int) ?usize {
        if (self.cache == null) return null;
        const cache = self.cache.?;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const padding: c_int = dpi.scale(20, host.ui_scale);
        const line_height: c_int = dpi.scale(28, host.ui_scale);
        const start_y = rect.y + padding + cache.title.h + line_height;
        if (y < start_y) return null;
        const rel = y - start_y;
        const idx = @as(usize, @intCast(@divFloor(rel, line_height)));
        if (idx >= self.folders.items.len) return null;
        return idx;
    }

    fn ensureCache(self: *RecentFoldersOverlayComponent, renderer: *c.SDL_Renderer, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) ?*Cache {
        const cache_store = assets.font_cache orelse return null;
        const title_font_size: c_int = dpi.scale(20, ui_scale);
        const entry_font_size: c_int = dpi.scale(16, ui_scale);
        const fg = theme.foreground;
        const entry_count = self.folders.items.len;

        if (self.cache) |cache| {
            if (cache.title_font_size == title_font_size and
                cache.entry_font_size == entry_font_size and
                cache.theme_fg.r == fg.r and cache.theme_fg.g == fg.g and cache.theme_fg.b == fg.b and
                cache.ui_scale == ui_scale and
                cache.entries.len == entry_count and
                cache.font_generation == cache_store.generation)
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
        const title_tex = makeTextTexture(renderer, title_fonts.regular, title, title_color) catch {
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
            var key_buf: [8]u8 = undefined;
            const digit: u8 = @as(u8, @intCast((idx + 1) % 10));
            const key_slice = std.fmt.bufPrint(&key_buf, "⌘{d}", .{digit}) catch |err| blk: {
                log.warn("failed to format hotkey: {}", .{err});
                break :blk key_buf[0..0];
            };
            const key_tex = makeTextTexture(renderer, entry_fonts.regular, key_slice, key_color) catch {
                destroyEntryTextures(entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                self.allocator.destroy(cache);
                return null;
            };

            const path_slice = self.folders.items[idx].display;
            const max_path_width = overlay_width - (2 * padding) - key_tex.w - hotkey_spacing;

            var path_buf: [256]u8 = undefined;
            const truncated_path = truncateTextLeft(path_slice, entry_fonts.regular, max_path_width, &path_buf) catch |err| blk: {
                log.warn("failed to truncate path: {}", .{err});
                break :blk path_slice;
            };
            const path_tex = makeTextTexture(renderer, entry_fonts.regular, truncated_path, entry_color) catch {
                c.SDL_DestroyTexture(key_tex.tex);
                destroyEntryTextures(entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
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
            .font_generation = cache_store.generation,
        };

        self.cache = cache;

        const line_height: c_int = 28;
        const content_height = (2 * 20) + title_tex.h + line_height + @as(c_int, @intCast(entry_count)) * line_height;
        self.overlay.setContentHeight(content_height);

        return cache;
    }

    fn destroyCache(self: *RecentFoldersOverlayComponent) void {
        if (self.cache) |cache| {
            c.SDL_DestroyTexture(cache.title.tex);
            destroyEntryTextures(cache.entries);
            self.allocator.free(cache.entries);
            self.allocator.destroy(cache);
            self.cache = null;
        }
    }

    fn makeDisplayPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const home = std.posix.getenv("HOME");
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
