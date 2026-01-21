const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const font_cache = @import("../../font_cache.zig");
const renderer_mod = @import("../../render/renderer.zig");
const dpi = @import("../scale.zig");
const input = @import("../../input/mapper.zig");
const colors = @import("../../colors.zig");

const Rect = geom.Rect;

const CWD_BAR_HEIGHT: c_int = 24;
const CWD_FONT_SIZE: c_int = 12;
const CWD_PADDING: c_int = 8;
const MARQUEE_SPEED: f32 = 30.0;
const FADE_WIDTH: c_int = 20;

pub fn reservedHeight(ui_scale: f32) c_int {
    return dpi.scale(CWD_BAR_HEIGHT, ui_scale) + renderer_mod.GRID_BORDER_THICKNESS;
}

pub fn minCellHeight(ui_scale: f32) c_int {
    return reservedHeight(ui_scale) + 1;
}

pub const CwdBarComponent = struct {
    allocator: std.mem.Allocator,
    font_generation: u64 = 0,
    session_caches: []SessionCache = &.{},
    max_sessions: usize = 0,

    const SessionCache = struct {
        basename_tex: ?*c.SDL_Texture = null,
        parent_tex: ?*c.SDL_Texture = null,
        basename_w: c_int = 0,
        basename_h: c_int = 0,
        parent_w: c_int = 0,
        parent_h: c_int = 0,
        cached_path: ?[]const u8 = null,
        font_size: c_int = 0,

        fn deinit(self: *SessionCache, allocator: std.mem.Allocator) void {
            if (self.basename_tex) |tex| {
                c.SDL_DestroyTexture(tex);
                self.basename_tex = null;
            }
            if (self.parent_tex) |tex| {
                c.SDL_DestroyTexture(tex);
                self.parent_tex = null;
            }
            if (self.cached_path) |path| {
                allocator.free(path);
                self.cached_path = null;
            }
            self.basename_w = 0;
            self.basename_h = 0;
            self.parent_w = 0;
            self.parent_h = 0;
            self.font_size = 0;
        }

        fn invalidate(self: *SessionCache, allocator: std.mem.Allocator) void {
            if (self.basename_tex) |tex| {
                c.SDL_DestroyTexture(tex);
                self.basename_tex = null;
            }
            if (self.parent_tex) |tex| {
                c.SDL_DestroyTexture(tex);
                self.parent_tex = null;
            }
            if (self.cached_path) |path| {
                allocator.free(path);
                self.cached_path = null;
            }
            self.basename_w = 0;
            self.basename_h = 0;
            self.parent_w = 0;
            self.parent_h = 0;
        }
    };

    pub fn init(allocator: std.mem.Allocator) !*CwdBarComponent {
        const self = try allocator.create(CwdBarComponent);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn asComponent(self: *CwdBarComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 50,
        };
    }

    pub fn destroy(self: *CwdBarComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        for (self.session_caches) |*cache| {
            cache.deinit(self.allocator);
        }
        if (self.session_caches.len > 0) {
            self.allocator.free(self.session_caches);
        }
        self.allocator.destroy(self);
    }

    fn ensureCacheCapacity(self: *CwdBarComponent, count: usize) !void {
        if (count <= self.max_sessions) return;

        const new_caches = try self.allocator.alloc(SessionCache, count);
        @memset(new_caches, SessionCache{});

        if (self.session_caches.len > 0) {
            @memcpy(new_caches[0..self.session_caches.len], self.session_caches);
            self.allocator.free(self.session_caches);
        }

        self.session_caches = new_caches;
        self.max_sessions = count;
    }

    fn handleEvent(_: *anyopaque, _: *const types.UiHost, _: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        return false;
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *CwdBarComponent = @ptrCast(@alignCast(self_ptr));

        const cache = assets.font_cache orelse return;
        if (self.font_generation != cache.generation) {
            self.font_generation = cache.generation;
            for (self.session_caches) |*sc| {
                sc.invalidate(self.allocator);
            }
        }

        self.ensureCacheCapacity(host.sessions.len) catch return;

        // CWD bar is only shown in Grid view (not full view or during animations)
        if (host.view_mode != .Grid) return;

        for (host.sessions, 0..) |info, i| {
            if (!info.spawned) continue;
            const grid_row: c_int = @intCast(i / host.grid_cols);
            const grid_col: c_int = @intCast(i % host.grid_cols);
            const cell_rect = Rect{
                .x = grid_col * host.cell_w,
                .y = grid_row * host.cell_h,
                .w = host.cell_w,
                .h = host.cell_h,
            };
            self.renderCwdBar(renderer, i, info, cell_rect, host, cache, i);
        }
    }

    fn renderCwdBar(
        self: *CwdBarComponent,
        renderer: *c.SDL_Renderer,
        session_idx: usize,
        info: types.SessionUiInfo,
        rect: Rect,
        host: *const types.UiHost,
        cache: *font_cache.FontCache,
        grid_index: ?usize,
    ) void {
        const cwd_path = info.cwd_path orelse return;
        const cwd_basename = info.cwd_basename orelse return;

        const bar_height = dpi.scale(CWD_BAR_HEIGHT, host.ui_scale);
        const border_thickness = renderer_mod.GRID_BORDER_THICKNESS;
        const padding = dpi.scale(CWD_PADDING, host.ui_scale);
        const fade_width = dpi.scale(FADE_WIDTH, host.ui_scale);

        if (rect.w <= border_thickness * 2 or rect.h <= bar_height + border_thickness) return;

        const bar_rect = Rect{
            .x = rect.x + border_thickness,
            .y = rect.y + rect.h - bar_height - border_thickness,
            .w = rect.w - border_thickness * 2,
            .h = bar_height,
        };

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const sel = host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 230);
        const bg_rect = c.SDL_FRect{
            .x = @floatFromInt(bar_rect.x),
            .y = @floatFromInt(bar_rect.y),
            .w = @floatFromInt(bar_rect.w),
            .h = @floatFromInt(bar_rect.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        const font_px = dpi.scale(CWD_FONT_SIZE, host.ui_scale);
        const fonts = cache.get(font_px) catch return;
        const cwd_font = fonts.regular;

        const fg = host.theme.foreground;
        const dimmed_fg = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 180 };

        var hotkey_width: c_int = 0;
        if (grid_index) |gi| {
            if (input.terminalHotkeyLabel(gi)) |hotkey_str| {
                const hotkey_surface = c.TTF_RenderText_Blended(cwd_font, hotkey_str.ptr, hotkey_str.len, dimmed_fg) orelse return;
                defer c.SDL_DestroySurface(hotkey_surface);

                const hotkey_texture = c.SDL_CreateTextureFromSurface(renderer, hotkey_surface) orelse return;
                defer c.SDL_DestroyTexture(hotkey_texture);

                var hotkey_w_f: f32 = 0;
                var hotkey_h_f: f32 = 0;
                _ = c.SDL_GetTextureSize(hotkey_texture, &hotkey_w_f, &hotkey_h_f);
                hotkey_width = @intFromFloat(hotkey_w_f);
                const hotkey_height: c_int = @intFromFloat(hotkey_h_f);

                const hotkey_x = bar_rect.x + bar_rect.w - hotkey_width - padding;
                const hotkey_y = bar_rect.y + @divFloor(bar_rect.h - hotkey_height, 2);

                _ = c.SDL_RenderTexture(renderer, hotkey_texture, null, &c.SDL_FRect{
                    .x = @floatFromInt(hotkey_x),
                    .y = @floatFromInt(hotkey_y),
                    .w = hotkey_w_f,
                    .h = hotkey_h_f,
                });
            }
        }

        const text_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const hotkey_extra_padding: c_int = if (hotkey_width > 0) padding else 0;
        const content_right_edge = bar_rect.x + bar_rect.w - hotkey_width - padding - hotkey_extra_padding;

        var basename_with_slash_buf: [std.fs.max_path_bytes]u8 = undefined;
        const basename_with_slash = blk: {
            if (std.mem.eql(u8, cwd_basename, "/")) {
                break :blk cwd_basename;
            }
            if (cwd_basename.len + 1 > basename_with_slash_buf.len) {
                return;
            }
            @memcpy(basename_with_slash_buf[0..cwd_basename.len], cwd_basename);
            basename_with_slash_buf[cwd_basename.len] = '/';
            break :blk basename_with_slash_buf[0 .. cwd_basename.len + 1];
        };

        var sc = &self.session_caches[session_idx];

        const path_changed = if (sc.cached_path) |cp| !std.mem.eql(u8, cp, cwd_path) else true;
        const font_changed = sc.font_size != font_px;

        if (path_changed or font_changed or sc.basename_tex == null) {
            sc.invalidate(self.allocator);
            sc.font_size = font_px;
            sc.cached_path = self.allocator.dupe(u8, cwd_path) catch null;

            const basename_surface = c.TTF_RenderText_Blended(cwd_font, basename_with_slash.ptr, basename_with_slash.len, text_color) orelse return;
            defer c.SDL_DestroySurface(basename_surface);

            const basename_texture = c.SDL_CreateTextureFromSurface(renderer, basename_surface) orelse return;

            var basename_width_f: f32 = 0;
            var basename_height_f: f32 = 0;
            _ = c.SDL_GetTextureSize(basename_texture, &basename_width_f, &basename_height_f);

            sc.basename_tex = basename_texture;
            sc.basename_w = @intFromFloat(basename_width_f);
            sc.basename_h = @intFromFloat(basename_height_f);
        }

        const basename_texture = sc.basename_tex orelse return;
        const basename_width: c_int = sc.basename_w;
        const text_height: c_int = sc.basename_h;
        const basename_width_f: f32 = @floatFromInt(basename_width);
        const basename_height_f: f32 = @floatFromInt(text_height);

        const basename_x = content_right_edge - basename_width;
        const text_y = bar_rect.y + @divFloor(bar_rect.h - text_height, 2);

        _ = c.SDL_RenderTexture(renderer, basename_texture, null, &c.SDL_FRect{
            .x = @floatFromInt(basename_x),
            .y = @floatFromInt(text_y),
            .w = basename_width_f,
            .h = basename_height_f,
        });

        var parent_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const parent_path = blk: {
            if (cwd_path.len <= cwd_basename.len) return;

            const parent_without_slash = cwd_path[0 .. cwd_path.len - cwd_basename.len];
            if (parent_without_slash.len == 0) return;

            if (parent_without_slash[parent_without_slash.len - 1] == '/') {
                break :blk parent_without_slash;
            } else {
                if (parent_without_slash.len + 1 > parent_path_buf.len) {
                    return;
                }
                @memcpy(parent_path_buf[0..parent_without_slash.len], parent_without_slash);
                parent_path_buf[parent_without_slash.len] = '/';
                break :blk parent_path_buf[0 .. parent_without_slash.len + 1];
            }
        };

        if (path_changed or font_changed or sc.parent_tex == null) {
            if (sc.parent_tex) |tex| {
                c.SDL_DestroyTexture(tex);
                sc.parent_tex = null;
            }
            sc.parent_w = 0;
            sc.parent_h = 0;

            const parent_surface = c.TTF_RenderText_Blended(cwd_font, parent_path.ptr, parent_path.len, text_color) orelse return;
            defer c.SDL_DestroySurface(parent_surface);

            const parent_texture = c.SDL_CreateTextureFromSurface(renderer, parent_surface) orelse return;

            var parent_width_f: f32 = 0;
            var parent_height_f: f32 = 0;
            _ = c.SDL_GetTextureSize(parent_texture, &parent_width_f, &parent_height_f);

            sc.parent_tex = parent_texture;
            sc.parent_w = @intFromFloat(parent_width_f);
            sc.parent_h = @intFromFloat(parent_height_f);
        }

        const parent_texture = sc.parent_tex orelse return;
        const parent_width: c_int = sc.parent_w;
        const parent_height: c_int = sc.parent_h;
        const parent_width_f: f32 = @floatFromInt(parent_width);
        const parent_height_f: f32 = @floatFromInt(parent_height);

        const available_width = basename_x - bar_rect.x - padding;
        if (available_width <= 0) return;

        if (parent_width <= available_width) {
            const parent_x = basename_x - parent_width;
            _ = c.SDL_RenderTexture(renderer, parent_texture, null, &c.SDL_FRect{
                .x = @floatFromInt(parent_x),
                .y = @floatFromInt(text_y),
                .w = parent_width_f,
                .h = parent_height_f,
            });
        } else {
            const clip_rect = c.SDL_Rect{
                .x = bar_rect.x + padding,
                .y = bar_rect.y,
                .w = available_width,
                .h = bar_rect.h,
            };
            _ = c.SDL_SetRenderClipRect(renderer, &clip_rect);

            const scroll_range = parent_width - available_width;
            const scroll_range_f: f32 = @floatFromInt(scroll_range);
            const idle_ms: f32 = 1000.0;
            const scroll_ms: f32 = scroll_range_f / MARQUEE_SPEED * 1000.0;
            const cycle_ms: f32 = idle_ms * 2.0 + scroll_ms;
            const cycle_ms_i64: i64 = @max(1, @as(i64, @intFromFloat(std.math.ceil(cycle_ms))));
            const elapsed_ms: f32 = @floatFromInt(@mod(host.now_ms, cycle_ms_i64));

            const scroll_offset: c_int = calc_scroll: {
                if (elapsed_ms < idle_ms) break :calc_scroll 0;
                if (elapsed_ms < idle_ms + scroll_ms) {
                    const progress = (elapsed_ms - idle_ms) / scroll_ms;
                    break :calc_scroll @intFromFloat(progress * scroll_range_f);
                }
                break :calc_scroll scroll_range;
            };

            const parent_x = basename_x - parent_width + scroll_offset;
            _ = c.SDL_RenderTexture(renderer, parent_texture, null, &c.SDL_FRect{
                .x = @floatFromInt(parent_x),
                .y = @floatFromInt(text_y),
                .w = parent_width_f,
                .h = parent_height_f,
            });

            _ = c.SDL_SetRenderClipRect(renderer, null);

            const fade_left = scroll_offset < scroll_range;
            const fade_right = scroll_offset > 0;

            if (fade_left) {
                renderFadeGradient(renderer, bar_rect, true, fade_width, padding, host.theme);
            }
            if (fade_right) {
                const visible_end_x = bar_rect.x + padding + available_width;
                const fade_rect = Rect{
                    .x = bar_rect.x,
                    .y = bar_rect.y,
                    .w = visible_end_x - bar_rect.x,
                    .h = bar_rect.h,
                };
                renderFadeGradient(renderer, fade_rect, false, fade_width, padding, host.theme);
            }
        }
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *CwdBarComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};

fn renderFadeGradient(renderer: *c.SDL_Renderer, bar_rect: Rect, is_left: bool, fade_width: c_int, padding: c_int, theme: *const colors.Theme) void {
    const sel = theme.selection;
    const base_color = c.SDL_FColor{
        .r = @as(f32, @floatFromInt(sel.r)) / 255.0,
        .g = @as(f32, @floatFromInt(sel.g)) / 255.0,
        .b = @as(f32, @floatFromInt(sel.b)) / 255.0,
        .a = 230.0 / 255.0,
    };
    const transparent = c.SDL_FColor{ .r = base_color.r, .g = base_color.g, .b = base_color.b, .a = 0.0 };

    const y1: f32 = @floatFromInt(bar_rect.y);
    const y2: f32 = @floatFromInt(bar_rect.y + bar_rect.h);

    if (is_left) {
        const x_start: f32 = @floatFromInt(bar_rect.x + padding);
        const x_end: f32 = @floatFromInt(bar_rect.x + padding + fade_width);

        const verts = [_]c.SDL_Vertex{
            .{ .position = .{ .x = x_start, .y = y1 }, .color = base_color },
            .{ .position = .{ .x = x_end, .y = y1 }, .color = transparent },
            .{ .position = .{ .x = x_start, .y = y2 }, .color = base_color },
            .{ .position = .{ .x = x_end, .y = y2 }, .color = transparent },
        };
        const indices = [_]c_int{ 0, 1, 2, 1, 3, 2 };
        _ = c.SDL_RenderGeometry(renderer, null, &verts, verts.len, &indices, indices.len);
    } else {
        const x_start: f32 = @floatFromInt(bar_rect.x + bar_rect.w - fade_width);
        const x_end: f32 = @floatFromInt(bar_rect.x + bar_rect.w);

        const verts = [_]c.SDL_Vertex{
            .{ .position = .{ .x = x_start, .y = y1 }, .color = transparent },
            .{ .position = .{ .x = x_end, .y = y1 }, .color = base_color },
            .{ .position = .{ .x = x_start, .y = y2 }, .color = transparent },
            .{ .position = .{ .x = x_end, .y = y2 }, .color = base_color },
        };
        const indices = [_]c_int{ 0, 1, 2, 1, 3, 2 };
        _ = c.SDL_RenderGeometry(renderer, null, &verts, verts.len, &indices, indices.len);
    }
}
