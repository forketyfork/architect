const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const UiComponent = @import("../component.zig").UiComponent;

pub const ToastComponent = struct {
    allocator: std.mem.Allocator,
    start_time: i64 = 0,
    active: bool = false,
    first_frame: FirstFrameGuard = .{},

    message: [256]u8 = undefined,
    message_len: usize = 0,

    font: ?*c.TTF_Font = null,
    symbol_fallback: ?*c.TTF_Font = null,
    emoji_fallback: ?*c.TTF_Font = null,
    texture: ?*c.SDL_Texture = null,
    tex_w: c_int = 0,
    tex_h: c_int = 0,
    dirty: bool = true,

    const NOTIFICATION_FONT_SIZE: c_int = 36;
    const NOTIFICATION_DURATION_MS: i64 = 2500;
    const NOTIFICATION_FADE_START_MS: i64 = 1500;
    const NOTIFICATION_BG_MAX_ALPHA: u8 = 200;
    const NOTIFICATION_BORDER_MAX_ALPHA: u8 = 180;
    const MAX_TOAST_LINES: usize = 16;
    const MAX_LINE_LENGTH: usize = 256;

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
        self.first_frame.markTransition();
    }

    pub fn destroy(self: *ToastComponent, renderer: *c.SDL_Renderer) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
        if (self.emoji_fallback) |f| {
            c.TTF_CloseFont(f);
            self.emoji_fallback = null;
        }
        if (self.symbol_fallback) |f| {
            c.TTF_CloseFont(f);
            self.symbol_fallback = null;
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

    fn wantsFrame(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *ToastComponent = @ptrCast(@alignCast(self_ptr));
        return self.first_frame.wantsFrame() or self.isVisible(host.now_ms);
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *ToastComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.isVisible(host.now_ms)) return;

        const alpha = self.getAlpha(host.now_ms);
        if (alpha == 0) return;

        self.ensureTexture(renderer, assets, host.theme) catch return;
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
        const sel = host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, bg_alpha);
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        const border_alpha = @min(alpha, NOTIFICATION_BORDER_MAX_ALPHA);
        const acc = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, border_alpha);
        _ = c.SDL_RenderRect(renderer, &bg_rect);

        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureAlphaMod(texture, alpha);
        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = text_width_f,
            .h = text_height_f,
        };

        _ = c.SDL_RenderTexture(renderer, texture, null, &dest_rect);
        self.first_frame.markDrawn();
    }

    fn ensureTexture(self: *ToastComponent, renderer: *c.SDL_Renderer, assets: *types.UiAssets, theme: *const @import("../../colors.zig").Theme) !void {
        if (!self.active) return;
        if (!self.dirty and self.texture != null) return;

        const font_path = assets.font_path orelse return error.FontPathNotSet;
        if (self.font == null) {
            self.font = c.TTF_OpenFont(font_path.ptr, @floatFromInt(NOTIFICATION_FONT_SIZE));
            if (self.font == null) return error.FontUnavailable;

            if (assets.symbol_fallback_path) |symbol_path| {
                self.symbol_fallback = c.TTF_OpenFont(symbol_path.ptr, @floatFromInt(NOTIFICATION_FONT_SIZE));
                if (self.symbol_fallback) |s| {
                    if (!c.TTF_AddFallbackFont(self.font.?, s)) {
                        c.TTF_CloseFont(s);
                        self.symbol_fallback = null;
                    }
                }
            }

            if (assets.emoji_fallback_path) |emoji_path| {
                self.emoji_fallback = c.TTF_OpenFont(emoji_path.ptr, @floatFromInt(NOTIFICATION_FONT_SIZE));
                if (self.emoji_fallback) |e| {
                    if (!c.TTF_AddFallbackFont(self.font.?, e)) {
                        c.TTF_CloseFont(e);
                        self.emoji_fallback = null;
                    }
                }
            }
        }
        const toast_font = self.font.?;
        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };

        var lines: [MAX_TOAST_LINES][]const u8 = undefined;
        var line_count: usize = 0;
        var line_start: usize = 0;
        for (0..self.message_len) |i| {
            if (self.message[i] == '\n') {
                if (line_count < lines.len) {
                    lines[line_count] = self.message[line_start..i];
                    line_count += 1;
                }
                line_start = i + 1;
            }
        }
        if (line_start < self.message_len and line_count < lines.len) {
            lines[line_count] = self.message[line_start..self.message_len];
            line_count += 1;
        }

        var max_width: c_int = 0;
        var line_surfaces: [MAX_TOAST_LINES]?*c.SDL_Surface = [_]?*c.SDL_Surface{null} ** MAX_TOAST_LINES;
        var line_heights: [MAX_TOAST_LINES]c_int = undefined;
        defer {
            for (line_surfaces[0..line_count]) |surf_opt| {
                if (surf_opt) |surf| {
                    c.SDL_DestroySurface(surf);
                }
            }
        }

        for (lines[0..line_count], 0..) |line, idx| {
            var line_buf: [MAX_LINE_LENGTH]u8 = undefined;
            @memcpy(line_buf[0..line.len], line);
            line_buf[line.len] = 0;

            const surface = c.TTF_RenderText_Blended(toast_font, @ptrCast(&line_buf), line.len, fg_color) orelse continue;
            line_surfaces[idx] = surface;
            line_heights[idx] = surface.*.h;
            max_width = @max(max_width, surface.*.w);
        }

        var total_height: c_int = 0;
        for (line_heights[0..line_count]) |h| {
            total_height += h;
        }
        const composite_surface = c.SDL_CreateSurface(max_width, total_height, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(composite_surface);

        _ = c.SDL_SetSurfaceBlendMode(composite_surface, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_FillSurfaceRect(composite_surface, null, 0);

        var y_offset: c_int = 0;
        for (line_surfaces[0..line_count], 0..) |surf_opt, idx| {
            if (surf_opt) |line_surface| {
                const dest_rect = c.SDL_Rect{
                    .x = 0,
                    .y = y_offset,
                    .w = line_surface.*.w,
                    .h = line_surface.*.h,
                };
                _ = c.SDL_BlitSurface(line_surface, null, composite_surface, &dest_rect);
                y_offset += line_heights[idx];
            }
        }

        const texture = c.SDL_CreateTextureFromSurface(renderer, composite_surface) orelse return error.TextureFailed;
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
        .wantsFrame = wantsFrame,
    };
};
