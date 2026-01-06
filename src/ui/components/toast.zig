const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;

pub const ToastComponent = struct {
    allocator: std.mem.Allocator,
    start_time: i64 = 0,
    active: bool = false,

    message: [256]u8 = undefined,
    message_len: usize = 0,

    font: ?*c.TTF_Font = null,
    texture: ?*c.SDL_Texture = null,
    tex_w: c_int = 0,
    tex_h: c_int = 0,
    dirty: bool = true,

    const FONT_PATH: [*:0]const u8 = "/System/Library/Fonts/SFNSMono.ttf";
    const NOTIFICATION_FONT_SIZE: c_int = 36;
    const NOTIFICATION_DURATION_MS: i64 = 2500;
    const NOTIFICATION_FADE_START_MS: i64 = 1500;
    const NOTIFICATION_BG_MAX_ALPHA: u8 = 200;
    const NOTIFICATION_BORDER_MAX_ALPHA: u8 = 180;

    pub fn init(allocator: std.mem.Allocator) !*ToastComponent {
        const comp = try allocator.create(ToastComponent);
        comp.* = .{ .allocator = allocator };
        return comp;
    }

    pub fn asComponent(self: *ToastComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 900,
        };
    }

    pub fn show(self: *ToastComponent, message: []const u8, now: i64) void {
        const len = @min(message.len, self.message.len - 1);
        @memcpy(self.message[0..len], message[0..len]);
        self.message[len] = 0;
        self.message_len = len;
        self.start_time = now;
        self.active = true;
        self.dirty = true;
    }

    pub fn destroy(self: *ToastComponent, renderer: *c.SDL_Renderer) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
        if (self.font) |f| {
            c.TTF_CloseFont(f);
            self.font = null;
        }
        self.allocator.destroy(self);
        _ = renderer;
    }

    fn handleEvent(_: *anyopaque, _: *const types.UiHost, _: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        return false;
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *ToastComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.isVisible(host.now_ms)) return;

        const alpha = self.getAlpha(host.now_ms);
        if (alpha == 0) return;

        self.ensureTexture(renderer) catch return;
        const texture = self.texture orelse return;

        var text_width_f: f32 = 0;
        var text_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &text_width_f, &text_height_f);

        const text_width: c_int = @intFromFloat(text_width_f);
        const text_height: c_int = @intFromFloat(text_height_f);

        const padding: c_int = 30;
        const bg_padding: c_int = 20;
        const x = @divFloor(host.window_w - text_width, 2);
        const y = padding;

        const bg_rect = c.SDL_FRect{
            .x = @as(f32, @floatFromInt(x - bg_padding)),
            .y = @as(f32, @floatFromInt(y - bg_padding)),
            .w = @as(f32, @floatFromInt(text_width + bg_padding * 2)),
            .h = @as(f32, @floatFromInt(text_height + bg_padding * 2)),
        };

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const bg_alpha = @min(alpha, NOTIFICATION_BG_MAX_ALPHA);
        _ = c.SDL_SetRenderDrawColor(renderer, 20, 20, 30, bg_alpha);
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        const border_alpha = @min(alpha, NOTIFICATION_BORDER_MAX_ALPHA);
        _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, border_alpha);
        _ = c.SDL_RenderRect(renderer, &bg_rect);

        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = text_width_f,
            .h = text_height_f,
        };

        _ = c.SDL_RenderTexture(renderer, texture, null, &dest_rect);
    }

    fn ensureTexture(self: *ToastComponent, renderer: *c.SDL_Renderer) !void {
        if (!self.active) return;
        if (!self.dirty and self.texture != null) return;

        if (self.font == null) {
            self.font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(NOTIFICATION_FONT_SIZE));
            if (self.font == null) return error.FontUnavailable;
        }
        const toast_font = self.font.?;

        const fg_color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
        const message_z = @as([*:0]const u8, @ptrCast(&self.message));
        const surface = c.TTF_RenderText_Blended(toast_font, message_z, self.message_len, fg_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
        if (self.texture) |old| {
            c.SDL_DestroyTexture(old);
        }
        self.texture = texture;
        self.dirty = false;

        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &w, &h);
        self.tex_w = @intFromFloat(w);
        self.tex_h = @intFromFloat(h);
    }

    fn isVisible(self: *const ToastComponent, now: i64) bool {
        if (!self.active) return false;
        const elapsed = now - self.start_time;
        return elapsed < NOTIFICATION_DURATION_MS;
    }

    fn getAlpha(self: *const ToastComponent, now: i64) u8 {
        if (!self.isVisible(now)) return 0;
        const elapsed = now - self.start_time;
        if (elapsed < NOTIFICATION_FADE_START_MS) {
            return 255;
        }
        const fade_progress = @as(f32, @floatFromInt(elapsed - NOTIFICATION_FADE_START_MS)) /
            @as(f32, @floatFromInt(NOTIFICATION_DURATION_MS - NOTIFICATION_FADE_START_MS));
        const eased_progress = fade_progress * fade_progress * (3.0 - 2.0 * fade_progress);
        const alpha = 255.0 * (1.0 - eased_progress);
        return @intFromFloat(@max(0, @min(255, alpha)));
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *ToastComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};
