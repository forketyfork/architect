//! Emoji-aware single-line text rendering for UI overlays.
//!
//! Apple Color Emoji is a bitmap font with one fixed 160 px strike and no
//! scalable outlines (`TTF_FontIsScalable` is false; `TTF_SetFontSize` reports
//! success but changes nothing). Because it is attached to the UI fonts with
//! `TTF_AddFallbackFont`, a single emoji in a string makes SDL_ttf return a
//! ~160 px tall surface — the glyph towers over the 17 px text around it.
//!
//! The terminal already solves this per glyph by scaling each rendered glyph
//! into its cell (`font.zig`). UI text has no cell grid, so this module does
//! the equivalent: split a line into emoji and non-emoji runs, render each
//! with the font that owns it, scale the emoji runs down to the line height,
//! and compose the runs into one surface.

const std = @import("std");
const c = @import("../c.zig");
const geom = @import("../geom.zig");

const log = std.log.scoped(.text_render);

pub const TextTex = struct {
    tex: *c.SDL_Texture,
    w: c_int,
    h: c_int,
};

/// The fonts needed to draw one line. `emoji` is the non-scalable color-emoji
/// fallback; leave it null for static labels that can never contain emoji.
pub const LineFonts = struct {
    text: *c.TTF_Font,
    emoji: ?*c.TTF_Font = null,
};

/// Codepoints from the pictographic planes, which the emoji font owns. Symbols
/// below this (arrows, geometric shapes, U+26xx) come from the scalable symbol
/// fallbacks and already render at the right size.
fn isEmojiBase(cp: u21) bool {
    return cp >= 0x1F000;
}

/// Joiners and modifiers that continue an emoji run rather than starting a new
/// one, so ZWJ sequences and keycaps stay in a single run.
fn isEmojiJoiner(cp: u21) bool {
    return cp == 0x200D or // zero-width joiner
        cp == 0xFE0F or // emoji presentation selector
        cp == 0xFE0E or // text presentation selector
        cp == 0x20E3; // combining enclosing keycap
}

fn containsEmoji(text: []const u8) bool {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| {
        if (isEmojiBase(cp)) return true;
    }
    return false;
}

/// Byte range of a run plus which font renders it.
const Run = struct {
    start: usize,
    end: usize,
    emoji: bool,
};

/// Splits `text` into alternating emoji / non-emoji runs. Returns the number of
/// runs written into `out`; a line with more runs than fit is rendered up to
/// that point, which only happens for pathological input.
fn splitRuns(text: []const u8, out: []Run) usize {
    var count: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var run_start: usize = 0;
    var run_emoji = false;
    var started = false;

    while (true) {
        const offset = it.i;
        const cp = it.nextCodepoint() orelse break;
        // A joiner keeps whatever run it lands in, so sequences stay together.
        const is_emoji = if (isEmojiJoiner(cp)) run_emoji else isEmojiBase(cp);

        if (!started) {
            run_start = offset;
            run_emoji = is_emoji;
            started = true;
            continue;
        }
        if (is_emoji == run_emoji) continue;

        if (count == out.len) return count;
        out[count] = .{ .start = run_start, .end = offset, .emoji = run_emoji };
        count += 1;
        run_start = offset;
        run_emoji = is_emoji;
    }

    if (started and count < out.len) {
        out[count] = .{ .start = run_start, .end = text.len, .emoji = run_emoji };
        count += 1;
    }
    return count;
}

fn renderRunSurface(font: *c.TTF_Font, text: []const u8, color: c.SDL_Color) ?*c.SDL_Surface {
    if (text.len == 0) return null;
    return c.TTF_RenderText_Blended(font, text.ptr, text.len, color);
}

/// Renders one line of text, scaling emoji down to the surrounding line height.
/// Falls back to a single plain render when the line has no emoji or no emoji
/// font is configured, which is the common case.
pub fn makeTextTexture(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    fonts: LineFonts,
    text: []const u8,
    color: c.SDL_Color,
) !TextTex {
    if (text.len == 0) return error.EmptyText;

    const emoji_font = fonts.emoji;
    if (emoji_font == null or !containsEmoji(text)) {
        const surface = renderRunSurface(fonts.text, text, color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(surface);
        return textureFromSurface(renderer, surface);
    }

    const composed = try composeRuns(allocator, fonts.text, emoji_font.?, text, color);
    defer c.SDL_DestroySurface(composed);
    return textureFromSurface(renderer, composed);
}

/// Upper bound on runs per line; beyond this the tail renders without emoji
/// splitting rather than allocating for a pathological string.
const max_runs = 64;

fn composeRuns(
    allocator: std.mem.Allocator,
    text_font: *c.TTF_Font,
    emoji_font: *c.TTF_Font,
    text: []const u8,
    color: c.SDL_Color,
) !*c.SDL_Surface {
    var runs: [max_runs]Run = undefined;
    const run_count = splitRuns(text, &runs);
    if (run_count == 0) return error.SurfaceFailed;

    const line_h = c.TTF_GetFontHeight(text_font);
    if (line_h <= 0) return error.SurfaceFailed;

    const surfaces = try allocator.alloc(?*c.SDL_Surface, run_count);
    defer {
        for (surfaces) |maybe| {
            if (maybe) |s| c.SDL_DestroySurface(s);
        }
        allocator.free(surfaces);
    }

    // Emoji keep their own colors, so they are rendered opaque white and never
    // tinted with the text color.
    const emoji_color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

    var total_w: c_int = 0;
    for (runs[0..run_count], 0..) |run, i| {
        const slice = text[run.start..run.end];
        const font = if (run.emoji) emoji_font else text_font;
        const run_color = if (run.emoji) emoji_color else color;
        surfaces[i] = renderRunSurface(font, slice, run_color);
        const surface = surfaces[i] orelse continue;
        total_w += if (run.emoji) scaledEmojiWidth(surface, line_h) else surface.*.w;
    }
    if (total_w <= 0) return error.SurfaceFailed;

    const dest = c.SDL_CreateSurface(total_w, line_h, c.SDL_PIXELFORMAT_RGBA32) orelse {
        log.warn("SDL_CreateSurface failed: {s}", .{c.SDL_GetError()});
        return error.SurfaceFailed;
    };
    errdefer c.SDL_DestroySurface(dest);
    _ = c.SDL_SetSurfaceBlendMode(dest, c.SDL_BLENDMODE_BLEND);

    var x: c_int = 0;
    for (runs[0..run_count], 0..) |run, i| {
        const surface = surfaces[i] orelse continue;
        if (run.emoji) {
            const w = scaledEmojiWidth(surface, line_h);
            var dst_rect = c.SDL_Rect{ .x = x, .y = 0, .w = w, .h = line_h };
            if (!c.SDL_BlitSurfaceScaled(surface, null, dest, &dst_rect, c.SDL_SCALEMODE_LINEAR)) {
                log.warn("SDL_BlitSurfaceScaled failed: {s}", .{c.SDL_GetError()});
            }
            x += w;
        } else {
            // Text runs already come back at the line height; top-align them so
            // every run shares the same baseline.
            var dst_rect = c.SDL_Rect{ .x = x, .y = 0, .w = surface.*.w, .h = surface.*.h };
            if (!c.SDL_BlitSurface(surface, null, dest, &dst_rect)) {
                log.warn("SDL_BlitSurface failed: {s}", .{c.SDL_GetError()});
            }
            x += surface.*.w;
        }
    }

    return dest;
}

/// Width an emoji surface gets when scaled to the line height, keeping aspect.
fn scaledEmojiWidth(surface: *c.SDL_Surface, line_h: c_int) c_int {
    if (surface.*.h <= 0) return 0;
    return @max(1, @divTrunc(surface.*.w * line_h, surface.*.h));
}

/// Fade painted over the leading edge of an overflowing line, so text dissolves
/// into the field instead of being cut mid-glyph. `color`/`alpha` should match
/// the field's own fill so the ramp lands exactly on the background.
pub const EdgeFade = struct {
    color: c.SDL_Color,
    alpha: u8,
    width: c_int,
};

/// Draws `tex` inside `region`, tail-aligned when it is too wide so the end of
/// the text — where the caret sits — stays visible, with `fade` painted over
/// the leading edge. Returns the x where the drawn text ends.
pub fn drawClippedTail(
    renderer: *c.SDL_Renderer,
    tex: TextTex,
    region: geom.Rect,
    fade: EdgeFade,
) c_int {
    const height = @min(tex.h, region.h);
    if (region.w <= 0) return region.x;

    if (tex.w <= region.w) {
        _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(region.x),
            .y = @floatFromInt(region.y),
            .w = @floatFromInt(tex.w),
            .h = @floatFromInt(height),
        });
        return region.x + tex.w;
    }

    const src = c.SDL_FRect{
        .x = @floatFromInt(tex.w - region.w),
        .y = 0,
        .w = @floatFromInt(region.w),
        .h = @floatFromInt(tex.h),
    };
    _ = c.SDL_RenderTexture(renderer, tex.tex, &src, &c.SDL_FRect{
        .x = @floatFromInt(region.x),
        .y = @floatFromInt(region.y),
        .w = @floatFromInt(region.w),
        .h = @floatFromInt(height),
    });
    drawLeadingFade(renderer, region, height, fade);
    return region.x + region.w;
}

fn drawLeadingFade(renderer: *c.SDL_Renderer, region: geom.Rect, height: c_int, fade: EdgeFade) void {
    const width = @min(fade.width, region.w);
    if (width <= 0 or fade.alpha == 0) return;

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    var i: c_int = 0;
    while (i < width) : (i += 1) {
        // Opaque at the outer edge, fully transparent where the text is legible.
        const remaining: i32 = width - i;
        const alpha: u8 = @intCast(@divTrunc(@as(i32, fade.alpha) * remaining, width));
        _ = c.SDL_SetRenderDrawColor(renderer, fade.color.r, fade.color.g, fade.color.b, alpha);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(region.x + i),
            .y = @floatFromInt(region.y),
            .w = 1,
            .h = @floatFromInt(height),
        });
    }
}

fn textureFromSurface(renderer: *c.SDL_Renderer, surface: *c.SDL_Surface) !TextTex {
    const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(texture, &w, &h);
    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
    return .{ .tex = texture, .w = @intFromFloat(w), .h = @intFromFloat(h) };
}

// --- Tests ---

test "containsEmoji only fires for the pictographic planes" {
    try std.testing.expect(!containsEmoji("hello"));
    try std.testing.expect(!containsEmoji("arrows → and ☀ come from scalable fallbacks"));
    try std.testing.expect(containsEmoji("hi 🙂"));
    try std.testing.expect(containsEmoji("🚀"));
}

test "splitRuns separates emoji from text" {
    var runs: [max_runs]Run = undefined;
    const text = "hi 🙂 there";
    const n = splitRuns(text, &runs);
    try std.testing.expectEqual(3, n);
    try std.testing.expectEqualStrings("hi ", text[runs[0].start..runs[0].end]);
    try std.testing.expect(!runs[0].emoji);
    try std.testing.expectEqualStrings("🙂", text[runs[1].start..runs[1].end]);
    try std.testing.expect(runs[1].emoji);
    try std.testing.expectEqualStrings(" there", text[runs[2].start..runs[2].end]);
    try std.testing.expect(!runs[2].emoji);
}

test "splitRuns keeps a plain line as one run" {
    var runs: [max_runs]Run = undefined;
    const text = "no emoji here";
    try std.testing.expectEqual(1, splitRuns(text, &runs));
    try std.testing.expect(!runs[0].emoji);
    try std.testing.expectEqualStrings(text, text[runs[0].start..runs[0].end]);
}

test "splitRuns keeps ZWJ sequences and keycaps in one run" {
    var runs: [max_runs]Run = undefined;
    // Family: man + ZWJ + woman + ZWJ + girl.
    const family = "👨\u{200D}👩\u{200D}👧";
    try std.testing.expectEqual(1, splitRuns(family, &runs));
    try std.testing.expect(runs[0].emoji);

    // Skin tone modifiers live above U+1F000 and need no special casing.
    const wave = "👋🏽";
    try std.testing.expectEqual(1, splitRuns(wave, &runs));
    try std.testing.expect(runs[0].emoji);
}

test "splitRuns handles emoji at both ends" {
    var runs: [max_runs]Run = undefined;
    const text = "🙂ok🚀";
    const n = splitRuns(text, &runs);
    try std.testing.expectEqual(3, n);
    try std.testing.expect(runs[0].emoji);
    try std.testing.expect(!runs[1].emoji);
    try std.testing.expect(runs[2].emoji);
}

test "splitRuns on empty text yields nothing" {
    var runs: [max_runs]Run = undefined;
    try std.testing.expectEqual(0, splitRuns("", &runs));
}

test "composed emoji lines stay at the text line height" {
    // The bug this guards against: Apple Color Emoji has a single 160 px
    // bitmap strike, so letting SDL_ttf resolve it through the attached
    // fallback returns a ~160 px tall surface for a 14 pt line.
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;

    // Opened directly rather than through `font_paths`, whose family probing
    // logs at error level for absent weights and would fail the test runner.
    if (!c.TTF_Init()) return error.SkipZigTest;
    defer c.TTF_Quit();

    const text_font = c.TTF_OpenFont("/System/Library/Fonts/SFNS.ttf", 14) orelse
        c.TTF_OpenFont("/System/Library/Fonts/Helvetica.ttc", 14) orelse
        return error.SkipZigTest;
    defer c.TTF_CloseFont(text_font);
    const emoji_font = c.TTF_OpenFont("/System/Library/Fonts/Apple Color Emoji.ttc", 14) orelse return error.SkipZigTest;
    defer c.TTF_CloseFont(emoji_font);

    const line_h = c.TTF_GetFontHeight(text_font);
    try std.testing.expect(line_h > 0);

    // Without the split, this same string comes back ~160 px tall.
    const composed = try composeRuns(std.testing.allocator, text_font, emoji_font, "hi 🙂 there", .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    defer c.SDL_DestroySurface(composed);
    try std.testing.expectEqual(line_h, composed.*.h);

    // The emoji occupies roughly one line-height of width, not 160 px.
    const plain = c.TTF_RenderText_Blended(text_font, "hi  there", 9, .{ .r = 255, .g = 255, .b = 255, .a = 255 }) orelse return error.SkipZigTest;
    defer c.SDL_DestroySurface(plain);
    try std.testing.expect(composed.*.w < plain.*.w + line_h * 2);
}

test "scaledEmojiWidth preserves the aspect ratio" {
    var square = c.SDL_Surface{ .flags = 0, .format = 0, .w = 160, .h = 160, .pitch = 0, .pixels = null, .refcount = 0, .reserved = null };
    try std.testing.expectEqual(@as(c_int, 17), scaledEmojiWidth(&square, 17));

    var wide = c.SDL_Surface{ .flags = 0, .format = 0, .w = 320, .h = 160, .pitch = 0, .pixels = null, .refcount = 0, .reserved = null };
    try std.testing.expectEqual(@as(c_int, 34), scaledEmojiWidth(&wide, 17));
}
