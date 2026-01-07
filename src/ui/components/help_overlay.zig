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

    fn deinit(self: *HelpOverlayComponent, _: *c.SDL_Renderer) void {
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
        _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 50, 220);
        const bg_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, 255);
        primitives.drawRoundedBorder(renderer, rect, radius);

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
        const fg_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
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
        _ = self;
        const font_path = assets.font_path orelse return;
        const title_font_size: c_int = dpi.scale(20, ui_scale);
        const key_font_size: c_int = dpi.scale(16, ui_scale);
        const padding: c_int = dpi.scale(20, ui_scale);
        const line_height: c_int = dpi.scale(28, ui_scale);
        var y_offset: c_int = rect.y + padding;

        const title_fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, title_font_size) catch return;
        defer closeFontWithFallbacks(title_fonts);

        const key_fonts = openFontWithFallbacks(font_path, assets.symbol_fallback_path, assets.emoji_fallback_path, key_font_size) catch return;
        defer closeFontWithFallbacks(key_fonts);

        const title_text = "Keyboard Shortcuts";
        const title_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
        const title_surface = c.TTF_RenderText_Blended(title_fonts.main, title_text, title_text.len, title_color) orelse return;
        defer c.SDL_DestroySurface(title_surface);

        const title_texture = c.SDL_CreateTextureFromSurface(renderer, title_surface) orelse return;
        defer c.SDL_DestroyTexture(title_texture);

        var title_width_f: f32 = 0;
        var title_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(title_texture, &title_width_f, &title_height_f);

        const title_x = rect.x + @divFloor(rect.w - @as(c_int, @intFromFloat(title_width_f)), 2);
        _ = c.SDL_RenderTexture(renderer, title_texture, null, &c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(y_offset),
            .w = title_width_f,
            .h = title_height_f,
        });

        y_offset += @as(c_int, @intFromFloat(title_height_f)) + line_height;

        const shortcuts = [_]struct { key: []const u8, desc: []const u8 }{
            .{ .key = "Click terminal", .desc = "Expand to full screen" },
            .{ .key = "ESC (hold)", .desc = "Collapse to grid view" },
            .{ .key = "⌘⇧[ / ⌘⇧]", .desc = "Switch terminals" },
            .{ .key = "⌘↑/↓/←/→", .desc = "Navigate grid" },
            .{ .key = "⌘⇧+ / ⌘⇧-", .desc = "Adjust font size" },
            .{ .key = "Drag (full view)", .desc = "Select text" },
            .{ .key = "⌘C", .desc = "Copy selection to clipboard" },
            .{ .key = "⌘V", .desc = "Paste clipboard into terminal" },
            .{ .key = "Mouse wheel", .desc = "Scroll history" },
        };

        const key_color = c.SDL_Color{ .r = 120, .g = 170, .b = 255, .a = 255 };
        const desc_color = c.SDL_Color{ .r = 180, .g = 180, .b = 180, .a = 255 };

        for (shortcuts) |shortcut| {
            const key_surface = c.TTF_RenderText_Blended(key_fonts.main, @ptrCast(shortcut.key.ptr), shortcut.key.len, key_color) orelse continue;
            defer c.SDL_DestroySurface(key_surface);
            const desc_surface = c.TTF_RenderText_Blended(key_fonts.main, @ptrCast(shortcut.desc.ptr), shortcut.desc.len, desc_color) orelse continue;
            defer c.SDL_DestroySurface(desc_surface);

            const key_texture = c.SDL_CreateTextureFromSurface(renderer, key_surface) orelse continue;
            defer c.SDL_DestroyTexture(key_texture);
            const desc_texture = c.SDL_CreateTextureFromSurface(renderer, desc_surface) orelse continue;
            defer c.SDL_DestroyTexture(desc_texture);

            var key_w: f32 = 0;
            var key_h: f32 = 0;
            _ = c.SDL_GetTextureSize(key_texture, &key_w, &key_h);
            var desc_w: f32 = 0;
            var desc_h: f32 = 0;
            _ = c.SDL_GetTextureSize(desc_texture, &desc_w, &desc_h);

            _ = c.SDL_RenderTexture(renderer, key_texture, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + padding),
                .y = @floatFromInt(y_offset),
                .w = key_w,
                .h = key_h,
            });

            _ = c.SDL_RenderTexture(renderer, desc_texture, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + rect.w - padding - @as(c_int, @intFromFloat(desc_w))),
                .y = @floatFromInt(y_offset),
                .w = desc_w,
                .h = desc_h,
            });

            y_offset += line_height;
        }
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

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};
