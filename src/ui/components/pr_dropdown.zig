const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const text_edit = @import("../text_edit.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../../dpi.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;
const search_utils = @import("search_utils.zig");
const model = @import("pr_dropdown_model.zig");
const repo = @import("pr_dropdown_repo.zig");
const fetch = @import("pr_dropdown_fetch.zig");
const view = @import("pr_dropdown_view.zig");

const log = std.log.scoped(.pr_dropdown);
pub const PullRequest = model.PullRequest;
const FetchStatus = model.FetchStatus;
const FetchResult = model.FetchResult;

const FetchContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    mutex: std.Io.Mutex = .init,
    result: ?FetchResult = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn deinit(self: *FetchContext) void {
        if (self.result) |*result| {
            model.freeFetchResult(self.allocator, result);
        }
        self.allocator.free(self.cwd);
        self.allocator.destroy(self);
    }

    fn takeResult(self: *FetchContext) ?FetchResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.result;
        self.result = null;
        return result;
    }
};

const FetchJob = struct {
    thread: std.Thread,
    context: *FetchContext,
};

pub const PRDropdownComponent = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    overlay: ExpandingOverlay = ExpandingOverlay.init(3, button_margin, button_size_small, button_size_large, button_animation_duration_ms),
    first_frame: FirstFrameGuard = .{},

    // Repo state (derived from focused cwd)
    last_cwd_seen: ?[]const u8 = null,
    repo_root: ?[]const u8 = null,
    is_github_repo: bool = false,
    current_branch: ?[]const u8 = null,
    current_pr_number: ?u32 = null,

    // Fetched PRs (owned by this component)
    prs: std.ArrayList(PullRequest) = .empty,
    fetch_status: FetchStatus = .idle,
    fetch_error: ?[]const u8 = null,
    last_fetch_ms: i64 = 0,
    last_fetched_repo: ?[]const u8 = null,

    // Background fetch plumbing. Jobs retain their repository key until the
    // worker is joined, so results can be discarded when focus has moved on.
    fetch_jobs: std.ArrayList(FetchJob) = .empty,

    // Filter / selection
    filtered_indices: std.ArrayList(usize) = .empty,
    selected_index: usize = 0,
    hovered_entry: ?usize = null,
    search_query: text_edit.TextInput = .{ .separators = text_edit.path_separators, .accepts = text_edit.isSingleLineChar },

    // Rendering cache
    cache: ?*view.Cache = null,
    escape_pressed: bool = false,
    focused_busy: bool = false,
    flow_animation_start_ms: i64 = 0,

    pub const button_size_small: c_int = 40;
    pub const button_size_large: c_int = 480;
    pub const component_z_index: i32 = 999;
    const button_margin: c_int = 20;
    const button_animation_duration_ms: i64 = 200;
    const line_height: c_int = 28;
    const max_display: usize = 10;
    const search_bar_height: c_int = 28;
    /// Time before a successful fetch is considered stale and re-fetched on open.
    const fetch_ttl_ms: i64 = 30_000;

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !UiComponent {
        const comp = try allocator.create(PRDropdownComponent);
        comp.* = .{ .allocator = allocator, .io = io };
        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = component_z_index,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));

        for (self.fetch_jobs.items) |*job| {
            job.thread.join();
            job.context.deinit();
        }
        self.fetch_jobs.deinit(self.allocator);

        self.destroyCache();
        self.clearPrs();
        self.prs.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);
        self.search_query.deinit(self.allocator);
        if (self.last_cwd_seen) |s| self.allocator.free(s);
        if (self.repo_root) |s| self.allocator.free(s);
        if (self.current_branch) |s| self.allocator.free(s);
        if (self.fetch_error) |s| self.allocator.free(s);
        if (self.last_fetched_repo) |s| self.allocator.free(s);
        self.allocator.destroy(self);
    }

    fn clearPrs(self: *PRDropdownComponent) void {
        for (self.prs.items) |pr| {
            self.allocator.free(pr.title);
            self.allocator.free(pr.branch);
        }
        self.prs.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();
        self.selected_index = 0;
        self.hovered_entry = null;
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));

        if (event.type == c.SDL_EVENT_KEY_UP and self.escape_pressed) {
            const key = event.key.key;
            if (key == c.SDLK_ESCAPE) {
                self.escape_pressed = false;
                return true;
            }
        }

        if (!self.pillVisible(host)) return false;

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL)) != 0;

                // Cmd+P toggles overlay (only meaningful inside a GitHub repo)
                if (has_gui and !has_blocking_mod and key == c.SDLK_P) {
                    if (self.overlay.state == .Open) {
                        self.closeOverlay(host.now_ms);
                    } else {
                        self.openOverlay(host.now_ms);
                    }
                    return true;
                }

                if (self.overlay.state != .Open) return false;

                const edit = self.search_query.handleKey(self.allocator, key, mod, host.now_ms);
                if (edit.consumed) {
                    if (edit.text_changed) self.refilter();
                    return true;
                }

                if (key == c.SDLK_UP) {
                    if (self.filtered_indices.items.len > 0) {
                        if (self.selected_index > 0) {
                            self.selected_index -= 1;
                        } else {
                            self.selected_index = self.filtered_indices.items.len - 1;
                        }
                    }
                    return true;
                }
                if (key == c.SDLK_DOWN) {
                    if (self.filtered_indices.items.len > 0) {
                        if (self.selected_index < self.filtered_indices.items.len - 1) {
                            self.selected_index += 1;
                        } else {
                            self.selected_index = 0;
                        }
                    }
                    return true;
                }

                if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
                    if (self.filteredPr(self.selected_index)) |pr| {
                        self.emitCheckout(actions, host.focused_session, pr);
                        self.closeOverlay(host.now_ms);
                    }
                    return true;
                }

                if (key == c.SDLK_ESCAPE) {
                    self.escape_pressed = true;
                    self.closeOverlay(host.now_ms);
                    return true;
                }

                if (has_gui and !has_blocking_mod) {
                    if (key >= c.SDLK_1 and key <= c.SDLK_9) {
                        const digit_idx: usize = @intCast(key - c.SDLK_1);
                        if (self.filteredPr(digit_idx)) |pr| {
                            self.emitCheckout(actions, host.focused_session, pr);
                            self.closeOverlay(host.now_ms);
                            return true;
                        }
                    }
                }

                return true;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (self.overlay.state == .Open) {
                    const text = std.mem.span(event.text.text);
                    if (self.search_query.insert(self.allocator, text, host.now_ms)) self.refilter();
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
                const inside = geom.containsPoint(rect, mouse_x, mouse_y);

                if (inside and self.overlay.state == .Open) {
                    if (self.entryIndexAtPoint(host, mouse_y)) |idx| {
                        if (self.filteredPr(idx)) |pr| {
                            self.emitCheckout(actions, host.focused_session, pr);
                            self.closeOverlay(host.now_ms);
                        }
                        return true;
                    }
                }

                if (inside) {
                    switch (self.overlay.state) {
                        .Closed => self.openOverlay(host.now_ms),
                        .Open => self.closeOverlay(host.now_ms),
                        else => {},
                    }
                    return true;
                }

                if (self.overlay.state == .Open and !inside) {
                    self.closeOverlay(host.now_ms);
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (self.overlay.state != .Open) return false;
                const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                const inside = geom.containsPoint(rect, mouse_x, mouse_y);
                if (!inside) {
                    self.hovered_entry = null;
                    return false;
                }
                self.hovered_entry = self.entryIndexAtPoint(host, mouse_y);
            },
            else => {},
        }
        return false;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.pillVisible(host)) return false;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        return geom.containsPoint(rect, x, y);
    }

    pub fn shouldShowPill(is_github_repo: bool, focused_busy: bool) bool {
        return is_github_repo and !focused_busy;
    }

    pub fn pillVisible(self: *const PRDropdownComponent, host: *const types.UiHost) bool {
        return shouldShowPill(self.is_github_repo, host.focused_has_foreground_process);
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));

        // Re-detect the repo when the focused cwd changes.
        const new_cwd = host.focused_cwd;
        if (model.cwdChanged(self.last_cwd_seen, new_cwd)) {
            self.applyCwd(new_cwd);
            // Fetch on repo entry even while collapsed so the pill can resolve
            // the checked-out branch's PR number.
            if (model.shouldFetchOnRepoEntry(self.is_github_repo, self.fetch_status)) {
                self.startFetch(host.now_ms);
            }
        }

        // A checkout changes HEAD without changing the shell's cwd. Keep the
        // collapsed pill's branch badge in sync with that change.
        if (self.is_github_repo) {
            self.refreshCurrentBranch();
        }

        // Close overlay if no longer applicable.
        if (!self.is_github_repo and self.overlay.state != .Closed) {
            self.closeOverlay(host.now_ms);
        }

        // Block while focused shell is busy with a foreground process.
        const busy = host.focused_has_foreground_process;
        if (busy != self.focused_busy) {
            self.focused_busy = busy;
            if (busy) {
                self.destroyCache();
                self.hovered_entry = null;
                self.escape_pressed = false;
            }
        }
        if (busy and self.overlay.state.isOpenOrOpening()) {
            self.closeOverlay(host.now_ms);
        }

        // Pick up completed background fetch results, including results that
        // belong to a repository that is no longer focused.
        self.collectFetchResults();

        // Advance the expand/collapse animation state machine.
        if (self.overlay.isAnimating() and self.overlay.isComplete(host.now_ms)) {
            self.overlay.state = switch (self.overlay.state) {
                .Expanding => .Open,
                .Collapsing => .Closed,
                else => self.overlay.state,
            };
            if (self.overlay.state == .Open) {
                self.first_frame.markTransition();
                self.flow_animation_start_ms = host.now_ms;
            }
            if (self.overlay.state == .Closed) {
                self.hovered_entry = null;
                self.flow_animation_start_ms = 0;
            }
        }
    }

    fn render(self_ptr: *anyopaque, ui_host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));
        self.first_frame.markDrawn();
        if (!self.pillVisible(ui_host)) return;

        const rect = self.overlay.rect(ui_host.now_ms, ui_host.window_w, ui_host.window_h, ui_host.ui_scale);
        const radius: c_int = 8;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const sel = ui_host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 245);
        primitives.fillRoundedRect(renderer, rect, radius);

        const accent = ui_host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 255);
        primitives.drawRoundedBorder(renderer, rect, radius);

        if (self.overlay.state != .Closed) {
            if (view.ensureCache(self.renderState(), &self.cache, renderer, ui_host.ui_scale, assets, ui_host.theme)) |cache| {
                self.overlay.setContentHeight(cache.content_height);
            }
        }

        switch (self.overlay.state) {
            .Closed, .Collapsing, .Expanding => view.renderGlyph(renderer, rect, ui_host.ui_scale, self.current_pr_number, assets, ui_host.theme),
            .Open => if (self.cache) |cache| view.renderOverlay(
                renderer,
                ui_host,
                rect,
                ui_host.ui_scale,
                assets,
                ui_host.theme,
                cache,
                self.renderState(),
                self.flow_animation_start_ms,
            ),
        }
    }

    fn entryIndexAtPoint(self: *PRDropdownComponent, host: *const types.UiHost, y: c_int) ?usize {
        const cache = self.cache orelse return null;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        const scaled_margin: c_int = dpi.scale(button_margin, host.ui_scale);
        const scaled_lh: c_int = dpi.scale(line_height, host.ui_scale);
        const search_h = dpi.scale(search_bar_height, host.ui_scale) + dpi.scale(8, host.ui_scale);
        const status_h: c_int = if (cache.status_line) |st| st.h + dpi.scale(8, host.ui_scale) else 0;
        const start_y = rect.y + scaled_margin + cache.title.h + dpi.scale(8, host.ui_scale) + search_h + status_h;
        if (y < start_y) return null;
        const rel = y - start_y;
        const idx = @as(usize, @intCast(@divFloor(rel, scaled_lh)));
        if (idx >= self.filtered_indices.items.len) return null;
        return idx;
    }

    fn filteredPr(self: *PRDropdownComponent, display_idx: usize) ?PullRequest {
        if (display_idx >= self.filtered_indices.items.len) return null;
        const source_idx = self.filtered_indices.items[display_idx];
        if (source_idx >= self.prs.items.len) return null;
        return self.prs.items[source_idx];
    }

    fn openOverlay(self: *PRDropdownComponent, now_ms: i64) void {
        self.overlay.startExpanding(now_ms);
        // Start a fetch if cache is empty or stale.
        const stale = self.fetchIsStale(now_ms);
        if (stale and self.is_github_repo) {
            self.startFetch(now_ms);
        }
    }

    fn closeOverlay(self: *PRDropdownComponent, now_ms: i64) void {
        self.overlay.startCollapsing(now_ms);
        self.search_query.clear();
        self.refilter();
    }

    fn fetchIsStale(self: *PRDropdownComponent, now_ms: i64) bool {
        if (self.fetch_status != .ok) return true;
        if (self.last_fetched_repo == null) return true;
        if (self.repo_root) |r| {
            if (self.last_fetched_repo) |lr| {
                if (!std.mem.eql(u8, r, lr)) return true;
            }
        }
        return (now_ms - self.last_fetch_ms) > fetch_ttl_ms;
    }

    fn refilter(self: *PRDropdownComponent) void {
        self.filtered_indices.clearRetainingCapacity();
        self.destroyCache();

        const query = std.mem.trim(u8, self.search_query.text(), " \t");

        for (self.prs.items, 0..) |pr, idx| {
            if (self.filtered_indices.items.len >= max_display) break;
            if (query.len == 0) {
                self.filtered_indices.append(self.allocator, idx) catch |err| {
                    log.warn("failed to append filtered index: {}", .{err});
                    break;
                };
                continue;
            }
            // Search across title, branch, and number.
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "#{d}", .{pr.number}) catch |err| blk: {
                log.warn("failed to format PR number {d}: {}", .{ pr.number, err });
                break :blk num_buf[0..0];
            };
            if (search_utils.findCaseInsensitive(pr.title, query, 0) != null or
                search_utils.findCaseInsensitive(pr.branch, query, 0) != null or
                search_utils.findCaseInsensitive(num_str, query, 0) != null)
            {
                self.filtered_indices.append(self.allocator, idx) catch |err| {
                    log.warn("failed to append filtered index: {}", .{err});
                    break;
                };
            }
        }

        if (self.selected_index >= self.filtered_indices.items.len) {
            self.selected_index = if (self.filtered_indices.items.len > 0) self.filtered_indices.items.len - 1 else 0;
        }
    }

    // -- Repo detection (fast, main-thread, .git config + HEAD parsing) --

    fn applyCwd(self: *PRDropdownComponent, new_cwd: ?[]const u8) void {
        var new_repo_root: ?[]u8 = null;
        var new_branch: ?[]u8 = null;
        var new_is_github_repo = false;

        if (new_cwd) |cwd| {
            new_repo_root = repo.findRepoRoot(self.allocator, self.io, cwd) catch |err| blk: {
                log.warn("failed to find repository for {s}: {}", .{ cwd, err });
                break :blk null;
            };
            if (new_repo_root) |root| {
                new_is_github_repo = repo.detectGithubOrigin(self.allocator, self.io, root) catch |err| blk: {
                    log.warn("failed to inspect GitHub origin for {s}: {}", .{ root, err });
                    break :blk false;
                };
                if (new_is_github_repo) {
                    new_branch = repo.readCurrentBranch(self.allocator, self.io, root) catch |err| blk: {
                        log.warn("failed to read branch for {s}: {}", .{ root, err });
                        break :blk null;
                    };
                }
            }
        }

        const same_repo = model.optionalSlicesEqual(self.repo_root, new_repo_root);
        const keep_results = same_repo and self.is_github_repo and new_is_github_repo;

        if (self.last_cwd_seen) |s| self.allocator.free(s);
        self.last_cwd_seen = null;
        if (new_cwd) |c2| {
            self.last_cwd_seen = self.allocator.dupe(u8, c2) catch |err| blk: {
                log.warn("failed to remember focused cwd: {}", .{err});
                break :blk null;
            };
        }

        if (self.repo_root) |s| self.allocator.free(s);
        self.repo_root = new_repo_root;
        new_repo_root = null;
        if (self.current_branch) |s| self.allocator.free(s);
        self.current_branch = new_branch;
        new_branch = null;
        self.is_github_repo = new_is_github_repo;
        self.current_pr_number = null;

        if (!keep_results) {
            self.clearPrs();
            self.fetch_status = .idle;
            self.last_fetch_ms = 0;
            if (self.last_fetched_repo) |s| self.allocator.free(s);
            self.last_fetched_repo = null;
            if (self.fetch_error) |s| self.allocator.free(s);
            self.fetch_error = null;
        }

        self.updateCurrentPrNumber();
        self.destroyCache();

        if (new_repo_root) |root| self.allocator.free(root);
        if (new_branch) |branch| self.allocator.free(branch);
    }

    fn refreshCurrentBranch(self: *PRDropdownComponent) void {
        const root = self.repo_root orelse return;
        const new_branch = repo.readCurrentBranch(self.allocator, self.io, root) catch |err| {
            log.warn("failed to refresh branch for {s}: {}", .{ root, err });
            return;
        };
        if (model.optionalSlicesEqual(self.current_branch, new_branch)) {
            if (new_branch) |branch| self.allocator.free(branch);
            return;
        }

        if (self.current_branch) |branch| self.allocator.free(branch);
        self.current_branch = new_branch;
        self.updateCurrentPrNumber();
        self.destroyCache();
    }

    fn updateCurrentPrNumber(self: *PRDropdownComponent) void {
        self.current_pr_number = model.prNumberForBranch(self.current_branch, self.prs.items);
    }

    // -- Fetch lifecycle --

    fn startFetch(self: *PRDropdownComponent, now_ms: i64) void {
        const repo_root = self.repo_root orelse return;
        if (self.hasFetchForRepo(repo_root)) return;

        const cwd_copy = self.allocator.dupe(u8, repo_root) catch |err| {
            log.warn("failed to copy repository path for PR fetch: {}", .{err});
            return;
        };

        const ctx = self.allocator.create(FetchContext) catch {
            self.allocator.free(cwd_copy);
            log.warn("failed to allocate PR fetch context", .{});
            return;
        };
        ctx.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .cwd = cwd_copy,
        };

        self.fetch_jobs.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            log.warn("failed to reserve PR fetch job: {}", .{err});
            ctx.deinit();
            return;
        };
        self.fetch_status = .fetching;
        self.last_fetch_ms = now_ms;

        const thread = std.Thread.spawn(.{}, fetchThreadMain, .{ctx}) catch |err| {
            log.warn("failed to spawn pr fetch thread: {}", .{err});
            self.fetch_status = .failed;
            ctx.deinit();
            return;
        };
        self.fetch_jobs.appendAssumeCapacity(.{ .thread = thread, .context = ctx });
    }

    fn fetchThreadMain(ctx: *FetchContext) void {
        const result = fetch.runGhPrList(ctx.allocator, ctx.io, ctx.cwd);
        ctx.mutex.lockUncancelable(ctx.io);
        ctx.result = result;
        ctx.mutex.unlock(ctx.io);
        ctx.done.store(true, .release);
    }

    fn hasFetchForRepo(self: *PRDropdownComponent, repo_root: []const u8) bool {
        for (self.fetch_jobs.items) |job| {
            if (std.mem.eql(u8, job.context.cwd, repo_root)) return true;
        }
        return false;
    }

    fn collectFetchResults(self: *PRDropdownComponent) void {
        var index: usize = 0;
        while (index < self.fetch_jobs.items.len) {
            if (!self.fetch_jobs.items[index].context.done.load(.acquire)) {
                index += 1;
                continue;
            }

            var job = self.fetch_jobs.swapRemove(index);
            job.thread.join();
            const result = job.context.takeResult();

            if (result) |fetch_result| {
                if (model.fetchResultMatchesRepo(job.context.cwd, self.repo_root, self.is_github_repo)) {
                    self.applyFetchResult(fetch_result);
                } else {
                    var stale_result = fetch_result;
                    model.freeFetchResult(self.allocator, &stale_result);
                }
            }
            job.context.deinit();
        }
    }

    fn applyFetchResult(self: *PRDropdownComponent, result: FetchResult) void {
        self.clearPrs();
        self.fetch_status = result.status;
        if (self.fetch_error) |s| self.allocator.free(s);
        self.fetch_error = result.error_message;
        defer self.allocator.free(result.prs);

        for (result.prs) |pr| {
            self.prs.append(self.allocator, pr) catch |err| {
                log.warn("failed to append PR: {}", .{err});
                self.allocator.free(pr.title);
                self.allocator.free(pr.branch);
                continue;
            };
        }

        if (self.last_fetched_repo) |s| self.allocator.free(s);
        self.last_fetched_repo = null;
        if (self.repo_root) |repo_root| {
            self.last_fetched_repo = self.allocator.dupe(u8, repo_root) catch |err| blk: {
                log.warn("failed to remember fetched repository: {}", .{err});
                break :blk null;
            };
        }

        self.updateCurrentPrNumber();
        self.refilter();
        self.first_frame.markTransition();
    }

    fn emitCheckout(_: *PRDropdownComponent, actions: *types.UiActionQueue, session_idx: usize, pr: PullRequest) void {
        const branch_copy = actions.allocator.dupe(u8, pr.branch) catch return;
        actions.append(.{ .CheckoutPullRequest = .{
            .session = session_idx,
            .pr_number = pr.number,
            .branch = branch_copy,
        } }) catch {
            actions.allocator.free(branch_copy);
        };
    }

    fn renderState(self: *PRDropdownComponent) view.RenderState {
        return .{
            .allocator = self.allocator,
            .prs = self.prs.items,
            .filtered_indices = self.filtered_indices.items,
            .search_query = &self.search_query,
            .selected_index = self.selected_index,
            .hovered_entry = self.hovered_entry,
            .fetch_status = self.fetch_status,
            .fetch_error = self.fetch_error,
        };
    }

    fn destroyCache(self: *PRDropdownComponent) void {
        view.destroyCache(self.allocator, &self.cache);
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));
        for (self.fetch_jobs.items) |job| {
            if (job.context.done.load(.acquire)) return true;
        }
        return self.overlay.isAnimating() or self.first_frame.wantsFrame() or self.overlay.state == .Open;
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        deinit(self_ptr, renderer);
    }

    pub const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

test "PR dropdown renders below sibling pill overlays" {
    try std.testing.expect(PRDropdownComponent.component_z_index < 1000);
}

test "pull request pill is hidden while the focused shell is busy" {
    try std.testing.expect(PRDropdownComponent.shouldShowPill(true, false));
    try std.testing.expect(!PRDropdownComponent.shouldShowPill(true, true));
    try std.testing.expect(!PRDropdownComponent.shouldShowPill(false, false));
}

const testing = std.testing;

fn testTheme() colors.Theme {
    const base = c.SDL_Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    return .{
        .background = base,
        .foreground = base,
        .selection = base,
        .accent = base,
        .palette = [_]c.SDL_Color{base} ** 16,
    };
}

fn testHost(now_ms: i64, focused_busy: bool, theme: *const colors.Theme) types.UiHost {
    return .{
        .now_ms = now_ms,
        .window_w = 1200,
        .window_h = 800,
        .window_focused = true,
        .ui_scale = 1.0,
        .grid_cols = 2,
        .grid_rows = 2,
        .cell_w = 8,
        .cell_h = 16,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Grid,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = focused_busy,
        .sessions = &.{},
        .theme = theme,
    };
}

fn keyEvent(key: c.SDL_Keycode, mod: c.SDL_Keymod) c.SDL_Event {
    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = key;
    event.key.mod = mod;
    return event;
}

fn textEvent(text: [*c]const u8) c.SDL_Event {
    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = text;
    return event;
}

test "open PR picker does not consume input while the focused shell is busy" {
    var component: PRDropdownComponent = .{ .allocator = testing.allocator, .io = undefined };
    defer component.search_query.deinit(testing.allocator);
    component.is_github_repo = true;
    component.overlay.state = .Open;
    try component.search_query.buf.appendSlice(testing.allocator, "before");

    var actions = types.UiActionQueue.init(testing.allocator);
    defer actions.deinit();
    var theme = testTheme();
    const host = testHost(0, true, &theme);

    var typed = textEvent("x");
    try testing.expect(!PRDropdownComponent.handleEvent(&component, &host, &typed, &actions));
    try testing.expectEqualStrings("before", component.search_query.text());

    var erased = keyEvent(c.SDLK_BACKSPACE, 0);
    try testing.expect(!PRDropdownComponent.handleEvent(&component, &host, &erased, &actions));
    try testing.expectEqualStrings("before", component.search_query.text());
}
