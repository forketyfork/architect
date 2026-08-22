const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const text_edit = @import("../text_edit.zig");
const dpi = @import("../../dpi.zig");
const flowing_line = @import("flowing_line.zig");
const search_utils = @import("search_utils.zig");
const font_cache_mod = @import("../../font_cache.zig");
const model = @import("pr_dropdown_model.zig");

const log = std.log.scoped(.pr_dropdown);
const TextTex = search_utils.TextTex;
const glyph_horizontal_padding: c_int = 8;

pub const EntryTex = struct {
    hotkey: TextTex,
    label: TextTex,
    displayed_text: []const u8,
};

pub const GlyphSize = struct {
    width: f32,
    height: f32,
};

pub const Cache = struct {
    ui_scale: f32,
    title_font_size: c_int,
    entry_font_size: c_int,
    title: TextTex,
    status_line: ?TextTex,
    entries: []EntryTex,
    theme_fg: c.SDL_Color,
    font_generation: u64,
    query_len: usize,
    filtered_count: usize,
    status: model.FetchStatus,
    content_height: c_int,
};

pub const RenderState = struct {
    allocator: std.mem.Allocator,
    prs: []const model.PullRequest,
    filtered_indices: []const usize,
    search_query: *const text_edit.TextInput,
    selected_index: usize,
    hovered_entry: ?usize,
    fetch_status: model.FetchStatus,
    fetch_error: ?[]const u8,
};

pub fn renderGlyph(
    renderer: *c.SDL_Renderer,
    rect: geom.Rect,
    ui_scale: f32,
    current_pr_number: ?u32,
    assets: *types.UiAssets,
    theme: *const colors.Theme,
) void {
    const cache = assets.font_cache orelse return;
    const font_size = dpi.scale(@max(12, @min(20, @divFloor(rect.h, 2))), ui_scale);
    const fonts = cache.get(font_size) catch return;

    var label_buf: [16]u8 = undefined;
    const label = if (current_pr_number) |number|
        std.fmt.bufPrint(&label_buf, "#{d}", .{number}) catch "⌘P"
    else
        "⌘P";

    const fg = theme.foreground;
    const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
    const surface = c.TTF_RenderText_Blended(fonts.regular, label.ptr, @intCast(label.len), fg_color) orelse return;
    defer c.SDL_DestroySurface(surface);
    const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
    defer c.SDL_DestroyTexture(texture);

    var tw: f32 = 0;
    var th: f32 = 0;
    _ = c.SDL_GetTextureSize(texture, &tw, &th);
    const glyph_size = if (current_pr_number != null)
        fitPrGlyphSize(rect.w, ui_scale, .{ .width = tw, .height = th })
    else
        GlyphSize{ .width = tw, .height = th };
    const dest = c.SDL_FRect{
        .x = @floatFromInt(rect.x + @divFloor(rect.w - @as(c_int, @intFromFloat(glyph_size.width)), 2)),
        .y = @floatFromInt(rect.y + @divFloor(rect.h - @as(c_int, @intFromFloat(glyph_size.height)), 2)),
        .w = glyph_size.width,
        .h = glyph_size.height,
    };
    _ = c.SDL_RenderTexture(renderer, texture, null, &dest);
}

pub fn fitPrGlyphSize(rect_width: c_int, ui_scale: f32, size: GlyphSize) GlyphSize {
    const max_width: c_int = @max(1, rect_width - dpi.scale(glyph_horizontal_padding, ui_scale));
    const max_width_f: f32 = @floatFromInt(max_width);
    if (size.width <= max_width_f) return size;

    const scale = max_width_f / size.width;
    return .{ .width = max_width_f, .height = size.height * scale };
}

pub fn ensureCache(
    state: RenderState,
    cache_ptr: *?*Cache,
    renderer: *c.SDL_Renderer,
    ui_scale: f32,
    assets: *types.UiAssets,
    theme: *const colors.Theme,
) ?*Cache {
    const cache_store = assets.font_cache orelse return null;
    const title_font_size: c_int = dpi.scale(20, ui_scale);
    const entry_font_size: c_int = dpi.scale(16, ui_scale);
    const fg = theme.foreground;
    const entry_count = state.filtered_indices.len;

    if (cache_ptr.*) |cache| {
        if (cache.title_font_size == title_font_size and
            cache.entry_font_size == entry_font_size and
            cache.theme_fg.r == fg.r and cache.theme_fg.g == fg.g and cache.theme_fg.b == fg.b and
            cache.ui_scale == ui_scale and
            cache.entries.len == entry_count and
            cache.font_generation == cache_store.generation and
            cache.query_len == state.search_query.text().len and
            cache.filtered_count == entry_count and
            cache.status == state.fetch_status)
        {
            return cache;
        }
        destroyCache(state.allocator, cache_ptr);
    }

    const cache = state.allocator.create(Cache) catch return null;
    errdefer state.allocator.destroy(cache);

    const title_fonts = cache_store.get(title_font_size) catch return null;
    const entry_fonts = cache_store.get(entry_font_size) catch return null;

    const title_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
    const title_tex = makeTextTexture(renderer, title_fonts.regular, "Pull Requests", title_color) catch return null;

    var status_line: ?TextTex = null;
    const status_text = statusLineText(state);
    if (status_text) |status| {
        const muted = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };
        status_line = makeTextTexture(renderer, entry_fonts.regular, status, muted) catch |err| blk: {
            log.warn("failed to render PR status line: {}", .{err});
            break :blk null;
        };
    }

    const key_color = c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 255 };
    const entry_color = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };

    const entries = state.allocator.alloc(EntryTex, entry_count) catch {
        c.SDL_DestroyTexture(title_tex.tex);
        if (status_line) |status| c.SDL_DestroyTexture(status.tex);
        return null;
    };
    errdefer state.allocator.free(entries);

    const padding = dpi.scale(20, ui_scale);
    const overlay_width = dpi.scale(480, ui_scale);
    const hotkey_spacing = dpi.scale(10, ui_scale);

    for (0..entry_count) |idx| {
        const source_idx = state.filtered_indices[idx];
        const pr = state.prs[source_idx];

        var key_buf: [8]u8 = undefined;
        const digit: u8 = @as(u8, @intCast((idx + 1) % 10));
        const key_slice = std.fmt.bufPrint(&key_buf, "⌘{d}", .{digit}) catch |err| blk: {
            log.warn("failed to format hotkey: {}", .{err});
            break :blk key_buf[0..0];
        };
        const key_tex = makeTextTexture(renderer, entry_fonts.regular, key_slice, key_color) catch {
            destroyEntryTextures(state.allocator, entries[0..idx]);
            state.allocator.free(entries);
            c.SDL_DestroyTexture(title_tex.tex);
            if (status_line) |status| c.SDL_DestroyTexture(status.tex);
            return null;
        };

        var label_buf: [512]u8 = undefined;
        const full_label = std.fmt.bufPrint(&label_buf, "#{d}  {s}", .{ pr.number, pr.title }) catch blk: {
            break :blk std.fmt.bufPrint(&label_buf, "#{d}", .{pr.number}) catch label_buf[0..0];
        };

        const max_label_width = overlay_width - (2 * padding) - key_tex.w - hotkey_spacing;
        var truncated_buf: [512]u8 = undefined;
        const display_label = truncateTextRight(full_label, entry_fonts.regular, max_label_width, &truncated_buf) catch |err| blk: {
            log.warn("failed to truncate label: {}", .{err});
            break :blk full_label;
        };
        const label_tex = makeTextTexture(renderer, entry_fonts.regular, display_label, entry_color) catch {
            c.SDL_DestroyTexture(key_tex.tex);
            destroyEntryTextures(state.allocator, entries[0..idx]);
            state.allocator.free(entries);
            c.SDL_DestroyTexture(title_tex.tex);
            if (status_line) |status| c.SDL_DestroyTexture(status.tex);
            return null;
        };
        const stored_text = state.allocator.dupe(u8, display_label) catch {
            c.SDL_DestroyTexture(label_tex.tex);
            c.SDL_DestroyTexture(key_tex.tex);
            destroyEntryTextures(state.allocator, entries[0..idx]);
            state.allocator.free(entries);
            c.SDL_DestroyTexture(title_tex.tex);
            if (status_line) |status| c.SDL_DestroyTexture(status.tex);
            return null;
        };
        entries[idx] = .{ .hotkey = key_tex, .label = label_tex, .displayed_text = stored_text };
    }

    const scaled_line_height: c_int = dpi.scale(28, ui_scale);
    const scaled_padding: c_int = dpi.scale(2 * 20, ui_scale);
    const search_h = dpi.scale(28, ui_scale) + dpi.scale(8, ui_scale);
    const status_h: c_int = if (status_line) |status| status.h + dpi.scale(8, ui_scale) else 0;
    const content_height = scaled_padding + title_tex.h + dpi.scale(8, ui_scale) + search_h + status_h + @as(c_int, @intCast(entry_count)) * scaled_line_height;

    cache.* = .{
        .ui_scale = ui_scale,
        .title_font_size = title_font_size,
        .entry_font_size = entry_font_size,
        .title = title_tex,
        .status_line = status_line,
        .entries = entries,
        .theme_fg = fg,
        .font_generation = cache_store.generation,
        .query_len = state.search_query.text().len,
        .filtered_count = entry_count,
        .status = state.fetch_status,
        .content_height = content_height,
    };

    cache_ptr.* = cache;
    return cache;
}

pub fn renderOverlay(
    renderer: *c.SDL_Renderer,
    host: *const types.UiHost,
    rect: geom.Rect,
    ui_scale: f32,
    assets: *types.UiAssets,
    theme: *const colors.Theme,
    cache: *const Cache,
    state: RenderState,
    flow_animation_start_ms: i64,
) void {
    const scaled_margin: c_int = dpi.scale(20, ui_scale);
    const scaled_line_height: c_int = dpi.scale(28, ui_scale);
    var y_offset: c_int = rect.y + scaled_margin;

    const title_tex = cache.title;
    const title_x = rect.x + @divFloor(rect.w - title_tex.w, 2);
    _ = c.SDL_RenderTexture(renderer, title_tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(title_x),
        .y = @floatFromInt(y_offset),
        .w = @floatFromInt(title_tex.w),
        .h = @floatFromInt(title_tex.h),
    });
    y_offset += title_tex.h + dpi.scale(8, ui_scale);

    const font_cache = assets.font_cache orelse return;
    const search_bar_rect = geom.Rect{
        .x = rect.x + scaled_margin,
        .y = y_offset,
        .w = rect.w - 2 * scaled_margin,
        .h = dpi.scale(28, ui_scale),
    };
    search_utils.renderSearchBar(
        state.allocator,
        renderer,
        host,
        search_bar_rect,
        font_cache,
        state.search_query,
        state.filtered_indices.len,
        if (state.filtered_indices.len > 0) state.selected_index else null,
    ) catch |err| {
        log.warn("failed to render search bar: {}", .{err});
    };
    y_offset += dpi.scale(28, ui_scale) + dpi.scale(8, ui_scale);

    if (cache.status_line) |status_tex| {
        _ = c.SDL_RenderTexture(renderer, status_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + scaled_margin),
            .y = @floatFromInt(y_offset),
            .w = @floatFromInt(status_tex.w),
            .h = @floatFromInt(status_tex.h),
        });
        y_offset += status_tex.h + dpi.scale(8, ui_scale);
    }

    const entry_font_size: c_int = dpi.scale(16, ui_scale);
    const entry_fonts = font_cache.get(entry_font_size) catch |err| blk: {
        log.warn("failed to load entry font size {d}: {}", .{ entry_font_size, err });
        break :blk null;
    };
    const query = std.mem.trim(u8, state.search_query.text(), " \t");

    for (cache.entries, 0..) |entry_tex, idx| {
        const is_selected = idx == state.selected_index;
        const is_hovered = if (state.hovered_entry) |hovered| hovered == idx else false;

        if (is_selected or is_hovered) {
            const highlight_y = @as(f32, @floatFromInt(y_offset - dpi.scale(4, ui_scale)));
            const highlight_h = @as(f32, @floatFromInt(scaled_line_height));
            const fade_width: f32 = @as(f32, @floatFromInt(dpi.scale(40, ui_scale)));
            const rect_x: f32 = @floatFromInt(rect.x);
            const rect_w: f32 = @floatFromInt(rect.w);

            const center_rect = c.SDL_FRect{
                .x = rect_x + fade_width,
                .y = highlight_y,
                .w = rect_w - 2.0 * fade_width,
                .h = highlight_h,
            };
            const acc = theme.accent;
            const alpha: u8 = if (is_selected) 60 else 40;
            _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, alpha);
            _ = c.SDL_RenderFillRect(renderer, &center_rect);

            const strips_count = 6;
            var i: usize = 0;
            while (i < strips_count) : (i += 1) {
                const progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(strips_count));
                const strip_w = fade_width / @as(f32, @floatFromInt(strips_count));

                const left_alpha = @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * progress));
                const left_strip = c.SDL_FRect{
                    .x = rect_x + @as(f32, @floatFromInt(i)) * strip_w,
                    .y = highlight_y,
                    .w = strip_w,
                    .h = highlight_h,
                };
                _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, left_alpha);
                _ = c.SDL_RenderFillRect(renderer, &left_strip);

                const right_alpha = @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * (1.0 - progress)));
                const right_strip = c.SDL_FRect{
                    .x = rect_x + rect_w - fade_width + @as(f32, @floatFromInt(i)) * strip_w,
                    .y = highlight_y,
                    .w = strip_w,
                    .h = highlight_h,
                };
                _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, right_alpha);
                _ = c.SDL_RenderFillRect(renderer, &right_strip);
            }
        }

        _ = c.SDL_RenderTexture(renderer, entry_tex.hotkey.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + scaled_margin),
            .y = @floatFromInt(y_offset),
            .w = @floatFromInt(entry_tex.hotkey.w),
            .h = @floatFromInt(entry_tex.hotkey.h),
        });

        const label_x = rect.x + scaled_margin + entry_tex.hotkey.w + dpi.scale(10, ui_scale);
        _ = c.SDL_RenderTexture(renderer, entry_tex.label.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(label_x),
            .y = @floatFromInt(y_offset),
            .w = @floatFromInt(entry_tex.label.w),
            .h = @floatFromInt(entry_tex.label.h),
        });

        if (query.len > 0 and entry_fonts != null) {
            renderLabelHighlights(
                renderer,
                host,
                entry_fonts.?,
                label_x,
                y_offset,
                scaled_line_height,
                ui_scale,
                entry_tex.displayed_text,
                query,
            );
        }

        if (is_selected) {
            const flow_y = y_offset + @divFloor(entry_tex.label.h, 2);
            flowing_line.render(renderer, flow_animation_start_ms, host.now_ms, rect, flow_y, ui_scale, theme);
        }

        y_offset += scaled_line_height;
    }
}

fn renderLabelHighlights(
    renderer: *c.SDL_Renderer,
    host: *const types.UiHost,
    entry_fonts: *font_cache_mod.FontSet,
    label_x: c_int,
    y_offset: c_int,
    line_height: c_int,
    ui_scale: f32,
    display_text: []const u8,
    query: []const u8,
) void {
    var pos: usize = 0;
    while (search_utils.findCaseInsensitive(display_text, query, pos)) |found| {
        const before_text = display_text[0..found];
        const match_text = display_text[found .. found + query.len];

        var before_w: c_int = 0;
        var before_h: c_int = 0;
        if (before_text.len > 0) {
            _ = c.TTF_GetStringSize(entry_fonts.regular, @ptrCast(before_text.ptr), before_text.len, &before_w, &before_h);
        }
        var match_w: c_int = 0;
        var match_h: c_int = 0;
        _ = c.TTF_GetStringSize(entry_fonts.regular, @ptrCast(match_text.ptr), match_text.len, &match_w, &match_h);

        const highlight_x = label_x + before_w;
        const highlight_y = y_offset + dpi.scale(2, ui_scale);
        const highlight_h = line_height - dpi.scale(6, ui_scale);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 120);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(highlight_x),
            .y = @floatFromInt(highlight_y),
            .w = @floatFromInt(match_w),
            .h = @floatFromInt(highlight_h),
        });
        pos = found + 1;
    }
}

fn statusLineText(state: RenderState) ?[]const u8 {
    return switch (state.fetch_status) {
        .idle => "Press ⌘P to refresh.",
        .fetching => "Loading pull requests…",
        .ok => if (state.prs.len == 0) "No open pull requests." else null,
        .failed => state.fetch_error orelse "Failed to fetch pull requests.",
        .gh_missing => "Install GitHub CLI (`gh`) to list pull requests.",
    };
}

pub fn destroyCache(allocator: std.mem.Allocator, cache_ptr: *?*Cache) void {
    if (cache_ptr.*) |cache| {
        c.SDL_DestroyTexture(cache.title.tex);
        if (cache.status_line) |status| c.SDL_DestroyTexture(status.tex);
        destroyEntryTextures(allocator, cache.entries);
        allocator.free(cache.entries);
        allocator.destroy(cache);
        cache_ptr.* = null;
    }
}

fn makeTextTexture(
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    text: []const u8,
    color: c.SDL_Color,
) !TextTex {
    if (text.len == 0) return error.EmptyText;
    var buf: [512]u8 = undefined;
    if (text.len >= buf.len) return error.TextTooLong;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), text.len, color) orelse return error.SurfaceFailed;
    defer c.SDL_DestroySurface(surface);
    const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(tex, &w, &h);
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    return TextTex{ .tex = tex, .w = @intFromFloat(w), .h = @intFromFloat(h) };
}

fn destroyEntryTextures(allocator: std.mem.Allocator, entries: []EntryTex) void {
    for (entries) |entry| {
        c.SDL_DestroyTexture(entry.hotkey.tex);
        c.SDL_DestroyTexture(entry.label.tex);
        allocator.free(entry.displayed_text);
    }
}

fn truncateTextRight(text: []const u8, font: *c.TTF_Font, max_width: c_int, buf: []u8) ![]const u8 {
    const ellipsis = "…";
    var text_w: c_int = 0;
    var text_h: c_int = 0;
    _ = c.TTF_GetStringSize(font, text.ptr, text.len, &text_w, &text_h);
    if (text_w <= max_width) {
        if (text.len >= buf.len) return error.TextTooLong;
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }

    var end: usize = text.len;
    while (end > 0) {
        while (end > 0 and (text[end - 1] & 0b1100_0000) == 0b1000_0000) {
            end -= 1;
        }
        if (end == 0) break;
        end -= 1;
        const candidate_len = end + ellipsis.len;
        if (candidate_len >= buf.len) continue;
        @memcpy(buf[0..end], text[0..end]);
        @memcpy(buf[end .. end + ellipsis.len], ellipsis);
        var test_w: c_int = 0;
        var test_h: c_int = 0;
        _ = c.TTF_GetStringSize(font, buf.ptr, candidate_len, &test_w, &test_h);
        if (test_w <= max_width) return buf[0..candidate_len];
    }
    if (ellipsis.len < buf.len) {
        @memcpy(buf[0..ellipsis.len], ellipsis);
        return buf[0..ellipsis.len];
    }
    return text[0..@min(text.len, buf.len)];
}

test "PR id glyph scales to fit the pill" {
    const fitted = fitPrGlyphSize(40, 1, .{ .width = 50, .height = 25 });
    try std.testing.expectEqual(@as(f32, 32), fitted.width);
    try std.testing.expectEqual(@as(f32, 16), fitted.height);

    const short = fitPrGlyphSize(40, 1, .{ .width = 24, .height = 12 });
    try std.testing.expectEqual(@as(f32, 24), short.width);
    try std.testing.expectEqual(@as(f32, 12), short.height);
}
