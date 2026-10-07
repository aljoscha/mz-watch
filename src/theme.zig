const vaxis = @import("vaxis");

pub const Palette = struct {
    base: vaxis.Style,
    muted: vaxis.Style,
    accent: vaxis.Style,
    danger: vaxis.Style,
    selected: vaxis.Style,
    hover: vaxis.Style,
    canvas: vaxis.Cell.Color,
    panel: vaxis.Style,
    border: vaxis.Style,

    // Light is the fallback when the terminal does not report a color scheme.
    pub const light: Palette = .{
        .base = .{ .fg = .{ .rgb = .{ 35, 42, 52 } } },
        .muted = .{ .fg = .{ .rgb = .{ 88, 100, 116 } } },
        .accent = .{ .fg = .{ .rgb = .{ 15, 112, 101 } }, .bold = true },
        .danger = .{ .fg = .{ .rgb = .{ 166, 45, 44 } } },
        .selected = .{ .fg = .{ .rgb = .{ 24, 77, 70 } }, .bg = .{ .rgb = .{ 222, 239, 235 } } },
        .hover = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = .{ .rgb = .{ 15, 112, 101 } } },
        .canvas = .{ .rgb = .{ 244, 246, 248 } },
        .panel = .{ .fg = .{ .rgb = .{ 35, 42, 52 } }, .bg = .{ .rgb = .{ 255, 255, 255 } } },
        .border = .{ .fg = .{ .rgb = .{ 198, 207, 215 } }, .bg = .{ .rgb = .{ 255, 255, 255 } } },
    };

    pub const dark: Palette = .{
        .base = .{ .fg = .{ .rgb = .{ 210, 217, 226 } } },
        .muted = .{ .fg = .{ .rgb = .{ 151, 164, 183 } } },
        .accent = .{ .fg = .{ .rgb = .{ 101, 210, 193 } }, .bold = true },
        .danger = .{ .fg = .{ .rgb = .{ 244, 140, 133 } } },
        .selected = .{ .fg = .{ .rgb = .{ 210, 217, 226 } }, .bg = .{ .rgb = .{ 35, 48, 61 } } },
        .hover = .{ .fg = .{ .rgb = .{ 19, 23, 30 } }, .bg = .{ .rgb = .{ 101, 210, 193 } } },
        .canvas = .default,
        .panel = .{ .fg = .{ .rgb = .{ 210, 217, 226 } }, .bg = .{ .rgb = .{ 26, 32, 40 } } },
        .border = .{ .fg = .{ .rgb = .{ 71, 84, 99 } }, .bg = .{ .rgb = .{ 26, 32, 40 } } },
    };
};
