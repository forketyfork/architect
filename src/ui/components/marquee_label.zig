const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");

pub const MarqueeLabel = struct {
    allocator: std.mem.Allocator,
    text: []const u8 = "",
    texture: ?*c.SDL_Texture = null,
    tex_w: c_int = 0,
    tex_h: c_int = 0,
    speed_px_per_sec: f32 = 30.0,
    start_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, text: []const u8, start_ms: i64, speed_px_per_sec: f32) MarqueeLabel {
        return .{ .allocator = allocator, .text = text, .start_ms = start_ms, .speed_px_per_sec = speed_px_per_sec };
    }

    pub fn setText(self: *MarqueeLabel, text: []const u8, now_ms: i64) void {
        self.text = text;
        self.start_ms = now_ms;
        self.invalidate();
    }

    pub fn invalidate(self: *MarqueeLabel) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
        self.tex_w = 0;
        self.tex_h = 0;
    }

    pub fn deinit(self: *MarqueeLabel) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
    }

    pub fn render(
        self: *MarqueeLabel,
        renderer: *c.SDL_Renderer,
        assets: *types.UiAssets,
        now_ms: i64,
        bounds: c.SDL_FRect,
    ) void {
        const font = assets.ui_font orelse return;
        if (self.texture == null) {
            const fg_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };
            const surface = c.TTF_RenderText_Blended(font.font, @ptrCast(self.text.ptr), self.text.len, fg_color) orelse return;
            defer c.SDL_DestroySurface(surface);
            const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
            self.texture = tex;
            var w: f32 = 0;
            var h: f32 = 0;
            _ = c.SDL_GetTextureSize(tex, &w, &h);
            self.tex_w = @intFromFloat(w);
            self.tex_h = @intFromFloat(h);
            _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
        }

        const tex = self.texture.?;
        if (self.tex_w <= 0) return;

        const travel = @as(f32, @floatFromInt(now_ms - self.start_ms)) / 1000.0 * self.speed_px_per_sec;
        const loop_w = @as(f32, @floatFromInt(self.tex_w)) + bounds.w;
        const offset = @mod(travel, loop_w);
        const x = bounds.x + bounds.w - offset;

        const dest = c.SDL_FRect{
            .x = x,
            .y = bounds.y + (bounds.h - @as(f32, @floatFromInt(self.tex_h))) / 2.0,
            .w = @as(f32, @floatFromInt(self.tex_w)),
            .h = @as(f32, @floatFromInt(self.tex_h)),
        };
        _ = c.SDL_RenderTexture(renderer, tex, null, &dest);

        // draw second copy for wrap
        if (dest.x + dest.w < bounds.x + bounds.w) {
            var wrap_dest = dest;
            wrap_dest.x += loop_w;
            _ = c.SDL_RenderTexture(renderer, tex, null, &wrap_dest);
        }
    }
};
