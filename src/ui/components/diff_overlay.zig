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
        self.clearLines();
        if (self.last_cwd) |cwd| self.allocator.free(cwd);
        self.lines.deinit(self.allocator);
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
                    if (host.view_mode != .Full) return false;
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

        const content_top = scaled_padding + close_rect.h + scaled_padding;
        const content_rect = c.SDL_Rect{
            .x = scaled_padding,
            .y = content_top,
            .w = host.window_w - scaled_padding * 2,
            .h = host.window_h - content_top - scaled_padding,
        };
        if (content_rect.w <= 0 or content_rect.h <= 0) return;

        _ = c.SDL_SetRenderClipRect(renderer, &content_rect);
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

    fn open(self: *DiffOverlayComponent, host: *const types.UiHost) void {
        self.visible = true;
        self.scroll_offset = 0;
        self.first_frame.markTransition();
        self.refreshDiff(host);
    }

    fn refreshDiff(self: *DiffOverlayComponent, host: *const types.UiHost) void {
        self.clearLines();
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
            "--color=always",
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

        const stdout = child.stdout.?.readToEndAlloc(self.allocator, max_output_bytes) catch |err| blk: {
            log.warn("failed to read git diff stdout: {}", .{err});
            break :blk null;
        };
        const stderr = child.stderr.?.readToEndAlloc(self.allocator, max_output_bytes) catch |err| blk: {
            log.warn("failed to read git diff stderr: {}", .{err});
            break :blk null;
        };
        const term = child.wait() catch |err| {
            log.warn("failed to wait on git diff: {}", .{err});
            if (stdout) |buf| self.allocator.free(buf);
            if (stderr) |buf| self.allocator.free(buf);
            self.setSingleLine("Failed to run git diff.", host.theme);
            return;
        };

        defer if (stdout) |buf| self.allocator.free(buf);
        defer if (stderr) |buf| self.allocator.free(buf);

        if (stdout == null) {
            self.setSingleLine("Failed to read git diff output.", host.theme);
            return;
        }

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    const err_text = if (stderr) |buf| buf else "Not a git repository.";
                    self.setSingleLine(err_text, host.theme);
                    return;
                }
            },
            else => {
                const err_text = if (stderr) |buf| buf else "Not a git repository.";
                self.setSingleLine(err_text, host.theme);
                return;
            },
        }

        const output = stdout.?;
        if (output.len == 0) {
            self.setSingleLine("Working tree clean.", host.theme);
            return;
        }

        self.parseDiffOutput(output, host.theme) catch |err| {
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
        primitives.fillRoundedRect(renderer, rect, @max(1, rect.w / 4));
        const acc = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 255);
        primitives.drawRoundedBorder(renderer, rect, @max(1, rect.w / 4));

        const inset = dpi.scale(close_button_padding, host.ui_scale);
        const x1 = rect.x + inset;
        const y1 = rect.y + inset;
        const x2 = rect.x + rect.w - inset;
        const y2 = rect.y + rect.h - inset;
        _ = c.SDL_RenderLine(renderer, x1, y1, x2, y2);
        _ = c.SDL_RenderLine(renderer, x1, y2, x2, y1);
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

        self.destroyCache(renderer);

        const line_fonts = cache.get(font_size) catch return null;
        const title_fonts = cache.get(title_size) catch return null;

        const line_height = dpi.scale(base_font_size + 6, host.ui_scale);

        const title_tex = self.makeTextTexture(renderer, title_fonts.bold orelse title_fonts.regular, "Git Diff", host.theme.foreground) catch return null;

        const line_textures = self.allocator.alloc(LineTexture, self.lines.items.len) catch return null;
        var line_idx: usize = 0;
        while (line_idx < self.lines.items.len) : (line_idx += 1) {
            line_textures[line_idx] = self.buildLineTexture(
                renderer,
                line_fonts.regular,
                self.lines.items[line_idx],
                line_height,
            ) catch LineTexture{
                .tex = null,
                .w = 0,
                .h = line_height,
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

        var surfaces = std.ArrayList(*c.SDL_Surface).init(self.allocator);
        defer surfaces.deinit(self.allocator);
        var widths = std.ArrayList(c_int).init(self.allocator);
        defer widths.deinit(self.allocator);
        var heights = std.ArrayList(c_int).init(self.allocator);
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

    fn clearLines(self: *DiffOverlayComponent) void {
        for (self.lines.items) |line| {
            for (line.segments) |segment| {
                self.allocator.free(segment.text);
            }
            self.allocator.free(line.segments);
        }
        self.lines.clearRetainingCapacity();
    }

    fn setSingleLine(self: *DiffOverlayComponent, text: []const u8, theme: *const colors.Theme) void {
        self.clearLines();
        const segment = Segment{
            .text = self.allocator.dupe(u8, text) catch return,
            .color = theme.foreground,
        };
        const segments = self.allocator.alloc(Segment, 1) catch {
            self.allocator.free(segment.text);
            return;
        };
        segments[0] = segment;
        self.lines.append(self.allocator, .{ .segments = segments }) catch {
            self.allocator.free(segment.text);
            self.allocator.free(segments);
        };
    }

    fn parseDiffOutput(self: *DiffOverlayComponent, output: []const u8, theme: *const colors.Theme) !void {
        var segments = std.ArrayList(Segment).init(self.allocator);
        defer segments.deinit(self.allocator);
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit(self.allocator);

        var color_state = ColorState{ .current = theme.foreground };

        var i: usize = 0;
        while (i < output.len) : (i += 1) {
            const ch = output[i];
            if (ch == 0x1b and i + 1 < output.len and output[i + 1] == '[') {
                const start = i + 2;
                var j = start;
                while (j < output.len and output[j] != 'm') : (j += 1) {}
                if (j < output.len) {
                    try self.flushSegment(&segments, &buffer, color_state.current);
                    color_state.apply(output[start..j], theme);
                    i = j;
                    continue;
                }
            }

            if (ch == '\n') {
                try self.flushSegment(&segments, &buffer, color_state.current);
                try self.finishLine(&segments);
                continue;
            }
            if (ch == '\r') continue;
            try buffer.append(self.allocator, ch);
        }

        try self.flushSegment(&segments, &buffer, color_state.current);
        if (segments.items.len > 0) {
            try self.finishLine(&segments);
        }
        if (self.lines.items.len == 0) {
            self.setSingleLine("Working tree clean.", theme);
        }
    }

    fn flushSegment(
        self: *DiffOverlayComponent,
        segments: *std.ArrayList(Segment),
        buffer: *std.ArrayList(u8),
        color: c.SDL_Color,
    ) !void {
        if (buffer.items.len == 0) return;
        const text = try self.allocator.dupe(u8, buffer.items);
        try segments.append(self.allocator, .{ .text = text, .color = color });
        buffer.clearRetainingCapacity();
    }

    fn finishLine(self: *DiffOverlayComponent, segments: *std.ArrayList(Segment)) !void {
        const seg_slice = try self.allocator.alloc(Segment, segments.items.len);
        @memcpy(seg_slice, segments.items);
        try self.lines.append(self.allocator, .{ .segments = seg_slice });
        segments.clearRetainingCapacity();
    }

    const ColorState = struct {
        current: c.SDL_Color,
        bright: bool = false,

        fn apply(self: *ColorState, seq: []const u8, theme: *const colors.Theme) void {
            if (seq.len == 0) {
                self.reset(theme);
                return;
            }
            var idx: usize = 0;
            while (idx < seq.len) {
                var end = idx;
                while (end < seq.len and seq[end] != ';') : (end += 1) {}
                const token = seq[idx..end];
                if (token.len == 0) {
                    self.reset(theme);
                } else if (std.fmt.parseInt(u8, token, 10)) |value| {
                    switch (value) {
                        0 => self.reset(theme),
                        1 => self.bright = true,
                        22 => self.bright = false,
                        30...37 => self.setPaletteColor(@intCast(value - 30), theme),
                        90...97 => self.setPaletteColor(@intCast(value - 90 + 8), theme),
                        39 => self.current = theme.foreground,
                        else => {},
                    }
                } else |_| {}
                idx = end + 1;
            }
        }

        fn reset(self: *ColorState, theme: *const colors.Theme) void {
            self.current = theme.foreground;
            self.bright = false;
        }

        fn setPaletteColor(self: *ColorState, idx: u8, theme: *const colors.Theme) void {
            var palette_idx = idx;
            if (self.bright and palette_idx < 8) palette_idx += 8;
            self.current = theme.getPaletteColor(palette_idx);
        }
    };

    const vtable = UiComponent.VTable{
        .deinit = deinit,
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .wantsFrame = wantsFrame,
    };
};
