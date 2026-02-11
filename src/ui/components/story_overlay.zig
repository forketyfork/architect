const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FullscreenOverlay = @import("fullscreen_overlay.zig").FullscreenOverlay;
const story_parser = @import("../story_parser.zig");

const log = std.log.scoped(.story_overlay);

// === Texture types ===

const SegmentKind = enum {
    text,
    marker,
};

const SegmentTexture = struct {
    tex: *c.SDL_Texture,
    kind: SegmentKind,
    x_offset: c_int,
    w: c_int,
    h: c_int,
};

const LineTexture = struct {
    segments: []SegmentTexture,
};

const TextTex = struct {
    tex: *c.SDL_Texture,
    w: c_int,
    h: c_int,
};

const Cache = struct {
    ui_scale: f32,
    font_generation: u64,
    line_height: c_int,
    char_width: c_int,
    title: TextTex,
    lines: []LineTexture,
    bold_font: *c.TTF_Font,
};

// === Anchor tracking ===

const AnchorPosition = struct {
    number: u8,
    x: c_int,
    y: c_int,
    is_code: bool,
};

// === Component ===

pub const StoryOverlayComponent = struct {
    allocator: std.mem.Allocator,
    overlay: FullscreenOverlay = .{},

    raw_content: ?[]u8 = null,
    display_rows: std.ArrayList(story_parser.DisplayRow) = .{},
    cache: ?*Cache = null,
    file_path: ?[]u8 = null,

    wrap_cols: usize = 0,

    anchor_positions: std.ArrayList(AnchorPosition) = .{},
    hovered_anchor: ?u8 = null,
    hover_start_ms: i64 = 0,

    pointer_cursor: ?*c.SDL_Cursor = null,
    arrow_cursor: ?*c.SDL_Cursor = null,

    const row_height: c_int = 22;
    const font_size: c_int = 13;
    const marker_width: c_int = 20;
    const code_indent: c_int = 8;
    const max_display_buffer: usize = 520;

    pub fn init(allocator: std.mem.Allocator) !*StoryOverlayComponent {
        const comp = try allocator.create(StoryOverlayComponent);
        comp.* = .{
            .allocator = allocator,
            .pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
            .arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
        };
        return comp;
    }

    pub fn asComponent(self: *StoryOverlayComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 1200,
        };
    }

    pub fn show(self: *StoryOverlayComponent, path: []const u8, now_ms: i64) bool {
        self.clearContent();

        const content = self.readFile(path) orelse {
            log.warn("failed to read story file: {s}", .{path});
            return false;
        };
        self.raw_content = content;

        const path_dupe = self.allocator.dupe(u8, path) catch |err| {
            log.warn("failed to duplicate story path: {}", .{err});
            return false;
        };
        if (self.file_path) |old| self.allocator.free(old);
        self.file_path = path_dupe;

        self.display_rows = story_parser.parse(self.allocator, content, self.wrap_cols);

        if (self.display_rows.items.len == 0) {
            log.warn("story file is empty: {s}", .{path});
            return false;
        }

        self.overlay.show(now_ms);
        return true;
    }

    pub fn hide(self: *StoryOverlayComponent, now_ms: i64) void {
        self.overlay.hide(now_ms);
        self.hovered_anchor = null;
        if (self.arrow_cursor) |cur| _ = c.SDL_SetCursor(cur);
    }

    fn readFile(self: *StoryOverlayComponent, path: []const u8) ?[]u8 {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            log.warn("failed to open story file {s}: {}", .{ path, err });
            return null;
        };
        defer file.close();

        const max_size: usize = 4 * 1024 * 1024;
        return file.readToEndAlloc(self.allocator, max_size) catch |err| {
            log.warn("failed to read story file {s}: {}", .{ path, err });
            return null;
        };
    }

    fn clearContent(self: *StoryOverlayComponent) void {
        story_parser.freeDisplayRows(self.allocator, &self.display_rows);

        if (self.raw_content) |content| {
            self.allocator.free(content);
            self.raw_content = null;
        }

        self.destroyCache();
    }

    // --- Event handling ---

    fn handleEventFn(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (!self.overlay.visible) return false;

        if (self.overlay.animation_state == .closing or self.overlay.animation_state == .opening) return true;

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;

                if (key == c.SDLK_ESCAPE) {
                    self.hide(host.now_ms);
                    return true;
                }

                if (self.overlay.handleScrollKey(key, host)) return true;

                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                self.overlay.handleMouseWheel(event.wheel.y);
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);

                if (FullscreenOverlay.isCloseButtonHit(mouse_x, mouse_y, host)) {
                    self.hide(host.now_ms);
                    return true;
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                self.overlay.updateCloseHover(mouse_x, mouse_y, host);
                const prev_hovered = self.hovered_anchor;
                self.updateAnchorHover(mouse_x, mouse_y, host);
                if (self.hovered_anchor != prev_hovered) {
                    const cursor = if (self.hovered_anchor != null) self.pointer_cursor else self.arrow_cursor;
                    if (cursor) |cur| _ = c.SDL_SetCursor(cur);
                }
                return true;
            },
            else => return false,
        }
    }

    fn updateFn(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        _ = self.overlay.updateAnimation(host.now_ms);
    }

    fn hitTestFn(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.hitTest(host, x, y);
    }

    fn wantsFrameFn(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.wantsFrame() or self.hovered_anchor != null;
    }

    // --- Anchor hover ---

    fn updateAnchorHover(self: *StoryOverlayComponent, mouse_x: c_int, mouse_y: c_int, host: *const types.UiHost) void {
        const hit_radius: i64 = if (self.cache) |ch| @as(i64, ch.line_height) else 12;
        const hit_radius_sq: i64 = hit_radius * hit_radius;
        var found: ?u8 = null;

        for (self.anchor_positions.items) |ap| {
            const dx: i64 = @as(i64, mouse_x) - @as(i64, ap.x);
            const dy: i64 = @as(i64, mouse_y) - @as(i64, ap.y);
            if (dx * dx + dy * dy <= hit_radius_sq) {
                found = ap.number;
                break;
            }
        }

        if (found != self.hovered_anchor) {
            self.hovered_anchor = found;
            if (found != null) {
                self.hover_start_ms = host.now_ms;
            }
        }
    }

    // --- Rendering ---

    fn renderFn(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.overlay.visible) return;

        const progress = self.overlay.renderProgress(host.now_ms);
        self.overlay.render_alpha = progress;

        if (progress <= 0.001) return;

        const cache_result = self.ensureCache(renderer, host, assets);
        const cache = cache_result orelse return;

        const rect = FullscreenOverlay.animatedOverlayRect(host, progress);
        const scaled_title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);

        const row_count_f: f32 = @floatFromInt(self.display_rows.items.len);
        const scaled_line_h_f: f32 = @floatFromInt(cache.line_height);
        const content_height: f32 = row_count_f * scaled_line_h_f;
        const viewport_height: f32 = @floatFromInt(rect.h - scaled_title_h);
        self.overlay.max_scroll = @max(0, content_height - viewport_height);
        self.overlay.scroll_offset = @min(self.overlay.max_scroll, self.overlay.scroll_offset);

        self.overlay.renderFrame(renderer, host, rect, progress);
        self.overlay.renderTitle(renderer, rect, cache.title.tex, cache.title.w, cache.title.h, host);
        FullscreenOverlay.renderTitleSeparator(renderer, host, rect, progress);
        self.overlay.renderCloseButton(renderer, host, rect);

        const content_clip = c.SDL_Rect{
            .x = rect.x,
            .y = rect.y + scaled_title_h,
            .w = rect.w,
            .h = rect.h - scaled_title_h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &content_clip);

        self.anchor_positions.clearRetainingCapacity();
        self.renderContent(host, renderer, rect, scaled_title_h, cache);
        self.renderBezierArrows(renderer, host);

        _ = c.SDL_SetRenderClipRect(renderer, null);

        self.overlay.renderScrollbar(renderer, host, rect, scaled_title_h, content_height, viewport_height);

        self.overlay.first_frame.markDrawn();
    }

    fn renderContent(self: *StoryOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, rect: geom.Rect, title_h: c_int, cache: *Cache) void {
        const alpha = self.overlay.render_alpha;
        const scroll_int: c_int = @intFromFloat(self.overlay.scroll_offset);
        const content_top = rect.y + title_h;
        const content_h = rect.h - title_h;

        const line_h = cache.line_height;
        if (line_h <= 0 or content_h <= 0) return;

        const first_visible: usize = @intCast(@divFloor(scroll_int, line_h));
        const fg = host.theme.foreground;
        const accent = host.theme.accent;

        var row_index: usize = first_visible;
        while (row_index < self.display_rows.items.len) : (row_index += 1) {
            const row = self.display_rows.items[row_index];
            const y_pos: c_int = content_top + @as(c_int, @intCast(row_index)) * line_h - scroll_int;

            if (y_pos > content_top + content_h) break;
            if (y_pos + line_h < content_top) continue;

            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            switch (row.kind) {
                .diff_header => {
                    _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, @intFromFloat(20.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(line_h),
                    });
                },
                .diff_line => {
                    switch (row.code_line_kind) {
                        .add => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 0, 80, 0, @intFromFloat(60.0 * alpha));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(rect.w - 2),
                                .h = @floatFromInt(line_h),
                            });
                        },
                        .remove => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 80, 0, 0, @intFromFloat(60.0 * alpha));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(rect.w - 2),
                                .h = @floatFromInt(line_h),
                            });
                        },
                        .context => {},
                    }
                },
                .code_line => {
                    _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, @intFromFloat(8.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(line_h),
                    });
                },
                .separator, .prose_line => {},
            }

            // Render text segments
            if (row_index < cache.lines.len) {
                const line_tex = cache.lines[row_index];
                for (line_tex.segments) |segment| {
                    const tex_alpha: u8 = @intFromFloat(255.0 * alpha);
                    _ = c.SDL_SetTextureAlphaMod(segment.tex, tex_alpha);

                    const dest_x: c_int = rect.x + segment.x_offset;
                    const dest_y: c_int = y_pos;

                    var render_w: c_int = segment.w;
                    const render_h: c_int = segment.h;
                    var clip_src: c.SDL_FRect = undefined;
                    var src_ptr: ?*const c.SDL_FRect = null;

                    const used = dest_x - rect.x;
                    const scaled_padding = dpi.scale(FullscreenOverlay.text_padding, host.ui_scale);
                    const max_width = rect.w - used - scaled_padding;
                    if (max_width <= 0) continue;
                    if (segment.w > max_width) {
                        render_w = max_width;
                        clip_src = c.SDL_FRect{
                            .x = 0,
                            .y = 0,
                            .w = @floatFromInt(render_w),
                            .h = @floatFromInt(render_h),
                        };
                        src_ptr = &clip_src;
                    }

                    _ = c.SDL_RenderTexture(renderer, segment.tex, src_ptr, &c.SDL_FRect{
                        .x = @floatFromInt(dest_x),
                        .y = @floatFromInt(dest_y),
                        .w = @floatFromInt(render_w),
                        .h = @floatFromInt(render_h),
                    });
                }
            }

            // Render anchor circles and track positions for bezier arrows
            if (row.anchors.len > 0 and cache.char_width > 0) {
                const is_code = row.kind == .diff_line or row.kind == .code_line;
                const is_diff = row.kind == .diff_line;
                for (row.anchors) |anc| {
                    const scaled_padding = dpi.scale(FullscreenOverlay.text_padding, host.ui_scale);
                    const scaled_code_indent = dpi.scale(code_indent, host.ui_scale);

                    // For diff lines, the first character (+/-/space) uses a fixed-width
                    // marker slot, not char_width. Account for this offset difference.
                    const char_off: c_int = @intCast(anc.char_offset);
                    const anchor_x: c_int = if (is_diff) blk: {
                        const scaled_marker_w = dpi.scale(marker_width, host.ui_scale);
                        break :blk rect.x + scaled_padding + scaled_code_indent + scaled_marker_w + (char_off - 1) * cache.char_width + @divFloor(cache.char_width, 2);
                    } else if (is_code) blk: {
                        break :blk rect.x + scaled_padding + scaled_code_indent + char_off * cache.char_width + @divFloor(cache.char_width, 2);
                    } else blk: {
                        break :blk rect.x + scaled_padding + char_off * cache.char_width + @divFloor(cache.char_width, 2);
                    };
                    const anchor_y: c_int = y_pos + @divFloor(line_h * 9, 20);
                    const base_radius = @divFloor(line_h * 2, 5);
                    const is_hovered = self.hovered_anchor != null and self.hovered_anchor.? == anc.number;
                    const radius = if (is_hovered) base_radius + dpi.scale(2, host.ui_scale) else base_radius;

                    renderAnchorBadge(renderer, host, anchor_x, anchor_y, radius, anc.number, alpha, cache.bold_font);

                    self.anchor_positions.append(self.allocator, .{
                        .number = anc.number,
                        .x = anchor_x,
                        .y = anchor_y,
                        .is_code = is_code,
                    }) catch |err| {
                        log.warn("failed to track anchor position: {}", .{err});
                    };
                }
            }
        }
    }

    fn renderAnchorBadge(renderer: *c.SDL_Renderer, host: *const types.UiHost, cx: c_int, cy: c_int, half_h: c_int, number: u8, alpha: f32, font: *c.TTF_Font) void {
        // Render the number as text to get its dimensions
        var num_buf: [4]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{number}) catch return;
        num_buf[num_str.len] = 0;
        const num_z: [*c]const u8 = @ptrCast(num_str.ptr);

        const bg = host.theme.background;
        const surface = c.TTF_RenderText_Blended(font, num_z, num_str.len, c.SDL_Color{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 255 }) orelse return;
        defer c.SDL_DestroySurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(tex);

        var tex_w_f: f32 = 0;
        var tex_h_f: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &tex_w_f, &tex_h_f);
        const tex_w: c_int = @intFromFloat(tex_w_f);
        const tex_h: c_int = @intFromFloat(tex_h_f);

        // Pill dimensions: height = 2 * half_h, width stretches to fit text + padding
        const pad_x: c_int = @max(half_h, @divFloor(tex_w, 2) + @divFloor(half_h, 2));
        const pill_w = pad_x * 2;
        const pill_h = half_h * 2;
        const pill_x = cx - @divFloor(pill_w, 2);
        const pill_y = cy - half_h;
        const corner_r: c_int = half_h;

        // Draw the pill background
        const accent = host.theme.accent;
        const bg_alpha: u8 = @intFromFloat(200.0 * alpha);
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, bg_alpha);
        primitives.fillRoundedRect(renderer, .{ .x = pill_x, .y = pill_y, .w = pill_w, .h = pill_h }, corner_r);

        // Draw the number text centered in the pill
        const tex_alpha: u8 = @intFromFloat(255.0 * alpha);
        _ = c.SDL_SetTextureAlphaMod(tex, tex_alpha);
        _ = c.SDL_RenderTexture(renderer, tex, null, &c.SDL_FRect{
            .x = @floatFromInt(cx - @divFloor(tex_w, 2)),
            .y = @floatFromInt(cy - @divFloor(tex_h, 2)),
            .w = @floatFromInt(tex_w),
            .h = @floatFromInt(tex_h),
        });
    }

    fn renderBezierArrows(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost) void {
        const hovered = self.hovered_anchor orelse return;

        var prose_pos: ?AnchorPosition = null;
        var code_pos: ?AnchorPosition = null;

        for (self.anchor_positions.items) |ap| {
            if (ap.number == hovered) {
                if (ap.is_code) {
                    code_pos = ap;
                } else {
                    prose_pos = ap;
                }
            }
        }

        const from = prose_pos orelse return;
        const to = code_pos orelse return;

        const elapsed_ms = host.now_ms - self.hover_start_ms;
        const time_seconds: f32 = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;

        primitives.renderBezierArrow(
            renderer,
            @floatFromInt(from.x),
            @floatFromInt(from.y),
            @floatFromInt(to.x),
            @floatFromInt(to.y),
            host.theme.accent,
            time_seconds,
        );
    }

    // --- Cache management ---

    fn ensureCache(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets) ?*Cache {
        const font_cache_ptr = assets.font_cache orelse return null;
        const generation = font_cache_ptr.generation;

        if (self.cache) |existing| {
            if (existing.ui_scale == host.ui_scale and existing.font_generation == generation) {
                return existing;
            }
        }

        self.destroyCache();

        const scaled_font_size = dpi.scale(font_size, host.ui_scale);
        const title_font_size = scaled_font_size + dpi.scale(4, host.ui_scale);
        const line_fonts = font_cache_ptr.get(scaled_font_size) catch return null;
        const title_fonts = font_cache_ptr.get(title_font_size) catch return null;

        const mono_font = line_fonts.regular;
        const bold_font = line_fonts.bold orelse line_fonts.regular;

        const char_w = measureCharWidth(renderer, mono_font) orelse 0;
        self.updateWrapCols(renderer, host, mono_font);

        const title_text_str = self.buildTitleText() catch return null;
        defer self.allocator.free(title_text_str);
        const title_tex = self.makeTextTexture(
            renderer,
            title_fonts.bold orelse title_fonts.regular,
            title_text_str,
            host.theme.foreground,
        ) catch return null;

        const line_height_scaled = dpi.scale(row_height, host.ui_scale);
        const line_textures = self.allocator.alloc(LineTexture, self.display_rows.items.len) catch {
            c.SDL_DestroyTexture(title_tex.tex);
            return null;
        };

        var idx: usize = 0;
        while (idx < self.display_rows.items.len) : (idx += 1) {
            line_textures[idx] = self.buildLineTexture(renderer, host, mono_font, bold_font, self.display_rows.items[idx]) catch |err| blk: {
                log.warn("failed to build story line texture: {}", .{err});
                break :blk LineTexture{ .segments = &.{} };
            };
        }

        const new_cache = self.allocator.create(Cache) catch {
            self.destroyLineTextures(line_textures);
            c.SDL_DestroyTexture(title_tex.tex);
            self.allocator.free(line_textures);
            return null;
        };
        new_cache.* = .{
            .ui_scale = host.ui_scale,
            .font_generation = generation,
            .line_height = line_height_scaled,
            .char_width = char_w,
            .title = title_tex,
            .lines = line_textures,
            .bold_font = bold_font,
        };
        self.cache = new_cache;
        return new_cache;
    }

    fn updateWrapCols(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, mono_font: *c.TTF_Font) void {
        const char_w = measureCharWidth(renderer, mono_font) orelse return;
        if (char_w <= 0) return;

        const rect = FullscreenOverlay.overlayRect(host);
        const scaled_padding = dpi.scale(FullscreenOverlay.text_padding, host.ui_scale);
        const scrollbar_w = dpi.scale(10, host.ui_scale);
        const text_area_w = rect.w - scaled_padding * 2 - scrollbar_w;
        if (text_area_w <= 0) return;

        const new_wrap: usize = @intCast(@divFloor(text_area_w, char_w));
        if (new_wrap != self.wrap_cols and new_wrap > 0) {
            self.wrap_cols = new_wrap;
            if (self.raw_content) |content| {
                story_parser.freeDisplayRows(self.allocator, &self.display_rows);
                self.display_rows = story_parser.parse(self.allocator, content, self.wrap_cols);
            }
        }
    }

    fn measureCharWidth(renderer: *c.SDL_Renderer, font: *c.TTF_Font) ?c_int {
        const probe = "0";
        var buf: [2]u8 = .{ probe[0], 0 };
        const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), 1, c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 }) orelse return null;
        defer c.SDL_DestroySurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return null;
        defer c.SDL_DestroyTexture(tex);
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &w, &h);
        return @intFromFloat(w);
    }

    fn buildTitleText(self: *StoryOverlayComponent) ![]const u8 {
        const prefix = "Story";
        const file_path = self.file_path orelse return self.allocator.dupe(u8, prefix);
        const base = std.fs.path.basename(file_path);

        const max_len: usize = 120;
        if (prefix.len + 3 + base.len <= max_len) {
            return std.fmt.allocPrint(self.allocator, "{s} \xe2\x80\x94 {s}", .{ prefix, base });
        }

        if (max_len <= prefix.len + 3) {
            return self.allocator.dupe(u8, prefix);
        }

        const tail_len = max_len - prefix.len - 3;
        const tail = base[base.len - tail_len ..];
        return std.fmt.allocPrint(self.allocator, "{s} \xe2\x80\x94 ...{s}", .{ prefix, tail });
    }

    fn buildLineTexture(
        self: *StoryOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        mono_font: *c.TTF_Font,
        bold_font: *c.TTF_Font,
        d_row: story_parser.DisplayRow,
    ) !LineTexture {
        var segments = try std.ArrayList(SegmentTexture).initCapacity(self.allocator, 2);
        errdefer {
            for (segments.items) |segment| {
                c.SDL_DestroyTexture(segment.tex);
            }
            segments.deinit(self.allocator);
        }

        const scaled_padding = dpi.scale(FullscreenOverlay.text_padding, host.ui_scale);
        const scaled_marker_w = dpi.scale(marker_width, host.ui_scale);
        const scaled_code_indent = dpi.scale(code_indent, host.ui_scale);
        const fg = host.theme.foreground;

        switch (d_row.kind) {
            .separator => {},
            .prose_line => {
                if (d_row.text.len == 0) return LineTexture{ .segments = &.{} };
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(d_row.text, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                const font = if (d_row.bold) bold_font else mono_font;
                try self.appendSegmentTexture(&segments, renderer, font, text, fg, .text, scaled_padding);
            },
            .diff_header => {
                if (d_row.text.len == 0) return LineTexture{ .segments = &.{} };
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(d_row.text, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                try self.appendSegmentTexture(&segments, renderer, bold_font, text, host.theme.accent, .text, scaled_padding + scaled_code_indent);
            },
            .diff_line => {
                const marker_str: []const u8 = switch (d_row.code_line_kind) {
                    .add => "+",
                    .remove => "-",
                    .context => " ",
                };
                const marker_color: c.SDL_Color = switch (d_row.code_line_kind) {
                    .add => host.theme.palette[2],
                    .remove => host.theme.palette[1],
                    .context => fg,
                };

                try self.appendSegmentTexture(&segments, renderer, mono_font, marker_str, marker_color, .marker, scaled_padding + scaled_code_indent);

                const text_slice = if (d_row.text.len > 1) d_row.text[1..] else "";
                if (text_slice.len > 0) {
                    var buf: [max_display_buffer]u8 = undefined;
                    const text = sanitizeText(text_slice, &buf);
                    if (text.len > 0) {
                        const text_color: c.SDL_Color = switch (d_row.code_line_kind) {
                            .add => host.theme.palette[2],
                            .remove => host.theme.palette[1],
                            .context => fg,
                        };
                        try self.appendSegmentTexture(&segments, renderer, mono_font, text, text_color, .text, scaled_padding + scaled_code_indent + scaled_marker_w);
                    }
                }
            },
            .code_line => {
                if (d_row.text.len == 0) return LineTexture{ .segments = &.{} };
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(d_row.text, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                try self.appendSegmentTexture(&segments, renderer, mono_font, text, fg, .text, scaled_padding + scaled_code_indent);
            },
        }

        return LineTexture{ .segments = try segments.toOwnedSlice(self.allocator) };
    }

    fn appendSegmentTexture(
        self: *StoryOverlayComponent,
        segments: *std.ArrayList(SegmentTexture),
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
        kind: SegmentKind,
        x_offset: c_int,
    ) !void {
        if (text.len == 0) return;
        const tex = try self.makeTextTexture(renderer, font, text, color);
        errdefer c.SDL_DestroyTexture(tex.tex);
        try segments.append(self.allocator, .{
            .tex = tex.tex,
            .kind = kind,
            .x_offset = x_offset,
            .w = tex.w,
            .h = tex.h,
        });
    }

    fn makeTextTexture(
        self: *StoryOverlayComponent,
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
    ) !TextTex {
        if (text.len == 0) return error.EmptyText;

        var buf: [128]u8 = undefined;
        var surface: *c.SDL_Surface = undefined;
        if (text.len < buf.len) {
            @memcpy(buf[0..text.len], text);
            buf[text.len] = 0;
            surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), @intCast(text.len), color) orelse return error.SurfaceFailed;
        } else {
            const heap_buf = try self.allocator.alloc(u8, text.len + 1);
            defer self.allocator.free(heap_buf);
            @memcpy(heap_buf[0..text.len], text);
            heap_buf[text.len] = 0;
            surface = c.TTF_RenderText_Blended(font, @ptrCast(heap_buf.ptr), @intCast(text.len), color) orelse return error.SurfaceFailed;
        }
        defer c.SDL_DestroySurface(surface);

        const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &w, &h);
        _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
        return TextTex{
            .tex = tex,
            .w = @intFromFloat(w),
            .h = @intFromFloat(h),
        };
    }

    fn sanitizeText(text: []const u8, buf: []u8) []const u8 {
        const max_chars: usize = 512;
        const display_len = @min(text.len, max_chars);
        var buf_pos: usize = 0;

        for (text[0..display_len]) |ch| {
            if (ch == '\t') {
                if (buf_pos + 1 >= buf.len) break;
                const remaining = buf.len - buf_pos - 1;
                const spaces_to_add = @min(4, remaining);
                var idx: usize = 0;
                while (idx < spaces_to_add) : (idx += 1) {
                    buf[buf_pos] = ' ';
                    buf_pos += 1;
                }
            } else if (ch >= 32 or ch == 0) {
                if (buf_pos + 1 >= buf.len) break;
                buf[buf_pos] = ch;
                buf_pos += 1;
            }
        }

        return buf[0..buf_pos];
    }

    fn destroyCache(self: *StoryOverlayComponent) void {
        const cache_ptr = self.cache orelse return;
        c.SDL_DestroyTexture(cache_ptr.title.tex);
        self.destroyLineTextures(cache_ptr.lines);
        self.allocator.free(cache_ptr.lines);
        self.allocator.destroy(cache_ptr);
        self.cache = null;
    }

    fn destroyLineTextures(self: *StoryOverlayComponent, lines: []LineTexture) void {
        for (lines) |line| {
            for (line.segments) |segment| {
                c.SDL_DestroyTexture(segment.tex);
            }
            if (line.segments.len > 0) {
                self.allocator.free(line.segments);
            }
        }
    }

    // --- Deinit ---

    fn destroy(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.clearContent();
        self.display_rows.deinit(self.allocator);
        self.anchor_positions.deinit(self.allocator);
        if (self.file_path) |path| {
            self.allocator.free(path);
            self.file_path = null;
        }
        if (self.pointer_cursor) |cur| c.SDL_DestroyCursor(cur);
        if (self.arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
        self.allocator.destroy(self);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEventFn,
        .hitTest = hitTestFn,
        .update = updateFn,
        .render = renderFn,
        .deinit = deinitComp,
        .wantsFrame = wantsFrameFn,
    };
};
