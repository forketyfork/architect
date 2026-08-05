const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const dpi = @import("../../dpi.zig");
const font_cache_mod = @import("../../font_cache.zig");
const text_edit = @import("../text_edit.zig");
const text_render = @import("../text_render.zig");

const FontCache = font_cache_mod.FontCache;

const log = std.log.scoped(.search_utils);

/// Unscaled caret width, matching the worktree name field.
const caret_width: c_int = 2;

/// Alpha the search bar fills itself with; the overflow fade ramps to it so the
/// text dissolves into the bar rather than into a differently-shaded strip.
const search_bar_fill_alpha: u8 = 230;

pub const SearchMatch = struct {
    line_index: usize,
    start: usize,
    len: usize,
};

pub const TextTex = text_render.TextTex;

pub fn findCaseInsensitive(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or haystack.len < needle.len or from >= haystack.len) return null;

    var pos = from;
    while (pos + needle.len <= haystack.len) : (pos += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[pos .. pos + needle.len], needle)) {
            return pos;
        }
    }
    return null;
}

/// Rebuild search matches across an array of plain text lines.
/// `plain_texts` is a slice of plain text strings indexed by line.
/// `skip` is an optional function that returns true for line indices to skip.
pub fn rebuildMatches(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(SearchMatch),
    plain_texts: []const []const u8,
    query_raw: []const u8,
    selected_match: *?usize,
    skip: ?*const fn (usize) bool,
) void {
    matches.clearRetainingCapacity();

    const query = std.mem.trim(u8, query_raw, " \t");
    if (query.len == 0) {
        selected_match.* = null;
        return;
    }

    for (plain_texts, 0..) |text, line_idx| {
        if (skip) |skip_fn| {
            if (skip_fn(line_idx)) continue;
        }

        var pos: usize = 0;
        while (findCaseInsensitive(text, query, pos)) |found| {
            matches.append(allocator, .{
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

    if (matches.items.len == 0) {
        selected_match.* = null;
        return;
    }

    if (selected_match.*) |idx| {
        if (idx >= matches.items.len) {
            selected_match.* = 0;
        }
    } else {
        selected_match.* = 0;
    }
}

pub fn renderSearchBar(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    host: *const types.UiHost,
    rect: geom.Rect,
    font_cache: *FontCache,
    input: *const text_edit.TextInput,
    matches_count: usize,
    selected_match: ?usize,
) !void {
    const search_radius = dpi.scale(6, host.ui_scale);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, host.theme.selection.r, host.theme.selection.g, host.theme.selection.b, search_bar_fill_alpha);
    primitives.fillRoundedRect(renderer, rect, search_radius);

    _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 220);
    primitives.drawRoundedBorder(renderer, rect, search_radius);

    const fonts = try font_cache.get(dpi.scale(14, host.ui_scale));
    const pad = dpi.scale(8, host.ui_scale);
    const query = input.text();
    var count_buf: [32]u8 = undefined;
    const count_text = if (matches_count == 0)
        "0/0"
    else blk: {
        const selected = (selected_match orelse 0) + 1;
        break :blk try std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ selected, matches_count });
    };

    const count_tex = try makeTextTexture(allocator, renderer, fonts.regular, count_text, host.theme.accent);
    defer c.SDL_DestroyTexture(count_tex.tex);

    const prefix_tex = try makeTextTexture(allocator, renderer, fonts.regular, "Search: ", host.theme.foreground);
    defer c.SDL_DestroyTexture(prefix_tex.tex);
    const prefix_x = rect.x + pad;
    const text_y = rect.y + @divFloor(rect.h - prefix_tex.h, 2);
    _ = c.SDL_RenderTexture(renderer, prefix_tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(prefix_x),
        .y = @floatFromInt(text_y),
        .w = @floatFromInt(prefix_tex.w),
        .h = @floatFromInt(prefix_tex.h),
    });

    // The query lives between the prefix and the match count and is clipped to
    // that box: a pasted line must not spill past the bar.
    const query_region = geom.Rect{
        .x = prefix_x + prefix_tex.w,
        .y = text_y,
        .w = (rect.x + rect.w - pad - count_tex.w - dpi.scale(8, host.ui_scale)) - (prefix_x + prefix_tex.w),
        .h = prefix_tex.h,
    };

    var query_end = query_region.x;
    if (query.len > 0 and query_region.w > 0) {
        const query_tex = try makeTextTextureEmoji(
            allocator,
            renderer,
            .{ .text = fonts.regular, .emoji = fonts.emoji },
            query,
            host.theme.foreground,
        );
        defer c.SDL_DestroyTexture(query_tex.tex);

        // Behind the glyphs, so the highlight never hides the text.
        if (input.select_all) {
            const sel = host.theme.accent;
            _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 110);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                .x = @floatFromInt(query_region.x),
                .y = @floatFromInt(query_region.y),
                .w = @floatFromInt(@min(query_tex.w, query_region.w)),
                .h = @floatFromInt(query_region.h),
            });
        }

        query_end = text_render.drawClippedTail(renderer, query_tex, query_region, .{
            .color = host.theme.selection,
            .alpha = search_bar_fill_alpha,
            .width = dpi.scale(20, host.ui_scale),
        });
    }

    if (input.caretVisible(host.now_ms)) {
        const fg = host.theme.foreground;
        const caret_x = @min(query_end + dpi.scale(1, host.ui_scale), query_region.x + query_region.w);
        _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, 255);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(caret_x),
            .y = @floatFromInt(query_region.y),
            .w = @floatFromInt(dpi.scale(caret_width, host.ui_scale)),
            .h = @floatFromInt(query_region.h),
        });
    }

    _ = c.SDL_RenderTexture(renderer, count_tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(rect.x + rect.w - count_tex.w - pad),
        .y = @floatFromInt(rect.y + @divFloor(rect.h - count_tex.h, 2)),
        .w = @floatFromInt(count_tex.w),
        .h = @floatFromInt(count_tex.h),
    });
}

/// Plain single-font text. Use `makeTextTextureEmoji` for anything that can
/// contain user or document text: an emoji rendered through the attached
/// bitmap fallback would blow the line up to the strike's 160 px.
pub fn makeTextTexture(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    text: []const u8,
    color: c.SDL_Color,
) !TextTex {
    return text_render.makeTextTexture(allocator, renderer, .{ .text = font }, text, color);
}

/// Emoji-aware variant: emoji runs are rendered with `fonts.emoji` and scaled
/// down to the line height. See `ui/text_render.zig`.
pub fn makeTextTextureEmoji(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    fonts: text_render.LineFonts,
    text: []const u8,
    color: c.SDL_Color,
) !TextTex {
    return text_render.makeTextTexture(allocator, renderer, fonts, text, color);
}

// --- Tests ---

test "findCaseInsensitive — empty needle" {
    try std.testing.expectEqual(null, findCaseInsensitive("hello", "", 0));
}

test "findCaseInsensitive — no match" {
    try std.testing.expectEqual(null, findCaseInsensitive("hello world", "xyz", 0));
}

test "findCaseInsensitive — exact match" {
    try std.testing.expectEqual(0, findCaseInsensitive("hello", "hello", 0));
}

test "findCaseInsensitive — case insensitive" {
    try std.testing.expectEqual(0, findCaseInsensitive("Hello World", "hello", 0));
    try std.testing.expectEqual(6, findCaseInsensitive("Hello World", "WORLD", 0));
}

test "findCaseInsensitive — with offset" {
    try std.testing.expectEqual(6, findCaseInsensitive("hello hello", "hello", 1));
}

test "findCaseInsensitive — match at end" {
    try std.testing.expectEqual(6, findCaseInsensitive("abcdefg", "g", 0));
}

test "findCaseInsensitive — needle longer than haystack" {
    try std.testing.expectEqual(null, findCaseInsensitive("hi", "hello", 0));
}

test "findCaseInsensitive — offset past haystack" {
    try std.testing.expectEqual(null, findCaseInsensitive("hello", "lo", 100));
}

test "findCaseInsensitive — multiple occurrences" {
    const haystack = "abcABCabc";
    try std.testing.expectEqual(0, findCaseInsensitive(haystack, "abc", 0));
    try std.testing.expectEqual(3, findCaseInsensitive(haystack, "abc", 1));
    try std.testing.expectEqual(6, findCaseInsensitive(haystack, "abc", 4));
}

test "rebuildMatches — empty query clears matches" {
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var selected: ?usize = 5;
    const texts: []const []const u8 = &.{ "hello", "world" };

    rebuildMatches(std.testing.allocator, &matches, texts, "  ", &selected, null);
    try std.testing.expectEqual(0, matches.items.len);
    try std.testing.expectEqual(null, selected);
}

test "rebuildMatches — finds matches across lines" {
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var selected: ?usize = null;
    const texts: []const []const u8 = &.{ "Hello World", "another hello here" };

    rebuildMatches(std.testing.allocator, &matches, texts, "hello", &selected, null);
    try std.testing.expectEqual(2, matches.items.len);
    try std.testing.expectEqual(0, matches.items[0].line_index);
    try std.testing.expectEqual(0, matches.items[0].start);
    try std.testing.expectEqual(1, matches.items[1].line_index);
    try std.testing.expectEqual(8, matches.items[1].start);
    try std.testing.expectEqual(0, selected);
}

test "rebuildMatches — skip function" {
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var selected: ?usize = null;
    const texts: []const []const u8 = &.{ "hello", "hello", "hello" };

    const skip = struct {
        fn f(idx: usize) bool {
            return idx == 1;
        }
    }.f;

    rebuildMatches(std.testing.allocator, &matches, texts, "hello", &selected, &skip);
    try std.testing.expectEqual(2, matches.items.len);
    try std.testing.expectEqual(0, matches.items[0].line_index);
    try std.testing.expectEqual(2, matches.items[1].line_index);
}

test "rebuildMatches — selected_match clamped on rebuild" {
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var selected: ?usize = 99;
    const texts: []const []const u8 = &.{"hello"};

    rebuildMatches(std.testing.allocator, &matches, texts, "hello", &selected, null);
    try std.testing.expectEqual(0, selected);
}

test "rebuildMatches — no matches sets selected to null" {
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var selected: ?usize = 0;
    const texts: []const []const u8 = &.{"hello"};

    rebuildMatches(std.testing.allocator, &matches, texts, "xyz", &selected, null);
    try std.testing.expectEqual(0, matches.items.len);
    try std.testing.expectEqual(null, selected);
}

test "rebuildMatches — multiple matches in same line" {
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var selected: ?usize = null;
    const texts: []const []const u8 = &.{"abcabc"};

    rebuildMatches(std.testing.allocator, &matches, texts, "abc", &selected, null);
    try std.testing.expectEqual(2, matches.items.len);
    try std.testing.expectEqual(0, matches.items[0].start);
    try std.testing.expectEqual(3, matches.items[1].start);
}
