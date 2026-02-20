const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const easing = @import("../../anim/easing.zig");

pub const AnimationEvent = enum {
    became_open,
    became_closed,
};

pub const FullscreenOverlay = struct {
    visible: bool = false,
    animation_state: AnimationState = .closed,
    animation_start_ms: i64 = 0,
    render_alpha: f32 = 1.0,

    scroll_offset: f32 = 0,
    max_scroll: f32 = 0,
    close_hovered: bool = false,

    first_frame: FirstFrameGuard = .{},

    pub const AnimationState = enum { closed, opening, open, closing };

    pub const animation_duration_ms: i64 = 250;
    pub const scale_from: f32 = 0.97;
    pub const scroll_speed: f32 = 40.0;
    pub const outer_margin: c_int = 40;
    pub const title_height: c_int = 50;
    pub const close_btn_size: c_int = 32;
    pub const close_btn_margin: c_int = 12;
    pub const text_padding: c_int = 12;

    // --- Lifecycle ---

    pub fn show(self: *FullscreenOverlay, now_ms: i64) void {
        self.visible = true;
        self.scroll_offset = 0;
        self.animation_state = .opening;
        self.animation_start_ms = now_ms;
        self.first_frame.markTransition();
    }

    pub fn hide(self: *FullscreenOverlay, now_ms: i64) void {
        self.animation_state = .closing;
        self.animation_start_ms = now_ms;
        self.first_frame.markTransition();
    }

    pub fn updateAnimation(self: *FullscreenOverlay, now_ms: i64) ?AnimationEvent {
        const elapsed = now_ms - self.animation_start_ms;
        switch (self.animation_state) {
            .opening => {
                if (elapsed >= animation_duration_ms) {
                    self.animation_state = .open;
                    return .became_open;
                }
            },
            .closing => {
                if (elapsed >= animation_duration_ms) {
                    self.animation_state = .closed;
                    self.visible = false;
                    return .became_closed;
                }
            },
            .open, .closed => {},
        }
        return null;
    }

    // --- Animation ---

    pub fn animationProgress(self: *const FullscreenOverlay, now_ms: i64) f32 {
        const elapsed = now_ms - self.animation_start_ms;
        if (elapsed >= animation_duration_ms) return 1.0;
        if (elapsed <= 0) return 0.0;
        const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(animation_duration_ms));
        return easing.easeInOutCubic(t);
    }

    pub fn renderProgress(self: *const FullscreenOverlay, now_ms: i64) f32 {
        const raw = self.animationProgress(now_ms);
        return switch (self.animation_state) {
            .opening => raw,
            .closing => 1.0 - raw,
            .open => 1.0,
            .closed => 0.0,
        };
    }

    // --- Layout ---

    pub fn overlayRect(host: *const types.UiHost) geom.Rect {
        const scaled_margin = dpi.scale(outer_margin, host.ui_scale);
        return .{
            .x = scaled_margin,
            .y = scaled_margin,
            .w = host.window_w - scaled_margin * 2,
            .h = host.window_h - scaled_margin * 2,
        };
    }

    pub fn animatedOverlayRect(host: *const types.UiHost, progress: f32) geom.Rect {
        const base = overlayRect(host);
        const scale = scale_from + (1.0 - scale_from) * progress;
        const base_w: f32 = @floatFromInt(base.w);
        const base_h: f32 = @floatFromInt(base.h);
        const base_x: f32 = @floatFromInt(base.x);
        const base_y: f32 = @floatFromInt(base.y);
        const new_w = base_w * scale;
        const new_h = base_h * scale;
        return .{
            .x = @intFromFloat(base_x + (base_w - new_w) / 2.0),
            .y = @intFromFloat(base_y + (base_h - new_h) / 2.0),
            .w = @intFromFloat(new_w),
            .h = @intFromFloat(new_h),
        };
    }

    pub fn closeButtonRect(host: *const types.UiHost) geom.Rect {
        const scaled_margin = dpi.scale(outer_margin, host.ui_scale);
        const scaled_btn_size = dpi.scale(close_btn_size, host.ui_scale);
        const scaled_btn_margin = dpi.scale(close_btn_margin, host.ui_scale);
        return .{
            .x = host.window_w - scaled_margin - scaled_btn_size - scaled_btn_margin,
            .y = scaled_margin + scaled_btn_margin,
            .w = scaled_btn_size,
            .h = scaled_btn_size,
        };
    }

    // --- Input ---

    pub fn handleScrollKey(self: *FullscreenOverlay, key: c.SDL_Keycode, host: *const types.UiHost) bool {
        if (key == c.SDLK_UP) {
            self.scroll_offset = @max(0, self.scroll_offset - scroll_speed);
            return true;
        }
        if (key == c.SDLK_DOWN) {
            self.scroll_offset = @min(self.max_scroll, self.scroll_offset + scroll_speed);
            return true;
        }
        if (key == c.SDLK_PAGEUP) {
            const page: f32 = @floatFromInt(host.window_h - dpi.scale(title_height + outer_margin * 2, host.ui_scale));
            self.scroll_offset = @max(0, self.scroll_offset - page);
            return true;
        }
        if (key == c.SDLK_PAGEDOWN) {
            const page: f32 = @floatFromInt(host.window_h - dpi.scale(title_height + outer_margin * 2, host.ui_scale));
            self.scroll_offset = @min(self.max_scroll, self.scroll_offset + page);
            return true;
        }
        if (key == c.SDLK_HOME) {
            self.scroll_offset = 0;
            return true;
        }
        if (key == c.SDLK_END) {
            self.scroll_offset = self.max_scroll;
            return true;
        }
        return false;
    }

    pub fn handleMouseWheel(self: *FullscreenOverlay, wheel_y: f32) void {
        self.scroll_offset = @max(0, self.scroll_offset - wheel_y * scroll_speed);
        self.scroll_offset = @min(self.max_scroll, self.scroll_offset);
    }

    pub fn isCloseButtonHit(mouse_x: c_int, mouse_y: c_int, host: *const types.UiHost) bool {
        const close_rect = closeButtonRect(host);
        return geom.containsPoint(close_rect, mouse_x, mouse_y);
    }

    pub fn updateCloseHover(self: *FullscreenOverlay, mouse_x: c_int, mouse_y: c_int, host: *const types.UiHost) void {
        const close_rect = closeButtonRect(host);
        self.close_hovered = geom.containsPoint(close_rect, mouse_x, mouse_y);
    }

    pub fn hitTest(self: *const FullscreenOverlay, host: *const types.UiHost, x: c_int, y: c_int) bool {
        if (!self.visible or self.animation_state == .closing) return false;
        const rect = overlayRect(host);
        return geom.containsPoint(rect, x, y);
    }

    pub fn wantsFrame(self: *const FullscreenOverlay) bool {
        return self.first_frame.wantsFrame() or self.animation_state == .opening or self.animation_state == .closing;
    }

    /// Returns true if the overlay is visible and should consume input events.
    pub fn isConsuming(self: *const FullscreenOverlay) bool {
        return self.visible and self.animation_state != .closed;
    }

    // --- Rendering ---

    pub fn renderFrame(self: *const FullscreenOverlay, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect, progress: f32) void {
        _ = self;
        const radius: c_int = dpi.scale(12, host.ui_scale);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const bg = host.theme.background;
        const bg_alpha: u8 = @intFromFloat(240.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, bg_alpha);
        primitives.fillRoundedRect(renderer, rect, radius);

        const accent = host.theme.accent;
        const border_alpha: u8 = @intFromFloat(180.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, border_alpha);
        primitives.drawRoundedBorder(renderer, rect, radius);
    }

    pub fn renderTitleSeparator(renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect, progress: f32) void {
        const scaled_title_h = dpi.scale(title_height, host.ui_scale);
        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const accent = host.theme.accent;
        const line_alpha: u8 = @intFromFloat(80.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, line_alpha);
        _ = c.SDL_RenderLine(
            renderer,
            @floatFromInt(rect.x + scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
            @floatFromInt(rect.x + rect.w - scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
        );
    }

    pub fn renderCloseButton(self: *const FullscreenOverlay, renderer: *c.SDL_Renderer, host: *const types.UiHost, overlay_rect: geom.Rect) void {
        const scaled_btn_size = dpi.scale(close_btn_size, host.ui_scale);
        const scaled_btn_margin = dpi.scale(close_btn_margin, host.ui_scale);
        const btn_rect = geom.Rect{
            .x = overlay_rect.x + overlay_rect.w - scaled_btn_size - scaled_btn_margin,
            .y = overlay_rect.y + scaled_btn_margin,
            .w = scaled_btn_size,
            .h = scaled_btn_size,
        };

        const fg = host.theme.foreground;
        const alpha: u8 = @intFromFloat(if (self.close_hovered) 255.0 * self.render_alpha else 160.0 * self.render_alpha);
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, alpha);

        const cross_size: c_int = @divFloor(btn_rect.w * 6, 10);
        const cross_x = btn_rect.x + @divFloor(btn_rect.w - cross_size, 2);
        const cross_y = btn_rect.y + @divFloor(btn_rect.h - cross_size, 2);

        const x1: f32 = @floatFromInt(cross_x);
        const y1: f32 = @floatFromInt(cross_y);
        const x2: f32 = @floatFromInt(cross_x + cross_size);
        const y2: f32 = @floatFromInt(cross_y + cross_size);

        _ = c.SDL_RenderLine(renderer, x1, y1, x2, y2);
        _ = c.SDL_RenderLine(renderer, x2, y1, x1, y2);

        if (self.close_hovered) {
            const bold_offset: f32 = 1.0;
            _ = c.SDL_RenderLine(renderer, x1 + bold_offset, y1, x2 + bold_offset, y2);
            _ = c.SDL_RenderLine(renderer, x2 + bold_offset, y1, x1 + bold_offset, y2);
            _ = c.SDL_RenderLine(renderer, x1, y1 + bold_offset, x2, y2 + bold_offset);
            _ = c.SDL_RenderLine(renderer, x2, y1 + bold_offset, x1, y2 + bold_offset);
        }
    }

    /// Render a title texture centered vertically in the title area.
    pub fn renderTitle(self: *const FullscreenOverlay, renderer: *c.SDL_Renderer, rect: geom.Rect, title_tex: *c.SDL_Texture, title_w: c_int, title_h: c_int, host: *const types.UiHost) void {
        const scaled_title_h = dpi.scale(title_height, host.ui_scale);
        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const tex_alpha: u8 = @intFromFloat(255.0 * self.render_alpha);
        _ = c.SDL_SetTextureAlphaMod(title_tex, tex_alpha);

        const text_y = rect.y + @divFloor(scaled_title_h - title_h, 2);
        _ = c.SDL_RenderTexture(renderer, title_tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + scaled_padding),
            .y = @floatFromInt(text_y),
            .w = @floatFromInt(title_w),
            .h = @floatFromInt(title_h),
        });
    }
};
