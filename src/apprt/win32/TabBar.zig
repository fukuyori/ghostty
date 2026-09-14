//! GDI drawing and hit testing for the native Win32 tab bar child window.

const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../../config/Config.zig");

pub const Item = struct {
    title: []const u8,
    active: bool,
};

pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    new_tab,
};

const logical_height: i32 = 32;
const logical_max_tab_width: i32 = 200;
const logical_close_width: i32 = 26;
const logical_padding: i32 = 10;

pub fn heightForDpi(dpi: u32) i32 {
    return scale(logical_height, dpi);
}

pub fn hitTest(
    width: i32,
    height: i32,
    tab_count: usize,
    x: i32,
    y: i32,
) Hit {
    if (x < 0 or y < 0 or x >= width or y >= height) return .none;

    const plus = plusRect(width, height, tab_count);
    if (contains(plus, x, y)) return .new_tab;

    for (0..tab_count) |index| {
        const tab = tabRect(width, height, tab_count, index);
        if (!contains(tab, x, y)) continue;
        if (contains(closeRect(tab, height), x, y)) return .{ .close = index };
        return .{ .tab = index };
    }
    return .none;
}

pub fn paint(
    alloc: std.mem.Allocator,
    hdc: win32.HDC,
    width: i32,
    height: i32,
    dpi: u32,
    config: *const Config,
    items: []const Item,
    hover: Hit,
) void {
    const background = config.background;
    const foreground = config.@"window-titlebar-foreground" orelse config.foreground;
    const inactive = mix(background, foreground, 4);
    const hovered = mix(background, foreground, 10);
    const active = mix(background, foreground, 15);
    const border = mix(background, foreground, 24);
    const accent = mix(background, foreground, 55);

    fill(hdc, .{ .left = 0, .top = 0, .right = width, .bottom = height }, colorRef(background));
    _ = win32.SetBkMode(hdc, win32.TRANSPARENT);
    _ = win32.SetTextColor(hdc, colorRef(foreground));
    const font = win32.GetStockObject(win32.DEFAULT_GUI_FONT);
    const previous_font = if (font) |value| win32.SelectObject(hdc, value) else null;
    defer if (previous_font) |value| {
        _ = win32.SelectObject(hdc, value);
    };

    for (items, 0..) |item, index| {
        const rect = tabRect(width, height, items.len, index);
        const tab_hovered = switch (hover) {
            .tab => |value| value == index,
            .close => |value| value == index,
            else => false,
        };
        fill(hdc, rect, colorRef(if (item.active) active else if (tab_hovered) hovered else inactive));

        const separator: win32.RECT = .{
            .left = rect.right - 1,
            .top = scale(7, dpi),
            .right = rect.right,
            .bottom = height - scale(7, dpi),
        };
        fill(hdc, separator, colorRef(border));

        const close = closeRect(rect, height);
        if (switch (hover) {
            .close => |value| value == index,
            else => false,
        }) {
            fill(hdc, close, 0x003A3AD0);
        }
        var label_rect: win32.RECT = .{
            .left = rect.left + scale(logical_padding, dpi),
            .top = rect.top,
            .right = @max(rect.left, close.left - scale(4, dpi)),
            .bottom = rect.bottom,
        };
        drawUtf8(
            alloc,
            hdc,
            if (item.title.len > 0) item.title else "Ghostty",
            &label_rect,
            draw_left | draw_vcenter | draw_singleline | draw_end_ellipsis | draw_noprefix,
        );

        var close_text = close;
        drawUtf8(
            alloc,
            hdc,
            "×",
            &close_text,
            draw_center | draw_vcenter | draw_singleline | draw_noprefix,
        );

        if (item.active) {
            fill(
                hdc,
                .{
                    .left = rect.left + scale(8, dpi),
                    .top = rect.bottom - scale(2, dpi),
                    .right = rect.right - scale(8, dpi),
                    .bottom = rect.bottom,
                },
                colorRef(accent),
            );
        }
    }

    var plus = plusRect(width, height, items.len);
    fill(hdc, plus, colorRef(if (hover == .new_tab) hovered else inactive));
    drawUtf8(
        alloc,
        hdc,
        "+",
        &plus,
        draw_center | draw_vcenter | draw_singleline | draw_noprefix,
    );

    fill(
        hdc,
        .{ .left = 0, .top = height - 1, .right = width, .bottom = height },
        colorRef(border),
    );
}

fn tabRect(width: i32, height: i32, count: usize, index: usize) win32.RECT {
    if (count == 0) return std.mem.zeroes(win32.RECT);
    const count_i: i64 = @intCast(count);
    const available: i64 = @max(0, width - height);
    const scaled_max = @divTrunc(
        @as(i64, logical_max_tab_width) * @as(i64, height),
        logical_height,
    );
    const total = @min(available, scaled_max * count_i);
    return .{
        .left = @intCast(@divTrunc(total * @as(i64, @intCast(index)), count_i)),
        .top = 0,
        .right = @intCast(@divTrunc(total * @as(i64, @intCast(index + 1)), count_i)),
        .bottom = height,
    };
}

fn plusRect(width: i32, height: i32, count: usize) win32.RECT {
    const left = if (count == 0) 0 else tabRect(width, height, count, count - 1).right;
    return .{
        .left = left,
        .top = 0,
        .right = @min(width, left + height),
        .bottom = height,
    };
}

fn closeRect(tab: win32.RECT, height: i32) win32.RECT {
    const width = @min(
        tab.right - tab.left,
        @divTrunc(logical_close_width * height, logical_height),
    );
    return .{
        .left = tab.right - width,
        .top = tab.top,
        .right = tab.right,
        .bottom = tab.bottom,
    };
}

fn contains(rect: win32.RECT, x: i32, y: i32) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn fill(hdc: win32.HDC, rect: win32.RECT, color: u32) void {
    const brush = win32.CreateSolidBrush(color) orelse return;
    defer _ = win32.DeleteObject(brush);
    _ = win32.FillRect(hdc, &rect, brush);
}

fn drawUtf8(
    alloc: std.mem.Allocator,
    hdc: win32.HDC,
    value: []const u8,
    rect: *win32.RECT,
    format: u32,
) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, value) catch return;
    defer alloc.free(wide);
    _ = win32.DrawTextW(
        hdc,
        wide.ptr,
        @intCast(wide.len),
        rect,
        @bitCast(format),
    );
}

fn scale(value: i32, dpi: u32) i32 {
    return @intCast(@divTrunc(@as(i64, value) * @as(i64, dpi) + 48, 96));
}

fn mix(background: Config.Color, foreground: Config.Color, percent: u16) Config.Color {
    return .{
        .r = mixChannel(background.r, foreground.r, percent),
        .g = mixChannel(background.g, foreground.g, percent),
        .b = mixChannel(background.b, foreground.b, percent),
    };
}

fn mixChannel(background: u8, foreground: u8, percent: u16) u8 {
    return @intCast((@as(u16, background) * (100 - percent) + @as(u16, foreground) * percent) / 100);
}

fn colorRef(color: Config.Color) u32 {
    return @as(u32, color.r) |
        (@as(u32, color.g) << 8) |
        (@as(u32, color.b) << 16);
}

const draw_left: u32 = 0x0000;
const draw_center: u32 = 0x0001;
const draw_vcenter: u32 = 0x0004;
const draw_singleline: u32 = 0x0020;
const draw_noprefix: u32 = 0x0800;
const draw_end_ellipsis: u32 = 0x8000;

test "Win32 tab bar hit testing distinguishes labels and buttons" {
    const width = 800;
    const height = 32;

    try std.testing.expectEqual(Hit{ .tab = 0 }, hitTest(width, height, 3, 10, 10));
    try std.testing.expectEqual(Hit{ .close = 0 }, hitTest(width, height, 3, 190, 10));
    try std.testing.expectEqual(Hit.new_tab, hitTest(width, height, 3, 615, 10));
    try std.testing.expectEqual(Hit.none, hitTest(width, height, 3, 700, 10));
}

test "Win32 tab bar height follows DPI" {
    try std.testing.expectEqual(@as(i32, 32), heightForDpi(96));
    try std.testing.expectEqual(@as(i32, 48), heightForDpi(144));
}
