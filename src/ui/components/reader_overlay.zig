const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../../dpi.zig");
const FullscreenOverlay = @import("fullscreen_overlay.zig").FullscreenOverlay;
const session_state = @import("../../session/state.zig");
const font_cache_mod = @import("../../font_cache.zig");
const terminal_history = @import("../../app/terminal_history.zig");
const open_url = @import("../../os/open.zig");
const markdown_parser = @import("markdown_parser.zig");
const markdown_renderer = @import("markdown_renderer.zig");
const scrollbar = @import("scrollbar.zig");

const log = std.log.scoped(.reader_overlay);
const SessionState = session_state.SessionState;
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

const TableRowMetrics = struct {
    cells: [max_table_columns][]const u8 = undefined,
    col_count: usize = 0,
    cell_cols: usize = 1,
    line_px: c_int = 0,
    max_lines: usize = 1,
    is_separator: bool = false,
    row_height: c_int = 0,
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

const WrappedTableRun = struct {
    text: []const u8,
    style: markdown_parser.InlineStyle,
    href: ?[]const u8 = null,
};

const max_table_columns: usize = markdown_parser.max_table_columns;

pub const ToggleResult = enum {
    opened,
    closed,
    unavailable,
};

pub const ReaderOverlayComponent = struct {
    allocator: std.mem.Allocator,
    sessions: []*SessionState,
    overlay: FullscreenOverlay = .{},
    scrollbar_state: scrollbar.State = .{},

    session_index: usize = 0,
    last_render_epoch: u64 = 0,
    wrap_cols: usize = 90,
    layout_char_w_px: c_int = 0,
    pinned_to_bottom: bool = true,

    raw_text: ?[]u8 = null,
    blocks: std.ArrayList(markdown_parser.DisplayBlock) = .{},
    lines: std.ArrayList(markdown_renderer.RenderLine) = .{},

    search_active: bool = false,
    search_query: std.ArrayList(u8) = .{},
    matches: std.ArrayList(SearchMatch) = .{},
    selected_match: ?usize = null,
    link_hits: std.ArrayList(LinkHit) = .{},
    hovered_link: ?usize = null,

    arrow_cursor: ?*c.SDL_Cursor = null,
    pointer_cursor: ?*c.SDL_Cursor = null,

    const base_font_size: c_int = 14;
    const code_font_size: c_int = 13;

    pub fn init(allocator: std.mem.Allocator, sessions: []*SessionState) !*ReaderOverlayComponent {
        const comp = try allocator.create(ReaderOverlayComponent);
        comp.* = .{
            .allocator = allocator,
            .sessions = sessions,
            .arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
            .pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
        };
        return comp;
    }

    pub fn asComponent(self: *ReaderOverlayComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 1150,
        };
    }

    pub fn toggle(self: *ReaderOverlayComponent, host: *const types.UiHost, now_ms: i64) ToggleResult {
        switch (self.overlay.animation_state) {
            .open, .opening => {
                self.hide(now_ms);
                return .closed;
            },
            .closing => {
                self.hide(now_ms);
                return .closed;
            },
            .closed => {},
        }

        if (host.focused_session >= self.sessions.len) return .unavailable;

        const session = self.sessions[host.focused_session];
        if (!session.spawned or session.terminal == null) return .unavailable;

        self.session_index = host.focused_session;
        self.pinned_to_bottom = true;
        self.layout_char_w_px = 0;
        self.wrap_cols = self.computeWrapCols(host);
        self.overlay.show(now_ms);
        self.refreshFromSession(host, true);
        return .opened;
    }

    fn hide(self: *ReaderOverlayComponent, now_ms: i64) void {
        self.overlay.hide(now_ms);
        self.scrollbar_state.hideNow();
        self.search_active = false;
        self.selected_match = null;
        self.clearLinkHits();
        if (self.arrow_cursor) |cur| _ = c.SDL_SetCursor(cur);
    }

    fn destroy(self: *ReaderOverlayComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.clearContent();
        self.blocks.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.search_query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.link_hits.deinit(self.allocator);
        self.scrollbar_state.deinit();

        if (self.arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
        if (self.pointer_cursor) |cur| c.SDL_DestroyCursor(cur);
        self.allocator.destroy(self);
    }

    fn clearContent(self: *ReaderOverlayComponent) void {
        if (self.raw_text) |text| {
            self.allocator.free(text);
            self.raw_text = null;
        }
        self.clearLinkHits();
        markdown_parser.freeBlocks(self.allocator, &self.blocks);
        markdown_renderer.freeLines(self.allocator, &self.lines);
        self.blocks = .{};
        self.lines = .{};
        self.last_render_epoch = 0;
    }

    fn clearLinkHits(self: *ReaderOverlayComponent) void {
        self.link_hits.clearRetainingCapacity();
        self.hovered_link = null;
    }

    fn refreshFromSession(self: *ReaderOverlayComponent, host: *const types.UiHost, force_bottom: bool) void {
        if (self.session_index >= self.sessions.len) return;

        const session = self.sessions[self.session_index];
        const extracted = terminal_history.extractSessionText(self.allocator, session) catch |err| {
            log.warn("failed to extract terminal history: {}", .{err});
            return;
        };

        if (self.raw_text) |old| self.allocator.free(old);
        self.raw_text = extracted;

        markdown_parser.freeBlocks(self.allocator, &self.blocks);
        self.blocks = markdown_parser.parse(self.allocator, extracted) catch |err| {
            log.warn("failed to parse markdown from terminal output: {}", .{err});
            self.blocks = .{};
            return;
        };

        self.rebuildLines(host, force_bottom);
        self.last_render_epoch = session.render_epoch;
    }

    fn rebuildLines(self: *ReaderOverlayComponent, host: *const types.UiHost, force_bottom: bool) void {
        const previous_max = self.overlay.max_scroll;
        const previous_offset = self.overlay.scroll_offset;
        self.clearLinkHits();

        markdown_renderer.freeLines(self.allocator, &self.lines);
        self.lines = markdown_renderer.buildLines(self.allocator, self.blocks.items, self.wrap_cols) catch |err| {
            log.warn("failed to build markdown layout: {}", .{err});
            self.lines = .{};
            return;
        };

        self.rebuildSearchMatches();
        _ = self.syncScrollMetrics(host);

        if (force_bottom or self.pinned_to_bottom or previous_max == 0) {
            self.overlay.scroll_offset = self.overlay.max_scroll;
            self.pinned_to_bottom = true;
        } else {
            self.overlay.scroll_offset = @min(self.overlay.max_scroll, previous_offset);
            self.pinned_to_bottom = self.isAtBottom();
        }
    }

    fn scrollContentRect(overlay_rect: geom.Rect, title_h: c_int) geom.Rect {
        return .{
            .x = overlay_rect.x,
            .y = overlay_rect.y + title_h,
            .w = overlay_rect.w,
            .h = @max(0, overlay_rect.h - title_h),
        };
    }

    fn syncScrollMetrics(self: *ReaderOverlayComponent, host: *const types.UiHost) scrollbar.Metrics {
        const rect = FullscreenOverlay.overlayRect(host);
        const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
        const content_rect = scrollContentRect(rect, title_h);
        const viewport = @as(f32, @floatFromInt(content_rect.h));
        const content = totalContentHeight(self, host);
        self.overlay.max_scroll = @max(0, content - viewport);
        self.overlay.scroll_offset = std.math.clamp(self.overlay.scroll_offset, 0, self.overlay.max_scroll);
        return scrollbar.Metrics.init(content, self.overlay.scroll_offset, viewport);
    }

    fn totalContentHeight(self: *const ReaderOverlayComponent, host: *const types.UiHost) f32 {
        var total: f32 = @floatFromInt(dpi.scale(16, host.ui_scale));
        for (self.lines.items) |line| {
            total += @floatFromInt(self.lineHeight(line, host));
        }
        return total;
    }

    fn isAtBottom(self: *const ReaderOverlayComponent) bool {
        return self.overlay.max_scroll - self.overlay.scroll_offset <= 2.0;
    }

    fn updatePinnedState(self: *ReaderOverlayComponent) void {
        self.pinned_to_bottom = self.isAtBottom();
    }

    fn hoveredLinkHref(self: *const ReaderOverlayComponent) ?[]const u8 {
        const idx = self.hovered_link orelse return null;
        if (idx >= self.link_hits.items.len) return null;
        return self.link_hits.items[idx].href;
    }

    fn linkHitIndexAt(self: *const ReaderOverlayComponent, x: c_int, y: c_int) ?usize {
        for (self.link_hits.items, 0..) |hit, idx| {
            if (geom.containsPoint(hit.rect, x, y)) return idx;
        }
        return null;
    }

    fn rebuildSearchMatches(self: *ReaderOverlayComponent) void {
        self.matches.clearRetainingCapacity();

        const query = std.mem.trim(u8, self.search_query.items, " \t");
        if (query.len == 0) {
            self.selected_match = null;
            return;
        }

        for (self.lines.items, 0..) |line, line_idx| {
            if (line.kind == .blank or line.kind == .horizontal_rule or line.kind == .prompt_separator) continue;

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

    fn nextMatch(self: *ReaderOverlayComponent, host: *const types.UiHost) void {
        if (self.matches.items.len == 0) return;
        const next_idx = if (self.selected_match) |idx| (idx + 1) % self.matches.items.len else 0;
        self.selected_match = next_idx;
        self.scrollToMatch(host, next_idx);
    }

    fn prevMatch(self: *ReaderOverlayComponent, host: *const types.UiHost) void {
        if (self.matches.items.len == 0) return;
        const prev_idx = if (self.selected_match) |idx|
            if (idx == 0) self.matches.items.len - 1 else idx - 1
        else
            0;
        self.selected_match = prev_idx;
        self.scrollToMatch(host, prev_idx);
    }

    fn scrollToMatch(self: *ReaderOverlayComponent, host: *const types.UiHost, match_idx: usize) void {
        if (match_idx >= self.matches.items.len) return;

        const target_line = self.matches.items[match_idx].line_index;
        const rect = FullscreenOverlay.overlayRect(host);
        const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
        const viewport_h = @as(f32, @floatFromInt(@max(0, rect.h - title_h - dpi.scale(8, host.ui_scale))));

        var y: f32 = @floatFromInt(dpi.scale(16, host.ui_scale));
        var idx: usize = 0;
        while (idx < target_line and idx < self.lines.items.len) : (idx += 1) {
            y += @floatFromInt(self.lineHeight(self.lines.items[idx], host));
        }

        const line_h: f32 = if (target_line < self.lines.items.len)
            @floatFromInt(self.lineHeight(self.lines.items[target_line], host))
        else
            @floatFromInt(dpi.scale(20, host.ui_scale));

        if (y < self.overlay.scroll_offset) {
            self.overlay.scroll_offset = y;
        } else if (y + line_h > self.overlay.scroll_offset + viewport_h) {
            self.overlay.scroll_offset = y + line_h - viewport_h;
        }

        self.overlay.scroll_offset = std.math.clamp(self.overlay.scroll_offset, 0, self.overlay.max_scroll);
        self.pinned_to_bottom = false;
    }

    fn wrappedLineCount(text: []const u8, max_cols: usize) usize {
        if (max_cols == 0 or text.len == 0) return 1;

        var line_count: usize = 1;
        var current_cols: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\n') {
                line_count += 1;
                current_cols = 0;
                i += 1;
                continue;
            }

            const is_space = text[i] == ' ' or text[i] == '\t';
            var end = i + 1;
            while (end < text.len and text[end] != '\n' and ((text[end] == ' ' or text[end] == '\t') == is_space)) : (end += 1) {}

            var remaining = end - i;
            while (remaining > 0) {
                if (is_space and current_cols == 0) break;

                if (!is_space and remaining > max_cols) {
                    if (current_cols > 0) {
                        line_count += 1;
                        current_cols = 0;
                    }
                    const chunk = @min(max_cols, remaining);
                    remaining -= chunk;
                    current_cols += chunk;
                    if (current_cols >= max_cols and remaining > 0) {
                        line_count += 1;
                        current_cols = 0;
                    }
                    continue;
                }

                if (current_cols + remaining > max_cols and current_cols > 0) {
                    line_count += 1;
                    current_cols = if (is_space) 0 else remaining;
                    remaining = 0;
                } else {
                    current_cols += remaining;
                    remaining = 0;
                }
            }

            i = end;
        }

        return line_count;
    }

    fn tableRowMetrics(self: *const ReaderOverlayComponent, host: *const types.UiHost, line: markdown_renderer.RenderLine) TableRowMetrics {
        var metrics = TableRowMetrics{};
        metrics.line_px = dpi.scale(18, host.ui_scale);

        metrics.col_count = splitTableCells(line.plain_text, &metrics.cells);
        if (metrics.col_count == 0) {
            metrics.row_height = dpi.scale(24, host.ui_scale);
            return metrics;
        }

        metrics.is_separator = isTableSeparatorLine(metrics.cells[0..metrics.col_count]);

        const overlay_rect = FullscreenOverlay.overlayRect(host);
        const col_rect = readingColumnRect(host, overlay_rect, self.wrap_cols);
        const scaled_padding = dpi.scale(10, host.ui_scale);
        const cell_pad = dpi.scale(8, host.ui_scale);

        const inner_w = @max(1, col_rect.w - scaled_padding * 2);
        const col_width_px = @max(1, @divFloor(inner_w, @as(c_int, @intCast(metrics.col_count))));
        const text_width_px = @max(1, col_width_px - cell_pad * 2);
        const char_w = layoutCharWidth(self, host);
        metrics.cell_cols = @intCast(@max(1, @divFloor(text_width_px, @max(1, char_w))));

        if (!metrics.is_separator) {
            var max_lines: usize = 1;
            var idx: usize = 0;
            while (idx < metrics.col_count) : (idx += 1) {
                const plain_cell = if (idx < line.table_cells.len)
                    line.table_cells[idx].plain_text
                else
                    metrics.cells[idx];
                const lines = wrappedLineCount(plain_cell, metrics.cell_cols);
                if (lines > max_lines) max_lines = lines;
            }
            metrics.max_lines = max_lines;
        }

        if (metrics.is_separator) {
            metrics.row_height = dpi.scale(16, host.ui_scale);
        } else {
            const vertical_pad = dpi.scale(8, host.ui_scale);
            metrics.row_height = @max(
                dpi.scale(24, host.ui_scale),
                @as(c_int, @intCast(metrics.max_lines)) * metrics.line_px + vertical_pad,
            );
        }

        return metrics;
    }

    fn lineHeight(self: *const ReaderOverlayComponent, line: markdown_renderer.RenderLine, host: *const types.UiHost) c_int {
        if (line.kind == .horizontal_rule) return dpi.scale(14, host.ui_scale);
        if (line.kind == .prompt_separator) return dpi.scale(18, host.ui_scale);
        if (line.kind == .blank) return dpi.scale(12, host.ui_scale);
        if (line.kind == .code) return dpi.scale(22, host.ui_scale);
        if (line.kind == .table) {
            const metrics = self.tableRowMetrics(host, line);
            return metrics.row_height;
        }

        if (line.heading_level > 0) {
            return switch (line.heading_level) {
                1 => dpi.scale(34, host.ui_scale),
                2 => dpi.scale(30, host.ui_scale),
                3 => dpi.scale(27, host.ui_scale),
                4 => dpi.scale(25, host.ui_scale),
                5 => dpi.scale(24, host.ui_scale),
                else => dpi.scale(23, host.ui_scale),
            };
        }

        return dpi.scale(22, host.ui_scale);
    }

    fn fontSizeForLine(line: markdown_renderer.RenderLine, ui_scale: f32) c_int {
        if (line.kind == .code) return dpi.scale(code_font_size, ui_scale);
        if (line.kind == .table) return dpi.scale(code_font_size, ui_scale);
        if (line.heading_level > 0) {
            return switch (line.heading_level) {
                1 => dpi.scale(24, ui_scale),
                2 => dpi.scale(22, ui_scale),
                3 => dpi.scale(20, ui_scale),
                4 => dpi.scale(18, ui_scale),
                5 => dpi.scale(17, ui_scale),
                else => dpi.scale(16, ui_scale),
            };
        }
        return dpi.scale(base_font_size, ui_scale);
    }

    fn estimatedLayoutCharWidth(host: *const types.UiHost) c_int {
        const scaled = dpi.scale(base_font_size, host.ui_scale);
        return @max(1, @divFloor(scaled * 11, 20));
    }

    fn layoutCharWidth(self: *const ReaderOverlayComponent, host: *const types.UiHost) c_int {
        if (self.layout_char_w_px > 0) return self.layout_char_w_px;
        return estimatedLayoutCharWidth(host);
    }

    fn computeWrapCols(self: *const ReaderOverlayComponent, host: *const types.UiHost) usize {
        const rect = FullscreenOverlay.overlayRect(host);
        const max_by_margin = @max(1, rect.w - dpi.scale(40, host.ui_scale));
        const max_by_ratio = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(rect.w)) * 0.72)));
        const column_w = @min(max_by_margin, max_by_ratio);
        const char_w = layoutCharWidth(self, host);
        const estimated_cols: usize = @intCast(@max(20, @divFloor(column_w - dpi.scale(24, host.ui_scale), @max(1, char_w))));
        return std.math.clamp(estimated_cols, 58, 220);
    }

    fn readingColumnRect(host: *const types.UiHost, rect: geom.Rect, wrap_cols: usize) geom.Rect {
        const char_w = @max(1, host.cell_w);
        const desired_w = @as(c_int, @intCast(wrap_cols)) * char_w;
        const min_outer_margin = dpi.scale(20, host.ui_scale);
        const max_by_margin = @max(1, rect.w - min_outer_margin * 2);
        const max_by_ratio = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(rect.w)) * 0.72)));
        const max_w = @min(max_by_margin, max_by_ratio);
        const min_w = @min(max_w, dpi.scale(420, host.ui_scale));
        const width = std.math.clamp(desired_w, min_w, max_w);
        return .{
            .x = rect.x + @divFloor(rect.w - width, 2),
            .y = rect.y,
            .w = width,
            .h = rect.h,
        };
    }

    fn jumpButtonRect(host: *const types.UiHost, overlay_rect: geom.Rect) geom.Rect {
        const w = dpi.scale(130, host.ui_scale);
        const h = dpi.scale(30, host.ui_scale);
        return .{
            .x = overlay_rect.x + overlay_rect.w - w - dpi.scale(18, host.ui_scale),
            .y = overlay_rect.y + overlay_rect.h - h - dpi.scale(18, host.ui_scale),
            .w = w,
            .h = h,
        };
    }

    fn searchBarRect(host: *const types.UiHost, overlay_rect: geom.Rect) geom.Rect {
        const h = dpi.scale(30, host.ui_scale);
        return .{
            .x = overlay_rect.x + dpi.scale(14, host.ui_scale),
            .y = overlay_rect.y + dpi.scale(58, host.ui_scale),
            .w = overlay_rect.w - dpi.scale(28, host.ui_scale),
            .h = h,
        };
    }

    fn toFColor(color: c.SDL_Color, alpha_scale: f32) c.SDL_FColor {
        return .{
            .r = @as(f32, @floatFromInt(color.r)) / 255.0,
            .g = @as(f32, @floatFromInt(color.g)) / 255.0,
            .b = @as(f32, @floatFromInt(color.b)) / 255.0,
            .a = (@as(f32, @floatFromInt(color.a)) / 255.0) * alpha_scale,
        };
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

    fn renderVerticalGradientRect(
        renderer: *c.SDL_Renderer,
        rect: c.SDL_FRect,
        top: c.SDL_Color,
        bottom: c.SDL_Color,
        alpha_scale: f32,
    ) void {
        if (rect.w <= 0 or rect.h <= 0) return;

        const top_col = toFColor(top, alpha_scale);
        const bottom_col = toFColor(bottom, alpha_scale);

        const verts = [_]c.SDL_Vertex{
            .{ .position = .{ .x = rect.x, .y = rect.y }, .color = top_col },
            .{ .position = .{ .x = rect.x + rect.w, .y = rect.y }, .color = top_col },
            .{ .position = .{ .x = rect.x, .y = rect.y + rect.h }, .color = bottom_col },
            .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + rect.h }, .color = bottom_col },
        };
        const indices = [_]c_int{ 0, 1, 2, 2, 1, 3 };
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_RenderGeometry(renderer, null, &verts, verts.len, &indices, indices.len);
    }

    fn renderHorizontalGradientRect(
        renderer: *c.SDL_Renderer,
        rect: c.SDL_FRect,
        left: c.SDL_Color,
        right: c.SDL_Color,
        alpha_scale: f32,
    ) void {
        if (rect.w <= 0 or rect.h <= 0) return;

        const left_col = toFColor(left, alpha_scale);
        const right_col = toFColor(right, alpha_scale);

        const verts = [_]c.SDL_Vertex{
            .{ .position = .{ .x = rect.x, .y = rect.y }, .color = left_col },
            .{ .position = .{ .x = rect.x + rect.w, .y = rect.y }, .color = right_col },
            .{ .position = .{ .x = rect.x, .y = rect.y + rect.h }, .color = left_col },
            .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + rect.h }, .color = right_col },
        };
        const indices = [_]c_int{ 0, 1, 2, 2, 1, 3 };
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_RenderGeometry(renderer, null, &verts, verts.len, &indices, indices.len);
    }

    fn splitTableCells(line: []const u8, cells: *[max_table_columns][]const u8) usize {
        var inner = std.mem.trim(u8, line, " \t");
        if (inner.len == 0) return 0;
        if (inner[0] == '|') inner = inner[1..];
        if (inner.len > 0 and inner[inner.len - 1] == '|') inner = inner[0 .. inner.len - 1];
        if (inner.len == 0) {
            cells[0] = "";
            return 1;
        }

        var count: usize = 0;
        var start: usize = 0;
        while (start <= inner.len and count < max_table_columns) {
            const end = std.mem.indexOfScalarPos(u8, inner, start, '|') orelse inner.len;
            cells[count] = std.mem.trim(u8, inner[start..end], " \t");
            count += 1;
            if (end == inner.len) break;
            start = end + 1;
        }
        return count;
    }

    fn isSeparatorCell(cell: []const u8) bool {
        if (cell.len == 0) return false;
        var dash_count: usize = 0;
        for (cell) |ch| {
            switch (ch) {
                '-' => dash_count += 1,
                ':' => {},
                else => return false,
            }
        }
        return dash_count >= 3;
    }

    fn isTableSeparatorLine(cells: []const []const u8) bool {
        if (cells.len == 0) return false;
        for (cells) |cell| {
            if (!isSeparatorCell(cell)) return false;
        }
        return true;
    }

    fn handleEventFn(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *ReaderOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (!self.overlay.visible) {
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                if (has_gui and !has_blocking and key == c.SDLK_R) {
                    actions.append(.ToggleReaderOverlay) catch |err| {
                        log.warn("failed to queue ToggleReaderOverlay action: {}", .{err});
                    };
                    return true;
                }
            }
            return false;
        }

        if (self.overlay.animation_state == .closing) {
            return switch (event.type) {
                c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING, c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_WHEEL, c.SDL_EVENT_MOUSE_MOTION => true,
                else => false,
            };
        }

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;
                const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;

                if (has_gui and !has_blocking and key == c.SDLK_R) {
                    actions.append(.ToggleReaderOverlay) catch |err| {
                        log.warn("failed to queue ToggleReaderOverlay action: {}", .{err});
                    };
                    return true;
                }

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
                    actions.append(.ToggleReaderOverlay) catch |err| {
                        log.warn("failed to queue ToggleReaderOverlay action: {}", .{err});
                    };
                    return true;
                }

                if (self.overlay.handleScrollKey(key, host)) {
                    self.scrollbar_state.noteActivity(host.now_ms);
                    self.updatePinnedState();
                    if (!self.isAtBottom()) self.pinned_to_bottom = false;
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
                self.updatePinnedState();
                if (!self.isAtBottom()) self.pinned_to_bottom = false;
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mx: c_int = @intFromFloat(event.button.x);
                const my: c_int = @intFromFloat(event.button.y);

                if (FullscreenOverlay.isCloseButtonHit(mx, my, host)) {
                    actions.append(.ToggleReaderOverlay) catch |err| {
                        log.warn("failed to queue ToggleReaderOverlay action: {}", .{err});
                    };
                    return true;
                }

                const overlay_rect = FullscreenOverlay.overlayRect(host);
                const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
                const metrics = self.syncScrollMetrics(host);

                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    if (scrollbar.computeLayout(scrollContentRect(overlay_rect, title_h), host.ui_scale, metrics)) |layout| {
                        switch (scrollbar.hitTest(layout, mx, my)) {
                            .thumb => {
                                self.scrollbar_state.beginDrag(layout, my, host.now_ms);
                                return true;
                            },
                            .track => {
                                self.overlay.scroll_offset = scrollbar.offsetForTrackClick(layout, metrics, my);
                                self.scrollbar_state.noteActivity(host.now_ms);
                                self.overlay.first_frame.markTransition();
                                self.updatePinnedState();
                                if (!self.isAtBottom()) self.pinned_to_bottom = false;
                                return true;
                            },
                            .none => {},
                        }
                    }
                }

                if (!self.pinned_to_bottom and self.overlay.max_scroll > 0) {
                    const jump_rect = jumpButtonRect(host, overlay_rect);
                    if (geom.containsPoint(jump_rect, mx, my)) {
                        self.pinned_to_bottom = true;
                        self.overlay.scroll_offset = self.overlay.max_scroll;
                        return true;
                    }
                }

                const search_rect = searchBarRect(host, overlay_rect);
                if (geom.containsPoint(search_rect, mx, my)) {
                    self.search_active = true;
                    return true;
                }

                if (event.button.button == c.SDL_BUTTON_LEFT) {
                    if (self.linkHitIndexAt(mx, my)) |hit_idx| {
                        const href = self.link_hits.items[hit_idx].href;
                        open_url.openUrl(self.allocator, href) catch |err| {
                            log.warn("failed to open reader link {s}: {}", .{ href, err });
                        };
                        return true;
                    }
                }

                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mx: c_int = @intFromFloat(event.motion.x);
                const my: c_int = @intFromFloat(event.motion.y);
                self.overlay.updateCloseHover(mx, my, host);
                const overlay_rect = FullscreenOverlay.overlayRect(host);
                const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
                const metrics = self.syncScrollMetrics(host);
                const scroll_layout = scrollbar.computeLayout(scrollContentRect(overlay_rect, title_h), host.ui_scale, metrics);

                if (self.scrollbar_state.dragging) {
                    if (scroll_layout) |layout| {
                        self.overlay.scroll_offset = scrollbar.offsetForDrag(&self.scrollbar_state, layout, metrics, my);
                        self.scrollbar_state.noteActivity(host.now_ms);
                        self.updatePinnedState();
                        if (!self.isAtBottom()) self.pinned_to_bottom = false;
                    } else {
                        self.scrollbar_state.endDrag(host.now_ms);
                    }
                }
                const scroll_hit = if (scroll_layout) |layout| scrollbar.hitTest(layout, mx, my) else .none;
                self.scrollbar_state.setHovered(self.scrollbar_state.dragging or scroll_hit != .none, host.now_ms);

                self.hovered_link = self.linkHitIndexAt(mx, my);

                var want_pointer = false;
                if (self.overlay.close_hovered) {
                    want_pointer = true;
                }
                if (!self.pinned_to_bottom and self.overlay.max_scroll > 0) {
                    const jump_rect = jumpButtonRect(host, overlay_rect);
                    if (geom.containsPoint(jump_rect, mx, my)) {
                        want_pointer = true;
                    }
                }
                if (self.hovered_link != null) want_pointer = true;
                if (self.scrollbar_state.dragging or scroll_hit != .none) want_pointer = true;

                if (want_pointer) {
                    if (self.pointer_cursor) |cur| _ = c.SDL_SetCursor(cur);
                } else if (self.arrow_cursor) |cur| {
                    _ = c.SDL_SetCursor(cur);
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT and self.scrollbar_state.dragging) {
                    self.scrollbar_state.endDrag(host.now_ms);
                    return true;
                }
                return true;
            },
            else => return false,
        }
    }

    fn updateFn(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *ReaderOverlayComponent = @ptrCast(@alignCast(self_ptr));
        _ = self.overlay.updateAnimation(host.now_ms);
        self.scrollbar_state.update(host.now_ms);

        if (!self.overlay.visible) return;

        const new_wrap = self.computeWrapCols(host);
        if (new_wrap != self.wrap_cols) {
            self.wrap_cols = new_wrap;
            self.rebuildLines(host, false);
        }

        if (self.session_index < self.sessions.len) {
            const session = self.sessions[self.session_index];
            if (session.render_epoch != self.last_render_epoch) {
                self.refreshFromSession(host, false);
            } else {
                _ = self.syncScrollMetrics(host);
            }
        }

        if (self.pinned_to_bottom) {
            self.overlay.scroll_offset = self.overlay.max_scroll;
        }
    }

    fn hitTestFn(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *ReaderOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.hitTest(host, x, y);
    }

    fn wantsFrameFn(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *ReaderOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.overlay.wantsFrame() or
            self.hovered_link != null or
            self.scrollbar_state.wantsFrame(host.now_ms);
    }

    fn renderFn(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *ReaderOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.overlay.visible) return;

        const font_cache = assets.font_cache orelse return;

        const progress = self.overlay.renderProgress(host.now_ms);
        self.overlay.render_alpha = progress;
        if (progress <= 0.001) return;

        const overlay_rect = FullscreenOverlay.animatedOverlayRect(host, progress);
        const title_h = dpi.scale(FullscreenOverlay.title_height, host.ui_scale);
        const content_rect = scrollContentRect(overlay_rect, title_h);
        const content_height = totalContentHeight(self, host);
        const viewport_height: f32 = @floatFromInt(content_rect.h);
        self.overlay.max_scroll = @max(0, content_height - viewport_height);
        self.overlay.scroll_offset = std.math.clamp(self.overlay.scroll_offset, 0, self.overlay.max_scroll);
        const scroll_metrics = scrollbar.Metrics.init(content_height, self.overlay.scroll_offset, viewport_height);

        self.overlay.renderFrame(renderer, host, overlay_rect, progress);

        const title_fonts = font_cache.get(dpi.scale(18, host.ui_scale)) catch return;
        const title_tex = makeTextTexture(self.allocator, renderer, title_fonts.bold orelse title_fonts.regular, "Reader Mode", host.theme.foreground) catch return;
        defer c.SDL_DestroyTexture(title_tex.tex);
        self.overlay.renderTitle(renderer, overlay_rect, title_tex.tex, title_tex.w, title_tex.h, host);
        FullscreenOverlay.renderTitleSeparator(renderer, host, overlay_rect, progress);
        self.overlay.renderCloseButton(renderer, host, overlay_rect);

        if (self.search_active or self.search_query.items.len > 0) {
            self.renderSearchBar(renderer, host, overlay_rect, font_cache) catch |err| {
                log.warn("failed to render reader search bar: {}", .{err});
            };
        }

        if (font_cache.get(dpi.scale(base_font_size, host.ui_scale)) catch null) |body_fonts| {
            if (measureCharWidth(self.allocator, renderer, body_fonts.regular)) |measured_char_w| {
                if (measured_char_w > 0 and measured_char_w != self.layout_char_w_px) {
                    self.layout_char_w_px = measured_char_w;
                    const new_wrap = self.computeWrapCols(host);
                    if (new_wrap != self.wrap_cols) {
                        self.wrap_cols = new_wrap;
                        self.rebuildLines(host, false);
                    }
                }
            }
        } else if (self.layout_char_w_px == 0) {
            self.layout_char_w_px = estimatedLayoutCharWidth(host);
        }

        const content_clip = c.SDL_Rect{
            .x = content_rect.x,
            .y = content_rect.y,
            .w = content_rect.w,
            .h = content_rect.h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &content_clip);

        const col_rect = readingColumnRect(host, overlay_rect, self.wrap_cols);
        const scaled_padding = dpi.scale(10, host.ui_scale);
        const cached_char_w = layoutCharWidth(self, host);
        const hovered_href = self.hoveredLinkHref();
        self.link_hits.clearRetainingCapacity();
        var y: c_int = overlay_rect.y + title_h + scaled_padding - @as(c_int, @intFromFloat(self.overlay.scroll_offset));

        for (self.lines.items, 0..) |line, idx| {
            const lh = self.lineHeight(line, host);
            if (y + lh < content_clip.y) {
                y += lh;
                continue;
            }
            if (y > content_clip.y + content_clip.h) break;

            if (line.kind == .table) {
                self.renderTableLine(renderer, host, font_cache, col_rect, y, lh, idx, line, hovered_href, progress, scaled_padding);
                y += lh;
                continue;
            }

            if (line.kind == .code) {
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                _ = c.SDL_SetRenderDrawColor(renderer, host.theme.selection.r, host.theme.selection.g, host.theme.selection.b, @intFromFloat(45.0 * progress));
                _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                    .x = @floatFromInt(col_rect.x),
                    .y = @floatFromInt(y),
                    .w = @floatFromInt(col_rect.w),
                    .h = @floatFromInt(lh),
                });
            }

            if (line.kind == .horizontal_rule) {
                _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(180.0 * progress));
                const line_y = y + @divFloor(lh, 2);
                _ = c.SDL_RenderLine(renderer, @floatFromInt(col_rect.x), @floatFromInt(line_y), @floatFromInt(col_rect.x + col_rect.w), @floatFromInt(line_y));
                y += lh;
                continue;
            }

            if (line.kind == .prompt_separator) {
                self.renderPromptSeparator(renderer, host, col_rect, y, lh, progress, scaled_padding);
                y += lh;
                continue;
            }

            if (line.quote_depth > 0) {
                renderQuoteBackground(renderer, host, col_rect, y, lh, progress, scaled_padding);
            }

            const line_font_size = fontSizeForLine(line, host.ui_scale);
            const line_fonts = font_cache.get(line_font_size) catch |err| {
                log.warn("failed to load reader font size {d}: {}", .{ line_font_size, err });
                y += lh;
                continue;
            };

            self.renderSearchHighlights(renderer, host, col_rect, y, lh, cached_char_w, idx);

            var x = col_rect.x + scaled_padding;
            if (line.quote_depth > 0) {
                x += dpi.scale(10, host.ui_scale);
            }
            for (line.runs) |run| {
                const run_font = chooseFont(line_fonts, run, line.heading_level > 0);
                const link_hovered = if (hovered_href) |href|
                    run.href != null and std.mem.eql(u8, run.href.?, href)
                else
                    false;
                const run_color = chooseRunColor(host, line, run, link_hovered);
                const tex = makeTextTexture(self.allocator, renderer, run_font, run.text, run_color) catch |err| {
                    log.warn("failed to render reader line run texture: {}", .{err});
                    continue;
                };
                defer c.SDL_DestroyTexture(tex.tex);
                const max_text_h = @max(1, lh - dpi.scale(4, host.ui_scale));
                const draw_size = fitTextureHeight(tex.w, tex.h, max_text_h);
                const draw_y = y + @divFloor(lh - draw_size.h, 2);
                _ = c.SDL_SetTextureAlphaMod(tex.tex, @intFromFloat(255.0 * progress));
                _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                    .x = @floatFromInt(x),
                    .y = @floatFromInt(draw_y),
                    .w = @floatFromInt(draw_size.w),
                    .h = @floatFromInt(draw_size.h),
                });
                if (run.href) |href| {
                    self.link_hits.append(self.allocator, .{
                        .rect = .{
                            .x = x,
                            .y = draw_y,
                            .w = draw_size.w,
                            .h = draw_size.h,
                        },
                        .href = href,
                    }) catch |err| {
                        log.warn("failed to track reader link hitbox: {}", .{err});
                    };
                }
                if (run.style == .strikethrough) {
                    const strike_y = y + @divFloor(lh, 2);
                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(renderer, run_color.r, run_color.g, run_color.b, @intFromFloat(220.0 * progress));
                    _ = c.SDL_RenderLine(
                        renderer,
                        @floatFromInt(x),
                        @floatFromInt(strike_y),
                        @floatFromInt(x + draw_size.w),
                        @floatFromInt(strike_y),
                    );
                }
                if (run.style == .link) {
                    const underline_y = y + @divFloor(lh * 3, 4);
                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(renderer, run_color.r, run_color.g, run_color.b, @intFromFloat(220.0 * progress));
                    _ = c.SDL_RenderLine(
                        renderer,
                        @floatFromInt(x),
                        @floatFromInt(underline_y),
                        @floatFromInt(x + draw_size.w),
                        @floatFromInt(underline_y),
                    );
                }
                x += draw_size.w;
            }

            y += lh;
        }

        _ = c.SDL_SetRenderClipRect(renderer, null);

        if (!self.pinned_to_bottom and self.overlay.max_scroll > 0) {
            self.renderJumpButton(renderer, host, overlay_rect, font_cache) catch |err| {
                log.warn("failed to render reader jump button: {}", .{err});
            };
        }

        if (scrollbar.computeLayout(content_rect, host.ui_scale, scroll_metrics)) |layout| {
            scrollbar.render(renderer, layout, host.theme.accent, &self.scrollbar_state);
            self.scrollbar_state.markDrawn();
        } else {
            self.scrollbar_state.hideNow();
        }

        self.overlay.first_frame.markDrawn();
    }

    fn renderTableLine(
        self: *ReaderOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        font_cache: *FontCache,
        col_rect: geom.Rect,
        y: c_int,
        lh: c_int,
        line_idx: usize,
        line: markdown_renderer.RenderLine,
        hovered_href: ?[]const u8,
        progress: f32,
        scaled_padding: c_int,
    ) void {
        const metrics = self.tableRowMetrics(host, line);
        if (metrics.col_count == 0) return;

        const row_rect = geom.Rect{
            .x = col_rect.x + scaled_padding,
            .y = y,
            .w = col_rect.w - scaled_padding * 2,
            .h = lh,
        };
        if (row_rect.w <= 0 or row_rect.h <= 0) return;

        const top_bg = host.theme.selection;
        const bottom_bg = host.theme.background;
        renderVerticalGradientRect(renderer, .{
            .x = @floatFromInt(row_rect.x),
            .y = @floatFromInt(row_rect.y),
            .w = @floatFromInt(row_rect.w),
            .h = @floatFromInt(row_rect.h),
        }, top_bg, bottom_bg, 0.32 * progress);
        const is_separator = metrics.is_separator;
        const prev_is_table = line_idx > 0 and self.lines.items[line_idx - 1].kind == .table;
        const next_is_table = line_idx + 1 < self.lines.items.len and self.lines.items[line_idx + 1].kind == .table;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(170.0 * progress));

        const left = row_rect.x;
        const right = row_rect.x + row_rect.w;
        const top = row_rect.y;
        const bottom = row_rect.y + row_rect.h;

        if (!prev_is_table) {
            _ = c.SDL_RenderLine(renderer, @floatFromInt(left), @floatFromInt(top), @floatFromInt(right), @floatFromInt(top));
        }
        if (!next_is_table) {
            _ = c.SDL_RenderLine(renderer, @floatFromInt(left), @floatFromInt(bottom), @floatFromInt(right), @floatFromInt(bottom));
        } else {
            _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(110.0 * progress));
            _ = c.SDL_RenderLine(renderer, @floatFromInt(left), @floatFromInt(bottom), @floatFromInt(right), @floatFromInt(bottom));
            _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(170.0 * progress));
        }

        const count_i: c_int = @intCast(metrics.col_count);
        var col: c_int = 0;
        while (col <= count_i) : (col += 1) {
            const x = if (col == count_i)
                right
            else
                left + @divFloor(row_rect.w * col, count_i);
            _ = c.SDL_RenderLine(renderer, @floatFromInt(x), @floatFromInt(top), @floatFromInt(x), @floatFromInt(bottom));
        }

        if (is_separator) {
            const sep_y = top + @divFloor(lh, 2);
            _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(210.0 * progress));
            _ = c.SDL_RenderLine(renderer, @floatFromInt(left), @floatFromInt(sep_y), @floatFromInt(right), @floatFromInt(sep_y));
            return;
        }

        const line_font_size = fontSizeForLine(line, host.ui_scale);
        const line_fonts = font_cache.get(line_font_size) catch |err| {
            log.warn("failed to load reader table font size {d}: {}", .{ line_font_size, err });
            return;
        };
        const cell_pad = dpi.scale(8, host.ui_scale);

        var cell_idx: usize = 0;
        while (cell_idx < metrics.col_count) : (cell_idx += 1) {
            const cell_left = left + @divFloor(row_rect.w * @as(c_int, @intCast(cell_idx)), count_i);
            const cell_plain = if (cell_idx < line.table_cells.len)
                line.table_cells[cell_idx].plain_text
            else
                metrics.cells[cell_idx];
            const cell_runs: []const markdown_renderer.RenderRun = if (cell_idx < line.table_cells.len)
                line.table_cells[cell_idx].runs
            else
                &.{};
            if (cell_plain.len == 0) continue;

            const text_x = cell_left + cell_pad;
            const text_y = y + @divFloor(lh - (@as(c_int, @intCast(metrics.max_lines)) * metrics.line_px), 2);
            self.renderWrappedTableCellRuns(
                renderer,
                host,
                line,
                line_fonts,
                cell_runs,
                cell_plain,
                hovered_href,
                text_x,
                text_y,
                metrics.cell_cols,
                metrics.line_px,
                progress,
            );
        }
    }

    fn renderWrappedTableCellRuns(
        self: *ReaderOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        line: markdown_renderer.RenderLine,
        fonts: *FontSet,
        runs: []const markdown_renderer.RenderRun,
        plain_text: []const u8,
        hovered_href: ?[]const u8,
        x: c_int,
        y: c_int,
        max_cols: usize,
        line_px: c_int,
        progress: f32,
    ) void {
        if (plain_text.len == 0 or max_cols == 0) return;
        if (runs.len == 0) {
            const fallback_color = if (line.kind == .table) host.theme.palette[6] else host.theme.foreground;
            self.renderTableCellPlainLine(renderer, fonts.regular, fallback_color, plain_text, x, y, line_px, progress);
            return;
        }

        var wrapped_runs = std.ArrayList(WrappedTableRun).empty;
        defer wrapped_runs.deinit(self.allocator);

        var draw_y = y;
        var cols: usize = 0;
        for (runs) |run| {
            var token_start: usize = 0;
            while (token_start < run.text.len) {
                if (run.text[token_start] == '\n') {
                    self.renderWrappedTableCellLine(renderer, host, line, fonts, wrapped_runs.items, x, draw_y, line_px, hovered_href, progress);
                    wrapped_runs.clearRetainingCapacity();
                    cols = 0;
                    draw_y += line_px;
                    token_start += 1;
                    continue;
                }

                const is_space = run.text[token_start] == ' ' or run.text[token_start] == '\t';
                var token_end = token_start + 1;
                while (token_end < run.text.len and run.text[token_end] != '\n' and ((run.text[token_end] == ' ' or run.text[token_end] == '\t') == is_space)) : (token_end += 1) {}

                var token = run.text[token_start..token_end];
                token_start = token_end;
                while (token.len > 0) {
                    if (is_space and cols == 0) break;

                    if (!is_space and token.len > max_cols) {
                        if (cols > 0) {
                            self.renderWrappedTableCellLine(renderer, host, line, fonts, wrapped_runs.items, x, draw_y, line_px, hovered_href, progress);
                            wrapped_runs.clearRetainingCapacity();
                            cols = 0;
                            draw_y += line_px;
                        }

                        const chunk_len = @min(max_cols, token.len);
                        wrapped_runs.append(self.allocator, .{
                            .text = token[0..chunk_len],
                            .style = run.style,
                            .href = run.href,
                        }) catch |err| {
                            log.warn("failed to append wrapped table run chunk: {}", .{err});
                            return;
                        };
                        cols += chunk_len;
                        token = token[chunk_len..];

                        if (cols >= max_cols and token.len > 0) {
                            self.renderWrappedTableCellLine(renderer, host, line, fonts, wrapped_runs.items, x, draw_y, line_px, hovered_href, progress);
                            wrapped_runs.clearRetainingCapacity();
                            cols = 0;
                            draw_y += line_px;
                        }
                        continue;
                    }

                    if (cols + token.len > max_cols and cols > 0) {
                        self.renderWrappedTableCellLine(renderer, host, line, fonts, wrapped_runs.items, x, draw_y, line_px, hovered_href, progress);
                        wrapped_runs.clearRetainingCapacity();
                        cols = 0;
                        draw_y += line_px;
                        if (is_space) {
                            token = "";
                            continue;
                        }
                    }

                    wrapped_runs.append(self.allocator, .{
                        .text = token,
                        .style = run.style,
                        .href = run.href,
                    }) catch |err| {
                        log.warn("failed to append wrapped table run token: {}", .{err});
                        return;
                    };
                    cols += token.len;
                    token = "";
                }
            }
        }

        self.renderWrappedTableCellLine(renderer, host, line, fonts, wrapped_runs.items, x, draw_y, line_px, hovered_href, progress);
    }

    fn renderWrappedTableCellLine(
        self: *ReaderOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        line: markdown_renderer.RenderLine,
        fonts: *FontSet,
        wrapped_runs: []const WrappedTableRun,
        x: c_int,
        y: c_int,
        max_h: c_int,
        hovered_href: ?[]const u8,
        progress: f32,
    ) void {
        if (wrapped_runs.len == 0) return;

        var draw_x = x;
        for (wrapped_runs) |wrapped_run| {
            if (wrapped_run.text.len == 0) continue;

            const run_font = chooseFontForStyle(fonts, wrapped_run.style, false);
            const link_hovered = if (hovered_href) |href|
                wrapped_run.href != null and std.mem.eql(u8, wrapped_run.href.?, href)
            else
                false;
            const run_color = chooseRunColorForStyle(host, line, wrapped_run.style, false, link_hovered);
            const tex = makeTextTexture(self.allocator, renderer, run_font, wrapped_run.text, run_color) catch |err| {
                log.warn("failed to render wrapped table run texture: {}", .{err});
                continue;
            };
            defer c.SDL_DestroyTexture(tex.tex);

            const draw_size = fitTextureHeight(tex.w, tex.h, @max(1, max_h - 2));
            const draw_y = y + @divFloor(max_h - draw_size.h, 2);
            _ = c.SDL_SetTextureAlphaMod(tex.tex, @intFromFloat(255.0 * progress));
            _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(draw_x),
                .y = @floatFromInt(draw_y),
                .w = @floatFromInt(draw_size.w),
                .h = @floatFromInt(draw_size.h),
            });

            if (wrapped_run.href) |href| {
                self.link_hits.append(self.allocator, .{
                    .rect = .{
                        .x = draw_x,
                        .y = draw_y,
                        .w = draw_size.w,
                        .h = draw_size.h,
                    },
                    .href = href,
                }) catch |err| {
                    log.warn("failed to track reader table link hitbox: {}", .{err});
                };
            }

            if (wrapped_run.style == .strikethrough) {
                const strike_y = y + @divFloor(max_h, 2);
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                _ = c.SDL_SetRenderDrawColor(renderer, run_color.r, run_color.g, run_color.b, @intFromFloat(220.0 * progress));
                _ = c.SDL_RenderLine(
                    renderer,
                    @floatFromInt(draw_x),
                    @floatFromInt(strike_y),
                    @floatFromInt(draw_x + draw_size.w),
                    @floatFromInt(strike_y),
                );
            }
            if (wrapped_run.style == .link) {
                const underline_y = y + @divFloor(max_h * 3, 4);
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                _ = c.SDL_SetRenderDrawColor(renderer, run_color.r, run_color.g, run_color.b, @intFromFloat(220.0 * progress));
                _ = c.SDL_RenderLine(
                    renderer,
                    @floatFromInt(draw_x),
                    @floatFromInt(underline_y),
                    @floatFromInt(draw_x + draw_size.w),
                    @floatFromInt(underline_y),
                );
            }

            draw_x += draw_size.w;
        }
    }

    fn renderTableCellPlainLine(
        self: *ReaderOverlayComponent,
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        color: c.SDL_Color,
        text: []const u8,
        x: c_int,
        y: c_int,
        max_h: c_int,
        progress: f32,
    ) void {
        if (text.len == 0) return;

        const tex = makeTextTexture(self.allocator, renderer, font, text, color) catch |err| {
            log.warn("failed to render table cell plain line texture: {}", .{err});
            return;
        };
        defer c.SDL_DestroyTexture(tex.tex);

        const draw_size = fitTextureHeight(tex.w, tex.h, @max(1, max_h - 2));
        _ = c.SDL_SetTextureAlphaMod(tex.tex, @intFromFloat(255.0 * progress));
        _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y + @divFloor(max_h - draw_size.h, 2)),
            .w = @floatFromInt(draw_size.w),
            .h = @floatFromInt(draw_size.h),
        });
    }

    fn renderQuoteBackground(renderer: *c.SDL_Renderer, host: *const types.UiHost, col_rect: geom.Rect, y: c_int, lh: c_int, progress: f32, scaled_padding: c_int) void {
        const quote_rect = geom.Rect{
            .x = col_rect.x + scaled_padding,
            .y = y,
            .w = col_rect.w - scaled_padding * 2,
            .h = lh,
        };
        if (quote_rect.w <= 0 or quote_rect.h <= 0) return;

        const top_bg = host.theme.palette[0];
        const bottom_bg = host.theme.selection;
        renderVerticalGradientRect(renderer, .{
            .x = @floatFromInt(quote_rect.x),
            .y = @floatFromInt(quote_rect.y),
            .w = @floatFromInt(quote_rect.w),
            .h = @floatFromInt(quote_rect.h),
        }, top_bg, bottom_bg, 0.35 * progress);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, @intFromFloat(180.0 * progress));
        _ = c.SDL_RenderRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(quote_rect.x),
            .y = @floatFromInt(quote_rect.y),
            .w = @floatFromInt(quote_rect.w),
            .h = @floatFromInt(quote_rect.h),
        });
    }

    fn renderPromptSeparator(
        self: *ReaderOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        col_rect: geom.Rect,
        y: c_int,
        lh: c_int,
        progress: f32,
        scaled_padding: c_int,
    ) void {
        _ = self;
        const separator_h = @max(dpi.scale(6, host.ui_scale), @divFloor(lh, 2));
        const separator_y = y + @divFloor(lh - separator_h, 2);
        const separator_rect = geom.Rect{
            .x = col_rect.x + scaled_padding,
            .y = separator_y,
            .w = col_rect.w - scaled_padding * 2,
            .h = separator_h,
        };
        if (separator_rect.w <= 0 or separator_rect.h <= 0) return;

        renderHorizontalGradientRect(renderer, .{
            .x = @floatFromInt(separator_rect.x),
            .y = @floatFromInt(separator_rect.y),
            .w = @floatFromInt(separator_rect.w),
            .h = @floatFromInt(separator_rect.h),
        }, host.theme.accent, host.theme.selection, 0.8 * progress);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.foreground.r, host.theme.foreground.g, host.theme.foreground.b, @intFromFloat(95.0 * progress));
        _ = c.SDL_RenderRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(separator_rect.x),
            .y = @floatFromInt(separator_rect.y),
            .w = @floatFromInt(separator_rect.w),
            .h = @floatFromInt(separator_rect.h),
        });
    }

    fn renderSearchHighlights(
        self: *ReaderOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        col_rect: geom.Rect,
        y: c_int,
        lh: c_int,
        char_w: c_int,
        line_idx: usize,
    ) void {
        const query = std.mem.trim(u8, self.search_query.items, " \t");
        if (query.len == 0) return;

        for (self.matches.items, 0..) |match_item, match_idx| {
            if (match_item.line_index != line_idx) continue;

            const selected = self.selected_match != null and self.selected_match.? == match_idx;
            const bg = if (selected) host.theme.accent else host.theme.selection;
            const alpha: u8 = if (selected) 180 else 120;

            const x = col_rect.x + dpi.scale(10, host.ui_scale) + @as(c_int, @intCast(match_item.start)) * char_w;
            const w = @as(c_int, @intCast(match_item.len)) * char_w;

            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, alpha);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y + dpi.scale(3, host.ui_scale)),
                .w = @floatFromInt(w),
                .h = @floatFromInt(lh - dpi.scale(6, host.ui_scale)),
            });
        }
    }

    fn renderSearchBar(self: *ReaderOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, overlay_rect: geom.Rect, font_cache: *FontCache) !void {
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

    fn renderJumpButton(self: *ReaderOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, overlay_rect: geom.Rect, font_cache: *FontCache) !void {
        const rect = jumpButtonRect(host, overlay_rect);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 210);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        });

        const fonts = try font_cache.get(dpi.scale(13, host.ui_scale));
        const label_tex = try makeTextTexture(self.allocator, renderer, fonts.bold orelse fonts.regular, "Jump to bottom", host.theme.background);
        defer c.SDL_DestroyTexture(label_tex.tex);
        _ = c.SDL_RenderTexture(renderer, label_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + @divFloor(rect.w - label_tex.w, 2)),
            .y = @floatFromInt(rect.y + @divFloor(rect.h - label_tex.h, 2)),
            .w = @floatFromInt(label_tex.w),
            .h = @floatFromInt(label_tex.h),
        });
    }

    fn chooseRunColor(host: *const types.UiHost, line: markdown_renderer.RenderLine, run: markdown_renderer.RenderRun, link_hovered: bool) c.SDL_Color {
        return chooseRunColorForStyle(host, line, run.style, run.marker, link_hovered);
    }

    fn chooseRunColorForStyle(
        host: *const types.UiHost,
        line: markdown_renderer.RenderLine,
        style: markdown_parser.InlineStyle,
        marker: bool,
        link_hovered: bool,
    ) c.SDL_Color {
        if (line.heading_level > 0) {
            return host.theme.accent;
        }

        if (style == .link) {
            return if (link_hovered) host.theme.palette[5] else host.theme.accent;
        }
        if (style == .code) {
            return host.theme.palette[3];
        }
        if (style == .bold) {
            return host.theme.foreground;
        }
        if (style == .italic) {
            return host.theme.palette[4];
        }
        if (line.kind == .code) {
            return host.theme.palette[6];
        }
        if (marker) {
            return host.theme.palette[3];
        }
        if (line.kind == .table) {
            return host.theme.palette[6];
        }
        return host.theme.foreground;
    }

    fn chooseFont(fonts: *FontSet, run: markdown_renderer.RenderRun, force_bold: bool) *c.TTF_Font {
        return chooseFontForStyle(fonts, run.style, force_bold);
    }

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

    fn measureCharWidth(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, font: *c.TTF_Font) ?c_int {
        const tex = makeTextTexture(allocator, renderer, font, "0", c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 }) catch return null;
        defer c.SDL_DestroyTexture(tex.tex);
        return @max(1, tex.w);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *ReaderOverlayComponent = @ptrCast(@alignCast(self_ptr));
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
