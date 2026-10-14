//! Tab and window titles for the Win32 runtime: title actions, the tab-title
//! dialog, focused-window title synchronization, and title-change notification.

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const brand = @import("../../brand.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

const tab_title_dialog_id: usize = 102;
const tab_title_edit_id: i32 = 1001;
const tab_title_capacity: usize = 512;
const dialog_ok_id: u16 = 1;
const dialog_cancel_id: u16 = 2;

pub fn tabTitleChanged(self: *App, surface: *const Surface) void {
    const window = self.windowForSurface(surface) orelse return;
    App.invalidateTabBar(window);
    self.syncTabBarAccessibility(window, false, false);
    App.notifyTabBarChildNameChanged(window, surface);
}

pub fn syncWindowTitle(self: *App, surface: *Surface) void {
    const value = if (self.windowForSurface(surface)) |window|
        window.titleForSurface(surface) orelse surface.title orelse brand.display_name
    else
        surface.title orelse brand.display_name;
    surface.applyTitle(value) catch |err| {
        log.warn("failed to synchronize focused surface title: {}", .{err});
    };
}

pub fn setTitle(target: apprt.Target, value: apprt.action.SetTitle) !bool {
    switch (target) {
        .app => {
            log.warn("set_title targeted the application", .{});
            return false;
        },
        .surface => |surface| {
            try surface.rt_surface.setTitle(value.title);
            return true;
        },
    }
}

pub fn setTabTitle(
    self: *App,
    target: apprt.Target,
    value: apprt.action.SetTitle,
) !bool {
    const surface = App.targetSurface(target) orelse {
        log.warn("set_tab_title targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("set_tab_title targeted an unowned surface", .{});
        return false;
    };
    if (!try window.setTabTitle(self.alloc, surface, value.title)) return false;
    App.invalidateTabBar(window);
    self.syncTabBarAccessibility(window, false, false);
    App.notifyTabBarChildNameChanged(window, surface);
    if (window.focusedSurface() == surface or
        window.tabForSurface(surface) == window.active_tab)
    {
        window.focusedSurface().syncTitle();
    }
    return true;
}

pub fn promptTitle(
    self: *App,
    target: apprt.Target,
    value: apprt.action.PromptTitle,
) !bool {
    if (value != .tab) {
        log.warn("Win32 prompt_title is only implemented for tabs", .{});
        return false;
    }
    const surface = App.targetSurface(target) orelse {
        log.warn("prompt_tab_title targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("prompt_tab_title targeted an unowned surface", .{});
        return false;
    };
    const index = window.tabIndexForSurface(surface) orelse return false;
    return try promptTabTitle(self, window, index);
}

const TabTitleDialogContext = struct {
    initial: [*:0]const u16,
    result: [tab_title_capacity:0]u16 = [_:0]u16{0} ** tab_title_capacity,
    result_len: usize = 0,
    accepted: bool = false,
};

fn tabTitleDialogContext(hwnd: win32.HWND) ?*TabTitleDialogContext {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn tabTitleDialogProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_INITDIALOG => {
            const context: *TabTitleDialogContext = @ptrFromInt(
                @as(usize, @bitCast(lparam)),
            );
            _ = win32.SetWindowLongPtrW(
                hwnd,
                win32.GWLP_USERDATA,
                @bitCast(@intFromPtr(context)),
            );
            _ = win32.SetDlgItemTextW(hwnd, tab_title_edit_id, context.initial);
            _ = win32.SendDlgItemMessageW(
                hwnd,
                tab_title_edit_id,
                win32.EM_SETLIMITTEXT,
                tab_title_capacity - 1,
                0,
            );
            _ = win32.SendDlgItemMessageW(
                hwnd,
                tab_title_edit_id,
                win32.EM_SETSEL,
                0,
                -1,
            );
            return 1;
        },
        win32.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            switch (command) {
                dialog_ok_id => {
                    const context = tabTitleDialogContext(hwnd) orelse return 0;
                    const len = win32.GetDlgItemTextW(
                        hwnd,
                        tab_title_edit_id,
                        &context.result,
                        tab_title_capacity,
                    );
                    context.result_len = @intCast(@max(0, len));
                    context.accepted = true;
                    _ = win32.EndDialog(hwnd, dialog_ok_id);
                    return 1;
                },
                dialog_cancel_id => {
                    _ = win32.EndDialog(hwnd, dialog_cancel_id);
                    return 1;
                },
                else => {},
            }
        },
        win32.WM_CLOSE => {
            _ = win32.EndDialog(hwnd, dialog_cancel_id);
            return 1;
        },
        else => {},
    }
    return 0;
}

pub fn promptTabTitle(self: *App, window: *Window, index: usize) !bool {
    const surface = window.focusedSurfaceAt(index) orelse return false;
    const initial = window.tabTitleAt(index) orelse brand.display_name;
    const initial_wide = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, initial);
    defer self.alloc.free(initial_wide);

    var context: TabTitleDialogContext = .{ .initial = initial_wide.ptr };
    const resource: [*:0]const u16 = @ptrFromInt(tab_title_dialog_id);
    const result = win32.DialogBoxParamW(
        win32.GetModuleHandleW(null),
        resource,
        window.hwnd,
        tabTitleDialogProc,
        @bitCast(@intFromPtr(&context)),
    );
    if (result == -1) {
        log.warn("DialogBoxParamW(tab title) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return false;
    }
    if (!context.accepted) return true;

    const title = try std.unicode.utf16LeToUtf8Alloc(
        self.alloc,
        context.result[0..context.result_len],
    );
    defer self.alloc.free(title);
    if (!try window.setTabTitle(self.alloc, surface, title)) return false;
    App.invalidateTabBar(window);
    self.syncTabBarAccessibility(window, false, false);
    App.notifyTabBarChildNameChanged(window, surface);
    if (window.active_tab == window.tabForSurface(surface).?) {
        window.focusedSurface().syncTitle();
    }
    return true;
}
