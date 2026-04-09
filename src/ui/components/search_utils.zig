const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const dpi = @import("../../dpi.zig");
const font_cache_mod = @import("../../font_cache.zig");

const FontCache = font_cache_mod.FontCache;

const log = std.log.scoped(.search_utils);

pub const SearchMatch = struct {
    line_index: usize,
    start: usize,
    len: usize,
};

pub const TextTex = struct {
    tex: *c.SDL_Texture,
    w: c_int,
    h: c_int,
};

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
    query: []const u8,
    matches_count: usize,
    selected_match: ?usize,
) !void {
    const search_radius = dpi.scale(6, host.ui_scale);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, host.theme.selection.r, host.theme.selection.g, host.theme.selection.b, 230);
    primitives.fillRoundedRect(renderer, rect, search_radius);

    _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 220);
    primitives.drawRoundedBorder(renderer, rect, search_radius);

    const fonts = try font_cache.get(dpi.scale(14, host.ui_scale));
    const prefix = "Search: ";
    var count_buf: [32]u8 = undefined;
    const count_text = if (matches_count == 0)
        "0/0"
    else blk: {
        const selected = (selected_match orelse 0) + 1;
        break :blk try std.fmt.bufPrint(&count_buf, "{d}/{d}", .{ selected, matches_count });
    };

    var text_buf = std.ArrayList(u8).empty;
    defer text_buf.deinit(allocator);
    try text_buf.appendSlice(allocator, prefix);
    try text_buf.appendSlice(allocator, query);

    const query_tex = try makeTextTexture(allocator, renderer, fonts.regular, text_buf.items, host.theme.foreground);
    defer c.SDL_DestroyTexture(query_tex.tex);
    _ = c.SDL_RenderTexture(renderer, query_tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(rect.x + dpi.scale(8, host.ui_scale)),
        .y = @floatFromInt(rect.y + @divFloor(rect.h - query_tex.h, 2)),
        .w = @floatFromInt(query_tex.w),
        .h = @floatFromInt(query_tex.h),
    });

    const count_tex = try makeTextTexture(allocator, renderer, fonts.regular, count_text, host.theme.accent);
    defer c.SDL_DestroyTexture(count_tex.tex);
    _ = c.SDL_RenderTexture(renderer, count_tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(rect.x + rect.w - count_tex.w - dpi.scale(8, host.ui_scale)),
        .y = @floatFromInt(rect.y + @divFloor(rect.h - count_tex.h, 2)),
        .w = @floatFromInt(count_tex.w),
        .h = @floatFromInt(count_tex.h),
    });
}

pub fn makeTextTexture(
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
