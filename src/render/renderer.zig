const std = @import("std");
const c = @import("../c.zig");
const ghostty_vt = @import("ghostty-vt");
const app_state = @import("../app/app_state.zig");
const font_mod = @import("../font.zig");
const session_state = @import("../session/state.zig");

const log = std.log.scoped(.render);

const SessionState = session_state.SessionState;
const Rect = app_state.Rect;
const AnimationState = app_state.AnimationState;
const ToastNotification = app_state.ToastNotification;
const HelpButtonAnimation = app_state.HelpButtonAnimation;

const FONT_PATH: [*:0]const u8 = "/System/Library/Fonts/SFNSMono.ttf";
const NOTIFICATION_FONT_SIZE: c_int = 36;
const NOTIFICATION_BG_MAX_ALPHA: u8 = 200;
const NOTIFICATION_BORDER_MAX_ALPHA: u8 = 180;
const ATTENTION_THICKNESS: c_int = 16;

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
) RenderError!void {
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
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

                try renderGridSessionCached(renderer, session, cell_rect, grid_scale, i == anim_state.focused_session, true, font, term_cols, term_rows, current_time);
            }
        },
        .Full => {
            const full_rect = Rect{ .x = 0, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.focused_session], full_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false);
        },
        .PanningLeft, .PanningRight => {
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, app_state.ANIMATION_DURATION_MS));
            const eased = AnimationState.easeInOutCubic(progress);

            const offset = @as(c_int, @intFromFloat(@as(f32, @floatFromInt(window_width)) * eased));
            const pan_offset = if (anim_state.mode == .PanningLeft) -offset else offset;

            const prev_rect = Rect{ .x = pan_offset, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.previous_session], prev_rect, 1.0, false, false, font, term_cols, term_rows, current_time, false);

            const new_offset = if (anim_state.mode == .PanningLeft)
                window_width - offset
            else
                -window_width + offset;
            const new_rect = Rect{ .x = new_offset, .y = 0, .w = window_width, .h = window_height };
            try renderSession(renderer, &sessions[anim_state.focused_session], new_rect, 1.0, true, false, font, term_cols, term_rows, current_time, false);
        },
        .PreCollapse => {
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(app_state.PRECOLLAPSE_DURATION_MS)));
            const eased = AnimationState.easeInOutCubic(progress);
            const anim_scale = 1.0 + (app_state.PRECOLLAPSE_SCALE - 1.0) * eased;

            const shrink_offset_x: c_int = @intFromFloat(@as(f32, @floatFromInt(window_width)) * (1.0 - anim_scale) / 2.0);
            const shrink_offset_y: c_int = @intFromFloat(@as(f32, @floatFromInt(window_height)) * (1.0 - anim_scale) / 2.0);
            const shrink_width: c_int = @intFromFloat(@as(f32, @floatFromInt(window_width)) * anim_scale);
            const shrink_height: c_int = @intFromFloat(@as(f32, @floatFromInt(window_height)) * anim_scale);

            const animating_rect = Rect{
                .x = shrink_offset_x,
                .y = shrink_offset_y,
                .w = shrink_width,
                .h = shrink_height,
            };
            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, true, font, term_cols, term_rows, current_time, false);
        },
        .CancelPreCollapse => {
            const animating_rect = anim_state.getCurrentRect(current_time);
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(app_state.ANIMATION_DURATION_MS)));
            const eased = AnimationState.easeInOutCubic(progress);

            const start_scale: f32 = app_state.PRECOLLAPSE_SCALE;
            const end_scale: f32 = 1.0;
            const anim_scale = start_scale + (end_scale - start_scale) * eased;

            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, true, font, term_cols, term_rows, current_time, false);
        },
        .Expanding, .Collapsing => {
            const animating_rect = anim_state.getCurrentRect(current_time);
            const elapsed = current_time - anim_state.start_time;
            const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, app_state.ANIMATION_DURATION_MS));
            const eased = AnimationState.easeInOutCubic(progress);
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

                    try renderGridSessionCached(renderer, session, cell_rect, grid_scale, false, true, font, term_cols, term_rows, current_time);
                }
            }

            const apply_effects = anim_scale < 0.999;
            try renderSession(renderer, &sessions[anim_state.focused_session], animating_rect, anim_scale, true, apply_effects, font, term_cols, term_rows, current_time, false);
        },
    }
}

fn renderSession(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    apply_effects: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    current_time_ms: i64,
    is_grid_view: bool,
) RenderError!void {
    try renderSessionContent(renderer, session, rect, scale, is_focused, font, term_cols, term_rows);
    renderSessionOverlays(renderer, session, rect, is_focused, apply_effects, current_time_ms, is_grid_view);
}

fn renderSessionContent(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    scale: f32,
    is_focused: bool,
    font: *font_mod.Font,
    term_cols: u16,
    term_rows: u16,
) RenderError!void {
    if (!session.spawned) {
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    } else if (is_focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 60, 255);
    } else {
        _ = c.SDL_SetRenderDrawColor(renderer, 30, 30, 40, 255);
    }
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
    const pages = screen.pages;

    const base_cell_width = font.cell_width;
    const base_cell_height = font.cell_height;

    const cell_width_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_width)) * scale)));
    const cell_height_actual: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(base_cell_height)) * scale)));

    const padding: c_int = 8;
    const drawable_w: c_int = rect.w - padding * 2;
    const drawable_h: c_int = rect.h - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return;

    const origin_x: c_int = rect.x + padding;
    const origin_y: c_int = rect.y + padding;

    const max_cols_fit: usize = @intCast(@max(0, @divFloor(drawable_w, cell_width_actual)));
    const max_rows_fit: usize = @intCast(@max(0, @divFloor(drawable_h, cell_height_actual)));
    const visible_cols: usize = @min(@as(usize, term_cols), max_cols_fit);
    const visible_rows: usize = @min(@as(usize, term_rows), max_rows_fit);

    const default_fg = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };

    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
        var col: usize = 0;
        while (col < visible_cols) : (col += 1) {
            const list_cell = pages.getCell(if (session.is_scrolled)
                .{ .viewport = .{ .x = @intCast(col), .y = @intCast(row) } }
            else
                .{ .active = .{ .x = @intCast(col), .y = @intCast(row) } }) orelse continue;

            const cell = list_cell.cell;
            const cp = cell.content.codepoint;
            if (cp == 0 or cp == ' ') continue;

            const x: c_int = origin_x + @as(c_int, @intCast(col)) * cell_width_actual;
            const y: c_int = origin_y + @as(c_int, @intCast(row)) * cell_height_actual;

            if (x < rect.x or x >= rect.x + rect.w) continue;
            if (y < rect.y or y >= rect.y + rect.h) continue;

            const style = list_cell.style();
            const fg_color = getCellColor(style.fg_color, default_fg);

            try font.renderGlyph(cp, x, y, cell_width_actual, cell_height_actual, fg_color);
        }
    }

    if (!session.is_scrolled and is_focused) {
        const cursor = screen.cursor;
        const cursor_col = cursor.x;
        const cursor_row = cursor.y;

        if (cursor_col < visible_cols and cursor_row < visible_rows) {
            const cursor_x: c_int = origin_x + @as(c_int, @intCast(cursor_col)) * cell_width_actual;
            const cursor_y: c_int = origin_y + @as(c_int, @intCast(cursor_row)) * cell_height_actual;

            if (cursor_x >= rect.x and cursor_x < rect.x + rect.w and
                cursor_y >= rect.y and cursor_y < rect.y + rect.h)
            {
                _ = c.SDL_SetRenderDrawColor(renderer, 200, 200, 200, 255);
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
}

fn renderSessionOverlays(
    renderer: *c.SDL_Renderer,
    session: *const SessionState,
    rect: Rect,
    is_focused: bool,
    apply_effects: bool,
    current_time_ms: i64,
    is_grid_view: bool,
) void {
    if (apply_effects) {
        applyTvOverlay(renderer, rect, is_focused);
    } else {
        if (is_focused) {
            _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, 255);
        } else {
            _ = c.SDL_SetRenderDrawColor(renderer, 60, 60, 60, 255);
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
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 100, 200);
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
                break :blk c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = base_alpha };
            },
            .done => c.SDL_Color{ .r = 35, .g = 209, .b = 139, .a = 230 },
            else => c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = 230 },
        };
        drawThickBorder(renderer, rect, ATTENTION_THICKNESS, color);

        const tint_color = switch (session.status) {
            .awaiting_approval => c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = 25 },
            .done => c.SDL_Color{ .r = 35, .g = 209, .b = 139, .a = 30 },
            else => c.SDL_Color{ .r = 255, .g = 212, .b = 71, .a = 25 },
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
) RenderError!void {
    const can_cache = ensureCacheTexture(renderer, session, rect.w, rect.h);

    if (can_cache) {
        if (session.cache_texture) |tex| {
            if (session.dirty) {
                log.debug("rendering to cache: session={d} spawned={} focused={}", .{ session.id, session.spawned, is_focused });
                _ = c.SDL_SetRenderTarget(renderer, tex);
                _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
                _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
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
            renderSessionOverlays(renderer, session, rect, is_focused, apply_effects, current_time_ms, true);
            return;
        }
    }

    try renderSession(renderer, session, rect, scale, is_focused, apply_effects, font, term_cols, term_rows, current_time_ms, true);
}

fn applyTvOverlay(renderer: *c.SDL_Renderer, rect: Rect, is_focused: bool) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 60);
    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    });

    const radius: c_int = 12;

    const border_color = if (is_focused)
        c.SDL_Color{ .r = 120, .g = 170, .b = 255, .a = 190 }
    else
        c.SDL_Color{ .r = 80, .g = 80, .b = 90, .a = 170 };

    _ = c.SDL_SetRenderDrawColor(renderer, border_color.r, border_color.g, border_color.b, border_color.a);
    drawRoundedBorder(renderer, rect, radius);
}

fn drawRoundedBorder(renderer: *c.SDL_Renderer, rect: Rect, radius: c_int) void {
    const fx = @as(f32, @floatFromInt(rect.x));
    const fy = @as(f32, @floatFromInt(rect.y));
    const fw = @as(f32, @floatFromInt(rect.w));
    const fh = @as(f32, @floatFromInt(rect.h));
    const frad = @as(f32, @floatFromInt(radius));

    _ = c.SDL_RenderLine(renderer, fx + frad, fy, fx + fw - frad - 1.0, fy);
    _ = c.SDL_RenderLine(renderer, fx + frad, fy + fh - 1.0, fx + fw - frad - 1.0, fy + fh - 1.0);
    _ = c.SDL_RenderLine(renderer, fx, fy + frad, fx, fy + fh - frad - 1.0);
    _ = c.SDL_RenderLine(renderer, fx + fw - 1.0, fy + frad, fx + fw - 1.0, fy + fh - frad - 1.0);

    var angle: f32 = 0.0;
    const step: f32 = std.math.pi / 64.0;
    while (angle <= std.math.pi / 2.0) : (angle += step) {
        const rx = frad * std.math.cos(angle);
        const ry = frad * std.math.sin(angle);

        const centers = [_]struct { x: f32, y: f32, sx: f32, sy: f32 }{
            .{ .x = fx + frad, .y = fy + frad, .sx = -1.0, .sy = -1.0 },
            .{ .x = fx + fw - frad - 1.0, .y = fy + frad, .sx = 1.0, .sy = -1.0 },
            .{ .x = fx + frad, .y = fy + fh - frad - 1.0, .sx = -1.0, .sy = 1.0 },
            .{ .x = fx + fw - frad - 1.0, .y = fy + fh - frad - 1.0, .sx = 1.0, .sy = 1.0 },
        };

        for (centers) |cinfo| {
            _ = c.SDL_RenderPoint(renderer, cinfo.x + cinfo.sx * rx, cinfo.y + cinfo.sy * ry);
        }
    }
}

fn drawThickBorder(renderer: *c.SDL_Renderer, rect: Rect, thickness: c_int, color: c.SDL_Color) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    const radius: c_int = 12;
    var i: c_int = 0;
    while (i < thickness) : (i += 1) {
        const r = Rect{
            .x = rect.x + i,
            .y = rect.y + i,
            .w = rect.w - i * 2,
            .h = rect.h - i * 2,
        };
        drawRoundedBorder(renderer, r, radius);
    }
}

pub fn renderToastNotification(
    renderer: *c.SDL_Renderer,
    notification: *const ToastNotification,
    current_time: i64,
    window_width: c_int,
) void {
    if (!notification.isVisible(current_time)) return;

    const alpha = notification.getAlpha(current_time);
    if (alpha == 0) return;

    const notification_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(NOTIFICATION_FONT_SIZE)) orelse return;
    defer c.TTF_CloseFont(notification_font);

    const message_z = @as([*:0]const u8, @ptrCast(&notification.message));
    const fg_color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = alpha };
    const surface = c.TTF_RenderText_Blended(notification_font, message_z, notification.message_len, fg_color) orelse return;
    defer c.SDL_DestroySurface(surface);

    const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
    defer c.SDL_DestroyTexture(texture);

    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);

    var text_width_f: f32 = 0;
    var text_height_f: f32 = 0;
    _ = c.SDL_GetTextureSize(texture, &text_width_f, &text_height_f);

    const text_width: c_int = @intFromFloat(text_width_f);
    const text_height: c_int = @intFromFloat(text_height_f);

    const padding: c_int = 30;
    const bg_padding: c_int = 20;
    const x = @divFloor(window_width - text_width, 2);
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

    const dest_rect = c.SDL_FRect{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .w = text_width_f,
        .h = text_height_f,
    };

    _ = c.SDL_RenderTexture(renderer, texture, null, &dest_rect);
}

pub fn renderHelpButton(
    renderer: *c.SDL_Renderer,
    help_button: *const HelpButtonAnimation,
    current_time: i64,
    window_width: c_int,
    window_height: c_int,
) void {
    const rect = help_button.getRect(current_time, window_width, window_height);
    const radius: c_int = 8;

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 50, 220);
    const bg_rect = c.SDL_FRect{
        .x = @floatFromInt(rect.x),
        .y = @floatFromInt(rect.y),
        .w = @floatFromInt(rect.w),
        .h = @floatFromInt(rect.h),
    };
    _ = c.SDL_RenderFillRect(renderer, &bg_rect);

    _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, 255);
    drawRoundedBorder(renderer, rect, radius);

    if (help_button.state == .Closed or help_button.state == .Collapsing or help_button.state == .Expanding) {
        const font_size = @max(16, @min(32, @divFloor(rect.h * 3, 4)));
        const question_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(font_size)) orelse return;
        defer c.TTF_CloseFont(question_font);

        const question_mark: [2]u8 = .{ '?', 0 };
        const fg_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
        const surface = c.TTF_RenderText_Blended(question_font, &question_mark, 1, fg_color) orelse return;
        defer c.SDL_DestroySurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(texture);

        var text_width_f: f32 = 0;
        var text_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &text_width_f, &text_height_f);

        const text_x = rect.x + @divFloor(rect.w - @as(c_int, @intFromFloat(text_width_f)), 2);
        const text_y = rect.y + @divFloor(rect.h - @as(c_int, @intFromFloat(text_height_f)), 2);

        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(text_x),
            .y = @floatFromInt(text_y),
            .w = text_width_f,
            .h = text_height_f,
        };
        _ = c.SDL_RenderTexture(renderer, texture, null, &dest_rect);
    } else if (help_button.state == .Open) {
        const title_font_size: c_int = 20;
        const key_font_size: c_int = 16;
        const padding: c_int = 20;
        const line_height: c_int = 28;
        var y_offset: c_int = rect.y + padding;

        const title_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(title_font_size)) orelse return;
        defer c.TTF_CloseFont(title_font);

        const key_font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(key_font_size)) orelse return;
        defer c.TTF_CloseFont(key_font);

        const title_text = "Keyboard Shortcuts";
        const title_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
        const title_surface = c.TTF_RenderText_Blended(title_font, title_text, title_text.len, title_color) orelse return;
        defer c.SDL_DestroySurface(title_surface);

        const title_texture = c.SDL_CreateTextureFromSurface(renderer, title_surface) orelse return;
        defer c.SDL_DestroyTexture(title_texture);

        var title_width_f: f32 = 0;
        var title_height_f: f32 = 0;
        _ = c.SDL_GetTextureSize(title_texture, &title_width_f, &title_height_f);

        const title_x = rect.x + @divFloor(rect.w - @as(c_int, @intFromFloat(title_width_f)), 2);
        _ = c.SDL_RenderTexture(renderer, title_texture, null, &c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(y_offset),
            .w = title_width_f,
            .h = title_height_f,
        });

        y_offset += @as(c_int, @intFromFloat(title_height_f)) + line_height;

        const shortcuts = [_]struct { key: []const u8, desc: []const u8 }{
            .{ .key = "Click terminal", .desc = "Expand to full screen" },
            .{ .key = "ESC (hold)", .desc = "Collapse to grid view" },
            .{ .key = "⌘⇧[ / ⌘⇧]", .desc = "Switch terminals" },
            .{ .key = "⌘↑/↓/←/→", .desc = "Navigate grid" },
            .{ .key = "⌘⇧+ / ⌘⇧-", .desc = "Adjust font size" },
            .{ .key = "Mouse wheel", .desc = "Scroll history" },
        };

        const key_color = c.SDL_Color{ .r = 120, .g = 170, .b = 255, .a = 255 };
        const desc_color = c.SDL_Color{ .r = 180, .g = 180, .b = 180, .a = 255 };

        for (shortcuts) |shortcut| {
            const key_surface = c.TTF_RenderText_Blended(key_font, shortcut.key.ptr, shortcut.key.len, key_color) orelse continue;
            defer c.SDL_DestroySurface(key_surface);

            const key_texture = c.SDL_CreateTextureFromSurface(renderer, key_surface) orelse continue;
            defer c.SDL_DestroyTexture(key_texture);

            var key_width_f: f32 = 0;
            var key_height_f: f32 = 0;
            _ = c.SDL_GetTextureSize(key_texture, &key_width_f, &key_height_f);

            _ = c.SDL_RenderTexture(renderer, key_texture, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + padding),
                .y = @floatFromInt(y_offset),
                .w = key_width_f,
                .h = key_height_f,
            });

            const desc_surface = c.TTF_RenderText_Blended(key_font, shortcut.desc.ptr, shortcut.desc.len, desc_color) orelse continue;
            defer c.SDL_DestroySurface(desc_surface);

            const desc_texture = c.SDL_CreateTextureFromSurface(renderer, desc_surface) orelse continue;
            defer c.SDL_DestroyTexture(desc_texture);

            var desc_width_f: f32 = 0;
            var desc_height_f: f32 = 0;
            _ = c.SDL_GetTextureSize(desc_texture, &desc_width_f, &desc_height_f);

            _ = c.SDL_RenderTexture(renderer, desc_texture, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + rect.w - padding - @as(c_int, @intFromFloat(desc_width_f))),
                .y = @floatFromInt(y_offset),
                .w = desc_width_f,
                .h = desc_height_f,
            });

            y_offset += line_height;
        }
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
    .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    .{ .r = 205, .g = 49, .b = 49, .a = 255 },
    .{ .r = 13, .g = 188, .b = 121, .a = 255 },
    .{ .r = 229, .g = 229, .b = 16, .a = 255 },
    .{ .r = 36, .g = 114, .b = 200, .a = 255 },
    .{ .r = 188, .g = 63, .b = 188, .a = 255 },
    .{ .r = 17, .g = 168, .b = 205, .a = 255 },
    .{ .r = 229, .g = 229, .b = 229, .a = 255 },
    .{ .r = 102, .g = 102, .b = 102, .a = 255 },
    .{ .r = 241, .g = 76, .b = 76, .a = 255 },
    .{ .r = 35, .g = 209, .b = 139, .a = 255 },
    .{ .r = 245, .g = 245, .b = 67, .a = 255 },
    .{ .r = 59, .g = 142, .b = 234, .a = 255 },
    .{ .r = 214, .g = 112, .b = 214, .a = 255 },
    .{ .r = 41, .g = 184, .b = 219, .a = 255 },
    .{ .r = 255, .g = 255, .b = 255, .a = 255 },
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

test "get256Color - grayscale" {
    const gray = get256Color(232);
    try std.testing.expectEqual(gray.r, gray.g);
    try std.testing.expectEqual(gray.g, gray.b);
}
