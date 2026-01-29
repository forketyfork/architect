const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const dpi = @import("../scale.zig");

/// Render an animated flowing line with multi-layer diffusion effect.
/// Used to highlight the currently selected item in overlays.
pub fn render(
    renderer: *c.SDL_Renderer,
    animation_start_ms: i64,
    now_ms: i64,
    rect: geom.Rect,
    y: c_int,
    ui_scale: f32,
    theme: *const colors.Theme,
) void {
    const elapsed_ms = now_ms - animation_start_ms;
    const time: f32 = @as(f32, @floatFromInt(elapsed_ms)) / 1000.0;

    const padding: c_int = dpi.scale(20, ui_scale);
    const start_x: f32 = @floatFromInt(rect.x + padding);
    const end_x: f32 = @floatFromInt(rect.x + rect.w - padding);
    const width = end_x - start_x;
    const base_y: f32 = @floatFromInt(y);

    if (width <= 0) return;

    const num_points: usize = @max(2, @as(usize, @intFromFloat(width / 3.0)));
    const point_spacing = width / @as(f32, @floatFromInt(num_points - 1));

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    const flow_speed = 0.5;
    const flow_offset = time * flow_speed;

    const accent = theme.accent;

    const diffusion_layers = 9;
    var layer: usize = 0;
    while (layer < diffusion_layers) : (layer += 1) {
        const layer_f: f32 = @floatFromInt(layer);
        const center: f32 = @as(f32, @floatFromInt(diffusion_layers - 1)) / 2.0;
        const layer_offset = (layer_f - center) * 1.2;
        const dist_from_center = @abs(layer_f - center);
        const layer_alpha_mult = 1.0 - (dist_from_center / (center + 1.0));

        var prev_x: f32 = start_x;
        var prev_y: f32 = base_y + layer_offset;

        for (0..num_points) |i| {
            const x = start_x + @as(f32, @floatFromInt(i)) * point_spacing;
            const normalized_x = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_points - 1)));

            const wave1 = @sin((normalized_x * 8.0 + flow_offset) * std.math.pi);
            const wave2 = @sin((normalized_x * 13.0 - flow_offset * 1.3) * std.math.pi) * 0.6;
            const wave3 = @cos((normalized_x * 21.0 + flow_offset * 0.7) * std.math.pi) * 0.4;
            const wave4 = @sin((normalized_x * 34.0 - flow_offset * 0.5) * std.math.pi) * 0.3;

            const combined_wave = (wave1 + wave2 + wave3 + wave4) / 2.3;
            const amplitude: f32 = @as(f32, @floatFromInt(dpi.scale(3, ui_scale)));
            const y_val = base_y + combined_wave * amplitude + layer_offset;

            if (i > 0) {
                const segment_progress = @abs(@sin((normalized_x * 5.0 - flow_offset * 2.0) * std.math.pi));
                const alpha_base: f32 = 100.0;
                const alpha_var: f32 = 40.0;
                const base_alpha = alpha_base + segment_progress * alpha_var;
                const final_alpha = base_alpha * layer_alpha_mult * 0.4;
                const alpha: u8 = @intFromFloat(@min(255.0, final_alpha));

                _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, alpha);
                _ = c.SDL_RenderLine(renderer, prev_x, prev_y, x, y_val);
            }

            prev_x = x;
            prev_y = y_val;
        }
    }
}
