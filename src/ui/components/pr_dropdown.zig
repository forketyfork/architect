const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../../dpi.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;
const flowing_line = @import("flowing_line.zig");
const search_utils = @import("search_utils.zig");
const font_cache_mod = @import("../../font_cache.zig");

const log = std.log.scoped(.pr_dropdown);

const TextTex = search_utils.TextTex;

pub const PullRequest = struct {
    number: u32,
    title: []const u8,
    branch: []const u8,
};

const FetchStatus = enum {
    idle,
    fetching,
    ok,
    failed,
    gh_missing,
};

const FetchResult = struct {
    status: FetchStatus,
    prs: []const PullRequest,
    error_message: ?[]const u8 = null,
};

const FetchContext = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    mutex: *std.Thread.Mutex,
    result_slot: *?FetchResult,
    done_flag: *std.atomic.Value(bool),

    fn deinit(self: *FetchContext) void {
        self.allocator.free(self.cwd);
        self.allocator.destroy(self);
    }
};

pub const PRDropdownComponent = struct {
    allocator: std.mem.Allocator,
    overlay: ExpandingOverlay = ExpandingOverlay.init(3, button_margin, button_size_small, button_size_large, button_animation_duration_ms),
    first_frame: FirstFrameGuard = .{},

    // Repo state (derived from focused cwd)
    last_cwd_seen: ?[]const u8 = null,
    repo_root: ?[]const u8 = null,
    is_github_repo: bool = false,
    current_branch: ?[]const u8 = null,
    current_pr_number: ?u32 = null,

    // Fetched PRs (owned by this component)
    prs: std.ArrayList(PullRequest) = .{},
    fetch_status: FetchStatus = .idle,
    fetch_error: ?[]const u8 = null,
    last_fetch_ms: i64 = 0,
    last_fetched_repo: ?[]const u8 = null,

    // Background fetch plumbing
    fetch_thread: ?std.Thread = null,
    fetch_mutex: std.Thread.Mutex = .{},
    fetch_pending_result: ?FetchResult = null,
    fetch_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fetch_ctx: ?*FetchContext = null,

    // Filter / selection
    filtered_indices: std.ArrayList(usize) = .{},
    selected_index: usize = 0,
    hovered_entry: ?usize = null,
    search_query: std.ArrayList(u8) = .{},

    // Rendering cache
    cache: ?*Cache = null,
    escape_pressed: bool = false,
    focused_busy: bool = false,
    flow_animation_start_ms: i64 = 0,

    pub const button_size_small: c_int = 40;
    pub const button_size_large: c_int = 480;
    const button_margin: c_int = 20;
    const button_animation_duration_ms: i64 = 200;
    const line_height: c_int = 28;
    const max_display: usize = 10;
    const search_bar_height: c_int = 28;
    /// Time before a successful fetch is considered stale and re-fetched on open.
    const fetch_ttl_ms: i64 = 30_000;
    const title = "Pull Requests";

    const EntryTex = struct {
        hotkey: TextTex,
        label: TextTex,
        displayed_text: []const u8,
    };

    const Cache = struct {
        ui_scale: f32,
        title_font_size: c_int,
        entry_font_size: c_int,
        title: TextTex,
        status_line: ?TextTex,
        entries: []EntryTex,
        theme_fg: c.SDL_Color,
        font_generation: u64,
        query_len: usize,
        filtered_count: usize,
        status: FetchStatus,
    };

    pub fn create(allocator: std.mem.Allocator) !UiComponent {
        const comp = try allocator.create(PRDropdownComponent);
        comp.* = .{ .allocator = allocator };
        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 1000,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));

        // Wait for any in-flight fetch so we can free its memory safely.
        if (self.fetch_thread) |t| {
            t.join();
            self.fetch_thread = null;
        }
        if (self.fetch_ctx) |ctx| {
            ctx.deinit();
            self.fetch_ctx = null;
        }
        if (self.fetch_pending_result) |*res| {
            freeFetchResult(self.allocator, res);
            self.fetch_pending_result = null;
        }

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

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_ALT | c.SDL_KMOD_CTRL)) != 0;

                // Cmd+P toggles overlay (only meaningful inside a GitHub repo)
                if (has_gui and !has_blocking_mod and key == c.SDLK_P) {
                    if (!self.is_github_repo) return false;
                    if (self.overlay.state == .Open) {
                        self.closeOverlay(host.now_ms);
                    } else {
                        self.openOverlay(host.now_ms);
                    }
                    return true;
                }

                if (self.overlay.state != .Open) return false;

                if (key == c.SDLK_BACKSPACE) {
                    if (self.search_query.items.len > 0) {
                        self.search_query.items.len -= 1;
                        self.refilter();
                    }
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
                    self.search_query.appendSlice(self.allocator, text) catch |err| {
                        log.warn("failed to append search input: {}", .{err});
                    };
                    self.refilter();
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (!self.is_github_repo) return false;
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
        if (!self.is_github_repo) return false;
        const rect = self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
        return geom.containsPoint(rect, x, y);
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));

        // Re-detect the repo when the focused cwd changes.
        const new_cwd = host.focused_cwd;
        if (cwdChanged(self.last_cwd_seen, new_cwd)) {
            self.applyCwd(new_cwd);
            // If the overlay is open and we're still in a github repo, refresh.
            if (self.is_github_repo and
                self.overlay.state != .Closed and
                self.fetch_thread == null and
                self.fetchIsStale(host.now_ms))
            {
                self.startFetch(host.now_ms);
            }
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

        // Pick up background fetch results.
        if (self.fetch_done.load(.acquire)) {
            self.collectFetchResult();
        }

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
        if (!self.is_github_repo) return;

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
            _ = self.ensureCache(renderer, ui_host.ui_scale, assets, ui_host.theme);
        }

        switch (self.overlay.state) {
            .Closed, .Collapsing, .Expanding => self.renderGlyph(renderer, rect, ui_host.ui_scale, assets, ui_host.theme),
            .Open => self.renderOverlay(renderer, ui_host, rect, ui_host.ui_scale, assets, ui_host.theme),
        }

        self.first_frame.markDrawn();
    }

    fn renderGlyph(self: *PRDropdownComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) void {
        const cache = assets.font_cache orelse return;
        const font_size = dpi.scale(@max(12, @min(20, @divFloor(rect.h, 2))), ui_scale);
        const fonts = cache.get(font_size) catch return;

        var label_buf: [16]u8 = undefined;
        const label = if (self.current_pr_number) |n|
            std.fmt.bufPrint(&label_buf, "#{d}", .{n}) catch "⌘P"
        else
            "⌘P";

        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const surface = c.TTF_RenderText_Blended(fonts.regular, label.ptr, @intCast(label.len), fg_color) orelse return;
        defer c.SDL_DestroySurface(surface);
        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(texture);

        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &tw, &th);
        const dest = c.SDL_FRect{
            .x = @floatFromInt(rect.x + @divFloor(rect.w - @as(c_int, @intFromFloat(tw)), 2)),
            .y = @floatFromInt(rect.y + @divFloor(rect.h - @as(c_int, @intFromFloat(th)), 2)),
            .w = tw,
            .h = th,
        };
        _ = c.SDL_RenderTexture(renderer, texture, null, &dest);
    }

    fn renderOverlay(self: *PRDropdownComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, rect: geom.Rect, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) void {
        const cache = self.ensureCache(renderer, ui_scale, assets, theme) orelse return;

        const scaled_margin: c_int = dpi.scale(button_margin, ui_scale);
        const scaled_line_height: c_int = dpi.scale(line_height, ui_scale);
        var y_offset: c_int = rect.y + scaled_margin;

        // Title
        const title_tex = cache.title;
        const title_x = rect.x + @divFloor(rect.w - title_tex.w, 2);
        _ = c.SDL_RenderTexture(renderer, title_tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(title_x),
            .y = @floatFromInt(y_offset),
            .w = @floatFromInt(title_tex.w),
            .h = @floatFromInt(title_tex.h),
        });
        y_offset += title_tex.h + dpi.scale(8, ui_scale);

        // Search bar
        const font_cache = assets.font_cache orelse return;
        const search_bar_rect = geom.Rect{
            .x = rect.x + scaled_margin,
            .y = y_offset,
            .w = rect.w - 2 * scaled_margin,
            .h = dpi.scale(search_bar_height, ui_scale),
        };
        search_utils.renderSearchBar(
            self.allocator,
            renderer,
            host,
            search_bar_rect,
            font_cache,
            self.search_query.items,
            self.filtered_indices.items.len,
            if (self.filtered_indices.items.len > 0) self.selected_index else null,
        ) catch |err| {
            log.warn("failed to render search bar: {}", .{err});
        };
        y_offset += dpi.scale(search_bar_height, ui_scale) + dpi.scale(8, ui_scale);

        // Status line (e.g. "Loading…", "gh CLI not installed", error)
        if (cache.status_line) |status_tex| {
            _ = c.SDL_RenderTexture(renderer, status_tex.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + scaled_margin),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(status_tex.w),
                .h = @floatFromInt(status_tex.h),
            });
            y_offset += status_tex.h + dpi.scale(8, ui_scale);
        }

        // Entries
        const entry_font_size: c_int = dpi.scale(16, ui_scale);
        const entry_fonts = font_cache.get(entry_font_size) catch |err| blk: {
            log.warn("failed to load entry font size {d}: {}", .{ entry_font_size, err });
            break :blk null;
        };
        const query = std.mem.trim(u8, self.search_query.items, " \t");

        for (cache.entries, 0..) |entry_tex, idx| {
            const is_selected = idx == self.selected_index;
            const is_hovered = if (self.hovered_entry) |h| h == idx else false;

            if (is_selected or is_hovered) {
                const highlight_y = @as(f32, @floatFromInt(y_offset - dpi.scale(4, ui_scale)));
                const highlight_h = @as(f32, @floatFromInt(scaled_line_height));
                const fade_width: f32 = @as(f32, @floatFromInt(dpi.scale(40, ui_scale)));
                const rect_x: f32 = @floatFromInt(rect.x);
                const rect_w: f32 = @floatFromInt(rect.w);

                const center_rect = c.SDL_FRect{
                    .x = rect_x + fade_width,
                    .y = highlight_y,
                    .w = rect_w - 2.0 * fade_width,
                    .h = highlight_h,
                };
                const acc = theme.accent;
                const alpha: u8 = if (is_selected) 60 else 40;
                _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, alpha);
                _ = c.SDL_RenderFillRect(renderer, &center_rect);

                const strips_count = 6;
                var i: usize = 0;
                while (i < strips_count) : (i += 1) {
                    const progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(strips_count));
                    const strip_w = fade_width / @as(f32, @floatFromInt(strips_count));

                    const left_alpha = @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * progress));
                    const left_strip = c.SDL_FRect{
                        .x = rect_x + @as(f32, @floatFromInt(i)) * strip_w,
                        .y = highlight_y,
                        .w = strip_w,
                        .h = highlight_h,
                    };
                    _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, left_alpha);
                    _ = c.SDL_RenderFillRect(renderer, &left_strip);

                    const right_alpha = @as(u8, @intFromFloat(@as(f32, @floatFromInt(alpha)) * (1.0 - progress)));
                    const right_strip = c.SDL_FRect{
                        .x = rect_x + rect_w - fade_width + @as(f32, @floatFromInt(i)) * strip_w,
                        .y = highlight_y,
                        .w = strip_w,
                        .h = highlight_h,
                    };
                    _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, right_alpha);
                    _ = c.SDL_RenderFillRect(renderer, &right_strip);
                }
            }

            _ = c.SDL_RenderTexture(renderer, entry_tex.hotkey.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(rect.x + scaled_margin),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.hotkey.w),
                .h = @floatFromInt(entry_tex.hotkey.h),
            });

            const label_x = rect.x + scaled_margin + entry_tex.hotkey.w + dpi.scale(10, ui_scale);
            _ = c.SDL_RenderTexture(renderer, entry_tex.label.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(label_x),
                .y = @floatFromInt(y_offset),
                .w = @floatFromInt(entry_tex.label.w),
                .h = @floatFromInt(entry_tex.label.h),
            });

            if (query.len > 0 and entry_fonts != null) {
                self.renderLabelHighlights(
                    renderer,
                    host,
                    entry_fonts.?,
                    label_x,
                    y_offset,
                    scaled_line_height,
                    ui_scale,
                    entry_tex.displayed_text,
                    query,
                );
            }

            if (is_selected) {
                const flow_y = y_offset + @divFloor(entry_tex.label.h, 2);
                flowing_line.render(renderer, self.flow_animation_start_ms, host.now_ms, rect, flow_y, ui_scale, theme);
            }

            y_offset += scaled_line_height;
        }
    }

    fn renderLabelHighlights(
        _: *PRDropdownComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        entry_fonts: *font_cache_mod.FontSet,
        label_x: c_int,
        y_offset: c_int,
        lh: c_int,
        ui_scale: f32,
        display_text: []const u8,
        query: []const u8,
    ) void {
        var pos: usize = 0;
        while (search_utils.findCaseInsensitive(display_text, query, pos)) |found| {
            const before_text = display_text[0..found];
            const match_text = display_text[found .. found + query.len];

            var before_w: c_int = 0;
            var before_h: c_int = 0;
            if (before_text.len > 0) {
                _ = c.TTF_GetStringSize(entry_fonts.regular, @ptrCast(before_text.ptr), before_text.len, &before_w, &before_h);
            }
            var match_w: c_int = 0;
            var match_h: c_int = 0;
            _ = c.TTF_GetStringSize(entry_fonts.regular, @ptrCast(match_text.ptr), match_text.len, &match_w, &match_h);

            const highlight_x = label_x + before_w;
            const highlight_y = y_offset + dpi.scale(2, ui_scale);
            const highlight_h = lh - dpi.scale(6, ui_scale);

            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetRenderDrawColor(renderer, host.theme.accent.r, host.theme.accent.g, host.theme.accent.b, 120);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                .x = @floatFromInt(highlight_x),
                .y = @floatFromInt(highlight_y),
                .w = @floatFromInt(match_w),
                .h = @floatFromInt(highlight_h),
            });
            pos = found + 1;
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
        if (stale and self.fetch_thread == null and self.is_github_repo) {
            self.startFetch(now_ms);
        }
    }

    fn closeOverlay(self: *PRDropdownComponent, now_ms: i64) void {
        self.overlay.startCollapsing(now_ms);
        self.search_query.clearRetainingCapacity();
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

        const query = std.mem.trim(u8, self.search_query.items, " \t");

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
            const num_str = std.fmt.bufPrint(&num_buf, "#{d}", .{pr.number}) catch num_buf[0..0];
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
        if (self.last_cwd_seen) |s| self.allocator.free(s);
        self.last_cwd_seen = null;
        if (new_cwd) |c2| {
            self.last_cwd_seen = self.allocator.dupe(u8, c2) catch null;
        }

        if (self.repo_root) |s| self.allocator.free(s);
        self.repo_root = null;
        if (self.current_branch) |s| self.allocator.free(s);
        self.current_branch = null;
        self.is_github_repo = false;
        self.current_pr_number = null;

        const cwd = new_cwd orelse return;
        const repo = findRepoRoot(self.allocator, cwd) catch null;
        if (repo) |r| {
            self.repo_root = r;
            const is_gh = detectGithubOrigin(self.allocator, r) catch false;
            self.is_github_repo = is_gh;
            const branch = readCurrentBranch(self.allocator, r) catch null;
            self.current_branch = branch;
            self.updateCurrentPrNumber();
        }

        self.destroyCache();
    }

    fn updateCurrentPrNumber(self: *PRDropdownComponent) void {
        self.current_pr_number = null;
        const branch = self.current_branch orelse return;
        for (self.prs.items) |pr| {
            if (std.mem.eql(u8, pr.branch, branch)) {
                self.current_pr_number = pr.number;
                return;
            }
        }
    }

    fn cwdChanged(prev: ?[]const u8, next: ?[]const u8) bool {
        if (prev == null and next == null) return false;
        if (prev == null or next == null) return true;
        return !std.mem.eql(u8, prev.?, next.?);
    }

    // -- Fetch lifecycle --

    fn startFetch(self: *PRDropdownComponent, now_ms: i64) void {
        const cwd = self.repo_root orelse return;
        const cwd_copy = self.allocator.dupe(u8, cwd) catch return;

        const ctx = self.allocator.create(FetchContext) catch {
            self.allocator.free(cwd_copy);
            return;
        };
        ctx.* = .{
            .allocator = self.allocator,
            .cwd = cwd_copy,
            .mutex = &self.fetch_mutex,
            .result_slot = &self.fetch_pending_result,
            .done_flag = &self.fetch_done,
        };

        self.fetch_done.store(false, .release);
        self.fetch_ctx = ctx;
        self.fetch_status = .fetching;
        self.last_fetch_ms = now_ms;

        const thread = std.Thread.spawn(.{}, fetchThreadMain, .{ctx}) catch |err| {
            log.warn("failed to spawn pr fetch thread: {}", .{err});
            self.fetch_status = .failed;
            ctx.deinit();
            self.fetch_ctx = null;
            return;
        };
        self.fetch_thread = thread;
    }

    fn fetchThreadMain(ctx: *FetchContext) void {
        const result = runGhPrList(ctx.allocator, ctx.cwd);
        ctx.mutex.lock();
        // Replace any previously-pending (but never collected) result. This should
        // be impossible (we don't start a fetch while one is in flight), but be
        // defensive so we never leak.
        if (ctx.result_slot.*) |*prev| {
            freeFetchResult(ctx.allocator, prev);
        }
        ctx.result_slot.* = result;
        ctx.mutex.unlock();
        ctx.done_flag.store(true, .release);
    }

    fn collectFetchResult(self: *PRDropdownComponent) void {
        if (self.fetch_thread) |t| {
            t.join();
            self.fetch_thread = null;
        }
        self.fetch_done.store(false, .release);

        var picked: ?FetchResult = null;
        self.fetch_mutex.lock();
        picked = self.fetch_pending_result;
        self.fetch_pending_result = null;
        self.fetch_mutex.unlock();

        const ctx = self.fetch_ctx;
        self.fetch_ctx = null;

        const result = picked orelse {
            if (ctx) |ctx_ptr| ctx_ptr.deinit();
            return;
        };

        // Move the result into component state.
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
        if (self.repo_root) |r| {
            self.last_fetched_repo = self.allocator.dupe(u8, r) catch null;
        }

        self.updateCurrentPrNumber();
        self.refilter();
        self.first_frame.markTransition();

        if (ctx) |ctx_ptr| ctx_ptr.deinit();
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

    // -- Cache --

    fn ensureCache(self: *PRDropdownComponent, renderer: *c.SDL_Renderer, ui_scale: f32, assets: *types.UiAssets, theme: *const colors.Theme) ?*Cache {
        const cache_store = assets.font_cache orelse return null;
        const title_font_size: c_int = dpi.scale(20, ui_scale);
        const entry_font_size: c_int = dpi.scale(16, ui_scale);
        const fg = theme.foreground;
        const entry_count = self.filtered_indices.items.len;

        if (self.cache) |cache| {
            if (cache.title_font_size == title_font_size and
                cache.entry_font_size == entry_font_size and
                cache.theme_fg.r == fg.r and cache.theme_fg.g == fg.g and cache.theme_fg.b == fg.b and
                cache.ui_scale == ui_scale and
                cache.entries.len == entry_count and
                cache.font_generation == cache_store.generation and
                cache.query_len == self.search_query.items.len and
                cache.filtered_count == entry_count and
                cache.status == self.fetch_status)
            {
                return cache;
            }
            self.destroyCache();
        }

        const cache = self.allocator.create(Cache) catch return null;
        errdefer self.allocator.destroy(cache);

        const title_fonts = cache_store.get(title_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };
        const entry_fonts = cache_store.get(entry_font_size) catch {
            self.allocator.destroy(cache);
            return null;
        };

        const title_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const title_tex = makeTextTexture(renderer, title_fonts.regular, title, title_color) catch {
            self.allocator.destroy(cache);
            return null;
        };

        // Build optional status line.
        var status_line: ?TextTex = null;
        const status_text = self.statusLineText();
        if (status_text) |st| {
            const muted = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };
            status_line = makeTextTexture(renderer, entry_fonts.regular, st, muted) catch null;
        }

        const key_color = c.SDL_Color{ .r = 97, .g = 175, .b = 239, .a = 255 };
        const entry_color = c.SDL_Color{ .r = 171, .g = 178, .b = 191, .a = 255 };

        const entries = self.allocator.alloc(EntryTex, entry_count) catch {
            c.SDL_DestroyTexture(title_tex.tex);
            if (status_line) |st| c.SDL_DestroyTexture(st.tex);
            self.allocator.destroy(cache);
            return null;
        };
        errdefer self.allocator.free(entries);

        const padding = dpi.scale(20, ui_scale);
        const overlay_width = dpi.scale(button_size_large, ui_scale);
        const hotkey_spacing = dpi.scale(10, ui_scale);

        for (0..entry_count) |idx| {
            const source_idx = self.filtered_indices.items[idx];
            const pr = self.prs.items[source_idx];

            var key_buf: [8]u8 = undefined;
            const digit: u8 = @as(u8, @intCast((idx + 1) % 10));
            const key_slice = std.fmt.bufPrint(&key_buf, "⌘{d}", .{digit}) catch |err| blk: {
                log.warn("failed to format hotkey: {}", .{err});
                break :blk key_buf[0..0];
            };
            const key_tex = makeTextTexture(renderer, entry_fonts.regular, key_slice, key_color) catch {
                destroyEntryTextures(self.allocator, entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                if (status_line) |st| c.SDL_DestroyTexture(st.tex);
                self.allocator.destroy(cache);
                return null;
            };

            var label_buf: [512]u8 = undefined;
            const full_label = std.fmt.bufPrint(&label_buf, "#{d}  {s}", .{ pr.number, pr.title }) catch blk: {
                break :blk std.fmt.bufPrint(&label_buf, "#{d}", .{pr.number}) catch label_buf[0..0];
            };

            const max_label_width = overlay_width - (2 * padding) - key_tex.w - hotkey_spacing;
            var truncated_buf: [512]u8 = undefined;
            const display_label = truncateTextRight(full_label, entry_fonts.regular, max_label_width, &truncated_buf) catch |err| blk: {
                log.warn("failed to truncate label: {}", .{err});
                break :blk full_label;
            };
            const label_tex = makeTextTexture(renderer, entry_fonts.regular, display_label, entry_color) catch {
                c.SDL_DestroyTexture(key_tex.tex);
                destroyEntryTextures(self.allocator, entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                if (status_line) |st| c.SDL_DestroyTexture(st.tex);
                self.allocator.destroy(cache);
                return null;
            };
            const stored_text = self.allocator.dupe(u8, display_label) catch {
                c.SDL_DestroyTexture(label_tex.tex);
                c.SDL_DestroyTexture(key_tex.tex);
                destroyEntryTextures(self.allocator, entries[0..idx]);
                self.allocator.free(entries);
                c.SDL_DestroyTexture(title_tex.tex);
                if (status_line) |st| c.SDL_DestroyTexture(st.tex);
                self.allocator.destroy(cache);
                return null;
            };
            entries[idx] = .{ .hotkey = key_tex, .label = label_tex, .displayed_text = stored_text };
        }

        cache.* = .{
            .ui_scale = ui_scale,
            .title_font_size = title_font_size,
            .entry_font_size = entry_font_size,
            .title = title_tex,
            .status_line = status_line,
            .entries = entries,
            .theme_fg = fg,
            .font_generation = cache_store.generation,
            .query_len = self.search_query.items.len,
            .filtered_count = entry_count,
            .status = self.fetch_status,
        };

        self.cache = cache;

        const scaled_lh: c_int = dpi.scale(line_height, ui_scale);
        const scaled_padding: c_int = dpi.scale(2 * button_margin, ui_scale);
        const search_h = dpi.scale(search_bar_height, ui_scale) + dpi.scale(8, ui_scale);
        const status_h: c_int = if (status_line) |st| st.h + dpi.scale(8, ui_scale) else 0;
        const content_height = scaled_padding + title_tex.h + dpi.scale(8, ui_scale) + search_h + status_h + @as(c_int, @intCast(entry_count)) * scaled_lh;
        self.overlay.setContentHeight(content_height);

        return cache;
    }

    fn statusLineText(self: *PRDropdownComponent) ?[]const u8 {
        return switch (self.fetch_status) {
            .idle => "Press ⌘P to refresh.",
            .fetching => "Loading pull requests…",
            .ok => if (self.prs.items.len == 0) "No open pull requests." else null,
            .failed => self.fetch_error orelse "Failed to fetch pull requests.",
            .gh_missing => "Install GitHub CLI (`gh`) to list pull requests.",
        };
    }

    fn destroyCache(self: *PRDropdownComponent) void {
        if (self.cache) |cache| {
            c.SDL_DestroyTexture(cache.title.tex);
            if (cache.status_line) |st| c.SDL_DestroyTexture(st.tex);
            destroyEntryTextures(self.allocator, cache.entries);
            self.allocator.free(cache.entries);
            self.allocator.destroy(cache);
            self.cache = null;
        }
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *PRDropdownComponent = @ptrCast(@alignCast(self_ptr));
        if (self.fetch_done.load(.acquire)) return true;
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

fn freeFetchResult(allocator: std.mem.Allocator, result: *FetchResult) void {
    for (result.prs) |pr| {
        allocator.free(pr.title);
        allocator.free(pr.branch);
    }
    allocator.free(result.prs);
    if (result.error_message) |m| allocator.free(m);
    result.prs = &[_]PullRequest{};
    result.error_message = null;
}

fn makeTextTexture(
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    text: []const u8,
    color: c.SDL_Color,
) !TextTex {
    if (text.len == 0) return error.EmptyText;
    var buf: [512]u8 = undefined;
    if (text.len >= buf.len) return error.TextTooLong;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), text.len, color) orelse return error.SurfaceFailed;
    defer c.SDL_DestroySurface(surface);
    const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(tex, &w, &h);
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    return TextTex{ .tex = tex, .w = @intFromFloat(w), .h = @intFromFloat(h) };
}

fn destroyEntryTextures(allocator: std.mem.Allocator, entries: []PRDropdownComponent.EntryTex) void {
    for (entries) |entry| {
        c.SDL_DestroyTexture(entry.hotkey.tex);
        c.SDL_DestroyTexture(entry.label.tex);
        allocator.free(entry.displayed_text);
    }
}

fn truncateTextRight(text: []const u8, font: *c.TTF_Font, max_width: c_int, buf: []u8) ![]const u8 {
    const ellipsis = "…";
    var text_w: c_int = 0;
    var text_h: c_int = 0;
    _ = c.TTF_GetStringSize(font, text.ptr, text.len, &text_w, &text_h);
    if (text_w <= max_width) {
        if (text.len >= buf.len) return error.TextTooLong;
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }

    var end: usize = text.len;
    while (end > 0) {
        // Avoid splitting multi-byte UTF-8 sequences.
        while (end > 0 and (text[end - 1] & 0b1100_0000) == 0b1000_0000) {
            end -= 1;
        }
        if (end == 0) break;
        end -= 1;
        const candidate_len = end + ellipsis.len;
        if (candidate_len >= buf.len) continue;
        @memcpy(buf[0..end], text[0..end]);
        @memcpy(buf[end .. end + ellipsis.len], ellipsis);
        var test_w: c_int = 0;
        var test_h: c_int = 0;
        _ = c.TTF_GetStringSize(font, buf.ptr, candidate_len, &test_w, &test_h);
        if (test_w <= max_width) return buf[0..candidate_len];
    }
    if (ellipsis.len < buf.len) {
        @memcpy(buf[0..ellipsis.len], ellipsis);
        return buf[0..ellipsis.len];
    }
    return text[0..@min(text.len, buf.len)];
}

// -- Filesystem helpers: locate repo root and parse origin URL / HEAD --

/// Walk upward from `cwd` looking for a `.git` directory (or `.git` file for worktrees).
/// Returns a newly-allocated absolute path to the directory containing `.git`.
pub fn findRepoRoot(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        const dot_git = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(dot_git);

        var found = false;
        if (std.fs.openDirAbsolute(dot_git, .{})) |dir_const| {
            var dir = dir_const;
            dir.close();
            found = true;
        } else |_| {
            if (std.fs.openFileAbsolute(dot_git, .{})) |file| {
                file.close();
                found = true;
            } else |_| {}
        }
        if (found) return current;

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }
        const parent_copy = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = parent_copy;
    }
}

/// Look at the git config and decide whether `[remote "origin"]` points at github.com.
/// Resolves `.git` files (worktrees) so it finds the main repo's config.
pub fn detectGithubOrigin(allocator: std.mem.Allocator, repo_root: []const u8) !bool {
    const cfg_path = try resolveConfigPath(allocator, repo_root);
    defer allocator.free(cfg_path);

    var file = std.fs.openFileAbsolute(cfg_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(bytes);

    return originUrlIsGithub(bytes);
}

fn resolveConfigPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]u8 {
    const dot_git = try std.fs.path.join(allocator, &.{ repo_root, ".git" });
    defer allocator.free(dot_git);

    if (std.fs.openDirAbsolute(dot_git, .{})) |dir_const| {
        var dir = dir_const;
        dir.close();
        return std.fs.path.join(allocator, &.{ dot_git, "config" });
    } else |_| {}

    var file = std.fs.openFileAbsolute(dot_git, .{}) catch {
        return std.fs.path.join(allocator, &.{ dot_git, "config" });
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) {
        return std.fs.path.join(allocator, &.{ dot_git, "config" });
    }
    const gitdir_rel = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
    const gitdir_abs = if (std.fs.path.isAbsolute(gitdir_rel))
        try allocator.dupe(u8, gitdir_rel)
    else
        try std.fs.path.resolve(allocator, &.{ repo_root, gitdir_rel });
    defer allocator.free(gitdir_abs);

    // For a worktree, gitdir is `<main>/.git/worktrees/<name>`. The config lives
    // at `<main>/.git/config`. Read `commondir` to find the main gitdir.
    const commondir_path = try std.fs.path.join(allocator, &.{ gitdir_abs, "commondir" });
    defer allocator.free(commondir_path);
    if (std.fs.openFileAbsolute(commondir_path, .{})) |cf| {
        defer cf.close();
        const cb = try cf.readToEndAlloc(allocator, 4096);
        defer allocator.free(cb);
        const ct = std.mem.trim(u8, cb, " \t\r\n");
        if (ct.len > 0) {
            if (std.fs.path.isAbsolute(ct)) {
                return std.fs.path.join(allocator, &.{ ct, "config" });
            }
            return std.fs.path.resolve(allocator, &.{ gitdir_abs, ct, "config" });
        }
    } else |_| {}
    return std.fs.path.join(allocator, &.{ gitdir_abs, "config" });
}

pub fn originUrlIsGithub(config_bytes: []const u8) bool {
    var in_origin_section = false;
    var line_iter = std.mem.splitScalar(u8, config_bytes, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == ';' or line[0] == '#') continue;

        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            const inside = line[1 .. line.len - 1];
            in_origin_section = sectionMatchesOrigin(inside);
            continue;
        }

        if (!in_origin_section) continue;
        // Look for `url = ...`
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "url")) continue;
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\"");
        if (urlPointsToGithub(value)) return true;
    }
    return false;
}

fn sectionMatchesOrigin(section: []const u8) bool {
    // Match `remote "origin"` (allowing arbitrary whitespace and quote style).
    const trimmed = std.mem.trim(u8, section, " \t");
    if (!std.mem.startsWith(u8, trimmed, "remote")) return false;
    const rest = std.mem.trim(u8, trimmed["remote".len..], " \t");
    if (rest.len < 2) return false;
    const first = rest[0];
    const last = rest[rest.len - 1];
    if (!((first == '"' and last == '"') or (first == '\'' and last == '\''))) return false;
    const name = rest[1 .. rest.len - 1];
    return std.mem.eql(u8, name, "origin");
}

fn urlPointsToGithub(url: []const u8) bool {
    // Accept both https://github.com/... and git@github.com:... (and ssh variants).
    if (std.mem.indexOf(u8, url, "github.com") == null) return false;
    return true;
}

/// Read HEAD and return the current branch name (or null if detached HEAD).
/// Handles both regular repos (`.git/HEAD`) and worktrees (`.git` is a file
/// pointing at `gitdir: <path>`; HEAD lives at `<gitdir>/HEAD`).
pub fn readCurrentBranch(allocator: std.mem.Allocator, repo_root: []const u8) !?[]u8 {
    const head_path = try resolveHeadPath(allocator, repo_root);
    defer allocator.free(head_path);

    var file = std.fs.openFileAbsolute(head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const branch = trimmed[prefix.len..];
    if (branch.len == 0) return null;
    return try allocator.dupe(u8, branch);
}

fn resolveHeadPath(allocator: std.mem.Allocator, repo_root: []const u8) ![]u8 {
    const dot_git = try std.fs.path.join(allocator, &.{ repo_root, ".git" });
    defer allocator.free(dot_git);

    // Regular repo: `.git` is a directory.
    if (std.fs.openDirAbsolute(dot_git, .{})) |dir_const| {
        var dir = dir_const;
        dir.close();
        return std.fs.path.join(allocator, &.{ dot_git, "HEAD" });
    } else |_| {}

    // Worktree: `.git` is a file with `gitdir: <path>` body.
    var file = std.fs.openFileAbsolute(dot_git, .{}) catch {
        return std.fs.path.join(allocator, &.{ dot_git, "HEAD" });
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) {
        return std.fs.path.join(allocator, &.{ dot_git, "HEAD" });
    }
    const gitdir_rel = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
    if (std.fs.path.isAbsolute(gitdir_rel)) {
        return std.fs.path.join(allocator, &.{ gitdir_rel, "HEAD" });
    }
    return std.fs.path.resolve(allocator, &.{ repo_root, gitdir_rel, "HEAD" });
}

// -- gh CLI invocation --

fn runGhPrList(allocator: std.mem.Allocator, cwd: []const u8) FetchResult {
    const argv = [_][]const u8{
        "gh",      "pr",     "list",
        "--state", "open",   "--limit",
        "30",      "--json", "number,title,headRefName",
    };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            return FetchResult{
                .status = .gh_missing,
                .prs = &[_]PullRequest{},
                .error_message = null,
            };
        }
        return buildFetchError(allocator, "Failed to launch gh: {s}", .{@errorName(err)});
    };

    var stdout_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch {
        _ = child.kill() catch {};
        return buildFetchError(allocator, "Out of memory reading gh output", .{});
    };
    defer stdout_buf.deinit(allocator);
    var stderr_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch {
        _ = child.kill() catch {};
        return buildFetchError(allocator, "Out of memory reading gh output", .{});
    };
    defer stderr_buf.deinit(allocator);

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 4 * 1024 * 1024) catch |err| {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return buildFetchError(allocator, "Failed to read gh output: {s}", .{@errorName(err)});
    };

    const term = child.wait() catch |err| {
        return buildFetchError(allocator, "Failed to wait for gh: {s}", .{@errorName(err)});
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                const stderr_msg = std.mem.trim(u8, stderr_buf.items, " \t\r\n");
                if (stderr_msg.len > 0) {
                    return buildFetchError(allocator, "gh exited {d}: {s}", .{ code, stderr_msg });
                }
                return buildFetchError(allocator, "gh exited with code {d}", .{code});
            }
        },
        else => return buildFetchError(allocator, "gh terminated abnormally", .{}),
    }

    return parseGhJson(allocator, stdout_buf.items);
}

fn buildFetchError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) FetchResult {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch null;
    return .{
        .status = .failed,
        .prs = &[_]PullRequest{},
        .error_message = msg,
    };
}

pub fn parseGhJson(allocator: std.mem.Allocator, bytes: []const u8) FetchResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, bytes, .{}) catch {
        return buildFetchError(allocator, "Failed to parse gh JSON output", .{});
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) {
        return buildFetchError(allocator, "Unexpected gh JSON shape (expected array)", .{});
    }
    const arr = root.array;

    var prs = std.ArrayList(PullRequest).empty;
    var ok = false;
    defer if (!ok) {
        for (prs.items) |pr| {
            allocator.free(pr.title);
            allocator.free(pr.branch);
        }
        prs.deinit(allocator);
    };

    for (arr.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const number_val = obj.get("number") orelse continue;
        if (number_val != .integer) continue;
        if (number_val.integer <= 0 or number_val.integer > std.math.maxInt(u32)) continue;
        const title_val = obj.get("title") orelse continue;
        const branch_val = obj.get("headRefName") orelse continue;
        if (title_val != .string or branch_val != .string) continue;

        const title_copy = allocator.dupe(u8, title_val.string) catch continue;
        const branch_copy = allocator.dupe(u8, branch_val.string) catch {
            allocator.free(title_copy);
            continue;
        };
        prs.append(allocator, .{
            .number = @intCast(number_val.integer),
            .title = title_copy,
            .branch = branch_copy,
        }) catch {
            allocator.free(title_copy);
            allocator.free(branch_copy);
            continue;
        };
    }

    const owned = prs.toOwnedSlice(allocator) catch {
        return buildFetchError(allocator, "Out of memory parsing PR list", .{});
    };
    ok = true;
    return .{ .status = .ok, .prs = owned, .error_message = null };
}

// --- Tests ---

test "originUrlIsGithub — https origin matches" {
    const cfg =
        \\[core]
        \\    bare = false
        \\[remote "origin"]
        \\    url = https://github.com/foo/bar.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    ;
    try std.testing.expect(originUrlIsGithub(cfg));
}

test "originUrlIsGithub — ssh origin matches" {
    const cfg =
        \\[remote "origin"]
        \\    url = git@github.com:foo/bar.git
    ;
    try std.testing.expect(originUrlIsGithub(cfg));
}

test "originUrlIsGithub — non-github origin returns false" {
    const cfg =
        \\[remote "origin"]
        \\    url = https://gitlab.com/foo/bar.git
    ;
    try std.testing.expect(!originUrlIsGithub(cfg));
}

test "originUrlIsGithub — github URL only in non-origin remote returns false" {
    const cfg =
        \\[remote "upstream"]
        \\    url = https://github.com/foo/bar.git
        \\[remote "origin"]
        \\    url = https://gitlab.com/foo/bar.git
    ;
    try std.testing.expect(!originUrlIsGithub(cfg));
}

test "originUrlIsGithub — comments and blank lines are tolerated" {
    const cfg =
        \\# my config
        \\
        \\[remote "origin"]
        \\    ; comment
        \\    url = https://github.com/foo/bar.git
    ;
    try std.testing.expect(originUrlIsGithub(cfg));
}

test "parseGhJson — parses a basic list" {
    const sample =
        \\[
        \\  {"number": 42, "title": "Add foo", "headRefName": "feature/foo"},
        \\  {"number": 17, "title": "Fix bar", "headRefName": "bugfix/bar"}
        \\]
    ;
    var result = parseGhJson(std.testing.allocator, sample);
    defer freeFetchResult(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(FetchStatus, .ok), result.status);
    try std.testing.expectEqual(@as(usize, 2), result.prs.len);
    try std.testing.expectEqual(@as(u32, 42), result.prs[0].number);
    try std.testing.expectEqualStrings("Add foo", result.prs[0].title);
    try std.testing.expectEqualStrings("feature/foo", result.prs[0].branch);
    try std.testing.expectEqual(@as(u32, 17), result.prs[1].number);
}

test "parseGhJson — skips malformed entries" {
    const sample =
        \\[
        \\  {"number": 1, "title": "Good", "headRefName": "main"},
        \\  {"number": "not a number", "title": "Bad", "headRefName": "x"},
        \\  {"number": 2, "title": "Also good", "headRefName": "feature"}
        \\]
    ;
    var result = parseGhJson(std.testing.allocator, sample);
    defer freeFetchResult(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(FetchStatus, .ok), result.status);
    try std.testing.expectEqual(@as(usize, 2), result.prs.len);
    try std.testing.expectEqual(@as(u32, 1), result.prs[0].number);
    try std.testing.expectEqual(@as(u32, 2), result.prs[1].number);
}

test "parseGhJson — empty list" {
    var result = parseGhJson(std.testing.allocator, "[]");
    defer freeFetchResult(std.testing.allocator, &result);
    try std.testing.expectEqual(@as(FetchStatus, .ok), result.status);
    try std.testing.expectEqual(@as(usize, 0), result.prs.len);
}

test "parseGhJson — invalid JSON yields error" {
    var result = parseGhJson(std.testing.allocator, "{ not json");
    defer freeFetchResult(std.testing.allocator, &result);
    try std.testing.expectEqual(@as(FetchStatus, .failed), result.status);
    try std.testing.expect(result.error_message != null);
}
