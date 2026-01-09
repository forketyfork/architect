const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const easing = @import("../../anim/easing.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const font_mod = @import("../../font.zig");

const FontWithFallbacks = struct {
    main: *c.TTF_Font,
    symbol: ?*c.TTF_Font,
    emoji: ?*c.TTF_Font,
};

const Shortcut = struct { key: []const u8, desc: []const u8 };
const shortcuts = [_]Shortcut{
    .{ .key = "Click terminal", .desc = "Expand to full screen" },
    .{ .key = "ESC (hold)", .desc = "Collapse to grid view" },
    .{ .key = "⌘↑/↓/←/→", .desc = "Navigate grid" },
    .{ .key = "⌘⇧+ / ⌘⇧-", .desc = "Adjust font size" },
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
    ui_scale: f32,
    title_font_size: c_int,
    key_font_size: c_int,
    title_fonts: FontWithFallbacks,
    key_fonts: FontWithFallbacks,
    title: TextTex,
    shortcuts: [shortcuts.len]ShortcutTex,
};

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

pub const HelpOverlayComponent = struct {
    allocator: std.mem.Allocator,
    state: State = .Closed,
    start_time: i64 = 0,
    start_size: c_int = HELP_BUTTON_SIZE_SMALL,
    target_size: c_int = HELP_BUTTON_SIZE_SMALL,
    cache: ?*Cache = null,

    const HELP_BUTTON_SIZE_SMALL: c_int = 40;
    const HELP_BUTTON_SIZE_LARGE: c_int = 400;
    const HELP_BUTTON_MARGIN: c_int = 20;
    const HELP_BUTTON_ANIMATION_DURATION_MS: i64 = 200;

    pub const State = enum { Closed, Expanding, Open, Collapsing };

    pub fn create(allocator: std.mem.Allocator) !UiComponent {
        const comp = try allocator.create(HelpOverlayComponent);
        comp.* = .{ .allocator = allocator };

        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 1000,
        };
    }

    fn deinit(self: *HelpOverlayComponent, renderer: *c.SDL_Renderer) void {
        self.destroyCache(renderer);
        self.allocator.destroy(self);
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (event.type != c.SDL_EVENT_MOUSE_BUTTON_DOWN) return false;

        const mouse_x: c_int = @intFromFloat(event.button.x);
        const mouse_y: c_int = @intFromFloat(event.button.y);
        const rect = self.getRect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const inside = geom.containsPoint(rect, mouse_x, mouse_y);

        if (inside) {
            switch (self.state) {
                .Closed => self.startExpanding(host.now_ms),
                .Open => self.startCollapsing(host.now_ms),
                else => {},
            }
            return true;
        }

        if (self.state == .Open and !inside) {
            self.startCollapsing(host.now_ms);
            return true;
        }

        return false;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        const rect = self.getRect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        return geom.containsPoint(rect, x, y);
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (self.isAnimating() and self.isComplete(host.now_ms)) {
            self.state = switch (self.state) {
                .Expanding => .Open,
                .Collapsing => .Closed,
                else => self.state,
            };
        }
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        const rect = self.getRect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const radius: c_int = 8;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 27, 34, 48, 220);
        const bg_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        _ = c.SDL_SetRenderDrawColor(renderer, 97, 175, 239, 255);
        primitives.drawRoundedBorder(renderer, rect, radius);

        // Pre-warm cached text while the button is expanding so the content is
        // ready once the panel fully opens.
        if (self.state != .Closed) {
            _ = self.ensureCache(renderer, host.ui_scale, assets);
        }

        switch (self.state) {
            .Closed, .Collapsing, .Expanding => self.renderQuestionMark(renderer, rect, host.ui_scale, assets),
            .Open => self.renderHelpOverlay(renderer, rect, host.ui_scale, assets),
        }
    }

    fn renderQuestionMark(_: *HelpOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets) void {
        const font_path = assets.font_path orelse return;
        const font_size = dpi.scale(@max(16, @min(32, @divFloor(rect.h * 3, 4))), ui_scale);
        const fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, font_size) catch return;
        defer closeFontWithFallbacks(fonts);

        const question_mark: [2]u8 = .{ '?', 0 };
        const fg_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };
        const surface = c.TTF_RenderText_Blended(fonts.main, &question_mark, 1, fg_color) orelse return;
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

    fn renderHelpOverlay(self: *HelpOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets) void {
        const cache = self.ensureCache(renderer, ui_scale, assets) orelse return;
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

    fn destroyCache(self: *HelpOverlayComponent, renderer: *c.SDL_Renderer) void {
        if (self.cache) |cache| {
            c.SDL_DestroyTexture(cache.title.tex);
            for (cache.shortcuts) |shortcut_tex| {
                c.SDL_DestroyTexture(shortcut_tex.key.tex);
                c.SDL_DestroyTexture(shortcut_tex.desc.tex);
            }
            closeFontWithFallbacks(cache.title_fonts);
            closeFontWithFallbacks(cache.key_fonts);
            self.allocator.destroy(cache);
            self.cache = null;
        }
        _ = renderer;
    }

    fn ensureCache(self: *HelpOverlayComponent, renderer: *c.SDL_Renderer, ui_scale: f32, assets: *types.UiAssets) ?*Cache {
        const font_path = assets.font_path orelse return null;
        const title_font_size: c_int = dpi.scale(20, ui_scale);
        const key_font_size: c_int = dpi.scale(16, ui_scale);

        if (self.cache) |cache| {
            if (cache.title_font_size == title_font_size and cache.key_font_size == key_font_size) {
                return cache;
            }
            self.destroyCache(renderer);
        }

        const cache = self.allocator.create(Cache) catch return null;
        errdefer self.allocator.destroy(cache);

        const title_fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, title_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };
        errdefer closeFontWithFallbacks(title_fonts);

        const key_fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, key_font_size) catch {
            closeFontWithFallbacks(title_fonts);
            self.allocator.destroy(cache);
            return null;
        };
        errdefer closeFontWithFallbacks(key_fonts);

        const title_text = "Keyboard Shortcuts";
        const title_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };
        const title_tex = makeTextTexture(renderer, title_fonts.main, title_text, title_color) catch {
            closeFontWithFallbacks(key_fonts);
            closeFontWithFallbacks(title_fonts);
            self.allocator.destroy(cache);
            return null;
        };

        const key_color = c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 255 };
        const desc_color = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };

        var shortcut_tex: [shortcuts.len]ShortcutTex = undefined;
        for (shortcuts, 0..) |shortcut, idx| {
            const key_tex = makeTextTexture(renderer, key_fonts.main, shortcut.key, key_color) catch {
                for (shortcut_tex[0..idx]) |st| {
                    c.SDL_DestroyTexture(st.key.tex);
                    c.SDL_DestroyTexture(st.desc.tex);
                }
                c.SDL_DestroyTexture(title_tex.tex);
                closeFontWithFallbacks(key_fonts);
                closeFontWithFallbacks(title_fonts);
                self.allocator.destroy(cache);
                return null;
            };
            const desc_tex = makeTextTexture(renderer, key_fonts.main, shortcut.desc, desc_color) catch {
                c.SDL_DestroyTexture(key_tex.tex);
                for (shortcut_tex[0..idx]) |st| {
                    c.SDL_DestroyTexture(st.key.tex);
                    c.SDL_DestroyTexture(st.desc.tex);
                }
                c.SDL_DestroyTexture(title_tex.tex);
                closeFontWithFallbacks(key_fonts);
                closeFontWithFallbacks(title_fonts);
                self.allocator.destroy(cache);
                return null;
            };
            shortcut_tex[idx] = .{ .key = key_tex, .desc = desc_tex };
        }

        cache.* = .{
            .ui_scale = ui_scale,
            .title_font_size = title_font_size,
            .key_font_size = key_font_size,
            .title_fonts = title_fonts,
            .key_fonts = key_fonts,
            .title = title_tex,
            .shortcuts = shortcut_tex,
        };

        self.cache = cache;
        return cache;
    }

    fn startExpanding(self: *HelpOverlayComponent, now: i64) void {
        self.state = .Expanding;
        self.start_time = now;
        self.start_size = HELP_BUTTON_SIZE_SMALL;
        self.target_size = HELP_BUTTON_SIZE_LARGE;
    }

    fn startCollapsing(self: *HelpOverlayComponent, now: i64) void {
        self.state = .Collapsing;
        self.start_time = now;
        self.start_size = HELP_BUTTON_SIZE_LARGE;
        self.target_size = HELP_BUTTON_SIZE_SMALL;
    }

    fn isAnimating(self: *HelpOverlayComponent) bool {
        return self.state == .Expanding or self.state == .Collapsing;
    }

    fn isComplete(self: *HelpOverlayComponent, now: i64) bool {
        const elapsed = now - self.start_time;
        return elapsed >= HELP_BUTTON_ANIMATION_DURATION_MS;
    }

    fn getRect(self: *HelpOverlayComponent, now: i64, window_width: c_int, window_height: c_int, ui_scale: f32) geom.Rect {
        _ = window_height;
        const margin = dpi.scale(HELP_BUTTON_MARGIN, ui_scale);
        const size = self.getCurrentSize(now, ui_scale);
        const x = window_width - margin - size;
        const y = margin;
        return geom.Rect{ .x = x, .y = y, .w = size, .h = size };
    }

    fn getCurrentSize(self: *HelpOverlayComponent, now: i64, ui_scale: f32) c_int {
        const elapsed = now - self.start_time;
        const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, HELP_BUTTON_ANIMATION_DURATION_MS));
        const eased = easing.easeInOutCubic(progress);
        const size_diff = self.target_size - self.start_size;
        const unscaled = self.start_size + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(size_diff)) * eased));
        return dpi.scale(unscaled, ui_scale);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.deinit(renderer);
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.isAnimating();
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
