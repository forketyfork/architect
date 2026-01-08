const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");

pub const QuitConfirmComponent = struct {
    allocator: std.mem.Allocator,
    font: ?*c.TTF_Font = null,
    font_path: ?[:0]const u8 = null,
    visible: bool = false,
    dirty: bool = true,
    process_count: usize = 0,

    title_tex: ?*c.SDL_Texture = null,
    title_w: c_int = 0,
    title_h: c_int = 0,

    message_tex: ?*c.SDL_Texture = null,
    message_w: c_int = 0,
    message_h: c_int = 0,

    quit_tex: ?*c.SDL_Texture = null,
    quit_w: c_int = 0,
    quit_h: c_int = 0,

    cancel_tex: ?*c.SDL_Texture = null,
    cancel_w: c_int = 0,
    cancel_h: c_int = 0,

    const MODAL_WIDTH: c_int = 520;
    const MODAL_HEIGHT: c_int = 220;
    const MODAL_RADIUS: c_int = 12;
    const PADDING: c_int = 24;
    const TITLE_SIZE: c_int = 22;
    const BODY_SIZE: c_int = 16;
    const BUTTON_WIDTH: c_int = 136;
    const BUTTON_HEIGHT: c_int = 40;
    const BUTTON_GAP: c_int = 12;

    pub fn init(allocator: std.mem.Allocator) !*QuitConfirmComponent {
        const self = try allocator.create(QuitConfirmComponent);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn asComponent(self: *QuitConfirmComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 2000,
        };
    }

    pub fn destroy(self: *QuitConfirmComponent, renderer: *c.SDL_Renderer) void {
        if (self.title_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.message_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.quit_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.cancel_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.font) |f| c.TTF_CloseFont(f);
        self.allocator.destroy(self);
        _ = renderer;
    }

    pub fn show(self: *QuitConfirmComponent, process_count: usize) void {
        self.visible = true;
        if (process_count != self.process_count) {
            self.process_count = process_count;
            self.dirty = true;
        }
    }

    pub fn hide(self: *QuitConfirmComponent) void {
        self.visible = false;
    }

    pub fn isVisible(self: *QuitConfirmComponent) bool {
        return self.visible;
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *QuitConfirmComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return false;

        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                return true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const is_confirm = key == c.SDLK_RETURN or key == c.SDLK_RETURN2 or key == c.SDLK_KP_ENTER or (key == c.SDLK_Q and (mod & c.SDL_KMOD_GUI) != 0);
                if (is_confirm) {
                    actions.append(.ConfirmQuit) catch {};
                    self.visible = false;
                    return true;
                }
                if (key == c.SDLK_ESCAPE or key == c.SDLK_W and (mod & c.SDL_KMOD_GUI) != 0) {
                    self.visible = false;
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const modal = self.modalRect(host);
                const buttons = self.buttonRects(modal, host.ui_scale);
                if (geom.containsPoint(buttons.quit, mouse_x, mouse_y)) {
                    actions.append(.ConfirmQuit) catch {};
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
        const self: *QuitConfirmComponent = @ptrCast(@alignCast(self_ptr));
        return self.visible;
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *QuitConfirmComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;
        if (assets.font_path) |path| {
            if (self.font_path == null or !std.mem.eql(u8, self.font_path.?, path)) {
                self.font_path = path;
                if (self.font) |f| {
                    c.TTF_CloseFont(f);
                    self.font = null;
                }
                self.dirty = true;
            }
        }
        if (self.font_path == null) return;

        self.ensureTextures(renderer, host.ui_scale) catch return;

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
        _ = c.SDL_SetRenderDrawColor(renderer, 23, 28, 39, 240);
        const modal_rect = c.SDL_FRect{
            .x = @floatFromInt(modal.x),
            .y = @floatFromInt(modal.y),
            .w = @floatFromInt(modal.w),
            .h = @floatFromInt(modal.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &modal_rect);
        _ = c.SDL_SetRenderDrawColor(renderer, 97, 175, 239, 255);
        primitives.drawRoundedBorder(renderer, modal, dpi.scale(MODAL_RADIUS, host.ui_scale));

        self.renderText(renderer, modal, host.ui_scale);
        self.renderButtons(renderer, modal, host.ui_scale);
    }

    fn renderText(self: *QuitConfirmComponent, renderer: *c.SDL_Renderer, modal: geom.Rect, ui_scale: f32) void {
        const padding = dpi.scale(PADDING, ui_scale);
        const title_x = modal.x + padding;
        const title_y = modal.y + padding;
        const title_rect = c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(title_y),
            .w = @floatFromInt(self.title_w),
            .h = @floatFromInt(self.title_h),
        };
        _ = c.SDL_RenderTexture(renderer, self.title_tex.?, null, &title_rect);

        const message_y = title_y + self.title_h + dpi.scale(12, ui_scale);
        const message_rect = c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(message_y),
            .w = @floatFromInt(self.message_w),
            .h = @floatFromInt(self.message_h),
        };
        _ = c.SDL_RenderTexture(renderer, self.message_tex.?, null, &message_rect);
    }

    fn renderButtons(self: *QuitConfirmComponent, renderer: *c.SDL_Renderer, modal: geom.Rect, ui_scale: f32) void {
        const buttons = self.buttonRects(modal, ui_scale);

        const cancel_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.cancel.x),
            .y = @floatFromInt(buttons.cancel.y),
            .w = @floatFromInt(buttons.cancel.w),
            .h = @floatFromInt(buttons.cancel.h),
        };
        _ = c.SDL_SetRenderDrawColor(renderer, 41, 50, 67, 255);
        _ = c.SDL_RenderFillRect(renderer, &cancel_rect);
        _ = c.SDL_SetRenderDrawColor(renderer, 97, 175, 239, 255);
        primitives.drawRoundedBorder(renderer, buttons.cancel, dpi.scale(8, ui_scale));

        const quit_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.quit.x),
            .y = @floatFromInt(buttons.quit.y),
            .w = @floatFromInt(buttons.quit.w),
            .h = @floatFromInt(buttons.quit.h),
        };
        _ = c.SDL_SetRenderDrawColor(renderer, 63, 34, 39, 255);
        _ = c.SDL_RenderFillRect(renderer, &quit_rect);
        _ = c.SDL_SetRenderDrawColor(renderer, 224, 108, 117, 255);
        primitives.drawRoundedBorder(renderer, buttons.quit, dpi.scale(8, ui_scale));

        const cancel_w = @as(f32, @floatFromInt(self.cancel_w));
        const cancel_h = @as(f32, @floatFromInt(self.cancel_h));
        const cancel_text_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.cancel.x + @divFloor(buttons.cancel.w - self.cancel_w, 2)),
            .y = @floatFromInt(buttons.cancel.y + @divFloor(buttons.cancel.h - self.cancel_h, 2)),
            .w = cancel_w,
            .h = cancel_h,
        };
        _ = c.SDL_RenderTexture(renderer, self.cancel_tex.?, null, &cancel_text_rect);

        const quit_text_rect = c.SDL_FRect{
            .x = @floatFromInt(buttons.quit.x + @divFloor(buttons.quit.w - self.quit_w, 2)),
            .y = @floatFromInt(buttons.quit.y + @divFloor(buttons.quit.h - self.quit_h, 2)),
            .w = @floatFromInt(self.quit_w),
            .h = @floatFromInt(self.quit_h),
        };
        _ = c.SDL_RenderTexture(renderer, self.quit_tex.?, null, &quit_text_rect);
    }

    fn modalRect(self: *QuitConfirmComponent, host: *const types.UiHost) geom.Rect {
        _ = self;
        const modal_w = dpi.scale(MODAL_WIDTH, host.ui_scale);
        const modal_h = dpi.scale(MODAL_HEIGHT, host.ui_scale);
        return geom.Rect{
            .x = @divFloor(host.window_w - modal_w, 2),
            .y = @divFloor(host.window_h - modal_h, 2),
            .w = modal_w,
            .h = modal_h,
        };
    }

    fn buttonRects(self: *QuitConfirmComponent, modal: geom.Rect, ui_scale: f32) struct { cancel: geom.Rect, quit: geom.Rect } {
        _ = self;
        const button_w = dpi.scale(BUTTON_WIDTH, ui_scale);
        const button_h = dpi.scale(BUTTON_HEIGHT, ui_scale);
        const gap = dpi.scale(BUTTON_GAP, ui_scale);
        const padding = dpi.scale(PADDING, ui_scale);
        const total_w = button_w * 2 + gap;
        const base_x = modal.x + modal.w - total_w - padding;
        const base_y = modal.y + modal.h - button_h - padding;
        return .{
            .cancel = .{ .x = base_x, .y = base_y, .w = button_w, .h = button_h },
            .quit = .{ .x = base_x + button_w + gap, .y = base_y, .w = button_w, .h = button_h },
        };
    }

    fn ensureTextures(self: *QuitConfirmComponent, renderer: *c.SDL_Renderer, ui_scale: f32) !void {
        if (!self.dirty and self.title_tex != null and self.message_tex != null and self.quit_tex != null and self.cancel_tex != null) return;
        const font_path = self.font_path orelse return error.FontPathNotSet;
        if (self.font == null) {
            self.font = c.TTF_OpenFont(font_path.ptr, @floatFromInt(dpi.scale(BODY_SIZE, ui_scale))) orelse return error.FontUnavailable;
        }

        const font = self.font.?;

        if (self.title_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.message_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.quit_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.cancel_tex) |tex| c.SDL_DestroyTexture(tex);

        _ = c.TTF_SetFontSize(font, @floatFromInt(dpi.scale(TITLE_SIZE, ui_scale)));
        const title_text = "Quit Architect?";
        const title_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };
        const title_surface = c.TTF_RenderText_Blended(font, title_text, title_text.len, title_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(title_surface);
        self.title_tex = c.SDL_CreateTextureFromSurface(renderer, title_surface) orelse return error.TextureFailed;
        const title_size = textureSize(self.title_tex.?);
        self.title_w = title_size.x;
        self.title_h = title_size.y;

        var message_buf: [128]u8 = undefined;
        const message = self.makeMessage(&message_buf);
        _ = c.TTF_SetFontSize(font, @floatFromInt(dpi.scale(BODY_SIZE, ui_scale)));
        const message_slice = std.mem.sliceTo(message, 0);
        const message_surface = c.TTF_RenderText_Blended(font, message_slice.ptr, @intCast(message_slice.len), title_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(message_surface);
        self.message_tex = c.SDL_CreateTextureFromSurface(renderer, message_surface) orelse return error.TextureFailed;
        const message_size = textureSize(self.message_tex.?);
        self.message_w = message_size.x;
        self.message_h = message_size.y;

        const quit_text = "Quit";
        const quit_color = c.SDL_Color{ .r = 224, .g = 108, .b = 117, .a = 255 };
        const quit_surface = c.TTF_RenderText_Blended(font, quit_text, quit_text.len, quit_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(quit_surface);
        self.quit_tex = c.SDL_CreateTextureFromSurface(renderer, quit_surface) orelse return error.TextureFailed;
        const quit_size = textureSize(self.quit_tex.?);
        self.quit_w = quit_size.x;
        self.quit_h = quit_size.y;

        const cancel_text = "Cancel";
        const cancel_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };
        const cancel_surface = c.TTF_RenderText_Blended(font, cancel_text, cancel_text.len, cancel_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(cancel_surface);
        self.cancel_tex = c.SDL_CreateTextureFromSurface(renderer, cancel_surface) orelse return error.TextureFailed;
        const cancel_size = textureSize(self.cancel_tex.?);
        self.cancel_w = cancel_size.x;
        self.cancel_h = cancel_size.y;

        self.dirty = false;
    }

    fn makeMessage(self: *QuitConfirmComponent, buffer: *[128]u8) [:0]const u8 {
        const plural = if (self.process_count == 1) "" else "s";
        const verb = if (self.process_count == 1) "has" else "have";
        const process_plural = if (self.process_count == 1) "" else "es";
        return std.fmt.bufPrintZ(
            buffer,
            "{d} terminal{s} {s} running process{s}. Quit anyway?",
            .{ self.process_count, plural, verb, process_plural },
        ) catch "Quit anyway?";
    }

    fn textureSize(tex: *c.SDL_Texture) struct { x: c_int, y: c_int } {
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &w, &h);
        return .{ .x = @intFromFloat(w), .y = @intFromFloat(h) };
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *QuitConfirmComponent = @ptrCast(@alignCast(self_ptr));
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
