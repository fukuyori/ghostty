//! Per-pane overlay scrollbar. The terminal core owns the scroll position;
//! this child window draws a translucent thumb and sends scroll_to_row input.
const Self = @This();
const std = @import("std");
const win32 = @import("win32").everything;
const Config = @import("../../config/Config.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");
const log = std.log.scoped(.win32_scrollbar);

const class_name = win32.L("GhosttyOverlayScrollbar");
const timer_id = 1;
const hide_delay_ms = 1400;
var class_registered = false;

surface: *Surface,
hwnd: win32.HWND,
state: terminal.Scrollbar = .zero,
background: Config.Color,
high_contrast: bool,
width_px: i32 = 0,
height_px: i32 = 0,
shown: bool = false,
dragging: bool = false,
drag_start_y: i32 = 0,
drag_start_top: i32 = 0,

pub fn init(self: *Self, surface: *Surface, background: Config.Color, high_contrast: bool) !void {
    try registerClass();
    const style: win32.WINDOW_STYLE = @bitCast(@as(u32, @bitCast(win32.WS_POPUP)));
    const hwnd = win32.CreateWindowExW(
        .{ .LAYERED = 1, .NOACTIVATE = 1, .TOOLWINDOW = 1 },
        class_name,
        win32.L(""),
        style,
        0,
        0,
        0,
        0,
        surface.windowHwnd(),
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse return error.CreateScrollbarFailed;
    self.* = .{ .surface = surface, .hwnd = hwnd, .background = background, .high_contrast = high_contrast };
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

pub fn deinit(self: *Self) void {
    _ = win32.KillTimer(self.hwnd, timer_id);
    if (self.dragging) _ = win32.ReleaseCapture();
    if (win32.DestroyWindow(self.hwnd) == 0) {
        log.warn("DestroyWindow(scrollbar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

fn registerClass() !void {
    if (class_registered) return;
    const instance = win32.GetModuleHandleW(null) orelse return error.CreateScrollbarFailed;
    const wc: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&wc) == 0) return error.CreateScrollbarFailed;
    class_registered = true;
}

fn scaled(dpi: u32, logical: i32) i32 {
    return @max(1, @divTrunc(logical * @as(i32, @intCast(dpi)), 96));
}

pub fn width(dpi: u32) i32 {
    return scaled(dpi, 14);
}

pub fn layout(self: *Self, x: i32, y: i32, pane_width: i32, height: i32, visible: bool) void {
    if (!visible or pane_width <= 0 or height <= 0) {
        self.hide();
        return;
    }
    const bar_width = width(win32.GetDpiForWindow(self.surface.windowHwnd()));
    const changed = self.width_px != bar_width or self.height_px != height;
    self.width_px = bar_width;
    self.height_px = height;
    var screen: win32.POINT = .{ .x = x + pane_width - bar_width, .y = y };
    if (win32.ClientToScreen(self.surface.windowHwnd(), &screen) == 0) return;
    if (win32.SetWindowPos(self.hwnd, null, screen.x, screen.y, bar_width, height, .{ .NOACTIVATE = 1 }) == 0) {
        log.warn("SetWindowPos(scrollbar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    }
    if (changed and self.shown) self.draw();
}

pub fn setAppearance(self: *Self, background: Config.Color, high_contrast: bool) void {
    self.background = background;
    self.high_contrast = high_contrast;
    if (self.shown) self.draw();
}

pub fn update(self: *Self, state: terminal.Scrollbar) void {
    const previous = self.state;
    self.state = state;
    if (state.total <= state.len) {
        self.hide();
        return;
    }
    if (self.shown) self.draw();
    if (state.offset != previous.offset and state.offset < state.total - state.len) self.reveal();
}

pub fn hoverAt(self: *Self, x: i32) void {
    if (self.width_px <= 0) return;
    const trigger = @as(i32, @intCast(self.surface.width)) - self.width_px - scaled(win32.GetDpiForWindow(self.hwnd), 4);
    if (x >= trigger) self.reveal();
}

pub fn reveal(self: *Self) void {
    if (self.state.total <= self.state.len or self.width_px <= 0 or self.height_px <= 0) return;
    if (!self.shown) {
        self.draw();
        _ = win32.ShowWindow(self.hwnd, win32.SW_SHOWNA);
        self.shown = true;
    }
    _ = win32.SetTimer(self.hwnd, timer_id, hide_delay_ms, null);
}

pub fn hide(self: *Self) void {
    _ = win32.KillTimer(self.hwnd, timer_id);
    if (self.shown) {
        _ = win32.ShowWindow(self.hwnd, win32.SW_HIDE);
        self.shown = false;
    }
}

const Thumb = struct { top: i32, height: i32 };

fn thumb(self: *const Self) Thumb {
    const inset = scaled(win32.GetDpiForWindow(self.hwnd), 3);
    const track: i32 = @max(1, self.height_px - 2 * inset);
    const proportional: u128 = @as(u128, @intCast(track)) * self.state.len / @max(1, self.state.total);
    const length = @min(track, @max(scaled(win32.GetDpiForWindow(self.hwnd), 24), @as(i32, @intCast(@min(proportional, @as(u128, @intCast(track)))))));
    const last = self.state.total -| self.state.len;
    const travel = track - length;
    const position = if (last == 0) 0 else @as(i32, @intCast(@as(u128, @intCast(travel)) * @min(self.state.offset, last) / last));
    return .{ .top = inset + position, .height = length };
}

fn rowAt(self: *const Self, top: i32) usize {
    const t = self.thumb();
    const inset = scaled(win32.GetDpiForWindow(self.hwnd), 3);
    const travel = @max(1, self.height_px - 2 * inset - t.height);
    const fraction = std.math.clamp(top - inset, 0, travel);
    const last = self.state.total -| self.state.len;
    return @intCast(@as(u128, @intCast(fraction)) * last / @as(u128, @intCast(travel)));
}

fn scrollTo(self: *Self, row: usize) void {
    const core = self.surface.core_surface orelse return;
    _ = core.performBindingAction(.{ .scroll_to_row = row }) catch |err| {
        log.warn("scroll_to_row failed: {}", .{err});
    };
}

fn draw(self: *Self) void {
    if (self.width_px <= 0 or self.height_px <= 0 or self.state.total <= self.state.len) return;
    const count: usize = @intCast(@as(i64, self.width_px) * self.height_px);
    if (count > 2_000_000) return;
    const memory = win32.CreateCompatibleDC(null);
    defer _ = win32.DeleteDC(memory);
    var info: win32.BITMAPINFO = std.mem.zeroes(win32.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(win32.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = self.width_px;
    info.bmiHeader.biHeight = -self.height_px;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = .RGB;
    var bits: ?*anyopaque = null;
    const bitmap = win32.CreateDIBSection(memory, &info, .RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = win32.DeleteObject(bitmap);
    const previous = win32.SelectObject(memory, bitmap);
    defer _ = win32.SelectObject(memory, previous);
    const pixels: [*]u32 = @ptrCast(@alignCast(bits orelse return));
    @memset(pixels[0..count], 0x01000000);

    const t = self.thumb();
    const dpi = win32.GetDpiForWindow(self.hwnd);
    const margin = scaled(dpi, 4);
    const radius = scaled(dpi, 3);
    const dark = (@as(u16, self.background.r) * 30 + @as(u16, self.background.g) * 59 + @as(u16, self.background.b) * 11) < 12800;
    const color = if (self.high_contrast) win32.GetSysColor(win32.COLOR_HIGHLIGHT) else if (dark) @as(u32, 0x00D6D6D6) else @as(u32, 0x00606060);
    const alpha: u32 = if (self.high_contrast) 255 else 180;
    const pixel = (alpha << 24) | (((color & 0xff) * alpha / 255) << 16) |
        (((color >> 8 & 0xff) * alpha / 255) << 8) | ((color >> 16 & 0xff) * alpha / 255);
    const left = @min(margin, self.width_px - 1);
    const right = @max(left + 1, self.width_px - margin);
    for (@as(usize, @intCast(t.top))..@as(usize, @intCast(t.top + t.height))) |yy| {
        const y: i32 = @intCast(yy);
        for (@as(usize, @intCast(left))..@as(usize, @intCast(right))) |xx| {
            const x: i32 = @intCast(xx);
            const corner_x = @min(x - left, right - 1 - x);
            const corner_y = @min(y - t.top, t.top + t.height - 1 - y);
            if (corner_x < radius and corner_y < radius) {
                const dx = radius - corner_x - 1;
                const dy = radius - corner_y - 1;
                if (dx * dx + dy * dy >= radius * radius) continue;
            }
            pixels[@intCast(y * self.width_px + x)] = pixel;
        }
    }

    var rect: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetWindowRect(self.hwnd, &rect) == 0) return;
    var destination: win32.POINT = .{ .x = rect.left, .y = rect.top };
    var size: win32.SIZE = .{ .cx = self.width_px, .cy = self.height_px };
    var origin: win32.POINT = .{ .x = 0, .y = 0 };
    var blend: win32.BLENDFUNCTION = .{ .BlendOp = 0, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = 1 };
    if (win32.UpdateLayeredWindow(self.hwnd, null, &destination, &size, memory, &origin, 0, &blend, .ALPHA) == 0) {
        log.warn("UpdateLayeredWindow(scrollbar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

fn selfFor(hwnd: win32.HWND) ?*Self {
    const value = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn mouseY(lparam: win32.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    const self = selfFor(hwnd) orelse return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        win32.WM_LBUTTONDOWN => {
            _ = win32.SetFocus(self.surface.hwnd);
            self.reveal();
            const y = mouseY(lparam);
            const t = self.thumb();
            if (y < t.top or y >= t.top + t.height) self.scrollTo(self.rowAt(y - @divTrunc(t.height, 2)));
            self.dragging = true;
            self.drag_start_y = y;
            self.drag_start_top = self.thumb().top;
            _ = win32.SetCapture(hwnd);
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            if (self.dragging) {
                self.scrollTo(self.rowAt(self.drag_start_top + mouseY(lparam) - self.drag_start_y));
            } else self.reveal();
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (self.dragging) {
                self.dragging = false;
                _ = win32.ReleaseCapture();
                self.reveal();
            }
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            self.dragging = false;
            return 0;
        },
        win32.WM_TIMER => {
            if (wparam != timer_id or self.dragging) return 0;
            var point: win32.POINT = undefined;
            var rect: win32.RECT = undefined;
            if (win32.GetCursorPos(&point) != 0 and win32.GetWindowRect(hwnd, &rect) != 0 and
                point.x >= rect.left and point.x < rect.right and point.y >= rect.top and point.y < rect.bottom) return 0;
            self.hide();
            return 0;
        },
        win32.WM_MOUSEWHEEL => return win32.SendMessageW(self.surface.hwnd, msg, wparam, lparam),
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
