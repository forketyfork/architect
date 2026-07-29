//! Compile-time smoke tests for pure helpers that are intentionally usable from
//! comptime code. Keeping these checks in a dedicated test root makes regressions
//! visible even when the same helpers are mostly exercised by runtime tests.

const config = @import("config.zig");
const grid_layout = @import("app/grid_layout.zig");

const Color = config.Color;
const GridLayout = grid_layout.GridLayout;
const GridPosition = grid_layout.GridPosition;

fn expectColorEqual(comptime expected: Color, comptime actual: Color) void {
    if (actual.r != expected.r or actual.g != expected.g or actual.b != expected.b) {
        @compileError("comptime color mismatch");
    }
}

fn expectUsizeEqual(comptime expected: usize, comptime actual: usize) void {
    if (actual != expected) {
        @compileError("comptime usize mismatch");
    }
}

fn expectBool(comptime condition: bool) void {
    if (!condition) {
        @compileError("comptime boolean check failed");
    }
}

test "color parsing and theme fallback remain comptime-evaluable" {
    comptime {
        expectColorEqual(
            .{ .r = 0x0e, .g = 0x11, .b = 0x16 },
            Color.fromHex("#0E1116") orelse @compileError("valid color did not parse"),
        );
        expectColorEqual(
            .{ .r = 0xcd, .g = 0xd6, .b = 0xe0 },
            Color.fromHex("cdd6e0") orelse @compileError("valid color without # did not parse"),
        );
        expectBool(Color.fromHex("#12345") == null);
        expectBool(Color.fromHex("#12xx56") == null);

        const themed = config.ThemeConfig{
            .background = "#010203",
            .foreground = "not-a-color",
            .selection = "",
            .accent = "#AABBCC",
        };
        expectColorEqual(.{ .r = 1, .g = 2, .b = 3 }, themed.getBackground());
        expectColorEqual(Color.default_foreground, themed.getForeground());
        expectColorEqual(Color.default_selection, themed.getSelection());
        expectColorEqual(.{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, themed.getAccent());

        const palette = config.PaletteConfig{
            .black = "#000102",
            .bright_white = "#FEFDFC",
        };
        expectColorEqual(.{ .r = 0, .g = 1, .b = 2 }, palette.getColor(0));
        expectColorEqual(config.default_palette[1], palette.getColor(1));
        expectColorEqual(.{ .r = 0xfe, .g = 0xfd, .b = 0xfc }, palette.getColor(15));
    }
}

test "grid dimension helpers remain comptime-evaluable and bounded" {
    comptime {
        inline for (0..(grid_layout.max_terminals + 8)) |count| {
            const dims = GridLayout.calculateDimensions(count);
            expectBool(dims.cols >= 1);
            expectBool(dims.rows >= 1);
            expectBool(dims.cols <= grid_layout.max_grid_size);
            expectBool(dims.rows <= grid_layout.max_grid_size);
            expectBool(dims.cols >= dims.rows);
            if (count <= grid_layout.max_terminals) {
                expectBool(dims.cols * dims.rows >= @max(count, 1));
            }
        }

        const dims_10 = GridLayout.calculateDimensions(10);
        expectUsizeEqual(4, dims_10.cols);
        expectUsizeEqual(3, dims_10.rows);

        const pos = GridPosition.fromIndex(17, 5);
        expectUsizeEqual(2, pos.col);
        expectUsizeEqual(3, pos.row);
        expectUsizeEqual(17, pos.toIndex(5));
    }
}
