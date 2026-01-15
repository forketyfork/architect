const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const button = @import("button.zig");
const font_utils = @import("../font_utils.zig");

pub const QuitConfirmComponent = struct {
    allocator: std.mem.Allocator,
    fonts: ?font_utils.FontWithFallbacks = null,
    font_path: ?[:0]const u8 = null,
    visible: bool = false,
    dirty: bool = true,
    process_count: usize = 0,
    escape_pressed: bool = false,

    title_tex: ?*c.SDL_Texture = null,
    title_w: c_int = 0,
    title_h: c_int = 0,

    message_tex: ?*c.SDL_Texture = null,
    message_w: c_int = 0,
    message_h: c_int = 0,

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
        if (self.fonts) |fonts| fonts.close();
        self.allocator.destroy(self);
        _ = renderer;
    }

    pub fn show(self: *QuitConfirmComponent, process_count: usize) void {
        self.visible = true;
        self.escape_pressed = false;
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
                const is_confirm = key == c.SDLK_RETURN or key == c.SDLK_RETURN2 or key == c.SDLK_KP_ENTER or (key == c.SDLK_Q and (mod & c.SDL_KMOD_GUI) != 0);
                if (is_confirm) {
                    actions.append(.ConfirmQuit) catch {};
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
                if (geom.containsPoint(buttons.quit, mouse_x, mouse_y)) {
                    actions.append(.ConfirmQuit) catch {};
                    self.visible = false;
                    return true;
                }
                if (geom.containsPoint(buttons.cancel, mouse_x, mouse_y)) {
                    self.visible = false;
                    return true;
                }
                if (geom.containsPoint(modal, mouse_x, mouse_y)) {
                    return true;
                }
                self.visible = false;
                return true;
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
                if (self.fonts) |fonts| {
                    fonts.close();
                    self.fonts = null;
                }
                self.dirty = true;
            }
        }
        if (self.font_path == null) return;

        self.ensureTextures(renderer, host.ui_scale, host.theme) catch return;

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
        primitives.drawRoundedBorder(renderer, modal, dpi.scale(MODAL_RADIUS, host.ui_scale));

        self.renderText(renderer, modal, host.ui_scale);
        self.renderButtons(renderer, modal, host.ui_scale, host.theme);
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

    fn renderButtons(self: *QuitConfirmComponent, renderer: *c.SDL_Renderer, modal: geom.Rect, ui_scale: f32, theme: *const @import("../../colors.zig").Theme) void {
        const buttons = self.buttonRects(modal, ui_scale);

        if (self.fonts) |fonts| {
            const cancel_rect = c.SDL_FRect{
                .x = @floatFromInt(buttons.cancel.x),
                .y = @floatFromInt(buttons.cancel.y),
                .w = @floatFromInt(buttons.cancel.w),
                .h = @floatFromInt(buttons.cancel.h),
            };
            button.renderButton(renderer, fonts.main, cancel_rect, "Cancel", .default, theme, ui_scale);

            const quit_rect = c.SDL_FRect{
                .x = @floatFromInt(buttons.quit.x),
                .y = @floatFromInt(buttons.quit.y),
                .w = @floatFromInt(buttons.quit.w),
                .h = @floatFromInt(buttons.quit.h),
            };
            button.renderButton(renderer, fonts.main, quit_rect, "Quit", .danger, theme, ui_scale);
        }
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

    fn ensureTextures(self: *QuitConfirmComponent, renderer: *c.SDL_Renderer, ui_scale: f32, theme: *const @import("../../colors.zig").Theme) !void {
        if (!self.dirty and self.title_tex != null and self.message_tex != null) return;
        const font_path = self.font_path orelse return error.FontPathNotSet;
        if (self.fonts == null) {
            self.fonts = font_utils.openFontWithFallbacks(font_path, null, null, dpi.scale(BODY_SIZE, ui_scale)) catch return error.FontUnavailable;
        }

        const font = self.fonts.?.main;

        if (self.title_tex) |tex| c.SDL_DestroyTexture(tex);
        if (self.message_tex) |tex| c.SDL_DestroyTexture(tex);

        _ = c.TTF_SetFontSize(font, @floatFromInt(dpi.scale(TITLE_SIZE, ui_scale)));
        const title_text = "Quit Architect?";
        const fg = theme.foreground;
        const title_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
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
