const std = @import("std");

/// Scale an integer length from logical points to physical pixels using ui_scale.
/// Returns at least 1 to avoid zero-sized UI elements on tiny scales.
pub fn scale(value: c_int, ui_scale: f32) c_int {
    return @max(1, @as(c_int, @intFromFloat(std.math.round(@as(f32, @floatFromInt(value)) * ui_scale))));
}
