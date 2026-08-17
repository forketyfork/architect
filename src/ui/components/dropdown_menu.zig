//! Shared open/hover/keyboard-nav state and rendering for a simple vertical
//! list menu, used by the agent pickers in the diff view and the selection
//! dialog. Owns the committed `selected` index; callers react to a
//! `.selected` event on click/Enter instead of tracking the pick themselves.

const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const font_cache = @import("../../font_cache.zig");
const text_render = @import("../text_render.zig");

const log = std.log.scoped(.dropdown_menu);

const TextTexture = text_render.TextTex;

pub const DropdownMenu = struct {
    allocator: std.mem.Allocator,
    open: bool = false,
    selected: usize = 0,
    /// Keyboard/hover cursor while open; meaningless when closed. Seeded from
    /// `selected` on open so arrow-key navigation and the "currently picked
    /// item stays highlighted" behavior fall out of the same field.
    active: ?usize = null,

    item_tex: []?TextTexture = &.{},
    tex_generation: u64 = 0,
    tex_font_size: c_int = 0,
    tex_hash: u64 = 0,

    pub const Event = enum { none, selected, closed };

    pub const Style = struct {
        font_size: c_int,
        radius: c_int,
        bg: c.SDL_Color,
        border: c.SDL_Color,
        highlight: c.SDL_Color,
        text: c.SDL_Color,
        text_inset_x: c_int,
        /// Multiplies every color's alpha; 1.0 for a menu with no fade
        /// animation, or an overlay's current fade-in/out alpha.
        fade: f32 = 1.0,
    };

    pub fn init(allocator: std.mem.Allocator) DropdownMenu {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DropdownMenu) void {
        self.invalidateTextures();
    }

    pub fn openMenu(self: *DropdownMenu) void {
        self.open = true;
        self.active = self.selected;
    }

    pub fn close(self: *DropdownMenu) void {
        self.open = false;
        self.active = null;
    }

    pub fn handleKey(self: *DropdownMenu, key: c.SDL_Keycode, items: []const []const u8) Event {
        if (!self.open or items.len == 0) return .none;
        if (key == c.SDLK_ESCAPE) {
            self.close();
            return .closed;
        }
        if (key == c.SDLK_UP or key == c.SDLK_DOWN) {
            const current: isize = @intCast(self.active orelse self.selected);
            const direction: isize = if (key == c.SDLK_UP) -1 else 1;
            const count: isize = @intCast(items.len);
            self.active = @intCast(@mod(current + direction + count, count));
            return .none;
        }
        if (key == c.SDLK_RETURN or key == c.SDLK_RETURN2 or key == c.SDLK_KP_ENTER) {
            self.selected = self.active orelse self.selected;
            self.close();
            return .selected;
        }
        return .none;
    }

    pub fn handleClick(
        self: *DropdownMenu,
        rect: geom.Rect,
        item_height: c_int,
        items: []const []const u8,
        x: c_int,
        y: c_int,
    ) Event {
        if (!self.open) return .none;
        const hit = itemAt(rect, item_height, items, x, y);
        self.close();
        if (hit) |idx| {
            self.selected = idx;
            return .selected;
        }
        return .closed;
    }

    pub fn handleMotion(
        self: *DropdownMenu,
        rect: geom.Rect,
        item_height: c_int,
        items: []const []const u8,
        x: c_int,
        y: c_int,
    ) void {
        if (!self.open) return;
        if (itemAt(rect, item_height, items, x, y)) |idx| self.active = idx;
    }

    pub fn itemAt(rect: geom.Rect, item_height: c_int, items: []const []const u8, x: c_int, y: c_int) ?usize {
        if (item_height <= 0 or !geom.containsPoint(rect, x, y)) return null;
        const index: usize = @intCast(@divFloor(y - rect.y, item_height));
        return if (index < items.len) index else null;
    }

    pub fn itemRect(rect: geom.Rect, item_height: c_int, index: usize) geom.Rect {
        return .{
            .x = rect.x,
            .y = rect.y + @as(c_int, @intCast(index)) * item_height,
            .w = rect.w,
            .h = item_height,
        };
    }

    /// Cached label texture for `index`, valid only after `ensureLabels` has
    /// run for the current frame. Exposed so callers can show the committed
    /// selection outside the menu box (e.g. a closed selector field).
    pub fn labelTexture(self: *const DropdownMenu, index: usize) ?TextTexture {
        if (index >= self.item_tex.len) return null;
        return self.item_tex[index];
    }

    pub fn ensureLabels(
        self: *DropdownMenu,
        renderer: *c.SDL_Renderer,
        cache: *font_cache.FontCache,
        font_size: c_int,
        items: []const []const u8,
        color: c.SDL_Color,
    ) !void {
        const hash = hashItems(items);
        if (self.tex_generation == cache.generation and
            self.tex_font_size == font_size and
            self.tex_hash == hash and
            self.item_tex.len == items.len)
        {
            return;
        }

        self.invalidateTextures();
        const fonts = try cache.get(font_size);
        const item_tex = try self.allocator.alloc(?TextTexture, items.len);
        @memset(item_tex, null);
        errdefer {
            for (item_tex) |maybe| if (maybe) |tex| c.SDL_DestroyTexture(tex.tex);
            self.allocator.free(item_tex);
        }
        for (items, 0..) |label, idx| {
            item_tex[idx] = text_render.makeTextTexture(self.allocator, renderer, .{ .text = fonts.regular }, label, color) catch |err| blk: {
                log.warn("failed to render dropdown label {d}: {}", .{ idx, err });
                break :blk null;
            };
        }
        self.item_tex = item_tex;
        self.tex_generation = cache.generation;
        self.tex_font_size = font_size;
        self.tex_hash = hash;
    }

    pub fn render(
        self: *DropdownMenu,
        renderer: *c.SDL_Renderer,
        cache: *font_cache.FontCache,
        rect: geom.Rect,
        item_height: c_int,
        items: []const []const u8,
        style: Style,
    ) !void {
        if (!self.open) return;
        try self.ensureLabels(renderer, cache, style.font_size, items, style.text);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        setColor(renderer, style.bg, style.fade);
        primitives.fillRoundedRect(renderer, rect, style.radius);
        setColor(renderer, style.border, style.fade);
        primitives.drawRoundedBorder(renderer, rect, style.radius);

        if (self.active) |active| {
            const row = itemRect(rect, item_height, active);
            setColor(renderer, style.highlight, style.fade);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
                .x = @floatFromInt(row.x + 1),
                .y = @floatFromInt(row.y),
                .w = @floatFromInt(row.w - 2),
                .h = @floatFromInt(row.h),
            });
        }

        for (items, 0..) |_, idx| {
            const tex = self.labelTexture(idx) orelse continue;
            const row = itemRect(rect, item_height, idx);
            _ = c.SDL_SetTextureAlphaMod(tex.tex, scaledAlpha(255, style.fade));
            _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
                .x = @floatFromInt(row.x + style.text_inset_x),
                .y = @floatFromInt(row.y + @divFloor(row.h - tex.h, 2)),
                .w = @floatFromInt(tex.w),
                .h = @floatFromInt(tex.h),
            });
        }
    }

    fn invalidateTextures(self: *DropdownMenu) void {
        for (self.item_tex) |maybe| if (maybe) |tex| c.SDL_DestroyTexture(tex.tex);
        if (self.item_tex.len > 0) self.allocator.free(self.item_tex);
        self.item_tex = &.{};
        self.tex_generation = 0;
        self.tex_font_size = 0;
        self.tex_hash = 0;
    }
};

fn setColor(renderer: *c.SDL_Renderer, color: c.SDL_Color, fade: f32) void {
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, scaledAlpha(color.a, fade));
}

fn scaledAlpha(base: u8, fade: f32) u8 {
    const scaled = @as(f32, @floatFromInt(base)) * fade;
    return @intFromFloat(std.math.clamp(scaled, 0.0, 255.0));
}

fn hashItems(items: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (items) |item| {
        hasher.update(item);
        hasher.update(&[_]u8{0});
    }
    return hasher.final();
}

// --- Tests ---

test "itemAt resolves the hovered item and rejects out-of-bounds points" {
    const items = [_][]const u8{ "a", "b", "c" };
    const rect = geom.Rect{ .x = 100, .y = 200, .w = 240, .h = 108 };

    try std.testing.expectEqual(@as(?usize, 0), DropdownMenu.itemAt(rect, 36, &items, 120, 210));
    try std.testing.expectEqual(@as(?usize, 1), DropdownMenu.itemAt(rect, 36, &items, 120, 250));
    try std.testing.expectEqual(@as(?usize, 2), DropdownMenu.itemAt(rect, 36, &items, 120, 307));
    try std.testing.expectEqual(@as(?usize, null), DropdownMenu.itemAt(rect, 36, &items, 99, 210));
    try std.testing.expectEqual(@as(?usize, null), DropdownMenu.itemAt(rect, 36, &items, 120, 308));
}

test "itemRect stacks items below the anchor rect" {
    const rect = geom.Rect{ .x = 10, .y = 20, .w = 100, .h = 90 };
    try std.testing.expectEqual(geom.Rect{ .x = 10, .y = 20, .w = 100, .h = 30 }, DropdownMenu.itemRect(rect, 30, 0));
    try std.testing.expectEqual(geom.Rect{ .x = 10, .y = 80, .w = 100, .h = 30 }, DropdownMenu.itemRect(rect, 30, 2));
}

test "openMenu seeds the keyboard cursor from the committed selection" {
    var menu = DropdownMenu.init(std.testing.allocator);
    menu.selected = 2;
    menu.openMenu();
    try std.testing.expect(menu.open);
    try std.testing.expectEqual(@as(?usize, 2), menu.active);
}

test "handleKey navigates with wraparound and confirms on enter" {
    const items = [_][]const u8{ "a", "b", "c" };
    var menu = DropdownMenu.init(std.testing.allocator);
    menu.openMenu();

    try std.testing.expectEqual(DropdownMenu.Event.none, menu.handleKey(c.SDLK_UP, &items));
    try std.testing.expectEqual(@as(?usize, 2), menu.active);

    try std.testing.expectEqual(DropdownMenu.Event.none, menu.handleKey(c.SDLK_DOWN, &items));
    try std.testing.expectEqual(@as(?usize, 0), menu.active);

    try std.testing.expectEqual(DropdownMenu.Event.selected, menu.handleKey(c.SDLK_RETURN, &items));
    try std.testing.expectEqual(@as(usize, 0), menu.selected);
    try std.testing.expect(!menu.open);
}

test "handleKey escape closes without committing a selection" {
    const items = [_][]const u8{ "a", "b", "c" };
    var menu = DropdownMenu.init(std.testing.allocator);
    menu.selected = 1;
    menu.openMenu();

    try std.testing.expectEqual(DropdownMenu.Event.none, menu.handleKey(c.SDLK_DOWN, &items));
    try std.testing.expectEqual(DropdownMenu.Event.closed, menu.handleKey(c.SDLK_ESCAPE, &items));
    try std.testing.expectEqual(@as(usize, 1), menu.selected);
    try std.testing.expect(!menu.open);
}

test "handleClick commits the clicked item and always closes" {
    const items = [_][]const u8{ "a", "b", "c" };
    const rect = geom.Rect{ .x = 0, .y = 0, .w = 100, .h = 90 };
    var menu = DropdownMenu.init(std.testing.allocator);
    menu.openMenu();

    try std.testing.expectEqual(DropdownMenu.Event.selected, menu.handleClick(rect, 30, &items, 10, 40));
    try std.testing.expectEqual(@as(usize, 1), menu.selected);
    try std.testing.expect(!menu.open);
}

test "handleClick outside the menu closes without changing the selection" {
    const items = [_][]const u8{ "a", "b", "c" };
    const rect = geom.Rect{ .x = 0, .y = 0, .w = 100, .h = 90 };
    var menu = DropdownMenu.init(std.testing.allocator);
    menu.selected = 2;
    menu.openMenu();

    try std.testing.expectEqual(DropdownMenu.Event.closed, menu.handleClick(rect, 30, &items, 500, 500));
    try std.testing.expectEqual(@as(usize, 2), menu.selected);
}

test "handleMotion tracks the hovered item and keeps the last one on leave" {
    const items = [_][]const u8{ "a", "b", "c" };
    const rect = geom.Rect{ .x = 0, .y = 0, .w = 100, .h = 90 };
    var menu = DropdownMenu.init(std.testing.allocator);
    menu.openMenu();

    menu.handleMotion(rect, 30, &items, 10, 40);
    try std.testing.expectEqual(@as(?usize, 1), menu.active);

    menu.handleMotion(rect, 30, &items, 500, 500);
    try std.testing.expectEqual(@as(?usize, 1), menu.active);
}
