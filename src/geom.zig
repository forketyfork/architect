pub const Rect = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub fn containsPoint(r: Rect, x: c_int, y: c_int) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}
