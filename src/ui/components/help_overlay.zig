const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const easing = @import("../../anim/easing.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;

pub const HelpOverlayComponent = struct {
    allocator: std.mem.Allocator,
    state: State = .Closed,
    start_time: i64 = 0,
    start_size: c_int = HELP_BUTTON_SIZE_SMALL,
    target_size: c_int = HELP_BUTTON_SIZE_SMALL,

    const FONT_PATH: [*:0]const u8 = "/System/Library/Fonts/SFNSMono.ttf";
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

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
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
            .Closed, .Collapsing, .Expanding => self.renderQuestionMark(renderer, rect, host.ui_scale),
            .Open => self.renderHelpOverlay(renderer, rect, host.ui_scale),
        }
    }

    fn renderQuestionMark(_: *HelpOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32) void {
        const font_size = scale(ui_scale, @max(16, @min(32, @divFloor(rect.h * 3, 4))));
        const question_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(font_size)) orelse return;
        defer c.TTF_CloseFont(question_font);

        const question_mark: [2]u8 = .{ '?', 0 };
        const fg_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
        const surface = c.TTF_RenderText_Blended(question_font, &question_mark, 1, fg_color) orelse return;
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

    fn renderHelpOverlay(self: *HelpOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32) void {
        _ = self;
        const title_font_size: c_int = scale(ui_scale, 20);
        const key_font_size: c_int = scale(ui_scale, 16);
        const padding: c_int = scale(ui_scale, 20);
        const line_height: c_int = scale(ui_scale, 28);
        var y_offset: c_int = rect.y + padding;

        const title_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(title_font_size)) orelse return;
        defer c.TTF_CloseFont(title_font);

        const key_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(key_font_size)) orelse return;
        defer c.TTF_CloseFont(key_font);

        const title_text = "Keyboard Shortcuts";
        const title_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
        const title_surface = c.TTF_RenderText_Blended(title_font, title_text, title_text.len, title_color) orelse return;
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
            .{ .key = "Mouse wheel", .desc = "Scroll history" },
        };

        const key_color = c.SDL_Color{ .r = 120, .g = 170, .b = 255, .a = 255 };
        const desc_color = c.SDL_Color{ .r = 180, .g = 180, .b = 180, .a = 255 };

        for (shortcuts) |shortcut| {
            const key_surface = c.TTF_RenderText_Blended(key_font, @ptrCast(shortcut.key.ptr), shortcut.key.len, key_color) orelse continue;
            defer c.SDL_DestroySurface(key_surface);
            const desc_surface = c.TTF_RenderText_Blended(key_font, @ptrCast(shortcut.desc.ptr), shortcut.desc.len, desc_color) orelse continue;
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
        const margin = scaled(HELP_BUTTON_MARGIN, ui_scale);
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
        return scaled(unscaled, ui_scale);
    }

    fn scaled(value: c_int, ui_scale: f32) c_int {
        return @max(1, @as(c_int, @intFromFloat(std.math.round(@as(f32, @floatFromInt(value)) * ui_scale))));
    }

    fn scale(ui_scale: f32, value: c_int) c_int {
        return scaled(value, ui_scale);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *HelpOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.deinit(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};
