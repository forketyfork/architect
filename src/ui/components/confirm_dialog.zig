const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../../dpi.zig");
const font_cache = @import("../../font_cache.zig");

const log = std.log.scoped(.confirm_dialog);

pub const ConfirmDialogComponent = struct {
    allocator: std.mem.Allocator,
    font_generation: u64 = 0,
    title_font_size: c_int = 0,
    body_font_size: c_int = 0,
    visible: bool = false,
    dirty: bool = true,
    escape_pressed: bool = false,

    title_text: []const u8 = "",
    message_text: []const u8 = "",
    confirm_text: []const u8 = "OK",
    cancel_text: []const u8 = "Cancel",

    on_confirm: ?types.UiAction = null,

    title_tex: ?*c.SDL_Texture = null,
    title_w: c_int = 0,
    title_h: c_int = 0,

    message_tex: ?*c.SDL_Texture = null,
    message_w: c_int = 0,
    message_h: c_int = 0,

    confirm_tex: ?*c.SDL_Texture = null,
    confirm_w: c_int = 0,
    confirm_h: c_int = 0,

    cancel_tex: ?*c.SDL_Texture = null,
    cancel_w: c_int = 0,
    cancel_h: c_int = 0,

    const modal_width: c_int = 520;
    const modal_height: c_int = 220;
    const modal_radius: c_int = 12;
    const padding: c_int = 24;
    const title_size: c_int = 22;
    const body_size: c_int = 16;
    const button_width: c_int = 136;
    const button_height: c_int = 40;
    const button_gap: c_int = 12;

    pub fn init(allocator: std.mem.Allocator) !*ConfirmDialogComponent {
        const self = try allocator.create(ConfirmDialogComponent);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn asComponent(self: *ConfirmDialogComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 2000,
        };
    }

    pub fn destroy(self: *ConfirmDialogComponent, renderer: *c.SDL_Renderer) void {
        if (self.title_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.message_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.confirm_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.cancel_tex) |tex| c.SDL_DestroyTexture(tex);
        self.allocator.destroy(self);
        _ = renderer;
    }

    pub fn show(
        self: *ConfirmDialogComponent,
        title: []const u8,
        message: []const u8,
        confirm_label: []const u8,
        cancel_label: []const u8,
        on_confirm: types.UiAction,
    ) void {
        self.visible = true;
        self.escape_pressed = false;
        self.title_text = title;
        self.message_text = message;
        self.confirm_text = confirm_label;
        self.cancel_text = cancel_label;
        self.on_confirm = on_confirm;
        self.dirty = true;
    }

    pub fn hide(self: *ConfirmDialogComponent) void {
        self.visible = false;
    }

    pub fn isVisible(self: *ConfirmDialogComponent) bool {
        return self.visible;
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *ConfirmDialogComponent = @ptrCast(@alignCast(self_ptr));

        if (event.type == c.SDL_EVENT_KEY_UP and self.escape_pressed) {
            const key = event.key.key;
            if (key == c.SDLK_ESCAPE) {
                self.escape_pressed = false;
                return true;
            }
        }

        if (!self.visible) return false;

        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                return true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const is_confirm = key == c.SDLK_RETURN or key == c.SDLK_RETURN2 or key == c.SDLK_KP_ENTER;
                if (is_confirm) {
                    if (self.on_confirm) |action| {
                        actions.append(action) catch |err| {
                            log.warn("failed to queue dialog confirmation: {}", .{err});
                        };
                    }
                    self.visible = false;
                    self.escape_pressed = false;
                    return true;
                }
                if (key == c.SDLK_ESCAPE or (key == c.SDLK_W and (mod & c.SDL_KMOD_GUI) != 0)) {
                    if (key == c.SDLK_ESCAPE) {
                        self.escape_pressed = true;
                    }
                    self.visible = false;
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const modal = self.modalRect(host);
                const buttons = self.buttonRects(modal, host.ui_scale);
                if (geom.containsPoint(buttons.confirm, mouse_x, mouse_y)) {
                    if (self.on_confirm) |action| {
                        actions.append(action) catch |err| {
                            log.warn("failed to queue dialog confirmation: {}", .{err});
                        };
                    }
                    self.visible = false;
                    return true;
                }
                if (geom.containsPoint(buttons.cancel, mouse_x, mouse_y)) {
                    self.visible = false;
                    return true;
                }
                if (geom.containsPoint(modal, mouse_x, mouse_y)) return true;
            },
            else => {},
        }

        return true;
    }

    fn hitTest(self_ptr: *anyopaque, _: *const types.UiHost, _: c_int, _: c_int) bool {
        const self: *ConfirmDialogComponent = @ptrCast(@alignCast(self_ptr));
        return self.visible;
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *ConfirmDialogComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;
        const cache = assets.font_cache orelse return;
        const title_font_size = dpi.scale(title_size, host.ui_scale);
        const body_font_size = dpi.scale(body_size, host.ui_scale);
        if (self.title_font_size != title_font_size or self.body_font_size != body_font_size or self.font_generation != cache.generation) {
            self.title_font_size = title_font_size;
            self.body_font_size = body_font_size;
            self.font_generation = cache.generation;
            self.dirty = true;
        }

        self.ensureTextures(renderer, host.theme, cache) catch return;
        const title_tex = self.title_tex orelse return;
        const message_tex = self.message_tex orelse return;
        const cancel_tex = self.cancel_tex orelse return;
        const confirm_tex = self.confirm_tex orelse return;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 170);
        const overlay = c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.window_w),
            .h = @floatFromInt(host.window_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &overlay);

        const modal = self.modalRect(host);
        const sel = host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 240);
        const modal_rect = c.SDL_FRect{
            .x = @floatFromInt(modal.x),
            .y = @floatFromInt(modal.y),
            .w = @floatFromInt(modal.w),
            .h = @floatFromInt(modal.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &modal_rect);
        const acc = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 255);
        primitives.drawRoundedBorder(renderer, modal, dpi.scale(modal_radius, host.ui_scale));

        self.renderText(renderer, modal, host.ui_scale, title_tex, message_tex);
        self.renderButtons(renderer, modal, host.ui_scale, host.theme, cancel_tex, confirm_tex);
    }

    fn renderText(self: *ConfirmDialogComponent, renderer: *c.SDL_Renderer, modal: geom.Rect, ui_scale: f32, title_tex: *c.SDL_Texture, message_tex: *c.SDL_Texture) void {
        const scaled_padding = dpi.scale(padding, ui_scale);
        const title_x = modal.x + scaled_padding;
        const title_y = modal.y + scaled_padding;
        const title_rect = c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(title_y),
            .w = @floatFromInt(self.title_w),
            .h = @floatFromInt(self.title_h),
        };
        _ = c.SDL_RenderTexture(renderer, title_tex, null, &title_rect);

        const message_y = title_y + self.title_h + dpi.scale(12, ui_scale);
        const message_rect = c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(message_y),
            .w = @floatFromInt(self.message_w),
            .h = @floatFromInt(self.message_h),
        };
        _ = c.SDL_RenderTexture(renderer, message_tex, null, &message_rect);
    }

    fn renderButtons(self: *ConfirmDialogComponent, renderer: *c.SDL_Renderer, modal: geom.Rect, ui_scale: f32, theme: *const colors.Theme, cancel_tex: *c.SDL_Texture, confirm_tex: *c.SDL_Texture) void {
        const buttons = self.buttonRects(modal, ui_scale);

        const cancel_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.cancel.x),
            .y = @floatFromInt(buttons.cancel.y),
            .w = @floatFromInt(buttons.cancel.w),
            .h = @floatFromInt(buttons.cancel.h),
        };
        const bg = theme.background;
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 255);
        _ = c.SDL_RenderFillRect(renderer, &cancel_rect);
        const acc = theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 255);
        primitives.drawRoundedBorder(renderer, buttons.cancel, dpi.scale(8, ui_scale));

        const confirm_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.confirm.x),
            .y = @floatFromInt(buttons.confirm.y),
            .w = @floatFromInt(buttons.confirm.w),
            .h = @floatFromInt(buttons.confirm.h),
        };
        const red = theme.palette[1];
        _ = c.SDL_SetRenderDrawColor(renderer, red.r, red.g, red.b, 255);
        _ = c.SDL_RenderFillRect(renderer, &confirm_rect);
        const bright_red = theme.palette[9];
        _ = c.SDL_SetRenderDrawColor(renderer, bright_red.r, bright_red.g, bright_red.b, 255);
        primitives.drawRoundedBorder(renderer, buttons.confirm, dpi.scale(8, ui_scale));

        const cancel_w = @as(f32, @floatFromInt(self.cancel_w));
        const cancel_h = @as(f32, @floatFromInt(self.cancel_h));
        const cancel_text_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.cancel.x + @divFloor(buttons.cancel.w - self.cancel_w, 2)),
            .y = @floatFromInt(buttons.cancel.y + @divFloor(buttons.cancel.h - self.cancel_h, 2)),
            .w = cancel_w,
            .h = cancel_h,
        };
        _ = c.SDL_RenderTexture(renderer, cancel_tex, null, &cancel_text_rect);

        const confirm_text_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.confirm.x + @divFloor(buttons.confirm.w - self.confirm_w, 2)),
            .y = @floatFromInt(buttons.confirm.y + @divFloor(buttons.confirm.h - self.confirm_h, 2)),
            .w = @floatFromInt(self.confirm_w),
            .h = @floatFromInt(self.confirm_h),
        };
        _ = c.SDL_RenderTexture(renderer, confirm_tex, null, &confirm_text_rect);
    }

    fn modalRect(self: *ConfirmDialogComponent, host: *const types.UiHost) geom.Rect {
        _ = self;
        const modal_w = dpi.scale(modal_width, host.ui_scale);
        const modal_h = dpi.scale(modal_height, host.ui_scale);
        return geom.Rect{
            .x = @divFloor(host.window_w - modal_w, 2),
            .y = @divFloor(host.window_h - modal_h, 2),
            .w = modal_w,
            .h = modal_h,
        };
    }

    fn buttonRects(self: *ConfirmDialogComponent, modal: geom.Rect, ui_scale: f32) struct { cancel: geom.Rect, confirm: geom.Rect } {
        _ = self;
        const button_w = dpi.scale(button_width, ui_scale);
        const button_h = dpi.scale(button_height, ui_scale);
        const gap = dpi.scale(button_gap, ui_scale);
        const scaled_padding = dpi.scale(padding, ui_scale);
        const total_w = button_w * 2 + gap;
        const base_x = modal.x + modal.w - total_w - scaled_padding;
        const base_y = modal.y + modal.h - button_h - scaled_padding;
        return .{
            .cancel = .{ .x = base_x, .y = base_y, .w = button_w, .h = button_h },
            .confirm = .{ .x = base_x + button_w + gap, .y = base_y, .w = button_w, .h = button_h },
        };
    }

    fn ensureTextures(self: *ConfirmDialogComponent, renderer: *c.SDL_Renderer, theme: *const colors.Theme, cache: *font_cache.FontCache) !void {
        if (!self.dirty and self.title_tex != null and self.message_tex != null and self.confirm_tex != null and self.cancel_tex != null) return;
        const title_fonts = try cache.get(self.title_font_size);
        const body_fonts = try cache.get(self.body_font_size);
        const title_font = title_fonts.regular;
        const body_font = body_fonts.regular;

        if (self.title_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.message_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.confirm_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.cancel_tex) |tex| c.SDL_DestroyTexture(tex);

        const fg = theme.foreground;
        const title_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const title_surface = c.TTF_RenderText_Blended(title_font, self.title_text.ptr, self.title_text.len, title_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(title_surface);
        self.title_tex = c.SDL_CreateTextureFromSurface(renderer, title_surface) orelse return error.TextureFailed;
        const tex_title_size = textureSize(self.title_tex.?);
        self.title_w = tex_title_size.x;
        self.title_h = tex_title_size.y;

        const message_surface = c.TTF_RenderText_Blended(body_font, self.message_text.ptr, self.message_text.len, title_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(message_surface);
        self.message_tex = c.SDL_CreateTextureFromSurface(renderer, message_surface) orelse return error.TextureFailed;
        const message_size = textureSize(self.message_tex.?);
        self.message_w = message_size.x;
        self.message_h = message_size.y;

        const confirm_fg = theme.foreground;
        const confirm_color = c.SDL_Color{ .r = confirm_fg.r, .g = confirm_fg.g, .b = confirm_fg.b, .a = 255 };
        const confirm_surface = c.TTF_RenderText_Blended(body_font, self.confirm_text.ptr, self.confirm_text.len, confirm_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(confirm_surface);
        self.confirm_tex = c.SDL_CreateTextureFromSurface(renderer, confirm_surface) orelse return error.TextureFailed;
        const confirm_size = textureSize(self.confirm_tex.?);
        self.confirm_w = confirm_size.x;
        self.confirm_h = confirm_size.y;

        const cancel_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const cancel_surface = c.TTF_RenderText_Blended(body_font, self.cancel_text.ptr, self.cancel_text.len, cancel_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(cancel_surface);
        self.cancel_tex = c.SDL_CreateTextureFromSurface(renderer, cancel_surface) orelse return error.TextureFailed;
        const cancel_size = textureSize(self.cancel_tex.?);
        self.cancel_w = cancel_size.x;
        self.cancel_h = cancel_size.y;

        self.dirty = false;
    }

    fn textureSize(tex: *c.SDL_Texture) struct { x: c_int, y: c_int } {
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &w, &h);
        return .{ .x = @intFromFloat(w), .y = @intFromFloat(h) };
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *ConfirmDialogComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};
