const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;

const log = std.log.scoped(.global_shortcuts);

pub const GlobalShortcutsComponent = struct {
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) !UiComponent {
        const comp = try allocator.create(GlobalShortcutsComponent);
        comp.* = .{ .allocator = allocator };

        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 0,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *GlobalShortcutsComponent = @ptrCast(@alignCast(self_ptr));
        self.allocator.destroy(self);
    }

    fn handleEvent(self_ptr: *anyopaque, _: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        _ = self_ptr;

        if (event.type != c.SDL_EVENT_KEY_DOWN) return false;

        const key = event.key.key;
        const mod = event.key.mod;

        const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
        const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;

        if (key == c.SDLK_COMMA and has_gui and !has_blocking_mod) {
            actions.append(.OpenConfig) catch |err| {
                log.warn("failed to queue open config action: {}", .{err});
            };
            return true;
        }

        return false;
    }

    const vtable = UiComponent.VTable{
        .deinit = deinit,
        .handleEvent = handleEvent,
        .hitTest = null,
        .update = null,
        .render = null,
        .wantsFrame = null,
    };
};
