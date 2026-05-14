const dpi = @import("../../dpi.zig");

pub const height: c_int = 24;
pub const font_size: c_int = 12;
pub const padding: c_int = 8;

pub fn reservedHeight(ui_scale: f32, border_thickness: c_int) c_int {
    return dpi.scale(height, ui_scale) + dpi.scale(border_thickness, ui_scale);
}

pub fn minCellHeight(ui_scale: f32, border_thickness: c_int) c_int {
    return reservedHeight(ui_scale, border_thickness) + 1;
}
