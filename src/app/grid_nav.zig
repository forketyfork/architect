const app_state = @import("app_state.zig");
const input = @import("../input/mapper.zig");
const session_state = @import("../session/state.zig");
const ui_mod = @import("../ui/mod.zig");
const xev = @import("xev");

const AnimationState = app_state.AnimationState;
const Rect = app_state.Rect;
const SessionState = session_state.SessionState;
const ViewMode = app_state.ViewMode;

pub fn startCollapseToGrid(
    anim_state: *AnimationState,
    now: i64,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    render_width: c_int,
    render_height: c_int,
    grid_cols: usize,
) void {
    const grid_row: c_int = @intCast(anim_state.focused_session / grid_cols);
    const grid_col: c_int = @intCast(anim_state.focused_session % grid_cols);
    const target_rect = Rect{
        .x = grid_col * cell_width_pixels,
        .y = grid_row * cell_height_pixels,
        .w = cell_width_pixels,
        .h = cell_height_pixels,
    };

    anim_state.mode = .Collapsing;
    anim_state.start_time = now;
    anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };
    anim_state.target_rect = target_rect;
}

pub fn gridNotificationBufferSize(grid_cols: usize, grid_rows: usize) usize {
    const block_bytes = 3;
    const spaces_between_cols = 3;
    return grid_rows * grid_cols * block_bytes + grid_rows * (grid_cols - 1) * spaces_between_cols + (grid_rows - 1);
}

pub fn formatGridNotification(buf: []u8, focused_session: usize, grid_cols: usize, grid_rows: usize) ![]const u8 {
    const row = focused_session / grid_cols;
    const col = focused_session % grid_cols;

    var offset: usize = 0;
    for (0..grid_rows) |r| {
        for (0..grid_cols) |col_idx| {
            const block = if (r == row and col_idx == col) "■" else "□";
            if (offset + block.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[offset..][0..block.len], block);
            offset += block.len;

            if (col_idx < grid_cols - 1) {
                const spaces_between_cols = 3;
                if (offset + spaces_between_cols > buf.len) return error.BufferTooSmall;
                buf[offset] = ' ';
                offset += 1;
                buf[offset] = ' ';
                offset += 1;
                buf[offset] = ' ';
                offset += 1;
            }
        }
        if (r < grid_rows - 1) {
            if (offset + 1 > buf.len) return error.BufferTooSmall;
            buf[offset] = '\n';
            offset += 1;
        }
    }
    return buf[0..offset];
}

pub fn navigateGrid(
    anim_state: *AnimationState,
    sessions: []*SessionState,
    session_interaction: *ui_mod.SessionInteractionComponent,
    direction: input.GridNavDirection,
    now: i64,
    enable_wrapping: bool,
    show_animation: bool,
    grid_cols: usize,
    grid_rows: usize,
    loop: *xev.Loop,
) !void {
    const current_row: usize = anim_state.focused_session / grid_cols;
    const current_col: usize = anim_state.focused_session % grid_cols;
    var new_row: usize = current_row;
    var new_col: usize = current_col;
    var animation_mode: ?ViewMode = null;
    var is_wrapping = false;

    const current_session = anim_state.focused_session;

    switch (direction) {
        .up => {
            if (current_row > 0) {
                new_row = current_row - 1;
            } else if (enable_wrapping) {
                new_row = grid_rows - 1;
                is_wrapping = true;
            }
            if (show_animation and new_row != current_row) {
                animation_mode = if (is_wrapping) .PanningUp else .PanningDown;
            }
        },
        .down => {
            if (current_row < grid_rows - 1) {
                new_row = current_row + 1;
            } else if (enable_wrapping) {
                new_row = 0;
                is_wrapping = true;
            }
            if (show_animation and new_row != current_row) {
                animation_mode = if (is_wrapping) .PanningDown else .PanningUp;
            }
        },
        .left => {
            if (current_col > 0) {
                new_col = current_col - 1;
            } else if (enable_wrapping) {
                new_col = grid_cols - 1;
                is_wrapping = true;
            }
            if (show_animation and new_col != current_col) {
                animation_mode = if (is_wrapping) .PanningLeft else .PanningRight;
            }
        },
        .right => {
            if (current_col < grid_cols - 1) {
                new_col = current_col + 1;
            } else if (enable_wrapping) {
                new_col = 0;
                is_wrapping = true;
            }
            if (show_animation and new_col != current_col) {
                animation_mode = if (is_wrapping) .PanningRight else .PanningLeft;
            }
        },
    }

    var new_session: usize = new_row * grid_cols + new_col;
    if (direction == .down and new_row > current_row and new_session < sessions.len and !sessions[new_session].spawned) {
        var col_idx: usize = grid_cols;
        while (col_idx > 0) {
            col_idx -= 1;
            const candidate = new_row * grid_cols + col_idx;
            if (candidate >= sessions.len) continue;
            if (sessions[candidate].spawned) {
                new_col = col_idx;
                new_session = candidate;
                break;
            }
        }
    }

    if (direction == .right and new_row == current_row and new_col > current_col and new_session < sessions.len and !sessions[new_session].spawned) {
        new_session = current_session;
        var col_idx: usize = 0;
        while (col_idx < grid_cols) : (col_idx += 1) {
            const candidate = new_row * grid_cols + col_idx;
            if (candidate >= sessions.len) break;
            if (sessions[candidate].spawned) {
                new_col = col_idx;
                new_session = candidate;
                break;
            }
        }
    }

    if (direction == .left and is_wrapping and new_session < sessions.len and !sessions[new_session].spawned) {
        var col_idx: usize = grid_cols;
        while (col_idx > 0) {
            col_idx -= 1;
            const candidate = new_row * grid_cols + col_idx;
            if (candidate >= sessions.len) continue;
            if (sessions[candidate].spawned) {
                new_col = col_idx;
                new_session = candidate;
                break;
            }
        }
    }

    if (direction == .up and is_wrapping and new_session < sessions.len and !sessions[new_session].spawned) {
        var col_idx: usize = grid_cols;
        while (col_idx > 0) {
            col_idx -= 1;
            const candidate = new_row * grid_cols + col_idx;
            if (candidate >= sessions.len) continue;
            if (sessions[candidate].spawned) {
                new_col = col_idx;
                new_session = candidate;
                break;
            }
        }
    }

    if (new_session != current_session) {
        if (anim_state.mode == .Full) {
            try sessions[new_session].ensureSpawnedWithLoop(loop);
        } else if (show_animation) {
            try sessions[new_session].ensureSpawnedWithLoop(loop);
        }
        session_interaction.clearSelection(current_session);
        session_interaction.clearSelection(new_session);

        if (animation_mode) |mode| {
            anim_state.mode = mode;
            anim_state.previous_session = current_session;
            anim_state.focused_session = new_session;
            anim_state.start_time = now;
        } else {
            anim_state.focused_session = new_session;
        }
    }
}
