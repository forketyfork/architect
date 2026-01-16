const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const font_cache = @import("../../font_cache.zig");

pub const RestartButtonsComponent = struct {
    allocator: std.mem.Allocator,
    font_generation: u64 = 0,
    texture: ?*c.SDL_Texture = null,
    tex_w: c_int = 0,
    tex_h: c_int = 0,

    const RESTART_BUTTON_FONT_SIZE: c_int = 20;
    const RESTART_BUTTON_HEIGHT: c_int = 40;
    const RESTART_BUTTON_PADDING: c_int = 12;
    const RESTART_BUTTON_MARGIN: c_int = 8;
    const RESTART_BUTTON_RADIUS: c_int = 8;

    pub fn init(allocator: std.mem.Allocator) !*RestartButtonsComponent {
        const self = try allocator.create(RestartButtonsComponent);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn asComponent(self: *RestartButtonsComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 100,
        };
    }

    pub fn destroy(self: *RestartButtonsComponent, renderer: *c.SDL_Renderer) void {
        if (self.texture) |tex| {
            c.SDL_DestroyTexture(tex);
            self.texture = null;
        }
        self.allocator.destroy(self);
        _ = renderer;
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *RestartButtonsComponent = @ptrCast(@alignCast(self_ptr));
        if (host.view_mode != .Grid) return false;
        if (event.type != c.SDL_EVENT_MOUSE_BUTTON_DOWN) return false;

        const mouse_x: c_int = @intFromFloat(event.button.x);
        const mouse_y: c_int = @intFromFloat(event.button.y);

        const grid_col = @min(@as(usize, @intCast(@divFloor(mouse_x, host.cell_w))), host.grid_cols - 1);
        const grid_row = @min(@as(usize, @intCast(@divFloor(mouse_y, host.cell_h))), host.grid_rows - 1);
        const clicked_session: usize = grid_row * @as(usize, host.grid_cols) + grid_col;
        if (clicked_session >= host.sessions.len) return false;

        const session_info = host.sessions[clicked_session];
        if (!(session_info.dead and session_info.spawned)) return false;

        const cell_rect = geom.Rect{
            .x = @as(c_int, @intCast(grid_col)) * host.cell_w,
            .y = @as(c_int, @intCast(grid_row)) * host.cell_h,
            .w = host.cell_w,
            .h = host.cell_h,
        };
        const button_rect = self.restartButtonRect(cell_rect);
        const inside = geom.containsPoint(button_rect, mouse_x, mouse_y);
        if (!inside) return false;

        actions.append(.{ .RestartSession = clicked_session }) catch {};
        return true;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *RestartButtonsComponent = @ptrCast(@alignCast(self_ptr));
        if (host.view_mode != .Grid) return false;

        const grid_col = @min(@as(usize, @intCast(@divFloor(x, host.cell_w))), host.grid_cols - 1);
        const grid_row = @min(@as(usize, @intCast(@divFloor(y, host.cell_h))), host.grid_rows - 1);
        const session_idx: usize = grid_row * @as(usize, host.grid_cols) + grid_col;
        if (session_idx >= host.sessions.len) return false;

        const session_info = host.sessions[session_idx];
        if (!(session_info.dead and session_info.spawned)) return false;

        const cell_rect = geom.Rect{
            .x = @as(c_int, @intCast(grid_col)) * host.cell_w,
            .y = @as(c_int, @intCast(grid_row)) * host.cell_h,
            .w = host.cell_w,
            .h = host.cell_h,
        };
        const button_rect = self.restartButtonRect(cell_rect);
        return geom.containsPoint(button_rect, x, y);
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *RestartButtonsComponent = @ptrCast(@alignCast(self_ptr));
        if (host.view_mode != .Grid) return;

        const cache = assets.font_cache orelse return;
        if (self.font_generation != cache.generation) {
            self.font_generation = cache.generation;
            if (self.texture) |tex| {
                c.SDL_DestroyTexture(tex);
                self.texture = null;
                self.tex_w = 0;
                self.tex_h = 0;
            }
        }

        for (host.sessions, 0..) |info, i| {
            if (!(info.dead and info.spawned)) continue;
            const grid_row: c_int = @intCast(i / host.grid_cols);
            const grid_col: c_int = @intCast(i % host.grid_cols);
            const cell_rect = geom.Rect{
                .x = grid_col * host.cell_w,
                .y = grid_row * host.cell_h,
                .w = host.cell_w,
                .h = host.cell_h,
            };
            self.renderButton(renderer, cell_rect, host.theme, cache);
        }
    }

    fn renderButton(self: *RestartButtonsComponent, renderer: *c.SDL_Renderer, rect: geom.Rect, theme: *const @import("../../colors.zig").Theme, cache: *font_cache.FontCache) void {
        self.ensureTexture(renderer, theme, cache) catch return;
        const text_width = self.tex_w;
        const text_height = self.tex_h;
        const button_w = text_width + RESTART_BUTTON_PADDING * 2;
        const button_h = RESTART_BUTTON_HEIGHT;
        const button_x = rect.x + rect.w - button_w - RESTART_BUTTON_MARGIN;
        const button_y = rect.y + rect.h - button_h - RESTART_BUTTON_MARGIN;

        const button_rect = geom.Rect{
            .x = button_x,
            .y = button_y,
            .w = button_w,
            .h = button_h,
        };

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const sel = theme.selection;
        _ = c.SDL_SetRenderDrawColor(renderer, sel.r, sel.g, sel.b, 220);
        const bg_rect = c.SDL_FRect{
            .x = @floatFromInt(button_x),
            .y = @floatFromInt(button_y),
            .w = @floatFromInt(button_w),
            .h = @floatFromInt(button_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        const acc = theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, acc.r, acc.g, acc.b, 255);
        primitives.drawRoundedBorder(renderer, button_rect, RESTART_BUTTON_RADIUS);

        const text_x = button_x + RESTART_BUTTON_PADDING;
        const text_y = button_y + @divFloor(button_h - text_height, 2);

        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(text_x),
            .y = @floatFromInt(text_y),
            .w = @floatFromInt(text_width),
            .h = @floatFromInt(text_height),
        };
        _ = c.SDL_RenderTexture(renderer, self.texture.?, null, &dest_rect);
    }

    fn restartButtonRect(self: *RestartButtonsComponent, rect: geom.Rect) geom.Rect {
        const text_width = if (self.tex_w > 0) self.tex_w else 80;
        const button_w = text_width + RESTART_BUTTON_PADDING * 2;
        const button_h = RESTART_BUTTON_HEIGHT;
        const button_x = rect.x + rect.w - button_w - RESTART_BUTTON_MARGIN;
        const button_y = rect.y + rect.h - button_h - RESTART_BUTTON_MARGIN;
        return geom.Rect{
            .x = button_x,
            .y = button_y,
            .w = button_w,
            .h = button_h,
        };
    }

    fn ensureTexture(self: *RestartButtonsComponent, renderer: ?*c.SDL_Renderer, theme: *const @import("../../colors.zig").Theme, cache: *font_cache.FontCache) !void {
        if (self.texture != null and !self.isDirty()) return;
        const r = renderer orelse return error.MissingRenderer;
        const fonts = try cache.get(RESTART_BUTTON_FONT_SIZE);
        const icon_font = fonts.regular;

        const restart_text = "Restart";
        const fg = theme.foreground;
        const fg_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const surface = c.TTF_RenderText_Blended(icon_font, restart_text, restart_text.len, fg_color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(surface);

        const texture = c.SDL_CreateTextureFromSurface(r, surface) orelse return error.TextureFailed;
        if (self.texture) |old| {
            c.SDL_DestroyTexture(old);
        }
        self.texture = texture;

        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &w, &h);
        self.tex_w = @intFromFloat(w);
        self.tex_h = @intFromFloat(h);
    }

    fn isDirty(self: *const RestartButtonsComponent) bool {
        return self.texture == null or self.tex_w == 0 or self.tex_h == 0;
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *RestartButtonsComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};
