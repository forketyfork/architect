const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;

const Shortcut = struct { key: []const u8, desc: []const u8 };
const shortcuts = [_]Shortcut{
    .{ .key = "Click terminal", .desc = "Expand to full screen" },
    .{ .key = "ESC (hold)", .desc = "Collapse to grid view" },
    .{ .key = "⌘↑/↓/←/→", .desc = "Navigate grid" },
    .{ .key = "⌘1–⌘9/⌘0", .desc = "Jump to a grid slot" },
    .{ .key = "⌘↵", .desc = "Expand focused terminal" },
    .{ .key = "⌘T", .desc = "Open worktree picker" },
    .{ .key = "⌘O", .desc = "Open recent folders" },
    .{ .key = "⌘?", .desc = "Open help" },
    .{ .key = "⌘N", .desc = "Spawn new terminal" },
    .{ .key = "⌘⇧+ / ⌘⇧-", .desc = "Adjust font size" },
    .{ .key = "⌘K", .desc = "Clear terminal" },
    .{ .key = "⌘W", .desc = "Delete terminal" },
    .{ .key = "⌘,", .desc = "Open config file" },
    .{ .key = "Drag (full view)", .desc = "Select text" },
    .{ .key = "⌘C", .desc = "Copy selection to clipboard" },
    .{ .key = "⌘V", .desc = "Paste clipboard into terminal" },
    .{ .key = "Mouse wheel", .desc = "Scroll history" },
};

const TextTex = struct {
    tex: *c.SDL_Texture,
    w: c_int,
    h: c_int,
};

const ShortcutTex = struct {
    key: TextTex,
    desc: TextTex,
};

const Cache = struct {
    title_font_size: c_int,
    key_font_size: c_int,
    title: TextTex,
    shortcuts: [shortcuts.len]ShortcutTex,
    theme_fg: c.SDL_Color,
    font_generation: u64,
};

pub const HelpOverlayComponent = struct {
    allocator: std.mem.Allocator,
    overlay: ExpandingOverlay = ExpandingOverlay.init(0, help_button_margin, help_button_size_small, help_button_size_large, help_button_animation_duration_ms),
    cache: ?*Cache = null,
    first_frame: FirstFrameGuard = .{},
    const help_button_size_small: c_int = 40;
    const help_button_size_large: c_int = 440;
    const help_button_margin: c_int = 20;
    const help_button_animation_duration_ms: i64 = 200;

    pub fn create(allocator: std.mem.Allocator) !UiComponent {
        const comp = try allocator.create(HelpOverlayComponent);
        comp.* = .{ .allocator = allocator };

        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 1000,
        };
    }

    fn deinit(self: *HelpOverlayComponent, _: *c.SDL_Renderer) void {
        self.destroyCache();
        self.allocator.destroy(self);
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));

        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
                const inside = geom.containsPoint(rect, mouse_x, mouse_y);

                if (inside) {
                    switch (self.overlay.state) {
                        .Closed => self.overlay.startExpanding(host.now_ms),
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
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL)) != 0;
                if (has_gui and !has_blocking_mod and key == c.SDLK_SLASH) {
                    if (self.overlay.state == .Open) {
                        self.overlay.startCollapsing(host.now_ms);
                    } else {
                        self.overlay.startExpanding(host.now_ms);
                    }
                    return true;
                }
            },
            else => {},
        }

        return false;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        return geom.containsPoint(rect, x, y);
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (self.overlay.isAnimating() and self.overlay.isComplete(host.now_ms)) {
            self.overlay.state = switch (self.overlay.state) {
                .Expanding => .Open,
                .Collapsing => .Closed,
                else => self.overlay.state,
            };
            if (self.overlay.state == .Open) self.first_frame.markTransition();
        }
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const radius: c_int = 8;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const sel = host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 245);
        const bg_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        const accent = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 255);
        primitives.drawRoundedBorder(renderer, rect, radius);

        // Pre-warm cached text while the button is expanding so the content is
        // ready once the panel fully opens.
        if (self.overlay.state != .Closed) {
            _ = self.ensureCache(renderer, host.ui_scale, assets, host.theme);
        }

        switch (self.overlay.state) {
            .Closed, .Collapsing, .Expanding => self.renderQuestionMark(renderer, rect, host.ui_scale, assets, host.theme),
            .Open => self.renderHelpOverlay(renderer, rect, host.ui_scale, assets, host.theme),
        }
    }

    fn renderQuestionMark(_: *HelpOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) void {
        const cache = assets.font_cache orelse return;
        const font_size = dpi.scale(@max(12, @min(20, @divFloor(rect.h, 2))), ui_scale);
        const fonts = cache.get(font_size) catch return;

        const question_mark = "⌘?";
        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const surface = c.TTF_RenderText_Blended(fonts.regular, question_mark.ptr, @intCast(question_mark.len), fg_color) orelse return;
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

    fn renderHelpOverlay(self: *HelpOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) void {
        const cache = self.ensureCache(renderer, ui_scale, assets, theme) orelse return;
        const padding: c_int = dpi.scale(20, ui_scale);
        const line_height: c_int = dpi.scale(28, ui_scale);
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

        for (cache.shortcuts) |shortcut_tex| {
            _ = c.SDL_RenderTexture(renderer, shortcut_tex.key.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + padding),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(shortcut_tex.key.w),
                .h = @floatFromInt(shortcut_tex.key.h),
            });

            _ = c.SDL_RenderTexture(renderer, shortcut_tex.desc.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + rect.w - padding - shortcut_tex.desc.w),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(shortcut_tex.desc.w),
                .h = @floatFromInt(shortcut_tex.desc.h),
            });

            y_offset += line_height;
        }
        self.first_frame.markDrawn();
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

    fn destroyCache(self: *HelpOverlayComponent) void {
        if (self.cache) |cache| {
            c.SDL_DestroyTexture(cache.title.tex);
            for (cache.shortcuts) |shortcut_tex| {
                c.SDL_DestroyTexture(shortcut_tex.key.tex);
                c.SDL_DestroyTexture(shortcut_tex.desc.tex);
            }
            self.allocator.destroy(cache);
            self.cache = null;
        }
    }

    fn ensureCache(self: *HelpOverlayComponent, renderer: *c.SDL_Renderer, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) ?*Cache {
        const cache_store = assets.font_cache orelse return null;
        const title_font_size: c_int = dpi.scale(20, ui_scale);
        const key_font_size: c_int = dpi.scale(16, ui_scale);
        const fg = theme.foreground;

        if (self.cache) |cache| {
            if (cache.title_font_size == title_font_size and
                cache.key_font_size == key_font_size and
                cache.theme_fg.r == fg.r and cache.theme_fg.g == fg.g and cache.theme_fg.b == fg.b and
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

        const key_fonts = cache_store.get(key_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const title_text = "Keyboard Shortcuts";
        const title_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const title_tex = makeTextTexture(renderer, title_fonts.regular, title_text, title_color) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const key_color = c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 255 };
        const desc_color = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };

        var shortcut_tex: [shortcuts.len]ShortcutTex = undefined;
        for (shortcuts, 0..) |shortcut, idx| {
            const key_tex = makeTextTexture(renderer, key_fonts.regular, shortcut.key, key_color) catch {
                for (shortcut_tex[0..idx]) |st| {
                    c.SDL_DestroyTexture(st.key.tex);
                    c.SDL_DestroyTexture(st.desc.tex);
                }
                c.SDL_DestroyTexture(title_tex.tex);
                self.allocator.destroy(cache);
                return null;
            };
            const desc_tex = makeTextTexture(renderer, key_fonts.regular, shortcut.desc, desc_color) catch {
                c.SDL_DestroyTexture(key_tex.tex);
                for (shortcut_tex[0..idx]) |st| {
                    c.SDL_DestroyTexture(st.key.tex);
                    c.SDL_DestroyTexture(st.desc.tex);
                }
                c.SDL_DestroyTexture(title_tex.tex);
                self.allocator.destroy(cache);
                return null;
            };
            shortcut_tex[idx] = .{ .key = key_tex, .desc = desc_tex };
        }

        cache.* = .{
            .title_font_size = title_font_size,
            .key_font_size = key_font_size,
            .title = title_tex,
            .shortcuts = shortcut_tex,
            .theme_fg = fg,
            .font_generation = cache_store.generation,
        };

        self.cache = cache;

        const line_height: c_int = 28;
        const content_height = (2 * 20) + title_tex.h + line_height + @as(c_int, @intCast(shortcuts.len)) * line_height;
        self.overlay.setContentHeight(content_height);

        return cache;
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.deinit(renderer);
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.isAnimating() or self.first_frame.wantsFrame();
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
