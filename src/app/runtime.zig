// Main application entry: wires SDL3 rendering, ghostty-vt terminals, PTY-backed
// shells, and the grid/animation system that drives the 3×3 terminal wall UI.
const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const posix = std.posix;
const app_state = @import("app_state.zig");
const grid_layout = @import("grid_layout.zig");
const grid_nav = @import("grid_nav.zig");
const input_keys = @import("input_keys.zig");
const input_text = @import("input_text.zig");
const layout = @import("layout.zig");
const terminal_actions = @import("terminal_actions.zig");
const ui_host = @import("ui_host.zig");
const worktree = @import("worktree.zig");
const control = @import("control.zig");
const notify = @import("../session/notify.zig");
const session_state = @import("../session/state.zig");
const view_state = @import("../ui/session_view_state.zig");
const platform = @import("../platform/sdl.zig");
const macos_input = @import("../platform/macos_input_source.zig");
const input = @import("../input/mapper.zig");
const renderer_mod = @import("../render/renderer.zig");
const pty_mod = @import("../pty.zig");
const font_mod = @import("../font.zig");
const font_paths_mod = @import("../font_paths.zig");
const config_mod = @import("../config.zig");
const logging_mod = @import("../logging.zig");
const colors_mod = @import("../colors.zig");
const ui_mod = @import("../ui/mod.zig");
const font_cache_mod = @import("../font_cache.zig");
const c = @import("../c.zig");
const dpi = @import("../dpi.zig");
const metrics_mod = @import("../metrics.zig");
const open_url = @import("../os/open.zig");
const terminal_history = @import("terminal_history.zig");

const log = std.log.scoped(.runtime);
extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;

const initial_window_width = 1200;
const initial_window_height = 900;
const default_font_size: c_int = 14;
const min_font_size: c_int = 8;
const max_font_size: c_int = 96;
const font_step: c_int = 1;
const ui_font_size: c_int = 18;
const active_frame_ns: i128 = 16_666_667;
const idle_frame_ns: i128 = 50_000_000;
const max_idle_render_gap_ns: i128 = 250_000_000;
const foreground_process_cache_ms: i64 = 150;
const Rect = app_state.Rect;
const AnimationState = app_state.AnimationState;
const NotificationQueue = notify.NotificationQueue;
const ControlQueue = control.SpawnQueue;
const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;
const GridLayout = grid_layout.GridLayout;
const SessionMove = grid_layout.SessionMove;

const FrameWaitDecision = union(enum) {
    none,
    idle_wait_ms: c_int,
    active_sleep_ns: u64,
};

const ForegroundProcessCache = struct {
    session_idx: ?usize = null,
    last_check_ms: i64 = 0,
    value: bool = false,

    fn get(self: *ForegroundProcessCache, now_ms: i64, focused_session: usize, sessions: []const *SessionState) bool {
        if (self.session_idx != focused_session) {
            self.session_idx = focused_session;
            self.last_check_ms = 0;
        }
        if (self.last_check_ms == 0 or now_ms < self.last_check_ms or
            now_ms - self.last_check_ms >= foreground_process_cache_ms)
        {
            self.value = sessions[focused_session].hasForegroundProcess();
            self.last_check_ms = now_ms;
        }
        return self.value;
    }
};

fn countForegroundProcesses(sessions: []const *SessionState) usize {
    var total: usize = 0;
    for (sessions) |session| {
        if (session.hasForegroundProcess()) {
            total += 1;
        }
    }
    return total;
}

fn countSpawnedSessions(sessions: []const *SessionState) usize {
    var count: usize = 0;
    for (sessions) |session| {
        if (session.spawned) count += 1;
    }
    return count;
}

fn remainingFrameBudgetNs(target_frame_ns: i128, frame_ns: i128) u64 {
    if (frame_ns >= target_frame_ns) return 0;
    return @intCast(target_frame_ns - frame_ns);
}

fn waitTimeoutMsFromNs(remaining_ns: u64) c_int {
    if (remaining_ns == 0) return 0;

    const timeout_ms = 1 + @divFloor(remaining_ns - 1, std.time.ns_per_ms);

    const max_timeout_ms: u64 = @intCast(std.math.maxInt(c_int));
    return @intCast(@min(timeout_ms, max_timeout_ms));
}

fn computeFrameWaitDecision(is_idle: bool, vsync_enabled: bool, frame_ns: i128) FrameWaitDecision {
    if (is_idle) {
        const timeout_ms = waitTimeoutMsFromNs(remainingFrameBudgetNs(idle_frame_ns, frame_ns));
        return if (timeout_ms > 0) .{ .idle_wait_ms = timeout_ms } else .none;
    }
    if (vsync_enabled) return .none;

    const sleep_ns = remainingFrameBudgetNs(active_frame_ns, frame_ns);
    return if (sleep_ns > 0) .{ .active_sleep_ns = sleep_ns } else .none;
}

fn waitForNextFrame(wait_decision: FrameWaitDecision) ?c.SDL_Event {
    return switch (wait_decision) {
        .none => null,
        .idle_wait_ms => |timeout_ms| platform.waitEventTimeout(timeout_ms),
        .active_sleep_ns => |sleep_ns| blk: {
            std.Thread.sleep(sleep_ns);
            break :blk null;
        },
    };
}

fn writeRuntimeEvent(message: []const u8, event_name: []const u8, extra_data: []const u8) void {
    logging_mod.writeEvent("runtime", message, event_name, extra_data) catch |err| {
        log.warn("failed to write runtime event {s}: {}", .{ event_name, err });
    };
}

fn emitViewModeTransitionEvents(
    previous_mode: app_state.ViewMode,
    next_mode: app_state.ViewMode,
    focused_session: usize,
    spawned_count: usize,
) void {
    if (previous_mode == next_mode) return;

    var extra_buf: [160]u8 = undefined;
    const extra_data = std.fmt.bufPrint(&extra_buf, "from={s} to={s} focused_session={d} spawned_count={d}", .{
        @tagName(previous_mode),
        @tagName(next_mode),
        focused_session,
        spawned_count,
    }) catch |err| {
        log.warn("failed to format runtime view event payload: {}", .{err});
        return;
    };

    if (previous_mode == .Grid and next_mode != .Grid) {
        writeRuntimeEvent("exiting grid view", "view_exit_grid", extra_data);
    }
    if (next_mode == .Grid and previous_mode != .Grid) {
        writeRuntimeEvent("entered grid view", "view_enter_grid", extra_data);
    }
    if (previous_mode == .Full and next_mode != .Full) {
        writeRuntimeEvent("exiting full view", "view_exit_full", extra_data);
    }
    if (next_mode == .Full and previous_mode != .Full) {
        writeRuntimeEvent("entered full view", "view_enter_full", extra_data);
    }
}

fn optionalStringEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn persistedAgentType(session: *const SessionState) ?[]const u8 {
    if (!session.agent_metadata_captured) return null;
    if (session.agent_kind == null or session.agent_session_id == null) return null;
    return session.agent_kind.?.name();
}

fn persistedAgentSessionId(session: *const SessionState, agent_type: ?[]const u8) ?[]const u8 {
    if (agent_type == null) return null;
    return session.agent_session_id;
}

fn seedSessionAgentMetadataFromEntry(
    session: *SessionState,
    entry: config_mod.Persistence.TerminalEntry,
    allocator: std.mem.Allocator,
) void {
    const agent_type_str = entry.agent_type orelse return;
    const session_id = entry.agent_session_id orelse return;
    if (session_id.len == 0) return;
    const agent_kind = session_state.AgentKind.fromString(agent_type_str) orelse return;

    session.agent_kind = agent_kind;
    if (session.agent_session_id) |sid| {
        allocator.free(sid);
        session.agent_session_id = null;
    }
    session.agent_session_id = allocator.dupe(u8, session_id) catch |err| {
        log.warn("failed to seed agent session id for restored session {d}: {}", .{ session.slot_index, err });
        return;
    };
    session.agent_metadata_captured = false;
}

fn terminalEntriesMatchSessions(
    persistence: *const config_mod.Persistence,
    sessions: []const *SessionState,
) bool {
    var entry_idx: usize = 0;
    for (sessions) |session| {
        if (!session.spawned or session.dead) continue;
        const path = session.cwd_path orelse continue;
        if (path.len == 0) continue;

        if (entry_idx >= persistence.terminal_entries.items.len) return false;
        const entry = persistence.terminal_entries.items[entry_idx];
        const agent_type = persistedAgentType(session);
        const agent_session_id = persistedAgentSessionId(session, agent_type);

        if (!std.mem.eql(u8, entry.path, path)) return false;
        if (!optionalStringEql(entry.agent_type, agent_type)) return false;
        if (!optionalStringEql(entry.agent_session_id, agent_session_id)) return false;

        entry_idx += 1;
    }
    return entry_idx == persistence.terminal_entries.items.len;
}

fn syncPersistenceTerminalEntriesFromSessions(
    persistence: *config_mod.Persistence,
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !bool {
    if (terminalEntriesMatchSessions(persistence, sessions)) return false;

    persistence.clearTerminalEntries(allocator);
    for (sessions) |session| {
        if (!session.spawned or session.dead) continue;
        const path = session.cwd_path orelse continue;
        if (path.len == 0) continue;

        const agent_type = persistedAgentType(session);
        const agent_session_id = persistedAgentSessionId(session, agent_type);
        try persistence.appendTerminalEntry(allocator, path, agent_type, agent_session_id);
    }
    return true;
}

fn savePersistenceIfDirty(
    persistence: *config_mod.Persistence,
    allocator: std.mem.Allocator,
    dirty: *bool,
) void {
    if (!dirty.*) return;
    persistence.save(allocator) catch |err| {
        std.debug.print("Failed to save persistence: {}\n", .{err});
        return;
    };
    dirty.* = false;
}

fn highestSpawnedIndex(sessions: []const *SessionState) ?usize {
    var idx: usize = sessions.len;
    while (idx > 0) {
        idx -= 1;
        if (sessions[idx].spawned) return idx;
    }
    return null;
}

fn agentProcessStarted(session: *const SessionState) bool {
    return session.hasForegroundProcess();
}

fn adjustedRenderHeightForMode(mode: app_state.ViewMode, render_height: c_int, ui_scale: f32, grid_rows: usize) c_int {
    return switch (mode) {
        .Grid => blk: {
            const cell_height = @divFloor(render_height, @as(c_int, @intCast(grid_rows)));
            const reserved_per_cell: c_int = if (cell_height >= ui_mod.cwd_bar.minCellHeight(ui_scale))
                ui_mod.cwd_bar.reservedHeight(ui_scale)
            else
                0;
            const reserved_total = reserved_per_cell * @as(c_int, @intCast(grid_rows));
            break :blk @max(0, render_height - reserved_total);
        },
        .Collapsing, .GridResizing, .Expanding, .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => render_height,
    };
}

/// Which sessions need full-window cell dimensions for the given view mode.
/// During Panning the previous session is still visible at full size on its way
/// off-screen, so it stays at full size until the pan completes.
fn fullSetForMode(mode: app_state.ViewMode, focused: usize, previous: usize) layout.FullSet {
    return switch (mode) {
        .Grid, .GridResizing => .{},
        .Full, .Expanding, .Collapsing => .{ .primary = focused },
        .PanningLeft, .PanningRight, .PanningUp, .PanningDown => .{ .primary = focused, .secondary = previous },
    };
}

fn applyTerminalLayout(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    font: *font_mod.Font,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    anim_state: *const AnimationState,
    grid_cols: usize,
    grid_rows: usize,
    grid_font_scale: f32,
    full_cols: *u16,
    full_rows: *u16,
) void {
    const sizes = computeTerminalSizes(font, render_width, render_height, ui_scale, grid_cols, grid_rows, grid_font_scale);
    full_cols.* = sizes.full.cols;
    full_rows.* = sizes.full.rows;
    const full_set = fullSetForMode(anim_state.mode, anim_state.focused_session, anim_state.previous_session);
    _ = layout.applyTerminalResize(sessions, allocator, sizes, full_set);
}

fn applyTerminalLayoutIfSizeChanged(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    font: *font_mod.Font,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    anim_state: *const AnimationState,
    grid_cols: usize,
    grid_rows: usize,
    grid_font_scale: f32,
    full_cols: *u16,
    full_rows: *u16,
) bool {
    const sizes = computeTerminalSizes(font, render_width, render_height, ui_scale, grid_cols, grid_rows, grid_font_scale);
    full_cols.* = sizes.full.cols;
    full_rows.* = sizes.full.rows;
    const full_set = fullSetForMode(anim_state.mode, anim_state.focused_session, anim_state.previous_session);
    return layout.applyTerminalResize(sessions, allocator, sizes, full_set);
}

/// Computes both terminal sizes from the raw render dimensions. grid_size
/// always uses the Grid-mode CWD-bar reservation so unfocused sessions stay at
/// stable dims across view-mode toggles; full_size uses the raw render height.
fn computeTerminalSizes(
    font: *font_mod.Font,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    grid_cols: usize,
    grid_rows: usize,
    grid_font_scale: f32,
) layout.Sizes {
    const grid_render_height = adjustedRenderHeightForMode(.Grid, render_height, ui_scale, grid_rows);
    return layout.calculateTerminalSizes(font, render_width, grid_render_height, render_height, grid_font_scale, grid_cols, grid_rows, ui_scale);
}

const SessionIndexSnapshot = struct {
    session_id: usize,
    index: usize,
};

/// Collect indices for spawned sessions to preserve their pre-compaction positions.
fn collectSessionIndexSnapshots(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !std.ArrayList(SessionIndexSnapshot) {
    var snapshots = std.ArrayList(SessionIndexSnapshot).empty;
    for (sessions, 0..) |session, idx| {
        if (session.spawned) {
            try snapshots.append(allocator, .{ .session_id = session.id, .index = idx });
        }
    }
    return snapshots;
}

fn findSnapshotIndex(snapshots: []const SessionIndexSnapshot, session_id: usize) ?usize {
    for (snapshots) |snapshot| {
        if (snapshot.session_id == session_id) return snapshot.index;
    }
    return null;
}

const SessionMoves = struct {
    list: std.ArrayList(SessionMove),
    moved: bool,
};

/// Collect session moves using the current indices as both old and new positions.
fn collectSessionMovesCurrent(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !std.ArrayList(SessionMove) {
    var moves = std.ArrayList(SessionMove).empty;
    for (sessions, 0..) |session, idx| {
        if (session.spawned) {
            try moves.append(allocator, .{ .session_idx = idx, .old_index = idx });
        }
    }
    return moves;
}

/// Collect session moves using snapshot indices as old positions, returning whether any moved.
fn collectSessionMovesFromSnapshots(
    sessions: []const *SessionState,
    snapshots: []const SessionIndexSnapshot,
    allocator: std.mem.Allocator,
) !SessionMoves {
    var moves = std.ArrayList(SessionMove).empty;
    var moved = false;
    for (sessions, 0..) |session, idx| {
        if (!session.spawned) continue;
        const old_index = findSnapshotIndex(snapshots, session.id);
        if (old_index) |old_idx| {
            if (old_idx != idx) moved = true;
        } else {
            moved = true;
        }
        try moves.append(allocator, .{ .session_idx = idx, .old_index = old_index });
    }
    return .{ .list = moves, .moved = moved };
}

fn findNextFreeSlotAfter(
    sessions: []const *SessionState,
    grid_capacity: usize,
    start_idx: usize,
) ?usize {
    if (grid_capacity == 0) return null;

    var offset: usize = 1;
    while (offset <= grid_capacity) : (offset += 1) {
        const idx = (start_idx + offset) % grid_capacity;
        if (idx >= sessions.len) continue;
        if (!sessions[idx].spawned) {
            return idx;
        }
    }
    return null;
}

fn findSessionIndexById(sessions: []const *SessionState, session_id: usize) ?usize {
    for (sessions, 0..) |session, idx| {
        if (session.spawned and session.id == session_id) return idx;
    }
    return null;
}

fn compactSessions(
    sessions: []*SessionState,
    views: []SessionViewState,
    render_cache: *renderer_mod.RenderCache,
    anim_state: *AnimationState,
) void {
    const focused_id: ?usize = if (anim_state.focused_session < sessions.len and sessions[anim_state.focused_session].spawned)
        sessions[anim_state.focused_session].id
    else
        null;
    const previous_id: ?usize = if (anim_state.previous_session < sessions.len and sessions[anim_state.previous_session].spawned)
        sessions[anim_state.previous_session].id
    else
        null;

    var write_idx: usize = 0;
    var idx: usize = 0;
    while (idx < sessions.len) : (idx += 1) {
        if (!sessions[idx].spawned) continue;
        if (write_idx != idx) {
            std.mem.swap(*SessionState, &sessions[write_idx], &sessions[idx]);
            std.mem.swap(SessionViewState, &views[write_idx], &views[idx]);
            std.mem.swap(renderer_mod.RenderCache.Entry, &render_cache.entries[write_idx], &render_cache.entries[idx]);
        }
        write_idx += 1;
    }

    for (sessions, 0..) |session, slot_idx| {
        session.slot_index = slot_idx;
    }

    if (focused_id) |id| {
        if (findSessionIndexById(sessions, id)) |new_idx| {
            anim_state.focused_session = new_idx;
        }
    }
    if (previous_id) |id| {
        if (findSessionIndexById(sessions, id)) |new_idx| {
            anim_state.previous_session = new_idx;
        }
    }
}

const WorkingDir = struct {
    cwd_z: ?[:0]const u8,
    buf: ?[]u8,

    fn init(allocator: std.mem.Allocator, cwd_path: ?[]const u8) WorkingDir {
        var buf: ?[]u8 = null;
        const cwd_z: ?[:0]const u8 = if (cwd_path) |path| blk: {
            const owned = allocator.alloc(u8, path.len + 1) catch break :blk null;
            @memcpy(owned[0..path.len], path);
            owned[path.len] = 0;
            buf = owned;
            break :blk owned[0..path.len :0];
        } else null;

        return .{
            .cwd_z = cwd_z,
            .buf = buf,
        };
    }

    fn deinit(self: *WorkingDir, allocator: std.mem.Allocator) void {
        if (self.buf) |buf| allocator.free(buf);
    }
};

const ExternalSpawnPlan = struct {
    slot_index: usize,
    cols: usize,
    rows: usize,
    expands_grid: bool,
};

fn planExternalSpawnSlot(
    sessions: []const *SessionState,
    grid_cols: usize,
    grid_rows: usize,
    focused_session: usize,
) ?ExternalSpawnPlan {
    const spawned_count = countSpawnedSessions(sessions);
    if (spawned_count >= grid_layout.max_terminals) return null;

    const capacity = grid_cols * grid_rows;
    if (spawned_count >= capacity) {
        const new_dims = GridLayout.calculateDimensions(spawned_count + 1);
        const new_capacity = new_dims.cols * new_dims.rows;
        if (new_capacity > grid_layout.max_terminals) return null;
        const slot_index = findNextFreeSlotAfter(sessions, new_capacity, focused_session) orelse return null;
        return .{
            .slot_index = slot_index,
            .cols = new_dims.cols,
            .rows = new_dims.rows,
            .expands_grid = true,
        };
    }

    const slot_index = if (focused_session < sessions.len and !sessions[focused_session].spawned)
        focused_session
    else
        findNextFreeSlotAfter(sessions, capacity, focused_session) orelse return null;

    return .{
        .slot_index = slot_index,
        .cols = grid_cols,
        .rows = grid_rows,
        .expands_grid = false,
    };
}

fn validateExternalSpawnCwd(cwd: []const u8) ?control.SpawnFailure {
    if (!std.fs.path.isAbsolute(cwd)) {
        return .{
            .code = .invalid_cwd,
            .message = "cwd must be an absolute directory",
        };
    }

    var dir = std.fs.openDirAbsolute(cwd, .{}) catch {
        return .{
            .code = .invalid_cwd,
            .message = "cwd must be an existing directory",
        };
    };
    dir.close();
    return null;
}

fn buildQueuedCommand(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    if (command.len == 0) return error.EmptyCommand;
    const needs_newline = command[command.len - 1] != '\n';
    const out_len = command.len + @as(usize, if (needs_newline) 1 else 0);
    const out = try allocator.alloc(u8, out_len);
    @memcpy(out[0..command.len], command);
    if (needs_newline) out[out.len - 1] = '\n';
    return out;
}

fn completeExternalSpawnFailure(
    pending: *control.PendingSpawn,
    code: control.SpawnErrorCode,
    message: []const u8,
) void {
    pending.completion.complete(.{ .failure = .{
        .code = code,
        .message = message,
    } });
}

fn handleExternalSpawnRequest(
    allocator: std.mem.Allocator,
    pending: *control.PendingSpawn,
    sessions: []const *SessionState,
    grid: *GridLayout,
    anim_state: *AnimationState,
    session_interaction_component: *ui_mod.SessionInteractionComponent,
    loop: *xev.Loop,
    animations_enabled: bool,
    now: i64,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    font: *font_mod.Font,
    grid_font_scale: f32,
    full_cols: *u16,
    full_rows: *u16,
    cell_width_pixels: *c_int,
    cell_height_pixels: *c_int,
) void {
    if (validateExternalSpawnCwd(pending.request.cwd)) |failure| {
        pending.completion.complete(.{ .failure = failure });
        return;
    }

    const plan = planExternalSpawnSlot(sessions, grid.cols, grid.rows, anim_state.focused_session) orelse {
        completeExternalSpawnFailure(pending, .full_grid, "all Architect terminal slots are in use");
        return;
    };

    const command_input = if (pending.request.command) |command| blk: {
        break :blk buildQueuedCommand(allocator, command) catch |err| {
            log.warn("failed to prepare external spawn command: {}", .{err});
            completeExternalSpawnFailure(pending, .spawn_failed, "failed to prepare command for the new session");
            return;
        };
    } else null;
    defer if (command_input) |input_bytes| allocator.free(input_bytes);

    const cwd_buf = allocZ(allocator, pending.request.cwd) catch |err| {
        log.warn("failed to allocate external spawn cwd: {}", .{err});
        completeExternalSpawnFailure(pending, .spawn_failed, "failed to prepare working directory");
        return;
    };
    defer allocator.free(cwd_buf);
    const cwd_z: [:0]const u8 = cwd_buf[0..pending.request.cwd.len :0];

    if (plan.expands_grid) {
        var moves = collectSessionMovesCurrent(sessions, allocator) catch |err| {
            log.warn("failed to collect external spawn grid moves: {}", .{err});
            completeExternalSpawnFailure(pending, .spawn_failed, "failed to prepare grid expansion");
            return;
        };
        defer moves.deinit(allocator);

        if (animations_enabled) {
            grid.startResize(plan.cols, plan.rows, now, render_width, render_height, moves.items) catch |err| {
                log.warn("failed to start external spawn grid resize: {}", .{err});
                grid.cols = plan.cols;
                grid.rows = plan.rows;
            };
            if (grid.is_resizing) {
                anim_state.mode = .GridResizing;
            }
        } else {
            grid.cols = plan.cols;
            grid.rows = plan.rows;
        }
    }

    const session = sessions[plan.slot_index];
    session.ensureSpawnedWithDir(cwd_z, loop) catch |err| {
        log.warn("external spawn failed for cwd {s}: {}", .{ pending.request.cwd, err });
        completeExternalSpawnFailure(pending, .spawn_failed, "failed to spawn terminal session");
        return;
    };

    if (command_input) |input_bytes| {
        session.pending_write.appendSlice(allocator, input_bytes) catch |err| {
            log.warn("failed to queue external spawn command for session {d}: {}", .{ session.id, err });
            completeExternalSpawnFailure(pending, .spawn_failed, "failed to queue command for the new session");
            return;
        };
    }

    session_interaction_component.setStatus(plan.slot_index, .running);
    session_interaction_component.setAttention(plan.slot_index, false, now);
    session_interaction_component.clearSelection(anim_state.focused_session);
    session_interaction_component.clearSelection(plan.slot_index);

    anim_state.previous_session = anim_state.focused_session;
    anim_state.focused_session = plan.slot_index;

    cell_width_pixels.* = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
    cell_height_pixels.* = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
    applyTerminalLayout(
        sessions,
        allocator,
        font,
        render_width,
        render_height,
        ui_scale,
        anim_state,
        grid.cols,
        grid.rows,
        grid_font_scale,
        full_cols,
        full_rows,
    );

    pending.completion.complete(.{ .success = .{
        .session_id = session.id,
        .slot_index = plan.slot_index,
    } });
}

fn initSharedFont(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    cache: *font_cache_mod.FontCache,
    size: c_int,
) font_mod.Font.InitError!font_mod.Font {
    const faces = cache.get(size) catch |err| switch (err) {
        error.FontUnavailable => return error.FontLoadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return font_mod.Font.initFromFaces(allocator, renderer, .{
        .regular = faces.regular,
        .bold = faces.bold,
        .italic = faces.italic,
        .bold_italic = faces.bold_italic,
        .symbol_embedded = faces.symbol_embedded,
        .symbol = faces.symbol,
        .symbol_secondary = faces.symbol_secondary,
        .emoji = faces.emoji,
    });
}

fn markTeardownComplete(flag: *bool) bool {
    if (flag.*) return false;
    flag.* = true;
    return true;
}

fn swapTwoResources(
    comptime Resource: type,
    comptime Context: type,
    comptime InitError: type,
    first: *Resource,
    second: *Resource,
    ctx: *Context,
    init_first: *const fn (ctx: *Context) InitError!Resource,
    init_second: *const fn (ctx: *Context) InitError!Resource,
    deinit_resource: *const fn (resource: *Resource) void,
) InitError!void {
    var next_first = try init_first(ctx);
    errdefer deinit_resource(&next_first);

    var next_second = try init_second(ctx);
    errdefer deinit_resource(&next_second);

    deinit_resource(first);
    deinit_resource(second);
    first.* = next_first;
    second.* = next_second;
}

const FontReloadContext = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    shared_cache: *font_cache_mod.FontCache,
    ui_cache: *font_cache_mod.FontCache,
    font_size: c_int,
    ui_scale: f32,
};

fn initTerminalFontForReload(ctx: *FontReloadContext) font_mod.Font.InitError!font_mod.Font {
    return initSharedFont(
        ctx.allocator,
        ctx.renderer,
        ctx.shared_cache,
        layout.scaledFontSize(ctx.font_size, ctx.ui_scale),
    );
}

fn initUiFontForReload(ctx: *FontReloadContext) font_mod.Font.InitError!font_mod.Font {
    return initSharedFont(
        ctx.allocator,
        ctx.renderer,
        ctx.ui_cache,
        layout.scaledFontSize(ui_font_size, ctx.ui_scale),
    );
}

fn deinitFontResource(font: *font_mod.Font) void {
    font.deinit();
}

fn reloadFontsForScale(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    shared_cache: *font_cache_mod.FontCache,
    ui_cache: *font_cache_mod.FontCache,
    font_size: c_int,
    ui_scale: f32,
    metrics_ptr: ?*metrics_mod.Metrics,
    font: *font_mod.Font,
    ui_font: *font_mod.Font,
) font_mod.Font.InitError!void {
    var ctx = FontReloadContext{
        .allocator = allocator,
        .renderer = renderer,
        .shared_cache = shared_cache,
        .ui_cache = ui_cache,
        .font_size = font_size,
        .ui_scale = ui_scale,
    };
    try swapTwoResources(
        font_mod.Font,
        FontReloadContext,
        font_mod.Font.InitError,
        font,
        ui_font,
        &ctx,
        initTerminalFontForReload,
        initUiFontForReload,
        deinitFontResource,
    );
    font.metrics = metrics_ptr;
}

fn applyScaleChangeAndResize(
    comptime Context: type,
    comptime ReloadError: type,
    ctx: *Context,
    prev_scale: f32,
    next_scale: f32,
    reload_fn: *const fn (ctx: *Context) ReloadError!void,
    resize_fn: *const fn (ctx: *Context) void,
) ReloadError!void {
    if (next_scale != prev_scale) {
        try reload_fn(ctx);
    }
    resize_fn(ctx);
}

const RuntimeScaleChangeContext = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    shared_font_cache: *font_cache_mod.FontCache,
    ui_font_cache: *font_cache_mod.FontCache,
    font_size: c_int,
    ui_scale: f32,
    metrics_ptr: ?*metrics_mod.Metrics,
    font: *font_mod.Font,
    ui_font: *font_mod.Font,
    ui: *ui_mod.UiRoot,
    sessions: []const *SessionState,
    render_width: c_int,
    render_height: c_int,
    anim_state: *const AnimationState,
    grid_cols: usize,
    grid_rows: usize,
    grid_font_scale: f32,
    full_cols: *u16,
    full_rows: *u16,
};

fn reloadRuntimeFontsForScaleChange(ctx: *RuntimeScaleChangeContext) font_mod.Font.InitError!void {
    try reloadFontsForScale(
        ctx.allocator,
        ctx.renderer,
        ctx.shared_font_cache,
        ctx.ui_font_cache,
        ctx.font_size,
        ctx.ui_scale,
        ctx.metrics_ptr,
        ctx.font,
        ctx.ui_font,
    );
    ctx.ui.assets.ui_font = ctx.ui_font;
}

fn applyRuntimeResizeForScaleChange(ctx: *RuntimeScaleChangeContext) void {
    const sizes = computeTerminalSizes(ctx.font, ctx.render_width, ctx.render_height, ctx.ui_scale, ctx.grid_cols, ctx.grid_rows, ctx.grid_font_scale);
    ctx.full_cols.* = sizes.full.cols;
    ctx.full_rows.* = sizes.full.rows;
    const full_set = fullSetForMode(ctx.anim_state.mode, ctx.anim_state.focused_session, ctx.anim_state.previous_session);
    _ = layout.applyTerminalResize(
        ctx.sessions,
        ctx.allocator,
        sizes,
        full_set,
    );
}

fn handleQuitRequest(
    sessions: []const *SessionState,
    confirm: *ui_mod.quit_confirm.QuitConfirmComponent,
) bool {
    const running_processes = countForegroundProcesses(sessions);
    if (running_processes > 0) {
        confirm.show(running_processes);
        return false;
    }
    return true;
}

const quit_primary_wait_ms: u64 = 2500;
const quit_retry_wait_ms: u64 = 2500;
const quit_term_wait_ms: u64 = 500;
const quit_capture_drain_poll_ns: u64 = 20 * std.time.ns_per_ms;
const quit_capture_drain_quiet_ns: i128 = 250 * @as(i128, std.time.ns_per_ms);
const quit_capture_drain_max_ns: i128 = 2500 * @as(i128, std.time.ns_per_ms);

const QuitTeardownTask = struct {
    session_idx: usize,
    shell_pid: posix.pid_t,
    pty_master: posix.fd_t,
    agent_kind: session_state.AgentKind,
    slave_path_len: usize = 0,
    slave_path: [posix.PATH_MAX + 1]u8 = [_]u8{0} ** (posix.PATH_MAX + 1),

    fn slavePathZ(self: *const QuitTeardownTask) [:0]const u8 {
        return self.slave_path[0..self.slave_path_len :0];
    }
};

const QuitTeardownWorker = struct {
    tasks: []QuitTeardownTask,
    done: *std.atomic.Value(bool),

    fn run(self: *QuitTeardownWorker) void {
        defer self.done.store(true, .seq_cst);
        var threads: [grid_layout.max_terminals]?std.Thread = [_]?std.Thread{null} ** grid_layout.max_terminals;
        for (self.tasks, 0..) |*task, idx| {
            threads[idx] = std.Thread.spawn(.{}, runTask, .{task}) catch |err| blk: {
                log.warn("quit teardown: failed to spawn parallel task for session {d}: {}", .{ task.session_idx, err });
                runTask(task);
                break :blk null;
            };
        }
        for (threads[0..self.tasks.len]) |thread_opt| {
            if (thread_opt) |thread| {
                thread.join();
            }
        }
    }

    fn runTask(task: *QuitTeardownTask) void {
        log.info("quit teardown: session {d} has foreground agent {s}", .{ task.session_idx, task.agent_kind.name() });
        sendExitSequence(task.pty_master, task.agent_kind);
        std.Thread.sleep(quit_primary_wait_ms * std.time.ns_per_ms);

        var fg_pgrp = foregroundPgrp(task.slavePathZ(), task.shell_pid);
        if (fg_pgrp != null) {
            log.debug("quit teardown: session {d} agent {s} still foreground after primary quit, retrying with interrupt", .{ task.session_idx, task.agent_kind.name() });
            sendExitSequence(task.pty_master, task.agent_kind);
            std.Thread.sleep(quit_retry_wait_ms * std.time.ns_per_ms);
            fg_pgrp = foregroundPgrp(task.slavePathZ(), task.shell_pid);
        }

        if (fg_pgrp) |pgrp| {
            log.debug("quit teardown: session {d} agent {s} did not exit gracefully, sending SIGTERM", .{ task.session_idx, task.agent_kind.name() });
            _ = std.c.kill(-pgrp, std.c.SIG.TERM);
            std.Thread.sleep(quit_term_wait_ms * std.time.ns_per_ms);
        } else {
            log.debug("quit teardown: session {d} agent {s} exited gracefully", .{ task.session_idx, task.agent_kind.name() });
        }
    }
};

const QuitTeardownState = struct {
    active: bool = false,
    task_count: usize = 0,
    tasks: [grid_layout.max_terminals]QuitTeardownTask = undefined,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: QuitTeardownWorker = undefined,
    thread: ?std.Thread = null,

    fn start(self: *QuitTeardownState, sessions: []*SessionState) !bool {
        if (self.active) return true;

        self.task_count = 0;
        for (sessions, 0..) |session, idx| {
            const agent_kind = session.detectForegroundAgent() orelse continue;
            const shell_pid = session.shellPid() orelse continue;
            const pty_master = session.ptyMasterFd() orelse continue;

            var task = QuitTeardownTask{
                .session_idx = idx,
                .shell_pid = shell_pid,
                .pty_master = pty_master,
                .agent_kind = agent_kind,
            };
            const copied_path = session.copyPtySlavePath(task.slave_path[0..]) orelse continue;
            task.slave_path_len = copied_path.len;

            session.startQuitCapture();
            self.tasks[self.task_count] = task;
            self.task_count += 1;
        }

        if (self.task_count == 0) return false;

        self.done.store(false, .seq_cst);
        self.worker = .{
            .tasks = self.tasks[0..self.task_count],
            .done = &self.done,
        };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{&self.worker});
        self.active = true;
        return true;
    }

    fn isFinished(self: *const QuitTeardownState) bool {
        return self.active and self.done.load(.seq_cst);
    }

    fn join(self: *QuitTeardownState) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn workerMain(worker: *QuitTeardownWorker) void {
        worker.run();
    }
};

fn sendExitSequence(master_fd: posix.fd_t, agent_kind: session_state.AgentKind) void {
    const sequence = agent_kind.exitControlSequence();
    for (sequence, 0..) |byte, idx| {
        const buf = [1]u8{byte};
        _ = posix.write(master_fd, &buf) catch |err| {
            log.warn("quit teardown: failed to send exit key sequence (step {d}) for {s}: {}", .{ idx + 1, agent_kind.name(), err });
            return;
        };
        if (idx + 1 < sequence.len) {
            std.Thread.sleep(220 * std.time.ns_per_ms);
        }
    }
    log.debug("quit teardown: wrote exit command for agent {s}", .{agent_kind.name()});
}

fn foregroundPgrp(slave_path_z: [:0]const u8, shell_pid: posix.pid_t) ?posix.pid_t {
    const fd = posix.openZ(slave_path_z, .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) catch return null;
    defer posix.close(fd);
    const fg = tcgetpgrp(fd);
    if (fg <= 0) return null;
    const fg_pgrp: posix.pid_t = @intCast(fg);
    if (fg_pgrp == shell_pid) return null;
    return fg_pgrp;
}

fn drainQuitCaptureOutput(tasks: []const QuitTeardownTask, sessions: []const *SessionState) void {
    if (tasks.len == 0) return;

    var last_capture_lengths: [grid_layout.max_terminals]usize = [_]usize{0} ** grid_layout.max_terminals;
    for (tasks, 0..) |task, idx| {
        last_capture_lengths[idx] = sessions[task.session_idx].quitCaptureBytes().len;
    }

    const start_ns = std.time.nanoTimestamp();
    var last_growth_ns = start_ns;

    while (true) {
        var saw_growth = false;
        for (tasks, 0..) |task, idx| {
            const session = sessions[task.session_idx];
            session.processOutput() catch |err| {
                log.warn("quit teardown: session {d} post-worker output drain failed: {}", .{ task.session_idx, err });
            };
            const new_len = session.quitCaptureBytes().len;
            if (new_len > last_capture_lengths[idx]) {
                saw_growth = true;
            }
            last_capture_lengths[idx] = new_len;
        }

        const now_ns = std.time.nanoTimestamp();
        if (saw_growth) {
            last_growth_ns = now_ns;
        }

        if (!shouldContinueQuitCaptureDrain(start_ns, last_growth_ns, now_ns)) break;
        std.Thread.sleep(quit_capture_drain_poll_ns);
    }
}

fn shouldContinueQuitCaptureDrain(start_ns: i128, last_growth_ns: i128, now_ns: i128) bool {
    const quiet_elapsed = now_ns - last_growth_ns;
    const total_elapsed = now_ns - start_ns;
    return quiet_elapsed < quit_capture_drain_quiet_ns and total_elapsed < quit_capture_drain_max_ns;
}

fn startQuitFlow(
    quit_state: *QuitTeardownState,
    sessions: []*SessionState,
    overlay: *ui_mod.quit_blocking_overlay.QuitBlockingOverlayComponent,
) bool {
    if (builtin.os.tag != .macos) return true;
    if (quit_state.active) return false;
    const started = quit_state.start(sessions) catch |err| {
        log.warn("quit teardown: failed to start worker thread: {}", .{err});
        return true;
    };
    if (!started) return true;
    overlay.setActive(true);
    return false;
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Socket listener relays external "awaiting approval / done" signals from
    // shells (or other tools) into the UI thread without blocking rendering.
    var notify_queue = NotificationQueue{};
    defer notify_queue.deinit(allocator);

    var control_queue = ControlQueue{};
    defer control_queue.deinit(allocator);

    const notify_sock = try notify.getNotifySocketPath(allocator);
    defer allocator.free(notify_sock);

    const control_sock = try control.getControlSocketPath(allocator);
    defer allocator.free(control_sock);

    const control_discovery_path = try control.getControlDiscoveryPath(allocator);
    defer allocator.free(control_discovery_path);

    var notify_stop = std.atomic.Value(bool).init(false);
    var control_stop = std.atomic.Value(bool).init(false);

    var config = config_mod.Config.load(allocator) catch |err| blk: {
        if (err == error.ConfigNotFound) {
            std.debug.print("Config not found, creating default config file\n", .{});
            config_mod.Config.createDefaultConfigFile(allocator) catch |create_err| {
                std.debug.print("Failed to create default config: {}\n", .{create_err});
            };
        } else {
            std.debug.print("Failed to load config: {}, using defaults\n", .{err});
        }
        break :blk config_mod.Config{
            .font = .{ .size = default_font_size },
            .window = .{
                .width = initial_window_width,
                .height = initial_window_height,
            },
        };
    };
    defer config.deinit(allocator);

    var file_logging_enabled = false;
    logging_mod.init(allocator, .{
        .min_level = config.logging.getMinLevel(),
    }) catch |err| {
        std.debug.print("Failed to initialize file logging: {}\n", .{err});
    };
    if (logging_mod.isInitialized()) {
        file_logging_enabled = true;
        logging_mod.writeStartupMarker() catch |err| {
            std.debug.print("Failed to write startup marker: {}\n", .{err});
        };
    }
    defer {
        if (file_logging_enabled) {
            logging_mod.writeShutdownMarker() catch |err| {
                std.debug.print("Failed to write shutdown marker: {}\n", .{err});
            };
        }
        logging_mod.deinit();
    }

    var persistence = config_mod.Persistence.load(allocator) catch |err| blk: {
        std.debug.print("Failed to load persistence: {}, using defaults\n", .{err});
        var fallback = config_mod.Persistence.init(allocator);
        fallback.font_size = config.font.size;
        fallback.window = config.window;
        break :blk fallback;
    };
    errdefer persistence.deinit(allocator);
    persistence.font_size = std.math.clamp(persistence.font_size, min_font_size, max_font_size);

    // Initialize recent folders with home directory if empty
    if (persistence.recent_folders.items.len == 0) {
        if (std.posix.getenv("HOME")) |home| {
            persistence.appendRecentFolder(allocator, home) catch |err| {
                log.warn("failed to initialize recent folders with home: {}", .{err});
            };
        }
    }

    const theme = colors_mod.Theme.fromConfig(config.theme);

    // Dynamic grid layout - starts with 1x1 and grows as terminals are added
    var grid = try GridLayout.init(allocator);
    defer grid.deinit();

    // Load persisted terminals to determine initial grid size
    const restored_entries = if (builtin.os.tag == .macos) persistence.terminal_entries.items else &[_]config_mod.Persistence.TerminalEntry{};
    const restored_limit = @min(restored_entries.len, grid_layout.max_terminals);
    const restored_slice = restored_entries[0..restored_limit];

    // Calculate initial grid size based on restored terminals
    const initial_terminal_count: usize = if (restored_slice.len > 0) restored_slice.len else 1;
    const initial_dims = GridLayout.calculateDimensions(initial_terminal_count);
    grid.cols = initial_dims.cols;
    grid.rows = initial_dims.rows;

    const animations_enabled = config.ui.enable_animations;

    const window_pos = if (persistence.window.x >= 0 and persistence.window.y >= 0)
        platform.WindowPosition{ .x = persistence.window.x, .y = persistence.window.y }
    else
        null;

    var sdl = try platform.init(
        "ARCHITECT",
        persistence.window.width,
        persistence.window.height,
        window_pos,
        config.rendering.vsync,
    );
    defer platform.deinit(&sdl);
    platform.startTextInput(sdl.window);
    defer platform.stopTextInput(sdl.window);
    const notify_thread = try notify.startNotifyThread(
        allocator,
        notify_sock,
        &notify_queue,
        &notify_stop,
        .{
            .context = &sdl,
            .callback = platform.pushWakeEventFromOpaque,
        },
    );
    defer {
        notify_stop.store(true, .seq_cst);
        notify_thread.join();
    }
    const control_thread = try control.startControlThread(
        allocator,
        control_sock,
        control_discovery_path,
        &control_queue,
        &control_stop,
        .{
            .context = &sdl,
            .callback = platform.pushWakeEventFromOpaque,
        },
    );
    defer {
        control_stop.store(true, .seq_cst);
        control.failPending(&control_queue, allocator, .app_not_running, "Architect is shutting down");
        control_thread.join();
        control.cleanupControlFiles(control_sock, control_discovery_path);
    }
    var text_input_active = true;
    var input_source_tracker = macos_input.InputSourceTracker.init();
    defer input_source_tracker.deinit();
    if (builtin.os.tag == .macos) {
        input_source_tracker.capture() catch |err| {
            log.warn("Failed to capture input source: {}", .{err});
        };
    }

    const renderer = sdl.renderer;

    var font_size: c_int = persistence.font_size;
    var window_width_points: c_int = sdl.window_w;
    var window_height_points: c_int = sdl.window_h;
    var render_width: c_int = sdl.render_w;
    var render_height: c_int = sdl.render_h;
    var scale_x = sdl.scale_x;
    var scale_y = sdl.scale_y;
    var ui_scale: f32 = @max(scale_x, scale_y);

    var font_paths = try font_paths_mod.FontPaths.init(allocator, config.font.family);
    defer font_paths.deinit();

    var shared_font_cache = font_cache_mod.FontCache.initWithFallbacks(allocator, false);
    defer shared_font_cache.deinit();
    shared_font_cache.setPaths(
        font_paths.regular,
        font_paths.bold,
        font_paths.italic,
        font_paths.bold_italic,
        font_paths.symbol_fallback,
        font_paths.symbol_fallback_secondary,
        font_paths.emoji_fallback,
    );

    var ui_font_cache = font_cache_mod.FontCache.initWithFallbacks(allocator, true);
    defer ui_font_cache.deinit();
    ui_font_cache.setPaths(
        font_paths.regular,
        font_paths.bold,
        font_paths.italic,
        font_paths.bold_italic,
        font_paths.symbol_fallback,
        font_paths.symbol_fallback_secondary,
        font_paths.emoji_fallback,
    );

    var metrics_storage: metrics_mod.Metrics = metrics_mod.Metrics.init();
    const metrics_ptr: ?*metrics_mod.Metrics = if (config.metrics.enabled) &metrics_storage else null;
    metrics_mod.global = metrics_ptr;

    var font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(font_size, ui_scale));
    defer font.deinit();
    font.metrics = metrics_ptr;

    var ui_font = try initSharedFont(allocator, renderer, &ui_font_cache, layout.scaledFontSize(ui_font_size, ui_scale));
    defer ui_font.deinit();

    var ui = ui_mod.UiRoot.init(allocator);
    var ui_deinitialized = false;
    errdefer if (markTeardownComplete(&ui_deinitialized)) ui.deinit(renderer);
    ui.assets.ui_font = &ui_font;
    ui.assets.font_cache = &ui_font_cache;

    var window_x: c_int = persistence.window.x;
    var window_y: c_int = persistence.window.y;

    const initial_view_mode: app_state.ViewMode = if (initial_terminal_count == 1) .Full else .Grid;
    const initial_term_render_height = adjustedRenderHeightForMode(initial_view_mode, render_height, ui_scale, grid.rows);
    const initial_sizes = computeTerminalSizes(&font, render_width, render_height, ui_scale, grid.cols, grid.rows, config.grid.font_scale);
    var full_cols: u16 = initial_sizes.full.cols;
    var full_rows: u16 = initial_sizes.full.rows;

    std.debug.print("Grid cell terminal size: {d}x{d}; full size: {d}x{d}\n", .{ initial_sizes.grid.cols, initial_sizes.grid.rows, full_cols, full_rows });

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Starting with {d}x{d} grid: {s}\n", .{ grid.cols, grid.rows, shell_path });

    var cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
    var cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));

    const terminal_padding = dpi.scale(renderer_mod.terminal_padding, ui_scale);
    const usable_width = @max(0, render_width - terminal_padding * 2);
    const usable_height = @max(0, initial_term_render_height - terminal_padding * 2);

    // All sessions seed at grid-cell size. The first applyTerminalLayoutIfSizeChanged
    // promotes the focused session to full size if the initial view is Full.
    const size = pty_mod.winsize{
        .ws_row = initial_sizes.grid.rows,
        .ws_col = initial_sizes.grid.cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    // Allocate max possible sessions to avoid reallocation
    const sessions_storage = try allocator.alloc(SessionState, grid_layout.max_terminals);
    const sessions = blk: {
        errdefer allocator.free(sessions_storage);
        break :blk try allocator.alloc(*SessionState, grid_layout.max_terminals);
    };
    var init_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < init_count) : (i += 1) {
            sessions_storage[i].deinit(allocator);
        }
        allocator.free(sessions_storage);
        allocator.free(sessions);
    }
    defer if (markTeardownComplete(&ui_deinitialized)) ui.deinit(renderer);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Initialize all session slots
    for (0..grid_layout.max_terminals) |i| {
        sessions_storage[i] = try SessionState.init(allocator, i, shell_path, size, notify_sock, theme);
        sessions[i] = &sessions_storage[i];
        init_count += 1;
    }

    // Restore persisted terminals
    for (restored_slice, 0..) |entry, new_idx| {
        if (new_idx >= sessions.len or entry.path.len == 0) continue;
        const dir_buf = allocZ(allocator, entry.path) catch |err| blk: {
            std.debug.print("Failed to restore terminal {d}: {}\n", .{ new_idx, err });
            break :blk null;
        };
        defer if (dir_buf) |buf| allocator.free(buf);
        if (dir_buf) |buf| {
            const dir: [:0]const u8 = buf[0..entry.path.len :0];
            sessions[new_idx].ensureSpawnedWithDir(dir, &loop) catch |err| {
                std.debug.print("Failed to spawn restored terminal {d}: {}\n", .{ new_idx, err });
            };
            if (sessions[new_idx].spawned) {
                seedSessionAgentMetadataFromEntry(sessions[new_idx], entry, allocator);
            }

            queueResumeCommand: {
                if (!sessions[new_idx].spawned) break :queueResumeCommand;
                const agent_type_str = entry.agent_type orelse break :queueResumeCommand;
                const session_id = entry.agent_session_id orelse break :queueResumeCommand;
                if (session_id.len == 0) break :queueResumeCommand;
                const agent_kind = session_state.AgentKind.fromString(agent_type_str) orelse break :queueResumeCommand;
                const resume_cmd = terminal_history.buildResumeCommand(allocator, agent_kind, session_id) catch |err| {
                    log.warn("failed to build resume command for session {d}: {}", .{ new_idx, err });
                    break :queueResumeCommand;
                };
                defer allocator.free(resume_cmd);
                // Write to pending_write; PTY input queues until the shell reads it after startup.
                sessions[new_idx].pending_write.appendSlice(allocator, resume_cmd) catch |err| {
                    log.warn("failed to queue resume command for session {d}: {}", .{ new_idx, err });
                };
            }
        }
    }

    // Always spawn at least the first terminal
    try sessions[0].ensureSpawnedWithLoop(&loop);

    init_count = sessions.len;

    const session_ui_info = try allocator.alloc(ui_mod.SessionUiInfo, grid_layout.max_terminals);
    defer allocator.free(session_ui_info);

    var render_cache = try renderer_mod.RenderCache.init(allocator, grid_layout.max_terminals);
    defer render_cache.deinit();

    var foreground_cache = ForegroundProcessCache{};

    var running = true;
    var persistence_dirty = false;
    var quit_teardown = QuitTeardownState{};
    defer quit_teardown.join();

    const initial_mode = initial_view_mode;
    var anim_state = AnimationState{
        .mode = initial_mode,
        .focused_session = 0,
        .previous_session = 0,
        .start_time = 0,
        .start_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .target_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
    var ime_composition = input_text.ImeComposition{};
    var last_focused_session: usize = anim_state.focused_session;
    var last_logged_mode = anim_state.mode;
    var relaunch_trace_frames: u8 = 0;
    var window_close_suppress_countdown: u8 = 0;

    const PendingCommentSend = struct {
        session: usize,
        text: []const u8,
        send_after_ms: i64,
    };
    var pending_comment_send: ?PendingCommentSend = null;

    const session_interaction_component = try ui_mod.SessionInteractionComponent.init(allocator, sessions, &font);
    try ui.register(session_interaction_component.asComponent());

    const worktree_comp_ptr = try allocator.create(ui_mod.worktree_overlay.WorktreeOverlayComponent);
    worktree_comp_ptr.* = .{ .allocator = allocator };
    const worktree_component = ui_mod.UiComponent{
        .ptr = worktree_comp_ptr,
        .vtable = &ui_mod.worktree_overlay.WorktreeOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(worktree_component);

    const recent_folders_comp_ptr = try allocator.create(ui_mod.recent_folders_overlay.RecentFoldersOverlayComponent);
    recent_folders_comp_ptr.* = .{ .allocator = allocator };
    const recent_folders_component = ui_mod.UiComponent{
        .ptr = recent_folders_comp_ptr,
        .vtable = &ui_mod.recent_folders_overlay.RecentFoldersOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(recent_folders_component);
    recent_folders_comp_ptr.setFolders(persistence.getRecentFolders());

    const help_comp_ptr = try allocator.create(ui_mod.help_overlay.HelpOverlayComponent);
    help_comp_ptr.* = .{ .allocator = allocator };
    const help_component = ui_mod.UiComponent{
        .ptr = help_comp_ptr,
        .vtable = &ui_mod.help_overlay.HelpOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(help_component);

    const pill_group_component = try ui_mod.pill_group.PillGroupComponent.create(allocator, help_comp_ptr, recent_folders_comp_ptr, worktree_comp_ptr);
    try ui.register(pill_group_component);
    const toast_component = try ui_mod.toast.ToastComponent.init(allocator);
    try ui.register(toast_component.asComponent());
    ui.toast_component = toast_component;
    const escape_component = try ui_mod.escape_hold.EscapeHoldComponent.init(allocator, &ui_font);
    try ui.register(escape_component.asComponent());
    const hotkey_component = try ui_mod.hotkey_indicator.HotkeyIndicatorComponent.init(allocator, &ui_font);
    try ui.register(hotkey_component.asComponent());
    ui.hotkey_component = hotkey_component;
    const restart_component = try ui_mod.restart_buttons.RestartButtonsComponent.init(allocator);
    try ui.register(restart_component.asComponent());
    const quit_confirm_component = try ui_mod.quit_confirm.QuitConfirmComponent.init(allocator);
    try ui.register(quit_confirm_component.asComponent());
    const quit_blocking_overlay_component = try ui_mod.quit_blocking_overlay.QuitBlockingOverlayComponent.init(allocator);
    try ui.register(quit_blocking_overlay_component.asComponent());
    const confirm_dialog_component = try ui_mod.confirm_dialog.ConfirmDialogComponent.init(allocator);
    try ui.register(confirm_dialog_component.asComponent());
    const global_shortcuts_component = try ui_mod.global_shortcuts.GlobalShortcutsComponent.create(allocator);
    try ui.register(global_shortcuts_component);
    const cwd_bar_component = try ui_mod.cwd_bar.CwdBarComponent.init(allocator);
    try ui.register(cwd_bar_component.asComponent());
    const metrics_overlay_component = try ui_mod.metrics_overlay.MetricsOverlayComponent.init(allocator);
    try ui.register(metrics_overlay_component.asComponent());
    const diff_overlay_component = try ui_mod.diff_overlay.DiffOverlayComponent.init(allocator);
    try ui.register(diff_overlay_component.asComponent());
    const reader_overlay_component = try ui_mod.reader_overlay.ReaderOverlayComponent.init(allocator, sessions);
    try ui.register(reader_overlay_component.asComponent());
    const story_overlay_component = try ui_mod.story_overlay.StoryOverlayComponent.init(allocator);
    try ui.register(story_overlay_component.asComponent());

    // Main loop: optionally wait for the next wake-worthy event, then handle SDL
    // input, feed PTY output into terminals, apply async notifications, drive
    // animations, and render at the current cadence.
    var last_render_ns: i128 = 0;
    var next_frame_wait: FrameWaitDecision = .none;
    while (running) {
        var next_event = waitForNextFrame(next_frame_wait);
        const frame_start_ns: i128 = std.time.nanoTimestamp();
        const now = std.time.milliTimestamp();
        if (relaunch_trace_frames > 0) {
            log.info("frame trace start mode={s} grid_resizing={} grid={d}x{d}", .{
                @tagName(anim_state.mode),
                grid.is_resizing,
                grid.cols,
                grid.rows,
            });
        }

        var event: c.SDL_Event = undefined;
        var processed_event = false;
        while (true) {
            if (next_event) |ready_event| {
                event = ready_event;
                next_event = null;
            } else if (!c.SDL_PollEvent(&event)) {
                break;
            }
            if (platform.isWakeEvent(&sdl, &event)) continue;
            if (anim_state.focused_session != last_focused_session) {
                const previous_session = last_focused_session;
                input_text.clearImeComposition(sessions[previous_session], &ime_composition) catch |err| {
                    std.debug.print("Failed to clear IME composition: {}\n", .{err});
                };
                ime_composition.reset();
                last_focused_session = anim_state.focused_session;
            }
            processed_event = true;
            var scaled_event = layout.scaleEventToRender(&event, scale_x, scale_y);
            if (builtin.os.tag == .macos and scaled_event.type == c.SDL_EVENT_KEY_DOWN) {
                const key = scaled_event.key.key;
                const mod = scaled_event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                if (has_gui and !has_blocking_mod and key == c.SDLK_W) {
                    // Use 2 frames to cover the delay between Cmd+W and SDL delivering a close request.
                    // A single frame is not always enough to suppress the close in the next loop.
                    window_close_suppress_countdown = 2;
                }
            }
            const focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
            const host_snapshot = ui_host.makeUiHost(
                now,
                render_width,
                render_height,
                ui_scale,
                cell_width_pixels,
                cell_height_pixels,
                grid.cols,
                grid.rows,
                full_cols,
                full_rows,
                &anim_state,
                sessions,
                session_ui_info,
                session_interaction_component.viewSlice(),
                focused_has_foreground_process,
                &theme,
            );
            var event_ui_host = host_snapshot;
            ui_host.applyMouseContext(&ui, &event_ui_host, &scaled_event);

            const ui_consumed = ui.handleEvent(&event_ui_host, &scaled_event);
            if (ui_consumed) continue;

            switch (scaled_event.type) {
                c.SDL_EVENT_QUIT => {
                    if (quit_teardown.active) continue;
                    if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                        if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                            running = false;
                        }
                    }
                },
                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (quit_teardown.active) continue;
                    if (builtin.os.tag == .macos and window_close_suppress_countdown > 0) {
                        // Reset immediately so we only suppress this close request.
                        window_close_suppress_countdown = 0;
                        continue;
                    }
                    if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                        if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                            running = false;
                        }
                    }
                },
                c.SDL_EVENT_WINDOW_DESTROYED => {
                    running = false;
                },
                c.SDL_EVENT_WINDOW_MOVED => {
                    window_x = scaled_event.window.data1;
                    window_y = scaled_event.window.data2;

                    persistence.window.x = window_x;
                    persistence.window.y = window_y;
                    persistence_dirty = true;
                    savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    layout.updateRenderSizes(sdl.window, &window_width_points, &window_height_points, &render_width, &render_height, &scale_x, &scale_y);
                    const prev_scale = ui_scale;
                    ui_scale = @max(scale_x, scale_y);
                    var scale_change_ctx = RuntimeScaleChangeContext{
                        .allocator = allocator,
                        .renderer = renderer,
                        .shared_font_cache = &shared_font_cache,
                        .ui_font_cache = &ui_font_cache,
                        .font_size = font_size,
                        .ui_scale = ui_scale,
                        .metrics_ptr = metrics_ptr,
                        .font = &font,
                        .ui_font = &ui_font,
                        .ui = &ui,
                        .sessions = sessions,
                        .render_width = render_width,
                        .render_height = render_height,
                        .anim_state = &anim_state,
                        .grid_cols = grid.cols,
                        .grid_rows = grid.rows,
                        .grid_font_scale = config.grid.font_scale,
                        .full_cols = &full_cols,
                        .full_rows = &full_rows,
                    };
                    try applyScaleChangeAndResize(
                        RuntimeScaleChangeContext,
                        font_mod.Font.InitError,
                        &scale_change_ctx,
                        prev_scale,
                        ui_scale,
                        reloadRuntimeFontsForScaleChange,
                        applyRuntimeResizeForScaleChange,
                    );
                    cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                    cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));

                    std.debug.print("Window resized to: {d}x{d} (render {d}x{d}), terminal size: {d}x{d}\n", .{ window_width_points, window_height_points, render_width, render_height, full_cols, full_rows });

                    persistence.window.width = window_width_points;
                    persistence.window.height = window_height_points;
                    persistence.window.x = window_x;
                    persistence.window.y = window_y;
                    persistence_dirty = true;
                    savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
                },
                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    if (builtin.os.tag == .macos) {
                        if (text_input_active) {
                            platform.stopTextInput(sdl.window);
                            text_input_active = false;
                        }
                    }
                    ime_composition.reset();
                },
                c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                    if (builtin.os.tag == .macos) {
                        input_source_tracker.restore() catch |err| {
                            log.warn("Failed to restore input source: {}", .{err});
                        };
                        // Reset text input so macOS restores the per-document input source.
                        if (text_input_active) {
                            platform.stopTextInput(sdl.window);
                        }
                        platform.startTextInput(sdl.window);
                        text_input_active = true;
                    }
                },
                c.SDL_EVENT_KEYMAP_CHANGED => {
                    if (builtin.os.tag == .macos) {
                        input_source_tracker.capture() catch |err| {
                            log.warn("Failed to capture input source: {}", .{err});
                        };
                    }
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const focused = sessions[anim_state.focused_session];
                    input_text.handleTextInput(focused, &ime_composition, scaled_event.text.text, session_interaction_component) catch |err| {
                        std.debug.print("Text input failed: {}\n", .{err});
                    };
                    if (anim_state.mode == .Grid) {
                        session_interaction_component.setAttention(anim_state.focused_session, false, now);
                    }
                },
                c.SDL_EVENT_TEXT_EDITING => {
                    const focused = sessions[anim_state.focused_session];
                    input_text.handleTextEditing(
                        focused,
                        &ime_composition,
                        scaled_event.edit.text,
                        scaled_event.edit.start,
                        scaled_event.edit.length,
                        session_interaction_component,
                    ) catch |err| {
                        std.debug.print("Edit input failed: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_DROP_FILE => {
                    const drop_path_ptr = scaled_event.drop.data;
                    if (drop_path_ptr == null) continue;
                    const drop_path = std.mem.span(drop_path_ptr.?);
                    if (drop_path.len == 0) continue;

                    const mouse_x: c_int = @intFromFloat(scaled_event.drop.x);
                    const mouse_y: c_int = @intFromFloat(scaled_event.drop.y);

                    const hovered_session = layout.calculateHoveredSession(
                        mouse_x,
                        mouse_y,
                        &anim_state,
                        cell_width_pixels,
                        cell_height_pixels,
                        render_width,
                        render_height,
                        grid.cols,
                        grid.rows,
                    ) orelse continue;

                    var session = sessions[hovered_session];
                    try session.ensureSpawnedWithLoop(&loop);

                    const escaped = worktree.shellQuotePath(allocator, drop_path) catch |err| {
                        std.debug.print("Failed to escape dropped path: {}\n", .{err});
                        continue;
                    };
                    defer allocator.free(escaped);

                    terminal_actions.pasteText(session, allocator, escaped, session_interaction_component) catch |err| switch (err) {
                        error.NoTerminal => ui.showToast("No terminal to paste into", now),
                        error.NoShell => ui.showToast("Shell not available", now),
                        else => std.debug.print("Failed to paste dropped path: {}\n", .{err}),
                    };
                },
                c.SDL_EVENT_KEY_DOWN => {
                    const key = scaled_event.key.key;
                    const mod = scaled_event.key.mod;
                    const focused = sessions[anim_state.focused_session];

                    const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                    const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                    const terminal_shortcut: ?usize = if (worktree_comp_ptr.overlay.state == .Closed)
                        input.terminalSwitchShortcut(key, mod, grid.cols * grid.rows)
                    else
                        null;

                    if (has_gui and !has_blocking_mod and key == c.SDLK_Q) {
                        if (quit_teardown.active) continue;
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘Q", now);
                        if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                            if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                                running = false;
                            }
                        }
                        continue;
                    }

                    if (has_gui and !has_blocking_mod and key == c.SDLK_W) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘W", now);
                        const session_idx = anim_state.focused_session;
                        const session = sessions[session_idx];

                        if (!session.spawned) {
                            log.info("close requested on unspawned session idx={d} mode={s}", .{ session_idx, @tagName(anim_state.mode) });
                            continue;
                        }

                        if (session.hasForegroundProcess()) {
                            confirm_dialog_component.show(
                                "Delete Terminal?",
                                "A process is running. Delete anyway?",
                                "Delete",
                                "Cancel",
                                .{ .DespawnSession = session_idx },
                            );
                        } else {
                            const spawned_count = countSpawnedSessions(sessions);
                            log.info("close requested idx={d} spawned_count={d} mode={s}", .{
                                session_idx,
                                spawned_count,
                                @tagName(anim_state.mode),
                            });
                            if (spawned_count == 1) {
                                var working_dir = WorkingDir.init(allocator, session.cwd_path);
                                defer working_dir.deinit(allocator);

                                log.info("relaunching last session idx={d} grid_resizing={}", .{
                                    session_idx,
                                    grid.is_resizing,
                                });
                                relaunch_trace_frames = 120;
                                try session.relaunch(working_dir.cwd_z, &loop);
                                session_interaction_component.resetView(session_idx);
                                session_interaction_component.setStatus(session_idx, .running);
                                session_interaction_component.setAttention(session_idx, false, now);
                                session.markDirty();
                                grid.cancelResize();
                                log.info("relaunch complete idx={d} spawned={} dead={}", .{
                                    session_idx,
                                    session.spawned,
                                    session.dead,
                                });
                                anim_state.mode = .Full;
                                continue;
                            }

                            // If in full view, collapse to grid first
                            if (anim_state.mode == .Full) {
                                if (animations_enabled) {
                                    grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                                } else {
                                    anim_state.mode = .Grid;
                                }
                            }

                            var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
                            defer if (old_positions) |*snapshots| {
                                snapshots.deinit(allocator);
                            };
                            if (animations_enabled and anim_state.mode == .Grid) {
                                old_positions = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
                                    std.debug.print("Failed to snapshot session positions: {}\n", .{err});
                                    break :blk null;
                                };
                            }

                            // Close the terminal
                            session.despawn(allocator);
                            session_interaction_component.resetView(session_idx);
                            session.markDirty();

                            compactSessions(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state);

                            // Count remaining spawned sessions after closing
                            const remaining_count = countSpawnedSessions(sessions);
                            const max_spawned_idx = highestSpawnedIndex(sessions);
                            const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

                            // Don't shrink below 1 terminal
                            if (remaining_count == 0) {
                                // Re-spawn a fresh terminal in slot 0
                                try sessions[0].ensureSpawnedWithLoop(&loop);
                                anim_state.focused_session = 0;
                                grid.cols = 1;
                                grid.rows = 1;
                                cell_width_pixels = render_width;
                                cell_height_pixels = render_height;
                                anim_state.mode = .Full;
                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                            } else if (remaining_count == 1) {
                                // Only 1 terminal remains - go directly to Full mode, no resize animation
                                grid.cols = 1;
                                grid.rows = 1;
                                cell_width_pixels = render_width;
                                cell_height_pixels = render_height;
                                if (!sessions[anim_state.focused_session].spawned) {
                                    for (sessions, 0..) |s, idx| {
                                        if (s.spawned) {
                                            anim_state.focused_session = idx;
                                            break;
                                        }
                                    }
                                }
                                anim_state.mode = .Full;
                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                            } else {
                                const new_dims = GridLayout.calculateDimensions(required_slots);
                                const should_shrink = new_dims.cols < grid.cols or new_dims.rows < grid.rows;

                                if (should_shrink) {
                                    const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                                    const grid_will_resize = new_dims.cols != grid.cols or new_dims.rows != grid.rows;
                                    if (can_animate_reflow) {
                                        if (old_positions) |snapshots| {
                                            var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                                break :blk null;
                                            };
                                            if (move_result) |*moves| {
                                                defer moves.list.deinit(allocator);
                                                if (grid_will_resize or moves.moved) {
                                                    grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                        std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                                    };
                                                    anim_state.mode = .GridResizing;
                                                } else {
                                                    grid.cols = new_dims.cols;
                                                    grid.rows = new_dims.rows;
                                                }
                                            } else {
                                                grid.cols = new_dims.cols;
                                                grid.rows = new_dims.rows;
                                            }
                                        } else {
                                            grid.cols = new_dims.cols;
                                            grid.rows = new_dims.rows;
                                        }
                                    } else {
                                        grid.cols = new_dims.cols;
                                        grid.rows = new_dims.rows;
                                    }

                                    cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                                    cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                                    applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);

                                    // Update focus to a valid session
                                    if (!sessions[anim_state.focused_session].spawned) {
                                        var new_focus: usize = 0;
                                        for (sessions, 0..) |s, idx| {
                                            if (s.spawned) {
                                                new_focus = idx;
                                                break;
                                            }
                                        }
                                        anim_state.focused_session = new_focus;
                                    }

                                    std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ grid.cols, grid.rows, remaining_count });
                                } else {
                                    const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                                    if (can_animate_reflow) {
                                        if (old_positions) |snapshots| {
                                            var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                                break :blk null;
                                            };
                                            if (move_result) |*moves| {
                                                defer moves.list.deinit(allocator);
                                                if (moves.moved) {
                                                    grid.startResize(grid.cols, grid.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                        std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                                                    };
                                                    anim_state.mode = .GridResizing;
                                                }
                                            }
                                        }
                                    }
                                    // Grid doesn't need to shrink, just update focus if needed
                                    if (!sessions[anim_state.focused_session].spawned) {
                                        // Find the next spawned session
                                        var new_focus: usize = 0;
                                        for (sessions, 0..) |s, idx| {
                                            if (s.spawned) {
                                                new_focus = idx;
                                                break;
                                            }
                                        }
                                        anim_state.focused_session = new_focus;
                                    }
                                }
                            }
                        }
                        continue;
                    }

                    if (key == c.SDLK_K and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘K", now);
                        terminal_actions.clearTerminal(focused);
                        ui.showToast("Cleared terminal", now);
                    } else if (key == c.SDLK_C and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘C", now);
                        terminal_actions.copySelectionToClipboard(focused, allocator, &ui, now) catch |err| {
                            std.debug.print("Copy failed: {}\n", .{err});
                        };
                    } else if (key == c.SDLK_V and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘V", now);
                        terminal_actions.pasteClipboardIntoSession(focused, allocator, &ui, now, session_interaction_component) catch |err| {
                            std.debug.print("Paste failed: {}\n", .{err});
                        };
                    } else if (input.fontSizeShortcut(key, mod)) |direction| {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(if (direction == .increase) "⌘+" else "⌘-", now);
                        const delta: c_int = if (direction == .increase) font_step else -font_step;
                        const target_size = std.math.clamp(font_size + delta, min_font_size, max_font_size);

                        if (target_size != font_size) {
                            const new_font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(target_size, ui_scale));
                            font.deinit();
                            font = new_font;
                            font.metrics = metrics_ptr;
                            font_size = target_size;

                            applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                            std.debug.print("Font size -> {d}px, terminal size: {d}x{d}\n", .{ font_size, full_cols, full_rows });

                            persistence.font_size = font_size;
                            persistence_dirty = true;
                            savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
                        }

                        var notification_buf: [64]u8 = undefined;
                        const notification_msg = std.fmt.bufPrint(&notification_buf, "Font size: {d}pt", .{font_size}) catch "Font size changed";
                        ui.showToast(notification_msg, now);
                    } else if (key == c.SDLK_N and has_gui and !has_blocking_mod and (anim_state.mode == .Full or anim_state.mode == .Grid)) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘N", now);

                        // Count currently spawned sessions
                        const spawned_count = countSpawnedSessions(sessions);

                        // Check if we need to expand the grid
                        if (grid.needsExpansion(spawned_count)) {
                            // Calculate new grid dimensions
                            const new_dims = GridLayout.calculateDimensions(spawned_count + 1);
                            if (new_dims.cols * new_dims.rows > grid_layout.max_terminals) {
                                ui.showToast("Maximum terminals reached", now);
                                continue;
                            }

                            // Get working directory from focused session
                            var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                            defer working_dir.deinit(allocator);

                            const new_capacity = new_dims.cols * new_dims.rows;
                            const new_idx = findNextFreeSlotAfter(sessions, new_capacity, anim_state.focused_session) orelse {
                                ui.showToast("All terminals in use", now);
                                continue;
                            };

                            // Collect active sessions for animation
                            var moves = collectSessionMovesCurrent(sessions, allocator) catch |err| {
                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                continue;
                            };
                            defer moves.deinit(allocator);

                            // Update grid dimensions and start animation
                            if (animations_enabled) {
                                grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.items) catch |err| {
                                    std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                };
                                anim_state.mode = .GridResizing;
                            } else {
                                grid.cols = new_dims.cols;
                                grid.rows = new_dims.rows;
                            }

                            // Spawn new terminal
                            try sessions[new_idx].ensureSpawnedWithDir(working_dir.cwd_z, &loop);
                            session_interaction_component.setStatus(new_idx, .running);
                            session_interaction_component.setAttention(new_idx, false, now);

                            // Update cell dimensions for new grid
                            cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                            cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                            applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);

                            session_interaction_component.clearSelection(anim_state.focused_session);
                            session_interaction_component.clearSelection(new_idx);

                            anim_state.previous_session = anim_state.focused_session;
                            anim_state.focused_session = new_idx;

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, new_idx, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);
                            std.debug.print("Grid expanded to {d}x{d}, new terminal at index {d}\n", .{ grid.cols, grid.rows, new_idx });
                        } else {
                            // Grid has space, find next free slot
                            const target_idx: ?usize = if (!focused.spawned)
                                anim_state.focused_session
                            else
                                findNextFreeSlotAfter(sessions, grid.capacity(), anim_state.focused_session);

                            if (target_idx) |next_free_idx| {
                                var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                                defer working_dir.deinit(allocator);

                                try sessions[next_free_idx].ensureSpawnedWithDir(working_dir.cwd_z, &loop);
                                session_interaction_component.setStatus(next_free_idx, .running);
                                session_interaction_component.setAttention(next_free_idx, false, now);

                                session_interaction_component.clearSelection(anim_state.focused_session);
                                session_interaction_component.clearSelection(next_free_idx);

                                anim_state.previous_session = anim_state.focused_session;
                                anim_state.focused_session = next_free_idx;

                                const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                                const notification_buf = try allocator.alloc(u8, buf_size);
                                defer allocator.free(notification_buf);
                                const notification_msg = try grid_nav.formatGridNotification(notification_buf, next_free_idx, grid.cols, grid.rows);
                                ui.showToast(notification_msg, now);
                            } else {
                                ui.showToast("All terminals in use", now);
                            }
                        }
                    } else if (terminal_shortcut) |idx| {
                        const hotkey_label = input.terminalHotkeyLabel(idx) orelse "⌘?";
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(hotkey_label, now);

                        if (anim_state.mode == .Grid) {
                            try sessions[idx].ensureSpawnedWithLoop(&loop);
                            session_interaction_component.setStatus(idx, .running);
                            session_interaction_component.setAttention(idx, false, now);

                            const grid_row: c_int = @intCast(idx / grid.cols);
                            const grid_col: c_int = @intCast(idx % grid.cols);
                            const start_rect = Rect{
                                .x = grid_col * cell_width_pixels,
                                .y = grid_row * cell_height_pixels,
                                .w = cell_width_pixels,
                                .h = cell_height_pixels,
                            };
                            const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                            anim_state.focused_session = idx;
                            if (animations_enabled) {
                                anim_state.mode = .Expanding;
                                anim_state.start_time = now;
                                anim_state.start_rect = start_rect;
                                anim_state.target_rect = target_rect;
                            } else {
                                anim_state.mode = .Full;
                                anim_state.start_time = now;
                                anim_state.start_rect = target_rect;
                                anim_state.target_rect = target_rect;
                                anim_state.previous_session = idx;
                            }
                            std.debug.print("Expanding session via hotkey: {d}\n", .{idx});
                        } else if (anim_state.mode == .Full and idx != anim_state.focused_session) {
                            try sessions[idx].ensureSpawnedWithLoop(&loop);
                            session_interaction_component.clearSelection(anim_state.focused_session);
                            session_interaction_component.clearSelection(idx);
                            session_interaction_component.setStatus(idx, .running);
                            session_interaction_component.setAttention(idx, false, now);
                            anim_state.focused_session = idx;

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, idx, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);
                            std.debug.print("Switched to session via hotkey: {d}\n", .{idx});
                        }
                    } else if (input.gridNavShortcut(key, mod)) |direction| {
                        if (anim_state.mode == .Grid) {
                            if (config.ui.show_hotkey_feedback) {
                                const arrow = switch (direction) {
                                    .up => "⌘↑",
                                    .down => "⌘↓",
                                    .left => "⌘←",
                                    .right => "⌘→",
                                };
                                ui.showHotkey(arrow, now);
                            }
                            try grid_nav.navigateGrid(&anim_state, sessions, session_interaction_component, direction, now, true, false, grid.cols, grid.rows, &loop);
                            const new_session = anim_state.focused_session;
                            session_interaction_component.triggerNavWave(new_session, now);
                            std.debug.print("Grid nav to session {d} (with wrapping)\n", .{new_session});
                        } else if (anim_state.mode == .Full) {
                            if (config.ui.show_hotkey_feedback) {
                                const arrow = switch (direction) {
                                    .up => "⌘↑",
                                    .down => "⌘↓",
                                    .left => "⌘←",
                                    .right => "⌘→",
                                };
                                ui.showHotkey(arrow, now);
                            }
                            try grid_nav.navigateGrid(&anim_state, sessions, session_interaction_component, direction, now, true, animations_enabled, grid.cols, grid.rows, &loop);

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, anim_state.focused_session, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);

                            std.debug.print("Full mode grid nav to session {d}\n", .{anim_state.focused_session});
                        } else {
                            if (focused.spawned and !focused.dead) {
                                session_interaction_component.resetScrollIfNeeded(anim_state.focused_session);
                                try input_keys.handleKeyInput(focused, key, mod);
                            }
                        }
                    } else if (key == c.SDLK_RETURN and (mod & c.SDL_KMOD_GUI) != 0 and anim_state.mode == .Grid) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘↵", now);
                        if (countSpawnedSessions(sessions) == 1) {
                            continue;
                        }
                        const clicked_session = anim_state.focused_session;
                        try sessions[clicked_session].ensureSpawnedWithLoop(&loop);

                        session_interaction_component.setStatus(clicked_session, .running);
                        session_interaction_component.setAttention(clicked_session, false, now);

                        const grid_row: c_int = @intCast(clicked_session / grid.cols);
                        const grid_col: c_int = @intCast(clicked_session % grid.cols);
                        const start_rect = Rect{
                            .x = grid_col * cell_width_pixels,
                            .y = grid_row * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                        const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                        anim_state.focused_session = clicked_session;
                        if (animations_enabled) {
                            anim_state.mode = .Expanding;
                            anim_state.start_time = now;
                            anim_state.start_rect = start_rect;
                            anim_state.target_rect = target_rect;
                        } else {
                            anim_state.mode = .Full;
                            anim_state.start_time = now;
                            anim_state.start_rect = target_rect;
                            anim_state.target_rect = target_rect;
                            anim_state.previous_session = clicked_session;
                        }
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    } else if (focused.spawned and !focused.dead and !input_keys.isModifierKey(key)) {
                        session_interaction_component.resetScrollIfNeeded(anim_state.focused_session);
                        if (anim_state.mode == .Grid) {
                            session_interaction_component.setAttention(anim_state.focused_session, false, now);
                        }
                        try input_keys.handleKeyInput(focused, key, mod);
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    const key = scaled_event.key.key;
                    if (key == c.SDLK_ESCAPE and input.canHandleEscapePress(anim_state.mode)) {
                        const focused = sessions[anim_state.focused_session];
                        if (focused.spawned and !focused.dead and focused.shell != null) {
                            const esc_byte: [1]u8 = .{27};
                            _ = focused.shell.?.write(&esc_byte) catch |err| {
                                log.warn("session {d}: failed to send escape key: {}", .{ anim_state.focused_session, err });
                            };
                        }
                        std.debug.print("Escape released, sent to terminal\n", .{});
                    }
                },
                else => {},
            }
        }

        if (!running) break;

        loop.run(.no_wait) catch |err| {
            log.err("xev loop run failed: {}", .{err});
            return err;
        };
        if (relaunch_trace_frames > 0) {
            log.info("frame trace after xev run", .{});
        }

        for (sessions) |session| {
            if (relaunch_trace_frames > 0 and session.spawned) {
                log.info("frame trace before process session idx={d} id={d}", .{ session.slot_index, session.id });
            }
            session.checkAlive();
            session.processOutput() catch |err| {
                log.err("session {d}: process output failed: {}", .{ session.id, err });
                return err;
            };
            session.flushPendingWrites() catch |err| {
                log.err("session {d}: flush pending writes failed: {}", .{ session.id, err });
                return err;
            };
            const prev_cwd_ptr = if (session.cwd_path) |p| p.ptr else null;
            session.updateCwd(now);
            _ = session.expireSynchronizedOutput(now);
            if (session.cwd_path) |new_cwd| {
                // Compare pointers: if they differ, cwd changed (and old memory was freed by updateCwd)
                const changed = prev_cwd_ptr == null or prev_cwd_ptr != new_cwd.ptr;
                if (changed and session.cwd_settled) {
                    persistence.appendRecentFolder(allocator, new_cwd) catch |err| {
                        log.warn("failed to update recent folders: {}", .{err});
                    };
                    recent_folders_comp_ptr.setFolders(persistence.getRecentFolders());
                    persistence_dirty = true;
                }
            }
            if (relaunch_trace_frames > 0 and session.spawned) {
                log.info("frame trace after process session idx={d} id={d}", .{ session.slot_index, session.id });
            }
        }

        const terminal_entries_changed = syncPersistenceTerminalEntriesFromSessions(&persistence, sessions, allocator) catch |err| blk: {
            log.warn("failed to sync terminal persistence state: {}", .{err});
            break :blk false;
        };
        if (terminal_entries_changed) {
            persistence_dirty = true;
        }
        savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);

        if (quit_teardown.isFinished()) {
            running = false;
        }
        var any_session_dirty = render_cache.anyDirty(sessions);

        var control_requests = control_queue.drainAll();
        defer control_requests.deinit(allocator);
        const had_control_requests = control_requests.items.len > 0;
        for (control_requests.items) |*request| {
            handleExternalSpawnRequest(
                allocator,
                request,
                sessions,
                &grid,
                &anim_state,
                session_interaction_component,
                &loop,
                animations_enabled,
                now,
                render_width,
                render_height,
                ui_scale,
                &font,
                config.grid.font_scale,
                &full_cols,
                &full_rows,
                &cell_width_pixels,
                &cell_height_pixels,
            );
            request.request.deinit(allocator);
        }

        var notifications = notify_queue.drainAll();
        defer notifications.deinit(allocator);
        const had_notifications = notifications.items.len > 0;
        for (notifications.items) |note| {
            switch (note) {
                .status => |s| {
                    const session_idx = findSessionIndexById(sessions, s.session) orelse continue;
                    session_interaction_component.setStatus(session_idx, s.state);
                    const wants_attention = switch (s.state) {
                        .awaiting_approval, .done => true,
                        else => false,
                    };
                    const is_focused_full = anim_state.mode == .Full and anim_state.focused_session == session_idx;
                    session_interaction_component.setAttention(session_idx, if (is_focused_full) false else wants_attention, now);
                    std.debug.print("Session {d} (slot {d}) status -> {s}\n", .{ s.session, session_idx, @tagName(s.state) });
                },
                .story => |s| {
                    if (!story_overlay_component.show(s.path, now)) {
                        ui.showToast("Failed to open story file", now);
                    }
                    allocator.free(s.path);
                },
            }
        }

        if (pending_comment_send) |pcs| {
            const prompt_ready = pcs.session < sessions.len and
                agentProcessStarted(sessions[pcs.session]);
            if (now >= pcs.send_after_ms or prompt_ready) {
                if (pcs.session < sessions.len) {
                    sessions[pcs.session].sendInput(pcs.text) catch |err| {
                        log.warn("failed to send pending diff comments: {}", .{err});
                    };
                }
                allocator.free(pcs.text);
                pending_comment_send = null;
            }
        }

        var focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
        const ui_update_host = ui_host.makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid.cols,
            grid.rows,
            full_cols,
            full_rows,
            &anim_state,
            sessions,
            session_ui_info,
            session_interaction_component.viewSlice(),
            focused_has_foreground_process,
            &theme,
        );
        ui.update(&ui_update_host);

        ui_action_loop: while (ui.popAction()) |action| switch (action) {
            .RestartSession => |idx| {
                if (idx < sessions.len) {
                    try sessions[idx].restart();
                    session_interaction_component.resetView(idx);
                    std.debug.print("UI requested restart: {d}\n", .{idx});
                }
            },
            .FocusSession => |idx| {
                if (anim_state.mode != .Grid) continue;
                if (idx >= sessions.len) continue;

                session_interaction_component.clearSelection(anim_state.focused_session);
                try sessions[idx].ensureSpawnedWithLoop(&loop);
                session_interaction_component.setStatus(idx, .running);
                session_interaction_component.setAttention(idx, false, now);

                const grid_row: c_int = @intCast(idx / grid.cols);
                const grid_col: c_int = @intCast(idx % grid.cols);
                const cell_rect = Rect{
                    .x = grid_col * cell_width_pixels,
                    .y = grid_row * cell_height_pixels,
                    .w = cell_width_pixels,
                    .h = cell_height_pixels,
                };
                const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                anim_state.focused_session = idx;
                if (animations_enabled) {
                    anim_state.mode = .Expanding;
                    anim_state.start_time = now;
                    anim_state.start_rect = cell_rect;
                    anim_state.target_rect = target_rect;
                } else {
                    anim_state.mode = .Full;
                    anim_state.start_time = now;
                    anim_state.start_rect = target_rect;
                    anim_state.target_rect = target_rect;
                    anim_state.previous_session = idx;
                }
                std.debug.print("Expanding session: {d}\n", .{idx});
            },
            .DespawnSession => |idx| {
                if (idx < sessions.len) {
                    if (anim_state.mode == .Full and anim_state.focused_session == idx) {
                        if (animations_enabled) {
                            grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                        } else {
                            anim_state.mode = .Grid;
                        }
                    }
                    log.info("ui despawn requested idx={d} mode={s} spawned_count={d}", .{
                        idx,
                        @tagName(anim_state.mode),
                        countSpawnedSessions(sessions),
                    });
                    var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
                    defer if (old_positions) |*snapshots| {
                        snapshots.deinit(allocator);
                    };
                    if (animations_enabled and anim_state.mode == .Grid) {
                        old_positions = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
                            std.debug.print("Failed to snapshot session positions: {}\n", .{err});
                            break :blk null;
                        };
                    }
                    sessions[idx].despawn(allocator);
                    session_interaction_component.resetView(idx);
                    sessions[idx].markDirty();
                    compactSessions(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state);
                    std.debug.print("UI requested despawn: {d}\n", .{idx});

                    // Handle grid contraction
                    const remaining_count = countSpawnedSessions(sessions);
                    const max_spawned_idx = highestSpawnedIndex(sessions);
                    const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

                    if (remaining_count == 0) {
                        // Re-spawn a fresh terminal in slot 0
                        sessions[0].ensureSpawnedWithLoop(&loop) catch |err| {
                            std.debug.print("Failed to respawn terminal: {}\n", .{err});
                        };
                        anim_state.focused_session = 0;
                        grid.cols = 1;
                        grid.rows = 1;
                        cell_width_pixels = render_width;
                        cell_height_pixels = render_height;
                        anim_state.mode = .Full;
                        applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                    } else if (remaining_count == 1) {
                        // Only 1 terminal remains - go directly to Full mode, no resize animation
                        grid.cols = 1;
                        grid.rows = 1;
                        cell_width_pixels = render_width;
                        cell_height_pixels = render_height;
                        if (!sessions[anim_state.focused_session].spawned) {
                            for (sessions, 0..) |s, i| {
                                if (s.spawned) {
                                    anim_state.focused_session = i;
                                    break;
                                }
                            }
                        }
                        anim_state.mode = .Full;
                        applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);
                    } else {
                        const new_dims = GridLayout.calculateDimensions(required_slots);
                        const should_shrink = new_dims.cols < grid.cols or new_dims.rows < grid.rows;
                        if (should_shrink) {
                            const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                            const grid_will_resize = new_dims.cols != grid.cols or new_dims.rows != grid.rows;
                            if (can_animate_reflow) {
                                if (old_positions) |snapshots| {
                                    var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                        std.debug.print("Failed to collect session moves: {}\n", .{err});
                                        break :blk null;
                                    };
                                    if (move_result) |*moves| {
                                        defer moves.list.deinit(allocator);
                                        if (grid_will_resize or moves.moved) {
                                            grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                            };
                                            anim_state.mode = .GridResizing;
                                        } else {
                                            grid.cols = new_dims.cols;
                                            grid.rows = new_dims.rows;
                                        }
                                    } else {
                                        grid.cols = new_dims.cols;
                                        grid.rows = new_dims.rows;
                                    }
                                } else {
                                    grid.cols = new_dims.cols;
                                    grid.rows = new_dims.rows;
                                }
                            } else {
                                grid.cols = new_dims.cols;
                                grid.rows = new_dims.rows;
                            }

                            cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                            cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                            applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, config.grid.font_scale, &full_cols, &full_rows);

                            if (!sessions[anim_state.focused_session].spawned) {
                                var new_focus: usize = 0;
                                for (sessions, 0..) |s, i| {
                                    if (s.spawned) {
                                        new_focus = i;
                                        break;
                                    }
                                }
                                anim_state.focused_session = new_focus;
                            }
                            std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ grid.cols, grid.rows, remaining_count });
                        } else {
                            const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                            if (can_animate_reflow) {
                                if (old_positions) |snapshots| {
                                    var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                        std.debug.print("Failed to collect session moves: {}\n", .{err});
                                        break :blk null;
                                    };
                                    if (move_result) |*moves| {
                                        defer moves.list.deinit(allocator);
                                        if (moves.moved) {
                                            grid.startResize(grid.cols, grid.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                                            };
                                            anim_state.mode = .GridResizing;
                                        }
                                    }
                                }
                            }
                            if (!sessions[anim_state.focused_session].spawned) {
                                var new_focus: usize = 0;
                                for (sessions, 0..) |s, i| {
                                    if (s.spawned) {
                                        new_focus = i;
                                        break;
                                    }
                                }
                                anim_state.focused_session = new_focus;
                            }
                        }
                    }
                }
            },
            .RequestCollapseFocused => {
                if (anim_state.mode == .Full) {
                    const spawned_count = countSpawnedSessions(sessions);
                    if (spawned_count == 1) {
                        std.debug.print("UI requested collapse ignored (single terminal)\n", .{});
                    } else if (animations_enabled) {
                        grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                    } else {
                        const grid_row: c_int = @intCast(anim_state.focused_session / grid.cols);
                        const grid_col: c_int = @intCast(anim_state.focused_session % grid.cols);
                        anim_state.mode = .Grid;
                        anim_state.start_time = now;
                        anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };
                        anim_state.target_rect = Rect{
                            .x = grid_col * cell_width_pixels,
                            .y = grid_row * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                    }
                    std.debug.print("UI requested collapse of focused session: {d}\n", .{anim_state.focused_session});
                }
            },
            .ConfirmQuit => {
                if (!quit_teardown.active) {
                    if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                        running = false;
                    }
                }
            },
            .OpenConfig => {
                if (config_mod.Config.getConfigPath(allocator)) |config_path| {
                    defer allocator.free(config_path);
                    if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘,", now);

                    const result = switch (builtin.os.tag) {
                        .macos => blk: {
                            var child = std.process.Child.init(&.{ "open", "-t", config_path }, allocator);
                            break :blk child.spawn();
                        },
                        else => open_url.openUrl(allocator, config_path),
                    };
                    result catch |err| {
                        std.debug.print("Failed to open config file: {}\n", .{err});
                    };
                    ui.showToast("Opening config file", now);
                } else |err| {
                    std.debug.print("Failed to get config path: {}\n", .{err});
                }
            },
            .SwitchWorktree => |switch_action| {
                defer allocator.free(switch_action.path);
                if (switch_action.session >= sessions.len) continue;

                var session = sessions[switch_action.session];
                if (session.hasForegroundProcess()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }

                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                worktree.changeSessionDirectory(session, allocator, switch_action.path) catch |err| {
                    std.debug.print("Failed to change directory for session {d}: {}\n", .{ switch_action.session, err });
                    ui.showToast("Could not switch worktree", now);
                    continue;
                };

                session_interaction_component.setStatus(switch_action.session, .running);
                session_interaction_component.setAttention(switch_action.session, false, now);
                ui.showToast("Switched worktree", now);
            },
            .CreateWorktree => |create_action| {
                defer allocator.free(create_action.base_path);
                defer allocator.free(create_action.name);
                if (create_action.session >= sessions.len) continue;
                var session = sessions[create_action.session];

                if (session.hasForegroundProcess()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                const target_path = worktree.resolveWorktreeDir(
                    allocator,
                    create_action.base_path,
                    create_action.name,
                    config.worktree.directory,
                ) catch |err| {
                    std.debug.print("Failed to resolve worktree directory: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };
                defer allocator.free(target_path);

                const command = worktree.buildCreateWorktreeCommand(
                    allocator,
                    create_action.base_path,
                    target_path,
                    create_action.name,
                    config.worktree.init_command,
                ) catch |err| {
                    std.debug.print("Failed to build worktree command: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send worktree command: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };

                session.recordCwd(target_path) catch |err| {
                    log.warn("session {d}: failed to record cwd: {}", .{ create_action.session, err });
                };

                session_interaction_component.setStatus(create_action.session, .running);
                session_interaction_component.setAttention(create_action.session, false, now);
                ui.showToast("Creating worktree…", now);
            },
            .RemoveWorktree => |remove_action| {
                defer allocator.free(remove_action.path);
                if (remove_action.session >= sessions.len) continue;
                var session = sessions[remove_action.session];

                if (session.hasForegroundProcess()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                for (sessions, 0..) |other_session, idx| {
                    if (idx == remove_action.session) continue;
                    if (!other_session.spawned or other_session.dead) continue;

                    const other_cwd = other_session.cwd_path orelse continue;
                    if (std.mem.eql(u8, other_cwd, remove_action.path)) {
                        ui.showToast("Worktree in use by another session", now);
                        continue :ui_action_loop;
                    }
                    if (std.mem.startsWith(u8, other_cwd, remove_action.path)) {
                        const suffix = other_cwd[remove_action.path.len..];
                        if (suffix.len > 0 and suffix[0] == '/') {
                            ui.showToast("Worktree in use by another session", now);
                            continue :ui_action_loop;
                        }
                    }
                }

                const command = worktree.buildRemoveWorktreeCommand(allocator, remove_action.path) catch |err| {
                    std.debug.print("Failed to build remove worktree command: {}\n", .{err});
                    ui.showToast("Could not remove worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send remove worktree command: {}\n", .{err});
                    ui.showToast("Could not remove worktree", now);
                    continue;
                };

                session_interaction_component.setStatus(remove_action.session, .running);
                session_interaction_component.setAttention(remove_action.session, false, now);
                ui.showToast("Removing worktree…", now);
            },
            .ChangeDirectory => |cd_action| {
                defer allocator.free(cd_action.path);
                if (cd_action.session >= sessions.len) continue;

                var session = sessions[cd_action.session];
                if (session.hasForegroundProcess()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }

                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                worktree.changeSessionDirectory(session, allocator, cd_action.path) catch |err| {
                    std.debug.print("Failed to change directory for session {d}: {}\n", .{ cd_action.session, err });
                    ui.showToast("Could not change directory", now);
                    continue;
                };

                // Note: appendRecentFolder is handled by the per-frame updateCwd loop
                // to avoid double-counting when cwd changes are detected

                session_interaction_component.setStatus(cd_action.session, .running);
                session_interaction_component.setAttention(cd_action.session, false, now);

                const basename = std.fs.path.basename(cd_action.path);
                const toast_msg_buf = std.fmt.allocPrint(allocator, "Changed to {s}", .{basename}) catch null;
                const toast_msg = toast_msg_buf orelse "Changed directory";
                defer if (toast_msg_buf) |buf| allocator.free(buf);
                ui.showToast(toast_msg, now);
            },
            .ToggleMetrics => {
                if (config.metrics.enabled) {
                    metrics_overlay_component.toggle();
                    if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘⇧M", now);
                } else {
                    ui.showToast("Metrics disabled in config", now);
                }
            },
            .ToggleDiffOverlay => {
                const focused_cwd = if (anim_state.focused_session < sessions.len)
                    sessions[anim_state.focused_session].cwd_path
                else
                    null;
                switch (diff_overlay_component.toggle(focused_cwd, now)) {
                    .not_a_repo => ui.showToast("Not a git repository", now),
                    .clean => ui.showToast("Working tree clean", now),
                    .opened => if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘D", now),
                }
            },
            .ToggleReaderOverlay => {
                const focused_has_foreground = foreground_cache.get(now, anim_state.focused_session, sessions);
                const host_snapshot = ui_host.makeUiHost(
                    now,
                    render_width,
                    render_height,
                    ui_scale,
                    cell_width_pixels,
                    cell_height_pixels,
                    grid.cols,
                    grid.rows,
                    full_cols,
                    full_rows,
                    &anim_state,
                    sessions,
                    session_ui_info,
                    session_interaction_component.viewSlice(),
                    focused_has_foreground,
                    &theme,
                );
                switch (reader_overlay_component.toggle(&host_snapshot, now)) {
                    .opened => {
                        ui.showToast("Reader Mode", now);
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘R", now);
                    },
                    .closed => {},
                    .unavailable => ui.showToast("Reader mode requires a selected running terminal", now),
                }
            },
            .SendDiffComments => |dc_action| {
                if (dc_action.session >= sessions.len) {
                    allocator.free(dc_action.comments_text);
                    if (dc_action.agent_command) |cmd| allocator.free(cmd);
                    continue;
                }
                var dc_session = sessions[dc_action.session];
                if (dc_action.agent_command) |cmd| {
                    dc_session.sendInput(cmd) catch |err| {
                        log.warn("failed to send agent command: {}", .{err});
                        allocator.free(dc_action.comments_text);
                        allocator.free(cmd);
                        continue;
                    };
                    allocator.free(cmd);
                    if (pending_comment_send) |prev| allocator.free(prev.text);
                    pending_comment_send = .{
                        .session = dc_action.session,
                        .text = dc_action.comments_text,
                        .send_after_ms = now + 2000,
                    };
                } else {
                    dc_session.sendInput(dc_action.comments_text) catch |err| {
                        log.warn("failed to send diff comments: {}", .{err});
                    };
                    allocator.free(dc_action.comments_text);
                }
            },
            .OpenStory => |story_action| {
                if (!story_overlay_component.show(story_action.path, now)) {
                    ui.showToast("Failed to open story file", now);
                }
                allocator.free(story_action.path);
            },
        };

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing or
            anim_state.mode == .PanningLeft or anim_state.mode == .PanningRight or
            anim_state.mode == .PanningUp or anim_state.mode == .PanningDown)
        {
            if (anim_state.isComplete(now)) {
                const previous_mode = anim_state.mode;
                const next_mode = switch (anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => .Full,
                    .Collapsing => .Grid,
                    else => anim_state.mode,
                };
                anim_state.mode = next_mode;
                if (previous_mode == .Collapsing and next_mode == .Grid and anim_state.focused_session < sessions.len) {
                    sessions[anim_state.focused_session].markDirty();
                }
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        // Handle grid resize animation completion
        if (anim_state.mode == .GridResizing) {
            if (grid.updateResize(now)) {
                anim_state.mode = .Grid;
                // Mark all sessions dirty to refresh render cache
                for (sessions) |session| {
                    session.markDirty();
                }
                std.debug.print("Grid resize complete: {d}x{d}\n", .{ grid.cols, grid.rows });
            }
        }

        const terminal_layout_changed = applyTerminalLayoutIfSizeChanged(
            sessions,
            allocator,
            &font,
            render_width,
            render_height,
            ui_scale,
            &anim_state,
            grid.cols,
            grid.rows,
            config.grid.font_scale,
            &full_cols,
            &full_rows,
        );
        if (terminal_layout_changed) {
            any_session_dirty = true;
            std.debug.print("Terminal layout adjusted for {s}: {d}x{d}\n", .{
                @tagName(anim_state.mode),
                full_cols,
                full_rows,
            });
        }

        if (anim_state.mode != last_logged_mode) {
            emitViewModeTransitionEvents(last_logged_mode, anim_state.mode, anim_state.focused_session, countSpawnedSessions(sessions));
            last_logged_mode = anim_state.mode;
        }

        focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
        const ui_render_host = ui_host.makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid.cols,
            grid.rows,
            full_cols,
            full_rows,
            &anim_state,
            sessions,
            session_ui_info,
            session_interaction_component.viewSlice(),
            focused_has_foreground_process,
            &theme,
        );

        const animating = anim_state.mode != .Grid and anim_state.mode != .Full;
        const ui_needs_frame = ui.needsFrame(&ui_render_host);
        const last_render_stale = last_render_ns == 0 or (frame_start_ns - last_render_ns) >= max_idle_render_gap_ns;
        const should_render = animating or any_session_dirty or ui_needs_frame or processed_event or had_notifications or had_control_requests or last_render_stale;

        if (should_render) {
            if (relaunch_trace_frames > 0) {
                log.info("frame trace before render", .{});
            }
            renderer_mod.render(
                renderer,
                &render_cache,
                sessions,
                session_interaction_component.viewSlice(),
                cell_width_pixels,
                cell_height_pixels,
                grid.cols,
                grid.rows,
                &anim_state,
                now,
                &font,
                full_cols,
                full_rows,
                render_width,
                render_height,
                &theme,
                ui_scale,
                config.grid.font_scale,
                &grid,
            ) catch |err| {
                log.err("render failed: {}", .{err});
                return err;
            };
            ui.render(&ui_render_host, renderer);
            _ = c.SDL_RenderPresent(renderer);
            if (relaunch_trace_frames > 0) {
                log.info("frame trace after render", .{});
            }
            metrics_mod.increment(.frame_count);
            last_render_ns = std.time.nanoTimestamp();
        }

        if (relaunch_trace_frames > 0) {
            relaunch_trace_frames -= 1;
        }

        const is_idle = !animating and !any_session_dirty and !ui_needs_frame and !processed_event and !had_notifications and !had_control_requests;

        if (window_close_suppress_countdown > 0) {
            window_close_suppress_countdown -= 1;
        }

        const frame_end_ns: i128 = std.time.nanoTimestamp();
        const frame_ns = frame_end_ns - frame_start_ns;
        next_frame_wait = computeFrameWaitDecision(is_idle, sdl.vsync_enabled, frame_ns);
    }

    if (builtin.os.tag == .macos) {
        const now = std.time.milliTimestamp();
        for (sessions) |session| {
            session.updateCwd(now);
        }

        if (quit_teardown.active) {
            quit_blocking_overlay_component.setActive(false);
            quit_teardown.join();
            drainQuitCaptureOutput(quit_teardown.tasks[0..quit_teardown.task_count], sessions[0..]);
            for (quit_teardown.tasks[0..quit_teardown.task_count]) |task| {
                const session = sessions[task.session_idx];
                session.stopQuitCapture();
                if (session.agent_session_id) |sid| {
                    allocator.free(sid);
                    session.agent_session_id = null;
                }
                session.agent_kind = null;
                session.agent_metadata_captured = false;
                const text = session.quitCaptureBytes();
                log.debug("quit teardown: session {d} extracted {d} bytes of terminal text", .{ task.session_idx, text.len });
                if (terminal_history.extractLastUuid(text)) |uuid| {
                    log.info("quit teardown: session {d} captured session id: {s}", .{ task.session_idx, uuid });
                    session.agent_kind = task.agent_kind;
                    session.agent_session_id = allocator.dupe(u8, uuid) catch |err| blk: {
                        log.warn("quit teardown: session {d} failed to allocate session id: {}", .{ task.session_idx, err });
                        break :blk null;
                    };
                    if (session.agent_session_id != null) {
                        session.agent_metadata_captured = true;
                    }
                } else {
                    log.warn("quit teardown: session {d} agent {s} exited but no session id found in output", .{ task.session_idx, task.agent_kind.name() });
                }
            }
        }

        _ = syncPersistenceTerminalEntriesFromSessions(&persistence, sessions, allocator) catch |err| {
            std.debug.print("Failed to refresh terminal persistence: {}\n", .{err});
        };
    }

    persistence.save(allocator) catch |err| {
        std.debug.print("Failed to save persistence: {}\n", .{err});
    };
    persistence.deinit(allocator);
}

fn allocZ(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, data.len + 1);
    @memcpy(buf[0..data.len], data);
    buf[data.len] = 0;
    return buf;
}

test "planExternalSpawnSlot expands a full current grid" {
    var first: SessionState = undefined;
    first.spawned = true;
    var second: SessionState = undefined;
    second.spawned = false;
    var sessions = [_]*SessionState{ &first, &second };

    const plan = planExternalSpawnSlot(&sessions, 1, 1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(plan.expands_grid);
    try std.testing.expectEqual(@as(usize, 2), plan.cols);
    try std.testing.expectEqual(@as(usize, 1), plan.rows);
    try std.testing.expectEqual(@as(usize, 1), plan.slot_index);
}

test "planExternalSpawnSlot reuses free capacity" {
    var first: SessionState = undefined;
    first.spawned = true;
    var second: SessionState = undefined;
    second.spawned = false;
    var sessions = [_]*SessionState{ &first, &second };

    const plan = planExternalSpawnSlot(&sessions, 2, 1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!plan.expands_grid);
    try std.testing.expectEqual(@as(usize, 2), plan.cols);
    try std.testing.expectEqual(@as(usize, 1), plan.rows);
    try std.testing.expectEqual(@as(usize, 1), plan.slot_index);
}

test "planExternalSpawnSlot reports full grid" {
    var storage: [grid_layout.max_terminals]SessionState = undefined;
    var sessions: [grid_layout.max_terminals]*SessionState = undefined;
    for (&storage, 0..) |*session, idx| {
        session.* = undefined;
        session.spawned = true;
        sessions[idx] = session;
    }

    try std.testing.expect(planExternalSpawnSlot(&sessions, grid_layout.max_grid_size, grid_layout.max_grid_size, 0) == null);
}

test "validateExternalSpawnCwd accepts directories and rejects relative paths" {
    try std.testing.expect(validateExternalSpawnCwd("/tmp") == null);

    const failure = validateExternalSpawnCwd("relative/path") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(control.SpawnErrorCode.invalid_cwd, failure.code);
}

test "buildQueuedCommand appends a newline only when needed" {
    const allocator = std.testing.allocator;

    const first = try buildQueuedCommand(allocator, "echo ok");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("echo ok\n", first);

    const second = try buildQueuedCommand(allocator, "echo ok\n");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("echo ok\n", second);
}

test "waitTimeoutMsFromNs rounds up to whole milliseconds" {
    try std.testing.expectEqual(@as(c_int, 0), waitTimeoutMsFromNs(0));
    try std.testing.expectEqual(@as(c_int, 1), waitTimeoutMsFromNs(std.time.ns_per_ms - 1));
    try std.testing.expectEqual(@as(c_int, 50), waitTimeoutMsFromNs((49 * std.time.ns_per_ms) + 999_999));
}

test "computeFrameWaitDecision returns idle wait while idle" {
    const decision = computeFrameWaitDecision(true, false, 10 * std.time.ns_per_ms);
    switch (decision) {
        .idle_wait_ms => |timeout_ms| try std.testing.expectEqual(@as(c_int, 40), timeout_ms),
        else => try std.testing.expect(false),
    }
}

test "computeFrameWaitDecision keeps active pacing without vsync" {
    const decision = computeFrameWaitDecision(false, false, 5 * std.time.ns_per_ms);
    switch (decision) {
        .active_sleep_ns => |sleep_ns| try std.testing.expectEqual(@as(u64, active_frame_ns - (5 * std.time.ns_per_ms)), sleep_ns),
        else => try std.testing.expect(false),
    }
}

test "computeFrameWaitDecision defers to vsync while active" {
    const decision = computeFrameWaitDecision(false, true, 5 * std.time.ns_per_ms);
    switch (decision) {
        .none => {},
        else => try std.testing.expect(false),
    }
}

test "fullSetForMode promotes focused (and previous during panning) to full size" {
    try std.testing.expectEqual(@as(?usize, null), fullSetForMode(.Grid, 2, 7).primary);
    try std.testing.expectEqual(@as(?usize, null), fullSetForMode(.GridResizing, 2, 7).primary);

    const full = fullSetForMode(.Full, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), full.primary);
    try std.testing.expectEqual(@as(?usize, null), full.secondary);

    const expanding = fullSetForMode(.Expanding, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), expanding.primary);
    try std.testing.expectEqual(@as(?usize, null), expanding.secondary);

    const collapsing = fullSetForMode(.Collapsing, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), collapsing.primary);
    try std.testing.expectEqual(@as(?usize, null), collapsing.secondary);

    const pan = fullSetForMode(.PanningLeft, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), pan.primary);
    try std.testing.expectEqual(@as(?usize, 7), pan.secondary);
}

test "markTeardownComplete returns true only once" {
    var done = false;
    try std.testing.expect(markTeardownComplete(&done));
    try std.testing.expect(!markTeardownComplete(&done));
}

test "shouldContinueQuitCaptureDrain stops after quiet window" {
    const start_ns: i128 = 0;
    const last_growth_ns: i128 = 0;
    const at_quiet_boundary = quit_capture_drain_quiet_ns;
    try std.testing.expect(!shouldContinueQuitCaptureDrain(start_ns, last_growth_ns, at_quiet_boundary));

    const just_before_quiet = quit_capture_drain_quiet_ns - 1;
    try std.testing.expect(shouldContinueQuitCaptureDrain(start_ns, last_growth_ns, just_before_quiet));
}

test "shouldContinueQuitCaptureDrain stops after max window" {
    const start_ns: i128 = 0;
    const recent_growth_ns = quit_capture_drain_max_ns - 1;
    const at_max_boundary = quit_capture_drain_max_ns;
    try std.testing.expect(!shouldContinueQuitCaptureDrain(start_ns, recent_growth_ns, at_max_boundary));
}

const TestSwapError = error{InitFailed};

const TestResource = struct {
    id: u8,
    deinit_count: *usize,

    fn deinit(self: *TestResource) void {
        self.deinit_count.* += 1;
    }
};

const TestSwapContext = struct {
    fail_on: enum {
        none,
        first,
        second,
    } = .none,
    next_id: u8 = 10,
    new_deinit_count: usize = 0,
};

fn initTestResourceFirst(ctx: *TestSwapContext) TestSwapError!TestResource {
    if (ctx.fail_on == .first) return error.InitFailed;

    const id = ctx.next_id;
    ctx.next_id += 1;
    return .{
        .id = id,
        .deinit_count = &ctx.new_deinit_count,
    };
}

fn initTestResourceSecond(ctx: *TestSwapContext) TestSwapError!TestResource {
    if (ctx.fail_on == .second) return error.InitFailed;

    const id = ctx.next_id;
    ctx.next_id += 1;
    return .{
        .id = id,
        .deinit_count = &ctx.new_deinit_count,
    };
}

fn deinitTestResource(resource: *TestResource) void {
    resource.deinit();
}

test "swapTwoResources replaces both resources after successful initialization" {
    var first_deinit_count: usize = 0;
    var second_deinit_count: usize = 0;
    var first = TestResource{ .id = 1, .deinit_count = &first_deinit_count };
    var second = TestResource{ .id = 2, .deinit_count = &second_deinit_count };
    var ctx = TestSwapContext{};

    try swapTwoResources(
        TestResource,
        TestSwapContext,
        TestSwapError,
        &first,
        &second,
        &ctx,
        initTestResourceFirst,
        initTestResourceSecond,
        deinitTestResource,
    );

    try std.testing.expectEqual(@as(usize, 1), first_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), second_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), ctx.new_deinit_count);
    try std.testing.expectEqual(@as(u8, 10), first.id);
    try std.testing.expectEqual(@as(u8, 11), second.id);
}

test "swapTwoResources keeps old resources when second initialization fails" {
    var first_deinit_count: usize = 0;
    var second_deinit_count: usize = 0;
    var first = TestResource{ .id = 1, .deinit_count = &first_deinit_count };
    var second = TestResource{ .id = 2, .deinit_count = &second_deinit_count };
    var ctx = TestSwapContext{ .fail_on = .second };

    try std.testing.expectError(
        error.InitFailed,
        swapTwoResources(
            TestResource,
            TestSwapContext,
            TestSwapError,
            &first,
            &second,
            &ctx,
            initTestResourceFirst,
            initTestResourceSecond,
            deinitTestResource,
        ),
    );

    try std.testing.expectEqual(@as(usize, 0), first_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), second_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), ctx.new_deinit_count);
    try std.testing.expectEqual(@as(u8, 1), first.id);
    try std.testing.expectEqual(@as(u8, 2), second.id);
}

const TestScaleChangeError = error{ReloadFailed};

const TestScaleChangeContext = struct {
    reload_calls: usize = 0,
    resize_calls: usize = 0,
    fail_reload: bool = false,
};

fn reloadTestScaleChange(ctx: *TestScaleChangeContext) TestScaleChangeError!void {
    ctx.reload_calls += 1;
    if (ctx.fail_reload) return error.ReloadFailed;
}

fn resizeTestScaleChange(ctx: *TestScaleChangeContext) void {
    ctx.resize_calls += 1;
}

test "adjustedRenderHeightForMode reserves cwd bar only in stable grid mode" {
    const render_height: c_int = 800;
    const grid_height = adjustedRenderHeightForMode(.Grid, render_height, 1.0, 2);

    try std.testing.expect(grid_height < render_height);
    try std.testing.expectEqual(render_height, adjustedRenderHeightForMode(.Collapsing, render_height, 1.0, 2));
    try std.testing.expectEqual(render_height, adjustedRenderHeightForMode(.GridResizing, render_height, 1.0, 2));
    try std.testing.expectEqual(render_height, adjustedRenderHeightForMode(.Full, render_height, 1.0, 2));
}

test "applyScaleChangeAndResize reloads then resizes when scale changes" {
    var ctx = TestScaleChangeContext{};

    try applyScaleChangeAndResize(
        TestScaleChangeContext,
        TestScaleChangeError,
        &ctx,
        1.0,
        2.0,
        reloadTestScaleChange,
        resizeTestScaleChange,
    );

    try std.testing.expectEqual(@as(usize, 1), ctx.reload_calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.resize_calls);
}

test "applyScaleChangeAndResize only resizes when scale stays unchanged" {
    var ctx = TestScaleChangeContext{};

    try applyScaleChangeAndResize(
        TestScaleChangeContext,
        TestScaleChangeError,
        &ctx,
        1.0,
        1.0,
        reloadTestScaleChange,
        resizeTestScaleChange,
    );

    try std.testing.expectEqual(@as(usize, 0), ctx.reload_calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.resize_calls);
}

test "applyScaleChangeAndResize skips resize when reload fails" {
    var ctx = TestScaleChangeContext{ .fail_reload = true };

    try std.testing.expectError(
        error.ReloadFailed,
        applyScaleChangeAndResize(
            TestScaleChangeContext,
            TestScaleChangeError,
            &ctx,
            1.0,
            2.0,
            reloadTestScaleChange,
            resizeTestScaleChange,
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), ctx.reload_calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.resize_calls);
}

test "seedSessionAgentMetadataFromEntry seeds known restored metadata" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.slot_index = 3;
    session.agent_kind = null;
    session.agent_session_id = null;
    session.agent_metadata_captured = true;

    const entry = config_mod.Persistence.TerminalEntry{
        .path = "/tmp/test",
        .agent_type = "codex",
        .agent_session_id = "abc-123",
    };
    seedSessionAgentMetadataFromEntry(&session, entry, allocator);

    try std.testing.expect(session.agent_kind != null);
    try std.testing.expectEqual(session_state.AgentKind.codex, session.agent_kind.?);
    try std.testing.expect(session.agent_session_id != null);
    try std.testing.expectEqualStrings("abc-123", session.agent_session_id.?);
    try std.testing.expect(session.agent_session_id.?.ptr != entry.agent_session_id.?.ptr);
    try std.testing.expect(!session.agent_metadata_captured);

    if (session.agent_session_id) |sid| allocator.free(sid);
}

test "syncPersistenceTerminalEntriesFromSessions ignores restored agent metadata until quit capture" {
    const allocator = std.testing.allocator;

    var persistence = config_mod.Persistence.init(allocator);
    defer persistence.deinit(allocator);

    try persistence.appendTerminalEntry(allocator, "/one", "codex", "stale-seed");

    var session: SessionState = undefined;
    session.slot_index = 0;
    session.spawned = true;
    session.dead = false;
    session.cwd_path = "/one";
    session.agent_kind = null;
    session.agent_session_id = null;
    session.agent_metadata_captured = false;

    seedSessionAgentMetadataFromEntry(&session, persistence.terminal_entries.items[0], allocator);
    defer if (session.agent_session_id) |sid| allocator.free(sid);

    var sessions = [_]*SessionState{&session};

    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqual(@as(usize, 1), persistence.terminal_entries.items.len);
    try std.testing.expect(persistence.terminal_entries.items[0].agent_type == null);
    try std.testing.expect(persistence.terminal_entries.items[0].agent_session_id == null);
}

test "syncPersistenceTerminalEntriesFromSessions reacts to cd, spawn, and despawn" {
    const allocator = std.testing.allocator;

    var persistence = config_mod.Persistence.init(allocator);
    defer persistence.deinit(allocator);

    var sessions_storage: [2]SessionState = undefined;
    for (&sessions_storage) |*session| {
        session.* = undefined;
        session.spawned = false;
        session.dead = false;
        session.cwd_path = null;
        session.agent_kind = null;
        session.agent_session_id = null;
        session.agent_metadata_captured = false;
    }
    var sessions = [_]*SessionState{ &sessions_storage[0], &sessions_storage[1] };

    sessions_storage[0].spawned = true;
    sessions_storage[0].cwd_path = "/one";

    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqual(@as(usize, 1), persistence.terminal_entries.items.len);
    try std.testing.expectEqualStrings("/one", persistence.terminal_entries.items[0].path);

    sessions_storage[0].cwd_path = "/two";
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqualStrings("/two", persistence.terminal_entries.items[0].path);
    try std.testing.expect(!(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator)));

    sessions_storage[0].spawned = false;
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqual(@as(usize, 0), persistence.terminal_entries.items.len);

    sessions_storage[1].spawned = true;
    sessions_storage[1].cwd_path = "/three";
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqual(@as(usize, 1), persistence.terminal_entries.items.len);
    try std.testing.expectEqualStrings("/three", persistence.terminal_entries.items[0].path);

    sessions_storage[1].agent_kind = .codex;
    sessions_storage[1].agent_session_id = "sid-42";
    sessions_storage[1].agent_metadata_captured = true;
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqualStrings("codex", persistence.terminal_entries.items[0].agent_type.?);
    try std.testing.expectEqualStrings("sid-42", persistence.terminal_entries.items[0].agent_session_id.?);
    try std.testing.expect(!(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator)));
}
