//! Win32 tab-bar presentation and pointer interaction. TabBar owns drawing
//! and geometry; Window retains tab, viewport, hover, and drag state.

const std = @import("std");
const win32 = @import("win32").everything;
const brand = @import("../../brand.zig");
const App = @import("App.zig");
const Mouse = @import("Mouse.zig");
const TabBar = @import("TabBar.zig");
const TabBarAccessibility = @import("TabBarAccessibility.zig");
const TabTitles = @import("TabTitles.zig");
const Window = @import("Window.zig");
const WindowLayout = @import("WindowLayout.zig");
const WindowLifecycle = @import("WindowLifecycle.zig");

const log = std.log.scoped(.win32);

pub fn invalidate(window: *const Window) void {
    const hwnd = window.tab_bar_hwnd orelse return;
    if (win32.InvalidateRect(hwnd, null, win32.TRUE) != 0) {
        _ = win32.UpdateWindow(hwnd);
    }
}

pub fn updateViewport(window: *Window, width: i32, height: i32) void {
    window.tab_bar_first_visible = TabBar.ensureVisible(
        width,
        height,
        window.tabCount(),
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        window.activeTabIndex(),
    );
}

fn getTabBarWindow(hwnd: win32.HWND) ?*Window {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn paintTabBar(self: *App, window: *Window, hdc: win32.HDC, width: i32, height: i32) void {
    updateViewport(window, width, height);
    const items = self.alloc.alloc(TabBar.Item, window.tabCount()) catch |err| {
        log.warn("failed to allocate tab bar labels: {}", .{err});
        return;
    };
    defer self.alloc.free(items);

    const active = window.activeTabIndex();
    for (items, 0..) |*item, index| {
        const surface = window.focusedSurfaceAt(index) orelse unreachable;
        item.* = .{
            .title = window.tabTitleAt(index) orelse surface.title orelse brand.display_name,
            .active = index == active,
        };
    }
    TabBar.paint(
        self.alloc,
        hdc,
        width,
        height,
        WindowLayout.windowDpi(window.hwnd),
        self.config,
        self.high_contrast,
        items,
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        window.tab_bar_hover,
    );
}

fn handleTabBarClick(self: *App, window: *Window, x: i32, y: i32) void {
    switch (tabBarHit(window, x, y)) {
        .none => {},
        .tab => |index| {
            if (window.selectTab(.{ .n = index + 1 })) App.activateWindowTab(self, window);
        },
        .close => |index| {
            const surface = window.focusedSurfaceAt(index) orelse return;
            const core = surface.core_surface orelse return;
            _ = WindowLifecycle.closeTab(self, .{ .surface = core }, .this);
        },
        .scroll_previous => {
            if (window.selectTab(.previous)) App.activateWindowTab(self, window);
        },
        .scroll_next => {
            if (window.selectTab(.next)) App.activateWindowTab(self, window);
        },
        .new_tab => {
            const core = window.focusedSurface().core_surface orelse return;
            _ = WindowLifecycle.newTab(self, .{ .surface = core }) catch |err| {
                log.warn("failed to create tab from tab bar: {}", .{err});
                return;
            };
        },
    }
}

fn handleTabBarButtonDown(
    self: *App,
    hwnd: win32.HWND,
    window: *Window,
    x: i32,
    y: i32,
) void {
    const hit = tabBarHit(window, x, y);
    window.tab_bar_pressed = hit;
    window.tab_bar_drag = switch (hit) {
        .tab => |index| .{
            .index = index,
            .start_x = x,
            .start_y = y,
        },
        else => null,
    };
    if (hit == .none) return;

    _ = win32.SetCapture(hwnd);
    if (hit == .tab) {
        const index = hit.tab;
        if (window.selectTab(.{ .n = index + 1 })) App.activateWindowTab(self, window);
    }
}

fn handleTabBarButtonUp(
    self: *App,
    hwnd: win32.HWND,
    window: *Window,
    x: i32,
    y: i32,
) void {
    const pressed = window.tab_bar_pressed;
    const was_dragging = if (window.tab_bar_drag) |drag| drag.active else false;
    window.tab_bar_pressed = .none;
    window.tab_bar_drag = null;
    if (win32.GetCapture() == hwnd and win32.ReleaseCapture() == 0) {
        log.warn("ReleaseCapture(tab bar) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
    }
    if (was_dragging or pressed == .none) return;

    const released = tabBarHit(window, x, y);
    if (!std.meta.eql(pressed, released)) return;
    // A tab label was selected on button down so keyboard focus follows the
    // new surface before a possible drag. Buttons perform their action here.
    if (pressed == .tab) return;
    handleTabBarClick(self, window, x, y);
}

fn handleTabBarDoubleClick(
    self: *App,
    hwnd: win32.HWND,
    window: *Window,
    x: i32,
    y: i32,
) void {
    cancelTabBarPointer(window);
    if (win32.GetCapture() == hwnd) _ = win32.ReleaseCapture();
    const index = switch (tabBarHit(window, x, y)) {
        .tab => |value| value,
        else => return,
    };
    if (window.selectTab(.{ .n = index + 1 })) App.activateWindowTab(self, window);
    _ = TabTitles.promptTabTitle(self, window, index) catch |err| {
        log.warn("failed to prompt for tab title: {}", .{err});
        return;
    };
}

fn updateTabBarDrag(window: *Window, x: i32, y: i32) void {
    const drag = if (window.tab_bar_drag) |*value| value else return;
    if (!drag.active) {
        const threshold_x = win32.GetSystemMetrics(.CXDRAG);
        const threshold_y = win32.GetSystemMetrics(.CYDRAG);
        if (!TabBar.dragThresholdExceeded(drag.*, x, y, threshold_x, threshold_y)) return;
        drag.active = true;
    }

    const hwnd = window.tab_bar_hwnd orelse return;
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(hwnd, &client) == 0) return;
    const hit = TabBar.hitTest(
        client.right - client.left,
        client.bottom - client.top,
        window.tabCount(),
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        x,
        y,
    );
    const destination = switch (hit) {
        .tab => |index| index,
        .close => |index| index,
        .scroll_previous => if (drag.index > 0) drag.index - 1 else return,
        .scroll_next => if (drag.index + 1 < window.tabCount()) drag.index + 1 else return,
        .none, .new_tab => return,
    };
    if (destination == drag.index) return;

    const old_state = window.stateSurface();
    if (!window.moveTabTo(drag.index, destination)) return;
    drag.index = destination;
    const new_state = window.stateSurface();
    if (old_state != new_state) App.transferWindowState(old_state, new_state);
    updateViewport(
        window,
        client.right - client.left,
        client.bottom - client.top,
    );
    window.tab_bar_hover = .{ .tab = destination };
    invalidate(window);
    TabBarAccessibility.sync(window.focusedSurface().rtApp(), window, false, true);
}

fn handleTabBarWheel(
    self: *App,
    hwnd: win32.HWND,
    window: *Window,
    msg: u32,
    wparam: win32.WPARAM,
) void {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(hwnd, &client) == 0) return;
    if (!TabBar.overflows(
        client.right - client.left,
        client.bottom - client.top,
        window.tabCount(),
        window.activeTabIsZoomed(),
    )) return;

    const delta = Mouse.wheelDelta(wparam);
    if (delta == 0) return;
    const selection: Window.SelectTab = if (msg == win32.WM_MOUSEHWHEEL)
        (if (delta > 0) .next else .previous)
    else if (delta > 0)
        .previous
    else
        .next;
    if (window.selectTab(selection)) App.activateWindowTab(self, window);
}

fn cancelTabBarPointer(window: *Window) void {
    window.tab_bar_pressed = .none;
    window.tab_bar_drag = null;
}

fn tabBarHit(window: *const Window, x: i32, y: i32) TabBar.Hit {
    const hwnd = window.tab_bar_hwnd orelse return .none;
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(hwnd, &client) == 0) return .none;
    return TabBar.hitTest(
        client.right - client.left,
        client.bottom - client.top,
        window.tabCount(),
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        x,
        y,
    );
}

fn updateTabBarHover(hwnd: win32.HWND, window: *Window, x: i32, y: i32) void {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(hwnd, &client) == 0) return;
    const hit = TabBar.hitTest(
        client.right - client.left,
        client.bottom - client.top,
        window.tabCount(),
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        x,
        y,
    );
    if (!std.meta.eql(hit, window.tab_bar_hover)) {
        window.tab_bar_hover = hit;
        invalidate(window);
    }

    if (window.tab_bar_tracking_mouse_leave) return;
    var event: win32.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (win32.TrackMouseEvent(&event) != 0) {
        window.tab_bar_tracking_mouse_leave = true;
    }
}

pub fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_GETOBJECT => {
            if (@as(i32, @truncate(lparam)) != TabBarAccessibility.objid_client) {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            const window = getTabBarWindow(hwnd) orelse {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            };
            const accessibility = TabBarAccessibility.forWindow(window) orelse {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            };
            return accessibility.objectResult(wparam);
        },
        TabBarAccessibility.select_message => {
            const window = getTabBarWindow(hwnd) orelse return 0;
            if (wparam == 0 or wparam > window.tabCount()) return 0;
            if (window.selectTab(.{ .n = wparam })) {
                App.activateWindowTab(window.focusedSurface().rtApp(), window);
            }
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = std.mem.zeroes(win32.PAINTSTRUCT);
            const hdc = win32.BeginPaint(hwnd, &ps) orelse {
                _ = win32.EndPaint(hwnd, &ps);
                return 0;
            };
            if (getTabBarWindow(hwnd)) |window| {
                var client: win32.RECT = std.mem.zeroes(win32.RECT);
                if (win32.GetClientRect(hwnd, &client) != 0) {
                    paintTabBar(
                        window.focusedSurface().rtApp(),
                        window,
                        hdc,
                        client.right - client.left,
                        client.bottom - client.top,
                    );
                }
            }
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            if (getTabBarWindow(hwnd)) |window| {
                const bits: usize = @bitCast(lparam);
                handleTabBarButtonUp(
                    window.focusedSurface().rtApp(),
                    hwnd,
                    window,
                    Mouse.signedLowWord(bits),
                    Mouse.signedHighWord(bits),
                );
            }
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            if (getTabBarWindow(hwnd)) |window| {
                const bits: usize = @bitCast(lparam);
                handleTabBarButtonDown(
                    window.focusedSurface().rtApp(),
                    hwnd,
                    window,
                    Mouse.signedLowWord(bits),
                    Mouse.signedHighWord(bits),
                );
            }
            return 0;
        },
        win32.WM_LBUTTONDBLCLK => {
            if (getTabBarWindow(hwnd)) |window| {
                const bits: usize = @bitCast(lparam);
                handleTabBarDoubleClick(
                    window.focusedSurface().rtApp(),
                    hwnd,
                    window,
                    Mouse.signedLowWord(bits),
                    Mouse.signedHighWord(bits),
                );
            }
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            if (getTabBarWindow(hwnd)) |window| {
                const bits: usize = @bitCast(lparam);
                updateTabBarHover(
                    hwnd,
                    window,
                    Mouse.signedLowWord(bits),
                    Mouse.signedHighWord(bits),
                );
                updateTabBarDrag(
                    window,
                    Mouse.signedLowWord(bits),
                    Mouse.signedHighWord(bits),
                );
            }
            return 0;
        },
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            if (getTabBarWindow(hwnd)) |window| {
                handleTabBarWheel(
                    window.focusedSurface().rtApp(),
                    hwnd,
                    window,
                    msg,
                    wparam,
                );
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            if (getTabBarWindow(hwnd)) |window| {
                window.tab_bar_tracking_mouse_leave = false;
                window.tab_bar_hover = .none;
                invalidate(window);
            }
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            if (getTabBarWindow(hwnd)) |window| cancelTabBarPointer(window);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
