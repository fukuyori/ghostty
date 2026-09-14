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
    scroll_previous,
    scroll_next,
    new_tab,
};

pub const Drag = struct {
    index: usize,
    start_x: i32,
    start_y: i32,
    active: bool = false,
};

const logical_height: i32 = 32;
const logical_max_tab_width: i32 = 200;
const logical_min_tab_width: i32 = 112;
const logical_close_width: i32 = 26;
const logical_padding: i32 = 10;
const logical_zoom_width: i32 = 58;
const logical_font_points: i32 = 9;

pub fn heightForDpi(dpi: u32) i32 {
    return scale(logical_height, dpi);
}

pub fn hitTest(
    width: i32,
    height: i32,
    tab_count: usize,
    zoomed: bool,
    first_visible: usize,
    x: i32,
    y: i32,
) Hit {
    if (x < 0 or y < 0 or x >= width or y >= height) return .none;

    const layout = barLayout(width, height, tab_count, zoomed, first_visible);
    if (layout.previous) |rect| {
        if (contains(rect, x, y)) return .scroll_previous;
    }
    if (layout.next) |rect| {
        if (contains(rect, x, y)) return .scroll_next;
    }
    if (contains(layout.plus, x, y)) return .new_tab;

    const index = tabAt(width, height, tab_count, zoomed, first_visible, x, y) orelse return .none;
    const tab = layout.tabRect(index);
    if (contains(closeRect(tab, height), x, y)) return .{ .close = index };
    return .{ .tab = index };
}

/// Return the tab under a point while treating the close button as part of
/// the tab. Drag reordering uses this so the full tab width is a drop target.
pub fn tabAt(
    width: i32,
    height: i32,
    tab_count: usize,
    zoomed: bool,
    first_visible: usize,
    x: i32,
    y: i32,
) ?usize {
    if (x < 0 or y < 0 or x >= width or y >= height) return null;
    const layout = barLayout(width, height, tab_count, zoomed, first_visible);
    const end = layout.first_visible + layout.visible_count;
    for (layout.first_visible..end) |index| {
        if (contains(layout.tabRect(index), x, y)) return index;
    }
    return null;
}

pub fn tabRect(
    width: i32,
    height: i32,
    tab_count: usize,
    zoomed: bool,
    first_visible: usize,
    index: usize,
) ?win32.RECT {
    if (index >= tab_count) return null;
    const layout = barLayout(width, height, tab_count, zoomed, first_visible);
    if (index < layout.first_visible or
        index >= layout.first_visible + layout.visible_count)
    {
        return null;
    }
    return layout.tabRect(index);
}

pub fn ensureVisible(
    width: i32,
    height: i32,
    tab_count: usize,
    zoomed: bool,
    first_visible: usize,
    active: usize,
) usize {
    if (tab_count == 0) return 0;
    const layout = barLayout(width, height, tab_count, zoomed, first_visible);
    if (active < layout.first_visible) return active;
    if (active >= layout.first_visible + layout.visible_count) {
        return active + 1 - layout.visible_count;
    }
    return layout.first_visible;
}

pub fn overflows(
    width: i32,
    height: i32,
    tab_count: usize,
    zoomed: bool,
) bool {
    return barLayout(width, height, tab_count, zoomed, 0).previous != null;
}

pub fn dragThresholdExceeded(
    drag: Drag,
    x: i32,
    y: i32,
    threshold_x: i32,
    threshold_y: i32,
) bool {
    const dx = @abs(@as(i64, x) - drag.start_x);
    const dy = @abs(@as(i64, y) - drag.start_y);
    return dx >= @max(1, threshold_x) or dy >= @max(1, threshold_y);
}

pub fn paint(
    alloc: std.mem.Allocator,
    hdc: win32.HDC,
    width: i32,
    height: i32,
    dpi: u32,
    config: *const Config,
    items: []const Item,
    zoomed: bool,
    first_visible: usize,
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
    const dpi_font = createFontForDpi(dpi);
    defer if (dpi_font) |value| {
        _ = win32.DeleteObject(value);
    };
    const font = dpi_font orelse win32.GetStockObject(win32.DEFAULT_GUI_FONT);
    const previous_font = if (font) |value| win32.SelectObject(hdc, value) else null;
    defer if (previous_font) |value| {
        _ = win32.SelectObject(hdc, value);
    };

    const layout = barLayout(width, height, items.len, zoomed, first_visible);
    const visible_end = layout.first_visible + layout.visible_count;
    for (items[layout.first_visible..visible_end], layout.first_visible..) |item, index| {
        const rect = layout.tabRect(index);
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

    if (layout.previous) |value| {
        var previous = value;
        fill(hdc, previous, colorRef(if (hover == .scroll_previous) hovered else inactive));
        drawUtf8(
            alloc,
            hdc,
            "<",
            &previous,
            draw_center | draw_vcenter | draw_singleline | draw_noprefix,
        );
    }
    if (layout.next) |value| {
        var next = value;
        fill(hdc, next, colorRef(if (hover == .scroll_next) hovered else inactive));
        drawUtf8(
            alloc,
            hdc,
            ">",
            &next,
            draw_center | draw_vcenter | draw_singleline | draw_noprefix,
        );
    }

    var plus = layout.plus;
    fill(hdc, plus, colorRef(if (hover == .new_tab) hovered else inactive));
    drawUtf8(
        alloc,
        hdc,
        "+",
        &plus,
        draw_center | draw_vcenter | draw_singleline | draw_noprefix,
    );

    if (layout.status) |status| {
        var badge = status;
        badge.left += scale(5, dpi);
        badge.top += scale(5, dpi);
        badge.right -= scale(5, dpi);
        badge.bottom -= scale(5, dpi);
        fill(hdc, badge, colorRef(active));
        _ = win32.SetTextColor(hdc, colorRef(accent));
        drawUtf8(
            alloc,
            hdc,
            "ZOOM",
            &badge,
            draw_center | draw_vcenter | draw_singleline | draw_noprefix,
        );
        _ = win32.SetTextColor(hdc, colorRef(foreground));
    }

    fill(
        hdc,
        .{ .left = 0, .top = height - 1, .right = width, .bottom = height },
        colorRef(border),
    );
}

const BarLayout = struct {
    height: i32,
    tab_left: i32,
    tab_right: i32,
    first_visible: usize,
    visible_count: usize,
    previous: ?win32.RECT,
    next: ?win32.RECT,
    plus: win32.RECT,
    status: ?win32.RECT,

    fn tabRect(self: BarLayout, index: usize) win32.RECT {
        if (self.visible_count == 0 or index < self.first_visible or
            index >= self.first_visible + self.visible_count)
        {
            return std.mem.zeroes(win32.RECT);
        }
        const relative = index - self.first_visible;
        const count: i64 = @intCast(self.visible_count);
        const extent: i64 = @max(0, self.tab_right - self.tab_left);
        return .{
            .left = self.tab_left + @as(i32, @intCast(@divTrunc(
                extent * @as(i64, @intCast(relative)),
                count,
            ))),
            .top = 0,
            .right = self.tab_left + @as(i32, @intCast(@divTrunc(
                extent * @as(i64, @intCast(relative + 1)),
                count,
            ))),
            .bottom = self.height,
        };
    }
};

fn barLayout(
    width: i32,
    height: i32,
    count: usize,
    zoomed: bool,
    requested_first: usize,
) BarLayout {
    const safe_width = @max(0, width);
    const safe_height = @max(0, height);
    const status_width = zoomStatusWidth(safe_width, safe_height, count, zoomed);
    const content_right = @max(0, safe_width - status_width);
    const plus_width = @min(safe_height, content_right);
    const no_overflow_extent = @max(0, content_right - plus_width);
    const minimum_tab_width = @max(
        1,
        @divTrunc(logical_min_tab_width * safe_height, logical_height),
    );
    const overflow = count > 0 and
        @as(i64, @intCast(count)) * minimum_tab_width > no_overflow_extent;

    const status: ?win32.RECT = if (status_width > 0) .{
        .left = safe_width - status_width,
        .top = 0,
        .right = safe_width,
        .bottom = safe_height,
    } else null;

    if (!overflow) {
        const scaled_max = @divTrunc(
            @as(i64, logical_max_tab_width) * safe_height,
            logical_height,
        );
        const total: i32 = @intCast(@min(
            @as(i64, no_overflow_extent),
            scaled_max * @as(i64, @intCast(count)),
        ));
        return .{
            .height = safe_height,
            .tab_left = 0,
            .tab_right = total,
            .first_visible = 0,
            .visible_count = count,
            .previous = null,
            .next = null,
            .plus = .{
                .left = total,
                .top = 0,
                .right = @min(content_right, total + plus_width),
                .bottom = safe_height,
            },
            .status = status,
        };
    }

    const control_width = if (content_right > 0)
        @min(safe_height, @max(1, @divTrunc(content_right, 4)))
    else
        0;
    const plus: win32.RECT = .{
        .left = content_right - control_width,
        .top = 0,
        .right = content_right,
        .bottom = safe_height,
    };
    const next: win32.RECT = .{
        .left = plus.left - control_width,
        .top = 0,
        .right = plus.left,
        .bottom = safe_height,
    };
    const tab_left = control_width;
    const tab_right = @max(tab_left, next.left);
    const tab_extent = @max(0, tab_right - tab_left);
    const capacity: usize = @min(
        count,
        @as(usize, @intCast(@max(1, @divTrunc(tab_extent, minimum_tab_width)))),
    );
    const max_first = count - capacity;
    const first = @min(requested_first, max_first);
    return .{
        .height = safe_height,
        .tab_left = tab_left,
        .tab_right = tab_right,
        .first_visible = first,
        .visible_count = capacity,
        .previous = .{
            .left = 0,
            .top = 0,
            .right = control_width,
            .bottom = safe_height,
        },
        .next = next,
        .plus = plus,
        .status = status,
    };
}

fn zoomStatusWidth(width: i32, height: i32, count: usize, zoomed: bool) i32 {
    if (!zoomed) return 0;
    const minimum_tabs = if (count == 0) 0 else height;
    const available = @max(0, width - height - minimum_tabs);
    const desired = @divTrunc(logical_zoom_width * height, logical_height);
    return @min(available, desired);
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

fn fontHeightForDpi(dpi: u32) i32 {
    return @intCast(@max(
        1,
        @divTrunc(@as(i64, logical_font_points) * dpi + 36, 72),
    ));
}

fn createFontForDpi(dpi: u32) ?win32.HFONT {
    return win32.CreateFontW(
        -fontHeightForDpi(dpi),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        @intFromEnum(win32.DEFAULT_CHARSET),
        win32.OUT_DEFAULT_PRECIS,
        .{},
        win32.CLEARTYPE_QUALITY,
        win32.FF_SWISS,
        win32.L("Segoe UI"),
    );
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

    try std.testing.expectEqual(Hit{ .tab = 0 }, hitTest(width, height, 3, false, 0, 10, 10));
    try std.testing.expectEqual(Hit{ .close = 0 }, hitTest(width, height, 3, false, 0, 190, 10));
    try std.testing.expectEqual(Hit.new_tab, hitTest(width, height, 3, false, 0, 615, 10));
    try std.testing.expectEqual(Hit.none, hitTest(width, height, 3, false, 0, 700, 10));
}

test "Win32 tab bar geometry and font follow DPI" {
    try std.testing.expectEqual(@as(i32, 32), heightForDpi(96));
    try std.testing.expectEqual(@as(i32, 40), heightForDpi(120));
    try std.testing.expectEqual(@as(i32, 48), heightForDpi(144));
    try std.testing.expectEqual(@as(i32, 64), heightForDpi(192));
    try std.testing.expectEqual(@as(i32, 12), fontHeightForDpi(96));
    try std.testing.expectEqual(@as(i32, 15), fontHeightForDpi(120));
    try std.testing.expectEqual(@as(i32, 18), fontHeightForDpi(144));
    try std.testing.expectEqual(@as(i32, 24), fontHeightForDpi(192));

    const font = createFontForDpi(192) orelse return error.TestUnexpectedResult;
    defer _ = win32.DeleteObject(font);
}

test "Win32 tab bar exposes the full tab as a drag target" {
    const width = 800;
    const height = 32;

    try std.testing.expectEqual(@as(?usize, 0), tabAt(width, height, 3, false, 0, 190, 10));
    try std.testing.expectEqual(@as(?usize, 2), tabAt(width, height, 3, false, 0, 410, 10));
    try std.testing.expectEqual(@as(?usize, null), tabAt(width, height, 3, false, 0, 615, 10));
    try std.testing.expectEqual(@as(?usize, null), tabAt(width, height, 3, false, 0, 10, 40));
}

test "Win32 tab bar reserves space for the zoom status" {
    const width = 800;
    const height = 32;

    const layout = barLayout(width, height, 3, true, 0);
    const status = layout.status.?;
    try std.testing.expectEqual(@as(i32, 742), status.left);
    try std.testing.expectEqual(Hit.none, hitTest(width, height, 3, true, 0, 770, 10));
    try std.testing.expectEqual(Hit.new_tab, hitTest(width, height, 3, true, 0, 610, 10));
    try std.testing.expect(layout.plus.right <= status.left);
    try std.testing.expect(barLayout(width, height, 3, false, 0).status == null);
}

test "Win32 tab bar overflow keeps the active tab reachable" {
    const width = 800;
    const height = 32;
    const count = 8;

    const first = ensureVisible(width, height, count, false, 0, 7);
    try std.testing.expect(!overflows(width, height, 3, false));
    try std.testing.expect(overflows(width, height, count, false));
    try std.testing.expectEqual(@as(usize, 2), first);
    const layout = barLayout(width, height, count, false, first);
    try std.testing.expectEqual(@as(usize, 6), layout.visible_count);
    try std.testing.expectEqual(Hit.scroll_previous, hitTest(width, height, count, false, first, 10, 10));
    try std.testing.expectEqual(Hit.scroll_next, hitTest(width, height, count, false, first, 750, 10));
    try std.testing.expectEqual(Hit.new_tab, hitTest(width, height, count, false, first, 780, 10));
    try std.testing.expectEqual(@as(?usize, 2), tabAt(width, height, count, false, first, 40, 10));
    try std.testing.expectEqual(@as(?usize, 7), tabAt(width, height, count, false, first, 700, 10));
    try std.testing.expect(tabRect(width, height, count, false, first, 1) == null);
    const active_rect = tabRect(width, height, count, false, first, 7).?;
    try std.testing.expect(active_rect.left >= 0);
    try std.testing.expect(active_rect.right <= width);
}

test "Win32 tab bar drag starts only after the configured threshold" {
    const drag: Drag = .{ .index = 1, .start_x = 100, .start_y = 16 };

    try std.testing.expect(!dragThresholdExceeded(drag, 103, 18, 4, 4));
    try std.testing.expect(dragThresholdExceeded(drag, 104, 16, 4, 4));
    try std.testing.expect(dragThresholdExceeded(drag, 100, 12, 4, 4));
}

test "Win32 tab bar height follows DPI" {
    try std.testing.expectEqual(@as(i32, 32), heightForDpi(96));
    try std.testing.expectEqual(@as(i32, 48), heightForDpi(144));
}
