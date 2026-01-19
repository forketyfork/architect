const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const UiComponent = @import("../component.zig").UiComponent;
const metrics_mod = @import("../../metrics.zig");
const font_cache = @import("../../font_cache.zig");

pub const MetricsOverlayComponent = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    first_frame: FirstFrameGuard = .{},

    font_generation: u64 = 0,
    texture: ?*c.SDL_Texture = null,
    tex_w: c_int = 0,
    tex_h: c_int = 0,
    dirty: bool = true,

    last_sample_ms: i64 = 0,
    cached_elapsed_ms: i64 = 0,

    const OVERLAY_FONT_SIZE: c_int = 14;
    const SAMPLE_INTERVAL_MS: i64 = 1000;
    const PADDING: c_int = 10;
    const BG_PADDING: c_int = 8;
    const BG_ALPHA: u8 = 180;
    const BORDER_ALPHA: u8 = 120;
    const MAX_LINES: usize = 8;
    const MAX_LINE_LENGTH: usize = 64;

    pub fn init(allocator: std.mem.Allocator) !*MetricsOverlayComponent {
        const comp = try allocator.create(MetricsOverlayComponent);
        comp.* = .{ .allocator = allocator };
        return comp;
    }

    pub fn asComponent(self: *MetricsOverlayComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 950,
        };
    }

    pub fn toggle(self: *MetricsOverlayComponent) void {
        self.visible = !self.visible;
        self.dirty = true;
        self.first_frame.markTransition();
    }

    pub fn destroy(self: *MetricsOverlayComponent, renderer: *c.SDL_Renderer) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
        self.allocator.destroy(self);
        _ = renderer;
    }

    fn handleEvent(_: *anyopaque, _: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        if (event.type == c.SDL_EVENT_KEY_DOWN) {
            const key_event = event.key;
            const mods = key_event.mod;
            const has_cmd = (mods & c.SDL_KMOD_GUI) != 0;
            const has_shift = (mods & c.SDL_KMOD_SHIFT) != 0;
            const has_blocking = (mods & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;

            if (has_cmd and has_shift and !has_blocking and key_event.key == c.SDLK_M) {
                actions.append(.{ .ToggleMetrics = {} }) catch {};
                return true;
            }
        }
        return false;
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *MetricsOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.first_frame.wantsFrame() or self.visible;
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *MetricsOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;

        const metrics_ptr = metrics_mod.global orelse return;

        if (host.now_ms - self.last_sample_ms >= SAMPLE_INTERVAL_MS) {
            self.cached_elapsed_ms = metrics_ptr.sampleRates(host.now_ms);
            self.last_sample_ms = host.now_ms;
            self.dirty = true;
        }

        const cache = assets.font_cache orelse return;
        if (self.font_generation != cache.generation) {
            self.font_generation = cache.generation;
            self.dirty = true;
        }

        self.ensureTexture(renderer, cache, host.theme, metrics_ptr) catch return;
        const texture = self.texture orelse return;

        var text_width_f: f32 = 0;
        var text_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &text_width_f, &text_height_f);

        const text_width: c_int = @intFromFloat(text_width_f);
        const text_height: c_int = @intFromFloat(text_height_f);

        const x = host.window_w - text_width - PADDING - BG_PADDING;
        const y = PADDING;

        const bg_rect = c.SDL_FRect{
            .x = @as(f32, @floatFromInt(x - BG_PADDING)),
            .y = @as(f32, @floatFromInt(y - BG_PADDING)),
            .w = @as(f32, @floatFromInt(text_width + BG_PADDING * 2)),
            .h = @as(f32, @floatFromInt(text_height + BG_PADDING * 2)),
        };

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const sel = host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, BG_ALPHA);
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        const acc = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, BORDER_ALPHA);
        _ = c.SDL_RenderRect(renderer, &bg_rect);

        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = text_width_f,
            .h = text_height_f,
        };

        _ = c.SDL_RenderTexture(renderer, texture, null, &dest_rect);
        self.first_frame.markDrawn();
    }

    fn ensureTexture(
        self: *MetricsOverlayComponent,
        renderer: *c.SDL_Renderer,
        cache: *font_cache.FontCache,
        theme: *const @import("../../colors.zig").Theme,
        metrics_ptr: *metrics_mod.Metrics,
    ) !void {
        if (!self.dirty and self.texture != null) return;

        const fonts = try cache.get(OVERLAY_FONT_SIZE);
        const overlay_font = fonts.regular;
        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };

        var line_bufs: [MAX_LINES][MAX_LINE_LENGTH]u8 = undefined;
        var lines: [MAX_LINES][]const u8 = undefined;
        var line_count: usize = 0;

        const frame_count = metrics_ptr.get(.frame_count);
        const cache_size = metrics_ptr.get(.glyph_cache_size);
        const hit_rate = metrics_ptr.getRate(.glyph_cache_hits, self.cached_elapsed_ms);
        const miss_rate = metrics_ptr.getRate(.glyph_cache_misses, self.cached_elapsed_ms);
        const evict_rate = metrics_ptr.getRate(.glyph_cache_evictions, self.cached_elapsed_ms);

        lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Frames: {d}", .{frame_count}) catch "Frames: ?";
        line_count += 1;

        lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Cache size: {d}", .{cache_size}) catch "Cache size: ?";
        line_count += 1;

        lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Hits/s: {d:.1}", .{hit_rate}) catch "Hits/s: ?";
        line_count += 1;

        lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Misses/s: {d:.1}", .{miss_rate}) catch "Misses/s: ?";
        line_count += 1;

        lines[line_count] = std.fmt.bufPrint(&line_bufs[line_count], "Evictions/s: {d:.1}", .{evict_rate}) catch "Evictions/s: ?";
        line_count += 1;

        var max_width: c_int = 0;
        var line_surfaces: [MAX_LINES]?*c.SDL_Surface = [_]?*c.SDL_Surface{null} ** MAX_LINES;
        var line_heights: [MAX_LINES]c_int = undefined;
        defer {
            for (line_surfaces[0..line_count]) |surf_opt| {
                if (surf_opt) |surf| {
                    c.SDL_DestroySurface(surf);
                }
            }
        }

        for (lines[0..line_count], 0..) |line, idx| {
            var render_buf: [MAX_LINE_LENGTH]u8 = undefined;
            @memcpy(render_buf[0..line.len], line);
            render_buf[line.len] = 0;

            const surface = c.TTF_RenderText_Blended(overlay_font, @ptrCast(&render_buf), line.len, fg_color) orelse continue;
            line_surfaces[idx] = surface;
            line_heights[idx] = surface.*.h;
            max_width = @max(max_width, surface.*.w);
        }

        var total_height: c_int = 0;
        for (line_heights[0..line_count]) |h| {
            total_height += h;
        }

        if (max_width == 0 or total_height == 0) return;

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

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *MetricsOverlayComponent = @ptrCast(@alignCast(self_ptr));
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
