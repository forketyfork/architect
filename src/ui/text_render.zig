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
//! the equivalent: split a line into emoji and non-emoji runs, render each with
//! the font that owns it, scale the emoji runs by the ascent ratio so they land
//! on the text baseline, and compose the runs into one surface.

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

/// Renders one line of text, scaling emoji to sit on the surrounding baseline.
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

    const text_ascent = c.TTF_GetFontAscent(text_font);
    const emoji_ascent = c.TTF_GetFontAscent(emoji_font);

    const placements = try allocator.alloc(EmojiPlacement, run_count);
    defer allocator.free(placements);

    var total_w: c_int = 0;
    for (runs[0..run_count], 0..) |run, i| {
        const slice = text[run.start..run.end];
        const font = if (run.emoji) emoji_font else text_font;
        const run_color = if (run.emoji) emoji_color else color;
        surfaces[i] = renderRunSurface(font, slice, run_color);
        placements[i] = .{ .w = 0, .h = 0, .y = 0 };
        const surface = surfaces[i] orelse continue;
        if (run.emoji) {
            placements[i] = placeEmoji(surface.*.w, surface.*.h, emoji_ascent, text_ascent, line_h);
            total_w += placements[i].w;
        } else {
            total_w += surface.*.w;
        }
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
            const place = placements[i];
            var dst_rect = c.SDL_Rect{ .x = x, .y = place.y, .w = place.w, .h = place.h };
            if (!c.SDL_BlitSurfaceScaled(surface, null, dest, &dst_rect, c.SDL_SCALEMODE_LINEAR)) {
                log.warn("SDL_BlitSurfaceScaled failed: {s}", .{c.SDL_GetError()});
            }
            x += place.w;
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

/// Where a scaled emoji surface goes inside the composed line box.
const EmojiPlacement = struct {
    w: c_int,
    h: c_int,
    /// Offset from the top of the line box.
    y: c_int,
};

/// Sizes and positions an emoji surface so it sits on the text baseline.
///
/// The surface SDL_ttf returns is the emoji font's whole line box (160x210 for
/// Apple Color Emoji at any requested size), with the 160x160 glyph occupying
/// the ascent region and empty descent padding below. Scaling that box to the
/// text line height lands the emoji baseline above the text's, which reads as
/// the emoji floating high. Scaling by the ascent ratio instead makes the glyph
/// exactly the text's ascent tall and puts the two baselines on the same line;
/// the empty descent padding that then hangs past the line box is clipped by
/// the blit.
fn placeEmoji(
    surface_w: c_int,
    surface_h: c_int,
    emoji_ascent: c_int,
    text_ascent: c_int,
    line_h: c_int,
) EmojiPlacement {
    if (surface_w <= 0 or surface_h <= 0) return .{ .w = 0, .h = 0, .y = 0 };

    // Without usable metrics, fall back to filling the line box.
    if (emoji_ascent <= 0 or text_ascent <= 0) {
        return .{ .w = @max(1, @divTrunc(surface_w * line_h, surface_h)), .h = line_h, .y = 0 };
    }

    const w = @max(1, divRound(surface_w * text_ascent, emoji_ascent));
    const h = @max(1, divRound(surface_h * text_ascent, emoji_ascent));
    // Rounded, not truncated: at these sizes one pixel of bias is visible as
    // the emoji sitting off the baseline.
    const scaled_baseline = divRound(h * emoji_ascent, surface_h);
    return .{ .w = w, .h = h, .y = text_ascent - scaled_baseline };
}

/// Nearest-integer division for the positive pixel math above.
fn divRound(a: c_int, b: c_int) c_int {
    if (b == 0) return 0;
    return @divTrunc(a + @divTrunc(b, 2), b);
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

test "placeEmoji lands the emoji baseline on the text baseline" {
    // Real metrics: Apple Color Emoji renders a 160x210 box (160x160 glyph over
    // 50 px of descent padding, ascent 160) next to SFNS 14 pt (height 17,
    // ascent 14).
    const place = placeEmoji(160, 210, 160, 14, 17);

    // The glyph becomes exactly the text ascent tall, so it sits on the
    // baseline rather than floating above it.
    try std.testing.expectEqual(@as(c_int, 14), place.w);
    try std.testing.expectEqual(@as(c_int, 0), place.y);

    const scaled_baseline = place.y + divRound(place.h * 160, 210);
    try std.testing.expectEqual(@as(c_int, 14), scaled_baseline);

    // Filling the line box instead — the previous behavior — put the baseline
    // a pixel high, which is what made the emoji look lifted.
    const naive_baseline = divRound(17 * 160, 210);
    try std.testing.expect(naive_baseline < scaled_baseline);
}

test "placeEmoji keeps the aspect ratio for multi-emoji runs" {
    const one = placeEmoji(160, 210, 160, 14, 17);
    const two = placeEmoji(320, 210, 160, 14, 17);
    try std.testing.expectEqual(one.w * 2, two.w);
    try std.testing.expectEqual(one.h, two.h);
    try std.testing.expectEqual(one.y, two.y);
}

test "placeEmoji falls back to the line box without usable metrics" {
    const place = placeEmoji(160, 160, 0, 14, 17);
    try std.testing.expectEqual(@as(c_int, 17), place.h);
    try std.testing.expectEqual(@as(c_int, 17), place.w);
    try std.testing.expectEqual(@as(c_int, 0), place.y);
}

test "placeEmoji tolerates an empty surface" {
    const place = placeEmoji(0, 0, 160, 14, 17);
    try std.testing.expectEqual(@as(c_int, 0), place.w);
    try std.testing.expectEqual(@as(c_int, 0), place.h);
}
