//! Window commands for the Win32 runtime: tab, split, and window navigation,
//! tab reordering, split resize/equalize/zoom, and tab activation.

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const SplitDivider = @import("SplitDivider.zig");
const TabBarAccessibility = @import("TabBarAccessibility.zig");
const TabBarController = @import("TabBarController.zig");
const Window = @import("Window.zig");
const WindowLayout = @import("WindowLayout.zig");
const WindowState = @import("WindowState.zig");

const log = std.log.scoped(.win32);

pub fn gotoWindow(
    self: *App,
    target: apprt.Target,
    direction: apprt.action.GotoWindow,
) bool {
    const current = App.targetSurface(target) orelse {
        log.warn("goto_window targeted the application", .{});
        return false;
    };
    if (self.windows.items.len < 2) return false;

    const current_window = self.windowForSurface(current) orelse return false;
    var start: usize = 0;
    for (self.windows.items, 0..) |window, i| {
        if (window == current_window) start = i;
    }

    var offset: usize = 1;
    while (offset < self.windows.items.len) : (offset += 1) {
        const index = switch (direction) {
            .next => (start + offset) % self.windows.items.len,
            .previous => (start + self.windows.items.len - offset) % self.windows.items.len,
        };
        const candidate = self.windows.items[index];
        // The quick terminal has its own toggle and is not a window cycle
        // destination.
        if (candidate.quick) continue;
        if (win32.IsWindowVisible(candidate.hwnd) == 0) continue;
        if (win32.IsIconic(candidate.hwnd) != 0) continue;
        return WindowState.presentSurface(candidate.focusedSurface());
    }
    return false;
}

pub fn gotoTab(
    self: *App,
    target: apprt.Target,
    value: apprt.action.GotoTab,
) bool {
    const surface = App.targetSurface(target) orelse {
        log.warn("goto_tab targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("goto_tab targeted an unowned surface", .{});
        return false;
    };

    const selection: Window.SelectTab = switch (value) {
        .previous => .previous,
        .next => .next,
        .last => .last,
        else => raw: {
            const raw = @backingInt(value);
            if (raw < 0) return false;
            break :raw .{ .n = @intCast(raw) };
        },
    };
    if (!window.selectTab(selection)) return false;
    activateWindowTab(self, window);
    return true;
}

pub fn moveTab(
    self: *App,
    target: apprt.Target,
    value: apprt.action.MoveTab,
) bool {
    const surface = App.targetSurface(target) orelse {
        log.warn("move_tab targeted the application", .{});
        return false;
    };
    const window = surface.rtApp().windowForSurface(surface) orelse {
        log.warn("move_tab targeted an unowned surface", .{});
        return false;
    };

    const old_state = window.stateSurface();
    if (!window.moveTab(surface, value.amount)) return false;
    const new_state = window.stateSurface();
    if (old_state != new_state) WindowState.transferWindowState(old_state, new_state);
    TabBarController.invalidate(window);
    TabBarAccessibility.sync(self, window, false, true);
    return true;
}

pub fn activateWindowTab(self: *App, window: *Window) void {
    SplitDivider.clearPointer(window);
    const focus = window.focusedSurface();
    _ = win32.SetWindowLongPtrW(
        window.hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(focus)),
    );
    WindowLayout.layoutWindow(self, window);
    focus.syncTitle();
    if (QuickTerminal.allowsFocus(focus)) _ = win32.SetFocus(focus.hwnd);
    TabBarAccessibility.sync(self, window, true, false);
}

pub fn gotoSplit(
    self: *App,
    target: apprt.Target,
    direction: apprt.action.GotoSplit,
) bool {
    const current = App.targetSurface(target) orelse {
        log.warn("goto_split targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(current) orelse {
        log.warn("goto_split targeted an unowned surface", .{});
        return false;
    };

    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect for split focus failed: err={d}", .{@backingInt(win32.GetLastError())});
        return false;
    }

    const surface_count = window.surfaceCountFor(current) orelse return false;
    const rects = self.alloc.alloc(Window.LeafRect, surface_count) catch |err| {
        log.warn("failed to allocate split focus layout: {}", .{err});
        return false;
    };
    defer self.alloc.free(rects);

    const focus = window.focusCandidate(
        current,
        switch (direction) {
            .previous => .previous,
            .next => .next,
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
        },
        WindowLayout.windowContentBounds(self, window, client),
        SplitDivider.gap(window),
        rects,
    ) orelse return false;

    window.updateZoomForNavigation(
        focus,
        self.config.@"split-preserve-zoom".navigation,
    );
    WindowLayout.layoutWindow(self, window);

    _ = window.setFocusedSurface(focus);
    _ = win32.SetWindowLongPtrW(
        window.hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(focus)),
    );
    if (QuickTerminal.allowsFocus(focus)) _ = win32.SetFocus(focus.hwnd);
    focus.syncTitle();
    return true;
}

pub fn resizeSplit(
    self: *App,
    target: apprt.Target,
    value: apprt.action.ResizeSplit,
) bool {
    const current = App.targetSurface(target) orelse {
        log.warn("resize_split targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(current) orelse {
        log.warn("resize_split targeted an unowned surface", .{});
        return false;
    };

    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect for split resize failed: err={d}", .{@backingInt(win32.GetLastError())});
        return false;
    }

    const amount: i32 = @intCast(value.amount);
    const changed = window.resizeSplit(
        current,
        switch (value.direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        },
        switch (value.direction) {
            .left, .up => -amount,
            .right, .down => amount,
        },
        WindowLayout.windowContentBounds(self, window, client),
        SplitDivider.gap(window),
    );
    if (!changed) return false;
    WindowLayout.layoutWindow(self, window);
    return true;
}

pub fn equalizeSplits(self: *App, target: apprt.Target) bool {
    const surface = App.targetSurface(target) orelse {
        log.warn("equalize_splits targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("equalize_splits targeted an unowned surface", .{});
        return false;
    };
    if (!window.equalizeSplits()) return false;
    WindowLayout.layoutWindow(self, window);
    return true;
}

pub fn toggleSplitZoom(self: *App, target: apprt.Target) bool {
    const surface = App.targetSurface(target) orelse {
        log.warn("toggle_split_zoom targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("toggle_split_zoom targeted an unowned surface", .{});
        return false;
    };
    if (!window.toggleSplitZoom(surface)) return false;
    WindowLayout.layoutWindow(self, window);
    return true;
}
