const c = @import("../c.zig");
const types = @import("types.zig");

pub const UiComponent = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    z_index: i32 = 0,

    pub const VTable = struct {
        handleEvent: ?*const fn (ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, out: *types.UiActionQueue) bool = null,
        update: ?*const fn (ptr: *anyopaque, host: *const types.UiHost, out: *types.UiActionQueue) void = null,
        render: ?*const fn (ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void = null,
        hitTest: ?*const fn (ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool = null,
        deinit: ?*const fn (ptr: *anyopaque, renderer: *c.SDL_Renderer) void = null,
    };
};
