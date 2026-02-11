const std = @import("std");

const log = std.log.scoped(.story_parser);

// === Public types ===

pub const CodeLineKind = enum { context, add, remove };

pub const CodeBlockMeta = struct {
    file: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    change_type: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const DisplayRowKind = enum {
    prose_line,
    diff_header,
    diff_line,
    code_line,
    separator,
};

pub const LineAnchor = struct {
    number: u8,
    char_offset: usize,
};

pub const DisplayRow = struct {
    kind: DisplayRowKind,
    text: []const u8 = "",
    code_line_kind: CodeLineKind = .context,
    bold: bool = false,
    anchors: []const LineAnchor = &.{},
    owns_text: bool = false,
};

// === Public API ===

pub fn parse(allocator: std.mem.Allocator, content: []const u8, wrap_cols: usize) std.ArrayList(DisplayRow) {
    var rows = std.ArrayList(DisplayRow){};
    var ctx = ParseContext{
        .allocator = allocator,
        .rows = &rows,
        .wrap_cols = wrap_cols,
    };
    ctx.parseContent(content);
    return rows;
}

pub fn freeDisplayRows(allocator: std.mem.Allocator, rows: *std.ArrayList(DisplayRow)) void {
    for (rows.items) |row| {
        if (row.owns_text) {
            allocator.free(row.text);
        }
        if (row.anchors.len > 0) {
            allocator.free(row.anchors);
        }
    }
    rows.deinit(allocator);
    rows.* = .{};
}

// === Internal parsing context ===

const ParseContext = struct {
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(DisplayRow),
    wrap_cols: usize,

    fn parseContent(self: *ParseContext, content: []const u8) void {
        var pos: usize = 0;

        while (pos < content.len) {
            const fence_start = findFenceStart(content, pos);

            if (fence_start) |fs| {
                if (fs.start > pos) {
                    self.addProseRows(content[pos..fs.start]);
                }

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
                if (pos < content.len) {
                    self.addProseRows(content[pos..]);
                }
                break;
            }
        }
    }

    // --- Fence detection ---

    const FenceStart = struct {
        start: usize,
        content_start: usize,
        is_story_diff: bool,
    };

    const FenceClose = struct {
        start: usize,
        after: usize,
    };

    fn findFenceStart(content: []const u8, from: usize) ?FenceStart {
        var pos = from;
        while (pos < content.len) {
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
            if (pos == 0 or (pos > 0 and content[pos - 1] == '\n')) {
                if (pos + 3 <= content.len and std.mem.eql(u8, content[pos..][0..3], "```")) {
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

    // --- Prose parsing ---

    fn addProseRows(self: *ParseContext, text: []const u8) void {
        var line_start: usize = 0;
        while (line_start < text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            const line = std.mem.trimRight(u8, text[line_start..line_end], " \t\r");

            if (line.len == 0) {
                self.rows.append(self.allocator, .{
                    .kind = .separator,
                }) catch |err| {
                    log.warn("failed to append separator row: {}", .{err});
                    return;
                };
            } else {
                var heading_level: usize = 0;
                var content_start: usize = 0;
                while (content_start < line.len and line[content_start] == '#') {
                    heading_level += 1;
                    content_start += 1;
                }
                if (heading_level > 0 and content_start < line.len and line[content_start] == ' ') {
                    content_start += 1;
                }
                const is_heading = heading_level > 0 and heading_level <= 6;

                const display_text = if (is_heading) line[content_start..] else line;
                self.addWrappedProseRows(display_text, is_heading);
            }

            if (line_end >= text.len) break;
            line_start = line_end + 1;
        }
    }

    fn addWrappedProseRows(self: *ParseContext, text: []const u8, bold: bool) void {
        if (text.len == 0) return;

        // Check for anchors. If none, use original text directly (it's a slice of
        // the content buffer and outlives the display rows). If anchors exist, strip
        // them into a heap-allocated buffer so the rows don't hold dangling pointers.
        var anchors_buf: [32]LineAnchor = undefined;
        var anchor_count: usize = 0;
        var stripped: []const u8 = text;
        var stripped_is_owned = false;

        if (std.mem.indexOf(u8, text, "**[") != null) {
            var stack_buf: [4096]u8 = undefined;
            const strip_result = stripProseAnchors(text, &stack_buf, &anchors_buf);
            anchor_count = strip_result.anchor_count;
            if (anchor_count > 0) {
                if (self.allocator.dupe(u8, strip_result.text)) |duped| {
                    stripped = duped;
                    stripped_is_owned = true;
                } else |err| {
                    log.warn("failed to allocate stripped prose text: {}", .{err});
                    anchor_count = 0;
                }
            }
        }

        const max_cols = if (self.wrap_cols > 0) self.wrap_cols else 120;

        if (stripped.len <= max_cols) {
            const anchors = if (anchor_count > 0)
                self.allocator.dupe(LineAnchor, anchors_buf[0..anchor_count]) catch |err| blk: {
                    log.warn("failed to dupe anchor: {}", .{err});
                    break :blk &[0]LineAnchor{};
                }
            else
                &[0]LineAnchor{};

            self.rows.append(self.allocator, .{
                .kind = .prose_line,
                .text = stripped,
                .bold = bold,
                .anchors = anchors,
                .owns_text = stripped_is_owned,
            }) catch |err| {
                log.warn("failed to append prose row: {}", .{err});
                if (stripped_is_owned) self.allocator.free(stripped);
            };
            return;
        }

        // Word-wrap with anchor position tracking.
        // When stripped_is_owned, each segment gets its own heap allocation
        // so it can be freed independently in freeDisplayRows.
        var pos: usize = 0;
        while (pos < stripped.len) {
            var end = @min(pos + max_cols, stripped.len);
            if (end < stripped.len) {
                var space_pos = end;
                while (space_pos > pos) {
                    space_pos -= 1;
                    if (stripped[space_pos] == ' ') break;
                }
                if (space_pos > pos) {
                    end = space_pos;
                }
            }

            // Collect anchors that fall within this wrapped line
            var line_anchor_count: usize = 0;
            var line_anchors_buf: [16]LineAnchor = undefined;
            for (anchors_buf[0..anchor_count]) |anchor| {
                if (anchor.char_offset >= pos and anchor.char_offset < end) {
                    if (line_anchor_count < line_anchors_buf.len) {
                        line_anchors_buf[line_anchor_count] = .{
                            .number = anchor.number,
                            .char_offset = anchor.char_offset - pos,
                        };
                        line_anchor_count += 1;
                    }
                }
            }

            const line_anchors = if (line_anchor_count > 0)
                self.allocator.dupe(LineAnchor, line_anchors_buf[0..line_anchor_count]) catch |err| blk: {
                    log.warn("failed to dupe anchor: {}", .{err});
                    break :blk &[0]LineAnchor{};
                }
            else
                &[0]LineAnchor{};

            const segment = stripped[pos..end];
            const row_text = if (stripped_is_owned)
                self.allocator.dupe(u8, segment) catch |err| blk: {
                    log.warn("failed to allocate wrapped segment: {}", .{err});
                    break :blk segment;
                }
            else
                segment;
            const segment_owned = stripped_is_owned and row_text.ptr != segment.ptr;

            self.rows.append(self.allocator, .{
                .kind = .prose_line,
                .text = row_text,
                .bold = bold,
                .anchors = line_anchors,
                .owns_text = segment_owned,
            }) catch |err| {
                log.warn("failed to append wrapped prose row: {}", .{err});
                if (segment_owned) self.allocator.free(row_text);
                return;
            };

            pos = end;
            if (pos < stripped.len and stripped[pos] == ' ') pos += 1;
        }

        // Free the original stripped buffer now that all segments have their own copies
        if (stripped_is_owned) self.allocator.free(stripped);
    }

    // --- Code block parsing ---

    fn addDiffBlock(self: *ParseContext, content: []const u8) void {
        self.rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
            return;
        };

        var lines_start: usize = 0;
        var meta = CodeBlockMeta{};

        const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        const first_line = std.mem.trim(u8, content[0..first_line_end], " \t\r");

        if (std.mem.startsWith(u8, first_line, "<!--") and std.mem.endsWith(u8, first_line, "-->")) {
            const json_start = 4;
            const json_end = first_line.len - 3;
            if (json_start < json_end) {
                const json_str = std.mem.trim(u8, first_line[json_start..json_end], " ");
                meta = parseMetaJson(json_str);
            }
            lines_start = if (first_line_end < content.len) first_line_end + 1 else content.len;
        }

        self.addDiffHeaderRow(meta);

        var pos = lines_start;
        while (pos < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
            const raw_line = content[pos..line_end];

            const kind: CodeLineKind = if (raw_line.len > 0 and raw_line[0] == '+')
                .add
            else if (raw_line.len > 0 and raw_line[0] == '-')
                .remove
            else
                .context;

            // Strip <!--ref:N--> and append circled-number emoji if present
            const ref_result = stripCodeRef(raw_line);
            var row_text: []const u8 = ref_result.text;
            var text_owned = false;
            var anchors: []const LineAnchor = &.{};

            if (ref_result.ref_number) |num| {
                const emoji = circledDigit(num);
                const base_text = ref_result.text;
                if (self.allocator.alloc(u8, base_text.len + 1 + 3)) |buf| {
                    @memcpy(buf[0..base_text.len], base_text);
                    buf[base_text.len] = ' ';
                    @memcpy(buf[base_text.len + 1 ..][0..3], &emoji);
                    row_text = buf;
                    text_owned = true;
                    const cp_offset = bytesToCodepoints(base_text) + 1;
                    anchors = self.allocator.dupe(LineAnchor, &[1]LineAnchor{.{
                        .number = num,
                        .char_offset = cp_offset,
                    }}) catch |err| blk: {
                        log.warn("failed to dupe anchor: {}", .{err});
                        break :blk &[0]LineAnchor{};
                    };
                } else |err| {
                    log.warn("failed to allocate code line with anchor: {}", .{err});
                }
            }

            self.rows.append(self.allocator, .{
                .kind = .diff_line,
                .text = row_text,
                .code_line_kind = kind,
                .anchors = anchors,
                .owns_text = text_owned,
            }) catch |err| {
                log.warn("failed to append diff line: {}", .{err});
                if (text_owned) self.allocator.free(row_text);
                return;
            };

            if (line_end >= content.len) break;
            pos = line_end + 1;
        }

        self.rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
        };
    }

    fn addDiffHeaderRow(self: *ParseContext, meta: CodeBlockMeta) void {
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

        const header_text = self.allocator.dupe(u8, buf[0..buf_pos]) catch |err| {
            log.warn("failed to allocate diff header text: {}", .{err});
            return;
        };
        self.rows.append(self.allocator, .{
            .kind = .diff_header,
            .text = header_text,
            .bold = true,
            .owns_text = true,
        }) catch |err| {
            log.warn("failed to append diff header: {}", .{err});
            self.allocator.free(header_text);
        };
    }

    fn addCodeBlock(self: *ParseContext, content: []const u8) void {
        self.rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
            return;
        };

        var pos: usize = 0;
        while (pos < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
            const raw_line = content[pos..line_end];

            // Strip <!--ref:N--> and append circled-number emoji if present
            const ref_result = stripCodeRef(raw_line);
            var row_text: []const u8 = ref_result.text;
            var text_owned = false;
            var anchors: []const LineAnchor = &.{};

            if (ref_result.ref_number) |num| {
                const emoji = circledDigit(num);
                const base_text = ref_result.text;
                if (self.allocator.alloc(u8, base_text.len + 1 + 3)) |buf| {
                    @memcpy(buf[0..base_text.len], base_text);
                    buf[base_text.len] = ' ';
                    @memcpy(buf[base_text.len + 1 ..][0..3], &emoji);
                    row_text = buf;
                    text_owned = true;
                    const cp_offset = bytesToCodepoints(base_text) + 1;
                    anchors = self.allocator.dupe(LineAnchor, &[1]LineAnchor{.{
                        .number = num,
                        .char_offset = cp_offset,
                    }}) catch |err| blk: {
                        log.warn("failed to dupe anchor: {}", .{err});
                        break :blk &[0]LineAnchor{};
                    };
                } else |err| {
                    log.warn("failed to allocate code line with anchor: {}", .{err});
                }
            }

            self.rows.append(self.allocator, .{
                .kind = .code_line,
                .text = row_text,
                .anchors = anchors,
                .owns_text = text_owned,
            }) catch |err| {
                log.warn("failed to append code line: {}", .{err});
                if (text_owned) self.allocator.free(row_text);
                return;
            };

            if (line_end >= content.len) break;
            pos = line_end + 1;
        }

        self.rows.append(self.allocator, .{ .kind = .separator }) catch |err| {
            log.warn("failed to append separator: {}", .{err});
        };
    }
};

// === Anchor stripping helpers ===

const StripResult = struct {
    text: []const u8,
    anchor_count: usize,
};

/// Replace **[N]** markers with circled-number emoji, recording their codepoint positions.
fn stripProseAnchors(text: []const u8, out_buf: []u8, anchors: []LineAnchor) StripResult {
    var out_pos: usize = 0;
    var cp_pos: usize = 0;
    var anchor_count: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (i + 5 <= text.len and std.mem.eql(u8, text[i..][0..3], "**[")) {
            const num_start = i + 3;
            var num_end = num_start;
            while (num_end < text.len and text[num_end] >= '0' and text[num_end] <= '9') {
                num_end += 1;
            }
            if (num_end > num_start and num_end + 3 <= text.len and std.mem.eql(u8, text[num_end..][0..3], "]**")) {
                const num = std.fmt.parseInt(u8, text[num_start..num_end], 10) catch |err| {
                    log.warn("failed to parse anchor number: {}", .{err});
                    if (out_pos < out_buf.len) {
                        out_buf[out_pos] = text[i];
                        out_pos += 1;
                        if (text[i] & 0xC0 != 0x80) cp_pos += 1;
                    }
                    i += 1;
                    continue;
                };

                if (anchor_count < anchors.len and out_pos + 3 <= out_buf.len) {
                    const emoji = circledDigit(num);
                    @memcpy(out_buf[out_pos..][0..3], &emoji);
                    anchors[anchor_count] = .{
                        .number = num,
                        .char_offset = cp_pos,
                    };
                    anchor_count += 1;
                    out_pos += 3;
                    cp_pos += 1;
                }
                i = num_end + 3;
                continue;
            }
        }

        if (out_pos < out_buf.len) {
            out_buf[out_pos] = text[i];
            out_pos += 1;
            if (text[i] & 0xC0 != 0x80) cp_pos += 1;
        }
        i += 1;
    }

    return .{
        .text = out_buf[0..out_pos],
        .anchor_count = anchor_count,
    };
}

/// UTF-8 bytes for circled digits ① (U+2460) through ⑨ (U+2468).
/// Numbers outside 1-9 get ① as fallback.
fn circledDigit(n: u8) [3]u8 {
    const base: u21 = 0x2460;
    const cp: u21 = if (n >= 1 and n <= 9) base + @as(u21, n) - 1 else base;
    return .{
        @intCast(0xE0 | (cp >> 12)),
        @intCast(0x80 | ((cp >> 6) & 0x3F)),
        @intCast(0x80 | (cp & 0x3F)),
    };
}

fn bytesToCodepoints(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

const CodeRefResult = struct {
    text: []const u8,
    ref_number: ?u8,
};

/// Strip trailing <!--ref:N--> from a code line.
fn stripCodeRef(line: []const u8) CodeRefResult {
    const trimmed = std.mem.trimRight(u8, line, " \t\r");

    // Look for <!--ref:N--> at the end
    if (trimmed.len >= 13) { // minimum: <!--ref:N-->
        if (std.mem.endsWith(u8, trimmed, "-->")) {
            // Find <!--ref:
            const marker = "<!--ref:";
            const search_start = if (trimmed.len > 30) trimmed.len - 30 else 0;
            if (std.mem.lastIndexOf(u8, trimmed[search_start..], marker)) |rel_pos| {
                const abs_pos = search_start + rel_pos;
                const num_start = abs_pos + marker.len;
                const num_end = trimmed.len - 3; // before -->
                if (num_end > num_start) {
                    const num = std.fmt.parseInt(u8, trimmed[num_start..num_end], 10) catch {
                        return .{ .text = line, .ref_number = null };
                    };
                    const stripped = std.mem.trimRight(u8, trimmed[0..abs_pos], " \t");
                    return .{ .text = stripped, .ref_number = num };
                }
            }
        }
    }

    return .{ .text = line, .ref_number = null };
}

// === JSON helpers ===

fn parseMetaJson(json_str: []const u8) CodeBlockMeta {
    var meta = CodeBlockMeta{};
    meta.file = extractJsonString(json_str, "file");
    meta.commit = extractJsonString(json_str, "commit");
    meta.change_type = extractJsonString(json_str, "type");
    meta.description = extractJsonString(json_str, "description");
    return meta;
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1..][0..key.len], key);
    needle_buf[1 + key.len] = '"';
    const needle = needle_buf[0 .. key.len + 2];

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = key_pos + needle.len;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':')) : (pos += 1) {}

    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;

    const value_start = pos;
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
