const std = @import("std");
const c = @import("../../c.zig");
const font_mod = @import("../../font.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

pub const HotkeyIndicatorComponent = struct {
    allocator: std.mem.Allocator,
    font: *font_mod.Font,
    first_frame: FirstFrameGuard = .{},

    active: bool = false,
    start_ms: i64 = 0,

    label: [16]u8 = undefined,
    label_len: usize = 0,

    const INDICATOR_MARGIN: c_int = 40;
    const INDICATOR_RADIUS: c_int = 30;
    const DISPLAY_DURATION_MS: i64 = 400;
    const FADE_START_MS: i64 = 200;

    pub fn init(allocator: std.mem.Allocator, font: *font_mod.Font) !*HotkeyIndicatorComponent {
        const comp = try allocator.create(HotkeyIndicatorComponent);
        comp.* = .{ .allocator = allocator, .font = font };
        return comp;
    }

    pub fn asComponent(self: *HotkeyIndicatorComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 800,
        };
    }

    pub fn destroy(self: *HotkeyIndicatorComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.allocator.destroy(self);
    }

    pub fn show(self: *HotkeyIndicatorComponent, label: []const u8, now_ms: i64) void {
        const len = @min(label.len, self.label.len);
        @memcpy(self.label[0..len], label[0..len]);
        self.label_len = len;
        self.start_ms = now_ms;
        self.active = true;
        self.first_frame.markTransition();
    }

    fn handleEvent(_: *anyopaque, _: *const types.UiHost, _: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        return false;
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *HotkeyIndicatorComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.active) return;

        const elapsed = host.now_ms - self.start_ms;
        if (elapsed >= DISPLAY_DURATION_MS) {
            self.active = false;
        }
    }

    fn wantsFrame(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *HotkeyIndicatorComponent = @ptrCast(@alignCast(self_ptr));
        if (self.first_frame.wantsFrame()) return true;
        if (!self.active) return false;
        const elapsed = host.now_ms - self.start_ms;
        return elapsed < DISPLAY_DURATION_MS;
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *HotkeyIndicatorComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.active) return;

        const elapsed = host.now_ms - self.start_ms;
        if (elapsed >= DISPLAY_DURATION_MS) return;

        const alpha = self.getAlpha(host.now_ms);
        if (alpha == 0) return;

        const margin = dpi.scale(INDICATOR_MARGIN, host.ui_scale);
        const radius = dpi.scale(INDICATOR_RADIUS, host.ui_scale);
        const ring_half_thickness = dpi.scale(4, host.ui_scale);
        const center_offset = dpi.scale(10, host.ui_scale);
        const center_x = margin + radius + center_offset;
        const center_y = margin + radius + center_offset;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

        // Draw backdrop shadow
        const backdrop_radius = @as(f32, @floatFromInt(radius)) + @as(f32, @floatFromInt(dpi.scale(40, host.ui_scale)));
        const backdrop_segments: usize = 64;
        const shadow_layers: usize = 30;

        const center_x_f = @as(f32, @floatFromInt(center_x));
        const center_y_f = @as(f32, @floatFromInt(center_y));
        const alpha_f = @as(f32, @floatFromInt(alpha)) / 255.0;

        var layer: usize = 0;
        while (layer < shadow_layers) : (layer += 1) {
            const layer_progress = @as(f32, @floatFromInt(layer)) / @as(f32, @floatFromInt(shadow_layers));
            const layer_radius = backdrop_radius * (1.0 - layer_progress);
            const layer_alpha: f32 = (180.0 / 255.0) * layer_progress * alpha_f;

            const base_color = c.SDL_FColor{ .r = 27.0 / 255.0, .g = 34.0 / 255.0, .b = 48.0 / 255.0, .a = layer_alpha };

            var seg: usize = 0;
            while (seg < backdrop_segments) : (seg += 1) {
                const angle1 = @as(f32, @floatFromInt(seg)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(backdrop_segments));
                const angle2 = @as(f32, @floatFromInt(seg + 1)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(backdrop_segments));

                const x1 = center_x_f + layer_radius * std.math.cos(angle1);
                const y1 = center_y_f + layer_radius * std.math.sin(angle1);
                const x2 = center_x_f + layer_radius * std.math.cos(angle2);
                const y2 = center_y_f + layer_radius * std.math.sin(angle2);

                const verts = [_]c.SDL_Vertex{
                    .{ .position = .{ .x = center_x_f, .y = center_y_f }, .color = base_color },
                    .{ .position = .{ .x = x1, .y = y1 }, .color = base_color },
                    .{ .position = .{ .x = x2, .y = y2 }, .color = base_color },
                };
                const indices = [_]c_int{ 0, 1, 2 };
                _ = c.SDL_RenderGeometry(renderer, null, &verts, verts.len, &indices, indices.len);
            }
        }

        // Draw full blue ring (not segmented)
        const arc_segments: usize = 64;
        const color = c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = alpha };

        const fcolor = c.SDL_FColor{
            .r = @as(f32, @floatFromInt(color.r)) / 255.0,
            .g = @as(f32, @floatFromInt(color.g)) / 255.0,
            .b = @as(f32, @floatFromInt(color.b)) / 255.0,
            .a = @as(f32, @floatFromInt(color.a)) / 255.0,
        };

        const inner_radius = @as(f32, @floatFromInt(radius - ring_half_thickness));
        const outer_radius = @as(f32, @floatFromInt(radius + ring_half_thickness));

        var i: usize = 0;
        while (i < arc_segments) : (i += 1) {
            const angle1 = @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(arc_segments));
            const angle2 = @as(f32, @floatFromInt(i + 1)) * 2.0 * std.math.pi / @as(f32, @floatFromInt(arc_segments));

            const x1_inner = center_x_f + inner_radius * std.math.cos(angle1);
            const y1_inner = center_y_f + inner_radius * std.math.sin(angle1);
            const x1_outer = center_x_f + outer_radius * std.math.cos(angle1);
            const y1_outer = center_y_f + outer_radius * std.math.sin(angle1);

            const x2_inner = center_x_f + inner_radius * std.math.cos(angle2);
            const y2_inner = center_y_f + inner_radius * std.math.sin(angle2);
            const x2_outer = center_x_f + outer_radius * std.math.cos(angle2);
            const y2_outer = center_y_f + outer_radius * std.math.sin(angle2);

            const verts = [_]c.SDL_Vertex{
                .{ .position = .{ .x = x1_inner, .y = y1_inner }, .color = fcolor },
                .{ .position = .{ .x = x1_outer, .y = y1_outer }, .color = fcolor },
                .{ .position = .{ .x = x2_inner, .y = y2_inner }, .color = fcolor },
                .{ .position = .{ .x = x2_outer, .y = y2_outer }, .color = fcolor },
            };
            const indices = [_]c_int{ 0, 1, 2, 2, 1, 3 };
            _ = c.SDL_RenderGeometry(renderer, null, &verts, verts.len, &indices, indices.len);
        }

        // Draw label text
        const text_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = alpha };
        const label_slice = self.label[0..self.label_len];

        // Count display width (handle multi-byte UTF-8 characters)
        var display_width: usize = 0;
        var idx: usize = 0;
        while (idx < label_slice.len) {
            const byte = label_slice[idx];
            if (byte < 0x80) {
                idx += 1;
            } else if (byte < 0xE0) {
                idx += 2;
            } else if (byte < 0xF0) {
                idx += 3;
            } else {
                idx += 4;
            }
            display_width += 1;
        }

        const text_width = self.font.cell_width * @as(c_int, @intCast(display_width));
        const text_height = self.font.cell_height;

        var x = center_x - @divFloor(text_width, 2);
        const y = center_y - @divFloor(text_height, 2);

        // Render each character
        idx = 0;
        while (idx < label_slice.len) {
            const byte = label_slice[idx];
            var char_len: usize = 1;
            if (byte >= 0xF0) {
                char_len = 4;
            } else if (byte >= 0xE0) {
                char_len = 3;
            } else if (byte >= 0xC0) {
                char_len = 2;
            }

            if (idx + char_len <= label_slice.len) {
                const ch_slice = label_slice[idx .. idx + char_len];
                if (char_len == 1) {
                    self.font.renderGlyph(ch_slice[0], x, y, self.font.cell_width, self.font.cell_height, text_color) catch {};
                } else {
                    // For multi-byte UTF-8, decode the codepoint
                    const codepoint = decodeUtf8(ch_slice);
                    self.font.renderGlyph(codepoint, x, y, self.font.cell_width, self.font.cell_height, text_color) catch {};
                }
            }
            x += self.font.cell_width;
            idx += char_len;
        }

        self.first_frame.markDrawn();
    }

    fn getAlpha(self: *const HotkeyIndicatorComponent, now_ms: i64) u8 {
        const elapsed = now_ms - self.start_ms;
        if (elapsed < 0) return 0;
        if (elapsed >= DISPLAY_DURATION_MS) return 0;
        if (elapsed < FADE_START_MS) return 255;

        const fade_elapsed = elapsed - FADE_START_MS;
        const fade_duration = DISPLAY_DURATION_MS - FADE_START_MS;
        const progress = @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(fade_duration));
        const eased = progress * progress * (3.0 - 2.0 * progress);
        return @intFromFloat(255.0 * (1.0 - eased));
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *HotkeyIndicatorComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

fn decodeUtf8(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0;
    const b0 = bytes[0];
    if (b0 < 0x80) return b0;
    if (bytes.len < 2) return 0xFFFD;
    const b1 = bytes[1];
    if (b0 < 0xE0) {
        return (@as(u21, b0 & 0x1F) << 6) | (b1 & 0x3F);
    }
    if (bytes.len < 3) return 0xFFFD;
    const b2 = bytes[2];
    if (b0 < 0xF0) {
        return (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | (b2 & 0x3F);
    }
    if (bytes.len < 4) return 0xFFFD;
    const b3 = bytes[3];
    return (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) | (@as(u21, b2 & 0x3F) << 6) | (b3 & 0x3F);
}
