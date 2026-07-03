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
    fallback: Fallback,
    variant: Variant,
    // Cluster length in codepoints. Using u16 provides generous headroom
    // (up to 65535) while the renderer currently caps runs at 512 codepoints.
    len: u16,
};

const white: c.SDL_Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// Bitmask of which font faces contain a given codepoint's glyph, memoized
/// per codepoint in `Font.face_mask_cache` so repeated lookups (which happen
/// every frame for every visible cell) skip the `TTF_FontHasGlyph` FFI call.
const FaceMask = struct {
    const primary: u8 = 1 << 0;
    const bold: u8 = 1 << 1;
    const italic: u8 = 1 << 2;
    const bold_italic: u8 = 1 << 3;
    const symbol_embedded: u8 = 1 << 4;
    const symbol: u8 = 1 << 5;
    const symbol_secondary: u8 = 1 << 6;
};

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
    face_mask_cache: std.AutoHashMap(u21, u8),
    cache_tick: u64 = 0,
    allocator: std.mem.Allocator,
    cell_width: c_int,
    cell_height: c_int,
    owns_fonts: bool,
    metrics: ?*metrics_mod.Metrics = null,

    /// Limit cached glyph textures to avoid unbounded GPU/heap growth.
    const max_glyph_cache_entries: usize = 4096;

    /// Number of entries evicted in one batch once the glyph cache is full.
    /// Selecting a whole batch per O(n) hashmap pass (see
    /// `selectEvictionVictims`) amortizes eviction cost across many inserts
    /// instead of paying a full scan on every single insert.
    const eviction_batch_size: usize = 256;

    /// Bound on the per-codepoint face mask memo. The memo is keyed by
    /// codepoint, so its size is bounded by the distinct codepoints actually
    /// seen rather than by rendered text volume. 64k comfortably covers real
    /// terminal usage (BMP plus common emoji); if ever exceeded, the memo is
    /// cleared and rebuilt lazily rather than growing unbounded.
    const max_face_mask_entries: usize = 65536;

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
        if (fallback == .emoji) return true;
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
            .face_mask_cache = std.AutoHashMap(u21, u8).init(allocator),
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
        self.face_mask_cache.deinit();
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
            .face_mask_cache = std.AutoHashMap(u21, u8).init(allocator),
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
        const texture = self.getGlyphTexture(utf8_slice[0..utf8_len], fallback_choice, effective_variant) catch |err| {
            if (err == error.GlyphRenderFailed) return;
            return err;
        };
        applyColorMod(texture, fallback_choice, fg_color);

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

        if (align_baseline) {
            if (glyphMetrics(metrics_font, cluster[0])) |glyph| {
                const glyph_h = glyph.max_y - glyph.min_y;
                const glyph_center_x = (glyph.min_x + glyph.max_x) * 0.5;
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
        const texture = self.getGlyphTexture(utf8_slice[0..utf8_len], fallback_choice, effective_variant) catch |err| {
            if (err == error.GlyphRenderFailed) return;
            return err;
        };
        applyColorMod(texture, fallback_choice, fg_color);

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
        var mask_buf: [max_cluster_size]u8 = undefined;
        const n = @min(codepoints.len, max_cluster_size);
        for (codepoints[0..n], 0..) |cp, i| {
            mask_buf[i] = self.faceMask(cp);
        }

        var has_emoji_range = false;
        for (codepoints) |cp| {
            if (cp >= 0x1F000) {
                has_emoji_range = true;
                break;
            }
        }

        return classifyFromMasks(
            mask_buf[0..n],
            has_emoji_range,
            self.symbol_fallback_embedded != null,
            self.symbol_fallback != null,
            self.symbol_fallback_secondary != null,
            self.emoji_fallback != null,
        );
    }

    /// Pure decision logic shared by `classifyFallback`: given the per-codepoint
    /// face masks for a cluster and which fallback fonts are configured, picks
    /// the fallback tier. Kept free of FFI/self so it can be unit tested directly.
    fn classifyFromMasks(
        masks: []const u8,
        has_emoji_range: bool,
        has_symbol_embedded_font: bool,
        has_symbol_font: bool,
        has_symbol_secondary_font: bool,
        has_emoji_font: bool,
    ) Fallback {
        var all_primary = true;
        var all_symbol_embedded = true;
        var all_symbol = true;
        var all_symbol_secondary = true;
        for (masks) |mask| {
            if (mask & FaceMask.primary == 0) all_primary = false;
            if (mask & FaceMask.symbol_embedded == 0) all_symbol_embedded = false;
            if (mask & FaceMask.symbol == 0) all_symbol = false;
            if (mask & FaceMask.symbol_secondary == 0) all_symbol_secondary = false;
        }

        if (all_primary) return .primary;
        if (has_emoji_range and has_emoji_font) return .emoji;
        if (has_symbol_embedded_font and all_symbol_embedded) return .symbol_embedded;
        if (has_symbol_font and all_symbol) return .symbol;
        if (has_symbol_secondary_font and all_symbol_secondary) return .symbol_secondary;
        if (has_emoji_font) return .emoji;
        return .primary;
    }

    /// Returns the bitmask of faces containing `cp`'s glyph, consulting and
    /// filling `face_mask_cache` so the `TTF_FontHasGlyph` FFI calls happen at
    /// most once per codepoint per `Font` instance instead of once per cell
    /// per frame.
    fn faceMask(self: *Font, cp: u21) u8 {
        if (self.face_mask_cache.get(cp)) |cached| return cached;

        var mask: u8 = 0;
        if (c.TTF_FontHasGlyph(self.font, @intCast(cp))) mask |= FaceMask.primary;
        if (self.bold_font) |f| {
            if (c.TTF_FontHasGlyph(f, @intCast(cp))) mask |= FaceMask.bold;
        }
        if (self.italic_font) |f| {
            if (c.TTF_FontHasGlyph(f, @intCast(cp))) mask |= FaceMask.italic;
        }
        if (self.bold_italic_font) |f| {
            if (c.TTF_FontHasGlyph(f, @intCast(cp))) mask |= FaceMask.bold_italic;
        }
        if (self.symbol_fallback_embedded) |f| {
            if (c.TTF_FontHasGlyph(f, @intCast(cp))) mask |= FaceMask.symbol_embedded;
        }
        if (self.symbol_fallback) |f| {
            if (c.TTF_FontHasGlyph(f, @intCast(cp))) mask |= FaceMask.symbol;
        }
        if (self.symbol_fallback_secondary) |f| {
            if (c.TTF_FontHasGlyph(f, @intCast(cp))) mask |= FaceMask.symbol_secondary;
        }

        if (self.face_mask_cache.count() >= max_face_mask_entries) {
            self.face_mask_cache.clearRetainingCapacity();
        }
        self.face_mask_cache.put(cp, mask) catch |err| {
            log.warn("failed to cache glyph face mask for U+{X}: {}", .{ cp, err });
        };
        return mask;
    }

    /// Sets the texture color modulation used to tint the shared white glyph
    /// texture at draw time. Non-emoji glyphs are rasterized in white once and
    /// tinted per draw via color mod; emoji glyphs are already full-color, so
    /// their mod is explicitly reset to white to avoid inheriting a stale tint
    /// left on the texture object from a prior draw.
    fn applyColorMod(texture: *c.SDL_Texture, fallback: Fallback, fg_color: c.SDL_Color) void {
        if (fallback == .emoji) {
            _ = c.SDL_SetTextureColorMod(texture, white.r, white.g, white.b);
        } else {
            _ = c.SDL_SetTextureColorMod(texture, fg_color.r, fg_color.g, fg_color.b);
        }
    }

    fn getGlyphTexture(self: *Font, utf8: []const u8, fallback: Fallback, variant: Variant) RenderGlyphError!*c.SDL_Texture {
        if (utf8.len > max_glyph_byte_length) {
            log.warn("Refusing to render excessively long glyph string: {d} bytes", .{utf8.len});
            return error.GlyphRenderFailed;
        }

        const key = GlyphKey{
            .hash = std.hash.Wyhash.hash(0, utf8),
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

        // Every glyph texture is rasterized in white regardless of fallback tier
        // (the cache key no longer includes color) so the same texture can be
        // reused across differently-colored draws via SDL_SetTextureColorMod.
        const surface = c.TTF_RenderText_Blended(render_font, @ptrCast(utf8.ptr), @intCast(utf8.len), white) orelse {
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

    const KeySeq = struct {
        key: GlyphKey,
        seq: u64,
    };

    // Batch eviction: once the cache exceeds its limit, evict a whole batch of
    // the oldest entries in a single O(n log batch_size) pass rather than
    // rescanning all n entries on every single insert. Key selection
    // (`selectEvictionVictims`) is a pure function over seq numbers so it can
    // be unit tested without touching SDL textures; only this function
    // performs the actual (SDL-destroying) removal.
    fn evictIfNeeded(self: *Font) void {
        if (self.glyph_cache.count() <= max_glyph_cache_entries) return;

        var victim_buf: [eviction_batch_size]KeySeq = undefined;
        const victims = selectEvictionVictims(&self.glyph_cache, &victim_buf);
        for (victims) |victim| {
            if (self.glyph_cache.fetchRemove(victim.key)) |removed| {
                c.SDL_DestroyTexture(removed.value.texture);
                if (self.metrics) |m| m.increment(.glyph_cache_evictions);
            }
        }
    }

    /// Selects up to `buf.len` entries with the lowest `seq` (i.e. the oldest)
    /// in one O(n log buf.len) pass over the map, using `buf` as a bounded
    /// max-heap: the root always holds the largest seq among the current
    /// candidates, so a full heap can reject or evict its root in O(log
    /// buf.len) as better (older) candidates are found.
    fn selectEvictionVictims(map: *std.AutoHashMap(GlyphKey, CacheEntry), buf: []KeySeq) []KeySeq {
        var filled: usize = 0;
        var it = map.iterator();
        while (it.next()) |entry| {
            const seq = entry.value_ptr.seq;
            if (filled < buf.len) {
                buf[filled] = .{ .key = entry.key_ptr.*, .seq = seq };
                heapSiftUp(buf[0 .. filled + 1], filled);
                filled += 1;
            } else if (seq < buf[0].seq) {
                buf[0] = .{ .key = entry.key_ptr.*, .seq = seq };
                heapSiftDown(buf[0..filled], 0);
            }
        }
        return buf[0..filled];
    }

    fn heapSiftUp(heap: []KeySeq, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (heap[parent].seq >= heap[i].seq) break;
            std.mem.swap(KeySeq, &heap[i], &heap[parent]);
            i = parent;
        }
    }

    fn heapSiftDown(heap: []KeySeq, start: usize) void {
        var i = start;
        while (true) {
            const left = 2 * i + 1;
            const right = 2 * i + 2;
            var largest = i;
            if (left < heap.len and heap[left].seq > heap[largest].seq) largest = left;
            if (right < heap.len and heap[right].seq > heap[largest].seq) largest = right;
            if (largest == i) break;
            std.mem.swap(KeySeq, &heap[i], &heap[largest]);
            i = largest;
        }
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
        // Bit is only ever set by `faceMask` when the corresponding font
        // pointer is non-null, so a missing font naturally yields `false`
        // here without a separate null check.
        const bit: u8 = switch (variant) {
            .regular => return true,
            .bold => FaceMask.bold,
            .italic => FaceMask.italic,
            .bold_italic => FaceMask.bold_italic,
        };
        for (codepoints) |cp| {
            if (self.faceMask(cp) & bit == 0) return false;
        }
        return true;
    }
};

test "selectEvictionVictims picks the lowest seq when under batch size" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(GlyphKey, Font.CacheEntry).init(allocator);
    defer map.deinit();

    const k1 = GlyphKey{ .hash = 1, .fallback = .primary, .variant = .regular, .len = 1 };
    const k2 = GlyphKey{ .hash = 2, .fallback = .primary, .variant = .regular, .len = 1 };
    // Textures are left undefined because selection never reads them: it only
    // inspects `seq`. Only `evictIfNeeded` touches (and destroys) textures.
    try map.put(k1, .{ .texture = undefined, .seq = 10 });
    try map.put(k2, .{ .texture = undefined, .seq = 5 });

    var buf: [4]Font.KeySeq = undefined;
    const victims = Font.selectEvictionVictims(&map, &buf);

    try std.testing.expectEqual(@as(usize, 2), victims.len);
    var saw_k2_first = false;
    for (victims) |v| {
        if (std.meta.eql(v.key, k2)) saw_k2_first = true;
    }
    try std.testing.expect(saw_k2_first);
}

test "selectEvictionVictims returns exactly the batch-size oldest entries" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(GlyphKey, Font.CacheEntry).init(allocator);
    defer map.deinit();

    // Seeded, shuffled-looking sequence so the heap has to evict its root
    // (i.e. discard newer candidates) multiple times during the scan.
    const seqs = [_]u64{ 50, 10, 90, 5, 70, 1, 60, 30, 2, 80, 20, 3 };
    for (seqs, 0..) |seq, i| {
        const key = GlyphKey{ .hash = @intCast(i), .fallback = .primary, .variant = .regular, .len = 1 };
        try map.put(key, .{ .texture = undefined, .seq = seq });
    }

    const batch_size = 4;
    var buf: [batch_size]Font.KeySeq = undefined;
    const victims = Font.selectEvictionVictims(&map, &buf);
    try std.testing.expectEqual(@as(usize, batch_size), victims.len);

    var got: [batch_size]u64 = undefined;
    for (victims, 0..) |v, i| got[i] = v.seq;
    std.mem.sort(u64, &got, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3, 5 }, &got);
}

test "classifyFromMasks prefers primary when all codepoints resolve there" {
    const masks = [_]u8{ FaceMask.primary, FaceMask.primary | FaceMask.symbol };
    const choice = Font.classifyFromMasks(&masks, false, true, true, true, true);
    try std.testing.expectEqual(Fallback.primary, choice);
}

test "classifyFromMasks falls back to emoji for emoji-range codepoints" {
    const masks = [_]u8{FaceMask.symbol_secondary};
    const choice = Font.classifyFromMasks(&masks, true, true, true, true, true);
    try std.testing.expectEqual(Fallback.emoji, choice);
}

test "classifyFromMasks walks symbol tiers in order" {
    const embedded_masks = [_]u8{FaceMask.symbol_embedded};
    try std.testing.expectEqual(
        Fallback.symbol_embedded,
        Font.classifyFromMasks(&embedded_masks, false, true, true, true, true),
    );

    const symbol_masks = [_]u8{FaceMask.symbol};
    try std.testing.expectEqual(
        Fallback.symbol,
        Font.classifyFromMasks(&symbol_masks, false, false, true, true, true),
    );

    const secondary_masks = [_]u8{FaceMask.symbol_secondary};
    try std.testing.expectEqual(
        Fallback.symbol_secondary,
        Font.classifyFromMasks(&secondary_masks, false, false, false, true, true),
    );
}

test "classifyFromMasks falls back to emoji font, then primary, when no tier matches" {
    const masks = [_]u8{0};
    try std.testing.expectEqual(
        Fallback.emoji,
        Font.classifyFromMasks(&masks, false, false, false, false, true),
    );
    try std.testing.expectEqual(
        Fallback.primary,
        Font.classifyFromMasks(&masks, false, false, false, false, false),
    );
}
