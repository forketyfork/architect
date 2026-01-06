const std = @import("std");
const c = @import("../c.zig");
const types = @import("types.zig");

const UiComponent = @import("component.zig").UiComponent;

pub const UiRoot = struct {
    allocator: std.mem.Allocator,
    components: std.ArrayList(UiComponent),
    actions: types.UiActionQueue,
    assets: types.UiAssets,

    pub fn init(allocator: std.mem.Allocator) UiRoot {
        return .{
            .allocator = allocator,
            .components = .{},
            .actions = types.UiActionQueue.init(allocator),
            .assets = .{},
        };
    }

    pub fn deinit(self: *UiRoot, renderer: *c.SDL_Renderer) void {
        for (self.components.items) |comp| {
            if (comp.vtable.deinit) |deinit_fn| {
                deinit_fn(comp.ptr, renderer);
            }
        }
        self.components.deinit(self.allocator);
        self.actions.deinit();
    }

    pub fn register(self: *UiRoot, component: UiComponent) !void {
        try self.components.append(self.allocator, component);
        sortComponents(&self.components);
    }

    pub fn handleEvent(self: *UiRoot, host: *const types.UiHost, event: *const c.SDL_Event) bool {
        var i: usize = self.components.items.len;
        while (i > 0) {
            i -= 1;
            const comp = self.components.items[i];
            if (comp.vtable.handleEvent) |handle_fn| {
                if (handle_fn(comp.ptr, host, event, &self.actions)) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn hitTest(self: *UiRoot, host: *const types.UiHost, x: c_int, y: c_int) bool {
        var i: usize = self.components.items.len;
        while (i > 0) {
            i -= 1;
            const comp = self.components.items[i];
            if (comp.vtable.hitTest) |hit_fn| {
                if (hit_fn(comp.ptr, host, x, y)) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn update(self: *UiRoot, host: *const types.UiHost) void {
        for (self.components.items) |comp| {
            if (comp.vtable.update) |update_fn| {
                update_fn(comp.ptr, host, &self.actions);
            }
        }
    }

    pub fn render(self: *UiRoot, host: *const types.UiHost, renderer: *c.SDL_Renderer) void {
        for (self.components.items) |comp| {
            if (comp.vtable.render) |render_fn| {
                render_fn(comp.ptr, host, renderer, &self.assets);
            }
        }
    }

    pub fn popAction(self: *UiRoot) ?types.UiAction {
        return self.actions.pop();
    }
};

fn sortComponents(list: *std.ArrayList(UiComponent)) void {
    std.sort.block(UiComponent, list.items, {}, lessThanZ);
}

fn lessThanZ(_: void, a: UiComponent, b: UiComponent) bool {
    return a.z_index < b.z_index;
}
