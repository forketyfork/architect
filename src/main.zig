const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("app/runtime.zig");
const logging = @import("logging.zig");
const cli_args = @import("cli_args.zig");
const env = @import("env.zig");

pub const std_options: std.Options = .{
    // Keep compile-time logging permissive; runtime filtering is handled by
    // logging.zig with the user-configured minimum level.
    .log_level = .debug,
    .logFn = logging.logFn,
};

pub fn main(init: std.process.Init) !void {
    env.init(init.minimal.environ);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    while (args.next()) |arg| {
        try argv.append(init.gpa, arg);
    }

    const parsed = cli_args.parse(argv.items[1..]) catch |err| {
        std.debug.print("architect: {s}\n{s}", .{ @errorName(err), cli_args.usage_text });
        std.process.exit(1);
    };

    try runtime.run(init.gpa, init.io, parsed.log_dir_override);
}

// Zig only collects tests from files reachable through this block, so every
// file that declares tests must be referenced here or its tests silently
// never run. A file can also be reached transitively, but that depends on
// which decls Sema happens to analyze, so the rule is: list every file that
// declares tests, explicitly. `scripts/check-test-registry.sh` enforces it.
// mcp/main.zig and app/control.zig are covered by the separate mcp test
// binary in build.zig.
test {
    _ = @import("app/app_state.zig");
    _ = @import("app/frame_schedule.zig");
    _ = @import("app/grid_layout.zig");
    _ = @import("app/layout.zig");
    _ = @import("app/runtime.zig");
    _ = @import("app/terminal_actions.zig");
    _ = @import("app/terminal_history.zig");
    _ = @import("cli_args.zig");
    _ = @import("clock.zig");
    _ = @import("colors.zig");
    _ = @import("config.zig");
    _ = @import("env.zig");
    _ = @import("font.zig");
    _ = @import("gfx/shimmer.zig");
    _ = @import("input/mapper.zig");
    _ = @import("logging.zig");
    _ = @import("metrics.zig");
    _ = @import("pty.zig");
    _ = @import("platform/sdl.zig");
    _ = @import("os/open.zig");
    _ = @import("proc.zig");
    _ = @import("render/renderer.zig");
    _ = @import("session/notify.zig");
    _ = @import("session/pty_reader.zig");
    _ = @import("session/state.zig");
    _ = @import("shell.zig");
    _ = @import("ui/components/cwd_bar.zig");
    _ = @import("ui/components/diff_comment_layout.zig");
    _ = @import("ui/components/diff_overlay.zig");
    _ = @import("ui/components/dropdown_menu.zig");
    _ = @import("ui/components/expanding_overlay.zig");
    _ = @import("ui/components/markdown_parser.zig");
    _ = @import("ui/components/markdown_renderer.zig");
    _ = @import("ui/components/metrics_overlay.zig");
    _ = @import("ui/components/pill_group.zig");
    _ = @import("ui/components/quit_blocking_overlay.zig");
    _ = @import("ui/components/recent_folders_overlay.zig");
    _ = @import("ui/components/pr_dropdown.zig");
    _ = @import("ui/components/pr_dropdown_fetch.zig");
    _ = @import("ui/components/pr_dropdown_model.zig");
    _ = @import("ui/components/pr_dropdown_repo.zig");
    _ = @import("ui/components/pr_dropdown_view.zig");
    _ = @import("ui/components/scrollbar.zig");
    _ = @import("ui/components/search_utils.zig");
    _ = @import("ui/components/selection_agent_overlay.zig");
    _ = @import("ui/components/session_interaction.zig");
    _ = @import("ui/components/worktree_overlay.zig");
    _ = @import("ui/first_frame_guard.zig");
    _ = @import("ui/text_edit.zig");
    _ = @import("ui/text_render.zig");
    _ = @import("url_matcher.zig");
    _ = @import("vt_stream.zig");
    _ = @import("wake_pipe.zig");

    // cwd.zig guards itself with a top-level @compileError on non-macOS
    // platforms, so it can only be referenced where it can compile.
    if (builtin.os.tag == .macos) {
        _ = @import("cwd.zig");
    }
}
