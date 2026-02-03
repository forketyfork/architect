const std = @import("std");
const c = @import("../../c.zig");
const input = @import("../../input/mapper.zig");
const font_mod = @import("../../font.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const HoldGesture = @import("../gestures/hold.zig").HoldGesture;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

const log = std.log.scoped(.escape_hold);

pub const EscapeHoldComponent = struct {
    allocator: std.mem.Allocator,
    gesture: HoldGesture = .{},
    font: *font_mod.Font,
    first_frame: FirstFrameGuard = .{},

    const esc_hold_total_ms: i64 = 700;
    const esc_indicator_delay_ms: i64 = 150;
    const esc_arc_count: usize = 5;
    const esc_visible_duration_ms: i64 = esc_hold_total_ms - esc_indicator_delay_ms;
    const esc_arc_segment_ms: i64 = esc_visible_duration_ms / esc_arc_count;
    const esc_indicator_margin: c_int = 40;
    const esc_indicator_radius: c_int = 30;

    pub fn init(allocator: std.mem.Allocator, font: *font_mod.Font) !*EscapeHoldComponent {
        const comp = try allocator.create(EscapeHoldComponent);
        comp.* = .{ .allocator = allocator, .font = font };
        return comp;
    }

    pub fn asComponent(self: *EscapeHoldComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 800,
        };
    }

    pub fn destroy(self: *EscapeHoldComponent, renderer: *c.SDL_Renderer) void {
        self.allocator.destroy(self);
        _ = renderer;
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *EscapeHoldComponent = @ptrCast(@alignCast(self_ptr));

        if (!input.canHandleEscapePress(host.view_mode)) return false;

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                if (event.key.key == c.SDLK_ESCAPE and !event.key.repeat) {
                    self.gesture.start(host.now_ms, esc_hold_total_ms);
                    self.first_frame.markTransition();
                    return true;
                }
            },
            c.SDL_EVENT_KEY_UP => {
                if (event.key.key == c.SDLK_ESCAPE) {
                    if (self.gesture.isComplete(host.now_ms) or self.gesture.consumed) {
                        self.gesture.stop();
                        return true;
                    }
                    // quick tap: let main handle ESC to terminal
                    self.gesture.stop();
                    return false;
                }
            },
            else => {},
        }

        return false;
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, actions: *types.UiActionQueue) void {
        const self: *EscapeHoldComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.gesture.active) return;
        if (self.gesture.isComplete(host.now_ms) and !self.gesture.consumed) {
            self.gesture.consumed = true;
            actions.append(.RequestCollapseFocused) catch |err| {
                log.warn("failed to queue collapse action: {}", .{err});
            };
        }

        if (self.gesture.consumed) {
            const elapsed_since_complete = host.now_ms - (self.gesture.start_ms + esc_hold_total_ms);
            const flash_duration_ms: i64 = 200;
            if (elapsed_since_complete >= flash_duration_ms) {
                self.gesture.stop();
            }
        }
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *EscapeHoldComponent = @ptrCast(@alignCast(self_ptr));
        return self.gesture.active or self.first_frame.wantsFrame();
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *EscapeHoldComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.gesture.active) return;

        const elapsed = host.now_ms - self.gesture.start_ms;
        if (elapsed < esc_indicator_delay_ms) return;

        const display_elapsed = elapsed - esc_indicator_delay_ms;
        const completed_arcs = @min(esc_arc_count, @as(usize, @intCast(@divFloor(display_elapsed, esc_arc_segment_ms))));
        const margin = dpi.scale(esc_indicator_margin, host.ui_scale);
        const radius = dpi.scale(esc_indicator_radius, host.ui_scale);
        const ring_half_thickness = dpi.scale(4, host.ui_scale);
        const center_offset = dpi.scale(10, host.ui_scale);
        const center_x = margin + radius + center_offset;
        const center_y = margin + radius + center_offset;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

        const backdrop_radius = @as(f32, @floatFromInt(radius)) + @as(f32, @floatFromInt(dpi.scale(40, host.ui_scale)));
        const backdrop_segments: usize = 64;
        const shadow_layers: usize = 30;

        const center_x_f = @as(f32, @floatFromInt(center_x));
        const center_y_f = @as(f32, @floatFromInt(center_y));

        var layer: usize = 0;
        while (layer < shadow_layers) : (layer += 1) {
            const layer_progress = @as(f32, @floatFromInt(layer)) / @as(f32, @floatFromInt(shadow_layers));
            const layer_radius = backdrop_radius * (1.0 - layer_progress);
            const alpha: u8 = @intFromFloat(180.0 * layer_progress);

            const base_color = c.SDL_FColor{ .r = 27.0 / 255.0, .g = 34.0 / 255.0, .b = 48.0 / 255.0, .a = @as(f32, @floatFromInt(alpha)) / 255.0 };

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

        const esc_text = "Esc";
        const text_color = c.SDL_Color{ .r = 205, .g = 214, .b = 224, .a = 255 };

        const text_width = self.font.cell_width * @as(c_int, @intCast(esc_text.len));
        const text_height = self.font.cell_height;

        var x = center_x - @divFloor(text_width, 2);
        const y = center_y - @divFloor(text_height, 2);

        for (esc_text) |ch| {
            self.font.renderGlyph(ch, x, y, self.font.cell_width, self.font.cell_height, text_color) catch |err| {
                log.warn("failed to render glyph: {}", .{err});
                continue;
            };
            x += self.font.cell_width;
        }

        const arc_segments: usize = 32;
        const degrees_per_arc: f32 = 360.0 / @as(f32, @floatFromInt(esc_arc_count));
        const gap_degrees: f32 = 8.0;

        const all_complete = completed_arcs >= esc_arc_count;
        var flash_brightness: f32 = 1.0;
        var flash_scale: f32 = 1.0;

        if (all_complete and self.gesture.active) {
            const elapsed_since_complete = host.now_ms - (self.gesture.start_ms + esc_hold_total_ms);
            if (elapsed_since_complete >= 0) {
                const flash_duration_ms: i64 = 200;
                const flash_progress = @min(1.0, @as(f32, @floatFromInt(elapsed_since_complete)) / @as(f32, @floatFromInt(flash_duration_ms)));
                const pulse = std.math.sin(flash_progress * std.math.pi);
                flash_brightness = 1.0 + 1.0 * pulse;
                flash_scale = 1.0 + 0.15 * pulse;
            }
        }

        var arc: usize = 0;
        while (arc < esc_arc_count) : (arc += 1) {
            const is_completed = arc < completed_arcs;
            var color = if (is_completed)
                c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 255 } // bright blue accent
            else
                c.SDL_Color{ .r = 215, .g = 186, .b = 125, .a = 255 }; // warm gold pending

            if (is_completed and all_complete) {
                color.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.r)) * flash_brightness));
                color.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.g)) * flash_brightness));
                color.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(color.b)) * flash_brightness));
            }

            _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);

            const start_angle = (@as(f32, @floatFromInt(arc)) * degrees_per_arc - 90.0 + gap_degrees / 2.0) * std.math.pi / 180.0;
            const end_angle = (@as(f32, @floatFromInt(arc + 1)) * degrees_per_arc - 90.0 - gap_degrees / 2.0) * std.math.pi / 180.0;

            const angle_step = (end_angle - start_angle) / @as(f32, @floatFromInt(arc_segments));

            const fcolor = c.SDL_FColor{
                .r = @as(f32, @floatFromInt(color.r)) / 255.0,
                .g = @as(f32, @floatFromInt(color.g)) / 255.0,
                .b = @as(f32, @floatFromInt(color.b)) / 255.0,
                .a = @as(f32, @floatFromInt(color.a)) / 255.0,
            };

            // Per-segment pop animation when it lights up
            var segment_scale: f32 = 1.0;
            if (is_completed and !all_complete) {
                // Calculate how long ago this segment completed
                const segment_complete_time = @as(i64, @intCast(arc + 1)) * esc_arc_segment_ms;
                const time_since_segment_complete = display_elapsed - segment_complete_time;
                const pop_duration_ms: i64 = 150;
                if (time_since_segment_complete >= 0 and time_since_segment_complete < pop_duration_ms) {
                    const pop_progress = @as(f32, @floatFromInt(time_since_segment_complete)) / @as(f32, @floatFromInt(pop_duration_ms));
                    // Ease out: starts big, settles to normal
                    const pop_amount = 0.2 * (1.0 - pop_progress * pop_progress);
                    segment_scale = 1.0 + pop_amount;
                }
            }

            var i: usize = 0;
            while (i < arc_segments) : (i += 1) {
                const angle1 = start_angle + @as(f32, @floatFromInt(i)) * angle_step;
                const angle2 = start_angle + @as(f32, @floatFromInt(i + 1)) * angle_step;

                const base_inner_radius = @as(f32, @floatFromInt(radius - ring_half_thickness));
                const base_outer_radius = @as(f32, @floatFromInt(radius + ring_half_thickness));

                const effective_scale = if (all_complete) flash_scale else segment_scale;
                const inner_radius = base_inner_radius * effective_scale;
                const outer_radius = base_outer_radius * effective_scale;

                const x1_inner = @as(f32, @floatFromInt(center_x)) + inner_radius * std.math.cos(angle1);
                const y1_inner = @as(f32, @floatFromInt(center_y)) + inner_radius * std.math.sin(angle1);
                const x1_outer = @as(f32, @floatFromInt(center_x)) + outer_radius * std.math.cos(angle1);
                const y1_outer = @as(f32, @floatFromInt(center_y)) + outer_radius * std.math.sin(angle1);

                const x2_inner = @as(f32, @floatFromInt(center_x)) + inner_radius * std.math.cos(angle2);
                const y2_inner = @as(f32, @floatFromInt(center_y)) + inner_radius * std.math.sin(angle2);
                const x2_outer = @as(f32, @floatFromInt(center_x)) + outer_radius * std.math.cos(angle2);
                const y2_outer = @as(f32, @floatFromInt(center_y)) + outer_radius * std.math.sin(angle2);

                const verts = [_]c.SDL_Vertex{
                    .{ .position = .{ .x = x1_inner, .y = y1_inner }, .color = fcolor },
                    .{ .position = .{ .x = x1_outer, .y = y1_outer }, .color = fcolor },
                    .{ .position = .{ .x = x2_inner, .y = y2_inner }, .color = fcolor },
                    .{ .position = .{ .x = x2_outer, .y = y2_outer }, .color = fcolor },
                };
                const indices = [_]c_int{ 0, 1, 2, 2, 1, 3 };
                _ = c.SDL_RenderGeometry(renderer, null, &verts, verts.len, &indices, indices.len);
            }
        }
        self.first_frame.markDrawn();
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *EscapeHoldComponent = @ptrCast(@alignCast(self_ptr));
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
