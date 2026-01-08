const std = @import("std");
const c = @import("../c.zig");
const ghostty_vt = @import("ghostty-vt");
const app_state = @import("../app/app_state.zig");
const geom = @import("../geom.zig");
const easing = @import("../anim/easing.zig");
const font_mod = @import("../font.zig");
const FontVariant = font_mod.Variant;
const session_state = @import("../session/state.zig");
const primitives = @import("../gfx/primitives.zig");
const dpi = @import("../ui/scale.zig");

const log = std.log.scoped(.render);

const SessionState = session_state.SessionState;
const Rect = geom.Rect;
const AnimationState = app_state.AnimationState;

const ATTENTION_THICKNESS: c_int = 3;
pub const TERMINAL_PADDING: c_int = 8;
const CWD_BAR_HEIGHT: c_int = 24;
const CWD_FONT_SIZE: c_int = 12;
const CWD_PADDING: c_int = 8;
const MARQUEE_SPEED: f32 = 30.0;
const FADE_WIDTH: c_int = 20;
const FAINT_FACTOR: f32 = 0.6;

pub const RenderError = font_mod.Font.RenderGlyphError;

pub fn render(
    renderer: *c.SDL_Renderer,
    sessions: []SessionState,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    grid_cols: usize,
    anim_state: *const AnimationState,
    current_time: i64,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    window_width: c_int,
    window_height: c_int,
    ui_scale: f32,
    font_path: [:0]const u8,
) RenderError!void {
    _ = c.SDL_SetRenderDrawColor(renderer, 14, 17, 22, 255);
    _ = c.SDL_RenderClear(renderer);

    const grid_scale: f32 = 1.0 / @as(f32, @floatFromInt(grid_cols));

    switch (anim_state.mode) {
        .Grid => {
            for (sessions, 0..) |*session, i| {
                const grid_row: c_int = @intCast(i / grid_cols);
                const grid_col: c_int = @intCast(i % grid_cols);

                const cell_rect = Rect{
                    .x = grid_col * cell_width_pixels,
                    .y = grid_row * cell_height_pixels,
                    .w = cell_width_pixels,
                    .h = cell_height_pixels,
                };

                try renderGridSessionCached(renderer, session, cell_rect, grid_scale, i == anim_state.focused_session, true, font, term_cols, term_rows, current_time, ui_scale, font_path);
            }
        },
        .Full => {
            const full_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.focused_session], full_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false, ui_scale, font_path);
        },
        .PanningLeft, .PanningRight => {
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, app_state.ANIMATION_DURATION_MS));
            const eased = easing.easeInOutCubic(progress);

            const offset = @as(c_int, @intFromFloat(@as(f32, @floatFromInt(window_width)) * eased));
            const pan_offset = if (anim_state.mode == .PanningLeft) -offset else offset;

            const prev_rect = Rect{ .x = pan_offset, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.previous_session], prev_rect, 1.0, false, false, font, term_cols, term_rows, current_time, false, ui_scale, font_path);

            const new_offset = if (anim_state.mode == .PanningLeft)
                window_width - offset
            else
                -window_width + offset;
            const new_rect = Rect{ .x = new_offset, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.focused_session], new_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false, ui_scale, font_path);
        },
        .Expanding, .Collapsing => {
            const animating_rect = anim_state.getCurrentRect(current_time);
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, app_state.ANIMATION_DURATION_MS));
            const eased = easing.easeInOutCubic(progress);
            const anim_scale = if (anim_state.mode == .Expanding)
                grid_scale + (1.0 - grid_scale) * eased
            else
                1.0 - (1.0 - grid_scale) * eased;

            for (sessions, 0..) |*session, i| {
                if (i != anim_state.focused_session) {
                    const grid_row: c_int = @intCast(i / grid_cols);
                    const grid_col: c_int = @intCast(i % grid_cols);

                    const cell_rect = Rect{
                        .x = grid_col * cell_width_pixels,
                        .y = grid_row * cell_height_pixels,
                        .w = cell_width_pixels,
                        .h = cell_height_pixels,
                    };

                    try renderGridSessionCached(renderer, session, cell_rect, grid_scale, false, true, font, term_cols, term_rows, current_time, ui_scale, font_path);
                }
            }

            const apply_effects = anim_scale < 0.999;
            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, apply_effects, font, term_cols, term_rows, current_time, false, ui_scale, font_path);
        },
    }
}

fn renderSession(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    apply_effects: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    current_time_ms: i64,
    is_grid_view: bool,
    ui_scale: f32,
    font_path: [:0]const u8,
) RenderError!void {
    try renderSessionContent(renderer, session, rect, scale, is_focused, font, term_cols, term_rows);
    if (is_grid_view) {
        renderCwdBar(renderer, session, rect, current_time_ms, ui_scale, font_path);
    }
    renderSessionOverlays(renderer, session, rect, is_focused, apply_effects, current_time_ms, is_grid_view);
}

fn renderSessionContent(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
) RenderError!void {
    const base_bg = c.SDL_Color{ .r = 14, .g = 17, .b = 22, .a = 255 };
    const session_bg_color = base_bg;

    _ = c.SDL_SetRenderDrawColor(renderer, session_bg_color.r, session_bg_color.g, session_bg_color.b, session_bg_color.a);
    const bg_rect = c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = c.SDL_RenderFillRect(renderer, &bg_rect);

    if (!session.spawned) return;

    const terminal = session.terminal orelse {
        log.err("session {d} is spawned but terminal is null!", .{session.id});
        return;
    };
    const screen = terminal.screens.active;
    const cursor_visible = terminal.modes.get(.cursor_visible);
    const pages = screen.pages;

    const base_cell_width = font.cell_width;
    const base_cell_height = font.cell_height;

    const cell_width_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_width)) * scale)));
    const cell_height_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_height)) * scale)));

    const padding: c_int = TERMINAL_PADDING;
    const drawable_w: c_int = rect.w - padding * 2;
    const drawable_h: c_int = rect.h - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return;

    const origin_x: c_int = rect.x + padding;
    const origin_y: c_int = rect.y + padding;

    const max_cols_fit: usize = @intCast(@max(0, @divFloor(drawable_w, cell_width_actual)));
    const max_rows_fit: usize = @intCast(@max(0, @divFloor(drawable_h, cell_height_actual)));
    const visible_cols: usize = @min(@as(usize, term_cols), max_cols_fit);
    const visible_rows: usize = @min(@as(usize, term_rows), max_rows_fit);

    const default_fg = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };
    const active_selection = screen.selection;

    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
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
            const list_cell = pages.getCell(if (session.is_scrolled)
                .{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }
            else
                .{ .active = .{ .x = @intCast(col), .y = @intCast(row) } }) orelse continue;

            const cell = list_cell.cell;
            const cp = cell.content.codepoint;
            const glyph_width_cells: c_int = switch (cell.wide) {
                .wide => 2,
                else => 1,
            };

            const x: c_int = origin_x + @as(c_int, @intCast(col)) * cell_width_actual;
            const y: c_int = origin_y + @as(c_int, @intCast(row)) * cell_height_actual;

            if (x + cell_width_actual <= rect.x or x >= rect.x + rect.w) continue;
            if (y + cell_height_actual <= rect.y or y >= rect.y + rect.h) continue;

            const style = list_cell.style();
            var fg_color = getCellColor(style.fg_color, default_fg);
            var bg_color = getCellColor(style.bg_color, session_bg_color);
            const variant = chooseVariant(style);

            if (style.flags.inverse) {
                const tmp = fg_color;
                fg_color = bg_color;
                bg_color = tmp;
            }

            if (style.flags.faint) {
                fg_color = applyFaint(fg_color);
            }

            if (!colorsEqual(bg_color, session_bg_color)) {
                _ = c.SDL_SetRenderDrawColor(renderer, bg_color.r, bg_color.g, bg_color.b, 255);
                const cell_rect = c.SDL_FRect{
                    .x = @floatFromInt(x),
                    .y = @floatFromInt(y),
                    .w = @floatFromInt(cell_width_actual),
                    .h = @floatFromInt(cell_height_actual),
                };
                _ = c.SDL_RenderFillRect(renderer, &cell_rect);
            }

            if (active_selection) |sel| {
                const point_tag = if (session.is_scrolled)
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
                            .w = @floatFromInt(cell_width_actual * glyph_width_cells),
                            .h = @floatFromInt(cell_height_actual),
                        };
                        _ = c.SDL_RenderFillRect(renderer, &sel_rect);
                    }
                }
            }

            if (session.hovered_link_start) |link_start| {
                if (session.hovered_link_end) |link_end| {
                    const point_tag = if (session.is_scrolled)
                        ghostty_vt.point.Point{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }
                    else
                        ghostty_vt.point.Point{ .active = .{ .x = @intCast(col), .y = @intCast(row) } };
                    if (pages.pin(point_tag)) |pin| {
                        const link_sel = ghostty_vt.Selection.init(link_start, link_end, false);
                        if (link_sel.contains(screen, pin)) {
                            _ = c.SDL_SetRenderDrawColor(renderer, fg_color.r, fg_color.g, fg_color.b, 255);
                            const underline_y: f32 = @floatFromInt(y + cell_height_actual - 1);
                            const x_start: f32 = @floatFromInt(x);
                            const x_end: f32 = @floatFromInt(x + cell_width_actual * glyph_width_cells - 1);
                            _ = c.SDL_RenderLine(renderer, x_start, underline_y, x_end, underline_y);
                        }
                    }
                }
            }

            const is_box_drawing = cp != 0 and cp != ' ' and !style.flags.invisible and renderBoxDrawing(renderer, cp, x, y, cell_width_actual, cell_height_actual, fg_color);
            if (is_box_drawing) {
                try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, cell_width_actual, cell_height_actual, run_fg, run_variant);
                run_len = 0;
                run_cells = 0;
                run_width_cells = 0;
                run_variant = .regular;
                continue;
            }

            const is_fill_glyph = cp != 0 and cp != ' ' and !style.flags.invisible and isFullCellGlyph(cp);

            if (is_fill_glyph) {
                try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, cell_width_actual, cell_height_actual, run_fg, run_variant);
                run_len = 0;
                run_cells = 0;
                run_width_cells = 0;
                run_variant = .regular;

                const draw_width = cell_width_actual * glyph_width_cells;
                try font.renderGlyphFill(cp, x, y, draw_width, cell_height_actual, fg_color, variant);
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
                    cell_width_actual,
                    run_variant,
                    variant,
                )) {
                    try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, cell_width_actual, cell_height_actual, run_fg, run_variant);
                    run_x = x;
                    run_fg = fg_color;
                    run_fallback = fallback_choice;
                    run_len = 0;
                    run_cells = 0;
                    run_width_cells = glyph_width_cells;
                    run_variant = variant;
                }

                if (cluster_len > run_buf.len) {
                    const draw_width = cell_width_actual * glyph_width_cells;
                    try font.renderCluster(cluster_buf[0..cluster_len], x, y, draw_width, cell_height_actual, fg_color, variant);
                    run_len = 0;
                    run_cells = 0;
                    run_width_cells = 0;
                    continue;
                }

                @memcpy(run_buf[run_len .. run_len + cluster_len], cluster_buf[0..cluster_len]);
                run_len += cluster_len;
                run_cells += glyph_width_cells;
            } else {
                try flushRun(font, run_buf[0..], run_len, run_x, y, run_cells, cell_width_actual, cell_height_actual, run_fg, run_variant);
                run_len = 0;
                run_cells = 0;
                run_width_cells = 0;
                run_variant = .regular;
            }
        }

        try flushRun(font, run_buf[0..], run_len, run_x, origin_y + @as(c_int, @intCast(row)) * cell_height_actual, run_cells, cell_width_actual, cell_height_actual, run_fg, run_variant);
    }

    if (!session.is_scrolled and is_focused and !session.dead and cursor_visible) {
        const cursor = screen.cursor;
        const cursor_col = cursor.x;
        const cursor_row = cursor.y;

        if (cursor_col < visible_cols and cursor_row < visible_rows) {
            const cursor_x: c_int = origin_x + @as(c_int, @intCast(cursor_col)) * cell_width_actual;
            const cursor_y: c_int = origin_y + @as(c_int, @intCast(cursor_row)) * cell_height_actual;

            if (cursor_x + cell_width_actual > rect.x and cursor_x < rect.x + rect.w and
                cursor_y + cell_height_actual > rect.y and cursor_y < rect.y + rect.h)
            {
                _ = c.SDL_SetRenderDrawColor(renderer, 215, 186, 125, 255);
                const cursor_rect = c.SDL_FRect{
                    .x = @floatFromInt(cursor_x),
                    .y = @floatFromInt(cursor_y),
                    .w = @floatFromInt(cell_width_actual),
                    .h = @floatFromInt(cell_height_actual),
                };
                _ = c.SDL_RenderFillRect(renderer, &cursor_rect);
            }
        }
    }

    if (session.dead) {
        const message = "[Process completed]";
        const cursor = screen.cursor;
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
    rect: Rect,
    is_focused: bool,
    apply_effects: bool,
    current_time_ms: i64,
    is_grid_view: bool,
) void {
    if (apply_effects) {
        applyTvOverlay(renderer, rect, is_focused);
    } else if (is_grid_view) {
        if (is_focused) {
            _ = c.SDL_SetRenderDrawColor(renderer, 97, 175, 239, 255);
        } else {
            _ = c.SDL_SetRenderDrawColor(renderer, 92, 99, 112, 255);
        }
        const border_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(rect.w),
            .h = @floatFromInt(rect.h),
        };
        _ = c.SDL_RenderRect(renderer, &border_rect);
    }

    if (is_grid_view and session.is_scrolled) {
        _ = c.SDL_SetRenderDrawColor(renderer, 215, 186, 125, 220);
        const indicator_rect = c.SDL_FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y + rect.h - 4),
            .w = @floatFromInt(rect.w),
            .h = 4.0,
        };
        _ = c.SDL_RenderFillRect(renderer, &indicator_rect);
    }

    if (is_grid_view and session.attention) {
        const color = switch (session.status) {
            .awaiting_approval => blk: {
                const phase_ms: f32 = @floatFromInt(@mod(current_time_ms, @as(i64, 1000)));
                const pulse = 0.5 + 0.5 * std.math.sin(phase_ms / 1000.0 * 2.0 * std.math.pi);
                const base_alpha: u8 = @intFromFloat(170 + 70 * pulse);
                break :blk c.SDL_Color{ .r = 215, .g = 186, .b = 125, .a = base_alpha };
            },
            .done => c.SDL_Color{ .r = 152, .g = 195, .b = 121, .a = 230 },
            else => c.SDL_Color{ .r = 215, .g = 186, .b = 125, .a = 230 },
        };
        primitives.drawThickBorder(renderer, rect, ATTENTION_THICKNESS, color);

        const tint_color = switch (session.status) {
            .awaiting_approval => c.SDL_Color{ .r = 215, .g = 186, .b = 125, .a = 25 },
            .done => c.SDL_Color{ .r = 152, .g = 195, .b = 121, .a = 30 },
            else => c.SDL_Color{ .r = 215, .g = 186, .b = 125, .a = 25 },
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
}

fn ensureCacheTexture(renderer: *c.SDL_Renderer, session: *SessionState, width: c_int, height: c_int) bool {
    if (session.cache_texture) |tex| {
        if (session.cache_w == width and session.cache_h == height) {
            return true;
        }
        log.debug("destroying cache for session {d} (resize)", .{session.id});
        c.SDL_DestroyTexture(tex);
        session.cache_texture = null;
    }

    log.debug("creating cache for session {d} spawned={}", .{ session.id, session.spawned });
    const tex = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, width, height) orelse {
        std.debug.print("Failed to create cache texture {d}x{d} for session {d}: {s}\n", .{ width, height, session.id, c.SDL_GetError() });
        return false;
    };
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    session.cache_texture = tex;
    session.cache_w = width;
    session.cache_h = height;
    session.dirty = true;
    return true;
}

fn renderGridSessionCached(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    apply_effects: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    current_time_ms: i64,
    ui_scale: f32,
    font_path: [:0]const u8,
) RenderError!void {
    const can_cache = ensureCacheTexture(renderer, session, rect.w, rect.h);

    if (can_cache) {
        if (session.cache_texture) |tex| {
            if (session.dirty) {
                log.debug("rendering to cache: session={d} spawned={} focused={}", .{ session.id, session.spawned, is_focused });
                _ = c.SDL_SetRenderTarget(renderer, tex);
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
                _ = c.SDL_SetRenderDrawColor(renderer, 14, 17, 22, 255);
                _ = c.SDL_RenderClear(renderer);
                const local_rect = Rect{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
                try renderSessionContent(renderer, session, local_rect, scale, is_focused, font, term_cols, term_rows);
                session.dirty = false;
                _ = c.SDL_SetRenderTarget(renderer, null);
            }

            const dest_rect = c.SDL_FRect{
                .x = @floatFromInt(rect.x),
                .y = @floatFromInt(rect.y),
                .w = @floatFromInt(rect.w),
                .h = @floatFromInt(rect.h),
            };
            _ = c.SDL_RenderTexture(renderer, tex, null, &dest_rect);
            renderCwdBar(renderer, session, rect, current_time_ms, ui_scale, font_path);
            renderSessionOverlays(renderer, session, rect, is_focused, apply_effects, current_time_ms, true);
            return;
        }
    }

    try renderSession(renderer, session, rect, scale, is_focused, apply_effects, font, term_cols, term_rows, current_time_ms, true, ui_scale, font_path);
}

fn applyTvOverlay(renderer: *c.SDL_Renderer, rect: Rect, is_focused: bool) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    _ = c.SDL_SetRenderDrawColor(renderer, 14, 17, 22, 60);
    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    });

    const radius: c_int = 12;

    const border_color = if (is_focused)
        c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 190 }
    else
        c.SDL_Color{ .r = 92, .g = 99, .b = 112, .a = 170 };

    _ = c.SDL_SetRenderDrawColor(renderer, border_color.r, border_color.g, border_color.b, border_color.a);
    primitives.drawRoundedBorder(renderer, rect, radius);
}

fn renderCwdBar(
    renderer: *c.SDL_Renderer,
    session: *SessionState,
    rect: Rect,
    current_time: i64,
    ui_scale: f32,
    font_path: [:0]const u8,
) void {
    const cwd_path = session.cwd_path orelse return;
    const cwd_basename = session.cwd_basename orelse return;

    const bar_height = dpi.scale(CWD_BAR_HEIGHT, ui_scale);
    const padding = dpi.scale(CWD_PADDING, ui_scale);
    const fade_width = dpi.scale(FADE_WIDTH, ui_scale);

    const bar_rect = Rect{
        .x = rect.x,
        .y = rect.y + rect.h - bar_height,
        .w = rect.w,
        .h = bar_height,
    };

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 27, 34, 48, 230);
    const bg_rect = c.SDL_FRect{
        .x = @floatFromInt(bar_rect.x),
        .y = @floatFromInt(bar_rect.y),
        .w = @floatFromInt(bar_rect.w),
        .h = @floatFromInt(bar_rect.h),
    };
    _ = c.SDL_RenderFillRect(renderer, &bg_rect);

    const font_px = dpi.scale(CWD_FONT_SIZE, ui_scale);
    if (session.cwd_font == null or session.cwd_font_size != font_px) {
        if (session.cwd_font) |font| {
            c.TTF_CloseFont(font);
        }
        session.cwd_font = c.TTF_OpenFont(font_path.ptr, @floatFromInt(font_px));
        session.cwd_font_size = font_px;
    }
    const cwd_font = session.cwd_font orelse return;

    const text_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };

    var basename_with_slash_buf: [std.fs.max_path_bytes]u8 = undefined;
    const basename_with_slash = blk: {
        if (std.mem.eql(u8, cwd_basename, "/")) {
            break :blk cwd_basename;
        }
        if (cwd_basename.len + 1 > basename_with_slash_buf.len) {
            log.warn("CWD basename too long for buffer (len={}, max_without_slash={}); skipping CWD bar rendering", .{
                cwd_basename.len,
                basename_with_slash_buf.len - 1,
            });
            return;
        }
        @memcpy(basename_with_slash_buf[0..cwd_basename.len], cwd_basename);
        basename_with_slash_buf[cwd_basename.len] = '/';
        break :blk basename_with_slash_buf[0 .. cwd_basename.len + 1];
    };

    if (session.cwd_basename_tex == null or session.cwd_basename_w == 0 or session.cwd_dirty) {
        if (session.cwd_basename_tex) |tex| {
            c.SDL_DestroyTexture(tex);
            session.cwd_basename_tex = null;
        }
        session.cwd_basename_w = 0;
        session.cwd_basename_h = 0;

        const basename_surface = c.TTF_RenderText_Blended(cwd_font, basename_with_slash.ptr, basename_with_slash.len, text_color) orelse return;
        defer c.SDL_DestroySurface(basename_surface);

        const basename_texture = c.SDL_CreateTextureFromSurface(renderer, basename_surface) orelse return;

        var basename_width_f: f32 = 0;
        var basename_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(basename_texture, &basename_width_f, &basename_height_f);

        session.cwd_basename_tex = basename_texture;
        session.cwd_basename_w = @intFromFloat(basename_width_f);
        session.cwd_basename_h = @intFromFloat(basename_height_f);
    }

    const basename_texture = session.cwd_basename_tex orelse return;
    const basename_width: c_int = session.cwd_basename_w;
    const text_height: c_int = session.cwd_basename_h;
    const basename_width_f: f32 = @floatFromInt(basename_width);
    const basename_height_f: f32 = @floatFromInt(text_height);

    const basename_x = bar_rect.x + bar_rect.w - basename_width - padding;
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
                log.warn(
                    "render: parent path too long (required={} bytes, buffer size={}), skipping parent path rendering",
                    .{ parent_without_slash.len + 1, parent_path_buf.len },
                );
                return;
            }
            @memcpy(parent_path_buf[0..parent_without_slash.len], parent_without_slash);
            parent_path_buf[parent_without_slash.len] = '/';
            break :blk parent_path_buf[0 .. parent_without_slash.len + 1];
        }
    };

    if (session.cwd_parent_tex == null or session.cwd_parent_w == 0 or session.cwd_dirty) {
        if (session.cwd_parent_tex) |tex| {
            c.SDL_DestroyTexture(tex);
            session.cwd_parent_tex = null;
        }
        session.cwd_parent_w = 0;
        session.cwd_parent_h = 0;

        const parent_surface = c.TTF_RenderText_Blended(cwd_font, parent_path.ptr, parent_path.len, text_color) orelse return;
        defer c.SDL_DestroySurface(parent_surface);

        const parent_texture = c.SDL_CreateTextureFromSurface(renderer, parent_surface) orelse return;

        var parent_width_f: f32 = 0;
        var parent_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(parent_texture, &parent_width_f, &parent_height_f);

        session.cwd_parent_tex = parent_texture;
        session.cwd_parent_w = @intFromFloat(parent_width_f);
        session.cwd_parent_h = @intFromFloat(parent_height_f);
    }

    const parent_texture = session.cwd_parent_tex orelse return;
    const parent_width: c_int = session.cwd_parent_w;
    const parent_height: c_int = session.cwd_parent_h;
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
        const elapsed_ms: f32 = @floatFromInt(@mod(current_time, cycle_ms_i64));

        const scroll_offset: c_int = blk: {
            if (elapsed_ms < idle_ms) break :blk 0;
            if (elapsed_ms < idle_ms + scroll_ms) {
                const progress = (elapsed_ms - idle_ms) / scroll_ms;
                break :blk @intFromFloat(progress * scroll_range_f);
            }
            break :blk scroll_range;
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
            renderFadeGradient(renderer, bar_rect, true, fade_width, padding);
        }
        if (fade_right) {
            const visible_end_x = bar_rect.x + padding + available_width;
            const fade_rect = Rect{
                .x = bar_rect.x,
                .y = bar_rect.y,
                .w = visible_end_x - bar_rect.x,
                .h = bar_rect.h,
            };
            renderFadeGradient(renderer, fade_rect, false, fade_width, padding);
        }
    }

    session.cwd_dirty = false;
}

fn renderFadeGradient(renderer: *c.SDL_Renderer, bar_rect: Rect, is_left: bool, fade_width: c_int, padding: c_int) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const fade_x = if (is_left) bar_rect.x + padding else bar_rect.x + bar_rect.w - fade_width;

    var i: c_int = 0;
    while (i < fade_width) : (i += 1) {
        const alpha_progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade_width));
        const alpha = if (is_left)
            @as(u8, @intFromFloat(230.0 * (1.0 - alpha_progress)))
        else
            @as(u8, @intFromFloat(230.0 * alpha_progress));

        _ = c.SDL_SetRenderDrawColor(renderer, 27, 34, 48, alpha);
        const line_x = fade_x + i;
        _ = c.SDL_RenderLine(renderer, @floatFromInt(line_x), @floatFromInt(bar_rect.y), @floatFromInt(line_x), @floatFromInt(bar_rect.y + bar_rect.h));
    }
}

fn getCellColor(color: ghostty_vt.Style.Color, default: c.SDL_Color) c.SDL_Color {
    return switch (color) {
        .none => default,
        .palette => |idx| get256Color(idx),
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

    const color_changed = !colorsEqual(run_fg, new_fg);
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
    const factor = FAINT_FACTOR;
    const r: u32 = @intFromFloat(@as(f32, @floatFromInt(color.r)) * factor);
    const g: u32 = @intFromFloat(@as(f32, @floatFromInt(color.g)) * factor);
    const b: u32 = @intFromFloat(@as(f32, @floatFromInt(color.b)) * factor);
    return c.SDL_Color{
        .r = @intCast(@min(@as(u32, 255), r)),
        .g = @intCast(@min(@as(u32, 255), g)),
        .b = @intCast(@min(@as(u32, 255), b)),
        .a = color.a,
    };
}

fn renderBoxDrawing(renderer: *c.SDL_Renderer, cp: u21, x: c_int, y: c_int, w: c_int, h: c_int, color: c.SDL_Color) bool {
    const thickness: f32 = @max(1.0, @as(f32, @floatFromInt(@min(w, h))) / 8.0);
    const half_t: f32 = thickness * 0.5;
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const mid_x: f32 = xf + wf * 0.5;
    const mid_y: f32 = yf + hf * 0.5;

    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);

    switch (cp) {
        0x2500 => {
            const rect = c.SDL_FRect{ .x = xf, .y = mid_y - half_t, .w = wf, .h = thickness };
            _ = c.SDL_RenderFillRect(renderer, &rect);
            return true;
        },
        0x2502 => {
            const rect = c.SDL_FRect{ .x = mid_x - half_t, .y = yf, .w = thickness, .h = hf };
            _ = c.SDL_RenderFillRect(renderer, &rect);
            return true;
        },
        0x256D => {
            const vert = c.SDL_FRect{ .x = mid_x - half_t, .y = mid_y, .w = thickness, .h = yf + hf - mid_y };
            const horiz = c.SDL_FRect{ .x = mid_x, .y = mid_y - half_t, .w = xf + wf - mid_x, .h = thickness };
            _ = c.SDL_RenderFillRect(renderer, &vert);
            _ = c.SDL_RenderFillRect(renderer, &horiz);
            return true;
        },
        0x256E => {
            const vert = c.SDL_FRect{ .x = mid_x - half_t, .y = mid_y, .w = thickness, .h = yf + hf - mid_y };
            const horiz = c.SDL_FRect{ .x = xf, .y = mid_y - half_t, .w = mid_x - xf, .h = thickness };
            _ = c.SDL_RenderFillRect(renderer, &vert);
            _ = c.SDL_RenderFillRect(renderer, &horiz);
            return true;
        },
        0x2570 => {
            const vert = c.SDL_FRect{ .x = mid_x - half_t, .y = yf, .w = thickness, .h = mid_y - yf };
            const horiz = c.SDL_FRect{ .x = mid_x, .y = mid_y - half_t, .w = xf + wf - mid_x, .h = thickness };
            _ = c.SDL_RenderFillRect(renderer, &vert);
            _ = c.SDL_RenderFillRect(renderer, &horiz);
            return true;
        },
        0x256F => {
            const vert = c.SDL_FRect{ .x = mid_x - half_t, .y = yf, .w = thickness, .h = mid_y - yf };
            const horiz = c.SDL_FRect{ .x = xf, .y = mid_y - half_t, .w = mid_x - xf, .h = thickness };
            _ = c.SDL_RenderFillRect(renderer, &vert);
            _ = c.SDL_RenderFillRect(renderer, &horiz);
            return true;
        },
        else => return false,
    }
}

fn isBoxDrawingChar(cp: u21) bool {
    return cp == 0x2500 or cp == 0x2502 or
        cp == 0x256D or cp == 0x256E or cp == 0x2570 or cp == 0x256F;
}

fn isFullCellGlyph(cp: u21) bool {
    return ((cp >= 0x2500 and cp <= 0x259F) and !isBoxDrawingChar(cp)) or (cp >= 0xE0B0 and cp <= 0xE0C8) or (cp == 0x2588);
}

fn get256Color(idx: u8) c.SDL_Color {
    if (idx < 16) {
        return ansi_colors[idx];
    } else if (idx < 232) {
        const color_idx = idx - 16;
        const r = (color_idx / 36) * 51;
        const g = ((color_idx % 36) / 6) * 51;
        const b = (color_idx % 6) * 51;
        return .{ .r = @intCast(r), .g = @intCast(g), .b = @intCast(b), .a = 255 };
    } else {
        const gray = 8 + (idx - 232) * 10;
        return .{ .r = @intCast(gray), .g = @intCast(gray), .b = @intCast(gray), .a = 255 };
    }
}

const ansi_colors = [_]c.SDL_Color{
    // Normal
    .{ .r = 14, .g = 17, .b = 22, .a = 255 }, // Black
    .{ .r = 224, .g = 108, .b = 117, .a = 255 }, // Red
    .{ .r = 152, .g = 195, .b = 121, .a = 255 }, // Green
    .{ .r = 209, .g = 154, .b = 102, .a = 255 }, // Yellow
    .{ .r = 97, .g = 175, .b = 239, .a = 255 }, // Blue
    .{ .r = 198, .g = 120, .b = 221, .a = 255 }, // Magenta
    .{ .r = 86, .g = 182, .b = 194, .a = 255 }, // Cyan
    .{ .r = 171, .g = 178, .b = 191, .a = 255 }, // White
    // Bright
    .{ .r = 92, .g = 99, .b = 112, .a = 255 }, // BrightBlack
    .{ .r = 224, .g = 108, .b = 117, .a = 255 }, // BrightRed
    .{ .r = 152, .g = 195, .b = 121, .a = 255 }, // BrightGreen
    .{ .r = 229, .g = 192, .b = 123, .a = 255 }, // BrightYellow
    .{ .r = 97, .g = 175, .b = 239, .a = 255 }, // BrightBlue
    .{ .r = 198, .g = 120, .b = 221, .a = 255 }, // BrightMagenta
    .{ .r = 86, .g = 182, .b = 194, .a = 255 }, // BrightCyan
    .{ .r = 205, .g = 214, .b = 224, .a = 255 }, // BrightWhite
};

test "get256Color - basic ANSI colors" {
    const black = get256Color(0);
    try std.testing.expectEqual(@as(u8, 0), black.r);
    try std.testing.expectEqual(@as(u8, 0), black.g);
    try std.testing.expectEqual(@as(u8, 0), black.b);

    const white = get256Color(15);
    try std.testing.expectEqual(@as(u8, 255), white.r);
    try std.testing.expectEqual(@as(u8, 255), white.g);
    try std.testing.expectEqual(@as(u8, 255), white.b);
}

fn colorsEqual(a: c.SDL_Color, b: c.SDL_Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

test "get256Color - grayscale" {
    const gray = get256Color(232);
    try std.testing.expectEqual(gray.r, gray.g);
    try std.testing.expectEqual(gray.g, gray.b);
}

test "colorsEqual" {
    const red = c.SDL_Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const also_red = c.SDL_Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const blue = c.SDL_Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const transparent_red = c.SDL_Color{ .r = 255, .g = 0, .b = 0, .a = 128 };

    try std.testing.expect(colorsEqual(red, also_red));
    try std.testing.expect(!colorsEqual(red, blue));
    try std.testing.expect(!colorsEqual(red, transparent_red));
}
