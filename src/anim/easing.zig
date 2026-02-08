pub fn easeInOutCubic(t: f32) f32 {
    if (t < 0.5) {
        return 4 * t * t * t;
    }

    const p = 2 * t - 2;
    return 1 + p * p * p / 2;
}

pub fn easeOutCubic(t: f32) f32 {
    const p = t - 1.0;
    return 1.0 + p * p * p;
}
