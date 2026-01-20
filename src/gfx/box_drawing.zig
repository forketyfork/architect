const std = @import("std");
const c = @import("../c.zig");

pub const Metrics = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    light_thickness: f32,
    heavy_thickness: f32,
};

pub fn computeMetrics(x: c_int, y: c_int, w: c_int, h: c_int) Metrics {
    const width: f32 = @floatFromInt(w);
    const height: f32 = @floatFromInt(h);
    const base_size = @min(width, height);
    const light = @max(1.0, @round(base_size / 8.0));
    const heavy = @max(2.0, @round(base_size / 4.0));
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = width,
        .height = height,
        .light_thickness = light,
        .heavy_thickness = heavy,
    };
}

const Segment = enum { none, light, heavy, double };

const BoxSpec = struct {
    left: Segment = .none,
    right: Segment = .none,
    up: Segment = .none,
    down: Segment = .none,
    diagonal_up: bool = false,
    diagonal_down: bool = false,
    dashes: u4 = 0,
    rounded: bool = false,
};

pub fn render(renderer: *c.SDL_Renderer, cp: u21, x: c_int, y: c_int, w: c_int, h: c_int, color: c.SDL_Color) bool {
    if (cp < 0x2500 or cp > 0x257F) return false;

    const idx = cp - 0x2500;
    const spec = box_specs[idx];

    if (spec.left == .none and spec.right == .none and spec.up == .none and spec.down == .none and !spec.diagonal_up and !spec.diagonal_down) {
        return false;
    }

    const m = computeMetrics(x, y, w, h);
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);

    if (spec.diagonal_up or spec.diagonal_down) {
        renderDiagonals(renderer, m, spec, color);
        return true;
    }

    if (spec.dashes > 0) {
        renderDashedLines(renderer, m, spec);
        return true;
    }

    if (spec.rounded) {
        renderRoundedCorner(renderer, m, spec, color);
        return true;
    }

    renderLines(renderer, m, spec);
    return true;
}

fn renderLines(renderer: *c.SDL_Renderer, m: Metrics, spec: BoxSpec) void {
    const mid_x = m.x + m.width * 0.5;
    const mid_y = m.y + m.height * 0.5;
    const light_half = m.light_thickness * 0.5;
    const heavy_half = m.heavy_thickness * 0.5;

    const hori_has_double = (spec.left == .double or spec.right == .double);
    const vert_has_double = (spec.up == .double or spec.down == .double);

    const double_gap = @max(1.0, m.light_thickness);
    const double_offset = (m.light_thickness + double_gap) * 0.5;

    if (spec.left != .none or spec.right != .none) {
        if (hori_has_double) {
            const y1 = mid_y - double_offset - light_half;
            const y2 = mid_y + double_offset - light_half;
            const h_thick = m.light_thickness;

            const left_x = m.x;
            const right_x = m.x + m.width;

            var mid_left_end = mid_x;
            var mid_right_start = mid_x;

            if (vert_has_double) {
                mid_left_end = mid_x - double_offset - light_half;
                mid_right_start = mid_x + double_offset + light_half;
            } else if (spec.up != .none or spec.down != .none) {
                const vert_half = if (spec.up == .heavy or spec.down == .heavy) heavy_half else light_half;
                mid_left_end = mid_x - vert_half;
                mid_right_start = mid_x + vert_half;
            }

            if (spec.left == .double) {
                const r1 = c.SDL_FRect{ .x = left_x, .y = y1, .w = mid_left_end - left_x, .h = h_thick };
                const r2 = c.SDL_FRect{ .x = left_x, .y = y2, .w = mid_left_end - left_x, .h = h_thick };
                _ = c.SDL_RenderFillRect(renderer, &r1);
                _ = c.SDL_RenderFillRect(renderer, &r2);
            } else if (spec.left != .none) {
                const half = if (spec.left == .heavy) heavy_half else light_half;
                const thick = if (spec.left == .heavy) m.heavy_thickness else m.light_thickness;
                const r = c.SDL_FRect{ .x = left_x, .y = mid_y - half, .w = mid_x - left_x, .h = thick };
                _ = c.SDL_RenderFillRect(renderer, &r);
            }

            if (spec.right == .double) {
                const r1 = c.SDL_FRect{ .x = mid_right_start, .y = y1, .w = right_x - mid_right_start, .h = h_thick };
                const r2 = c.SDL_FRect{ .x = mid_right_start, .y = y2, .w = right_x - mid_right_start, .h = h_thick };
                _ = c.SDL_RenderFillRect(renderer, &r1);
                _ = c.SDL_RenderFillRect(renderer, &r2);
            } else if (spec.right != .none) {
                const half = if (spec.right == .heavy) heavy_half else light_half;
                const thick = if (spec.right == .heavy) m.heavy_thickness else m.light_thickness;
                const r = c.SDL_FRect{ .x = mid_x, .y = mid_y - half, .w = right_x - mid_x, .h = thick };
                _ = c.SDL_RenderFillRect(renderer, &r);
            }
        } else {
            const left_weight = spec.left;
            const right_weight = spec.right;
            const mixed_weight = (left_weight == .light and right_weight == .heavy) or
                (left_weight == .heavy and right_weight == .light);

            if (mixed_weight) {
                const left_half = if (left_weight == .heavy) heavy_half else light_half;
                const left_thick = if (left_weight == .heavy) m.heavy_thickness else m.light_thickness;
                const right_half = if (right_weight == .heavy) heavy_half else light_half;
                const right_thick = if (right_weight == .heavy) m.heavy_thickness else m.light_thickness;

                var left_x = m.x;
                var right_x = m.x + m.width;
                if (left_weight == .none) left_x = mid_x;
                if (right_weight == .none) right_x = mid_x;

                if (left_weight != .none) {
                    const r = c.SDL_FRect{ .x = left_x, .y = mid_y - left_half, .w = mid_x - left_x + left_half, .h = left_thick };
                    _ = c.SDL_RenderFillRect(renderer, &r);
                }
                if (right_weight != .none) {
                    const r = c.SDL_FRect{ .x = mid_x - right_half, .y = mid_y - right_half, .w = right_x - mid_x + right_half, .h = right_thick };
                    _ = c.SDL_RenderFillRect(renderer, &r);
                }
            } else {
                const max_heavy = (left_weight == .heavy or right_weight == .heavy);
                const half = if (max_heavy) heavy_half else light_half;
                const thick = if (max_heavy) m.heavy_thickness else m.light_thickness;

                var left_x = m.x;
                var right_x = m.x + m.width;

                if (spec.left == .none) left_x = mid_x - half;
                if (spec.right == .none) right_x = mid_x + half;

                const r = c.SDL_FRect{ .x = left_x, .y = mid_y - half, .w = right_x - left_x, .h = thick };
                _ = c.SDL_RenderFillRect(renderer, &r);
            }
        }
    }

    if (spec.up != .none or spec.down != .none) {
        if (vert_has_double) {
            const x1 = mid_x - double_offset - light_half;
            const x2 = mid_x + double_offset - light_half;
            const w_thick = m.light_thickness;

            const top_y = m.y;
            const bottom_y = m.y + m.height;

            var mid_top_end = mid_y;
            var mid_bottom_start = mid_y;

            if (hori_has_double) {
                mid_top_end = mid_y - double_offset - light_half;
                mid_bottom_start = mid_y + double_offset + light_half;
            } else if (spec.left != .none or spec.right != .none) {
                const hori_half = if (spec.left == .heavy or spec.right == .heavy) heavy_half else light_half;
                mid_top_end = mid_y - hori_half;
                mid_bottom_start = mid_y + hori_half;
            }

            if (spec.up == .double) {
                const r1 = c.SDL_FRect{ .x = x1, .y = top_y, .w = w_thick, .h = mid_top_end - top_y };
                const r2 = c.SDL_FRect{ .x = x2, .y = top_y, .w = w_thick, .h = mid_top_end - top_y };
                _ = c.SDL_RenderFillRect(renderer, &r1);
                _ = c.SDL_RenderFillRect(renderer, &r2);
            } else if (spec.up != .none) {
                const half = if (spec.up == .heavy) heavy_half else light_half;
                const thick = if (spec.up == .heavy) m.heavy_thickness else m.light_thickness;
                const r = c.SDL_FRect{ .x = mid_x - half, .y = top_y, .w = thick, .h = mid_y - top_y };
                _ = c.SDL_RenderFillRect(renderer, &r);
            }

            if (spec.down == .double) {
                const r1 = c.SDL_FRect{ .x = x1, .y = mid_bottom_start, .w = w_thick, .h = bottom_y - mid_bottom_start };
                const r2 = c.SDL_FRect{ .x = x2, .y = mid_bottom_start, .w = w_thick, .h = bottom_y - mid_bottom_start };
                _ = c.SDL_RenderFillRect(renderer, &r1);
                _ = c.SDL_RenderFillRect(renderer, &r2);
            } else if (spec.down != .none) {
                const half = if (spec.down == .heavy) heavy_half else light_half;
                const thick = if (spec.down == .heavy) m.heavy_thickness else m.light_thickness;
                const r = c.SDL_FRect{ .x = mid_x - half, .y = mid_y, .w = thick, .h = bottom_y - mid_y };
                _ = c.SDL_RenderFillRect(renderer, &r);
            }
        } else {
            const up_weight = spec.up;
            const down_weight = spec.down;
            const mixed_weight = (up_weight == .light and down_weight == .heavy) or
                (up_weight == .heavy and down_weight == .light);

            if (mixed_weight) {
                const up_half = if (up_weight == .heavy) heavy_half else light_half;
                const up_thick = if (up_weight == .heavy) m.heavy_thickness else m.light_thickness;
                const down_half = if (down_weight == .heavy) heavy_half else light_half;
                const down_thick = if (down_weight == .heavy) m.heavy_thickness else m.light_thickness;

                var top_y = m.y;
                var bottom_y = m.y + m.height;
                if (up_weight == .none) top_y = mid_y;
                if (down_weight == .none) bottom_y = mid_y;

                if (up_weight != .none) {
                    const r = c.SDL_FRect{ .x = mid_x - up_half, .y = top_y, .w = up_thick, .h = mid_y - top_y + up_half };
                    _ = c.SDL_RenderFillRect(renderer, &r);
                }
                if (down_weight != .none) {
                    const r = c.SDL_FRect{ .x = mid_x - down_half, .y = mid_y - down_half, .w = down_thick, .h = bottom_y - mid_y + down_half };
                    _ = c.SDL_RenderFillRect(renderer, &r);
                }
            } else {
                const max_heavy = (up_weight == .heavy or down_weight == .heavy);
                const half = if (max_heavy) heavy_half else light_half;
                const thick = if (max_heavy) m.heavy_thickness else m.light_thickness;

                var top_y = m.y;
                var bottom_y = m.y + m.height;

                if (spec.up == .none) top_y = mid_y - half;
                if (spec.down == .none) bottom_y = mid_y + half;

                const r = c.SDL_FRect{ .x = mid_x - half, .y = top_y, .w = thick, .h = bottom_y - top_y };
                _ = c.SDL_RenderFillRect(renderer, &r);
            }
        }
    }
}

fn renderDashedLines(renderer: *c.SDL_Renderer, m: Metrics, spec: BoxSpec) void {
    const mid_x = m.x + m.width * 0.5;
    const mid_y = m.y + m.height * 0.5;

    const is_horizontal = (spec.left != .none or spec.right != .none);
    const is_heavy = (spec.left == .heavy or spec.right == .heavy or spec.up == .heavy or spec.down == .heavy);
    const thickness = if (is_heavy) m.heavy_thickness else m.light_thickness;
    const half = thickness * 0.5;
    const dashes = spec.dashes;

    if (is_horizontal) {
        const total_len = m.width;
        const dash_len = total_len / @as(f32, @floatFromInt(dashes * 2 - 1));
        var i: u4 = 0;
        while (i < dashes) : (i += 1) {
            const start_x = m.x + @as(f32, @floatFromInt(i * 2)) * dash_len;
            const r = c.SDL_FRect{ .x = start_x, .y = mid_y - half, .w = dash_len, .h = thickness };
            _ = c.SDL_RenderFillRect(renderer, &r);
        }
    } else {
        const total_len = m.height;
        const dash_len = total_len / @as(f32, @floatFromInt(dashes * 2 - 1));
        var i: u4 = 0;
        while (i < dashes) : (i += 1) {
            const start_y = m.y + @as(f32, @floatFromInt(i * 2)) * dash_len;
            const r = c.SDL_FRect{ .x = mid_x - half, .y = start_y, .w = thickness, .h = dash_len };
            _ = c.SDL_RenderFillRect(renderer, &r);
        }
    }
}

fn renderRoundedCorner(renderer: *c.SDL_Renderer, m: Metrics, spec: BoxSpec, color: c.SDL_Color) void {
    const mid_x = m.x + m.width * 0.5;
    const mid_y = m.y + m.height * 0.5;
    const thickness = m.light_thickness;
    const half = thickness * 0.5;

    const radius = @min(m.width, m.height) * 0.5;
    if (radius <= half) {
        renderLines(renderer, m, spec);
        return;
    }

    const has_right = (spec.right != .none);
    const has_left = (spec.left != .none);
    const has_up = (spec.up != .none);
    const has_down = (spec.down != .none);

    var start_angle: f32 = undefined;
    var horiz_start: f32 = undefined;
    var horiz_end: f32 = undefined;
    var vert_start: f32 = undefined;
    var vert_end: f32 = undefined;
    var sx: f32 = undefined;
    var sy: f32 = undefined;

    if (has_right and has_down) {
        start_angle = 0;
        horiz_start = mid_x + radius;
        horiz_end = m.x + m.width;
        vert_start = mid_y + radius;
        vert_end = m.y + m.height;
        sx = 1.0;
        sy = 1.0;
    } else if (has_left and has_down) {
        start_angle = std.math.pi * 0.5;
        horiz_start = m.x;
        horiz_end = mid_x - radius;
        vert_start = mid_y + radius;
        vert_end = m.y + m.height;
        sx = -1.0;
        sy = 1.0;
    } else if (has_left and has_up) {
        start_angle = std.math.pi;
        horiz_start = m.x;
        horiz_end = mid_x - radius;
        vert_start = m.y;
        vert_end = mid_y - radius;
        sx = -1.0;
        sy = -1.0;
    } else if (has_right and has_up) {
        start_angle = std.math.pi * 1.5;
        horiz_start = mid_x + radius;
        horiz_end = m.x + m.width;
        vert_start = m.y;
        vert_end = mid_y - radius;
        sx = 1.0;
        sy = -1.0;
    } else {
        return;
    }

    if (horiz_end > horiz_start) {
        const hori_r = c.SDL_FRect{ .x = horiz_start, .y = mid_y - half, .w = horiz_end - horiz_start, .h = thickness };
        _ = c.SDL_RenderFillRect(renderer, &hori_r);
    }
    if (vert_end > vert_start) {
        const vert_r = c.SDL_FRect{ .x = mid_x - half, .y = vert_start, .w = thickness, .h = vert_end - vert_start };
        _ = c.SDL_RenderFillRect(renderer, &vert_r);
    }

    drawBezierCorner(renderer, mid_x, mid_y, radius, sx, sy, thickness, color);
}

const CornerPoint = struct {
    x: f32,
    y: f32,
};

fn drawBezierCorner(
    renderer: *c.SDL_Renderer,
    mid_x: f32,
    mid_y: f32,
    radius: f32,
    sx: f32,
    sy: f32,
    thickness: f32,
    color: c.SDL_Color,
) void {
    const bezier_control_factor: f32 = 0.25;
    const p0 = CornerPoint{ .x = mid_x, .y = mid_y + sy * radius };
    const p1 = CornerPoint{ .x = mid_x, .y = mid_y + sy * bezier_control_factor * radius };
    const p2 = CornerPoint{ .x = mid_x + sx * bezier_control_factor * radius, .y = mid_y };
    const p3 = CornerPoint{ .x = mid_x + sx * radius, .y = mid_y };
    const segments: usize = 12;

    var prev = p0;
    var i: usize = 1;
    while (i <= segments) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const u = 1.0 - t;
        const tt = t * t;
        const uu = u * u;
        const uuu = uu * u;
        const ttt = tt * t;

        const x = uuu * p0.x + 3.0 * uu * t * p1.x + 3.0 * u * tt * p2.x + ttt * p3.x;
        const y = uuu * p0.y + 3.0 * uu * t * p1.y + 3.0 * u * tt * p2.y + ttt * p3.y;
        drawThickLine(renderer, prev.x, prev.y, x, y, thickness, color);
        prev = .{ .x = x, .y = y };
    }
}

fn renderDiagonals(renderer: *c.SDL_Renderer, m: Metrics, spec: BoxSpec, color: c.SDL_Color) void {
    const thickness = m.light_thickness;

    if (spec.diagonal_down) {
        const start_x = m.x;
        const start_y = m.y;
        const end_x = m.x + m.width;
        const end_y = m.y + m.height;
        drawThickLine(renderer, start_x, start_y, end_x, end_y, thickness, color);
    }

    if (spec.diagonal_up) {
        const start_x = m.x;
        const start_y = m.y + m.height;
        const end_x = m.x + m.width;
        const end_y = m.y;
        drawThickLine(renderer, start_x, start_y, end_x, end_y, thickness, color);
    }
}

fn drawThickLine(renderer: *c.SDL_Renderer, x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32, color: c.SDL_Color) void {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;

    const nx = -dy / len * thickness * 0.5;
    const ny = dx / len * thickness * 0.5;

    const r: f32 = @as(f32, @floatFromInt(color.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(color.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(color.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;

    const verts = [_]c.SDL_Vertex{
        .{ .position = .{ .x = x1 + nx, .y = y1 + ny }, .color = .{ .r = r, .g = g, .b = b, .a = a }, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = x1 - nx, .y = y1 - ny }, .color = .{ .r = r, .g = g, .b = b, .a = a }, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = x2 + nx, .y = y2 + ny }, .color = .{ .r = r, .g = g, .b = b, .a = a }, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = x2 - nx, .y = y2 - ny }, .color = .{ .r = r, .g = g, .b = b, .a = a }, .tex_coord = .{ .x = 0, .y = 0 } },
    };

    const indices = [_]c_int{ 0, 1, 2, 1, 3, 2 };
    _ = c.SDL_RenderGeometry(renderer, null, &verts, 4, &indices, 6);
}

const box_specs: [128]BoxSpec = specs: {
    var arr: [128]BoxSpec = [_]BoxSpec{.{}} ** 128;

    arr[0x00] = .{ .left = .light, .right = .light }; // ─
    arr[0x01] = .{ .left = .heavy, .right = .heavy }; // ━
    arr[0x02] = .{ .up = .light, .down = .light }; // │
    arr[0x03] = .{ .up = .heavy, .down = .heavy }; // ┃

    arr[0x04] = .{ .left = .light, .right = .light, .dashes = 3 }; // ┄
    arr[0x05] = .{ .left = .heavy, .right = .heavy, .dashes = 3 }; // ┅
    arr[0x06] = .{ .up = .light, .down = .light, .dashes = 3 }; // ┆
    arr[0x07] = .{ .up = .heavy, .down = .heavy, .dashes = 3 }; // ┇
    arr[0x08] = .{ .left = .light, .right = .light, .dashes = 4 }; // ┈
    arr[0x09] = .{ .left = .heavy, .right = .heavy, .dashes = 4 }; // ┉
    arr[0x0A] = .{ .up = .light, .down = .light, .dashes = 4 }; // ┊
    arr[0x0B] = .{ .up = .heavy, .down = .heavy, .dashes = 4 }; // ┋

    arr[0x0C] = .{ .right = .light, .down = .light }; // ┌
    arr[0x0D] = .{ .right = .light, .down = .heavy }; // ┍
    arr[0x0E] = .{ .right = .heavy, .down = .light }; // ┎
    arr[0x0F] = .{ .right = .heavy, .down = .heavy }; // ┏

    arr[0x10] = .{ .left = .light, .down = .light }; // ┐
    arr[0x11] = .{ .left = .light, .down = .heavy }; // ┑
    arr[0x12] = .{ .left = .heavy, .down = .light }; // ┒
    arr[0x13] = .{ .left = .heavy, .down = .heavy }; // ┓

    arr[0x14] = .{ .right = .light, .up = .light }; // └
    arr[0x15] = .{ .right = .light, .up = .heavy }; // ┕
    arr[0x16] = .{ .right = .heavy, .up = .light }; // ┖
    arr[0x17] = .{ .right = .heavy, .up = .heavy }; // ┗

    arr[0x18] = .{ .left = .light, .up = .light }; // ┘
    arr[0x19] = .{ .left = .light, .up = .heavy }; // ┙
    arr[0x1A] = .{ .left = .heavy, .up = .light }; // ┚
    arr[0x1B] = .{ .left = .heavy, .up = .heavy }; // ┛

    arr[0x1C] = .{ .up = .light, .down = .light, .right = .light }; // ├
    arr[0x1D] = .{ .up = .light, .down = .heavy, .right = .light }; // ┝
    arr[0x1E] = .{ .up = .heavy, .down = .light, .right = .light }; // ┞
    arr[0x1F] = .{ .up = .heavy, .down = .heavy, .right = .light }; // ┟
    arr[0x20] = .{ .up = .light, .down = .light, .right = .heavy }; // ┠
    arr[0x21] = .{ .up = .light, .down = .heavy, .right = .heavy }; // ┡
    arr[0x22] = .{ .up = .heavy, .down = .light, .right = .heavy }; // ┢
    arr[0x23] = .{ .up = .heavy, .down = .heavy, .right = .heavy }; // ┣

    arr[0x24] = .{ .up = .light, .down = .light, .left = .light }; // ┤
    arr[0x25] = .{ .up = .light, .down = .heavy, .left = .light }; // ┥
    arr[0x26] = .{ .up = .heavy, .down = .light, .left = .light }; // ┦
    arr[0x27] = .{ .up = .heavy, .down = .heavy, .left = .light }; // ┧
    arr[0x28] = .{ .up = .light, .down = .light, .left = .heavy }; // ┨
    arr[0x29] = .{ .up = .light, .down = .heavy, .left = .heavy }; // ┩
    arr[0x2A] = .{ .up = .heavy, .down = .light, .left = .heavy }; // ┪
    arr[0x2B] = .{ .up = .heavy, .down = .heavy, .left = .heavy }; // ┫

    arr[0x2C] = .{ .left = .light, .right = .light, .down = .light }; // ┬
    arr[0x2D] = .{ .left = .light, .right = .heavy, .down = .light }; // ┭
    arr[0x2E] = .{ .left = .heavy, .right = .light, .down = .light }; // ┮
    arr[0x2F] = .{ .left = .heavy, .right = .heavy, .down = .light }; // ┯
    arr[0x30] = .{ .left = .light, .right = .light, .down = .heavy }; // ┰
    arr[0x31] = .{ .left = .light, .right = .heavy, .down = .heavy }; // ┱
    arr[0x32] = .{ .left = .heavy, .right = .light, .down = .heavy }; // ┲
    arr[0x33] = .{ .left = .heavy, .right = .heavy, .down = .heavy }; // ┳

    arr[0x34] = .{ .left = .light, .right = .light, .up = .light }; // ┴
    arr[0x35] = .{ .left = .light, .right = .heavy, .up = .light }; // ┵
    arr[0x36] = .{ .left = .heavy, .right = .light, .up = .light }; // ┶
    arr[0x37] = .{ .left = .heavy, .right = .heavy, .up = .light }; // ┷
    arr[0x38] = .{ .left = .light, .right = .light, .up = .heavy }; // ┸
    arr[0x39] = .{ .left = .light, .right = .heavy, .up = .heavy }; // ┹
    arr[0x3A] = .{ .left = .heavy, .right = .light, .up = .heavy }; // ┺
    arr[0x3B] = .{ .left = .heavy, .right = .heavy, .up = .heavy }; // ┻

    arr[0x3C] = .{ .left = .light, .right = .light, .up = .light, .down = .light }; // ┼
    arr[0x3D] = .{ .left = .light, .right = .heavy, .up = .light, .down = .light }; // ┽
    arr[0x3E] = .{ .left = .heavy, .right = .light, .up = .light, .down = .light }; // ┾
    arr[0x3F] = .{ .left = .heavy, .right = .heavy, .up = .light, .down = .light }; // ┿

    arr[0x40] = .{ .left = .light, .right = .light, .up = .light, .down = .heavy }; // ╀
    arr[0x41] = .{ .left = .light, .right = .light, .up = .heavy, .down = .light }; // ╁
    arr[0x42] = .{ .left = .light, .right = .light, .up = .heavy, .down = .heavy }; // ╂
    arr[0x43] = .{ .left = .light, .right = .heavy, .up = .light, .down = .heavy }; // ╃
    arr[0x44] = .{ .left = .heavy, .right = .light, .up = .light, .down = .heavy }; // ╄
    arr[0x45] = .{ .left = .light, .right = .heavy, .up = .heavy, .down = .light }; // ╅
    arr[0x46] = .{ .left = .heavy, .right = .light, .up = .heavy, .down = .light }; // ╆
    arr[0x47] = .{ .left = .heavy, .right = .heavy, .up = .light, .down = .heavy }; // ╇
    arr[0x48] = .{ .left = .heavy, .right = .heavy, .up = .heavy, .down = .light }; // ╈
    arr[0x49] = .{ .left = .light, .right = .heavy, .up = .heavy, .down = .heavy }; // ╉
    arr[0x4A] = .{ .left = .heavy, .right = .light, .up = .heavy, .down = .heavy }; // ╊
    arr[0x4B] = .{ .left = .heavy, .right = .heavy, .up = .heavy, .down = .heavy }; // ╋

    arr[0x4C] = .{ .left = .light, .right = .light, .dashes = 2 }; // ╌
    arr[0x4D] = .{ .left = .heavy, .right = .heavy, .dashes = 2 }; // ╍
    arr[0x4E] = .{ .up = .light, .down = .light, .dashes = 2 }; // ╎
    arr[0x4F] = .{ .up = .heavy, .down = .heavy, .dashes = 2 }; // ╏

    arr[0x50] = .{ .left = .double, .right = .double }; // ═
    arr[0x51] = .{ .up = .double, .down = .double }; // ║
    arr[0x52] = .{ .right = .double, .down = .light }; // ╒
    arr[0x53] = .{ .right = .light, .down = .double }; // ╓
    arr[0x54] = .{ .right = .double, .down = .double }; // ╔
    arr[0x55] = .{ .left = .double, .down = .light }; // ╕
    arr[0x56] = .{ .left = .light, .down = .double }; // ╖
    arr[0x57] = .{ .left = .double, .down = .double }; // ╗
    arr[0x58] = .{ .right = .double, .up = .light }; // ╘
    arr[0x59] = .{ .right = .light, .up = .double }; // ╙
    arr[0x5A] = .{ .right = .double, .up = .double }; // ╚
    arr[0x5B] = .{ .left = .double, .up = .light }; // ╛
    arr[0x5C] = .{ .left = .light, .up = .double }; // ╜
    arr[0x5D] = .{ .left = .double, .up = .double }; // ╝
    arr[0x5E] = .{ .up = .double, .down = .double, .right = .light }; // ╞
    arr[0x5F] = .{ .up = .light, .down = .light, .right = .double }; // ╟
    arr[0x60] = .{ .up = .double, .down = .double, .right = .double }; // ╠
    arr[0x61] = .{ .up = .double, .down = .double, .left = .light }; // ╡
    arr[0x62] = .{ .up = .light, .down = .light, .left = .double }; // ╢
    arr[0x63] = .{ .up = .double, .down = .double, .left = .double }; // ╣
    arr[0x64] = .{ .left = .double, .right = .double, .down = .light }; // ╤
    arr[0x65] = .{ .left = .light, .right = .light, .down = .double }; // ╥
    arr[0x66] = .{ .left = .double, .right = .double, .down = .double }; // ╦
    arr[0x67] = .{ .left = .double, .right = .double, .up = .light }; // ╧
    arr[0x68] = .{ .left = .light, .right = .light, .up = .double }; // ╨
    arr[0x69] = .{ .left = .double, .right = .double, .up = .double }; // ╩
    arr[0x6A] = .{ .left = .double, .right = .double, .up = .light, .down = .light }; // ╪
    arr[0x6B] = .{ .left = .light, .right = .light, .up = .double, .down = .double }; // ╫
    arr[0x6C] = .{ .left = .double, .right = .double, .up = .double, .down = .double }; // ╬

    arr[0x6D] = .{ .right = .light, .down = .light, .rounded = true }; // ╭
    arr[0x6E] = .{ .left = .light, .down = .light, .rounded = true }; // ╮
    arr[0x6F] = .{ .left = .light, .up = .light, .rounded = true }; // ╯
    arr[0x70] = .{ .right = .light, .up = .light, .rounded = true }; // ╰

    arr[0x71] = .{ .diagonal_up = true }; // ╱
    arr[0x72] = .{ .diagonal_down = true }; // ╲
    arr[0x73] = .{ .diagonal_down = true, .diagonal_up = true }; // ╳

    arr[0x74] = .{ .left = .light }; // ╴
    arr[0x75] = .{ .up = .light }; // ╵
    arr[0x76] = .{ .right = .light }; // ╶
    arr[0x77] = .{ .down = .light }; // ╷
    arr[0x78] = .{ .left = .heavy }; // ╸
    arr[0x79] = .{ .up = .heavy }; // ╹
    arr[0x7A] = .{ .right = .heavy }; // ╺
    arr[0x7B] = .{ .down = .heavy }; // ╻
    arr[0x7C] = .{ .left = .light, .right = .heavy }; // ╼
    arr[0x7D] = .{ .up = .light, .down = .heavy }; // ╽
    arr[0x7E] = .{ .left = .heavy, .right = .light }; // ╾
    arr[0x7F] = .{ .up = .heavy, .down = .light }; // ╿

    break :specs arr;
};
