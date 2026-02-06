const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const dpi = @import("../scale.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const easing = @import("../../anim/easing.zig");

const log = std.log.scoped(.diff_overlay);

const HunkLineKind = enum { context, add, remove };

const HunkLine = struct {
    kind: HunkLineKind,
    text: []const u8,
    old_line: ?usize,
    new_line: ?usize,
};

const DiffHunk = struct {
    header_text: []const u8,
    old_start: usize,
    new_start: usize,
    lines: std.ArrayList(HunkLine),
};

const DiffFile = struct {
    path: []const u8,
    collapsed: bool = false,
    hunks: std.ArrayList(DiffHunk),
};

const DisplayRowKind = enum {
    file_header,
    hunk_header,
    diff_line,
    message,
};

const DisplayRow = struct {
    kind: DisplayRowKind,
    file_index: ?usize = null,
    hunk_index: ?usize = null,
    line_index: ?usize = null,
    message: ?[]u8 = null,
    text_byte_offset: usize = 0,
};

const SegmentKind = enum {
    file_path,
    hunk_header,
    line_number_old,
    line_number_new,
    marker,
    line_text,
    message,
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

const GitResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

pub const DiffOverlayComponent = struct {
    allocator: std.mem.Allocator,
    visible: bool = false,
    first_frame: FirstFrameGuard = .{},

    files: std.ArrayList(DiffFile) = .{},
    raw_output: ?[]u8 = null,
    display_rows: std.ArrayList(DisplayRow) = .{},
    cache: ?*Cache = null,
    last_repo_root: ?[]u8 = null,

    scroll_offset: f32 = 0,
    max_scroll: f32 = 0,

    close_hovered: bool = false,
    hovered_file: ?usize = null,

    wrap_cols: usize = 0,

    animation_state: AnimationState = .closed,
    animation_start_ms: i64 = 0,
    render_alpha: f32 = 1.0,

    const AnimationState = enum { closed, opening, open, closing };
    const animation_duration_ms: i64 = 250;
    const scale_from: f32 = 0.97;

    const margin: c_int = 40;
    const title_height: c_int = 50;
    const close_btn_size: c_int = 32;
    const close_btn_margin: c_int = 12;
    const line_height: c_int = 22;
    const text_padding: c_int = 12;
    const font_size: c_int = 13;
    const scroll_speed: f32 = 40.0;
    const gutter_width: c_int = 48;
    const marker_width: c_int = 20;
    const chevron_size: c_int = 12;
    const file_header_pad: c_int = 8;
    const max_output_bytes: usize = 4 * 1024 * 1024;
    const tab_display_width: usize = 4;
    const min_printable_char: u8 = 32;

    // max_chars plus room for tab-to-spaces expansion
    const max_display_buffer: usize = 520;

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

    pub const ShowResult = enum { opened, not_a_repo, clean };

    pub fn show(self: *DiffOverlayComponent, cwd: ?[]const u8, now_ms: i64) ShowResult {
        self.visible = true;
        self.scroll_offset = 0;
        self.animation_state = .opening;
        self.animation_start_ms = now_ms;
        self.first_frame.markTransition();
        return self.loadDiff(cwd);
    }

    pub fn hide(self: *DiffOverlayComponent, now_ms: i64) void {
        self.animation_state = .closing;
        self.animation_start_ms = now_ms;
        self.first_frame.markTransition();
    }

    pub fn toggle(self: *DiffOverlayComponent, cwd: ?[]const u8, now_ms: i64) ShowResult {
        switch (self.animation_state) {
            .open, .opening => {
                self.hide(now_ms);
                return .opened;
            },
            .closed => return self.show(cwd, now_ms),
            .closing => return .opened,
        }
    }

    fn cancelShow(self: *DiffOverlayComponent) void {
        self.visible = false;
        self.animation_state = .closed;
    }

    fn loadDiff(self: *DiffOverlayComponent, cwd: ?[]const u8) ShowResult {
        self.clearContent();

        const dir = cwd orelse {
            self.cancelShow();
            return .not_a_repo;
        };

        self.updateRepoRoot(dir);

        if (self.last_repo_root == null) {
            self.cancelShow();
            return .not_a_repo;
        }

        const argv_unstaged = [_][]const u8{
            "git",
            "--no-pager",
            "diff",
            "--no-ext-diff",
            "--color=never",
            "--unified=3",
        };
        const argv_staged = [_][]const u8{
            "git",
            "--no-pager",
            "diff",
            "--staged",
            "--no-ext-diff",
            "--color=never",
            "--unified=3",
        };

        var combined = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| {
            log.warn("failed to allocate diff buffer: {}", .{err});
            self.setSingleLine("Failed to allocate diff buffer.");
            return .opened;
        };
        defer combined.deinit(self.allocator);

        const unstaged = self.runGitCommand(dir, &argv_unstaged) catch |err| {
            self.handleGitError(err);
            return .opened;
        };
        defer self.freeGitResult(unstaged);
        if (self.gitExitErrorText(unstaged)) |err_text| {
            self.setSingleLine(err_text);
            return .opened;
        }

        if (unstaged.stdout.len > 0) {
            combined.appendSlice(self.allocator, unstaged.stdout) catch |err| {
                log.warn("failed to append unstaged diff: {}", .{err});
                self.setSingleLine("Failed to build git diff output.");
                return .opened;
            };
        }

        const staged = self.runGitCommand(dir, &argv_staged) catch |err| {
            if (combined.items.len == 0) {
                self.handleGitError(err);
                return .opened;
            }
            log.warn("failed to run staged git diff: {}", .{err});
            return .opened;
        };
        defer self.freeGitResult(staged);
        if (self.gitExitErrorText(staged)) |err_text| {
            if (combined.items.len == 0) {
                self.setSingleLine(err_text);
                return .opened;
            }
            log.warn("staged git diff failed: {s}", .{err_text});
        } else if (staged.stdout.len > 0) {
            if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n') {
                combined.append(self.allocator, '\n') catch |err| {
                    log.warn("failed to append diff separator: {}", .{err});
                    self.setSingleLine("Failed to build git diff output.");
                    return .opened;
                };
            }
            if (combined.items.len > 0) {
                combined.append(self.allocator, '\n') catch |err| {
                    log.warn("failed to append diff separator: {}", .{err});
                    self.setSingleLine("Failed to build git diff output.");
                    return .opened;
                };
            }
            combined.appendSlice(self.allocator, staged.stdout) catch |err| {
                log.warn("failed to append staged diff: {}", .{err});
                self.setSingleLine("Failed to build git diff output.");
                return .opened;
            };
        }

        self.appendUntrackedFiles(dir, &combined);

        if (combined.items.len == 0) {
            self.cancelShow();
            return .clean;
        }

        self.raw_output = combined.toOwnedSlice(self.allocator) catch |err| {
            log.warn("failed to store git diff output: {}", .{err});
            self.setSingleLine("Failed to build git diff output.");
            return .opened;
        };
        const output = self.raw_output orelse {
            self.setSingleLine("Failed to build git diff output.");
            return .opened;
        };
        self.parseDiffOutput(output);
        return .opened;
    }

    fn appendUntrackedFiles(self: *DiffOverlayComponent, cwd: []const u8, combined: *std.ArrayList(u8)) void {
        const repo_root = self.last_repo_root orelse cwd;

        const argv = [_][]const u8{
            "git",
            "ls-files",
            "--others",
            "--exclude-standard",
        };

        const result = self.runGitCommand(repo_root, &argv) catch |err| {
            log.warn("failed to list untracked files: {}", .{err});
            return;
        };
        defer self.freeGitResult(result);

        if (self.gitExitErrorText(result) != null) return;
        if (result.stdout.len == 0) return;

        var pos: usize = 0;
        while (pos < result.stdout.len) {
            const line_end = std.mem.indexOfScalarPos(u8, result.stdout, pos, '\n') orelse result.stdout.len;
            const rel_path = result.stdout[pos..line_end];
            pos = if (line_end < result.stdout.len) line_end + 1 else result.stdout.len;

            if (rel_path.len == 0) continue;

            self.appendSingleUntrackedFile(repo_root, rel_path, combined);

            if (combined.items.len >= max_output_bytes) break;
        }
    }

    fn appendSingleUntrackedFile(self: *DiffOverlayComponent, repo_root: []const u8, rel_path: []const u8, combined: *std.ArrayList(u8)) void {
        if (rel_path.len > 0 and rel_path[rel_path.len - 1] == '/') return;

        const abs_path = std.fs.path.join(self.allocator, &.{ repo_root, rel_path }) catch |err| {
            log.warn("failed to join path for untracked file: {}", .{err});
            return;
        };
        defer self.allocator.free(abs_path);

        const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| {
            log.warn("failed to open untracked file {s}: {}", .{ rel_path, err });
            return;
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            log.warn("failed to stat untracked file {s}: {}", .{ rel_path, err });
            return;
        };

        // Skip files that are too large or likely binary
        const max_file_bytes: usize = 256 * 1024;
        if (stat.size > max_file_bytes) {
            self.appendUntrackedHeader(rel_path, combined);
            combined.appendSlice(self.allocator, "@@ -0,0 +1 @@\n+<file too large to display>\n") catch |err| {
                log.warn("failed to append untracked placeholder: {}", .{err});
            };
            return;
        }

        const content = file.readToEndAlloc(self.allocator, max_file_bytes) catch |err| {
            log.warn("failed to read untracked file {s}: {}", .{ rel_path, err });
            return;
        };
        defer self.allocator.free(content);

        if (content.len == 0) {
            self.appendUntrackedHeader(rel_path, combined);
            combined.appendSlice(self.allocator, "@@ -0,0 +0,0 @@\n") catch |err| {
                log.warn("failed to append empty file hunk: {}", .{err});
            };
            return;
        }

        if (looksLikeBinary(content)) {
            self.appendUntrackedHeader(rel_path, combined);
            combined.appendSlice(self.allocator, "@@ -0,0 +1 @@\n+<binary file>\n") catch |err| {
                log.warn("failed to append binary placeholder: {}", .{err});
            };
            return;
        }

        // Count lines
        var line_count: usize = 0;
        for (content) |ch| {
            if (ch == '\n') line_count += 1;
        }
        if (content.len > 0 and content[content.len - 1] != '\n') line_count += 1;

        self.appendUntrackedHeader(rel_path, combined);

        // Hunk header: @@ -0,0 +1,N @@
        var hunk_buf: [64]u8 = undefined;
        const hunk_header = std.fmt.bufPrint(&hunk_buf, "@@ -0,0 +1,{d} @@\n", .{line_count}) catch return;
        combined.appendSlice(self.allocator, hunk_header) catch |err| {
            log.warn("failed to append hunk header: {}", .{err});
            return;
        };

        // Each line prefixed with '+'
        var line_pos: usize = 0;
        while (line_pos < content.len) {
            if (combined.items.len >= max_output_bytes) break;
            const eol = std.mem.indexOfScalarPos(u8, content, line_pos, '\n') orelse content.len;
            combined.append(self.allocator, '+') catch |err| {
                log.warn("failed to append line marker: {}", .{err});
                return;
            };
            combined.appendSlice(self.allocator, content[line_pos..eol]) catch |err| {
                log.warn("failed to append line content: {}", .{err});
                return;
            };
            combined.append(self.allocator, '\n') catch |err| {
                log.warn("failed to append newline: {}", .{err});
                return;
            };
            line_pos = if (eol < content.len) eol + 1 else content.len;
        }
    }

    fn appendUntrackedHeader(self: *DiffOverlayComponent, rel_path: []const u8, combined: *std.ArrayList(u8)) void {
        if (combined.items.len > 0 and combined.items[combined.items.len - 1] != '\n') {
            combined.append(self.allocator, '\n') catch return;
        }

        // diff --git a/<path> b/<path>
        combined.appendSlice(self.allocator, "diff --git a/") catch return;
        combined.appendSlice(self.allocator, rel_path) catch return;
        combined.appendSlice(self.allocator, " b/") catch return;
        combined.appendSlice(self.allocator, rel_path) catch return;
        combined.appendSlice(self.allocator, "\nnew file\n--- /dev/null\n+++ b/") catch return;
        combined.appendSlice(self.allocator, rel_path) catch return;
        combined.append(self.allocator, '\n') catch return;
    }

    fn looksLikeBinary(content: []const u8) bool {
        const check_len = @min(content.len, 8192);
        for (content[0..check_len]) |ch| {
            if (ch == 0) return true;
        }
        return false;
    }

    fn updateRepoRoot(self: *DiffOverlayComponent, cwd: []const u8) void {
        if (self.last_repo_root) |root| {
            self.allocator.free(root);
            self.last_repo_root = null;
        }

        const argv = [_][]const u8{
            "git",
            "rev-parse",
            "--show-toplevel",
        };

        const result = self.runGitCommand(cwd, &argv) catch |err| {
            log.warn("failed to run git rev-parse: {}", .{err});
            return;
        };
        defer self.freeGitResult(result);

        if (self.gitExitErrorText(result) != null) {
            return;
        }

        const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
        if (trimmed.len == 0) return;

        const repo_root = self.allocator.dupe(u8, trimmed) catch |err| {
            log.warn("failed to cache repo root: {}", .{err});
            return;
        };
        self.last_repo_root = repo_root;
    }

    fn runGitCommand(self: *DiffOverlayComponent, cwd: []const u8, argv: []const []const u8) !GitResult {
        var child = std.process.Child.init(argv, self.allocator);
        child.cwd = cwd;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            log.warn("failed to spawn git command: {}", .{err});
            return error.SpawnFailed;
        };

        var stdout = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| {
            log.warn("failed to allocate stdout buffer: {}", .{err});
            return error.OutputAllocFailed;
        };
        errdefer stdout.deinit(self.allocator);
        var stderr = std.ArrayList(u8).initCapacity(self.allocator, 256) catch |err| {
            log.warn("failed to allocate stderr buffer: {}", .{err});
            return error.OutputAllocFailed;
        };
        errdefer stderr.deinit(self.allocator);

        child.collectOutput(self.allocator, &stdout, &stderr, max_output_bytes) catch |err| {
            log.warn("failed to collect git command output: {}", .{err});
            const terminate = child.kill() catch |kill_err| switch (kill_err) {
                error.AlreadyTerminated => child.wait() catch |wait_err| {
                    log.warn("failed to wait on git command: {}", .{wait_err});
                    return error.WaitFailed;
                },
                else => {
                    log.warn("failed to terminate git command: {}", .{kill_err});
                    return error.TerminateFailed;
                },
            };
            _ = terminate;
            return switch (err) {
                error.StdoutStreamTooLong, error.StderrStreamTooLong => error.OutputTooLarge,
                else => error.ReadFailed,
            };
        };

        const term = child.wait() catch |err| {
            log.warn("failed to wait on git command: {}", .{err});
            return error.WaitFailed;
        };

        return .{
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
            .term = term,
        };
    }

    fn handleGitError(self: *DiffOverlayComponent, err: anyerror) void {
        switch (err) {
            error.OutputTooLarge => self.setSingleLine("Git diff output too large to display."),
            error.OutputAllocFailed => self.setSingleLine("Failed to allocate diff buffer."),
            else => self.setSingleLine("Failed to run git diff."),
        }
    }

    fn gitExitErrorText(_: *DiffOverlayComponent, result: GitResult) ?[]const u8 {
        return switch (result.term) {
            .Exited => |code| if (code == 0)
                null
            else if (result.stderr.len > 0)
                result.stderr
            else
                "Not a git repository.",
            else => if (result.stderr.len > 0) result.stderr else "Not a git repository.",
        };
    }

    fn freeGitResult(self: *DiffOverlayComponent, result: GitResult) void {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    // --- Parsing ---

    fn parseDiffOutput(self: *DiffOverlayComponent, output: []const u8) void {
        var current_file_idx: ?usize = null;
        var current_hunk_idx: ?usize = null;
        var old_line: usize = 0;
        var new_line: usize = 0;

        var pos: usize = 0;
        while (pos < output.len) {
            const line_end = std.mem.indexOfScalarPos(u8, output, pos, '\n') orelse output.len;
            const line_text = output[pos..line_end];

            if (std.mem.startsWith(u8, line_text, "diff --git ")) {
                const path = extractFilePath(line_text);
                var hunks = std.ArrayList(DiffHunk){};
                _ = &hunks;
                self.files.append(self.allocator, .{
                    .path = path,
                    .collapsed = false,
                    .hunks = .{},
                }) catch |err| {
                    log.warn("failed to append file: {}", .{err});
                    pos = if (line_end < output.len) line_end + 1 else output.len;
                    continue;
                };
                current_file_idx = self.files.items.len - 1;
                current_hunk_idx = null;
            } else if (std.mem.startsWith(u8, line_text, "index ") or
                std.mem.startsWith(u8, line_text, "--- ") or
                std.mem.startsWith(u8, line_text, "+++ ") or
                std.mem.startsWith(u8, line_text, "new file") or
                std.mem.startsWith(u8, line_text, "deleted file") or
                std.mem.startsWith(u8, line_text, "old mode") or
                std.mem.startsWith(u8, line_text, "new mode") or
                std.mem.startsWith(u8, line_text, "similarity") or
                std.mem.startsWith(u8, line_text, "rename") or
                std.mem.startsWith(u8, line_text, "copy"))
            {
                // Skip metadata lines
            } else if (std.mem.startsWith(u8, line_text, "@@")) {
                if (current_file_idx) |fi| {
                    const parsed = parseHunkHeader(line_text);
                    old_line = parsed.old_start;
                    new_line = parsed.new_start;
                    self.files.items[fi].hunks.append(self.allocator, .{
                        .header_text = line_text,
                        .old_start = parsed.old_start,
                        .new_start = parsed.new_start,
                        .lines = .{},
                    }) catch |err| {
                        log.warn("failed to append hunk: {}", .{err});
                        pos = if (line_end < output.len) line_end + 1 else output.len;
                        continue;
                    };
                    current_hunk_idx = self.files.items[fi].hunks.items.len - 1;
                }
            } else if (current_file_idx != null and current_hunk_idx != null) {
                const fi = current_file_idx.?;
                const hi = current_hunk_idx.?;
                var hunk = &self.files.items[fi].hunks.items[hi];

                if (line_text.len > 0 and line_text[0] == '+') {
                    hunk.lines.append(self.allocator, .{
                        .kind = .add,
                        .text = line_text[1..],
                        .old_line = null,
                        .new_line = new_line,
                    }) catch |err| {
                        log.warn("failed to append hunk line: {}", .{err});
                    };
                    new_line += 1;
                } else if (line_text.len > 0 and line_text[0] == '-') {
                    hunk.lines.append(self.allocator, .{
                        .kind = .remove,
                        .text = line_text[1..],
                        .old_line = old_line,
                        .new_line = null,
                    }) catch |err| {
                        log.warn("failed to append hunk line: {}", .{err});
                    };
                    old_line += 1;
                } else if (line_text.len > 0 and line_text[0] == '\\') {
                    // "\ No newline at end of file" - skip
                } else {
                    const text = if (line_text.len > 0 and line_text[0] == ' ') line_text[1..] else line_text;
                    hunk.lines.append(self.allocator, .{
                        .kind = .context,
                        .text = text,
                        .old_line = old_line,
                        .new_line = new_line,
                    }) catch |err| {
                        log.warn("failed to append hunk line: {}", .{err});
                    };
                    old_line += 1;
                    new_line += 1;
                }
            }

            pos = if (line_end < output.len) line_end + 1 else output.len;
        }

        self.rebuildDisplayRows();
    }

    fn extractFilePath(line: []const u8) []const u8 {
        const prefix = "diff --git ";
        if (line.len <= prefix.len) return line;
        const rest = line[prefix.len..];
        if (std.mem.indexOf(u8, rest, " b/")) |idx| {
            return rest[idx + 3 ..];
        }
        return rest;
    }

    fn parseHunkHeader(line: []const u8) struct { old_start: usize, new_start: usize } {
        var p: usize = 0;
        while (p < line.len and line[p] != '-') : (p += 1) {}
        if (p < line.len) p += 1;
        const old_start = parseNumber(line, &p);
        while (p < line.len and line[p] != '+') : (p += 1) {}
        if (p < line.len) p += 1;
        const new_start = parseNumber(line, &p);
        return .{ .old_start = old_start, .new_start = new_start };
    }

    fn parseNumber(line: []const u8, p: *usize) usize {
        var result: usize = 0;
        while (p.* < line.len and line[p.*] >= '0' and line[p.*] <= '9') {
            result = result * 10 + @as(usize, line[p.*] - '0');
            p.* += 1;
        }
        return result;
    }

    fn clearContent(self: *DiffOverlayComponent) void {
        self.destroyCache();
        self.clearDisplayRows();
        for (self.files.items) |*file| {
            for (file.hunks.items) |*hunk| {
                hunk.lines.deinit(self.allocator);
            }
            file.hunks.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
        self.files = .{};
        self.hovered_file = null;
        if (self.last_repo_root) |root| {
            self.allocator.free(root);
            self.last_repo_root = null;
        }
        if (self.raw_output) |output| {
            self.allocator.free(output);
            self.raw_output = null;
        }
        self.scroll_offset = 0;
    }

    fn clearDisplayRows(self: *DiffOverlayComponent) void {
        for (self.display_rows.items) |row| {
            if (row.message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.display_rows.clearRetainingCapacity();
    }

    fn setSingleLine(self: *DiffOverlayComponent, text: []const u8) void {
        self.clearContent();
        const msg = self.allocator.dupe(u8, text) catch |err| {
            log.warn("failed to allocate message: {}", .{err});
            return;
        };
        self.display_rows.append(self.allocator, .{
            .kind = .message,
            .message = msg,
        }) catch |err| {
            log.warn("failed to append message row: {}", .{err});
            self.allocator.free(msg);
        };
    }

    fn rebuildDisplayRows(self: *DiffOverlayComponent) void {
        self.destroyCache();
        self.clearDisplayRows();
        self.hovered_file = null;

        var file_idx: usize = 0;
        while (file_idx < self.files.items.len) : (file_idx += 1) {
            const file = &self.files.items[file_idx];
            self.display_rows.append(self.allocator, .{
                .kind = .file_header,
                .file_index = file_idx,
            }) catch |err| {
                log.warn("failed to append file row: {}", .{err});
                return;
            };
            if (file.collapsed) continue;

            var hunk_idx: usize = 0;
            while (hunk_idx < file.hunks.items.len) : (hunk_idx += 1) {
                self.display_rows.append(self.allocator, .{
                    .kind = .hunk_header,
                    .file_index = file_idx,
                    .hunk_index = hunk_idx,
                }) catch |err| {
                    log.warn("failed to append hunk row: {}", .{err});
                    return;
                };

                var line_idx: usize = 0;
                const hunk = &file.hunks.items[hunk_idx];
                while (line_idx < hunk.lines.items.len) : (line_idx += 1) {
                    const line_text = hunk.lines.items[line_idx].text;
                    self.appendWrappedDiffRows(file_idx, hunk_idx, line_idx, line_text);
                }
            }
        }
    }

    fn appendWrappedDiffRows(self: *DiffOverlayComponent, file_idx: usize, hunk_idx: usize, line_idx: usize, text: []const u8) void {
        if (self.wrap_cols == 0 or textDisplayCols(text) <= self.wrap_cols) {
            self.display_rows.append(self.allocator, .{
                .kind = .diff_line,
                .file_index = file_idx,
                .hunk_index = hunk_idx,
                .line_index = line_idx,
            }) catch |err| {
                log.warn("failed to append diff row: {}", .{err});
            };
            return;
        }

        var byte_off: usize = 0;
        while (byte_off < text.len) {
            self.display_rows.append(self.allocator, .{
                .kind = .diff_line,
                .file_index = file_idx,
                .hunk_index = hunk_idx,
                .line_index = line_idx,
                .text_byte_offset = byte_off,
            }) catch |err| {
                log.warn("failed to append wrapped diff row: {}", .{err});
                return;
            };
            byte_off = byteOffsetAtDisplayCol(text, byte_off, self.wrap_cols);
        }
    }

    fn textDisplayCols(text: []const u8) usize {
        var cols: usize = 0;
        for (text) |ch| {
            if (ch == '\t') cols += tab_display_width else if (ch >= min_printable_char) cols += 1;
        }
        return cols;
    }

    fn byteOffsetAtDisplayCol(text: []const u8, start: usize, max_cols: usize) usize {
        var cols: usize = 0;
        var i: usize = start;
        while (i < text.len) {
            const byte_len = std.unicode.utf8ByteSequenceLength(text[i]) catch |err| blk: {
                log.warn("invalid UTF-8 lead byte at offset {}: {}", .{ i, err });
                break :blk 1;
            };
            const advance: usize = if (text[i] == '\t') tab_display_width else if (text[i] >= min_printable_char) 1 else 0;
            if (cols + advance > max_cols and cols > 0) break;
            cols += advance;
            i += @min(byte_len, text.len - i);
        }
        return i;
    }

    // --- Animation helpers ---

    fn animationProgress(self: *const DiffOverlayComponent, now_ms: i64) f32 {
        const elapsed = now_ms - self.animation_start_ms;
        const clamped = @max(@as(i64, 0), elapsed);
        const t = @min(1.0, @as(f32, @floatFromInt(clamped)) / @as(f32, @floatFromInt(animation_duration_ms)));
        return easing.easeInOutCubic(t);
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

    // --- Layout helpers ---

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

    fn lineHeight(self: *DiffOverlayComponent, host: *const types.UiHost) c_int {
        if (self.cache) |cache| {
            return cache.line_height;
        }
        return dpi.scale(line_height, host.ui_scale);
    }

    // --- Event handling ---

    fn handleEventFn(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));

        if (!self.visible or self.animation_state == .closing) {
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT | c.SDL_KMOD_SHIFT)) != 0;

                if (has_gui and !has_blocking and key == c.SDLK_D) {
                    actions.append(.ToggleDiffOverlay) catch |err| {
                        log.warn("failed to queue ToggleDiffOverlay action: {}", .{err});
                    };
                    return true;
                }
            }
            return false;
        }

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

                if (key == c.SDLK_UP) {
                    self.scroll_offset = @max(0, self.scroll_offset - scroll_speed);
                    return true;
                }
                if (key == c.SDLK_DOWN) {
                    self.scroll_offset = @min(self.max_scroll, self.scroll_offset + scroll_speed);
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
                    actions.append(.ToggleDiffOverlay) catch |err| {
                        log.warn("failed to queue ToggleDiffOverlay action: {}", .{err});
                    };
                    return true;
                }

                const rect = overlayRect(host);
                const scaled_title_h = dpi.scale(title_height, host.ui_scale);
                const scaled_line_h = self.lineHeight(host);
                const content_top = rect.y + scaled_title_h;
                const scroll_int: c_int = @intFromFloat(self.scroll_offset);

                if (mouse_y >= content_top and scaled_line_h > 0) {
                    const relative_y = mouse_y - content_top + scroll_int;
                    if (relative_y >= 0) {
                        const click_row: usize = @intCast(@divFloor(relative_y, scaled_line_h));
                        if (click_row < self.display_rows.items.len) {
                            const row = self.display_rows.items[click_row];
                            if (row.kind == .file_header) {
                                if (row.file_index) |file_idx| {
                                    self.files.items[file_idx].collapsed = !self.files.items[file_idx].collapsed;
                                    self.rebuildDisplayRows();
                                }
                            }
                        }
                    }
                }

                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);
                const close_rect = closeButtonRect(host);
                self.close_hovered = geom.containsPoint(close_rect, mouse_x, mouse_y);

                const rect = overlayRect(host);
                const scaled_title_h = dpi.scale(title_height, host.ui_scale);
                const scaled_line_h = self.lineHeight(host);
                const content_top = rect.y + scaled_title_h;
                const scroll_int: c_int = @intFromFloat(self.scroll_offset);

                self.hovered_file = null;
                if (mouse_y >= content_top and scaled_line_h > 0) {
                    const relative_y = mouse_y - content_top + scroll_int;
                    if (relative_y >= 0) {
                        const hover_row: usize = @intCast(@divFloor(relative_y, scaled_line_h));
                        if (hover_row < self.display_rows.items.len) {
                            const row = self.display_rows.items[hover_row];
                            if (row.kind == .file_header) {
                                self.hovered_file = row.file_index;
                            }
                        }
                    }
                }

                return true;
            },
            c.SDL_EVENT_KEY_UP, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING => return true,
            else => return false,
        }
    }

    fn updateFn(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        const elapsed = host.now_ms - self.animation_start_ms;
        switch (self.animation_state) {
            .opening => {
                if (elapsed >= animation_duration_ms) {
                    self.animation_state = .open;
                }
            },
            .closing => {
                if (elapsed >= animation_duration_ms) {
                    self.animation_state = .closed;
                    self.visible = false;
                    self.clearContent();
                }
            },
            .open, .closed => {},
        }
    }

    fn hitTestFn(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible or self.animation_state == .closing) return false;
        const rect = overlayRect(host);
        return geom.containsPoint(rect, x, y);
    }

    fn wantsFrameFn(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        return self.first_frame.wantsFrame() or self.visible or self.animation_state == .closing;
    }

    // --- Rendering ---

    fn renderFn(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *DiffOverlayComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.visible) return;

        // Compute animation progress
        const raw_progress = self.animationProgress(host.now_ms);
        const progress: f32 = switch (self.animation_state) {
            .opening => raw_progress,
            .closing => 1.0 - raw_progress,
            .open => 1.0,
            .closed => 0.0,
        };
        self.render_alpha = progress;

        if (progress <= 0.001) return;

        const cache = self.ensureCache(renderer, host, assets) orelse return;

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

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const bg = host.theme.background;
        const bg_alpha: u8 = @intFromFloat(240.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, bg_alpha);
        primitives.fillRoundedRect(renderer, rect, radius);

        const accent = host.theme.accent;
        const border_alpha: u8 = @intFromFloat(180.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, border_alpha);
        primitives.drawRoundedBorder(renderer, rect, radius);

        self.renderTitle(renderer, rect, scaled_title_h, scaled_padding, cache);

        const line_alpha: u8 = @intFromFloat(80.0 * progress);
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, line_alpha);
        _ = c.SDL_RenderLine(
            renderer,
            @floatFromInt(rect.x + scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
            @floatFromInt(rect.x + rect.w - scaled_padding),
            @floatFromInt(rect.y + scaled_title_h),
        );

        self.renderCloseButton(host, renderer, assets, rect, scaled_font_size);

        const content_clip = c.SDL_Rect{
            .x = rect.x,
            .y = rect.y + scaled_title_h,
            .w = rect.w,
            .h = rect.h - scaled_title_h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &content_clip);

        self.renderDiffContent(host, renderer, rect, scaled_title_h, scaled_padding, cache);

        _ = c.SDL_SetRenderClipRect(renderer, null);

        self.renderScrollbar(host, renderer, rect, scaled_title_h, content_height, viewport_height);

        self.first_frame.markDrawn();
    }

    fn renderTitle(self: *DiffOverlayComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, title_h: c_int, padding: c_int, cache: *Cache) void {
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

    fn renderCloseButton(self: *DiffOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets, overlay_rect: geom.Rect, _: c_int) void {
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

    fn updateWrapCols(self: *DiffOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, mono_font: *c.TTF_Font) void {
        const char_w = measureCharWidth(renderer, mono_font) orelse return;
        if (char_w <= 0) return;

        const rect = overlayRect(host);
        const scaled_gutter_w = dpi.scale(gutter_width, host.ui_scale);
        const scaled_marker_w = dpi.scale(marker_width, host.ui_scale);
        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const scrollbar_w = dpi.scale(10, host.ui_scale);
        const text_area_w = rect.w - scaled_gutter_w * 2 - scaled_marker_w - scaled_padding - scrollbar_w;
        if (text_area_w <= 0) return;

        const new_wrap: usize = @intCast(@divFloor(text_area_w, char_w));
        if (new_wrap != self.wrap_cols and new_wrap > 0) {
            self.wrap_cols = new_wrap;
            self.rebuildDisplayRows();
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

    fn ensureCache(self: *DiffOverlayComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets) ?*Cache {
        const font_cache = assets.font_cache orelse return null;
        const generation = font_cache.generation;

        if (self.cache) |existing| {
            if (existing.ui_scale == host.ui_scale and existing.font_generation == generation) {
                return existing;
            }
        }

        self.destroyCache();

        const scaled_font_size = dpi.scale(font_size, host.ui_scale);
        const title_font_size = scaled_font_size + dpi.scale(4, host.ui_scale);
        const line_fonts = font_cache.get(scaled_font_size) catch return null;
        const title_fonts = font_cache.get(title_font_size) catch return null;

        const mono_font = line_fonts.regular;
        const bold_font = line_fonts.bold orelse line_fonts.regular;

        self.updateWrapCols(renderer, host, mono_font);

        const title_text = self.buildTitleText() catch return null;
        defer self.allocator.free(title_text);
        const title_tex = self.makeTextTexture(
            renderer,
            title_fonts.bold orelse title_fonts.regular,
            title_text,
            host.theme.foreground,
        ) catch return null;

        const line_height_scaled = dpi.scale(line_height, host.ui_scale);
        const line_textures = self.allocator.alloc(LineTexture, self.display_rows.items.len) catch {
            c.SDL_DestroyTexture(title_tex.tex);
            return null;
        };

        var idx: usize = 0;
        while (idx < self.display_rows.items.len) : (idx += 1) {
            line_textures[idx] = self.buildLineTexture(renderer, host, mono_font, bold_font, self.display_rows.items[idx]) catch |err| blk: {
                log.warn("failed to build diff line texture: {}", .{err});
                break :blk LineTexture{ .segments = &.{} };
            };
        }

        const cache = self.allocator.create(Cache) catch {
            self.destroyLineTextures(line_textures);
            c.SDL_DestroyTexture(title_tex.tex);
            self.allocator.free(line_textures);
            return null;
        };
        cache.* = .{
            .ui_scale = host.ui_scale,
            .font_generation = generation,
            .line_height = line_height_scaled,
            .title = title_tex,
            .lines = line_textures,
        };
        self.cache = cache;
        return cache;
    }

    fn buildTitleText(self: *DiffOverlayComponent) ![]const u8 {
        const prefix = "Git Diff";
        const repo_root = self.last_repo_root orelse return self.allocator.dupe(u8, prefix);
        const base = std.fs.path.basename(repo_root);

        const max_len: usize = 120;
        if (prefix.len + 3 + base.len <= max_len) {
            return std.fmt.allocPrint(self.allocator, "{s} - {s}", .{ prefix, base });
        }

        if (max_len <= prefix.len + 3) {
            return self.allocator.dupe(u8, prefix);
        }

        const tail_len = max_len - prefix.len - 3;
        const tail = base[base.len - tail_len ..];
        return std.fmt.allocPrint(self.allocator, "{s} - ...{s}", .{ prefix, tail });
    }

    fn makeTextTexture(
        self: *DiffOverlayComponent,
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

    fn buildLineTexture(
        self: *DiffOverlayComponent,
        renderer: *c.SDL_Renderer,
        host: *const types.UiHost,
        mono_font: *c.TTF_Font,
        bold_font: *c.TTF_Font,
        row: DisplayRow,
    ) !LineTexture {
        var segments = try std.ArrayList(SegmentTexture).initCapacity(self.allocator, 4);
        errdefer {
            for (segments.items) |segment| {
                c.SDL_DestroyTexture(segment.tex);
            }
            segments.deinit(self.allocator);
        }

        const scaled_gutter_w = dpi.scale(gutter_width, host.ui_scale);
        const scaled_marker_w = dpi.scale(marker_width, host.ui_scale);
        const scaled_chevron_sz = dpi.scale(chevron_size, host.ui_scale);
        const scaled_fh_pad = dpi.scale(file_header_pad, host.ui_scale);
        const scaled_padding = dpi.scale(text_padding, host.ui_scale);
        const gutter_total_w = scaled_gutter_w * 2;
        const text_start_x = gutter_total_w + scaled_marker_w;

        const fg = host.theme.foreground;
        const dim_color = c.SDL_Color{
            .r = @intCast(@as(u16, fg.r) / 2),
            .g = @intCast(@as(u16, fg.g) / 2),
            .b = @intCast(@as(u16, fg.b) / 2),
            .a = 200,
        };

        switch (row.kind) {
            .file_header => {
                const file_idx = row.file_index orelse return LineTexture{ .segments = &.{} };
                const file = &self.files.items[file_idx];
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(file.path, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                const path_x = scaled_fh_pad + scaled_chevron_sz + dpi.scale(6, host.ui_scale);
                try self.appendSegmentTexture(&segments, renderer, bold_font, text, host.theme.accent, .file_path, path_x);
            },
            .hunk_header => {
                const file_idx = row.file_index orelse return LineTexture{ .segments = &.{} };
                const hunk_idx = row.hunk_index orelse return LineTexture{ .segments = &.{} };
                const hunk = &self.files.items[file_idx].hunks.items[hunk_idx];
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(hunk.header_text, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                const x_offset = gutter_total_w + scaled_padding;
                try self.appendSegmentTexture(&segments, renderer, mono_font, text, host.theme.palette[5], .hunk_header, x_offset);
            },
            .diff_line => {
                const file_idx = row.file_index orelse return LineTexture{ .segments = &.{} };
                const hunk_idx = row.hunk_index orelse return LineTexture{ .segments = &.{} };
                const line_idx = row.line_index orelse return LineTexture{ .segments = &.{} };
                const line = &self.files.items[file_idx].hunks.items[hunk_idx].lines.items[line_idx];
                const is_continuation = row.text_byte_offset > 0;

                if (!is_continuation) {
                    if (line.old_line) |num| {
                        var num_buf: [12]u8 = undefined;
                        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch "";
                        if (num_str.len > 0) {
                            const tex = try self.makeTextTexture(renderer, mono_font, num_str, dim_color);
                            errdefer c.SDL_DestroyTexture(tex.tex);
                            const right_pad: f32 = 6.0;
                            const text_x = @as(f32, @floatFromInt(scaled_gutter_w)) - @as(f32, @floatFromInt(tex.w)) - right_pad;
                            try segments.append(self.allocator, .{
                                .tex = tex.tex,
                                .kind = .line_number_old,
                                .x_offset = @intFromFloat(text_x),
                                .w = tex.w,
                                .h = tex.h,
                            });
                        }
                    }

                    if (line.new_line) |num| {
                        var num_buf: [12]u8 = undefined;
                        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch "";
                        if (num_str.len > 0) {
                            const tex = try self.makeTextTexture(renderer, mono_font, num_str, dim_color);
                            errdefer c.SDL_DestroyTexture(tex.tex);
                            const right_pad: f32 = 6.0;
                            const gutter_x: c_int = scaled_gutter_w;
                            const text_x = @as(f32, @floatFromInt(gutter_x + scaled_gutter_w)) - @as(f32, @floatFromInt(tex.w)) - right_pad;
                            try segments.append(self.allocator, .{
                                .tex = tex.tex,
                                .kind = .line_number_new,
                                .x_offset = @intFromFloat(text_x),
                                .w = tex.w,
                                .h = tex.h,
                            });
                        }
                    }

                    const marker_str: []const u8 = switch (line.kind) {
                        .add => "+",
                        .remove => "-",
                        .context => "",
                    };
                    if (marker_str.len > 0) {
                        const marker_color: c.SDL_Color = switch (line.kind) {
                            .add => host.theme.palette[2],
                            .remove => host.theme.palette[1],
                            .context => fg,
                        };
                        try self.appendSegmentTexture(&segments, renderer, mono_font, marker_str, marker_color, .marker, gutter_total_w);
                    }
                }

                const slice_start = @min(row.text_byte_offset, line.text.len);
                const slice_end = if (self.wrap_cols > 0)
                    @min(byteOffsetAtDisplayCol(line.text, slice_start, self.wrap_cols), line.text.len)
                else
                    line.text.len;
                const text_slice = line.text[slice_start..slice_end];

                if (text_slice.len > 0) {
                    var text_buf: [max_display_buffer]u8 = undefined;
                    const text = sanitizeText(text_slice, &text_buf);
                    if (text.len > 0) {
                        const text_color: c.SDL_Color = switch (line.kind) {
                            .add => host.theme.palette[2],
                            .remove => host.theme.palette[1],
                            .context => fg,
                        };
                        try self.appendSegmentTexture(&segments, renderer, mono_font, text, text_color, .line_text, text_start_x);
                    }
                }
            },
            .message => {
                const msg = row.message orelse return LineTexture{ .segments = &.{} };
                var buf: [max_display_buffer]u8 = undefined;
                const text = sanitizeText(msg, &buf);
                if (text.len == 0) return LineTexture{ .segments = &.{} };
                try self.appendSegmentTexture(&segments, renderer, bold_font, text, host.theme.foreground, .message, scaled_padding);
            },
        }

        return LineTexture{ .segments = try segments.toOwnedSlice(self.allocator) };
    }

    fn appendSegmentTexture(
        self: *DiffOverlayComponent,
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

    fn destroyCache(self: *DiffOverlayComponent) void {
        const cache = self.cache orelse return;
        c.SDL_DestroyTexture(cache.title.tex);
        self.destroyLineTextures(cache.lines);
        self.allocator.free(cache.lines);
        self.allocator.destroy(cache);
        self.cache = null;
    }

    fn destroyLineTextures(self: *DiffOverlayComponent, lines: []LineTexture) void {
        for (lines) |line| {
            for (line.segments) |segment| {
                c.SDL_DestroyTexture(segment.tex);
            }
            if (line.segments.len > 0) {
                self.allocator.free(line.segments);
            }
        }
    }

    fn renderDiffContent(self: *DiffOverlayComponent, host: *const types.UiHost, renderer: *c.SDL_Renderer, rect: geom.Rect, title_h: c_int, padding: c_int, cache: *Cache) void {
        const alpha = self.render_alpha;
        const scroll_int: c_int = @intFromFloat(self.scroll_offset);
        const content_top = rect.y + title_h;
        const content_h = rect.h - title_h;

        const row_height = cache.line_height;
        if (row_height <= 0 or content_h <= 0) return;

        const first_visible: usize = @intCast(@divFloor(scroll_int, row_height));
        const visible_count: usize = @intCast(@divFloor(content_h, row_height) + 2);

        const scaled_gutter_w = dpi.scale(gutter_width, host.ui_scale);
        const scaled_chevron_sz = dpi.scale(chevron_size, host.ui_scale);
        const scaled_fh_pad = dpi.scale(file_header_pad, host.ui_scale);
        const gutter_total_w = scaled_gutter_w * 2;

        const fg = host.theme.foreground;
        const accent = host.theme.accent;

        const end_row = @min(self.display_rows.items.len, first_visible + visible_count);
        var row_index: usize = first_visible;
        while (row_index < end_row) : (row_index += 1) {
            const row = self.display_rows.items[row_index];
            const y_pos = content_top + @as(c_int, @intCast(row_index)) * row_height - scroll_int;

            switch (row.kind) {
                .file_header => {
                    if (row.file_index) |file_idx| {
                        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                        if (self.hovered_file) |hf| {
                            if (hf == file_idx) {
                                const sel = host.theme.selection;
                                _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, @intFromFloat(40.0 * alpha));
                                _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                    .x = @floatFromInt(rect.x + 1),
                                    .y = @floatFromInt(y_pos),
                                    .w = @floatFromInt(rect.w - 2),
                                    .h = @floatFromInt(row_height),
                                });
                            }
                        }

                        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, @intFromFloat(20.0 * alpha));
                        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                            .x = @floatFromInt(rect.x + 1),
                            .y = @floatFromInt(y_pos),
                            .w = @floatFromInt(rect.w - 2),
                            .h = @floatFromInt(row_height),
                        });

                        const file = &self.files.items[file_idx];
                        renderChevron(renderer, host, rect.x + scaled_fh_pad, y_pos, scaled_chevron_sz, row_height, file.collapsed, alpha);
                    }
                },
                .message => {
                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, @intFromFloat(15.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(row_height),
                    });
                },
                .hunk_header => {
                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, @intFromFloat(15.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(rect.w - 2),
                        .h = @floatFromInt(row_height),
                    });

                    _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, @intFromFloat(10.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(gutter_total_w),
                        .h = @floatFromInt(line_height),
                    });
                },
                .diff_line => {
                    const file_idx = row.file_index orelse continue;
                    const hunk_idx = row.hunk_index orelse continue;
                    const line_idx = row.line_index orelse continue;
                    const line = &self.files.items[file_idx].hunks.items[hunk_idx].lines.items[line_idx];

                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    switch (line.kind) {
                        .add => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 0, 80, 0, @intFromFloat(60.0 * alpha));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(rect.w - 2),
                                .h = @floatFromInt(row_height),
                            });
                        },
                        .remove => {
                            _ = c.SDL_SetRenderDrawColor(renderer, 80, 0, 0, @intFromFloat(60.0 * alpha));
                            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                                .x = @floatFromInt(rect.x + 1),
                                .y = @floatFromInt(y_pos),
                                .w = @floatFromInt(rect.w - 2),
                                .h = @floatFromInt(row_height),
                            });
                        },
                        .context => {},
                    }

                    _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, @intFromFloat(10.0 * alpha));
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                        .x = @floatFromInt(rect.x + 1),
                        .y = @floatFromInt(y_pos),
                        .w = @floatFromInt(gutter_total_w),
                        .h = @floatFromInt(row_height),
                    });
                },
            }

            if (row_index >= cache.lines.len) continue;
            const line_tex = cache.lines[row_index];
            for (line_tex.segments) |segment| {
                const tex_alpha: u8 = @intFromFloat(255.0 * alpha);
                _ = c.SDL_SetTextureAlphaMod(segment.tex, tex_alpha);

                const dest_x: c_int = rect.x + segment.x_offset;
                var dest_y: c_int = y_pos;
                if (segment.kind == .line_number_old or segment.kind == .line_number_new) {
                    dest_y = y_pos + @divFloor(row_height - segment.h, 2);
                }

                var render_w: c_int = segment.w;
                const render_h: c_int = segment.h;
                var clip_src: c.SDL_FRect = undefined;
                var src_ptr: ?*const c.SDL_FRect = null;

                switch (segment.kind) {
                    .file_path, .hunk_header, .line_text, .message => {
                        const used = dest_x - rect.x;
                        const max_width = rect.w - used - padding;
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
                    },
                    else => {},
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

    fn renderChevron(renderer: *c.SDL_Renderer, host: *const types.UiHost, x: c_int, y: c_int, size: c_int, row_h: c_int, collapsed: bool, alpha: f32) void {
        const half: f32 = @floatFromInt(@divFloor(size, 2));
        const cx: f32 = @as(f32, @floatFromInt(x)) + half;
        const cy: f32 = @as(f32, @floatFromInt(y)) + @as(f32, @floatFromInt(row_h)) / 2.0;

        const fg = host.theme.foreground;
        const fcolor = c.SDL_FColor{
            .r = @as(f32, @floatFromInt(fg.r)) / 255.0,
            .g = @as(f32, @floatFromInt(fg.g)) / 255.0,
            .b = @as(f32, @floatFromInt(fg.b)) / 255.0,
            .a = 0.7 * alpha,
        };

        const verts: [3]c.SDL_Vertex = if (collapsed) .{
            .{ .position = .{ .x = cx - half * 0.3, .y = cy - half * 0.5 }, .color = fcolor },
            .{ .position = .{ .x = cx - half * 0.3, .y = cy + half * 0.5 }, .color = fcolor },
            .{ .position = .{ .x = cx + half * 0.4, .y = cy }, .color = fcolor },
        } else .{
            .{ .position = .{ .x = cx - half * 0.5, .y = cy - half * 0.3 }, .color = fcolor },
            .{ .position = .{ .x = cx + half * 0.5, .y = cy - half * 0.3 }, .color = fcolor },
            .{ .position = .{ .x = cx, .y = cy + half * 0.4 }, .color = fcolor },
        };

        const indices = [_]c_int{ 0, 1, 2 };
        _ = c.SDL_RenderGeometry(renderer, null, &verts, 3, &indices, 3);
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

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const alpha = self.render_alpha;
        _ = c.SDL_SetRenderDrawColor(renderer, 128, 128, 128, @intFromFloat(30.0 * alpha));
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + rect.w - scrollbar_width - scrollbar_margin),
            .y = @floatFromInt(rect.y + title_h + scrollbar_margin),
            .w = @floatFromInt(scrollbar_width),
            .h = @floatFromInt(track_height),
        });

        const accent_col = host.theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, accent_col.r, accent_col.g, accent_col.b, @intFromFloat(120.0 * alpha));
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
        self.display_rows.deinit(self.allocator);
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
