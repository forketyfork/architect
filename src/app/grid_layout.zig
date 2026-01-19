// Dynamic grid layout management for the terminal wall.
// Handles automatic grid expansion/contraction as terminals are added/removed.
const std = @import("std");
const geom = @import("../geom.zig");
const easing = @import("../anim/easing.zig");

const Rect = geom.Rect;

pub const MAX_GRID_SIZE: usize = 12;
pub const MAX_TERMINALS: usize = MAX_GRID_SIZE * MAX_GRID_SIZE;

/// Represents a position in the grid (column, row).
pub const GridPosition = struct {
    col: usize,
    row: usize,

    pub fn toIndex(self: GridPosition, cols: usize) usize {
        return self.row * cols + self.col;
    }

    pub fn fromIndex(idx: usize, cols: usize) GridPosition {
        return .{
            .col = idx % cols,
            .row = idx / cols,
        };
    }
};

/// Animation state for a terminal moving between grid positions.
pub const TerminalAnimation = struct {
    session_idx: usize,
    start_rect: Rect,
    target_rect: Rect,
    start_time: i64,
};

/// Manages dynamic grid dimensions based on active terminal count.
pub const GridLayout = struct {
    cols: usize,
    rows: usize,
    /// Animations for terminals moving during grid resize.
    animations: std.ArrayList(TerminalAnimation),
    /// Timestamp when grid resize animation started.
    resize_start_time: i64,
    /// Previous dimensions before resize (for animation).
    prev_cols: usize,
    prev_rows: usize,
    /// Whether a grid resize animation is in progress.
    is_resizing: bool,

    pub const ANIMATION_DURATION_MS: i64 = 300;

    pub fn init(allocator: std.mem.Allocator) GridLayout {
        return .{
            .cols = 1,
            .rows = 1,
            .animations = std.ArrayList(TerminalAnimation).init(allocator),
            .resize_start_time = 0,
            .prev_cols = 1,
            .prev_rows = 1,
            .is_resizing = false,
        };
    }

    pub fn deinit(self: *GridLayout) void {
        self.animations.deinit();
    }

    /// Calculate optimal grid dimensions for a given terminal count.
    /// Maintains cols >= rows invariant.
    pub fn calculateDimensions(count: usize) struct { cols: usize, rows: usize } {
        if (count == 0) return .{ .cols = 1, .rows = 1 };
        if (count == 1) return .{ .cols = 1, .rows = 1 };
        if (count == 2) return .{ .cols = 2, .rows = 1 };

        // Find smallest grid where cols >= rows and cols * rows >= count
        var rows: usize = 1;
        while (rows <= MAX_GRID_SIZE) : (rows += 1) {
            // Start with square, then try cols = rows + 1
            var cols = rows;
            while (cols <= MAX_GRID_SIZE and cols <= rows + 1) : (cols += 1) {
                if (cols * rows >= count) {
                    return .{ .cols = cols, .rows = rows };
                }
            }
        }

        return .{ .cols = MAX_GRID_SIZE, .rows = MAX_GRID_SIZE };
    }

    /// Returns the total capacity of the current grid.
    pub fn capacity(self: *const GridLayout) usize {
        return self.cols * self.rows;
    }

    /// Check if the grid needs to expand to fit one more terminal.
    pub fn needsExpansion(self: *const GridLayout, active_count: usize) bool {
        return active_count >= self.capacity();
    }

    /// Check if the grid can shrink after removing a terminal.
    pub fn canShrink(self: *const GridLayout, active_count: usize) bool {
        if (active_count == 0) return self.cols > 1 or self.rows > 1;
        const optimal = calculateDimensions(active_count);
        return optimal.cols < self.cols or optimal.rows < self.rows;
    }

    /// Convert session index to grid position.
    pub fn indexToPosition(self: *const GridLayout, idx: usize) GridPosition {
        return GridPosition.fromIndex(idx, self.cols);
    }

    /// Convert grid position to session index.
    pub fn positionToIndex(self: *const GridLayout, pos: GridPosition) usize {
        return pos.toIndex(self.cols);
    }

    /// Calculate pixel rect for a grid cell.
    pub fn cellRect(
        self: *const GridLayout,
        pos: GridPosition,
        render_width: c_int,
        render_height: c_int,
    ) Rect {
        const cell_w = @divFloor(render_width, @as(c_int, @intCast(self.cols)));
        const cell_h = @divFloor(render_height, @as(c_int, @intCast(self.rows)));
        return Rect{
            .x = @as(c_int, @intCast(pos.col)) * cell_w,
            .y = @as(c_int, @intCast(pos.row)) * cell_h,
            .w = cell_w,
            .h = cell_h,
        };
    }

    /// Start a grid resize animation.
    pub fn startResize(
        self: *GridLayout,
        new_cols: usize,
        new_rows: usize,
        now: i64,
        render_width: c_int,
        render_height: c_int,
        active_sessions: []const usize,
    ) !void {
        self.animations.clearRetainingCapacity();
        self.prev_cols = self.cols;
        self.prev_rows = self.rows;
        self.resize_start_time = now;

        // Calculate where each active session will move from/to
        const old_cell_w = @divFloor(render_width, @as(c_int, @intCast(self.cols)));
        const old_cell_h = @divFloor(render_height, @as(c_int, @intCast(self.rows)));
        const new_cell_w = @divFloor(render_width, @as(c_int, @intCast(new_cols)));
        const new_cell_h = @divFloor(render_height, @as(c_int, @intCast(new_rows)));

        for (active_sessions, 0..) |session_idx, new_logical_idx| {
            const old_pos = GridPosition.fromIndex(session_idx, self.cols);
            const new_pos = GridPosition.fromIndex(new_logical_idx, new_cols);

            const start_rect = Rect{
                .x = @as(c_int, @intCast(old_pos.col)) * old_cell_w,
                .y = @as(c_int, @intCast(old_pos.row)) * old_cell_h,
                .w = old_cell_w,
                .h = old_cell_h,
            };

            const target_rect = Rect{
                .x = @as(c_int, @intCast(new_pos.col)) * new_cell_w,
                .y = @as(c_int, @intCast(new_pos.row)) * new_cell_h,
                .w = new_cell_w,
                .h = new_cell_h,
            };

            try self.animations.append(.{
                .session_idx = session_idx,
                .start_rect = start_rect,
                .target_rect = target_rect,
                .start_time = now,
            });
        }

        self.cols = new_cols;
        self.rows = new_rows;
        self.is_resizing = true;
    }

    /// Update resize animation state. Returns true if animation is complete.
    pub fn updateResize(self: *GridLayout, now: i64) bool {
        if (!self.is_resizing) return true;

        const elapsed = now - self.resize_start_time;
        if (elapsed >= ANIMATION_DURATION_MS) {
            self.is_resizing = false;
            self.animations.clearRetainingCapacity();
            return true;
        }
        return false;
    }

    /// Get the current animated rect for a session during resize.
    pub fn getAnimatedRect(
        self: *const GridLayout,
        session_idx: usize,
        now: i64,
        render_width: c_int,
        render_height: c_int,
    ) ?Rect {
        if (!self.is_resizing) return null;

        for (self.animations.items) |anim| {
            if (anim.session_idx == session_idx) {
                const elapsed = now - anim.start_time;
                const progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, ANIMATION_DURATION_MS));
                const eased = easing.easeInOutCubic(progress);
                return interpolateRect(anim.start_rect, anim.target_rect, eased);
            }
        }

        // Session wasn't in the animation list - it's a new cell
        _ = render_width;
        _ = render_height;
        return null;
    }

    /// Get animation progress (0.0 to 1.0).
    pub fn getResizeProgress(self: *const GridLayout, now: i64) f32 {
        if (!self.is_resizing) return 1.0;
        const elapsed = now - self.resize_start_time;
        return @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, ANIMATION_DURATION_MS));
    }

    fn interpolateRect(start: Rect, target: Rect, progress: f32) Rect {
        return Rect{
            .x = start.x + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.x - start.x)) * progress)),
            .y = start.y + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.y - start.y)) * progress)),
            .w = start.w + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.w - start.w)) * progress)),
            .h = start.h + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(target.h - start.h)) * progress)),
        };
    }
};

test "calculateDimensions" {
    // 0-1 terminals: 1x1
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(0).cols);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(0).rows);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(1).cols);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(1).rows);

    // 2 terminals: 2x1
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(2).cols);
    try std.testing.expectEqual(@as(usize, 1), GridLayout.calculateDimensions(2).rows);

    // 3-4 terminals: 2x2
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(3).cols);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(3).rows);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(4).cols);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(4).rows);

    // 5-6 terminals: 3x2
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(5).cols);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(5).rows);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(6).cols);
    try std.testing.expectEqual(@as(usize, 2), GridLayout.calculateDimensions(6).rows);

    // 7-9 terminals: 3x3
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(7).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(7).rows);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(9).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(9).rows);

    // 10-12 terminals: 4x3
    try std.testing.expectEqual(@as(usize, 4), GridLayout.calculateDimensions(10).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(10).rows);
    try std.testing.expectEqual(@as(usize, 4), GridLayout.calculateDimensions(12).cols);
    try std.testing.expectEqual(@as(usize, 3), GridLayout.calculateDimensions(12).rows);
}

test "GridPosition" {
    const pos = GridPosition{ .col = 2, .row = 1 };
    try std.testing.expectEqual(@as(usize, 5), pos.toIndex(3));

    const pos2 = GridPosition.fromIndex(5, 3);
    try std.testing.expectEqual(@as(usize, 2), pos2.col);
    try std.testing.expectEqual(@as(usize, 1), pos2.row);
}
