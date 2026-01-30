// SDL_ttf-backed font helper with glyph caching so terminals can render text
// efficiently at varying scales.
const std = @import("std");
const c = @import("c.zig");
const metrics_mod = @import("metrics.zig");

const log = std.log.scoped(.font);

pub const Fallback = enum {
    primary,
    symbol_embedded,
    symbol,
    symbol_secondary,
    emoji,
};

pub const Variant = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,
};

pub const Faces = struct {
    regular: *c.TTF_Font,
    bold: ?*c.TTF_Font = null,
    italic: ?*c.TTF_Font = null,
    bold_italic: ?*c.TTF_Font = null,
    symbol_embedded: ?*c.TTF_Font = null,
    symbol: ?*c.TTF_Font = null,
    symbol_secondary: ?*c.TTF_Font = null,
    emoji: ?*c.TTF_Font = null,
};

const GlyphKey = struct {
    hash: u64,
    color: u32,
    fallback: Fallback,
    variant: Variant,
    // Cluster length in codepoints. Using u16 provides generous headroom
    // (up to 65535) while the renderer currently caps runs at 512 codepoints.
    len: u16,
};

const white: c.SDL_Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

const FontMetrics = struct {
    ascent: f32,
    descent: f32,
    line_height: f32,
};

const GlyphMetrics = struct {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    advance: f32,
};

pub const Font = struct {
    font: *c.TTF_Font,
    bold_font: ?*c.TTF_Font,
    italic_font: ?*c.TTF_Font,
    bold_italic_font: ?*c.TTF_Font,
    symbol_fallback_embedded: ?*c.TTF_Font,
    symbol_fallback: ?*c.TTF_Font,
    symbol_fallback_secondary: ?*c.TTF_Font,
    emoji_fallback: ?*c.TTF_Font,
    primary_metrics: FontMetrics,
    emoji_metrics: ?FontMetrics,
    symbol_embedded_metrics: ?FontMetrics,
    symbol_metrics: ?FontMetrics,
    symbol_secondary_metrics: ?FontMetrics,
    renderer: *c.SDL_Renderer,
    glyph_cache: std.AutoHashMap(GlyphKey, CacheEntry),
    cache_tick: u64 = 0,
    allocator: std.mem.Allocator,
    cell_width: c_int,
    cell_height: c_int,
    owns_fonts: bool,
    metrics: ?*metrics_mod.Metrics = null,

    /// Limit cached glyph textures to avoid unbounded GPU/heap growth.
    const max_glyph_cache_entries: usize = 4096;

    /// Maximum byte length for a single glyph string to prevent abuse from
    /// malicious or malformed terminal output. 256 bytes allows for reasonable
    /// grapheme clusters including emoji sequences and combining characters
    /// while protecting against memory exhaustion attacks.
    const max_glyph_byte_length: usize = 256;

    /// Maximum codepoints in a single grapheme cluster before chunking.
    /// Chosen to balance rendering performance with memory usage. Values above
    /// this threshold are split into smaller segments to avoid creating
    /// excessively large textures (e.g., cursor trail effects with 120+ chars).
    const max_cluster_size: usize = 32;
    const unicode_replacement: u21 = 0xFFFD;

    fn fontMetrics(font: *c.TTF_Font) FontMetrics {
        const ascent = c.TTF_GetFontAscent(font);
        const descent = c.TTF_GetFontDescent(font);
        return .{
            .ascent = @floatFromInt(ascent),
            .descent = @floatFromInt(descent),
            .line_height = @floatFromInt(ascent - descent),
        };
    }

    fn glyphMetrics(font: *c.TTF_Font, codepoint: u21) ?GlyphMetrics {
        var min_x: c_int = 0;
        var max_x: c_int = 0;
        var min_y: c_int = 0;
        var max_y: c_int = 0;
        var advance: c_int = 0;
        if (!c.TTF_GetGlyphMetrics(font, @intCast(codepoint), &min_x, &max_x, &min_y, &max_y, &advance)) {
            return null;
        }
        return .{
            .min_x = @floatFromInt(min_x),
            .max_x = @floatFromInt(max_x),
            .min_y = @floatFromInt(min_y),
            .max_y = @floatFromInt(max_y),
            .advance = @floatFromInt(advance),
        };
    }

    fn shouldBaselineAlign(fallback: Fallback, cluster: []const u21) bool {
        if (fallback == .emoji) {
            return cluster.len == 1 and isSymbolLike(cluster[0]);
        }
        if (fallback != .primary) return true;
        if (cluster.len != 1) return false;
        return isSymbolLike(cluster[0]);
    }

    fn isSymbolLike(codepoint: u21) bool {
        return (codepoint >= 0x2190 and codepoint <= 0x21FF) or // Arrows
            (codepoint >= 0x2300 and codepoint <= 0x23FF) or // Misc Technical
            (codepoint >= 0x2460 and codepoint <= 0x24FF) or // Enclosed Alphanumerics
            (codepoint >= 0x25A0 and codepoint <= 0x25FF) or // Geometric Shapes
            (codepoint >= 0x2600 and codepoint <= 0x26FF) or // Misc Symbols
            (codepoint >= 0x2B00 and codepoint <= 0x2BFF); // Misc Symbols and Arrows
    }

    inline fn isValidScalar(cp: u21) bool {
        return cp <= 0x10_FFFF and !(cp >= 0xD800 and cp <= 0xDFFF);
    }

    fn sanitizeCluster(codepoints: []const u21, buf: *[max_cluster_size]u21) []const u21 {
        var needs_sanitize = false;
        for (codepoints) |cp| {
            if (!isValidScalar(cp)) {
                needs_sanitize = true;
                break;
            }
        }
        if (!needs_sanitize) return codepoints;

        for (codepoints, 0..) |cp, idx| {
            buf[idx] = if (isValidScalar(cp)) cp else unicode_replacement;
        }
        return buf[0..codepoints.len];
    }

    const CacheEntry = struct {
        texture: *c.SDL_Texture,
        seq: u64,
    };

    pub const InitError = error{
        FontLoadFailed,
    } || std.mem.Allocator.Error;

    pub fn initFromFaces(
        allocator: std.mem.Allocator,
        renderer: *c.SDL_Renderer,
        faces: Faces,
    ) InitError!Font {
        return initWithFaces(allocator, renderer, faces, false);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        renderer: *c.SDL_Renderer,
        font_path: [*:0]const u8,
        bold_font_path: ?[*:0]const u8,
        italic_font_path: ?[*:0]const u8,
        bold_italic_font_path: ?[*:0]const u8,
        symbol_fallback_path: ?[*:0]const u8,
        symbol_fallback_secondary_path: ?[*:0]const u8,
        emoji_fallback_path: ?[*:0]const u8,
        size: c_int,
    ) InitError!Font {
        const font = c.TTF_OpenFont(font_path, @floatFromInt(size)) orelse {
            log.err("TTF_OpenFont failed: {s}", .{c.SDL_GetError()});
            return error.FontLoadFailed;
        };
        errdefer c.TTF_CloseFont(font);

        _ = c.TTF_SetFontDirection(font, c.TTF_DIRECTION_LTR);

        const bold_font = if (bold_font_path) |path| blk: {
            const f = c.TTF_OpenFont(path, @floatFromInt(size));
            if (f == null) {
                log.warn("Failed to open bold font: {s}", .{c.SDL_GetError()});
            } else {
                _ = c.TTF_SetFontDirection(f.?, c.TTF_DIRECTION_LTR);
            }
            break :blk f;
        } else null;
        errdefer if (bold_font) |f| c.TTF_CloseFont(f);

        const italic_font = if (italic_font_path) |path| blk: {
            const f = c.TTF_OpenFont(path, @floatFromInt(size));
            if (f == null) {
                log.warn("Failed to open italic font: {s}", .{c.SDL_GetError()});
            } else {
                _ = c.TTF_SetFontDirection(f.?, c.TTF_DIRECTION_LTR);
            }
            break :blk f;
        } else null;
        errdefer if (italic_font) |f| c.TTF_CloseFont(f);

        const bold_italic_font = if (bold_italic_font_path) |path| blk: {
            const f = c.TTF_OpenFont(path, @floatFromInt(size));
            if (f == null) {
                log.warn("Failed to open bold-italic font: {s}", .{c.SDL_GetError()});
            } else {
                _ = c.TTF_SetFontDirection(f.?, c.TTF_DIRECTION_LTR);
            }
            break :blk f;
        } else null;
        errdefer if (bold_italic_font) |f| c.TTF_CloseFont(f);

        const symbol_fallback = if (symbol_fallback_path) |path| blk: {
            const f = c.TTF_OpenFont(path, @floatFromInt(size));
            if (f == null) {
                log.warn("Failed to open symbol fallback font: {s}", .{c.SDL_GetError()});
            } else {
                _ = c.TTF_SetFontDirection(f.?, c.TTF_DIRECTION_LTR);
            }
            break :blk f;
        } else null;
        errdefer if (symbol_fallback) |f| c.TTF_CloseFont(f);

        const symbol_fallback_secondary = if (symbol_fallback_secondary_path) |path| blk: {
            const f = c.TTF_OpenFont(path, @floatFromInt(size));
            if (f == null) {
                log.warn("Failed to open secondary symbol fallback font: {s}", .{c.SDL_GetError()});
            } else {
                _ = c.TTF_SetFontDirection(f.?, c.TTF_DIRECTION_LTR);
            }
            break :blk f;
        } else null;
        errdefer if (symbol_fallback_secondary) |f| c.TTF_CloseFont(f);

        const emoji_fallback = if (emoji_fallback_path) |path| blk: {
            const f = c.TTF_OpenFont(path, @floatFromInt(size));
            if (f == null) {
                log.warn("Failed to open emoji fallback font: {s}", .{c.SDL_GetError()});
            } else {
                _ = c.TTF_SetFontDirection(f.?, c.TTF_DIRECTION_LTR);
            }
            break :blk f;
        } else null;
        errdefer if (emoji_fallback) |f| c.TTF_CloseFont(f);

        var cell_width: c_int = 0;
        var cell_height: c_int = 0;
        if (!c.TTF_GetStringSize(font, "M", 1, &cell_width, &cell_height)) {
            log.err("TTF_GetStringSize failed: {s}", .{c.SDL_GetError()});
            return error.FontLoadFailed;
        }

        log.debug("Font cell dimensions: {d}x{d}", .{ cell_width, cell_height });

        return Font{
            .font = font,
            .bold_font = bold_font,
            .italic_font = italic_font,
            .bold_italic_font = bold_italic_font,
            .symbol_fallback_embedded = null,
            .symbol_fallback = symbol_fallback,
            .symbol_fallback_secondary = symbol_fallback_secondary,
            .emoji_fallback = emoji_fallback,
            .primary_metrics = fontMetrics(font),
            .emoji_metrics = if (emoji_fallback) |f| fontMetrics(f) else null,
            .symbol_embedded_metrics = null,
            .symbol_metrics = if (symbol_fallback) |f| fontMetrics(f) else null,
            .symbol_secondary_metrics = if (symbol_fallback_secondary) |f| fontMetrics(f) else null,
            .renderer = renderer,
            .glyph_cache = std.AutoHashMap(GlyphKey, CacheEntry).init(allocator),
            .allocator = allocator,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .owns_fonts = true,
        };
    }

    pub fn deinit(self: *Font) void {
        var it = self.glyph_cache.valueIterator();
        while (it.next()) |entry| {
            c.SDL_DestroyTexture(entry.texture);
        }
        self.glyph_cache.deinit();
        if (self.owns_fonts) {
            c.TTF_CloseFont(self.font);
            if (self.bold_font) |f| c.TTF_CloseFont(f);
            if (self.italic_font) |f| c.TTF_CloseFont(f);
            if (self.bold_italic_font) |f| c.TTF_CloseFont(f);
            if (self.symbol_fallback_embedded) |f| c.TTF_CloseFont(f);
            if (self.symbol_fallback) |f| c.TTF_CloseFont(f);
            if (self.symbol_fallback_secondary) |f| c.TTF_CloseFont(f);
            if (self.emoji_fallback) |f| c.TTF_CloseFont(f);
        }
    }

    fn initWithFaces(
        allocator: std.mem.Allocator,
        renderer: *c.SDL_Renderer,
        faces: Faces,
        owns_fonts: bool,
    ) InitError!Font {
        var cell_width: c_int = 0;
        var cell_height: c_int = 0;
        if (!c.TTF_GetStringSize(faces.regular, "M", 1, &cell_width, &cell_height)) {
            log.err("TTF_GetStringSize failed: {s}", .{c.SDL_GetError()});
            return error.FontLoadFailed;
        }

        log.debug("Font cell dimensions: {d}x{d}", .{ cell_width, cell_height });

        return Font{
            .font = faces.regular,
            .bold_font = faces.bold,
            .italic_font = faces.italic,
            .bold_italic_font = faces.bold_italic,
            .symbol_fallback_embedded = faces.symbol_embedded,
            .symbol_fallback = faces.symbol,
            .symbol_fallback_secondary = faces.symbol_secondary,
            .emoji_fallback = faces.emoji,
            .primary_metrics = fontMetrics(faces.regular),
            .emoji_metrics = if (faces.emoji) |f| fontMetrics(f) else null,
            .symbol_embedded_metrics = if (faces.symbol_embedded) |f| fontMetrics(f) else null,
            .symbol_metrics = if (faces.symbol) |f| fontMetrics(f) else null,
            .symbol_secondary_metrics = if (faces.symbol_secondary) |f| fontMetrics(f) else null,
            .renderer = renderer,
            .glyph_cache = std.AutoHashMap(GlyphKey, CacheEntry).init(allocator),
            .allocator = allocator,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .owns_fonts = owns_fonts,
        };
    }

    pub const RenderGlyphError = error{
        GlyphRenderFailed,
        TextureCreationFailed,
        InvalidCodepoint,
    } || std.mem.Allocator.Error;

    pub fn renderGlyph(self: *Font, codepoint: u21, x: c_int, y: c_int, target_width: c_int, target_height: c_int, fg_color: c.SDL_Color) RenderGlyphError!void {
        var buf = [_]u21{codepoint};
        return self.renderCluster(&buf, x, y, target_width, target_height, fg_color, .regular);
    }

    pub fn renderGlyphFill(self: *Font, codepoint: u21, x: c_int, y: c_int, target_width: c_int, target_height: c_int, fg_color: c.SDL_Color, variant: Variant) RenderGlyphError!void {
        var buf = [_]u21{codepoint};
        return self.renderClusterFill(&buf, x, y, target_width, target_height, fg_color, variant);
    }

    pub fn renderCluster(
        self: *Font,
        codepoints: []const u21,
        x: c_int,
        y: c_int,
        target_width: c_int,
        target_height: c_int,
        fg_color: c.SDL_Color,
        variant: Variant,
    ) RenderGlyphError!void {
        if (codepoints.len == 0) return;
        if (codepoints.len == 1 and codepoints[0] == 0) return;

        if (codepoints.len > max_cluster_size) {
            const chars_per_chunk = max_cluster_size;
            const cell_width = @max(1, @divTrunc(target_width, @as(c_int, @intCast(codepoints.len))));

            var offset: usize = 0;
            while (offset < codepoints.len) {
                const chunk_end = @min(offset + chars_per_chunk, codepoints.len);
                const chunk = codepoints[offset..chunk_end];
                const chunk_x = x + @as(c_int, @intCast(offset)) * cell_width;
                const chunk_width = @as(c_int, @intCast(chunk.len)) * cell_width;
                try self.renderCluster(chunk, chunk_x, y, chunk_width, target_height, fg_color, variant);
                offset = chunk_end;
            }
            return;
        }

        var sanitized_buf: [max_cluster_size]u21 = undefined;
        const cluster = sanitizeCluster(codepoints, &sanitized_buf);
        const effective_variant = self.effectiveVariant(variant, cluster);

        var total_bytes: usize = 0;
        for (cluster) |cp| {
            total_bytes += std.unicode.utf8CodepointSequenceLength(cp) catch return error.InvalidCodepoint;
        }

        var stack_buf: [512]u8 = undefined;
        const use_heap = total_bytes > stack_buf.len;
        const utf8_slice = if (use_heap)
            try self.allocator.alloc(u8, total_bytes)
        else
            stack_buf[0..total_bytes];
        defer if (use_heap) self.allocator.free(utf8_slice);

        var utf8_len: usize = 0;
        for (cluster) |cp| {
            var local: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(cp, &local) catch return error.InvalidCodepoint;
            @memcpy(utf8_slice[utf8_len .. utf8_len + encoded_len], local[0..encoded_len]);
            utf8_len += encoded_len;
        }

        const fallback_choice = self.classifyFallback(cluster);
        const texture = self.getGlyphTexture(utf8_slice[0..utf8_len], fg_color, fallback_choice, effective_variant) catch |err| {
            if (err == error.GlyphRenderFailed) return;
            return err;
        };

        var tex_w: f32 = 0;
        var tex_h: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &tex_w, &tex_h);
        if (tex_w == 0 or tex_h == 0) return;

        const avail_w: f32 = @floatFromInt(target_width);
        const avail_h: f32 = @floatFromInt(target_height);
        const scale = if (avail_w / tex_w < avail_h / tex_h)
            avail_w / tex_w
        else
            avail_h / tex_h;
        const dest_w = tex_w * scale;
        const dest_h = tex_h * scale;

        const base_x: f32 = @floatFromInt(x);
        const base_y: f32 = @floatFromInt(y);
        const metrics_font = switch (fallback_choice) {
            .symbol_embedded => self.symbol_fallback_embedded orelse self.symbol_fallback orelse self.font,
            .symbol => self.symbol_fallback orelse self.font,
            .symbol_secondary => self.symbol_fallback_secondary orelse self.symbol_fallback orelse self.font,
            .emoji => self.emoji_fallback orelse self.font,
            .primary => self.variantFont(effective_variant),
        };

        const align_baseline = shouldBaselineAlign(fallback_choice, cluster);
        const metrics = switch (fallback_choice) {
            .primary => self.primary_metrics,
            .symbol_embedded => self.symbol_embedded_metrics orelse self.primary_metrics,
            .symbol => self.symbol_metrics orelse self.primary_metrics,
            .symbol_secondary => self.symbol_secondary_metrics orelse self.primary_metrics,
            .emoji => self.emoji_metrics orelse self.primary_metrics,
        };

        var dest_x = base_x + (avail_w - dest_w) * 0.5;
        var dest_y = base_y + (avail_h - dest_h) * 0.5;

        if (align_baseline and cluster.len == 1) {
            if (glyphMetrics(metrics_font, cluster[0])) |glyph| {
                const glyph_w = glyph.max_x - glyph.min_x;
                const glyph_h = glyph.max_y - glyph.min_y;
                const glyph_center_x = glyph_w * 0.5;
                const glyph_center_y = (metrics.ascent - glyph.max_y) + glyph_h * 0.5;
                const surface_center_x = tex_w * 0.5;
                const surface_center_y = tex_h * 0.5;
                dest_x += (surface_center_x - glyph_center_x) * scale;
                dest_y += (surface_center_y - glyph_center_y) * scale;
            }
        }
        const dest_rect = c.SDL_FRect{
            .x = dest_x,
            .y = dest_y,
            .w = dest_w,
            .h = dest_h,
        };

        _ = c.SDL_RenderTexture(self.renderer, texture, null, &dest_rect);
    }

    pub fn renderClusterFill(
        self: *Font,
        codepoints: []const u21,
        x: c_int,
        y: c_int,
        target_width: c_int,
        target_height: c_int,
        fg_color: c.SDL_Color,
        variant: Variant,
    ) RenderGlyphError!void {
        if (codepoints.len == 0) return;
        if (codepoints.len == 1 and codepoints[0] == 0) return;

        if (codepoints.len > max_cluster_size) {
            const chars_per_chunk = max_cluster_size;
            const cell_width = @max(1, @divTrunc(target_width, @as(c_int, @intCast(codepoints.len))));

            var offset: usize = 0;
            while (offset < codepoints.len) {
                const chunk_end = @min(offset + chars_per_chunk, codepoints.len);
                const chunk = codepoints[offset..chunk_end];
                const chunk_x = x + @as(c_int, @intCast(offset)) * cell_width;
                const chunk_width = @as(c_int, @intCast(chunk.len)) * cell_width;
                try self.renderClusterFill(chunk, chunk_x, y, chunk_width, target_height, fg_color, variant);
                offset = chunk_end;
            }
            return;
        }

        var sanitized_buf: [max_cluster_size]u21 = undefined;
        const cluster = sanitizeCluster(codepoints, &sanitized_buf);
        const effective_variant = self.effectiveVariant(variant, cluster);

        var total_bytes: usize = 0;
        for (cluster) |cp| {
            total_bytes += std.unicode.utf8CodepointSequenceLength(cp) catch return error.InvalidCodepoint;
        }

        var stack_buf: [512]u8 = undefined;
        const use_heap = total_bytes > stack_buf.len;
        const utf8_slice = if (use_heap)
            try self.allocator.alloc(u8, total_bytes)
        else
            stack_buf[0..total_bytes];
        defer if (use_heap) self.allocator.free(utf8_slice);

        var utf8_len: usize = 0;
        for (cluster) |cp| {
            var local: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(cp, &local) catch return error.InvalidCodepoint;
            @memcpy(utf8_slice[utf8_len .. utf8_len + encoded_len], local[0..encoded_len]);
            utf8_len += encoded_len;
        }

        const fallback_choice = self.classifyFallback(cluster);
        const texture = self.getGlyphTexture(utf8_slice[0..utf8_len], fg_color, fallback_choice, effective_variant) catch |err| {
            if (err == error.GlyphRenderFailed) return;
            return err;
        };

        var tex_w: f32 = 0;
        var tex_h: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &tex_w, &tex_h);
        if (tex_w == 0 or tex_h == 0) return;

        const pad_px: c_int = @max(1, @divFloor(target_width, 5));
        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(x - pad_px),
            .y = @floatFromInt(y - pad_px),
            .w = @floatFromInt(target_width + pad_px * 2),
            .h = @floatFromInt(target_height + pad_px * 2),
        };

        _ = c.SDL_RenderTexture(self.renderer, texture, null, &dest_rect);
    }

    pub fn classifyFallback(self: *Font, codepoints: []const u21) Fallback {
        const has_all = blk: {
            for (codepoints) |cp| {
                if (!c.TTF_FontHasGlyph(self.font, @intCast(cp))) {
                    break :blk false;
                }
            }
            break :blk true;
        };
        if (has_all) return .primary;

        const has_emoji = blk: {
            for (codepoints) |cp| {
                if (cp >= 0x1F000) break :blk true;
            }
            break :blk false;
        };

        if (has_emoji and self.emoji_fallback != null) {
            return .emoji;
        }

        if (self.symbol_fallback_embedded) |fallback_font| {
            const has_in_symbol = blk: {
                for (codepoints) |cp| {
                    if (!c.TTF_FontHasGlyph(fallback_font, @intCast(cp))) {
                        break :blk false;
                    }
                }
                break :blk true;
            };
            if (has_in_symbol) return .symbol_embedded;
        }

        if (self.symbol_fallback) |fallback_font| {
            const has_in_symbol = blk: {
                for (codepoints) |cp| {
                    if (!c.TTF_FontHasGlyph(fallback_font, @intCast(cp))) {
                        break :blk false;
                    }
                }
                break :blk true;
            };
            if (has_in_symbol) return .symbol;
        }

        if (self.symbol_fallback_secondary) |fallback_font| {
            const has_in_symbol = blk: {
                for (codepoints) |cp| {
                    if (!c.TTF_FontHasGlyph(fallback_font, @intCast(cp))) {
                        break :blk false;
                    }
                }
                break :blk true;
            };
            if (has_in_symbol) return .symbol_secondary;
        }

        if (self.emoji_fallback != null) return .emoji;

        return .primary;
    }

    fn getGlyphTexture(self: *Font, utf8: []const u8, fg_color: c.SDL_Color, fallback: Fallback, variant: Variant) RenderGlyphError!*c.SDL_Texture {
        if (utf8.len > max_glyph_byte_length) {
            log.warn("Refusing to render excessively long glyph string: {d} bytes", .{utf8.len});
            return error.GlyphRenderFailed;
        }

        const key = GlyphKey{
            .hash = std.hash.Wyhash.hash(0, utf8),
            .color = packColor(if (fallback == .emoji) white else fg_color),
            .fallback = fallback,
            .variant = variant,
            .len = @intCast(utf8.len),
        };

        if (self.glyph_cache.getEntry(key)) |entry| {
            entry.value_ptr.seq = self.nextSeq();
            if (self.metrics) |m| m.increment(.glyph_cache_hits);
            return entry.value_ptr.texture;
        }

        const render_font = switch (fallback) {
            .primary => self.variantFont(variant),
            .symbol_embedded => self.symbol_fallback_embedded orelse self.symbol_fallback orelse self.font,
            .symbol => self.symbol_fallback orelse self.font,
            .symbol_secondary => self.symbol_fallback_secondary orelse self.symbol_fallback orelse self.font,
            .emoji => self.emoji_fallback orelse self.font,
        };
        const render_color = if (fallback == .emoji) white else fg_color;

        const surface = c.TTF_RenderText_Blended(render_font, @ptrCast(utf8.ptr), @intCast(utf8.len), render_color) orelse {
            log.debug("TTF_RenderText_Blended failed: {s}", .{c.SDL_GetError()});
            return error.GlyphRenderFailed;
        };

        var surf_rect: c.SDL_Rect = undefined;
        _ = c.SDL_GetSurfaceClipRect(surface, &surf_rect);
        const max_dim: c_int = 16384;
        if (surf_rect.w > max_dim or surf_rect.h > max_dim) {
            log.warn("Glyph surface too large ({d}x{d}), skipping render", .{ surf_rect.w, surf_rect.h });
            c.SDL_DestroySurface(surface);
            return error.GlyphRenderFailed;
        }
        defer c.SDL_DestroySurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(self.renderer, surface) orelse {
            log.err("SDL_CreateTextureFromSurface failed: {s}", .{c.SDL_GetError()});
            return error.TextureCreationFailed;
        };

        _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_LINEAR);

        try self.glyph_cache.put(key, .{ .texture = texture, .seq = self.nextSeq() });
        if (self.metrics) |m| {
            m.increment(.glyph_cache_misses);
            m.set(.glyph_cache_size, self.glyph_cache.count());
        }
        self.evictIfNeeded();
        return texture;
    }

    fn nextSeq(self: *Font) u64 {
        self.cache_tick +%= 1;
        return self.cache_tick;
    }

    fn evictIfNeeded(self: *Font) void {
        if (self.glyph_cache.count() <= max_glyph_cache_entries) return;

        if (findOldestKey(&self.glyph_cache)) |victim| {
            if (self.glyph_cache.fetchRemove(victim)) |removed| {
                c.SDL_DestroyTexture(removed.value.texture);
                if (self.metrics) |m| m.increment(.glyph_cache_evictions);
            }
        }
    }

    // O(n) linear scan to find the oldest entry. A proper LRU list would give O(1) eviction,
    // but in practice the 4096-entry cache is large enough that evictions are rare during
    // normal terminal usage—even with diverse Unicode, emoji, and multiple font sizes.
    // The simplicity of a flat hashmap outweighs the cost of occasional linear scans.
    fn findOldestKey(map: *std.AutoHashMap(GlyphKey, CacheEntry)) ?GlyphKey {
        var it = map.iterator();
        var oldest_key: ?GlyphKey = null;
        var oldest_seq: u64 = std.math.maxInt(u64);
        while (it.next()) |entry| {
            const seq = entry.value_ptr.seq;
            if (oldest_key == null or seq < oldest_seq) {
                oldest_key = entry.key_ptr.*;
                oldest_seq = seq;
            }
        }
        return oldest_key;
    }

    fn packColor(color: c.SDL_Color) u32 {
        return (@as(u32, color.r)) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24);
    }

    fn variantFont(self: *Font, variant: Variant) *c.TTF_Font {
        return switch (variant) {
            .regular => self.font,
            .bold => self.bold_font orelse self.font,
            .italic => self.italic_font orelse self.font,
            .bold_italic => self.bold_italic_font orelse self.bold_font orelse self.font,
        };
    }

    fn effectiveVariant(self: *Font, variant: Variant, codepoints: []const u21) Variant {
        if (variant == .regular) return .regular;
        if (self.variantHasGlyphs(variant, codepoints)) return variant;
        return .regular;
    }

    fn variantHasGlyphs(self: *Font, variant: Variant, codepoints: []const u21) bool {
        const font_ptr = switch (variant) {
            .regular => return true,
            .bold => self.bold_font,
            .italic => self.italic_font,
            .bold_italic => self.bold_italic_font,
        } orelse return false;
        for (codepoints) |cp| {
            if (!c.TTF_FontHasGlyph(font_ptr, @intCast(cp))) {
                return false;
            }
        }
        return true;
    }
};

test "findOldestKey picks lowest seq" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(GlyphKey, Font.CacheEntry).init(allocator);
    defer map.deinit();

    const k1 = GlyphKey{ .hash = 1, .color = 0, .fallback = .primary, .variant = .regular, .len = 1 };
    const k2 = GlyphKey{ .hash = 2, .color = 0, .fallback = .primary, .variant = .regular, .len = 1 };
    try map.put(k1, .{ .texture = undefined, .seq = 10 });
    try map.put(k2, .{ .texture = undefined, .seq = 5 });

    const oldest = Font.findOldestKey(&map) orelse return error.TestExpectedResult;
    try std.testing.expect(std.meta.eql(oldest, k2));
}
