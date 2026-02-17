const std = @import("std");
const c = @import("../c.zig");
const colors = @import("../colors.zig");
const ghostty_vt = @import("ghostty-vt");
const app_state = @import("../app/app_state.zig");
const grid_layout = @import("../app/grid_layout.zig");
const geom = @import("../geom.zig");
const easing = @import("../anim/easing.zig");
const font_mod = @import("../font.zig");
const FontVariant = font_mod.Variant;
const session_state = @import("../session/state.zig");
const view_state = @import("../ui/session_view_state.zig");
const primitives = @import("../gfx/primitives.zig");
const box_drawing = @import("../gfx/box_drawing.zig");
const session_interaction = @import("../ui/components/session_interaction.zig");
const scrollbar = @import("../ui/components/scrollbar.zig");

const log = std.log.scoped(.render);

const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;
const Rect = geom.Rect;
const AnimationState = app_state.AnimationState;
const GridLayout = grid_layout.GridLayout;

const attention_thickness: c_int = 3;
pub const terminal_padding: c_int = 8;
pub const grid_border_thickness: c_int = attention_thickness;
const faint_factor: f32 = 0.6;
const cursor_color = c.SDL_Color{ .r = 215, .g = 186, .b = 125, .a = 255 };
const dark_fallback = c.SDL_Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

pub const RenderError = font_mod.Font.RenderGlyphError;

pub const RenderCache = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub const Entry = struct {
        texture: ?*c.SDL_Texture = null,
        width: c_int = 0,
        height: c_int = 0,
        cache_epoch: u64 = 0,
        presented_epoch: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, session_count: usize) !RenderCache {
        const entries = try allocator.alloc(Entry, session_count);
        for (entries) |*cache_entry| {
            cache_entry.* = .{};
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *RenderCache) void {
        for (self.entries) |cache_entry| {
            if (cache_entry.texture) |tex| {
                c.SDL_DestroyTexture(tex);
            }
        }
        self.allocator.free(self.entries);
        self.entries = &[_]Entry{};
    }

    pub fn entry(self: *RenderCache, idx: usize) *Entry {
        return &self.entries[idx];
    }

    pub fn anyDirty(self: *RenderCache, sessions: []const *SessionState) bool {
        std.debug.assert(sessions.len == self.entries.len);
        for (sessions, 0..) |session, i| {
            if (!session.spawned) continue;
            if (session.render_epoch != self.entries[i].presented_epoch) return true;
        }
        return false;
    }
};

pub fn render(
    renderer: *c.SDL_Renderer,
    render_cache: *RenderCache,
    sessions: []const *SessionState,
    views: []SessionViewState,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    grid_cols: usize,
    grid_rows: usize,
    anim_state: *const AnimationState,
    current_time: i64,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    window_width: c_int,
    window_height: c_int,
    theme: *const colors.Theme,
    ui_scale: f32,
    grid_font_scale: f32,
    grid: ?*const GridLayout,
) RenderError!void {
    _ = c.SDL_SetRenderDrawColor(renderer, theme.background.r, theme.background.g, theme.background.b, 255);
    _ = c.SDL_RenderClear(renderer);
    std.debug.assert(sessions.len == views.len);

    // Use the larger dimension for grid scale to ensure proper scaling
    // Multiply by grid_font_scale to allow proportionally larger font in grid view
    const grid_dim = @max(grid_cols, grid_rows);
    const base_grid_scale: f32 = 1.0 / @as(f32, @floatFromInt(grid_dim));
    const grid_scale: f32 = base_grid_scale * grid_font_scale;
    const grid_slots_to_render: usize = @min(sessions.len, grid_cols * grid_rows);

    switch (anim_state.mode) {
        .Grid => {
            var i: usize = 0;
            while (i < grid_slots_to_render) : (i += 1) {
                const session = sessions[i];
                if (!session.spawned) continue;
                const grid_row: c_int = @intCast(i / grid_cols);
                const grid_col: c_int = @intCast(i % grid_cols);

                const cell_rect = Rect{
                    .x = grid_col * cell_width_pixels,
                    .y = grid_row * cell_height_pixels,
                    .w = cell_width_pixels,
                    .h = cell_height_pixels,
                };

                const entry = render_cache.entry(i);
                try renderGridSessionCached(renderer, session, &views[i], entry, cell_rect, grid_scale, i == anim_state.focused_session, true, true, font, term_cols, term_rows, current_time, theme, ui_scale);
            }
        },
        .Full => {
            const full_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };
            const entry = render_cache.entry(anim_state.focused_session);
            try renderSession(renderer, sessions[anim_state.focused_session], &views[anim_state.focused_session], entry, full_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false, theme, ui_scale);
        },
        .PanningLeft, .PanningRight => {
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, app_state.animation_duration_ms));
            const eased = easing.easeInOutCubic(progress);

            const offset = @as(c_int, @intFromFloat(@as(f32, @floatFromInt(window_width)) * eased));
            const pan_offset = if (anim_state.mode == .PanningLeft) -offset else offset;

            const prev_rect = Rect{ .x = pan_offset, .y = 0, .w = window_width, .h = window_height };
            const prev_entry = render_cache.entry(anim_state.previous_session);
            try renderSession(renderer, sessions[anim_state.previous_session], &views[anim_state.previous_session], prev_entry, prev_rect, 1.0, false, false, font, term_cols, term_rows, current_time, false, theme, ui_scale);

            const new_offset = if (anim_state.mode == .PanningLeft)
                window_width - offset
            else
                -window_width + offset;
            const new_rect = Rect{ .x = new_offset, .y = 0, .w = window_width, .h = window_height };
            const new_entry = render_cache.entry(anim_state.focused_session);
            try renderSession(renderer, sessions[anim_state.focused_session], &views[anim_state.focused_session], new_entry, new_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false, theme, ui_scale);
        },
        .PanningUp, .PanningDown => {
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, app_state.animation_duration_ms));
            const eased = easing.easeInOutCubic(progress);

            const offset = @as(c_int, @intFromFloat(@as(f32, @floatFromInt(window_height)) * eased));
            const pan_offset = if (anim_state.mode == .PanningUp) -offset else offset;

            const prev_rect = Rect{ .x = 0, .y = pan_offset, .w = window_width, .h = window_height };
            const prev_entry = render_cache.entry(anim_state.previous_session);
            try renderSession(renderer, sessions[anim_state.previous_session], &views[anim_state.previous_session], prev_entry, prev_rect, 1.0, false, false, font, term_cols, term_rows, current_time, false, theme, ui_scale);

            const new_offset = if (anim_state.mode == .PanningUp)
                window_height - offset
            else
                -window_height + offset;
            const new_rect = Rect{ .x = 0, .y = new_offset, .w = window_width, .h = window_height };
            const new_entry = render_cache.entry(anim_state.focused_session);
            try renderSession(renderer, sessions[anim_state.focused_session], &views[anim_state.focused_session], new_entry, new_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false, theme, ui_scale);
        },
        .Expanding, .Collapsing => {
            const animating_rect = anim_state.getCurrentRect(current_time);
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, app_state.animation_duration_ms));
            const eased = easing.easeInOutCubic(progress);
            const anim_scale = if (anim_state.mode == .Expanding)
                grid_scale + (1.0 - grid_scale) * eased
            else
                1.0 - (1.0 - grid_scale) * eased;

            var i: usize = 0;
            while (i < grid_slots_to_render) : (i += 1) {
                const session = sessions[i];
                if (i != anim_state.focused_session) {
                    if (!session.spawned) continue;
                    const grid_row: c_int = @intCast(i / grid_cols);
                    const grid_col: c_int = @intCast(i % grid_cols);

                    const cell_rect = Rect{
                        .x = grid_col * cell_width_pixels,
                        .y = grid_row * cell_height_pixels,
                        .w = cell_width_pixels,
                        .h = cell_height_pixels,
                    };

                    const entry = render_cache.entry(i);
                    try renderGridSessionCached(renderer, session, &views[i], entry, cell_rect, grid_scale, false, true, true, font, term_cols, term_rows, current_time, theme, ui_scale);
                }
            }

            const apply_effects = anim_scale < 0.999;
            const entry = render_cache.entry(anim_state.focused_session);
            try renderSession(renderer, sessions[anim_state.focused_session], &views[anim_state.focused_session], entry, animating_rect, anim_scale, true, apply_effects, font, term_cols, term_rows, current_time, true, theme, ui_scale);
        },
        .GridResizing => {
            // Render session contents first so borders draw on top.
            for (sessions, 0..) |session, i| {
                if (!session.spawned) continue;

                // Get animated rect from GridLayout if available
                const cell_rect: Rect = if (grid) |g| blk: {
                    if (g.getAnimatedRect(i, current_time)) |animated_rect| {
                        break :blk animated_rect;
                    }
                    // New session or no animation - use final position
                    const pos = g.indexToPosition(i);
                    break :blk Rect{
                        .x = @as(c_int, @intCast(pos.col)) * cell_width_pixels,
                        .y = @as(c_int, @intCast(pos.row)) * cell_height_pixels,
                        .w = cell_width_pixels,
                        .h = cell_height_pixels,
                    };
                } else blk: {
                    // Fallback: calculate position from index
                    const grid_row: c_int = @intCast(i / grid_cols);
                    const grid_col: c_int = @intCast(i % grid_cols);
                    break :blk Rect{
                        .x = grid_col * cell_width_pixels,
                        .y = grid_row * cell_height_pixels,
                        .w = cell_width_pixels,
                        .h = cell_height_pixels,
                    };
                };

                const entry = render_cache.entry(i);
                try renderGridSessionCached(renderer, session, &views[i], entry, cell_rect, grid_scale, i == anim_state.focused_session, true, false, font, term_cols, term_rows, current_time, theme, ui_scale);
            }

            // Render borders and overlays on top of the animated content.
            for (sessions, 0..) |session, i| {
                if (!session.spawned) continue;

                const cell_rect: Rect = if (grid) |g| blk: {
                    if (g.getAnimatedRect(i, current_time)) |animated_rect| {
                        break :blk animated_rect;
                    }
                    const pos = g.indexToPosition(i);
                    break :blk Rect{
                        .x = @as(c_int, @intCast(pos.col)) * cell_width_pixels,
                        .y = @as(c_int, @intCast(pos.row)) * cell_height_pixels,
                        .w = cell_width_pixels,
                        .h = cell_height_pixels,
                    };
                } else blk: {
                    const grid_row: c_int = @intCast(i / grid_cols);
                    const grid_col: c_int = @intCast(i % grid_cols);
                    break :blk Rect{
                        .x = grid_col * cell_width_pixels,
                        .y = grid_row * cell_height_pixels,
                        .w = cell_width_pixels,
                        .h = cell_height_pixels,
                    };
                };

                renderSessionOverlays(renderer, session, &views[i], cell_rect, i == anim_state.focused_session, true, current_time, true, theme, ui_scale);
            }
        },
    }
}

fn renderSession(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    view: *SessionViewState,
    cache_entry: *RenderCache.Entry,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    apply_effects: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    current_time_ms: i64,
    is_grid_view: bool,
    theme: *const colors.Theme,
    ui_scale: f32,
) RenderError!void {
    try renderSessionContent(renderer, session, view, rect, scale, is_focused, font, term_cols, term_rows, current_time_ms, theme);
    renderSessionOverlays(renderer, session, view, rect, is_focused, apply_effects, current_time_ms, is_grid_view, theme, ui_scale);
    cache_entry.presented_epoch = session.render_epoch;
}

fn renderSessionContent(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    view: *const SessionViewState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    _: i64,
    theme: *const colors.Theme,
) RenderError!void {
    if (!session.spawned) return;

    const terminal = session.terminal orelse {
        log.err("session {d} is spawned but terminal is null!", .{session.id});
        return;
    };

    const base_bg = c.SDL_Color{ .r = theme.background.r, .g = theme.background.g, .b = theme.background.b, .a = 255 };
    const session_bg_color = if (terminal.colors.background.get()) |rgb|
        c.SDL_Color{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 }
    else
        base_bg;

    _ = c.SDL_SetRenderDrawColor(renderer, session_bg_color.r, session_bg_color.g, session_bg_color.b, session_bg_color.a);
    const bg_rect = c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = c.SDL_RenderFillRect(renderer, &bg_rect);
    const screen = terminal.screens.active;
    const cursor_visible = terminal.modes.get(.cursor_visible);
    const cursor = screen.cursor;
    const cursor_col: usize = cursor.x;
    const cursor_row: usize = cursor.y;
    const should_render_cursor = !view.is_viewing_scrollback and is_focused and !session.dead and cursor_visible;
    const pages = screen.pages;

    const base_cell_width = font.cell_width;
    const base_cell_height = font.cell_height;

    const cell_width_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_width)) * scale)));
    const cell_height_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_height)) * scale)));

    const padding: c_int = terminal_padding;
    const drawable_w: c_int = rect.w - padding * 2;
    const drawable_h: c_int = rect.h - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return;

    const origin_x: c_int = rect.x + padding;
    const origin_y: c_int = rect.y + padding;

    const max_cols_fit: usize = @intCast(@max(0, @divFloor(drawable_w, cell_width_actual)));
    const max_rows_fit: usize = @intCast(@max(0, @divFloor(drawable_h, cell_height_actual)));
    const visible_cols: usize = @min(@as(usize, term_cols), max_cols_fit);
    const visible_rows: usize = @min(@as(usize, term_rows), max_rows_fit);

    const default_fg = c.SDL_Color{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b, .a = 255 };
    const active_selection = screen.selection;

    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
        const eff_cw = cell_width_actual;
        const eff_ch = cell_height_actual;

        // Buffer for a single shaped render run.
        // 512 codepoints comfortably exceeds typical terminal line widths,
        // avoids excessive splitting in normal use, and bounds per-run work.
        var run_buf: [512]u21 = undefined;
        var run_len: usize = 0;
        var run_cells: c_int = 0;
        var run_x: c_int = 0;
        var run_fg: c.SDL_Color = undefined;
        var run_fallback: font_mod.Fallback = .primary;
        var run_width_cells: c_int = 0;
        var run_variant: FontVariant = .regular;

        var col: usize = 0;
        while (col < visible_cols) : (col += 1) {
            const list_cell = pages.getCell(if (view.is_viewing_scrollback)
                .{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }
            else
                .{ .active = .{ .x = @intCast(col), .y = @intCast(row) } }) orelse continue;

            const cell = list_cell.cell;
            const cp: u21 = if (cell.content_tag == .codepoint) cell.content.codepoint else 0;
            const glyph_width_cells: c_int = switch (cell.wide) {
                .wide => 2,
                else => 1,
            };

            const x: c_int = origin_x + @as(c_int, @intCast(col)) * eff_cw;
            const y: c_int = origin_y + @as(c_int, @intCast(row)) * cell_height_actual;

            if (x + eff_cw <= rect.x or x >= rect.x + rect.w) continue;
            if (y + eff_ch <= rect.y or y >= rect.y + rect.h) continue;

            const on_cursor = should_render_cursor and cursor_col == col and cursor_row == row;

            const style = list_cell.style();
            var fg_color = getCellColor(style.fg_color, default_fg, theme);
            var bg_color = if (style.bg(list_cell.cell, &terminal.colors.palette.current)) |rgb|
                c.SDL_Color{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = 255 }
            else
                session_bg_color;
            const variant = chooseVariant(style);

            if (style.flags.inverse) {
                const tmp = fg_color;
                fg_color = bg_color;
                bg_color = tmp;
            }

            if (style.flags.faint) {
                fg_color = applyFaint(fg_color);
            }

            if (on_cursor) {
                bg_color = cursor_color;
                fg_color = chooseCursorFg(theme);
            }

            if (!colors.colorsEqual(bg_color, session_bg_color)) {
                _ = c.SDL_SetRenderDrawColor(renderer, bg_color.r, bg_color.g, bg_color.b, 255);
                const cell_rect = c.SDL_FRect{
                    .x = @floatFromInt(x),
                    .y = @floatFromInt(y),
                    .w = @floatFromInt(eff_cw),
                    .h = @floatFromInt(eff_ch),
                };
                _ = c.SDL_RenderFillRect(renderer, &cell_rect);
            }

            if (active_selection) |sel| {
                const point_tag = if (view.is_viewing_scrollback)
                    ghostty_vt.point.Point{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }
                else
                    ghostty_vt.point.Point{ .active = .{ .x = @intCast(col), .y = @intCast(row) } };
                if (pages.pin(point_tag)) |pin| {
                    if (sel.contains(screen, pin)) {
                        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                        _ = c.SDL_SetRenderDrawColor(renderer, 27, 34, 48, 255);
                        const sel_rect = c.SDL_FRect{
                            .x = @floatFromInt(x),
                            .y = @floatFromInt(y),
                            .w = @floatFromInt(eff_cw * glyph_width_cells),
                            .h = @floatFromInt(eff_ch),
                        };
                        _ = c.SDL_RenderFillRect(renderer, &sel_rect);
                    }
                }
            }

            if (view.hovered_link_start) |link_start| {
                if (view.hovered_link_end) |link_end| {
                    const point_for_link = if (view.is_viewing_scrollback)
                        ghostty_vt.point.Point{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }
                    else
                        ghostty_vt.point.Point{ .active = .{ .x = @intCast(col), .y = @intCast(row) } };
                    if (pages.pin(point_for_link)) |link_pin| {
                        const link_sel = ghostty_vt.Selection.init(link_start, link_end, false);
                        if (link_sel.contains(screen, link_pin)) {
                            _ = c.SDL_SetRenderDrawColor(renderer, fg_color.r, fg_color.g, fg_color.b, 255);
                            const underline_y: f32 = @floatFromInt(y + eff_ch - 1);
                            const x_start: f32 = @floatFromInt(x);
                            const x_end: f32 = @floatFromInt(x + eff_cw * glyph_width_cells - 1);
                            _ = c.SDL_RenderLine(renderer, x_start, underline_y, x_end, underline_y);
                        }
                    }
                }
            }

            const is_box_drawing = cp != 0 and cp != ' ' and !style.flags.invisible and renderBoxDrawing(renderer, cp, x, y, eff_cw, eff_ch, fg_color);
            if (is_box_drawing) {
                try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, eff_cw, eff_ch, run_fg, run_variant);
                run_len = 0;
                run_cells = 0;
                run_width_cells = 0;
                continue;
            }

            const is_fill_glyph = cp != 0 and cp != ' ' and !style.flags.invisible and isFullCellGlyph(cp);

            if (is_fill_glyph) {
                try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, eff_cw, eff_ch, run_fg, run_variant);
                run_len = 0;
                run_cells = 0;
                run_width_cells = 0;

                const draw_width = eff_cw * glyph_width_cells;
                try font.renderGlyphFill(cp, x, y, draw_width, eff_ch, fg_color, variant);
                continue;
            }

            if (cp != 0 and cp != ' ' and !style.flags.invisible) {
                var cluster_buf: [16]u21 = undefined;
                var cluster_len: usize = 0;
                cluster_buf[cluster_len] = cp;
                cluster_len += 1;

                if (cell.hasGrapheme()) {
                    if (list_cell.node.data.lookupGrapheme(list_cell.cell)) |extra| {
                        for (extra) |gcp| {
                            if (cluster_len >= cluster_buf.len) break;
                            cluster_buf[cluster_len] = gcp;
                            cluster_len += 1;
                        }
                    }
                }

                const fallback_choice = font.classifyFallback(cluster_buf[0..cluster_len]);

                if (run_len == 0) {
                    run_x = x;
                    run_fg = fg_color;
                    run_fallback = fallback_choice;
                    run_width_cells = glyph_width_cells;
                    run_variant = variant;
                }

                if (shouldFlushRun(
                    run_len,
                    run_buf.len,
                    cluster_len,
                    run_fg,
                    fg_color,
                    run_fallback,
                    fallback_choice,
                    run_width_cells,
                    glyph_width_cells,
                    run_cells,
                    eff_cw,
                    run_variant,
                    variant,
                )) {
                    try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, eff_cw, eff_ch, run_fg, run_variant);
                    run_x = x;
                    run_fg = fg_color;
                    run_fallback = fallback_choice;
                    run_len = 0;
                    run_cells = 0;
                    run_width_cells = glyph_width_cells;
                    run_variant = variant;
                }

                if (cluster_len > run_buf.len) {
                    const draw_width = eff_cw * glyph_width_cells;
                    try font.renderCluster(cluster_buf[0..cluster_len], x, y, draw_width, eff_ch, fg_color, variant);
                    run_len = 0;
                    run_cells = 0;
                    run_width_cells = 0;
                    continue;
                }

                @memcpy(run_buf[run_len .. run_len + cluster_len], cluster_buf[0..cluster_len]);
                run_len += cluster_len;
                run_cells += glyph_width_cells;
            } else {
                try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, eff_cw, eff_ch, run_fg, run_variant);
                run_len = 0;
                run_cells = 0;
                run_width_cells = 0;
            }
        }

        try flushRun(font, run_buf[0..], run_len, run_x, origin_y + @as(c_int, @intCast(row)) * cell_height_actual, run_cells, eff_cw, eff_ch, run_fg, run_variant);
    }

    if (session.dead) {
        const message = "[Process completed]";
        const message_row: usize = @intCast(cursor.y);

        if (message_row < visible_rows) {
            const message_x: c_int = origin_x;
            const message_y: c_int = origin_y + @as(c_int, @intCast(message_row)) * cell_height_actual;
            const fg_color = c.SDL_Color{ .r = 92, .g = 99, .b = 112, .a = 255 };

            var offset_x = message_x;
            for (message) |ch| {
                try font.renderGlyph(ch, offset_x, message_y, cell_width_actual, cell_height_actual, fg_color);
                offset_x += cell_width_actual;
            }
        }
    }
}

fn renderSessionOverlays(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    view: *SessionViewState,
    rect: Rect,
    is_focused: bool,
    apply_effects: bool,
    current_time_ms: i64,
    is_grid_view: bool,
    theme: *const colors.Theme,
    ui_scale: f32,
) void {
    const has_attention = is_grid_view and view.attention;
    const border_thickness: c_int = attention_thickness;

    if (apply_effects) {
        applyTvOverlay(renderer, rect, is_focused, theme);
    }

    if (is_grid_view) {
        if (!is_focused) {
            const base_border = theme.selection;
            primitives.drawThickBorder(renderer, rect, border_thickness, base_border);
        }

        if (is_focused) {
            const focus_blue = theme.palette[12];
            const inset: c_int = if (has_attention) border_thickness else 0;
            var focus_rect = rect;
            focus_rect.x += inset;
            focus_rect.y += inset;
            focus_rect.w -= inset * 2;
            focus_rect.h -= inset * 2;
            if (focus_rect.w > 0 and focus_rect.h > 0) {
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                if (!has_attention) {
                    _ = c.SDL_SetRenderDrawColor(renderer, focus_blue.r, focus_blue.g, focus_blue.b, 38);
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(focus_rect.x),
                        .y = @floatFromInt(focus_rect.y),
                        .w = @floatFromInt(focus_rect.w),
                        .h = @floatFromInt(focus_rect.h),
                    });
                }
                primitives.drawThickBorder(renderer, focus_rect, border_thickness, focus_blue);
            }
        }
    }

    if (has_attention) {
        const yellow = theme.palette[3];
        const base_green = theme.palette[2];
        const done_green = c.SDL_Color{
            .r = @intCast(std.math.clamp(@as(i32, base_green.r) - 30, 0, 255)),
            .g = @intCast(std.math.clamp(@as(i32, base_green.g) + 30, 0, 255)),
            .b = @intCast(std.math.clamp(@as(i32, base_green.b) - 20, 0, 255)),
            .a = 255,
        };
        const color = switch (view.status) {
            .awaiting_approval => blk: {
                const phase_ms: f32 = @floatFromInt(@mod(current_time_ms, @as(i64, 1000)));
                const pulse = 0.5 + 0.5 * std.math.sin(phase_ms / 1000.0 * 2.0 * std.math.pi);
                const base_alpha: u8 = @intFromFloat(170 + 70 * pulse);
                break :blk c.SDL_Color{ .r = yellow.r, .g = yellow.g, .b = yellow.b, .a = base_alpha };
            },
            .done => blk: {
                break :blk c.SDL_Color{ .r = done_green.r, .g = done_green.g, .b = done_green.b, .a = 230 };
            },
            else => c.SDL_Color{ .r = yellow.r, .g = yellow.g, .b = yellow.b, .a = 230 },
        };
        primitives.drawThickBorder(renderer, rect, attention_thickness, color);

        const tint_color = switch (view.status) {
            .awaiting_approval => c.SDL_Color{ .r = yellow.r, .g = yellow.g, .b = yellow.b, .a = 55 },
            .done => blk: {
                break :blk c.SDL_Color{ .r = done_green.r, .g = done_green.g, .b = done_green.b, .a = 55 };
            },
            else => c.SDL_Color{ .r = yellow.r, .g = yellow.g, .b = yellow.b, .a = 55 },
        };
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, tint_color.r, tint_color.g, tint_color.b, tint_color.a);
        const tint_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderFillRect(renderer, &tint_rect);
    }

    renderTerminalScrollbar(renderer, session, view, rect, theme, ui_scale);
}

fn renderTerminalScrollbar(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    view: *SessionViewState,
    rect: Rect,
    theme: *const colors.Theme,
    ui_scale: f32,
) void {
    if (!session.spawned) {
        view.terminal_scrollbar.hideNow();
        return;
    }
    const terminal = session.terminal orelse {
        view.terminal_scrollbar.hideNow();
        return;
    };
    const content_rect = terminalContentRect(rect) orelse {
        view.terminal_scrollbar.hideNow();
        return;
    };
    const bar = terminal.screens.active.pages.scrollbar();
    const metrics = scrollbar.Metrics.init(
        @as(f32, @floatFromInt(bar.total)),
        @as(f32, @floatFromInt(bar.offset)),
        @as(f32, @floatFromInt(bar.len)),
    );
    const layout = scrollbar.computeLayout(content_rect, ui_scale, metrics) orelse {
        view.terminal_scrollbar.hideNow();
        return;
    };
    scrollbar.render(renderer, layout, theme.accent, &view.terminal_scrollbar);
    view.terminal_scrollbar.markDrawn();
}

fn terminalContentRect(rect: Rect) ?Rect {
    const padded_w = rect.w - terminal_padding * 2;
    const padded_h = rect.h - terminal_padding * 2;
    if (padded_w <= 0 or padded_h <= 0) return null;
    return .{
        .x = rect.x + terminal_padding,
        .y = rect.y + terminal_padding,
        .w = padded_w,
        .h = padded_h,
    };
}

fn ensureCacheTexture(renderer: *c.SDL_Renderer, cache_entry: *RenderCache.Entry, session: *SessionState, width: c_int, height: c_int) bool {
    if (cache_entry.texture) |tex| {
        if (cache_entry.width == width and cache_entry.height == height) {
            return true;
        }
        log.debug("destroying cache for session {d} (resize)", .{session.id});
        c.SDL_DestroyTexture(tex);
        cache_entry.texture = null;
        cache_entry.width = 0;
        cache_entry.height = 0;
        cache_entry.cache_epoch = 0;
    }

    log.debug("creating cache for session {d} spawned={}", .{ session.id, session.spawned });
    const tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, width, height) orelse {
        std.debug.print("Failed to create cache texture {d}x{d} for session {d}: {s}\n", .{ width, height, session.id, c.SDL_GetError() });
        return false;
    };
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    cache_entry.texture = tex;
    cache_entry.width = width;
    cache_entry.height = height;
    cache_entry.cache_epoch = 0;
    return true;
}

fn renderGridSessionCached(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    view: *SessionViewState,
    cache_entry: *RenderCache.Entry,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    apply_effects: bool,
    render_overlays: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    current_time_ms: i64,
    theme: *const colors.Theme,
    ui_scale: f32,
) RenderError!void {
    if (!session.spawned) {
        cache_entry.presented_epoch = session.render_epoch;
        return;
    }
    const can_cache = ensureCacheTexture(renderer, cache_entry, session, rect.w, rect.h);

    const wave_active = view.wave_start_time > 0 and current_time_ms >= view.wave_start_time;
    const wave_elapsed_ms: f32 = if (wave_active) @as(f32, @floatFromInt(current_time_ms - view.wave_start_time)) else 0;
    const wave_total: f32 = @floatFromInt(session_interaction.wave_total_ms);
    const is_waving = wave_active and wave_elapsed_ms < wave_total;

    if (can_cache) {
        if (cache_entry.texture) |tex| {
            if (cache_entry.cache_epoch != session.render_epoch) {
                log.debug("rendering to cache: session={d} spawned={} focused={}", .{ session.id, session.spawned, is_focused });
                _ = c.SDL_SetRenderTarget(renderer, tex);
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
                _ = c.SDL_SetRenderDrawColor(renderer, theme.background.r, theme.background.g, theme.background.b, 255);
                _ = c.SDL_RenderClear(renderer);
                const local_rect = Rect{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
                try renderSessionContent(renderer, session, view, local_rect, scale, is_focused, font, term_cols, term_rows, current_time_ms, theme);
                if (is_waving and render_overlays) {
                    renderSessionOverlays(renderer, session, view, local_rect, is_focused, apply_effects, current_time_ms, true, theme, ui_scale);
                }
                cache_entry.cache_epoch = session.render_epoch;
                _ = c.SDL_SetRenderTarget(renderer, null);
            }

            if (is_waving) {
                renderWaveStrips(renderer, tex, rect, wave_elapsed_ms);
            } else {
                const dest_rect = c.SDL_FRect{
                    .x = @floatFromInt(rect.x),
                    .y = @floatFromInt(rect.y),
                    .w = @floatFromInt(rect.w),
                    .h = @floatFromInt(rect.h),
                };
                _ = c.SDL_RenderTexture(renderer, tex, null, &dest_rect);
                if (render_overlays) {
                    renderSessionOverlays(renderer, session, view, rect, is_focused, apply_effects, current_time_ms, true, theme, ui_scale);
                }
            }
            cache_entry.presented_epoch = session.render_epoch;
            return;
        }
    }

    if (render_overlays) {
        try renderSession(renderer, session, view, cache_entry, rect, scale, is_focused, apply_effects, font, term_cols, term_rows, current_time_ms, true, theme, ui_scale);
        return;
    }

    try renderSessionContent(renderer, session, view, rect, scale, is_focused, font, term_cols, term_rows, current_time_ms, theme);
    cache_entry.presented_epoch = session.render_epoch;
}

/// Render the cached tile texture in horizontal strips with per-strip wave scaling.
/// The wave sweeps from bottom to top: bottom strips animate first, top strips last.
/// Only the width of each strip is scaled (centered horizontally), preserving vertical layout.
fn renderWaveStrips(
    renderer: *c.SDL_Renderer,
    tex: *c.SDL_Texture,
    rect: Rect,
    wave_elapsed_ms: f32,
) void {
    const total: f32 = @floatFromInt(session_interaction.wave_total_ms);
    const row_anim: f32 = @floatFromInt(session_interaction.wave_row_anim_ms);
    const amplitude: f32 = session_interaction.wave_amplitude;
    const strip_h: c_int = @intCast(session_interaction.wave_strip_height);
    const tile_h = rect.h;
    const tile_w = rect.w;
    if (tile_h <= 0 or tile_w <= 0) return;

    const num_strips: c_int = @divTrunc(tile_h + strip_h - 1, strip_h);
    const stagger: f32 = total - row_anim;
    const num_strips_f: f32 = @floatFromInt(@max(1, num_strips - 1));
    const tile_w_f: f32 = @floatFromInt(tile_w);

    var i: c_int = 0;
    while (i < num_strips) : (i += 1) {
        const src_y = i * strip_h;
        const src_h = @min(strip_h, tile_h - src_y);
        if (src_h <= 0) break;

        // Bottom strips (high i) animate first → strip_frac=0 for bottom, 1 for top
        const strip_frac: f32 = @as(f32, @floatFromInt(num_strips - 1 - i)) / num_strips_f;
        const delay: f32 = strip_frac * stagger;
        const strip_t: f32 = wave_elapsed_ms - delay;

        // Envelope: taper amplitude to zero at top and bottom edges so corners stay fixed
        const pos_frac: f32 = @as(f32, @floatFromInt(i)) / num_strips_f;
        const envelope: f32 = @sin(pos_frac * std.math.pi);

        var scale: f32 = 1.0;
        if (strip_t > 0 and strip_t < row_anim) {
            const t: f32 = strip_t / row_anim;
            scale = 1.0 + amplitude * envelope * @sin(t * std.math.pi);
        }

        const scaled_w: f32 = tile_w_f * scale;
        const x_offset: f32 = (tile_w_f - scaled_w) * 0.5;

        const src_rect = c.SDL_FRect{
            .x = 0,
            .y = @floatFromInt(src_y),
            .w = @floatFromInt(tile_w),
            .h = @floatFromInt(src_h),
        };
        const dst_rect = c.SDL_FRect{
            .x = @as(f32, @floatFromInt(rect.x)) + x_offset,
            .y = @floatFromInt(rect.y + src_y),
            .w = scaled_w,
            .h = @floatFromInt(src_h),
        };
        _ = c.SDL_RenderTexture(renderer, tex, &src_rect, &dst_rect);
    }
}

fn applyTvOverlay(renderer: *c.SDL_Renderer, rect: Rect, is_focused: bool, theme: *const colors.Theme) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const bg = theme.background;
    _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 60);
    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    });

    const radius: c_int = 12;

    const border_color = if (is_focused) blk: {
        const acc = theme.accent;
        break :blk c.SDL_Color{ .r = acc.r, .g = acc.g, .b = acc.b, .a = 190 };
    } else blk: {
        const sel = theme.selection;
        break :blk c.SDL_Color{ .r = sel.r, .g = sel.g, .b = sel.b, .a = 170 };
    };

    _ = c.SDL_SetRenderDrawColor(renderer, border_color.r, border_color.g, border_color.b, border_color.a);
    primitives.drawRoundedBorder(renderer, rect, radius);
}

fn getCellColor(color: ghostty_vt.Style.Color, default: c.SDL_Color, theme: *const colors.Theme) c.SDL_Color {
    return switch (color) {
        .none => default,
        .palette => |idx| colors.get256ColorWithTheme(idx, theme),
        .rgb => |rgb| c.SDL_Color{
            .r = rgb.r,
            .g = rgb.g,
            .b = rgb.b,
            .a = 255,
        },
    };
}

fn flushRun(
    font: *font_mod.Font,
    buffer: []const u21,
    len: usize,
    x: c_int,
    y: c_int,
    cells: c_int,
    cell_width_actual: c_int,
    cell_height_actual: c_int,
    fg: c.SDL_Color,
    variant: FontVariant,
) RenderError!void {
    if (len == 0 or cells == 0) return;
    const draw_width = cell_width_actual * cells;
    try font.renderCluster(buffer[0..len], x, y, draw_width, cell_height_actual, fg, variant);
}

fn shouldFlushRun(
    run_len: usize,
    run_buf_cap: usize,
    cluster_len: usize,
    run_fg: c.SDL_Color,
    new_fg: c.SDL_Color,
    run_fallback: font_mod.Fallback,
    new_fallback: font_mod.Fallback,
    run_width_cells: c_int,
    new_width_cells: c_int,
    run_cells: c_int,
    cell_width_actual: c_int,
    run_variant: FontVariant,
    new_variant: FontVariant,
) bool {
    if (run_len == 0) return false;

    const color_changed = !colors.colorsEqual(run_fg, new_fg);
    const fallback_changed = run_fallback != new_fallback;
    const width_changed = run_width_cells != new_width_cells;
    const variant_changed = run_variant != new_variant;
    const would_overflow = run_len + cluster_len > run_buf_cap;
    const max_pixels: c_int = 16000;
    const would_be_too_wide = (run_cells + new_width_cells) * cell_width_actual > max_pixels;

    return color_changed or fallback_changed or width_changed or variant_changed or would_overflow or would_be_too_wide;
}

fn chooseVariant(style: ghostty_vt.Style) FontVariant {
    const flags = style.flags;
    if (flags.bold and flags.italic) return .bold_italic;
    if (flags.bold) return .bold;
    if (flags.italic) return .italic;
    return .regular;
}

fn applyFaint(color: c.SDL_Color) c.SDL_Color {
    const factor = faint_factor;
    const r: u32 = @intFromFloat(@as(f32, @floatFromInt(color.r)) * factor);
    const g: u32 = @intFromFloat(@as(f32, @floatFromInt(color.g)) * factor);
    const b: u32 = @intFromFloat(@as(f32, @floatFromInt(color.b)) * factor);
    return c.SDL_Color{
        .r = @intCast(r),
        .g = @intCast(g),
        .b = @intCast(b),
        .a = color.a,
    };
}

fn colorLuma(color: c.SDL_Color) u16 {
    // Simple Rec. 601 luma approximation
    return @intCast((@as(u32, color.r) * 299 + @as(u32, color.g) * 587 + @as(u32, color.b) * 114) / 1000);
}

fn chooseCursorFg(theme: *const colors.Theme) c.SDL_Color {
    const cursor_luma = colorLuma(cursor_color);
    if (cursor_luma > 140) {
        const bg_luma = colorLuma(theme.background);
        if (bg_luma < 180) return theme.background;
        return dark_fallback;
    }
    return theme.foreground;
}

fn renderBoxDrawing(renderer: *c.SDL_Renderer, cp: u21, x: c_int, y: c_int, w: c_int, h: c_int, color: c.SDL_Color) bool {
    return box_drawing.render(renderer, cp, x, y, w, h, color);
}

fn isBoxDrawingChar(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x257F;
}

fn isFullCellGlyph(cp: u21) bool {
    return ((cp >= 0x2500 and cp <= 0x259F) and !isBoxDrawingChar(cp)) or (cp >= 0xE0B0 and cp <= 0xE0C8) or (cp == 0x2588);
}
