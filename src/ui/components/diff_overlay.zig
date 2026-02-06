const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const log = std.log.scoped(.diff_overlay);

const Segment = struct {
    text: []const u8,
    color: c.SDL_Color,
};

const Line = struct {
    segments: []Segment,
};

const DiffLineKind = enum {
    context,
    add,
    remove,
};

const DiffLine = struct {
    kind: DiffLineKind,
    old_no: ?u32,
    new_no: ?u32,
    text: []const u8,
};

const FileDiff = struct {
    path: []const u8,
    collapsed: bool = false,
    additions: usize = 0,
    deletions: usize = 0,
    lines: []DiffLine,
};

const LineTexture = struct {
    tex: ?*c.SDL_Texture,
    w: c_int,
    h: c_int,
};

const TextTex = struct {
    tex: *c.SDL_Texture,
    w: c_int,
    h: c_int,
};

const Cache = struct {
    ui_scale: f32,
    font_generation: u64,
    line_height: c_int,
    title: TextTex,
    lines: []LineTexture,
};

pub const DiffOverlayComponent = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    scroll_offset: i32 = 0,
    lines: std.ArrayList(Line) = .{},
    line_file_indices: std.ArrayList(?usize) = .{},
    files: std.ArrayList(FileDiff) = .{},
    cache: ?*Cache = null,
    last_cwd: ?[]const u8 = null,
    first_frame: FirstFrameGuard = .{},

    const base_font_size: c_int = 14;
    const title_font_size: c_int = 18;
    const padding: c_int = 24;
    const close_button_size: c_int = 28;
    const close_button_padding: c_int = 6;
    const border_radius: c_int = 8;
    const max_output_bytes: usize = 4 * 1024 * 1024;
    const scroll_lines_per_tick: i32 = 3;

    pub fn create(allocator: std.mem.Allocator) !UiComponent {
        const comp = try allocator.create(DiffOverlayComponent);
        comp.* = .{ .allocator = allocator };
        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 1100,
        };
    }

    fn deinit(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        _ = renderer;
        self.destroyCache();
        self.clearDisplayLines();
        self.clearDiff();
        if (self.last_cwd) |cwd| self.allocator.free(cwd);
        self.lines.deinit(self.allocator);
        self.line_file_indices.deinit(self.allocator);
        self.files.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;

                if (self.visible and key == c.SDLK_ESCAPE) {
                    self.visible = false;
                    return true;
                }

                if (has_gui and !has_blocking_mod and key == c.SDLK_D) {
                    if (self.visible) {
                        self.visible = false;
                    } else {
                        self.open(host);
                    }
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (!self.visible) return false;
                if (event.button.button != c.SDL_BUTTON_LEFT) return false;
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                if (geom.containsPoint(self.closeButtonRect(host), mouse_x, mouse_y)) {
                    self.visible = false;
                    return true;
                }
                if (self.toggleFileAt(host, mouse_x, mouse_y)) {
                    return true;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                if (!self.visible) return false;
                self.scrollByWheel(event);
                return true;
            },
            else => {},
        }

        return false;
    }

    fn hitTest(self_ptr: *anyopaque, _: *const types.UiHost, _: c_int, _: c_int) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.visible;
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.visible or self.first_frame.wantsFrame();
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;

        const cache = self.ensureCache(renderer, host, assets) orelse return;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const bg = host.theme.background;
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 245);
        const bg_rect = c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.window_w),
            .h = @floatFromInt(host.window_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        const accent = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, 200);
        primitives.drawRoundedBorder(renderer, .{
            .x = 0,
            .y = 0,
            .w = host.window_w,
            .h = host.window_h,
        }, border_radius);

        const scaled_padding = dpi.scale(padding, host.ui_scale);
        const close_rect = self.closeButtonRect(host);
        self.renderCloseButton(renderer, close_rect, host);

        _ = c.SDL_RenderTexture(renderer, cache.title.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(scaled_padding),
            .y = @floatFromInt(scaled_padding + @divFloor(close_rect.h - cache.title.h, 2)),
            .w = @floatFromInt(cache.title.w),
            .h = @floatFromInt(cache.title.h),
        });

        const content_rect = self.contentRect(host);
        if (content_rect.w <= 0 or content_rect.h <= 0) return;
        const clip_rect = c.SDL_Rect{
            .x = content_rect.x,
            .y = content_rect.y,
            .w = content_rect.w,
            .h = content_rect.h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &clip_rect);
        defer _ = c.SDL_SetRenderClipRect(renderer, null);

        const total_height: i32 = @as(i32, cache.line_height) * @as(i32, @intCast(cache.lines.len));
        const max_scroll: i32 = @max(0, total_height - content_rect.h);
        self.scroll_offset = std.math.clamp(self.scroll_offset, 0, max_scroll);

        const line_height = cache.line_height;
        const start_line: usize = if (line_height > 0)
            @intCast(@divFloor(@as(i32, self.scroll_offset), line_height))
        else
            0;
        const offset_y: i32 = if (line_height > 0) @rem(self.scroll_offset, line_height) else 0;

        var y: i32 = content_rect.y - offset_y;
        var idx: usize = start_line;
        while (idx < cache.lines.len and y < content_rect.y + content_rect.h) : (idx += 1) {
            const line_tex = cache.lines[idx];
            if (line_tex.tex) |tex| {
                _ = c.SDL_RenderTexture(renderer, tex, null, &c.SDL_FRect{
                    .x = @floatFromInt(content_rect.x),
                    .y = @floatFromInt(y),
                    .w = @floatFromInt(line_tex.w),
                    .h = @floatFromInt(line_tex.h),
                });
            }
            y += line_height;
        }
        self.first_frame.markDrawn();
    }

    fn contentRect(self: *DiffOverlayComponent, host: *const types.UiHost) geom.Rect {
        const scaled_padding = dpi.scale(padding, host.ui_scale);
        const close_rect = self.closeButtonRect(host);
        const content_top = scaled_padding + close_rect.h + scaled_padding;
        return .{
            .x = scaled_padding,
            .y = content_top,
            .w = host.window_w - scaled_padding * 2,
            .h = host.window_h - content_top - scaled_padding,
        };
    }

    fn lineHeight(self: *DiffOverlayComponent, host: *const types.UiHost) c_int {
        if (self.cache) |cache| {
            return cache.line_height;
        }
        return dpi.scale(base_font_size + 6, host.ui_scale);
    }

    fn toggleFileAt(self: *DiffOverlayComponent, host: *const types.UiHost, mouse_x: c_int, mouse_y: c_int) bool {
        if (self.lines.items.len == 0) return false;
        const content_rect = self.contentRect(host);
        if (!geom.containsPoint(content_rect, mouse_x, mouse_y)) return false;
        const line_height = self.lineHeight(host);
        if (line_height <= 0) return false;
        const relative_y = mouse_y - content_rect.y + self.scroll_offset;
        if (relative_y < 0) return false;
        const line_index_signed: i32 = @divFloor(relative_y, line_height);
        if (line_index_signed < 0) return false;
        const line_index: usize = @intCast(line_index_signed);
        if (line_index >= self.line_file_indices.items.len) return false;
        const file_index = self.line_file_indices.items[line_index] orelse return false;
        if (file_index >= self.files.items.len) return false;
        self.files.items[file_index].collapsed = !self.files.items[file_index].collapsed;
        self.rebuildLines(host.theme) catch |err| {
            log.warn("failed to rebuild diff lines: {}", .{err});
        };
        self.destroyCache();
        return true;
    }

    fn open(self: *DiffOverlayComponent, host: *const types.UiHost) void {
        self.visible = true;
        self.scroll_offset = 0;
        self.first_frame.markTransition();
        self.refreshDiff(host);
    }

    fn refreshDiff(self: *DiffOverlayComponent, host: *const types.UiHost) void {
        self.clearDisplayLines();
        self.clearDiff();
        self.destroyCache();

        if (self.last_cwd) |cwd| {
            self.allocator.free(cwd);
            self.last_cwd = null;
        }

        const cwd = host.focused_cwd orelse {
            self.setSingleLine("No working directory detected.", host.theme);
            return;
        };

        self.last_cwd = self.allocator.dupe(u8, cwd) catch |err| {
            log.warn("failed to cache cwd: {}", .{err});
            self.setSingleLine("Unable to read working directory.", host.theme);
            return;
        };

        const argv = [_][]const u8{
            "git",
            "--no-pager",
            "diff",
            "--no-ext-diff",
            "--color=never",
            "--unified=3",
            "--",
            ".",
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.cwd = cwd;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            log.warn("failed to spawn git diff: {}", .{err});
            self.setSingleLine("Failed to run git diff.", host.theme);
            return;
        };

        var stdout = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| {
            log.warn("failed to allocate stdout buffer: {}", .{err});
            self.setSingleLine("Failed to allocate diff buffer.", host.theme);
            return;
        };
        defer stdout.deinit(self.allocator);
        var stderr = std.ArrayList(u8).initCapacity(self.allocator, 256) catch |err| {
            log.warn("failed to allocate stderr buffer: {}", .{err});
            self.setSingleLine("Failed to allocate diff buffer.", host.theme);
            return;
        };
        defer stderr.deinit(self.allocator);

        child.collectOutput(self.allocator, &stdout, &stderr, max_output_bytes) catch |err| {
            log.warn("failed to collect git diff output: {}", .{err});
            const terminate = child.kill() catch |kill_err| switch (kill_err) {
                error.AlreadyTerminated => child.wait() catch |wait_err| {
                    log.warn("failed to wait on git diff: {}", .{wait_err});
                    self.setSingleLine("Failed to stop git diff.", host.theme);
                    return;
                },
                else => {
                    log.warn("failed to terminate git diff: {}", .{kill_err});
                    self.setSingleLine("Failed to stop git diff.", host.theme);
                    return;
                },
            };
            _ = terminate;
            switch (err) {
                error.StdoutStreamTooLong, error.StderrStreamTooLong => {
                    self.setSingleLine("Git diff output too large to display.", host.theme);
                },
                else => {
                    self.setSingleLine("Failed to read git diff output.", host.theme);
                },
            }
            return;
        };

        const term = child.wait() catch |err| {
            log.warn("failed to wait on git diff: {}", .{err});
            self.setSingleLine("Failed to run git diff.", host.theme);
            return;
        };

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    const err_text = if (stderr.items.len > 0) stderr.items else "Not a git repository.";
                    self.setSingleLine(err_text, host.theme);
                    return;
                }
            },
            else => {
                const err_text = if (stderr.items.len > 0) stderr.items else "Not a git repository.";
                self.setSingleLine(err_text, host.theme);
                return;
            },
        }

        if (stdout.items.len == 0) {
            self.setSingleLine("Working tree clean.", host.theme);
            return;
        }

        self.parseDiffOutput(stdout.items, host.theme) catch |err| {
            log.warn("failed to parse diff output: {}", .{err});
            self.setSingleLine("Failed to parse git diff output.", host.theme);
        };
    }

    fn closeButtonRect(self: *DiffOverlayComponent, host: *const types.UiHost) geom.Rect {
        _ = self;
        const scaled_padding = dpi.scale(padding, host.ui_scale);
        const button_size = dpi.scale(close_button_size, host.ui_scale);
        return .{
            .x = host.window_w - scaled_padding - button_size,
            .y = scaled_padding,
            .w = button_size,
            .h = button_size,
        };
    }

    fn renderCloseButton(self: *DiffOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, host: *const types.UiHost) void {
        _ = self;
        const sel = host.theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 220);
        const corner_radius = @max(@as(c_int, 1), @divTrunc(rect.w, @as(c_int, 4)));
        primitives.fillRoundedRect(renderer, rect, corner_radius);
        const acc = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 255);
        primitives.drawRoundedBorder(renderer, rect, corner_radius);

        const inset = dpi.scale(close_button_padding, host.ui_scale);
        const x1 = rect.x + inset;
        const y1 = rect.y + inset;
        const x2 = rect.x + rect.w - inset;
        const y2 = rect.y + rect.h - inset;
        const fx1: f32 = @floatFromInt(x1);
        const fy1: f32 = @floatFromInt(y1);
        const fx2: f32 = @floatFromInt(x2);
        const fy2: f32 = @floatFromInt(y2);
        _ = c.SDL_RenderLine(renderer, fx1, fy1, fx2, fy2);
        _ = c.SDL_RenderLine(renderer, fx1, fy2, fx2, fy1);
    }

    fn scrollByWheel(self: *DiffOverlayComponent, event: *const c.SDL_Event) void {
        if (self.cache == null) return;
        const cache = self.cache.?;
        const ticks: i32 = if (event.wheel.integer_y != 0)
            @intCast(event.wheel.integer_y)
        else
            @intFromFloat(event.wheel.y);
        if (ticks == 0) return;
        const delta = -ticks * cache.line_height * scroll_lines_per_tick;
        self.scroll_offset = self.scroll_offset + delta;
    }

    fn ensureCache(self: *DiffOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets) ?*Cache {
        const cache = assets.font_cache orelse return null;
        const font_size = dpi.scale(base_font_size, host.ui_scale);
        const title_size = dpi.scale(title_font_size, host.ui_scale);
        const generation = cache.generation;

        if (self.cache) |existing| {
            if (existing.ui_scale == host.ui_scale and existing.font_generation == generation) {
                return existing;
            }
        }

        self.destroyCache();

        const line_fonts = cache.get(font_size) catch return null;
        const title_fonts = cache.get(title_size) catch return null;

        const line_height = dpi.scale(base_font_size + 6, host.ui_scale);

        const title_text = self.buildTitleText() catch return null;
        defer self.allocator.free(title_text);
        const title_tex = self.makeTextTexture(renderer, title_fonts.bold orelse title_fonts.regular, title_text, host.theme.foreground) catch return null;

        const line_textures = self.allocator.alloc(LineTexture, self.lines.items.len) catch return null;
        var line_idx: usize = 0;
        while (line_idx < self.lines.items.len) : (line_idx += 1) {
            line_textures[line_idx] = self.buildLineTexture(
                renderer,
                line_fonts.regular,
                self.lines.items[line_idx],
                line_height,
            ) catch |err| blk: {
                log.warn("failed to build diff line texture: {}", .{err});
                break :blk LineTexture{
                    .tex = null,
                    .w = 0,
                    .h = line_height,
                };
            };
        }

        const new_cache = self.allocator.create(Cache) catch return null;
        new_cache.* = .{
            .ui_scale = host.ui_scale,
            .font_generation = generation,
            .line_height = line_height,
            .title = title_tex,
            .lines = line_textures,
        };
        self.cache = new_cache;
        return new_cache;
    }

    fn buildLineTexture(
        self: *DiffOverlayComponent,
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        line: Line,
        line_height: c_int,
    ) !LineTexture {
        if (line.segments.len == 0) {
            return LineTexture{ .tex = null, .w = 0, .h = line_height };
        }

        var surfaces = try std.ArrayList(*c.SDL_Surface).initCapacity(self.allocator, line.segments.len);
        defer surfaces.deinit(self.allocator);
        var widths = try std.ArrayList(c_int).initCapacity(self.allocator, line.segments.len);
        defer widths.deinit(self.allocator);
        var heights = try std.ArrayList(c_int).initCapacity(self.allocator, line.segments.len);
        defer heights.deinit(self.allocator);

        var total_width: c_int = 0;
        var max_height: c_int = 0;

        errdefer {
            for (surfaces.items) |surface| {
                c.SDL_DestroySurface(surface);
            }
        }

        for (line.segments) |segment| {
            const surface = try self.renderSegment(font, segment.text, segment.color);
            try surfaces.append(self.allocator, surface);
            try widths.append(self.allocator, surface.*.w);
            try heights.append(self.allocator, surface.*.h);
            total_width += surface.*.w;
            max_height = @max(max_height, surface.*.h);
        }

        const composite = c.SDL_CreateSurface(total_width, max_height, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(composite);

        _ = c.SDL_SetSurfaceBlendMode(composite, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_FillSurfaceRect(composite, null, 0);

        var x_offset: c_int = 0;
        var idx: usize = 0;
        while (idx < surfaces.items.len) : (idx += 1) {
            const dest = c.SDL_Rect{
                .x = x_offset,
                .y = 0,
                .w = widths.items[idx],
                .h = heights.items[idx],
            };
            _ = c.SDL_BlitSurface(surfaces.items[idx], null, composite, &dest);
            x_offset += widths.items[idx];
        }

        for (surfaces.items) |surface| {
            c.SDL_DestroySurface(surface);
        }

        const texture = c.SDL_CreateTextureFromSurface(renderer, composite) orelse return error.TextureFailed;
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);

        return LineTexture{
            .tex = texture,
            .w = total_width,
            .h = max_height,
        };
    }

    fn renderSegment(
        self: *DiffOverlayComponent,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
    ) !*c.SDL_Surface {
        if (text.len == 0) return error.SurfaceFailed;
        const buf = try self.allocator.alloc(u8, text.len + 1);
        defer self.allocator.free(buf);
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        return c.TTF_RenderText_Blended(font, @ptrCast(buf.ptr), @intCast(text.len), color) orelse error.SurfaceFailed;
    }

    fn makeTextTexture(
        self: *DiffOverlayComponent,
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
    ) !TextTex {
        var buf: [128]u8 = undefined;
        var surface: *c.SDL_Surface = undefined;
        if (text.len < buf.len) {
            @memcpy(buf[0..text.len], text);
            buf[text.len] = 0;
            surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), @intCast(text.len), color) orelse return error.SurfaceFailed;
        } else {
            const heap_buf = try self.allocator.alloc(u8, text.len + 1);
            defer self.allocator.free(heap_buf);
            @memcpy(heap_buf[0..text.len], text);
            heap_buf[text.len] = 0;
            surface = c.TTF_RenderText_Blended(font, @ptrCast(heap_buf.ptr), @intCast(text.len), color) orelse return error.SurfaceFailed;
        }
        defer c.SDL_DestroySurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &w, &h);
        _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
        return TextTex{
            .tex = tex,
            .w = @intFromFloat(w),
            .h = @intFromFloat(h),
        };
    }

    fn destroyCache(self: *DiffOverlayComponent) void {
        const cache = self.cache orelse return;
        c.SDL_DestroyTexture(cache.title.tex);
        for (cache.lines) |line| {
            if (line.tex) |tex| c.SDL_DestroyTexture(tex);
        }
        self.allocator.free(cache.lines);
        self.allocator.destroy(cache);
        self.cache = null;
    }

    fn clearDisplayLines(self: *DiffOverlayComponent) void {
        for (self.lines.items) |line| {
            for (line.segments) |segment| {
                self.allocator.free(segment.text);
            }
            self.allocator.free(line.segments);
        }
        self.lines.clearRetainingCapacity();
        self.line_file_indices.clearRetainingCapacity();
    }

    fn clearDiff(self: *DiffOverlayComponent) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            for (file.lines) |line| {
                if (line.text.len > 0) {
                    self.allocator.free(line.text);
                }
            }
            if (file.lines.len > 0) {
                self.allocator.free(file.lines);
            }
        }
        self.files.clearRetainingCapacity();
    }

    fn setSingleLine(self: *DiffOverlayComponent, text: []const u8, theme: *const colors.Theme) void {
        self.clearDisplayLines();
        self.clearDiff();
        const text_copy = self.allocator.dupe(u8, text) catch return;
        errdefer self.allocator.free(text_copy);
        const segments = self.allocator.alloc(Segment, 1) catch {
            self.allocator.free(text_copy);
            return;
        };
        segments[0] = .{
            .text = text_copy,
            .color = theme.foreground,
        };
        self.appendLine(segments, null) catch {
            for (segments) |segment| self.allocator.free(segment.text);
            self.allocator.free(segments);
        };
    }

    fn parseDiffOutput(self: *DiffOverlayComponent, output: []const u8, theme: *const colors.Theme) !void {
        self.clearDisplayLines();
        self.clearDiff();

        var pending_lines: std.ArrayList(DiffLine) = .empty;
        defer pending_lines.deinit(self.allocator);

        var current_index: ?usize = null;
        var old_line: u32 = 0;
        var new_line: u32 = 0;

        var iter = std.mem.splitScalar(u8, output, '\n');
        while (iter.next()) |raw_line| {
            if (std.mem.startsWith(u8, raw_line, "diff --git ")) {
                try self.finishFile(&pending_lines, current_index);
                current_index = null;
                old_line = 0;
                new_line = 0;

                const path = self.parseDiffHeaderPath(raw_line) orelse continue;
                const path_copy = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(path_copy);
                try self.files.append(self.allocator, .{
                    .path = path_copy,
                    .collapsed = false,
                    .additions = 0,
                    .deletions = 0,
                    .lines = &.{},
                });
                current_index = self.files.items.len - 1;
                continue;
            }

            const file_index = current_index orelse continue;
            if (std.mem.startsWith(u8, raw_line, "@@")) {
                if (parseHunkHeader(raw_line)) |range| {
                    old_line = range.old_start;
                    new_line = range.new_start;
                }
                continue;
            }
            if (std.mem.startsWith(u8, raw_line, "index ") or
                std.mem.startsWith(u8, raw_line, "--- ") or
                std.mem.startsWith(u8, raw_line, "+++ ") or
                std.mem.startsWith(u8, raw_line, "new file") or
                std.mem.startsWith(u8, raw_line, "deleted file") or
                std.mem.startsWith(u8, raw_line, "similarity index") or
                std.mem.startsWith(u8, raw_line, "rename from") or
                std.mem.startsWith(u8, raw_line, "rename to"))
            {
                continue;
            }
            if (raw_line.len == 0) continue;

            const prefix = raw_line[0];
            const content = raw_line[1..];
            const kind: DiffLineKind = switch (prefix) {
                ' ' => .context,
                '+' => .add,
                '-' => .remove,
                else => continue,
            };

            var old_no: ?u32 = null;
            var new_no: ?u32 = null;
            switch (kind) {
                .context => {
                    old_no = old_line;
                    new_no = new_line;
                    old_line += 1;
                    new_line += 1;
                },
                .remove => {
                    old_no = old_line;
                    old_line += 1;
                },
                .add => {
                    new_no = new_line;
                    new_line += 1;
                },
            }

            const file = &self.files.items[file_index];
            try self.appendParsedLine(&pending_lines, file, kind, old_no, new_no, content);
        }

        try self.finishFile(&pending_lines, current_index);
        if (self.files.items.len == 0) {
            self.setSingleLine("Working tree clean.", theme);
            return;
        }
        try self.rebuildLines(theme);
    }

    fn appendParsedLine(
        self: *DiffOverlayComponent,
        pending_lines: *std.ArrayList(DiffLine),
        file: *FileDiff,
        kind: DiffLineKind,
        old_no: ?u32,
        new_no: ?u32,
        text: []const u8,
    ) !void {
        const text_copy = if (text.len == 0) "" else try self.allocator.dupe(u8, text);
        errdefer if (text_copy.len > 0) self.allocator.free(text_copy);
        try pending_lines.append(self.allocator, .{
            .kind = kind,
            .old_no = old_no,
            .new_no = new_no,
            .text = text_copy,
        });
        switch (kind) {
            .add => file.additions += 1,
            .remove => file.deletions += 1,
            else => {},
        }
    }

    fn finishFile(self: *DiffOverlayComponent, pending_lines: *std.ArrayList(DiffLine), current_index: ?usize) !void {
        const file_index = current_index orelse return;
        if (pending_lines.items.len > 0) {
            const slice = try self.allocator.alloc(DiffLine, pending_lines.items.len);
            @memcpy(slice, pending_lines.items);
            self.files.items[file_index].lines = slice;
        }
        pending_lines.clearRetainingCapacity();
    }

    fn rebuildLines(self: *DiffOverlayComponent, theme: *const colors.Theme) !void {
        self.clearDisplayLines();

        var max_old: u32 = 0;
        var max_new: u32 = 0;
        for (self.files.items) |file| {
            for (file.lines) |line| {
                if (line.old_no) |value| {
                    if (value > max_old) max_old = value;
                }
                if (line.new_no) |value| {
                    if (value > max_new) max_new = value;
                }
            }
        }

        const old_width = digits(max_old);
        const new_width = digits(max_new);

        var file_idx: usize = 0;
        while (file_idx < self.files.items.len) : (file_idx += 1) {
            const file = &self.files.items[file_idx];
            try self.appendHeaderLine(file, file_idx, theme);
            if (file.collapsed) continue;
            for (file.lines) |line| {
                try self.appendDiffLine(line, old_width, new_width, theme);
            }
        }

        if (self.lines.items.len == 0) {
            self.setSingleLine("Working tree clean.", theme);
        }
    }

    fn appendHeaderLine(self: *DiffOverlayComponent, file: *const FileDiff, file_idx: usize, theme: *const colors.Theme) !void {
        const marker = if (file.collapsed) "[+]" else "[-]";
        const header = if (file.additions > 0 or file.deletions > 0)
            try std.fmt.allocPrint(self.allocator, "{s} {s} (+{d} -{d})", .{ marker, file.path, file.additions, file.deletions })
        else
            try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ marker, file.path });
        errdefer self.allocator.free(header);

        const segments = try self.allocator.alloc(Segment, 1);
        segments[0] = .{
            .text = header,
            .color = theme.accent,
        };
        try self.appendLine(segments, file_idx);
    }

    fn buildTitleText(self: *DiffOverlayComponent) ![]const u8 {
        const base = "Git Diff - ";
        const cwd = self.last_cwd orelse return self.allocator.dupe(u8, "Git Diff");
        const max_len: usize = 120;
        if (base.len + cwd.len <= max_len) {
            return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, cwd });
        }

        if (max_len <= base.len + 3) {
            return self.allocator.dupe(u8, "Git Diff");
        }

        const tail_len = max_len - base.len - 3;
        const tail = cwd[cwd.len - tail_len ..];
        return std.fmt.allocPrint(self.allocator, "{s}...{s}", .{ base, tail });
    }

    fn appendDiffLine(self: *DiffOverlayComponent, line: DiffLine, old_width: usize, new_width: usize, theme: *const colors.Theme) !void {
        const number_col = try self.formatLineNumberColumn(line.old_no, line.new_no, old_width, new_width);
        errdefer self.allocator.free(number_col);
        const content = try self.formatLineContent(line.kind, line.text);
        errdefer self.allocator.free(content);

        const segments = try self.allocator.alloc(Segment, 2);
        segments[0] = .{
            .text = number_col,
            .color = theme.getPaletteColor(8),
        };
        segments[1] = .{
            .text = content,
            .color = colorForLineKind(line.kind, theme),
        };
        try self.appendLine(segments, null);
    }

    fn appendLine(self: *DiffOverlayComponent, segments: []Segment, file_index: ?usize) !void {
        try self.lines.append(self.allocator, .{ .segments = segments });
        errdefer {
            self.lines.items.len -= 1;
            for (segments) |segment| self.allocator.free(segment.text);
            self.allocator.free(segments);
        }
        try self.line_file_indices.append(self.allocator, file_index);
    }

    fn formatLineNumberColumn(
        self: *DiffOverlayComponent,
        old_no: ?u32,
        new_no: ?u32,
        old_width: usize,
        new_width: usize,
    ) ![]const u8 {
        const total_len = old_width + 1 + new_width + 1;
        const buf = try self.allocator.alloc(u8, total_len);
        @memset(buf, ' ');
        if (old_no) |value| {
            writeNumberRightAligned(buf[0..old_width], value);
        }
        if (new_no) |value| {
            const start = old_width + 1;
            writeNumberRightAligned(buf[start .. start + new_width], value);
        }
        return buf;
    }

    fn formatLineContent(self: *DiffOverlayComponent, kind: DiffLineKind, text: []const u8) ![]const u8 {
        const prefix: u8 = switch (kind) {
            .context => ' ',
            .add => '+',
            .remove => '-',
        };
        const buf = try self.allocator.alloc(u8, text.len + 2);
        buf[0] = prefix;
        buf[1] = ' ';
        if (text.len > 0) {
            @memcpy(buf[2..], text);
        }
        return buf;
    }

    fn parseDiffHeaderPath(self: *DiffOverlayComponent, line: []const u8) ?[]const u8 {
        _ = self;
        const marker = " b/";
        const idx = std.mem.indexOf(u8, line, marker) orelse return null;
        return line[idx + marker.len ..];
    }

    fn digits(value: u32) usize {
        var remaining = value;
        var count: usize = 1;
        while (remaining >= 10) : (remaining /= 10) {
            count += 1;
        }
        return count;
    }

    fn writeNumberRightAligned(dest: []u8, value: u32) void {
        var buf: [20]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        if (out.len > dest.len) return;
        const start = dest.len - out.len;
        @memcpy(dest[start .. start + out.len], out);
    }

    fn colorForLineKind(kind: DiffLineKind, theme: *const colors.Theme) c.SDL_Color {
        return switch (kind) {
            .context => theme.foreground,
            .add => theme.getPaletteColor(10),
            .remove => theme.getPaletteColor(9),
        };
    }

    const HunkRange = struct {
        old_start: u32,
        new_start: u32,
    };

    fn parseHunkHeader(line: []const u8) ?HunkRange {
        if (!std.mem.startsWith(u8, line, "@@")) return null;
        var idx: usize = 2;
        while (idx < line.len and line[idx] == ' ') : (idx += 1) {}
        if (idx >= line.len or line[idx] != '-') return null;
        idx += 1;
        const old_start = parseNumber(line, &idx) orelse return null;
        if (idx < line.len and line[idx] == ',') {
            idx += 1;
            _ = parseNumber(line, &idx) orelse return null;
        }
        while (idx < line.len and line[idx] != '+') : (idx += 1) {}
        if (idx >= line.len) return null;
        idx += 1;
        const new_start = parseNumber(line, &idx) orelse return null;
        return .{
            .old_start = old_start,
            .new_start = new_start,
        };
    }

    fn parseNumber(line: []const u8, idx: *usize) ?u32 {
        const start = idx.*;
        var value: u32 = 0;
        while (idx.* < line.len) : (idx.* += 1) {
            const ch = line[idx.*];
            if (ch < '0' or ch > '9') break;
            value = value * 10 + @as(u32, ch - '0');
        }
        if (idx.* == start) return null;
        return value;
    }

    const vtable = UiComponent.VTable{
        .deinit = deinit,
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .wantsFrame = wantsFrame,
    };
};
