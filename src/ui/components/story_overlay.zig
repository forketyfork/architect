const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FullscreenOverlay = @import("fullscreen_overlay.zig").FullscreenOverlay;
const font_cache_mod = @import("../../font_cache.zig");
const open_url = @import("../../os/open.zig");
const markdown_parser = @import("markdown_parser.zig");
const markdown_renderer = @import("markdown_renderer.zig");
const scrollbar = @import("scrollbar.zig");

const log = std.log.scoped(.story_overlay);

const FontCache = font_cache_mod.FontCache;
const FontSet = font_cache_mod.FontSet;

const SearchMatch = struct {
    line_index: usize,
    start: usize,
    len: usize,
};

const LinkHit = struct {
    rect: geom.Rect,
    href: []const u8,
};

const TextTex = struct {
    tex: *c.SDL_Texture,
    w: c_int,
    h: c_int,
};

const DrawSize = struct {
    w: c_int,
    h: c_int,
};

const AnchorPosition = struct {
    number: u8,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    is_code: bool,
};

pub const StoryOverlayComponent = struct {
    allocator: std.mem.Allocator,
    overlay: FullscreenOverlay = .{},
    scrollbar_state: scrollbar.State = .{},

    raw_content: ?[]u8 = null,
    blocks: std.ArrayList(markdown_parser.DisplayBlock) = .{},
    lines: std.ArrayList(markdown_renderer.RenderLine) = .{},
    file_path: ?[]u8 = null,

    wrap_cols: usize = 0,

    anchor_positions: std.ArrayList(AnchorPosition) = .{},
    hovered_anchor: ?u8 = null,
    hover_start_ms: i64 = 0,

    search_active: bool = false,
    search_query: std.ArrayList(u8) = .{},
    matches: std.ArrayList(SearchMatch) = .{},
    selected_match: ?usize = null,

    link_hits: std.ArrayList(LinkHit) = .{},
    hovered_link: ?usize = null,

    pointer_cursor: ?*c.SDL_Cursor = null,
    arrow_cursor: ?*c.SDL_Cursor = null,

    const row_height: c_int = 22;
    const base_font_size: c_int = 14;
    const code_font_size: c_int = 13;
    const marker_width: c_int = 20;
    const code_indent: c_int = 8;

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

        self.parseAndBuildLines();

        if (self.lines.items.len == 0) {
            log.warn("story file is empty: {s}", .{path});
            return false;
        }

        self.overlay.show(now_ms);
        return true;
    }

    pub fn hide(self: *StoryOverlayComponent, now_ms: i64) void {
        self.overlay.hide(now_ms);
        self.scrollbar_state.hideNow();
        self.hovered_anchor = null;
        self.search_active = false;
        self.selected_match = null;
        self.clearLinkHits();
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

    fn parseAndBuildLines(self: *StoryOverlayComponent) void {
        markdown_parser.freeBlocks(self.allocator, &self.blocks);
        self.blocks = markdown_parser.parseStory(self.allocator, self.raw_content orelse "") catch |err| {
            log.warn("failed to parse story markdown: {}", .{err});
            self.blocks = .{};
            return;
        };

        self.rebuildLines();
    }

    fn rebuildLines(self: *StoryOverlayComponent) void {
        self.clearLinkHits();
        markdown_renderer.freeLines(self.allocator, &self.lines);
        const effective_wrap = if (self.wrap_cols > 0) self.wrap_cols else 120;
        self.lines = markdown_renderer.buildLines(self.allocator, self.blocks.items, effective_wrap) catch |err| {
            log.warn("failed to build story layout: {}", .{err});
            self.lines = .{};
            return;
        };
        self.rebuildSearchMatches();
    }

    fn clearContent(self: *StoryOverlayComponent) void {
        if (self.raw_content) |content| {
            self.allocator.free(content);
            self.raw_content = null;
        }
        self.clearLinkHits();
        markdown_parser.freeBlocks(self.allocator, &self.blocks);
        markdown_renderer.freeLines(self.allocator, &self.lines);
    }

    fn clearLinkHits(self: *StoryOverlayComponent) void {
        self.link_hits.clearRetainingCapacity();
        self.hovered_link = null;
    }

    // --- Search ---

    fn rebuildSearchMatches(self: *StoryOverlayComponent) void {
        self.matches.clearRetainingCapacity();

        const query = std.mem.trim(u8, self.search_query.items, " \t");
        if (query.len == 0) {
            self.selected_match = null;
            return;
        }

        for (self.lines.items, 0..) |line, line_idx| {
            if (line.kind == .blank or line.kind == .horizontal_rule) continue;

            var pos: usize = 0;
            while (findCaseInsensitive(line.plain_text, query, pos)) |found| {
                self.matches.append(self.allocator, .{
                    .line_index = line_idx,
                    .start = found,
                    .len = query.len,
                }) catch |err| {
                    log.warn("failed to append search match: {}", .{err});
                    return;
                };
                pos = found + 1;
            }
        }

        if (self.matches.items.len == 0) {
            self.selected_match = null;
            return;
        }

        if (self.selected_match) |idx| {
            if (idx >= self.matches.items.len) {
                self.selected_match = 0;
            }
        } else {
            self.selected_match = 0;
        }
    }

    fn findCaseInsensitive(haystack: []const u8, needle: []const u8, from: usize) ?usize {
        if (needle.len == 0 or haystack.len < needle.len or from >= haystack.len) return null;

        var pos = from;
        while (pos + needle.len <= haystack.len) : (pos += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[pos .. pos + needle.len], needle)) {
                return pos;
            }
        }
        return null;
    }

    fn nextMatch(self: *StoryOverlayComponent, host: *const types.UiHost) void {
        if (self.matches.items.len == 0) return;
        const next_idx = if (self.selected_match) |idx| (idx + 1) % self.matches.items.len else 0;
        self.selected_match = next_idx;
        self.scrollToMatch(host, next_idx);
    }

    fn prevMatch(self: *StoryOverlayComponent, host: *const types.UiHost) void {
        if (self.matches.items.len == 0) return;
        const prev_idx = if (self.selected_match) |idx|
            if (idx == 0) self.matches.items.len - 1 else idx - 1
        else
            0;
        self.selected_match = prev_idx;
        self.scrollToMatch(host, prev_idx);
    }

    fn scrollToMatch(self: *StoryOverlayComponent, host: *const types.UiHost, match_idx: usize) void {
        if (match_idx >= self.matches.items.len) return;

        const target_line = self.matches.items[match_idx].line_index;
        const rect = FullscreenOverlay.overlayRect(host);
        const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
        const viewport_h = @as(f32, @floatFromInt(@max(0, rect.h - title_h - dpi.scale(8, host.ui_scale))));

        var y: f32 = 0;
        var idx: usize = 0;
        while (idx < target_line and idx < self.lines.items.len) : (idx += 1) {
            y += @floatFromInt(self.lineHeight(self.lines.items[idx], host));
        }

        if (y < self.overlay.scroll_offset or y > self.overlay.scroll_offset + viewport_h) {
            self.overlay.scroll_offset = @max(0, y - viewport_h / 3.0);
        }
    }

    // --- Link handling ---

    fn hoveredLinkHref(self: *const StoryOverlayComponent) ?[]const u8 {
        const idx = self.hovered_link orelse return null;
        if (idx >= self.link_hits.items.len) return null;
        return self.link_hits.items[idx].href;
    }

    fn linkHitIndexAt(self: *const StoryOverlayComponent, x: c_int, y: c_int) ?usize {
        for (self.link_hits.items, 0..) |hit, idx| {
            if (geom.containsPoint(hit.rect, x, y)) return idx;
        }
        return null;
    }

    // --- Event handling ---

    fn handleEventFn(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (!self.overlay.visible) return false;

        if (self.overlay.animation_state == .closing or self.overlay.animation_state == .opening) return true;

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;
                const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;

                if (has_gui and !has_blocking and key == c.SDLK_F) {
                    self.search_active = !self.search_active;
                    if (!self.search_active and self.search_query.items.len == 0) {
                        self.selected_match = null;
                    }
                    return true;
                }

                if (self.search_active) {
                    if (key == c.SDLK_ESCAPE) {
                        self.search_active = false;
                        self.search_query.clearRetainingCapacity();
                        self.rebuildSearchMatches();
                        return true;
                    }

                    if (key == c.SDLK_BACKSPACE) {
                        if (self.search_query.items.len > 0) {
                            self.search_query.items.len -= 1;
                            self.rebuildSearchMatches();
                        }
                        return true;
                    }

                    if (key == c.SDLK_RETURN or key == c.SDLK_RETURN2 or key == c.SDLK_KP_ENTER) {
                        if (has_shift) {
                            self.prevMatch(host);
                        } else {
                            self.nextMatch(host);
                        }
                        return true;
                    }
                } else if (key == c.SDLK_ESCAPE) {
                    self.hide(host.now_ms);
                    return true;
                }

                if (self.overlay.handleScrollKey(key, host)) {
                    self.scrollbar_state.noteActivity(host.now_ms);
                    return true;
                }

                return true;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (self.search_active) {
                    const text = std.mem.span(event.text.text);
                    self.search_query.appendSlice(self.allocator, text) catch |err| {
                        log.warn("failed to append search input: {}", .{err});
                    };
                    self.rebuildSearchMatches();
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                self.overlay.handleMouseWheel(event.wheel.y);
                self.scrollbar_state.noteActivity(host.now_ms);
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);

                if (FullscreenOverlay.isCloseButtonHit(mouse_x, mouse_y, host)) {
                    self.hide(host.now_ms);
                    return true;
                }

                const overlay_rect = FullscreenOverlay.overlayRect(host);
                const search_rect = searchBarRect(host, overlay_rect);
                if (geom.containsPoint(search_rect, mouse_x, mouse_y)) {
                    self.search_active = true;
                    return true;
                }

                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
                    const content_rect = geom.Rect{
                        .x = overlay_rect.x,
                        .y = overlay_rect.y + title_h,
                        .w = overlay_rect.w,
                        .h = overlay_rect.h - title_h,
                    };
                    const scroll_metrics = scrollbar.Metrics.init(
                        self.totalContentHeight(host),
                        self.overlay.scroll_offset,
                        @floatFromInt(@max(0, content_rect.h)),
                    );
                    if (scrollbar.computeLayout(content_rect, host.ui_scale, scroll_metrics)) |layout| {
                        switch (scrollbar.hitTest(layout, mouse_x, mouse_y)) {
                            .thumb => {
                                self.scrollbar_state.beginDrag(layout, mouse_y, host.now_ms);
                                return true;
                            },
                            .track => {
                                self.overlay.scroll_offset = scrollbar.offsetForTrackClick(layout, scroll_metrics, mouse_y);
                                self.scrollbar_state.noteActivity(host.now_ms);
                                return true;
                            },
                            .none => {},
                        }
                    }

                    if (self.linkHitIndexAt(mouse_x, mouse_y)) |hit_idx| {
                        const href = self.link_hits.items[hit_idx].href;
                        open_url.openUrl(self.allocator, href) catch |err| {
                            log.warn("failed to open story link {s}: {}", .{ href, err });
                        };
                        return true;
                    }
                }

                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT and self.scrollbar_state.dragging) {
                    self.scrollbar_state.endDrag(host.now_ms);
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                self.overlay.updateCloseHover(mouse_x, mouse_y, host);

                const overlay_rect = FullscreenOverlay.overlayRect(host);
                const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
                const content_rect = geom.Rect{
                    .x = overlay_rect.x,
                    .y = overlay_rect.y + title_h,
                    .w = overlay_rect.w,
                    .h = overlay_rect.h - title_h,
                };
                const scroll_metrics = scrollbar.Metrics.init(
                    self.totalContentHeight(host),
                    self.overlay.scroll_offset,
                    @floatFromInt(@max(0, content_rect.h)),
                );
                const scroll_layout = scrollbar.computeLayout(content_rect, host.ui_scale, scroll_metrics);

                if (self.scrollbar_state.dragging) {
                    if (scroll_layout) |layout| {
                        self.overlay.scroll_offset = scrollbar.offsetForDrag(&self.scrollbar_state, layout, scroll_metrics, mouse_y);
                        self.scrollbar_state.noteActivity(host.now_ms);
                    } else {
                        self.scrollbar_state.endDrag(host.now_ms);
                    }
                }

                const scroll_hit = if (scroll_layout) |layout| scrollbar.hitTest(layout, mouse_x, mouse_y) else .none;
                const was_scrollbar = self.scrollbar_state.hovered or self.scrollbar_state.dragging;
                self.scrollbar_state.setHovered(self.scrollbar_state.dragging or scroll_hit != .none, host.now_ms);

                const prev_hovered_anchor = self.hovered_anchor;
                self.updateAnchorHover(mouse_x, mouse_y, host);

                const prev_link = self.hovered_link;
                self.hovered_link = self.linkHitIndexAt(mouse_x, mouse_y);

                const want_pointer = self.hovered_anchor != null or self.hovered_link != null or self.scrollbar_state.dragging or scroll_hit != .none;
                const was_pointer = prev_hovered_anchor != null or prev_link != null or was_scrollbar;
                if (want_pointer != was_pointer) {
                    const cursor = if (want_pointer) self.pointer_cursor else self.arrow_cursor;
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
        self.scrollbar_state.update(host.now_ms);
        if (!self.overlay.visible) return;

        const new_wrap = self.computeWrapCols(host);
        if (new_wrap != self.wrap_cols and new_wrap > 0) {
            self.wrap_cols = new_wrap;
            self.rebuildLines();
        }
    }

    fn hitTestFn(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.hitTest(host, x, y);
    }

    fn wantsFrameFn(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.wantsFrame() or
            self.scrollbar_state.wantsFrame(host.now_ms) or
            self.hovered_anchor != null or
            self.hovered_link != null;
    }

    // --- Anchor hover ---

    fn updateAnchorHover(self: *StoryOverlayComponent, mouse_x: c_int, mouse_y: c_int, host: *const types.UiHost) void {
        const hit_radius: i64 = dpi.scale(12, host.ui_scale);
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

    // --- Wrap column computation ---

    fn computeWrapCols(self: *const StoryOverlayComponent, host: *const types.UiHost) usize {
        _ = self;
        const rect = FullscreenOverlay.overlayRect(host);
        const scaled_padding = dpi.scale(FullscreenOverlay.text_padding, host.ui_scale);
        const text_area_w = rect.w - scaled_padding * 2 - scrollbar.reservedWidth(host.ui_scale);
        if (text_area_w <= 0) return 80;

        const estimated_char_w: c_int = dpi.scale(8, host.ui_scale);
        if (estimated_char_w <= 0) return 80;

        const cols: usize = @intCast(@divFloor(text_area_w, estimated_char_w));
        return @max(cols, 40);
    }

    // --- Line height ---

    fn lineHeight(self: *const StoryOverlayComponent, line: markdown_renderer.RenderLine, host: *const types.UiHost) c_int {
        _ = self;
        return switch (line.kind) {
            .blank => dpi.scale(12, host.ui_scale),
            .horizontal_rule => dpi.scale(14, host.ui_scale),
            .story_diff_header, .story_diff_line, .story_code_line, .code => dpi.scale(row_height, host.ui_scale),
            .table => dpi.scale(24, host.ui_scale),
            .text => switch (line.heading_level) {
                1 => dpi.scale(34, host.ui_scale),
                2 => dpi.scale(30, host.ui_scale),
                3 => dpi.scale(27, host.ui_scale),
                4 => dpi.scale(25, host.ui_scale),
                5 => dpi.scale(24, host.ui_scale),
                6 => dpi.scale(23, host.ui_scale),
                else => dpi.scale(row_height, host.ui_scale),
            },
            .prompt_separator => dpi.scale(18, host.ui_scale),
        };
    }

    fn totalContentHeight(self: *const StoryOverlayComponent, host: *const types.UiHost) f32 {
        var total: f32 = 0;
        for (self.lines.items) |line| {
            total += @floatFromInt(self.lineHeight(line, host));
        }
        return total;
    }

    fn fontSizeForLine(line: markdown_renderer.RenderLine, ui_scale: f32) c_int {
        if (line.heading_level > 0) {
            const heading_sizes = [6]c_int{ 24, 20, 18, 16, 15, 14 };
            const idx: usize = @min(@as(usize, line.heading_level) - 1, 5);
            return dpi.scale(heading_sizes[idx], ui_scale);
        }
        return switch (line.kind) {
            .story_diff_header, .story_diff_line, .story_code_line, .code => dpi.scale(code_font_size, ui_scale),
            .table => dpi.scale(code_font_size, ui_scale),
            else => dpi.scale(base_font_size, ui_scale),
        };
    }

    // --- Rendering ---

    fn renderFn(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.overlay.visible) return;

        const font_cache = assets.font_cache orelse return;

        const progress = self.overlay.renderProgress(host.now_ms);
        self.overlay.render_alpha = progress;
        if (progress <= 0.001) return;

        const overlay_rect = FullscreenOverlay.animatedOverlayRect(host, progress);
        const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
        const content_height = self.totalContentHeight(host);
        const viewport_height: f32 = @floatFromInt(@max(0, overlay_rect.h - title_h));
        self.overlay.max_scroll = @max(0, content_height - viewport_height);
        self.overlay.scroll_offset = @min(self.overlay.max_scroll, self.overlay.scroll_offset);

        self.overlay.renderFrame(renderer, host, overlay_rect, progress);

        const title_font_size = dpi.scale(18, host.ui_scale);
        const title_fonts = font_cache.get(title_font_size) catch return;
        const title_text_str = self.buildTitleText() catch return;
        defer self.allocator.free(title_text_str);
        const title_tex = makeTextTexture(self.allocator, renderer, title_fonts.bold orelse title_fonts.regular, title_text_str, host.theme.foreground) catch return;
        defer c.SDL_DestroyTexture(title_tex.tex);
        self.overlay.renderTitle(renderer, overlay_rect, title_tex.tex, title_tex.w, title_tex.h, host);
        FullscreenOverlay.renderTitleSeparator(renderer, host, overlay_rect, progress);
        self.overlay.renderCloseButton(renderer, host, overlay_rect);

        if (self.search_active or self.search_query.items.len > 0) {
            self.renderSearchBar(renderer, host, overlay_rect, font_cache) catch |err| {
                log.warn("failed to render story search bar: {}", .{err});
            };
        }

        const content_clip = c.SDL_Rect{
            .x = overlay_rect.x,
            .y = overlay_rect.y + title_h,
            .w = overlay_rect.w,
            .h = overlay_rect.h - title_h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &content_clip);

        self.anchor_positions.clearRetainingCapacity();
        self.link_hits.clearRetainingCapacity();
        self.renderContent(host, renderer, overlay_rect, title_h, font_cache, progress);
        self.renderBezierArrows(renderer, host);

        _ = c.SDL_SetRenderClipRect(renderer, null);

        const scroll_metrics = scrollbar.Metrics.init(content_height, self.overlay.scroll_offset, viewport_height);
        const content_rect = geom.Rect{
            .x = overlay_rect.x,
            .y = overlay_rect.y + title_h,
            .w = overlay_rect.w,
            .h = overlay_rect.h - title_h,
        };
        if (scrollbar.computeLayout(content_rect, host.ui_scale, scroll_metrics)) |layout| {
            scrollbar.render(renderer, layout, host.theme.accent, &self.scrollbar_state);
            self.scrollbar_state.markDrawn();
        } else {
            self.scrollbar_state.hideNow();
        }
        self.overlay.first_frame.markDrawn();
    }

    fn renderContent(
        self: *StoryOverlayComponent,
        host: *const types.UiHost,
        renderer: *c.SDL_Renderer,
        overlay_rect: geom.Rect,
        title_h: c_int,
        font_cache: *FontCache,
        progress: f32,
    ) void {
        const scroll_int: c_int = @intFromFloat(self.overlay.scroll_offset);
        const content_top = overlay_rect.y + title_h;
        const content_h = overlay_rect.h - title_h;
        if (content_h <= 0) return;

        const scaled_padding = dpi.scale(FullscreenOverlay.text_padding, host.ui_scale);
        const scaled_code_indent = dpi.scale(code_indent, host.ui_scale);
        const hovered_href = self.hoveredLinkHref();

        var y_pos: c_int = content_top - scroll_int;

        for (self.lines.items, 0..) |line, line_idx| {
            const lh = self.lineHeight(line, host);

            if (y_pos + lh < content_top) {
                y_pos += lh;
                continue;
            }
            if (y_pos > content_top + content_h) break;

            // Background fills for story-specific line kinds
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            switch (line.kind) {
                .story_diff_header => {
                    _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(20.0 * progress));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(overlay_rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(overlay_rect.w - 2),
                        .h = @floatFromInt(lh),
                    });
                },
                .story_diff_line => {
                    switch (line.code_line_kind) {
                        .add => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 0, 80, 0, @intFromFloat(60.0 * progress));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(overlay_rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(overlay_rect.w - 2),
                                .h = @floatFromInt(lh),
                            });
                        },
                        .remove => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 80, 0, 0, @intFromFloat(60.0 * progress));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(overlay_rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(overlay_rect.w - 2),
                                .h = @floatFromInt(lh),
                            });
                        },
                        .context => {},
                    }
                },
                .story_code_line, .code => {
                    _ = c.SDL_SetRenderDrawColor(renderer, host.theme.foreground.r, host.theme.foreground.g, host.theme.foreground.b, @intFromFloat(8.0 * progress));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(overlay_rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(overlay_rect.w - 2),
                        .h = @floatFromInt(lh),
                    });
                },
                .horizontal_rule => {
                    _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(180.0 * progress));
                    const line_y = y_pos + @divFloor(lh, 2);
                    _ = c.SDL_RenderLine(renderer, @floatFromInt(overlay_rect.x + scaled_padding), @floatFromInt(line_y), @floatFromInt(overlay_rect.x + overlay_rect.w - scaled_padding), @floatFromInt(line_y));
                    y_pos += lh;
                    continue;
                },
                .blank => {
                    y_pos += lh;
                    continue;
                },
                else => {},
            }

            if (line.quote_depth > 0) {
                renderQuoteBackground(renderer, host, overlay_rect, scaled_padding, y_pos, lh, progress);
            }

            // Load fonts for this line (needed by both search highlights and text rendering)
            const line_font_size = fontSizeForLine(line, host.ui_scale);
            const line_fonts = font_cache.get(line_font_size) catch |err| {
                log.warn("failed to load story font size {d}: {}", .{ line_font_size, err });
                y_pos += lh;
                continue;
            };

            // Search highlights (uses font for proportional width measurement)
            self.renderSearchHighlights(renderer, host, overlay_rect, y_pos, lh, line_idx, line, line_fonts);

            var x: c_int = overlay_rect.x + scaled_padding;

            // Code-like lines get extra indent
            if (line.kind == .story_diff_header or line.kind == .story_diff_line or
                line.kind == .story_code_line or line.kind == .code)
            {
                x += scaled_code_indent;
            }

            if (line.quote_depth > 0) {
                x += dpi.scale(10, host.ui_scale);
            }

            // For diff lines, render +/- marker separately with diff color, then remaining runs
            if (line.kind == .story_diff_line and line.runs.len > 0) {
                const first_run = line.runs[0];
                if (first_run.text.len > 0 and first_run.anchor_number == null) {
                    const marker_char = first_run.text[0];
                    const marker_str: []const u8 = switch (marker_char) {
                        '+' => "+",
                        '-' => "-",
                        else => " ",
                    };
                    const marker_color = self.diffLineColor(line, host);
                    const marker_tex = makeTextTexture(self.allocator, renderer, line_fonts.regular, marker_str, marker_color) catch |err| {
                        log.warn("failed to create marker texture: {}", .{err});
                        y_pos += lh;
                        continue;
                    };
                    defer c.SDL_DestroyTexture(marker_tex.tex);
                    const max_text_h = @max(1, lh - dpi.scale(4, host.ui_scale));
                    const marker_draw = fitTextureHeight(marker_tex.w, marker_tex.h, max_text_h);
                    _ = c.SDL_SetTextureAlphaMod(marker_tex.tex, @intFromFloat(255.0 * progress));
                    _ = c.SDL_RenderTexture(renderer, marker_tex.tex, null, &c.SDL_FRect{
                        .x = @floatFromInt(x),
                        .y = @floatFromInt(y_pos + @divFloor(lh - marker_draw.h, 2)),
                        .w = @floatFromInt(marker_draw.w),
                        .h = @floatFromInt(marker_draw.h),
                    });

                    const scaled_marker_w = dpi.scale(marker_width, host.ui_scale);
                    x += scaled_marker_w;

                    // Render rest of diff line text (skip first char which is +/-/space)
                    const rest_text = if (first_run.text.len > 1) first_run.text[1..] else "";
                    if (rest_text.len > 0) {
                        const text_color = self.diffLineColor(line, host);
                        const tex = makeTextTexture(self.allocator, renderer, line_fonts.regular, rest_text, text_color) catch |err| {
                            log.warn("failed to create diff text texture: {}", .{err});
                            y_pos += lh;
                            continue;
                        };
                        defer c.SDL_DestroyTexture(tex.tex);
                        const draw_size = fitTextureHeight(tex.w, tex.h, max_text_h);
                        _ = c.SDL_SetTextureAlphaMod(tex.tex, @intFromFloat(255.0 * progress));
                        _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                            .x = @floatFromInt(x),
                            .y = @floatFromInt(y_pos + @divFloor(lh - draw_size.h, 2)),
                            .w = @floatFromInt(draw_size.w),
                            .h = @floatFromInt(draw_size.h),
                        });
                        x += draw_size.w;
                    }
                }

                // Render remaining runs (e.g. anchor badges) after the first code run
                if (line.runs.len > 1) {
                    for (line.runs[1..]) |run| {
                        self.renderRun(renderer, host, line, run, line_fonts, hovered_href, &x, y_pos, lh, progress);
                    }
                }
            } else {
                for (line.runs) |run| {
                    self.renderRun(renderer, host, line, run, line_fonts, hovered_href, &x, y_pos, lh, progress);
                }
            }

            y_pos += lh;
        }
    }

    fn diffLineColor(self: *const StoryOverlayComponent, line: markdown_renderer.RenderLine, host: *const types.UiHost) c.SDL_Color {
        _ = self;
        return switch (line.code_line_kind) {
            .add => host.theme.palette[2],
            .remove => host.theme.palette[1],
            .context => host.theme.foreground,
        };
    }

    fn chooseRunColor(self: *const StoryOverlayComponent, host: *const types.UiHost, line: markdown_renderer.RenderLine, run: markdown_renderer.RenderRun, link_hovered: bool) c.SDL_Color {
        _ = self;
        if (line.heading_level > 0) return host.theme.accent;
        if (run.style == .link) return if (link_hovered) host.theme.palette[5] else host.theme.accent;
        if (run.style == .code) return host.theme.palette[3];
        if (run.style == .bold) return host.theme.foreground;
        if (run.style == .italic) return host.theme.palette[4];
        if (line.kind == .story_diff_header) return host.theme.accent;
        if (line.kind == .story_code_line or line.kind == .code) return host.theme.foreground;
        if (run.marker) return host.theme.palette[3];
        if (line.kind == .table) return host.theme.palette[6];
        return host.theme.foreground;
    }

    fn renderRun(
        self: *StoryOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        line: markdown_renderer.RenderLine,
        run: markdown_renderer.RenderRun,
        line_fonts: *FontSet,
        hovered_href: ?[]const u8,
        x: *c_int,
        y_pos: c_int,
        lh: c_int,
        progress: f32,
    ) void {
        const max_text_h = @max(1, lh - dpi.scale(4, host.ui_scale));
        const is_anchor = run.anchor_number != null;
        const is_code_line = line.kind == .story_diff_line or line.kind == .story_code_line;

        // Choose font - anchors use bold
        const run_font = if (is_anchor)
            line_fonts.bold orelse line_fonts.regular
        else
            chooseFontForStyle(line_fonts, run.style, line.heading_level > 0);

        // Choose color - anchors use background color on accent pill
        const run_color = if (is_anchor)
            host.theme.background
        else blk: {
            const link_hovered = if (hovered_href) |href|
                run.href != null and std.mem.eql(u8, run.href.?, href)
            else
                false;
            break :blk self.chooseRunColor(host, line, run, link_hovered);
        };

        const tex = makeTextTexture(self.allocator, renderer, run_font, run.text, run_color) catch |err| {
            log.warn("failed to create run texture: {}", .{err});
            return;
        };
        defer c.SDL_DestroyTexture(tex.tex);
        const draw_size = fitTextureHeight(tex.w, tex.h, max_text_h);
        const draw_y = y_pos + @divFloor(lh - draw_size.h, 2);

        // Draw anchor pill background behind the text
        if (is_anchor) {
            const pill_pad = dpi.scale(2, host.ui_scale);
            const pill_rect = geom.Rect{
                .x = x.* - pill_pad,
                .y = draw_y - pill_pad,
                .w = draw_size.w + pill_pad * 2,
                .h = draw_size.h + pill_pad * 2,
            };
            const corner_r = @divFloor(pill_rect.h, 2);
            const accent = host.theme.accent;
            const bg_alpha: u8 = @intFromFloat(200.0 * progress);
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, bg_alpha);
            primitives.fillRoundedRect(renderer, pill_rect, corner_r);
        }

        _ = c.SDL_SetTextureAlphaMod(tex.tex, @intFromFloat(255.0 * progress));
        _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(x.*),
            .y = @floatFromInt(draw_y),
            .w = @floatFromInt(draw_size.w),
            .h = @floatFromInt(draw_size.h),
        });

        // Track anchor position for bezier arrows
        if (run.anchor_number) |num| {
            const pill_pad_track = dpi.scale(2, host.ui_scale);
            const pill_w = draw_size.w + pill_pad_track * 2;
            const pill_h = draw_size.h + pill_pad_track * 2;
            const center_x = x.* + @divFloor(draw_size.w, 2);
            const center_y = y_pos + @divFloor(lh, 2);
            self.anchor_positions.append(self.allocator, .{
                .number = num,
                .x = center_x,
                .y = center_y,
                .w = pill_w,
                .h = pill_h,
                .is_code = is_code_line,
            }) catch |err| {
                log.warn("failed to track anchor position: {}", .{err});
            };
        }

        // Link hit tracking and decoration
        if (run.href) |href| {
            self.link_hits.append(self.allocator, .{
                .rect = .{ .x = x.*, .y = draw_y, .w = draw_size.w, .h = draw_size.h },
                .href = href,
            }) catch |err| {
                log.warn("failed to track story link hitbox: {}", .{err});
            };
        }
        if (run.style == .strikethrough) {
            const strike_y = y_pos + @divFloor(lh, 2);
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, run_color.r, run_color.g, run_color.b, @intFromFloat(220.0 * progress));
            _ = c.SDL_RenderLine(renderer, @floatFromInt(x.*), @floatFromInt(strike_y), @floatFromInt(x.* + draw_size.w), @floatFromInt(strike_y));
        }
        if (run.style == .link) {
            const underline_y = y_pos + @divFloor(lh * 3, 4);
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, run_color.r, run_color.g, run_color.b, @intFromFloat(220.0 * progress));
            _ = c.SDL_RenderLine(renderer, @floatFromInt(x.*), @floatFromInt(underline_y), @floatFromInt(x.* + draw_size.w), @floatFromInt(underline_y));
        }

        x.* += draw_size.w;
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

        const from_edge = anchorEdgePoint(from, to);
        const to_edge = anchorEdgePoint(to, from);

        const elapsed_ms = host.now_ms - self.hover_start_ms;
        const time_seconds: f32 = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;

        primitives.renderBezierArrow(
            renderer,
            from_edge[0],
            from_edge[1],
            to_edge[0],
            to_edge[1],
            host.theme.accent,
            time_seconds,
        );
    }

    fn anchorEdgePoint(from: AnchorPosition, to: AnchorPosition) [2]f32 {
        const cx: f32 = @floatFromInt(from.x);
        const cy: f32 = @floatFromInt(from.y);
        const half_h: f32 = @floatFromInt(@divFloor(from.h, 2));
        if (to.y > from.y) {
            return .{ cx, cy + half_h };
        } else {
            return .{ cx, cy - half_h };
        }
    }

    fn renderQuoteBackground(renderer: *c.SDL_Renderer, host: *const types.UiHost, overlay_rect: geom.Rect, scaled_padding: c_int, y: c_int, lh: c_int, progress: f32) void {
        const quote_rect = geom.Rect{
            .x = overlay_rect.x + scaled_padding,
            .y = y,
            .w = overlay_rect.w - scaled_padding * 2,
            .h = lh,
        };
        if (quote_rect.w <= 0 or quote_rect.h <= 0) return;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(30.0 * progress));
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(quote_rect.x),
            .y = @floatFromInt(quote_rect.y),
            .w = @floatFromInt(quote_rect.w),
            .h = @floatFromInt(quote_rect.h),
        });
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(180.0 * progress));
        _ = c.SDL_RenderRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(quote_rect.x),
            .y = @floatFromInt(quote_rect.y),
            .w = @floatFromInt(quote_rect.w),
            .h = @floatFromInt(quote_rect.h),
        });
    }

    fn renderSearchHighlights(
        self: *StoryOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        overlay_rect: geom.Rect,
        y: c_int,
        lh: c_int,
        line_idx: usize,
        line: markdown_renderer.RenderLine,
        line_fonts: *FontSet,
    ) void {
        const query = std.mem.trim(u8, self.search_query.items, " \t");
        if (query.len == 0) return;

        const scaled_padding = dpi.scale(FullscreenOverlay.text_padding, host.ui_scale);
        const max_text_h = @max(1, lh - dpi.scale(4, host.ui_scale));

        // Compute the same base x as the text rendering code
        var base_x: c_int = overlay_rect.x + scaled_padding;
        if (line.kind == .story_diff_header or line.kind == .story_diff_line or
            line.kind == .story_code_line or line.kind == .code)
        {
            base_x += dpi.scale(code_indent, host.ui_scale);
        }
        if (line.quote_depth > 0) {
            base_x += dpi.scale(10, host.ui_scale);
        }

        for (self.matches.items, 0..) |match_item, match_idx| {
            if (match_item.line_index != line_idx) continue;

            const selected = self.selected_match != null and self.selected_match.? == match_idx;
            const bg = if (selected) host.theme.accent else host.theme.selection;
            const alpha: u8 = if (selected) 180 else 120;

            const start_x = byteOffsetToPixelX(line, line_fonts, base_x, max_text_h, match_item.start, host.ui_scale);
            const end_x = byteOffsetToPixelX(line, line_fonts, base_x, max_text_h, match_item.start + match_item.len, host.ui_scale);
            const highlight_w = end_x - start_x;

            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, alpha);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                .x = @floatFromInt(start_x),
                .y = @floatFromInt(y + dpi.scale(3, host.ui_scale)),
                .w = @floatFromInt(highlight_w),
                .h = @floatFromInt(lh - dpi.scale(6, host.ui_scale)),
            });
        }
    }

    fn byteOffsetToPixelX(
        line: markdown_renderer.RenderLine,
        line_fonts: *FontSet,
        base_x: c_int,
        max_text_h: c_int,
        target_byte: usize,
        ui_scale: f32,
    ) c_int {
        var byte_pos: usize = 0;
        var pixel_x: c_int = base_x;

        for (line.runs, 0..) |run, run_idx| {
            if (byte_pos >= target_byte) break;

            // Diff line first run: marker char uses fixed width, rest rendered separately
            if (line.kind == .story_diff_line and run_idx == 0 and run.text.len > 0 and run.anchor_number == null) {
                // Marker character (1 byte, fixed pixel width)
                if (target_byte < byte_pos + 1) return pixel_x;
                const mw = dpi.scale(marker_width, ui_scale);
                byte_pos += 1;
                pixel_x += mw;

                // Rest of first run text
                const rest = run.text[1..];
                if (rest.len > 0) {
                    if (target_byte < byte_pos + rest.len) {
                        const offset = target_byte - byte_pos;
                        return pixel_x + measureScaledTextWidth(line_fonts.regular, rest[0..offset], max_text_h);
                    }
                    pixel_x += measureScaledTextWidth(line_fonts.regular, rest, max_text_h);
                    byte_pos += rest.len;
                }
                continue;
            }

            const is_anchor = run.anchor_number != null;
            const run_font = if (is_anchor)
                line_fonts.bold orelse line_fonts.regular
            else
                chooseFontForStyle(line_fonts, run.style, line.heading_level > 0);

            if (target_byte < byte_pos + run.text.len) {
                const offset = target_byte - byte_pos;
                return pixel_x + measureScaledTextWidth(run_font, run.text[0..offset], max_text_h);
            }
            pixel_x += measureScaledTextWidth(run_font, run.text, max_text_h);
            byte_pos += run.text.len;
        }

        return pixel_x;
    }

    fn measureScaledTextWidth(font: *c.TTF_Font, text: []const u8, max_text_h: c_int) c_int {
        if (text.len == 0) return 0;
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetStringSize(font, @ptrCast(text.ptr), text.len, &w, &h);
        return fitTextureHeight(w, h, max_text_h).w;
    }

    fn renderSearchBar(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, overlay_rect: geom.Rect, font_cache: *FontCache) !void {
        const rect = searchBarRect(host, overlay_rect);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.selection.r, host.theme.selection.g, host.theme.selection.b, 230);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        });

        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 220);
        _ = c.SDL_RenderRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        });

        const fonts = try font_cache.get(dpi.scale(14, host.ui_scale));
        const prefix = "Search: ";
        const query = self.search_query.items;
        var count_buf: [32]u8 = undefined;
        const count_text = if (self.matches.items.len == 0)
            "0/0"
        else blk: {
            const selected = (self.selected_match orelse 0) + 1;
            break :blk try std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ selected, self.matches.items.len });
        };

        var text_buf = std.ArrayList(u8).empty;
        defer text_buf.deinit(self.allocator);
        try text_buf.appendSlice(self.allocator, prefix);
        try text_buf.appendSlice(self.allocator, query);

        const query_tex = try makeTextTexture(self.allocator, renderer, fonts.regular, text_buf.items, host.theme.foreground);
        defer c.SDL_DestroyTexture(query_tex.tex);
        _ = c.SDL_RenderTexture(renderer, query_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + dpi.scale(8, host.ui_scale)),
            .y = @floatFromInt(rect.y + @divFloor(rect.h - query_tex.h, 2)),
            .w = @floatFromInt(query_tex.w),
            .h = @floatFromInt(query_tex.h),
        });

        const count_tex = try makeTextTexture(self.allocator, renderer, fonts.regular, count_text, host.theme.accent);
        defer c.SDL_DestroyTexture(count_tex.tex);
        _ = c.SDL_RenderTexture(renderer, count_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + rect.w - count_tex.w - dpi.scale(8, host.ui_scale)),
            .y = @floatFromInt(rect.y + @divFloor(rect.h - count_tex.h, 2)),
            .w = @floatFromInt(count_tex.w),
            .h = @floatFromInt(count_tex.h),
        });
    }

    // --- Title ---

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

    // --- Utilities ---

    fn chooseFontForStyle(fonts: *FontSet, style: markdown_parser.InlineStyle, force_bold: bool) *c.TTF_Font {
        const want_bold = force_bold or style == .bold;
        const want_italic = style == .italic;

        if (want_bold and want_italic) {
            if (fonts.bold_italic) |font| return font;
            if (fonts.bold) |font| return font;
            if (fonts.italic) |font| return font;
            return fonts.regular;
        }
        if (want_bold) {
            if (fonts.bold) |font| return font;
            return fonts.regular;
        }
        if (want_italic) {
            if (fonts.italic) |font| return font;
            return fonts.regular;
        }
        return fonts.regular;
    }

    fn makeTextTexture(
        allocator: std.mem.Allocator,
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
    ) !TextTex {
        if (text.len == 0) return error.EmptyText;

        var stack_buf: [256]u8 = undefined;
        var surface: *c.SDL_Surface = undefined;

        if (text.len < stack_buf.len) {
            @memcpy(stack_buf[0..text.len], text);
            stack_buf[text.len] = 0;
            surface = c.TTF_RenderText_Blended(font, @ptrCast(&stack_buf), @intCast(text.len), color) orelse return error.SurfaceFailed;
        } else {
            const heap_buf = try allocator.alloc(u8, text.len + 1);
            defer allocator.free(heap_buf);
            @memcpy(heap_buf[0..text.len], text);
            heap_buf[text.len] = 0;
            surface = c.TTF_RenderText_Blended(font, @ptrCast(heap_buf.ptr), @intCast(text.len), color) orelse return error.SurfaceFailed;
        }
        defer c.SDL_DestroySurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &w, &h);
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
        return .{ .tex = texture, .w = @intFromFloat(w), .h = @intFromFloat(h) };
    }

    fn fitTextureHeight(tex_w: c_int, tex_h: c_int, max_h: c_int) DrawSize {
        if (tex_w <= 0 or tex_h <= 0) return .{ .w = 0, .h = 0 };
        if (max_h <= 0 or tex_h <= max_h) return .{ .w = tex_w, .h = tex_h };

        const scale = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(tex_h));
        return .{
            .w = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(tex_w)) * scale))),
            .h = max_h,
        };
    }

    fn searchBarRect(host: *const types.UiHost, overlay_rect: geom.Rect) geom.Rect {
        const bar_w = dpi.scale(300, host.ui_scale);
        const bar_h = dpi.scale(32, host.ui_scale);
        const margin = dpi.scale(8, host.ui_scale);
        const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
        return .{
            .x = overlay_rect.x + overlay_rect.w - bar_w - margin,
            .y = overlay_rect.y + title_h + margin,
            .w = bar_w,
            .h = bar_h,
        };
    }

    // --- Deinit ---

    fn destroy(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.scrollbar_state.deinit();
        self.clearContent();
        self.blocks.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.anchor_positions.deinit(self.allocator);
        self.search_query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.link_hits.deinit(self.allocator);
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
