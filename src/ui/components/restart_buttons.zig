const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;

pub const RestartButtonsComponent = struct {
    allocator: std.mem.Allocator,
    font: ?*c.TTF_Font = null,
    texture: ?*c.SDL_Texture = null,
    tex_w: c_int = 0,
    tex_h: c_int = 0,

    const FONT_PATH: [*:0]const u8 = "/System/Library/Fonts/SFNSMono.ttf";
    const RESTART_BUTTON_FONT_SIZE: c_int = 16;
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
        if (self.font) |f| {
            c.TTF_CloseFont(f);
            self.font = null;
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
        if (!session_info.dead) return false;

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

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *RestartButtonsComponent = @ptrCast(@alignCast(self_ptr));
        if (host.view_mode != .Grid) return;

        for (host.sessions, 0..) |info, i| {
            if (!info.dead) continue;
            const grid_row: c_int = @intCast(i / host.grid_cols);
            const grid_col: c_int = @intCast(i % host.grid_cols);
            const cell_rect = geom.Rect{
                .x = grid_col * host.cell_w,
                .y = grid_row * host.cell_h,
                .w = host.cell_w,
                .h = host.cell_h,
            };
            self.renderButton(renderer, cell_rect);
        }
    }

    fn renderButton(self: *RestartButtonsComponent, renderer: *c.SDL_Renderer, rect: geom.Rect) void {
        self.ensureTexture(renderer) catch return;
        const text_width = self.tex_w;
        const text_height = self.tex_h;
        const button_w = text_width + RESTART_BUTTON_PADDING * 2;
        const button_h = text_height + RESTART_BUTTON_PADDING * 2;
        const button_x = rect.x + rect.w - button_w - RESTART_BUTTON_MARGIN;
        const button_y = rect.y + rect.h - button_h - RESTART_BUTTON_MARGIN;

        const button_rect = geom.Rect{
            .x = button_x,
            .y = button_y,
            .w = button_w,
            .h = button_h,
        };

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 50, 220);
        const bg_rect = c.SDL_FRect{
            .x = @floatFromInt(button_x),
            .y = @floatFromInt(button_y),
            .w = @floatFromInt(button_w),
            .h = @floatFromInt(button_h),
        };
        _ = c.SDL_RenderFillRect(renderer, &bg_rect);

        _ = c.SDL_SetRenderDrawColor(renderer, 100, 150, 255, 255);
        primitives.drawRoundedBorder(renderer, button_rect, RESTART_BUTTON_RADIUS);

        const text_x = button_x + RESTART_BUTTON_PADDING;
        const text_y = button_y + RESTART_BUTTON_PADDING;

        const dest_rect = c.SDL_FRect{
            .x = @floatFromInt(text_x),
            .y = @floatFromInt(text_y),
            .w = @floatFromInt(text_width),
            .h = @floatFromInt(text_height),
        };
        _ = c.SDL_RenderTexture(renderer, self.texture.?, null, &dest_rect);
    }

    fn restartButtonRect(self: *RestartButtonsComponent, rect: geom.Rect) geom.Rect {
        self.ensureTexture(null) catch {};
        const text_width = self.tex_w;
        const text_height = self.tex_h;
        const button_w = text_width + RESTART_BUTTON_PADDING * 2;
        const button_h = text_height + RESTART_BUTTON_PADDING * 2;
        const button_x = rect.x + rect.w - button_w - RESTART_BUTTON_MARGIN;
        const button_y = rect.y + rect.h - button_h - RESTART_BUTTON_MARGIN;
        return geom.Rect{
            .x = button_x,
            .y = button_y,
            .w = button_w,
            .h = button_h,
        };
    }

    fn ensureTexture(self: *RestartButtonsComponent, renderer: ?*c.SDL_Renderer) !void {
        if (self.texture != null and !self.isDirty()) return;
        const r = renderer orelse return error.MissingRenderer;
        if (self.font == null) {
            self.font = c.TTF_OpenFont(FONT_PATH, @floatFromInt(RESTART_BUTTON_FONT_SIZE));
            if (self.font == null) return error.FontUnavailable;
        }
        const icon_font = self.font.?;

        const restart_text = "Restart";
        const fg_color = c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 };
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
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};
