const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const easing = @import("../../anim/easing.zig");

const log = std.log.scoped(.story_overlay);

// === Data types ===

const CodeLineKind = enum { context, add, remove };

const CodeBlockMeta = struct {
    file: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    change_type: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

const DisplayRowKind = enum {
    prose_line,
    diff_header,
    diff_line,
    code_line,
    separator,
};

const DisplayRow = struct {
    kind: DisplayRowKind,
    text: []const u8 = "",
    code_line_kind: CodeLineKind = .context,
    bold: bool = false,
};

const SegmentKind = enum {
    text,
    marker,
};

const SegmentTexture = struct {
    tex: *c.SDL_Texture,
    kind: SegmentKind,
    x_offset: c_int,
    w: c_int,
    h: c_int,
};

const LineTexture = struct {
    segments: []SegmentTexture,
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

// === Component ===

pub const StoryOverlayComponent = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    first_frame: FirstFrameGuard = .{},

    raw_content: ?[]u8 = null,
    display_rows: std.ArrayList(DisplayRow) = .{},
    cache: ?*Cache = null,
    file_path: ?[]u8 = null,

    scroll_offset: f32 = 0,
    max_scroll: f32 = 0,
    close_hovered: bool = false,

    wrap_cols: usize = 0,

    animation_state: AnimationState = .closed,
    animation_start_ms: i64 = 0,
    render_alpha: f32 = 1.0,

    const AnimationState = enum { closed, opening, open, closing };
    const animation_duration_ms: i64 = 250;
    const scale_from: f32 = 0.97;

    const outer_margin: c_int = 40;
    const title_height: c_int = 50;
    const close_btn_size: c_int = 32;
    const close_btn_margin: c_int = 12;
    const row_height: c_int = 22;
    const text_padding: c_int = 12;
    const font_size: c_int = 13;
    const scroll_speed: f32 = 40.0;
    const marker_width: c_int = 20;
    const code_indent: c_int = 8;
    const max_display_buffer: usize = 520;

    pub fn init(allocator: std.mem.Allocator) !*StoryOverlayComponent {
        const comp = try allocator.create(StoryOverlayComponent);
        comp.* = .{ .allocator = allocator };
        return comp;
    }

    pub fn asComponent(self: *StoryOverlayComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 1200,
        };
    }

    pub fn show(self: *StoryOverlayComponent, path: []const u8, now_ms: i64) bool {
        self.clearContent();
        self.scroll_offset = 0;

        const content = self.readFile(path) orelse {
            log.warn("failed to read story file: {s}", .{path});
            return false;
        };
        self.raw_content = content;

        const path_dupe = self.allocator.dupe(u8, path) catch |err| {
            log.warn("failed to duplicate story path: {}", .{err});
            return false;
        };
        if (self.file_path) |old| self.allocator.free(old);
        self.file_path = path_dupe;

        self.parseAndBuild(content);

        if (self.display_rows.items.len == 0) {
            log.warn("story file is empty: {s}", .{path});
            return false;
        }

        self.visible = true;
        self.animation_state = .opening;
        self.animation_start_ms = now_ms;
        self.first_frame.markTransition();
        return true;
    }

    pub fn hide(self: *StoryOverlayComponent, now_ms: i64) void {
        self.animation_state = .closing;
        self.animation_start_ms = now_ms;
        self.first_frame.markTransition();
    }

    fn readFile(self: *StoryOverlayComponent, path: []const u8) ?[]u8 {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            log.warn("failed to open story file {s}: {}", .{ path, err });
            return null;
        };
        defer file.close();

        const max_size: usize = 4 * 1024 * 1024;
        return file.readToEndAlloc(self.allocator, max_size) catch |err| {
            log.warn("failed to read story file {s}: {}", .{ path, err });
            return null;
        };
    }

    fn parseAndBuild(self: *StoryOverlayComponent, content: []const u8) void {
        // Parse the markdown content into display rows.
        // We look for ```story-diff and other ``` fenced blocks.
        var pos: usize = 0;

        while (pos < content.len) {
            // Look for the next fenced code block
            const fence_start = findFenceStart(content, pos);

            if (fence_start) |fs| {
                // Add prose before this fence
                if (fs.start > pos) {
                    self.addProseRows(content[pos..fs.start]);
                }

                // Find the closing fence
                const close = findFenceClose(content, fs.content_start);
                const block_end = if (close) |cl| cl.after else content.len;
                const block_content = if (close) |cl| content[fs.content_start..cl.start] else content[fs.content_start..];

                if (fs.is_story_diff) {
                    self.addDiffBlock(block_content);
                } else {
                    self.addCodeBlock(block_content);
                }

                pos = block_end;
            } else {
                // No more fences — rest is prose
                if (pos < content.len) {
                    self.addProseRows(content[pos..]);
                }
                break;
            }
        }
    }

    const FenceStart = struct {
        start: usize, // position of the opening ```
        content_start: usize, // position after the info line
        is_story_diff: bool,
    };

    const FenceClose = struct {
        start: usize, // position of the closing ```
        after: usize, // position after the closing ``` line
    };

    fn findFenceStart(content: []const u8, from: usize) ?FenceStart {
        var pos = from;
        while (pos < content.len) {
            // Find start of a line
            if (pos > 0 and content[pos - 1] != '\n') {
                const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse return null;
                pos = nl + 1;
                continue;
            }

            if (pos + 3 <= content.len and std.mem.eql(u8, content[pos..][0..3], "```")) {
                const line_end = std.mem.indexOfScalarPos(u8, content, pos + 3, '\n') orelse content.len;
                const info_string = std.mem.trim(u8, content[pos + 3 .. line_end], " \t\r");
                const is_diff = std.mem.eql(u8, info_string, "story-diff");
                return FenceStart{
                    .start = pos,
                    .content_start = if (line_end < content.len) line_end + 1 else content.len,
                    .is_story_diff = is_diff,
                };
            }

            const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n');
            if (nl) |n| {
                pos = n + 1;
            } else {
                break;
            }
        }
        return null;
    }

    fn findFenceClose(content: []const u8, from: usize) ?FenceClose {
        var pos = from;
        while (pos < content.len) {
            // Check if current position is start of a line with ```
            if (pos == 0 or (pos > 0 and content[pos - 1] == '\n')) {
                if (pos + 3 <= content.len and std.mem.eql(u8, content[pos..][0..3], "```")) {
                    // Check that the rest of the line is just whitespace
                    const line_end = std.mem.indexOfScalarPos(u8, content, pos + 3, '\n') orelse content.len;
                    const rest = std.mem.trim(u8, content[pos + 3 .. line_end], " \t\r");
                    if (rest.len == 0) {
                        return FenceClose{
                            .start = pos,
                            .after = if (line_end < content.len) line_end + 1 else content.len,
                        };
                    }
                }
            }

            const nl = std.mem.indexOfScalarPos(u8, content, pos, '\n');
            if (nl) |n| {
                pos = n + 1;
            } else {
                break;
            }
        }
        return null;
    }

    fn addProseRows(self: *StoryOverlayComponent, text: []const u8) void {
        var line_start: usize = 0;
        while (line_start <= text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            const line = std.mem.trimRight(u8, text[line_start..line_end], " \t\r");

            if (line.len == 0) {
                self.display_rows.append(self.allocator, .{
                    .kind = .separator,
                }) catch |err| {
                    log.warn("failed to append separator row: {}", .{err});
                    return;
                };
            } else {
                // Detect markdown headings
                var heading_level: usize = 0;
                var content_start: usize = 0;
                while (content_start < line.len and line[content_start] == '#') {
                    heading_level += 1;
                    content_start += 1;
                }
                if (heading_level > 0 and content_start < line.len and line[content_start] == ' ') {
                    content_start += 1; // skip space after #
                }
                const is_heading = heading_level > 0 and heading_level <= 6;

                const display_text = if (is_heading) line[content_start..] else line;
                self.addWrappedProseRows(display_text, is_heading);
            }

            if (line_end >= text.len) break;
            line_start = line_end + 1;
        }
    }

    fn addWrappedProseRows(self: *StoryOverlayComponent, text: []const u8, bold: bool) void {
        if (text.len == 0) return;

        const max_cols = if (self.wrap_cols > 0) self.wrap_cols else 120;

        if (text.len <= max_cols) {
            self.display_rows.append(self.allocator, .{
                .kind = .prose_line,
                .text = text,
                .bold = bold,
            }) catch |err| {
                log.warn("failed to append prose row: {}", .{err});
            };
            return;
        }

        // Word-wrap
        var pos: usize = 0;
        while (pos < text.len) {
            var end = @min(pos + max_cols, text.len);
            if (end < text.len) {
                // Find last space before end for word-wrap
                var space_pos = end;
                while (space_pos > pos) {
                    space_pos -= 1;
                    if (text[space_pos] == ' ') break;
                }
                if (space_pos > pos) {
                    end = space_pos;
                }
            }

            self.display_rows.append(self.allocator, .{
                .kind = .prose_line,
                .text = text[pos..end],
                .bold = if (pos == 0) bold else false,
            }) catch |err| {
                log.warn("failed to append wrapped prose row: {}", .{err});
                return;
            };

            pos = end;
            // Skip space at wrap point
            if (pos < text.len and text[pos] == ' ') pos += 1;
        }
    }

    fn addDiffBlock(self: *StoryOverlayComponent, content: []const u8) void {
        // Add a separator before the code block
        self.display_rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
            return;
        };

        // Parse metadata from first line if it's an HTML comment
        var lines_start: usize = 0;
        var meta = CodeBlockMeta{};

        const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        const first_line = std.mem.trim(u8, content[0..first_line_end], " \t\r");

        if (std.mem.startsWith(u8, first_line, "<!--") and std.mem.endsWith(u8, first_line, "-->")) {
            // Extract JSON between <!-- and -->
            const json_start = 4; // skip "<!--"
            const json_end = first_line.len - 3; // skip "-->"
            if (json_start < json_end) {
                const json_str = std.mem.trim(u8, first_line[json_start..json_end], " ");
                meta = parseMetaJson(json_str);
            }
            lines_start = if (first_line_end < content.len) first_line_end + 1 else content.len;
        }

        // Build header text
        self.addDiffHeaderRow(meta);

        // Parse diff lines
        var pos = lines_start;
        while (pos < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
            const line = content[pos..line_end];

            const kind: CodeLineKind = if (line.len > 0 and line[0] == '+')
                .add
            else if (line.len > 0 and line[0] == '-')
                .remove
            else
                .context;

            self.display_rows.append(self.allocator, .{
                .kind = .diff_line,
                .text = line,
                .code_line_kind = kind,
            }) catch |err| {
                log.warn("failed to append diff line: {}", .{err});
                return;
            };

            if (line_end >= content.len) break;
            pos = line_end + 1;
        }

        // Separator after
        self.display_rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
        };
    }

    fn addDiffHeaderRow(self: *StoryOverlayComponent, meta: CodeBlockMeta) void {
        // Build header text: "file — description" or just "file" or just "description"
        if (meta.file == null and meta.description == null) return;

        var buf: [512]u8 = undefined;
        var buf_pos: usize = 0;

        if (meta.file) |file| {
            const copy_len = @min(file.len, buf.len - buf_pos);
            @memcpy(buf[buf_pos..][0..copy_len], file[0..copy_len]);
            buf_pos += copy_len;
        }

        if (meta.file != null and meta.description != null) {
            const sep = " \xe2\x80\x94 "; // " — " UTF-8
            const sep_len = @min(sep.len, buf.len - buf_pos);
            @memcpy(buf[buf_pos..][0..sep_len], sep[0..sep_len]);
            buf_pos += sep_len;
        }

        if (meta.description) |desc| {
            const copy_len = @min(desc.len, buf.len - buf_pos);
            @memcpy(buf[buf_pos..][0..copy_len], desc[0..copy_len]);
            buf_pos += copy_len;
        }

        if (buf_pos == 0) return;

        // Store header text — it points into raw_content or the static buf.
        // We need to allocate to keep it alive.
        const header_text = self.allocator.dupe(u8, buf[0..buf_pos]) catch |err| {
            log.warn("failed to allocate diff header text: {}", .{err});
            return;
        };
        // Store in a display row. The text will be freed via freeHeaderTexts.
        self.display_rows.append(self.allocator, .{
            .kind = .diff_header,
            .text = header_text,
            .bold = true,
        }) catch |err| {
            log.warn("failed to append diff header: {}", .{err});
            self.allocator.free(header_text);
        };
    }

    fn addCodeBlock(self: *StoryOverlayComponent, content: []const u8) void {
        // Regular fenced code block (not story-diff)
        self.display_rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
            return;
        };

        var pos: usize = 0;
        while (pos < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
            const line = content[pos..line_end];

            self.display_rows.append(self.allocator, .{
                .kind = .code_line,
                .text = line,
            }) catch |err| {
                log.warn("failed to append code line: {}", .{err});
                return;
            };

            if (line_end >= content.len) break;
            pos = line_end + 1;
        }

        self.display_rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
        };
    }

    fn parseMetaJson(json_str: []const u8) CodeBlockMeta {
        var meta = CodeBlockMeta{};

        // Simple JSON field extraction without a full parser.
        // Looks for "key": "value" patterns.
        meta.file = extractJsonString(json_str, "file");
        meta.commit = extractJsonString(json_str, "commit");
        meta.change_type = extractJsonString(json_str, "type");
        meta.description = extractJsonString(json_str, "description");

        return meta;
    }

    fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        // Look for "key": "value" pattern
        // Build the search needle: "key"
        var needle_buf: [128]u8 = undefined;
        if (key.len + 3 > needle_buf.len) return null;
        needle_buf[0] = '"';
        @memcpy(needle_buf[1..][0..key.len], key);
        needle_buf[1 + key.len] = '"';
        const needle = needle_buf[0 .. key.len + 2];

        const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
        var pos = key_pos + needle.len;

        // Skip whitespace and colon
        while (pos < json.len and (json[pos] == ' ' or json[pos] == ':')) : (pos += 1) {}

        if (pos >= json.len or json[pos] != '"') return null;
        pos += 1; // skip opening quote

        const value_start = pos;
        // Find closing quote (handle escaped quotes)
        while (pos < json.len) {
            if (json[pos] == '\\' and pos + 1 < json.len) {
                pos += 2;
                continue;
            }
            if (json[pos] == '"') break;
            pos += 1;
        }

        if (pos >= json.len) return null;
        return json[value_start..pos];
    }

    fn clearContent(self: *StoryOverlayComponent) void {
        // Free any heap-allocated diff header texts
        for (self.display_rows.items) |row| {
            if (row.kind == .diff_header) {
                self.allocator.free(row.text);
            }
        }
        self.display_rows.deinit(self.allocator);
        self.display_rows = .{};

        if (self.raw_content) |content| {
            self.allocator.free(content);
            self.raw_content = null;
        }

        self.destroyCache();
    }

    // --- Animation ---

    fn animationProgress(self: *StoryOverlayComponent, now_ms: i64) f32 {
        const elapsed = now_ms - self.animation_start_ms;
        if (elapsed >= animation_duration_ms) return 1.0;
        if (elapsed <= 0) return 0.0;
        const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(animation_duration_ms));
        return easing.easeInOutCubic(t);
    }

    // --- Event handling ---

    fn handleEventFn(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        _ = actions;

        if (!self.visible) return false;

        // While animating closed, consume events but don't process
        if (self.animation_state == .closing) return true;
        // While animating open, consume events but wait for completion
        if (self.animation_state == .opening) return true;

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;

                if (key == c.SDLK_ESCAPE) {
                    self.hide(host.now_ms);
                    return true;
                }

                if (key == c.SDLK_UP) {
                    self.scroll_offset = @max(0, self.scroll_offset - scroll_speed);
                    return true;
                }
                if (key == c.SDLK_DOWN) {
                    self.scroll_offset = @min(self.max_scroll, self.scroll_offset + scroll_speed);
                    return true;
                }
                if (key == c.SDLK_PAGEUP) {
                    const page: f32 = @floatFromInt(host.window_h - dpi.scale(title_height + outer_margin * 2, host.ui_scale));
                    self.scroll_offset = @max(0, self.scroll_offset - page);
                    return true;
                }
                if (key == c.SDLK_PAGEDOWN) {
                    const page: f32 = @floatFromInt(host.window_h - dpi.scale(title_height + outer_margin * 2, host.ui_scale));
                    self.scroll_offset = @min(self.max_scroll, self.scroll_offset + page);
                    return true;
                }
                if (key == c.SDLK_HOME) {
                    self.scroll_offset = 0;
                    return true;
                }
                if (key == c.SDLK_END) {
                    self.scroll_offset = self.max_scroll;
                    return true;
                }

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
                    self.hide(host.now_ms);
                    return true;
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                const close_rect = closeButtonRect(host);
                self.close_hovered = geom.containsPoint(close_rect, mouse_x, mouse_y);
                return true;
            },
            else => return false,
        }
    }

    fn updateFn(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (self.animation_state == .opening and self.animationProgress(host.now_ms) >= 1.0) {
            self.animation_state = .open;
        }
        if (self.animation_state == .closing and self.animationProgress(host.now_ms) >= 1.0) {
            self.animation_state = .closed;
            self.visible = false;
        }
    }

    fn hitTestFn(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible or self.animation_state == .closing) return false;
        const rect = overlayRect(host);
        return geom.containsPoint(rect, x, y);
    }

    fn wantsFrameFn(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.first_frame.wantsFrame() or self.animation_state == .opening or self.animation_state == .closing;
    }

    // --- Rendering ---

    fn renderFn(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;

        const raw_progress = self.animationProgress(host.now_ms);
        const progress: f32 = switch (self.animation_state) {
            .opening => raw_progress,
            .closing => 1.0 - raw_progress,
            .open => 1.0,
            .closed => 0.0,
        };
        self.render_alpha = progress;

        if (progress <= 0.001) return;

        const cache_result = self.ensureCache(renderer, host, assets);
        const cache = cache_result orelse return;

        const rect = animatedOverlayRect(host, progress);
        const scaled_title_h = dpi.scale(title_height, host.ui_scale);
        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const scaled_font_size = dpi.scale(font_size, host.ui_scale);
        const radius: c_int = dpi.scale(12, host.ui_scale);

        const row_count_f: f32 = @floatFromInt(self.display_rows.items.len);
        const scaled_line_h_f: f32 = @floatFromInt(cache.line_height);
        const content_height: f32 = row_count_f * scaled_line_h_f;
        const viewport_height: f32 = @floatFromInt(rect.h - scaled_title_h);
        self.max_scroll = @max(0, content_height - viewport_height);
        self.scroll_offset = @min(self.max_scroll, self.scroll_offset);

        // Background
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const bg = host.theme.background;
        const bg_alpha: u8 = @intFromFloat(240.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, bg_alpha);
        primitives.fillRoundedRect(renderer, rect, radius);

        // Border
        const accent = host.theme.accent;
        const border_alpha: u8 = @intFromFloat(180.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, border_alpha);
        primitives.drawRoundedBorder(renderer, rect, radius);

        // Title
        self.renderTitle(renderer, rect, scaled_title_h, scaled_padding, cache);

        // Title separator line
        const line_alpha: u8 = @intFromFloat(80.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, line_alpha);
        _ = c.SDL_RenderLine(
            renderer,
            @floatFromInt(rect.x + scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
            @floatFromInt(rect.x + rect.w - scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
        );

        // Close button
        self.renderCloseButton(host, renderer, rect, scaled_font_size);

        // Content clip
        const content_clip = c.SDL_Rect{
            .x = rect.x,
            .y = rect.y + scaled_title_h,
            .w = rect.w,
            .h = rect.h - scaled_title_h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &content_clip);

        self.renderContent(host, renderer, rect, scaled_title_h, scaled_padding, cache);

        _ = c.SDL_SetRenderClipRect(renderer, null);

        self.renderScrollbar(host, renderer, rect, scaled_title_h, content_height, viewport_height);

        self.first_frame.markDrawn();
    }

    fn renderTitle(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, title_h: c_int, padding: c_int, cache: *Cache) void {
        const tex_alpha: u8 = @intFromFloat(255.0 * self.render_alpha);
        _ = c.SDL_SetTextureAlphaMod(cache.title.tex, tex_alpha);

        const text_y = rect.y + @divFloor(title_h - cache.title.h, 2);
        _ = c.SDL_RenderTexture(renderer, cache.title.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + padding),
            .y = @floatFromInt(text_y),
            .w = @floatFromInt(cache.title.w),
            .h = @floatFromInt(cache.title.h),
        });
    }

    fn renderCloseButton(self: *StoryOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, overlay_rect: geom.Rect, _: c_int) void {
        const scaled_btn_size = dpi.scale(close_btn_size, host.ui_scale);
        const scaled_btn_margin = dpi.scale(close_btn_margin, host.ui_scale);
        const btn_rect = geom.Rect{
            .x = overlay_rect.x + overlay_rect.w - scaled_btn_size - scaled_btn_margin,
            .y = overlay_rect.y + scaled_btn_margin,
            .w = scaled_btn_size,
            .h = scaled_btn_size,
        };

        const fg = host.theme.foreground;
        const alpha: u8 = @intFromFloat(if (self.close_hovered) 255.0 * self.render_alpha else 160.0 * self.render_alpha);
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, alpha);

        const cross_size: c_int = @divFloor(btn_rect.w * 6, 10);
        const cross_x = btn_rect.x + @divFloor(btn_rect.w - cross_size, 2);
        const cross_y = btn_rect.y + @divFloor(btn_rect.h - cross_size, 2);

        const x1: f32 = @floatFromInt(cross_x);
        const y1: f32 = @floatFromInt(cross_y);
        const x2: f32 = @floatFromInt(cross_x + cross_size);
        const y2: f32 = @floatFromInt(cross_y + cross_size);

        _ = c.SDL_RenderLine(renderer, x1, y1, x2, y2);
        _ = c.SDL_RenderLine(renderer, x2, y1, x1, y2);

        if (self.close_hovered) {
            const bold_offset: f32 = 1.0;
            _ = c.SDL_RenderLine(renderer, x1 + bold_offset, y1, x2 + bold_offset, y2);
            _ = c.SDL_RenderLine(renderer, x2 + bold_offset, y1, x1 + bold_offset, y2);
            _ = c.SDL_RenderLine(renderer, x1, y1 + bold_offset, x2, y2 + bold_offset);
            _ = c.SDL_RenderLine(renderer, x2, y1 + bold_offset, x1, y2 + bold_offset);
        }
    }

    fn renderContent(self: *StoryOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, rect: geom.Rect, title_h: c_int, padding: c_int, cache: *Cache) void {
        const alpha = self.render_alpha;
        const scroll_int: c_int = @intFromFloat(self.scroll_offset);
        const content_top = rect.y + title_h;
        const content_h = rect.h - title_h;

        const line_h = cache.line_height;
        if (line_h <= 0 or content_h <= 0) return;

        const first_visible: usize = @intCast(@divFloor(scroll_int, line_h));
        const fg = host.theme.foreground;
        const accent = host.theme.accent;
        _ = padding;

        var row_index: usize = first_visible;
        while (row_index < self.display_rows.items.len) : (row_index += 1) {
            const row = self.display_rows.items[row_index];
            const y_pos: c_int = content_top + @as(c_int, @intCast(row_index)) * line_h - scroll_int;

            // Stop when below viewport
            if (y_pos > content_top + content_h) break;
            // Skip rows above viewport
            if (y_pos + line_h < content_top) continue;

            // Draw row backgrounds
            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
            switch (row.kind) {
                .diff_header => {
                    _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, @intFromFloat(20.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(line_h),
                    });
                },
                .diff_line => {
                    switch (row.code_line_kind) {
                        .add => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 0, 80, 0, @intFromFloat(60.0 * alpha));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(rect.w - 2),
                                .h = @floatFromInt(line_h),
                            });
                        },
                        .remove => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 80, 0, 0, @intFromFloat(60.0 * alpha));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(rect.w - 2),
                                .h = @floatFromInt(line_h),
                            });
                        },
                        .context => {},
                    }
                },
                .code_line => {
                    _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, @intFromFloat(8.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(line_h),
                    });
                },
                .separator, .prose_line => {},
            }

            // Render text
            if (row_index >= cache.lines.len) continue;
            const line_tex = cache.lines[row_index];
            for (line_tex.segments) |segment| {
                const tex_alpha: u8 = @intFromFloat(255.0 * alpha);
                _ = c.SDL_SetTextureAlphaMod(segment.tex, tex_alpha);

                const dest_x: c_int = rect.x + segment.x_offset;
                const dest_y: c_int = y_pos;

                var render_w: c_int = segment.w;
                const render_h: c_int = segment.h;
                var clip_src: c.SDL_FRect = undefined;
                var src_ptr: ?*const c.SDL_FRect = null;

                // Clip text that extends beyond the overlay
                const used = dest_x - rect.x;
                const scaled_padding = dpi.scale(text_padding, host.ui_scale);
                const max_width = rect.w - used - scaled_padding;
                if (max_width <= 0) continue;
                if (segment.w > max_width) {
                    render_w = max_width;
                    clip_src = c.SDL_FRect{
                        .x = 0,
                        .y = 0,
                        .w = @floatFromInt(render_w),
                        .h = @floatFromInt(render_h),
                    };
                    src_ptr = &clip_src;
                }

                _ = c.SDL_RenderTexture(renderer, segment.tex, src_ptr, &c.SDL_FRect{
                    .x = @floatFromInt(dest_x),
                    .y = @floatFromInt(dest_y),
                    .w = @floatFromInt(render_w),
                    .h = @floatFromInt(render_h),
                });
            }
        }
    }

    fn renderScrollbar(self: *StoryOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, rect: geom.Rect, title_h: c_int, content_height: f32, viewport_height: f32) void {
        if (content_height <= viewport_height) return;

        const scrollbar_width = dpi.scale(6, host.ui_scale);
        const scrollbar_margin = dpi.scale(4, host.ui_scale);
        const track_height = rect.h - title_h - scrollbar_margin * 2;
        const thumb_ratio = viewport_height / content_height;
        const thumb_height: c_int = @max(dpi.scale(20, host.ui_scale), @as(c_int, @intFromFloat(@as(f32, @floatFromInt(track_height)) * thumb_ratio)));
        const scroll_ratio = if (self.max_scroll > 0) self.scroll_offset / self.max_scroll else 0;
        const thumb_y: c_int = @intFromFloat(@as(f32, @floatFromInt(track_height - thumb_height)) * scroll_ratio);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const bar_alpha = self.render_alpha;
        _ = c.SDL_SetRenderDrawColor(renderer, 128, 128, 128, @intFromFloat(30.0 * bar_alpha));
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + rect.w - scrollbar_width - scrollbar_margin),
            .y = @floatFromInt(rect.y + title_h + scrollbar_margin),
            .w = @floatFromInt(scrollbar_width),
            .h = @floatFromInt(track_height),
        });

        const accent_col = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent_col.r, accent_col.g, accent_col.b, @intFromFloat(120.0 * bar_alpha));
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + rect.w - scrollbar_width - scrollbar_margin),
            .y = @floatFromInt(rect.y + title_h + scrollbar_margin + thumb_y),
            .w = @floatFromInt(scrollbar_width),
            .h = @floatFromInt(thumb_height),
        });
    }

    // --- Cache management ---

    fn ensureCache(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets) ?*Cache {
        const font_cache_ptr = assets.font_cache orelse return null;
        const generation = font_cache_ptr.generation;

        if (self.cache) |existing| {
            if (existing.ui_scale == host.ui_scale and existing.font_generation == generation) {
                return existing;
            }
        }

        self.destroyCache();

        const scaled_font_size = dpi.scale(font_size, host.ui_scale);
        const title_font_size = scaled_font_size + dpi.scale(4, host.ui_scale);
        const line_fonts = font_cache_ptr.get(scaled_font_size) catch return null;
        const title_fonts = font_cache_ptr.get(title_font_size) catch return null;

        const mono_font = line_fonts.regular;
        const bold_font = line_fonts.bold orelse line_fonts.regular;

        self.updateWrapCols(renderer, host, mono_font);

        const title_text_str = self.buildTitleText() catch return null;
        defer self.allocator.free(title_text_str);
        const title_tex = self.makeTextTexture(
            renderer,
            title_fonts.bold orelse title_fonts.regular,
            title_text_str,
            host.theme.foreground,
        ) catch return null;

        const line_height_scaled = dpi.scale(row_height, host.ui_scale);
        const line_textures = self.allocator.alloc(LineTexture, self.display_rows.items.len) catch {
            c.SDL_DestroyTexture(title_tex.tex);
            return null;
        };

        var idx: usize = 0;
        while (idx < self.display_rows.items.len) : (idx += 1) {
            line_textures[idx] = self.buildLineTexture(renderer, host, mono_font, bold_font, self.display_rows.items[idx]) catch |err| blk: {
                log.warn("failed to build story line texture: {}", .{err});
                break :blk LineTexture{ .segments = &.{} };
            };
        }

        const new_cache = self.allocator.create(Cache) catch {
            self.destroyLineTextures(line_textures);
            c.SDL_DestroyTexture(title_tex.tex);
            self.allocator.free(line_textures);
            return null;
        };
        new_cache.* = .{
            .ui_scale = host.ui_scale,
            .font_generation = generation,
            .line_height = line_height_scaled,
            .title = title_tex,
            .lines = line_textures,
        };
        self.cache = new_cache;
        return new_cache;
    }

    fn updateWrapCols(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, mono_font: *c.TTF_Font) void {
        const char_w = measureCharWidth(renderer, mono_font) orelse return;
        if (char_w <= 0) return;

        const rect = overlayRect(host);
        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const scrollbar_w = dpi.scale(10, host.ui_scale);
        const text_area_w = rect.w - scaled_padding * 2 - scrollbar_w;
        if (text_area_w <= 0) return;

        const new_wrap: usize = @intCast(@divFloor(text_area_w, char_w));
        if (new_wrap != self.wrap_cols and new_wrap > 0) {
            self.wrap_cols = new_wrap;
            // Rebuild display rows with new wrap width
            if (self.raw_content) |content| {
                // Free old diff header texts
                for (self.display_rows.items) |d_row| {
                    if (d_row.kind == .diff_header) {
                        self.allocator.free(d_row.text);
                    }
                }
                self.display_rows.deinit(self.allocator);
                self.display_rows = .{};
                self.parseAndBuild(content);
            }
        }
    }

    fn measureCharWidth(renderer: *c.SDL_Renderer, font: *c.TTF_Font) ?c_int {
        const probe = "0";
        var buf: [2]u8 = .{ probe[0], 0 };
        const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), 1, c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 }) orelse return null;
        defer c.SDL_DestroySurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return null;
        defer c.SDL_DestroyTexture(tex);
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &w, &h);
        return @intFromFloat(w);
    }

    fn buildTitleText(self: *StoryOverlayComponent) ![]const u8 {
        const prefix = "Story";
        const file_path = self.file_path orelse return self.allocator.dupe(u8, prefix);
        const base = std.fs.path.basename(file_path);

        const max_len: usize = 120;
        if (prefix.len + 3 + base.len <= max_len) {
            return std.fmt.allocPrint(self.allocator, "{s} \xe2\x80\x94 {s}", .{ prefix, base });
        }

        if (max_len <= prefix.len + 3) {
            return self.allocator.dupe(u8, prefix);
        }

        const tail_len = max_len - prefix.len - 3;
        const tail = base[base.len - tail_len ..];
        return std.fmt.allocPrint(self.allocator, "{s} \xe2\x80\x94 ...{s}", .{ prefix, tail });
    }

    fn buildLineTexture(
        self: *StoryOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        mono_font: *c.TTF_Font,
        bold_font: *c.TTF_Font,
        d_row: DisplayRow,
    ) !LineTexture {
        var segments = try std.ArrayList(SegmentTexture).initCapacity(self.allocator, 2);
        errdefer {
            for (segments.items) |segment| {
                c.SDL_DestroyTexture(segment.tex);
            }
            segments.deinit(self.allocator);
        }

        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const scaled_marker_w = dpi.scale(marker_width, host.ui_scale);
        const scaled_code_indent = dpi.scale(code_indent, host.ui_scale);
        const fg = host.theme.foreground;

        switch (d_row.kind) {
            .separator => {},
            .prose_line => {
                if (d_row.text.len == 0) return LineTexture{ .segments = &.{} };
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(d_row.text, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                const font = if (d_row.bold) bold_font else mono_font;
                try self.appendSegmentTexture(&segments, renderer, font, text, fg, .text, scaled_padding);
            },
            .diff_header => {
                if (d_row.text.len == 0) return LineTexture{ .segments = &.{} };
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(d_row.text, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                try self.appendSegmentTexture(&segments, renderer, bold_font, text, host.theme.accent, .text, scaled_padding + scaled_code_indent);
            },
            .diff_line => {
                // Marker (+/-)
                const marker_str: []const u8 = switch (d_row.code_line_kind) {
                    .add => "+",
                    .remove => "-",
                    .context => " ",
                };
                const marker_color: c.SDL_Color = switch (d_row.code_line_kind) {
                    .add => host.theme.palette[2],
                    .remove => host.theme.palette[1],
                    .context => fg,
                };

                try self.appendSegmentTexture(&segments, renderer, mono_font, marker_str, marker_color, .marker, scaled_padding + scaled_code_indent);

                // Line text (skip the first character which is the +/-/ marker)
                const text_slice = if (d_row.text.len > 0) d_row.text else "";
                if (text_slice.len > 0) {
                    var buf: [max_display_buffer]u8 = undefined;
                    const text = sanitizeText(text_slice, &buf);
                    if (text.len > 0) {
                        const text_color: c.SDL_Color = switch (d_row.code_line_kind) {
                            .add => host.theme.palette[2],
                            .remove => host.theme.palette[1],
                            .context => fg,
                        };
                        try self.appendSegmentTexture(&segments, renderer, mono_font, text, text_color, .text, scaled_padding + scaled_code_indent + scaled_marker_w);
                    }
                }
            },
            .code_line => {
                if (d_row.text.len == 0) return LineTexture{ .segments = &.{} };
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(d_row.text, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                try self.appendSegmentTexture(&segments, renderer, mono_font, text, fg, .text, scaled_padding + scaled_code_indent);
            },
        }

        return LineTexture{ .segments = try segments.toOwnedSlice(self.allocator) };
    }

    fn appendSegmentTexture(
        self: *StoryOverlayComponent,
        segments: *std.ArrayList(SegmentTexture),
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
        kind: SegmentKind,
        x_offset: c_int,
    ) !void {
        if (text.len == 0) return;
        const tex = try self.makeTextTexture(renderer, font, text, color);
        errdefer c.SDL_DestroyTexture(tex.tex);
        try segments.append(self.allocator, .{
            .tex = tex.tex,
            .kind = kind,
            .x_offset = x_offset,
            .w = tex.w,
            .h = tex.h,
        });
    }

    fn makeTextTexture(
        self: *StoryOverlayComponent,
        renderer: *c.SDL_Renderer,
        font: *c.TTF_Font,
        text: []const u8,
        color: c.SDL_Color,
    ) !TextTex {
        if (text.len == 0) return error.EmptyText;

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

    fn sanitizeText(text: []const u8, buf: []u8) []const u8 {
        const max_chars: usize = 512;
        const display_len = @min(text.len, max_chars);
        var buf_pos: usize = 0;

        for (text[0..display_len]) |ch| {
            if (ch == '\t') {
                if (buf_pos + 1 >= buf.len) break;
                const remaining = buf.len - buf_pos - 1;
                const spaces_to_add = @min(4, remaining);
                var idx: usize = 0;
                while (idx < spaces_to_add) : (idx += 1) {
                    buf[buf_pos] = ' ';
                    buf_pos += 1;
                }
            } else if (ch >= 32 or ch == 0) {
                if (buf_pos + 1 >= buf.len) break;
                buf[buf_pos] = ch;
                buf_pos += 1;
            }
        }

        return buf[0..buf_pos];
    }

    fn destroyCache(self: *StoryOverlayComponent) void {
        const cache_ptr = self.cache orelse return;
        c.SDL_DestroyTexture(cache_ptr.title.tex);
        self.destroyLineTextures(cache_ptr.lines);
        self.allocator.free(cache_ptr.lines);
        self.allocator.destroy(cache_ptr);
        self.cache = null;
    }

    fn destroyLineTextures(self: *StoryOverlayComponent, lines: []LineTexture) void {
        for (lines) |line| {
            for (line.segments) |segment| {
                c.SDL_DestroyTexture(segment.tex);
            }
            if (line.segments.len > 0) {
                self.allocator.free(line.segments);
            }
        }
    }

    // --- Layout ---

    fn overlayRect(host: *const types.UiHost) geom.Rect {
        const scaled_margin = dpi.scale(outer_margin, host.ui_scale);
        return .{
            .x = scaled_margin,
            .y = scaled_margin,
            .w = host.window_w - scaled_margin * 2,
            .h = host.window_h - scaled_margin * 2,
        };
    }

    fn animatedOverlayRect(host: *const types.UiHost, progress: f32) geom.Rect {
        const base = overlayRect(host);
        const scale = scale_from + (1.0 - scale_from) * progress;
        const base_w: f32 = @floatFromInt(base.w);
        const base_h: f32 = @floatFromInt(base.h);
        const base_x: f32 = @floatFromInt(base.x);
        const base_y: f32 = @floatFromInt(base.y);
        const new_w = base_w * scale;
        const new_h = base_h * scale;
        return .{
            .x = @intFromFloat(base_x + (base_w - new_w) / 2.0),
            .y = @intFromFloat(base_y + (base_h - new_h) / 2.0),
            .w = @intFromFloat(new_w),
            .h = @intFromFloat(new_h),
        };
    }

    fn closeButtonRect(host: *const types.UiHost) geom.Rect {
        const scaled_margin = dpi.scale(outer_margin, host.ui_scale);
        const scaled_btn_size = dpi.scale(close_btn_size, host.ui_scale);
        const scaled_btn_margin = dpi.scale(close_btn_margin, host.ui_scale);
        return .{
            .x = host.window_w - scaled_margin - scaled_btn_size - scaled_btn_margin,
            .y = scaled_margin + scaled_btn_margin,
            .w = scaled_btn_size,
            .h = scaled_btn_size,
        };
    }

    // --- Deinit ---

    fn destroy(self: *StoryOverlayComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.clearContent();
        self.display_rows.deinit(self.allocator);
        if (self.file_path) |path| {
            self.allocator.free(path);
            self.file_path = null;
        }
        self.allocator.destroy(self);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *StoryOverlayComponent = @ptrCast(@alignCast(self_ptr));
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
