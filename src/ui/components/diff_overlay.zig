const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

const log = std.log.scoped(.diff_overlay);

const DiffLineKind = enum { header, add, remove, context, hunk };

const DiffLine = struct {
    kind: DiffLineKind,
    text: []const u8,
};

pub const DiffOverlayComponent = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    first_frame: FirstFrameGuard = .{},

    // Diff content
    lines: std.ArrayList(DiffLine) = .{},
    raw_output: ?[]u8 = null,

    // Scroll state
    scroll_offset: f32 = 0,
    max_scroll: f32 = 0,

    // Cached textures for visible lines
    cached_textures: std.ArrayList(CachedLineTex) = .{},
    cache_start_line: usize = 0,
    cache_font_size: c_int = 0,
    cache_theme_bg: c.SDL_Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    cache_window_w: c_int = 0,

    // Close button state
    close_hovered: bool = false,

    const margin: c_int = 40;
    const title_height: c_int = 50;
    const close_btn_size: c_int = 32;
    const close_btn_margin: c_int = 12;
    const line_height: c_int = 22;
    const text_padding: c_int = 12;
    const font_size: c_int = 13;
    const scroll_speed: f32 = 40.0;
    const CachedLineTex = struct {
        texture: *c.SDL_Texture,
        w: c_int,
        h: c_int,
    };

    pub fn init(allocator: std.mem.Allocator) !*DiffOverlayComponent {
        const comp = try allocator.create(DiffOverlayComponent);
        comp.* = .{ .allocator = allocator };
        return comp;
    }

    pub fn asComponent(self: *DiffOverlayComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 1100,
        };
    }

    pub fn show(self: *DiffOverlayComponent, cwd: ?[]const u8) void {
        self.visible = true;
        self.scroll_offset = 0;
        self.first_frame.markTransition();
        self.loadDiff(cwd);
    }

    pub fn hide(self: *DiffOverlayComponent) void {
        self.visible = false;
        self.clearContent();
        self.first_frame.markTransition();
    }

    pub fn toggle(self: *DiffOverlayComponent, cwd: ?[]const u8) void {
        if (self.visible) {
            self.hide();
        } else {
            self.show(cwd);
        }
    }

    fn loadDiff(self: *DiffOverlayComponent, cwd: ?[]const u8) void {
        self.clearContent();

        const diff_output = runGitDiff(self.allocator, cwd) orelse {
            // Show a message that this is not a git repo or no changes
            self.addLine(.context, "No git diff available (not a git repository or no changes)");
            return;
        };

        self.raw_output = diff_output;
        self.parseDiffOutput(diff_output);
    }

    fn runGitCommand(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch |err| {
            log.warn("failed to spawn git: {}", .{err});
            return null;
        };

        const stdout_file = child.stdout orelse {
            _ = child.wait() catch |err| {
                log.warn("failed to wait for git: {}", .{err});
            };
            return null;
        };

        const max_output = 10 * 1024 * 1024; // 10 MB
        const output = stdout_file.readToEndAlloc(allocator, max_output) catch |err| {
            log.warn("failed to read git output: {}", .{err});
            _ = child.wait() catch |wait_err| {
                log.warn("failed to wait for git: {}", .{wait_err});
            };
            return null;
        };

        _ = child.wait() catch |err| {
            log.warn("failed to wait for git: {}", .{err});
            allocator.free(output);
            return null;
        };

        return output;
    }

    fn runGitDiff(allocator: std.mem.Allocator, cwd: ?[]const u8) ?[]u8 {
        const dir = cwd orelse return null;
        const argv = [_][]const u8{ "git", "-C", dir, "diff", "--no-ext-diff" };
        const output = runGitCommand(allocator, &argv);
        if (output) |out| {
            if (out.len == 0) {
                allocator.free(out);
                return runGitDiffStaged(allocator, dir);
            }
            return out;
        }
        return null;
    }

    fn runGitDiffStaged(allocator: std.mem.Allocator, dir: []const u8) ?[]u8 {
        const argv = [_][]const u8{ "git", "-C", dir, "diff", "--staged", "--no-ext-diff" };
        const output = runGitCommand(allocator, &argv);
        if (output) |out| {
            if (out.len == 0) {
                allocator.free(out);
                return null;
            }
            return out;
        }
        return null;
    }

    fn parseDiffOutput(self: *DiffOverlayComponent, output: []const u8) void {
        var pos: usize = 0;
        while (pos < output.len) {
            const line_end = std.mem.indexOfScalarPos(u8, output, pos, '\n') orelse output.len;
            const line_text = output[pos..line_end];

            const kind: DiffLine = if (line_text.len == 0)
                .{ .kind = .context, .text = line_text }
            else if (std.mem.startsWith(u8, line_text, "diff ") or
                std.mem.startsWith(u8, line_text, "index ") or
                std.mem.startsWith(u8, line_text, "--- ") or
                std.mem.startsWith(u8, line_text, "+++ "))
                .{ .kind = .header, .text = line_text }
            else if (std.mem.startsWith(u8, line_text, "@@"))
                .{ .kind = .hunk, .text = line_text }
            else if (line_text[0] == '+')
                .{ .kind = .add, .text = line_text }
            else if (line_text[0] == '-')
                .{ .kind = .remove, .text = line_text }
            else
                .{ .kind = .context, .text = line_text };

            self.lines.append(self.allocator, kind) catch |err| {
                log.warn("failed to append diff line: {}", .{err});
                return;
            };

            pos = if (line_end < output.len) line_end + 1 else output.len;
        }
    }

    fn addLine(self: *DiffOverlayComponent, kind: DiffLineKind, text: []const u8) void {
        self.lines.append(self.allocator, .{ .kind = kind, .text = text }) catch |err| {
            log.warn("failed to append line: {}", .{err});
        };
    }

    fn clearContent(self: *DiffOverlayComponent) void {
        self.destroyCachedTextures();
        self.lines.deinit(self.allocator);
        self.lines = .{};
        if (self.raw_output) |output| {
            self.allocator.free(output);
            self.raw_output = null;
        }
        self.scroll_offset = 0;
    }

    fn destroyCachedTextures(self: *DiffOverlayComponent) void {
        for (self.cached_textures.items) |cached| {
            c.SDL_DestroyTexture(cached.texture);
        }
        self.cached_textures.deinit(self.allocator);
        self.cached_textures = .{};
        self.cache_start_line = 0;
        self.cache_font_size = 0;
    }

    fn closeButtonRect(host: *const types.UiHost) geom.Rect {
        const scaled_margin = dpi.scale(margin, host.ui_scale);
        const scaled_btn_size = dpi.scale(close_btn_size, host.ui_scale);
        const scaled_btn_margin = dpi.scale(close_btn_margin, host.ui_scale);
        return .{
            .x = host.window_w - scaled_margin - scaled_btn_size - scaled_btn_margin,
            .y = scaled_margin + scaled_btn_margin,
            .w = scaled_btn_size,
            .h = scaled_btn_size,
        };
    }

    fn overlayRect(host: *const types.UiHost) geom.Rect {
        const scaled_margin = dpi.scale(margin, host.ui_scale);
        return .{
            .x = scaled_margin,
            .y = scaled_margin,
            .w = host.window_w - scaled_margin * 2,
            .h = host.window_h - scaled_margin * 2,
        };
    }

    fn handleEventFn(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (!self.visible) {
            // Intercept Cmd+D to open
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT)) != 0;

                if (has_gui and !has_blocking and key == c.SDLK_D) {
                    if (host.view_mode == .Full) {
                        actions.append(.ToggleDiffOverlay) catch |err| {
                            log.warn("failed to queue ToggleDiffOverlay action: {}", .{err});
                        };
                        return true;
                    }
                }
            }
            return false;
        }

        // Overlay is visible - consume all events
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT)) != 0;

                if (key == c.SDLK_ESCAPE) {
                    actions.append(.ToggleDiffOverlay) catch |err| {
                        log.warn("failed to queue ToggleDiffOverlay action: {}", .{err});
                    };
                    return true;
                }

                if (has_gui and !has_blocking and key == c.SDLK_D) {
                    actions.append(.ToggleDiffOverlay) catch |err| {
                        log.warn("failed to queue ToggleDiffOverlay action: {}", .{err});
                    };
                    return true;
                }

                // Arrow key scrolling
                if (key == c.SDLK_UP) {
                    self.scroll_offset = @max(0, self.scroll_offset - scroll_speed);
                    return true;
                }
                if (key == c.SDLK_DOWN) {
                    self.scroll_offset = @min(self.max_scroll, self.scroll_offset + scroll_speed);
                    return true;
                }

                // Block all other keys
                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const wheel_y = event.wheel.y;
                self.scroll_offset = @max(0, self.scroll_offset - wheel_y * scroll_speed);
                self.scroll_offset = @min(self.max_scroll, self.scroll_offset);
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);

                const close_rect = closeButtonRect(host);
                if (geom.containsPoint(close_rect, mouse_x, mouse_y)) {
                    actions.append(.ToggleDiffOverlay) catch |err| {
                        log.warn("failed to queue ToggleDiffOverlay action: {}", .{err});
                    };
                    return true;
                }

                // Consume click inside overlay
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                const close_rect = closeButtonRect(host);
                self.close_hovered = geom.containsPoint(close_rect, mouse_x, mouse_y);
                return true;
            },
            c.SDL_EVENT_KEY_UP, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING => return true,
            else => return false,
        }
    }

    fn updateFn(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn hitTestFn(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return false;
        const rect = overlayRect(host);
        return geom.containsPoint(rect, x, y);
    }

    fn wantsFrameFn(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.first_frame.wantsFrame() or self.visible;
    }

    fn renderFn(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;

        const rect = overlayRect(host);
        const scaled_title_h = dpi.scale(title_height, host.ui_scale);
        const scaled_line_h = dpi.scale(line_height, host.ui_scale);
        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const scaled_font_size = dpi.scale(font_size, host.ui_scale);
        const radius: c_int = dpi.scale(12, host.ui_scale);

        // Calculate max scroll
        const line_count_f: f32 = @floatFromInt(self.lines.items.len);
        const scaled_line_h_f: f32 = @floatFromInt(scaled_line_h);
        const content_height: f32 = line_count_f * scaled_line_h_f;
        const viewport_height: f32 = @floatFromInt(rect.h - scaled_title_h);
        self.max_scroll = @max(0, content_height - viewport_height);
        self.scroll_offset = @min(self.max_scroll, self.scroll_offset);

        // Draw semi-transparent background
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const bg = host.theme.background;
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 240);
        primitives.fillRoundedRect(renderer, rect, radius);

        // Draw border
        const accent = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 180);
        primitives.drawRoundedBorder(renderer, rect, radius);

        // Render title
        self.renderTitle(host, renderer, assets, rect, scaled_title_h, scaled_font_size);

        // Draw separator line
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 80);
        _ = c.SDL_RenderLine(
            renderer,
            @floatFromInt(rect.x + scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
            @floatFromInt(rect.x + rect.w - scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
        );

        // Render close button
        self.renderCloseButton(host, renderer, assets, scaled_font_size);

        // Set clip rect for content area
        const content_clip = c.SDL_Rect{
            .x = rect.x,
            .y = rect.y + scaled_title_h,
            .w = rect.w,
            .h = rect.h - scaled_title_h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &content_clip);

        // Render diff lines
        self.renderDiffLines(host, renderer, assets, rect, scaled_title_h, scaled_line_h, scaled_padding, scaled_font_size);

        // Clear clip rect
        _ = c.SDL_SetRenderClipRect(renderer, null);

        // Render scrollbar
        self.renderScrollbar(host, renderer, rect, scaled_title_h, content_height, viewport_height);

        self.first_frame.markDrawn();
    }

    fn renderTitle(_: *DiffOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets, rect: geom.Rect, title_h: c_int, scaled_font_size: c_int) void {
        const cache = assets.font_cache orelse return;
        const title_font_size = scaled_font_size + dpi.scale(4, host.ui_scale);
        const fonts = cache.get(title_font_size) catch return;
        const bold_font = fonts.bold orelse fonts.regular;

        const title_text = "Git Diff";
        const fg = host.theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };

        var buf: [64]u8 = undefined;
        @memcpy(buf[0..title_text.len], title_text);
        buf[title_text.len] = 0;

        const surface = c.TTF_RenderText_Blended(bold_font, @ptrCast(&buf), title_text.len, fg_color) orelse return;
        defer c.SDL_DestroySurface(surface);
        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(texture);

        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &tw, &th);

        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const text_y = rect.y + @divFloor(title_h - @as(c_int, @intFromFloat(th)), 2);
        _ = c.SDL_RenderTexture(renderer, texture, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + scaled_padding),
            .y = @floatFromInt(text_y),
            .w = tw,
            .h = th,
        });
    }

    fn renderCloseButton(self: *DiffOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets, scaled_font_size: c_int) void {
        const btn_rect = closeButtonRect(host);
        const radius = dpi.scale(6, host.ui_scale);

        // Button background
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        if (self.close_hovered) {
            const red = host.theme.palette[1];
            _ = c.SDL_SetRenderDrawColor(renderer, red.r, red.g, red.b, 200);
        } else {
            const sel = host.theme.selection;
            _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 200);
        }
        primitives.fillRoundedRect(renderer, btn_rect, radius);

        // X text
        const cache = assets.font_cache orelse return;
        const fonts = cache.get(scaled_font_size) catch return;

        const x_text = "X";
        const fg = host.theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };

        var buf: [4]u8 = undefined;
        @memcpy(buf[0..x_text.len], x_text);
        buf[x_text.len] = 0;

        const surface = c.TTF_RenderText_Blended(fonts.regular, @ptrCast(&buf), x_text.len, fg_color) orelse return;
        defer c.SDL_DestroySurface(surface);
        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(texture);

        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &tw, &th);

        const text_x = btn_rect.x + @divFloor(btn_rect.w - @as(c_int, @intFromFloat(tw)), 2);
        const text_y = btn_rect.y + @divFloor(btn_rect.h - @as(c_int, @intFromFloat(th)), 2);
        _ = c.SDL_RenderTexture(renderer, texture, null, &c.SDL_FRect{
            .x = @floatFromInt(text_x),
            .y = @floatFromInt(text_y),
            .w = tw,
            .h = th,
        });
    }

    fn renderDiffLines(self: *DiffOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets, rect: geom.Rect, title_h: c_int, scaled_line_h: c_int, scaled_padding: c_int, scaled_font_size: c_int) void {
        const cache = assets.font_cache orelse return;
        const fonts = cache.get(scaled_font_size) catch return;
        const mono_font = fonts.regular;

        const scroll_int: c_int = @intFromFloat(self.scroll_offset);
        const content_top = rect.y + title_h;
        const content_height = rect.h - title_h;

        // Determine visible line range
        if (scaled_line_h <= 0 or content_height <= 0) return;
        const first_visible: usize = @intCast(@divFloor(scroll_int, scaled_line_h));
        const visible_count: usize = @intCast(@divFloor(content_height, scaled_line_h) + 2);

        var line_idx = first_visible;
        while (line_idx < self.lines.items.len and line_idx < first_visible + visible_count) : (line_idx += 1) {
            const diff_line = self.lines.items[line_idx];
            const y_pos = content_top + @as(c_int, @intCast(line_idx)) * scaled_line_h - scroll_int;

            // Draw line background highlight for adds/removes
            switch (diff_line.kind) {
                .add => {
                    // Green tinted background
                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(renderer, 0, 80, 0, 60);
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(scaled_line_h),
                    });
                },
                .remove => {
                    // Red tinted background
                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(renderer, 80, 0, 0, 60);
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(scaled_line_h),
                    });
                },
                else => {},
            }

            // Determine text color
            const text_color: c.SDL_Color = switch (diff_line.kind) {
                .header => host.theme.palette[3], // Yellow
                .hunk => host.theme.palette[5], // Magenta/Cyan
                .add => host.theme.palette[2], // Green
                .remove => host.theme.palette[1], // Red
                .context => host.theme.foreground,
            };

            // Render line text
            if (diff_line.text.len > 0) {
                self.renderLineText(renderer, mono_font, diff_line.text, text_color, rect.x + scaled_padding, y_pos, rect.w - scaled_padding * 2);
            }
        }
    }

    // max_chars plus room for tab-to-spaces expansion (up to 4 spaces per tab)
    const max_display_buffer: usize = 520;

    fn renderLineText(_: *DiffOverlayComponent, renderer: *c.SDL_Renderer, font: *c.TTF_Font, text: []const u8, color: c.SDL_Color, x: c_int, y: c_int, max_width: c_int) void {
        const max_chars: usize = 512;
        const display_len = @min(text.len, max_chars);

        var buf: [max_display_buffer]u8 = undefined;
        var buf_pos: usize = 0;
        for (text[0..display_len]) |ch| {
            if (ch == '\t') {
                const spaces_to_add = @min(4, buf.len - buf_pos - 1);
                for (0..spaces_to_add) |_| {
                    buf[buf_pos] = ' ';
                    buf_pos += 1;
                }
            } else if (ch >= 32 or ch == 0) {
                if (buf_pos < buf.len - 1) {
                    buf[buf_pos] = ch;
                    buf_pos += 1;
                }
            }
        }
        if (buf_pos == 0) return;
        buf[buf_pos] = 0;

        const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), buf_pos, color) orelse return;
        defer c.SDL_DestroySurface(surface);
        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(texture);

        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &tw, &th);

        // Clip to max_width
        const max_w_f: f32 = @floatFromInt(max_width);
        const render_w = @min(tw, max_w_f);
        var clip_src = c.SDL_FRect{ .x = 0, .y = 0, .w = render_w, .h = th };
        const src_ptr: ?*const c.SDL_FRect = if (tw > max_w_f) &clip_src else null;

        _ = c.SDL_RenderTexture(renderer, texture, src_ptr, &c.SDL_FRect{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = render_w,
            .h = th,
        });
    }

    fn renderScrollbar(self: *DiffOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, rect: geom.Rect, title_h: c_int, content_height: f32, viewport_height: f32) void {
        if (content_height <= viewport_height) return;

        const scrollbar_width = dpi.scale(6, host.ui_scale);
        const scrollbar_margin = dpi.scale(4, host.ui_scale);
        const track_height = rect.h - title_h - scrollbar_margin * 2;
        const thumb_ratio = viewport_height / content_height;
        const thumb_height: c_int = @max(dpi.scale(20, host.ui_scale), @as(c_int, @intFromFloat(@as(f32, @floatFromInt(track_height)) * thumb_ratio)));
        const scroll_ratio = if (self.max_scroll > 0) self.scroll_offset / self.max_scroll else 0;
        const thumb_y: c_int = @intFromFloat(@as(f32, @floatFromInt(track_height - thumb_height)) * scroll_ratio);

        // Draw track
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 128, 128, 128, 30);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + rect.w - scrollbar_width - scrollbar_margin),
            .y = @floatFromInt(rect.y + title_h + scrollbar_margin),
            .w = @floatFromInt(scrollbar_width),
            .h = @floatFromInt(track_height),
        });

        // Draw thumb
        const accent = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 120);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + rect.w - scrollbar_width - scrollbar_margin),
            .y = @floatFromInt(rect.y + title_h + scrollbar_margin + thumb_y),
            .w = @floatFromInt(scrollbar_width),
            .h = @floatFromInt(thumb_height),
        });
    }

    fn destroy(self: *DiffOverlayComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.clearContent();
        self.allocator.destroy(self);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEventFn,
        .hitTest = hitTestFn,
        .update = updateFn,
        .render = renderFn,
        .deinit = deinitComp,
        .wantsFrame = wantsFrameFn,
    };
};
