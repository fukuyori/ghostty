/// Win32 application runtime for Ghostty. This is a minimal native Windows
/// application using the Win32 API with D3D11 or OpenGL rendering.
const App = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const build_config = @import("../../build_config.zig");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const math = @import("../../math.zig");
const rendererpkg = @import("../../renderer.zig");
const d3d11_buffer = @import("../../renderer/d3d11/buffer.zig");
const D3D11RenderPass = @import("../../renderer/d3d11/RenderPass.zig");
const D3D11Sampler = @import("../../renderer/d3d11/Sampler.zig");
const D3D11Shaders = @import("../../renderer/d3d11/shaders.zig");
const D3D11Texture = @import("../../renderer/d3d11/Texture.zig");
const Backdrop = @import("Backdrop.zig");
const ContextMenu = @import("ContextMenu.zig");
const DirectComposition = @import("DirectComposition.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const TabBarAccessibility = @import("TabBarAccessibility.zig");
const Titlebar = @import("Titlebar.zig");
const Window = @import("Window.zig");
const SearchBar = @import("SearchBar.zig");
const CommandPalette = @import("CommandPalette.zig");
const Scrollbar = @import("Scrollbar.zig");
const FileDrop = @import("FileDrop.zig");
const Mouse = @import("Mouse.zig");

const log = std.log.scoped(.win32);
const WindowList = std.ArrayListUnmanaged(*Window);
const window_class_name = win32.L("GhosttyWindow");
const tab_bar_class_name = win32.L("GhosttyTabBar");
const split_divider_class_name = win32.L("GhosttySplitDivider");
const wakeup_class_name = win32.L("GhosttyWakeup");

/// Parent handle that creates a message-only window. Message-only windows
/// never appear on screen and exist so that posted messages are delivered
/// through DispatchMessage, including from inside modal loops.
const hwnd_message: win32.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

/// Renderer recovery cycles the app schedules for one surface before it
/// stops and leaves the surface blank. Each cycle is a bounded, backed-off
/// series of attempts on the renderer thread. A later power resume resets
/// the budget.
const gpu_recovery_max_cycles: u32 = 3;
const default_window_title = win32.L("Ghostty");
const icon_resource_id: usize = 1;
const tab_title_dialog_id: usize = 102;
const tab_title_edit_id: i32 = 1001;
const tab_title_capacity: usize = 512;
const dialog_ok_id: u16 = 1;
const dialog_cancel_id: u16 = 2;
const split_divider_logical_gap: i32 = 1;
const split_divider_high_contrast_logical_gap: i32 = 2;
const split_divider_hit_slop: i32 = 4;
// WinEvent accessibility event and object identifiers from winuser.h.
const event_object_reorder: u32 = 0x8004;
const event_object_selection: u32 = 0x8006;
const event_object_namechange: u32 = 0x800C;
const objid_client: i32 = -4;
const childid_self: i32 = 0;

/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP = win32.WM_USER + 1;

/// A surface can request closure from a core callback. Route it through the
/// window thread so confirmation and native resource teardown happen there.
const WM_CLOSE_SURFACE = win32.WM_USER + 2;

/// Test-only request used by the Windows regression script. It is ignored
/// unless the process explicitly enables GHOSTTY_TEST_DEVICE_RECOVERY.
const WM_TEST_RECOVER_RENDERER = win32.WM_USER + 3;
const WM_TEST_RECOVERY_STATUS = win32.WM_USER + 4;

/// Opening a modal dialog directly from a core key callback lets the modal
/// message loop destroy that callback's surface before the callback returns.
/// Post the request so the key callback unwinds before the dialog is shown.
const WM_SHOW_COMMAND_PALETTE = win32.WM_USER + 5;

/// VK_PROCESSKEY. Windows substitutes this virtual key in keyboard messages
/// for every keystroke an active IME consumes, leaving the physical scan
/// code untouched.
const vk_processkey: win32.WPARAM = @intFromEnum(win32.VK_PROCESSKEY);

core_app: *CoreApp,
config: *Config,
alloc: Allocator,
running: bool = true,
thread_id: u32,
/// Message-only window that receives core wakeup requests. Thread messages
/// are discarded while a modal loop (MessageBox, window move or size) runs,
/// so wakeups are posted to this window instead. Null falls back to thread
/// messages.
wakeup_hwnd: ?win32.HWND = null,
windows: WindowList = .empty,
backdrop_runtime: Backdrop.Runtime = .{},
high_contrast: bool = false,
test_device_recovery: bool = false,
test_device_recovery_failures: u32 = 0,
power_suspended: bool = false,
command_palette_owner: ?*Surface = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;
    const config_ptr = try alloc.create(Config);
    errdefer alloc.destroy(config_ptr);
    config_ptr.* = try Config.load(alloc);
    errdefer config_ptr.deinit();
    var environ = try global.environMap();
    defer environ.deinit();
    // The regression hooks exist only in builds made with
    // -Dwin32-test-hooks=true; release builds ignore the environment.
    const test_device_recovery = if (comptime build_config.win32_test_hooks)
        if (environ.get("GHOSTTY_TEST_DEVICE_RECOVERY")) |value|
            std.mem.eql(u8, value, "1")
        else
            false
    else
        false;
    const test_device_recovery_failures = if (test_device_recovery)
        if (environ.get("GHOSTTY_TEST_DEVICE_RECOVERY_FAILURES")) |value|
            std.fmt.parseUnsigned(u32, value, 10) catch 0
        else
            0
    else
        0;

    self.* = .{
        .core_app = core_app,
        .config = config_ptr,
        .alloc = alloc,
        .thread_id = win32.GetCurrentThreadId(),
        .high_contrast = highContrastEnabled(),
        .test_device_recovery = test_device_recovery,
        .test_device_recovery_failures = test_device_recovery_failures,
    };
    errdefer self.windows.deinit(self.alloc);
    errdefer self.backdrop_runtime.deinit();

    try registerWindowClass();
    self.wakeup_hwnd = createWakeupWindow(self) catch |err| wakeup: {
        log.warn("wakeup window unavailable; falling back to thread messages: {}", .{err});
        break :wakeup null;
    };
    errdefer self.destroyWakeupWindow();
    try self.createWindow(.{});
    self.showConfigDiagnostics(.app, self.config);
}

fn createWakeupWindow(self: *App) !win32.HWND {
    const hinstance = win32.GetModuleHandleW(null);
    const hwnd = win32.CreateWindowExW(
        .{},
        wakeup_class_name,
        win32.L(""),
        .{},
        0,
        0,
        0,
        0,
        hwnd_message,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("CreateWindowExW(wakeup) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
    _ = win32.SetWindowLongPtrW(
        hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );
    return hwnd;
}

fn destroyWakeupWindow(self: *App) void {
    const hwnd = self.wakeup_hwnd orelse return;
    self.wakeup_hwnd = null;
    if (win32.DestroyWindow(hwnd) == 0) {
        log.warn("DestroyWindow(wakeup) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

fn wakeupWndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (msg == WM_WAKEUP) {
        const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (ptr != 0) {
            const app: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            app.core_app.tick(app) catch |err| {
                log.err("core app tick failed: {}", .{err});
            };
        }
        return 0;
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn run(self: *App) !void {
    log.info("starting Win32 event loop", .{});

    while (self.running) {
        var msg: win32.MSG = std.mem.zeroes(win32.MSG);
        const ret = win32.GetMessageW(&msg, null, 0, 0);
        if (ret == 0) {
            self.running = false;
            break;
        }
        if (ret == -1) {
            log.err("GetMessage failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return error.Win32Error;
        }
        // Thread-message fallback used only when the wakeup window could
        // not be created. Window-targeted wakeups go through DispatchMessage.
        if (msg.hwnd == null and msg.message == WM_WAKEUP) {
            self.core_app.tick(self) catch |err| {
                log.err("core app tick failed: {}", .{err});
            };
            continue;
        }
        const search_handled = search: {
            for (self.windows.items) |window| {
                var surfaces = window.surfaceIterator();
                while (surfaces.next()) |surface| {
                    if (surface.search_bar) |bar| {
                        if (bar.filterMessage(&msg)) break :search true;
                    }
                }
            }
            break :search false;
        };
        if (search_handled) continue;
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    while (self.windows.pop()) |window| {
        disableWindowBackgroundBlur(window);
        deinitTabBarAccessibility(window);
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| {
            surface.deinit();
            if (win32.DestroyWindow(surface.hwnd) == 0) {
                log.warn("DestroyWindow(surface) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            }
        }
        if (win32.DestroyWindow(window.hwnd) == 0) {
            log.warn("DestroyWindow(window) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| self.alloc.destroy(surface);
        window.deinit(self.alloc);
        self.alloc.destroy(window);
    }
    self.windows.deinit(self.alloc);
    self.destroyWakeupWindow();
    self.backdrop_runtime.deinit();
    self.config.deinit();
    self.alloc.destroy(self.config);
}

pub fn wakeup(self: *App) void {
    if (self.wakeup_hwnd) |hwnd| {
        if (win32.PostMessageW(hwnd, WM_WAKEUP, 0, 0) == 0) {
            log.warn("PostMessage(WM_WAKEUP) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        return;
    }
    if (win32.PostThreadMessageW(self.thread_id, WM_WAKEUP, 0, 0) == 0) {
        log.warn("PostThreadMessage(WM_WAKEUP) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

pub fn requestSurfaceClose(_: *App, surface: *Surface, confirm: bool) void {
    // The core may request the same close more than once before the posted
    // request runs (a child exit racing a close_tab, for example). The first
    // request frees the surface, so a second post would dereference freed
    // memory when it is processed.
    if (surface.close_requested) return;
    surface.close_requested = true;
    if (win32.PostMessageW(
        surface.windowHwnd(),
        WM_CLOSE_SURFACE,
        @intFromBool(confirm),
        @bitCast(@intFromPtr(surface)),
    ) == 0) {
        log.warn("PostMessage(WM_CLOSE_SURFACE) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

fn closeSurface(self: *App, surface: *Surface, confirm: bool) void {
    if (confirm and !confirmSurfaceClose(surface.windowHwnd())) return;

    const window = self.windowForSurface(surface) orelse {
        log.warn("close requested for an unowned surface", .{});
        return;
    };
    clearWindowSplitPointer(window);
    const close_window = window.totalSurfaceCount() == 1;
    const tab_surface_count = window.surfaceCountFor(surface) orelse return;
    const close_tab = !close_window and tab_surface_count == 1;
    if (close_tab) {
        const index = window.tabIndexForSurface(surface) orelse return;
        _ = self.destroyTabAt(window, index);
        return;
    }

    const was_state_surface = window.stateSurface() == surface;
    // A split can close inside a background tab, for example when its shell
    // exits. Focus and the window's focused-surface pointer must then stay
    // with the active tab; focusing the hidden replacement would switch tabs.
    const in_active_tab = window.tabForSurface(surface) == window.active_tab;
    const next_focus = if (close_window)
        null
    else
        window.removeSurface(self.alloc, surface) catch |err| {
            log.warn("failed to remove surface from its window: {}", .{err});
            return;
        };

    if (!close_window and was_state_surface) {
        transferWindowState(surface, window.stateSurface());
    }

    if (next_focus) |focus| {
        if (in_active_tab) {
            _ = win32.SetWindowLongPtrW(
                window.hwnd,
                win32.GWLP_USERDATA,
                @bitCast(@intFromPtr(focus)),
            );
        }
    }

    if (close_window) disableWindowBackgroundBlur(window);
    if (close_window) deinitTabBarAccessibility(window);

    // Keep the child HWND and its DC alive until the renderer has stopped and
    // the surface has released all native rendering resources.
    surface.deinit();
    if (win32.DestroyWindow(surface.hwnd) == 0) {
        log.warn("DestroyWindow(surface) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }

    if (close_window) {
        if (win32.DestroyWindow(window.hwnd) == 0) {
            log.warn("DestroyWindow(window) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        self.alloc.destroy(surface);
        std.debug.assert(self.removeWindow(window));
        window.deinit(self.alloc);
        self.alloc.destroy(window);
        return;
    }

    const focus = next_focus.?;
    self.alloc.destroy(surface);
    if (in_active_tab) {
        _ = win32.SetFocus(focus.hwnd);
    } else {
        // The background tab's own focused surface was already advanced by
        // Tab.removeSurface; only its title in the tab bar can change.
        invalidateTabBar(window);
    }
    self.layoutWindow(window);
}

fn destroyTabAt(self: *App, window: *Window, index: usize) bool {
    clearWindowSplitPointer(window);
    const tab_surfaces = window.surfacesAt(index) orelse return false;
    const surfaces = self.alloc.dupe(*Surface, tab_surfaces) catch |err| {
        log.warn("failed to allocate tab close list: {}", .{err});
        return false;
    };
    defer self.alloc.free(surfaces);

    const old_state = window.stateSurface();
    var state_will_close = false;
    for (surfaces) |surface| {
        if (surface == old_state) state_will_close = true;
    }

    const focus = window.removeTabAt(self.alloc, index) catch |err| {
        log.warn("failed to remove tab: {}", .{err});
        return false;
    };
    if (state_will_close) transferWindowState(old_state, window.stateSurface());

    _ = win32.SetWindowLongPtrW(
        window.hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(focus)),
    );
    for (surfaces) |surface| {
        surface.deinit();
        if (win32.DestroyWindow(surface.hwnd) == 0) {
            log.warn("DestroyWindow(tab surface) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        self.alloc.destroy(surface);
    }

    self.layoutWindow(window);
    _ = win32.SetFocus(focus.hwnd);
    focus.syncTitle();
    self.syncTabBarAccessibility(window, true, true);
    return true;
}

fn removeWindow(self: *App, window: *Window) bool {
    for (self.windows.items, 0..) |candidate, i| {
        if (candidate != window) continue;
        _ = self.windows.swapRemove(i);
        return true;
    }
    return false;
}

fn windowForSurface(self: *App, surface: *const Surface) ?*Window {
    for (self.windows.items) |window| {
        if (window.contains(surface)) return window;
    }
    return null;
}

pub fn surfaceIsFocused(self: *App, surface: *const Surface) bool {
    const window = self.windowForSurface(surface) orelse return false;
    return window.focusedSurface() == surface;
}

pub fn tabTitleChanged(self: *App, surface: *const Surface) void {
    const window = self.windowForSurface(surface) orelse return;
    invalidateTabBar(window);
    self.syncTabBarAccessibility(window, false, false);
    notifyTabBarChildNameChanged(window, surface);
}

pub fn syncWindowTitle(self: *App, surface: *Surface) void {
    const value = if (self.windowForSurface(surface)) |window|
        window.titleForSurface(surface) orelse surface.title orelse "Ghostty"
    else
        surface.title orelse "Ghostty";
    surface.applyTitle(value) catch |err| {
        log.warn("failed to synchronize focused surface title: {}", .{err});
    };
}

fn windowForHwnd(self: *App, hwnd: win32.HWND) ?*Window {
    for (self.windows.items) |window| {
        if (window.hwnd == hwnd) return window;
    }
    return null;
}

fn confirmSurfaceClose(hwnd: win32.HWND) bool {
    const caption = std.unicode.utf8ToUtf16LeStringLiteral("Close Terminal?");
    const message = std.unicode.utf8ToUtf16LeStringLiteral(
        "The terminal still has a running process. If you close the terminal the process will be killed.",
    );
    const style: win32.MESSAGEBOX_STYLE = .{
        .YESNO = 1,
        .ICONHAND = 1,
        .ICONQUESTION = 1,
        .DEFBUTTON2 = 1,
    };
    return win32.MessageBoxW(hwnd, message, caption, style) == win32.IDYES;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            // Match GTK and macOS: a running process in any surface asks
            // once before every terminal session is terminated.
            if (self.quitConfirmationHwnd()) |hwnd| {
                if (!confirmAllWindowsClose(hwnd)) return true;
            }
            win32.PostQuitMessage(0);
            return true;
        },
        .quit_timer => {
            if (value == .start) win32.PostQuitMessage(0);
            return true;
        },
        .set_title => switch (target) {
            .app => {
                log.warn("set_title targeted the application", .{});
                return false;
            },
            .surface => |surface| {
                try surface.rt_surface.setTitle(value.title);
                return true;
            },
        },
        .set_tab_title => return try self.setTabTitle(target, value),
        .start_search => {
            const surface = targetSurface(target) orelse return false;
            if (surface.search_bar == null) {
                const bar = try self.alloc.create(SearchBar);
                errdefer self.alloc.destroy(bar);
                try bar.init(surface);
                surface.search_bar = bar;
            }
            const bar = surface.search_bar.?;
            try bar.start(value.needle);
            if (self.windowForSurface(surface)) |window| self.layoutWindow(window);
            bar.focus();
            return true;
        },
        .end_search => {
            const surface = targetSurface(target) orelse return false;
            if (surface.search_bar) |bar| bar.stop();
            if (self.windowForSurface(surface)) |window| self.layoutWindow(window);
            return true;
        },
        .search_total, .search_selected => {
            const surface = targetSurface(target) orelse return false;
            if (surface.search_bar) |bar| {
                if (action == .search_total) bar.total = value.total else bar.selected = value.selected;
                bar.updateStatus();
            }
            return true;
        },
        .scrollbar => {
            const surface = targetSurface(target) orelse return false;
            if (surface.scrollbar) |bar| bar.update(value);
            return true;
        },
        .mouse_shape => {
            const surface = targetSurface(target) orelse return false;
            surface.mouse_shape = value;
            Mouse.refresh(surface);
            return true;
        },
        .mouse_visibility => {
            const surface = targetSurface(target) orelse return false;
            surface.mouse_visible = value == .visible;
            Mouse.refresh(surface);
            return true;
        },
        .prompt_title => return try self.promptTitle(target, value),
        .toggle_command_palette => {
            const surface = targetSurface(target) orelse return false;
            if (win32.PostMessageW(surface.hwnd, WM_SHOW_COMMAND_PALETTE, 0, 0) == 0) {
                log.warn("PostMessage(WM_SHOW_COMMAND_PALETTE) failed: err={d}", .{
                    @intFromEnum(win32.GetLastError()),
                });
                return false;
            }
            return true;
        },
        .new_window => {
            try self.createWindow(.{});
            return true;
        },
        .new_tab => return try self.newTab(target),
        .close_tab => return self.closeTab(target, value),
        .goto_tab => return self.gotoTab(target, value),
        .move_tab => return self.moveTab(target, value),
        .new_split => return try self.newSplit(target, value),
        .goto_split => return self.gotoSplit(target, value),
        .resize_split => return self.resizeSplit(target, value),
        .equalize_splits => return self.equalizeSplits(target),
        .toggle_split_zoom => return self.toggleSplitZoom(target),
        .close_window => return self.closeWindow(target),
        .close_all_windows => return self.closeAllWindows(),
        .goto_window => return self.gotoWindow(target, value),
        .present_terminal => return presentTerminal(target),
        .toggle_visibility => return self.toggleVisibility(),
        .toggle_maximize => return toggleMaximize(target),
        .toggle_fullscreen => return toggleFullscreen(target, value),
        .toggle_window_decorations => return toggleWindowDecorations(target),
        .float_window => return floatWindow(target, value),
        .initial_size => return setInitialSize(target, value),
        .reset_window_size => return resetWindowSize(target),
        .open_url => return self.openUrl(target, value),
        .open_config => return try self.openConfig(target, value),
        .reload_config => {
            try self.reloadConfig(target, value);
            return true;
        },
        .renderer_health => return try recoverRenderer(target, value),
        .config_change => {
            switch (target) {
                .surface => |core| {
                    const state = windowStateSurface(core.rt_surface);
                    const decorated = value.config.@"window-decoration" != .none;
                    if (!setWindowDecorations(state, decorated)) {
                        log.warn("failed to apply window-decoration setting", .{});
                    }
                    Titlebar.apply(state.windowHwnd(), value.config, self.high_contrast);
                    updateWindowBackgroundBlur(state, value.config);
                    try self.configureScrollbar(core.rt_surface, value.config);
                    if (self.windowForSurface(state)) |window| self.layoutWindow(window);
                },
                .app => {
                    const config = try value.config.clone(self.alloc);
                    self.config.deinit();
                    self.config.* = config;
                    for (self.windows.items) |window| self.layoutWindow(window);
                },
            }
            return true;
        },
        else => return false,
    }
}

fn configureScrollbar(self: *App, surface: *Surface, config: *const Config) !void {
    const enabled = config.scrollbar != .never;
    if (enabled) {
        if (surface.scrollbar) |bar| {
            bar.setAppearance(config.background, self.high_contrast);
            return;
        }
        const bar = try self.alloc.create(Scrollbar);
        errdefer self.alloc.destroy(bar);
        try bar.init(surface, config.background, self.high_contrast);
        surface.scrollbar = bar;
    } else if (surface.scrollbar) |bar| {
        bar.deinit();
        self.alloc.destroy(bar);
        surface.scrollbar = null;
    }
}

fn showCommandPalette(self: *App, source: *Surface) anyerror!void {
    if (self.command_palette_owner != null) return;
    const owner = self.windowForSurface(source) orelse return;
    const source_id = (source.core_surface orelse return).id;
    self.command_palette_owner = source;
    defer self.command_palette_owner = null;

    var jumps: std.ArrayListUnmanaged(CommandPalette.Jump) = .empty;
    defer jumps.deinit(self.alloc);
    for (self.windows.items) |window| {
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| {
            const core = surface.core_surface orelse continue;
            const title = window.titleForSurface(surface) orelse "Untitled";
            try jumps.append(self.alloc, .{ .surface = surface, .id = core.id, .title = title });
        }
    }

    var palette = try CommandPalette.init(self.alloc, self.config, jumps.items);
    defer palette.deinit();
    const selected_opt = palette.show(owner.hwnd);
    if (self.windowForSurface(source)) |window| {
        if (source.core_surface) |core| {
            if (core.id == source_id and window.focusedSurface() == source) {
                _ = win32.SetFocus(source.hwnd);
            }
        }
    }
    const selected = selected_opt orelse return;
    const entry = palette.entries.items[selected];
    switch (entry.kind) {
        .action => |action| {
            // A shell can close its pane while the modal dialog pumps messages.
            if (self.windowForSurface(source) == null) return;
            const core = source.core_surface orelse return;
            if (core.id != source_id) return;
            _ = try core.performBindingAction(action);
        },
        .jump => |jump| {
            const window = self.windowForSurface(jump.surface) orelse return;
            const core = jump.surface.core_surface orelse return;
            if (core.id != jump.id) return;
            _ = window.setFocusedSurface(jump.surface);
            activateWindowTab(self, window);
            _ = presentSurface(jump.surface);
        },
    }
}

fn recoverRenderer(target: apprt.Target, health: rendererpkg.Health) !bool {
    if (comptime build_config.renderer != .d3d11) return false;

    const surface = targetSurface(target) orelse {
        log.warn("renderer_health targeted the application", .{});
        return false;
    };
    if (health == .healthy) {
        surface.gpu_recovery_cycles = 0;
        log.info("D3D11 renderer recovered", .{});
        return true;
    }

    // The renderer thread reports unhealthy both when a frame first detects
    // device loss and after every attempt of a recovery cycle failed. Bound
    // the number of cycles so a permanently lost device does not rebuild
    // forever; a later power resume resets the budget.
    if (surface.gpu_recovery_cycles >= gpu_recovery_max_cycles) {
        log.err(
            "D3D11 renderer recovery exhausted after {d} cycles; rendering stays stopped",
            .{surface.gpu_recovery_cycles},
        );
        return true;
    }
    surface.gpu_recovery_cycles += 1;
    log.warn(
        "D3D11 renderer is unhealthy; scheduling device recovery cycle={d}/{d}",
        .{ surface.gpu_recovery_cycles, gpu_recovery_max_cycles },
    );
    const core = surface.core_surface orelse return false;
    try core.recoverRenderer();
    return true;
}

fn handlePowerBroadcast(self: *App, event: u32) void {
    if (event == win32.PBT_APMSUSPEND) {
        if (!self.power_suspended) log.info("Windows power suspend detected", .{});
        self.power_suspended = true;
        return;
    }

    if (!isPowerResumeEvent(event) or !self.power_suspended) return;
    self.power_suspended = false;

    if (comptime build_config.renderer != .d3d11) return;

    var scheduled: usize = 0;
    for (self.windows.items) |window| {
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| {
            const core = surface.core_surface orelse continue;
            surface.gpu_recovery_cycles = 0;
            core.recoverRenderer() catch |err| {
                log.err("failed to schedule renderer recovery after power resume: {}", .{err});
                continue;
            };
            scheduled += 1;
        }
    }
    log.info(
        "Windows power resume detected; scheduled renderer recovery surfaces={d}",
        .{scheduled},
    );
}

fn isPowerResumeEvent(event: u32) bool {
    return switch (event) {
        win32.PBT_APMRESUMECRITICAL,
        win32.PBT_APMRESUMESUSPEND,
        win32.PBT_APMRESUMESTANDBY,
        win32.PBT_APMRESUMEAUTOMATIC,
        => true,
        else => false,
    };
}

fn setTabTitle(
    self: *App,
    target: apprt.Target,
    value: apprt.action.SetTitle,
) !bool {
    const surface = targetSurface(target) orelse {
        log.warn("set_tab_title targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("set_tab_title targeted an unowned surface", .{});
        return false;
    };
    if (!try window.setTabTitle(self.alloc, surface, value.title)) return false;
    invalidateTabBar(window);
    self.syncTabBarAccessibility(window, false, false);
    notifyTabBarChildNameChanged(window, surface);
    if (window.focusedSurface() == surface or
        window.tabForSurface(surface) == window.active_tab)
    {
        window.focusedSurface().syncTitle();
    }
    return true;
}

fn promptTitle(
    self: *App,
    target: apprt.Target,
    value: apprt.action.PromptTitle,
) !bool {
    if (value != .tab) {
        log.warn("Win32 prompt_title is only implemented for tabs", .{});
        return false;
    }
    const surface = targetSurface(target) orelse {
        log.warn("prompt_tab_title targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("prompt_tab_title targeted an unowned surface", .{});
        return false;
    };
    const index = window.tabIndexForSurface(surface) orelse return false;
    return try self.promptTabTitle(window, index);
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

fn promptTabTitle(self: *App, window: *Window, index: usize) !bool {
    const surface = window.focusedSurfaceAt(index) orelse return false;
    const initial = window.tabTitleAt(index) orelse "Ghostty";
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
    invalidateTabBar(window);
    self.syncTabBarAccessibility(window, false, false);
    notifyTabBarChildNameChanged(window, surface);
    if (window.active_tab == window.tabForSurface(surface).?) {
        window.focusedSurface().syncTitle();
    }
    return true;
}

fn closeWindow(self: *App, target: apprt.Target) bool {
    const surface = targetSurface(target) orelse {
        log.warn("close_window targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("close_window targeted an unowned surface", .{});
        return false;
    };
    return self.closeOwnedWindow(window);
}

fn closeTab(
    self: *App,
    target: apprt.Target,
    mode: apprt.action.CloseTabMode,
) bool {
    const surface = targetSurface(target) orelse {
        log.warn("close_tab targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("close_tab targeted an unowned surface", .{});
        return false;
    };
    const target_index = window.tabIndexForSurface(surface) orelse return false;

    if (window.tabCount() == 1) {
        if (mode != .this) return false;
        return self.closeOwnedWindow(window);
    }

    var selected_count: usize = 0;
    var needs_confirmation = false;
    for (0..window.tabCount()) |index| {
        if (!tabSelectedForClose(index, target_index, mode)) continue;
        selected_count += 1;
        const surfaces = window.surfacesAt(index) orelse continue;
        for (surfaces) |candidate| {
            const core = candidate.core_surface orelse continue;
            if (core.needsConfirmQuit()) needs_confirmation = true;
        }
    }
    if (selected_count == 0) return false;
    if (needs_confirmation and !confirmSurfaceClose(window.hwnd)) return true;

    // Defer native destruction until the current key/action callback returns.
    // Every request is posted before the message loop can mutate tab indexes.
    for (0..window.tabCount()) |index| {
        if (!tabSelectedForClose(index, target_index, mode)) continue;
        const surfaces = window.surfacesAt(index) orelse continue;
        for (surfaces) |candidate| self.requestSurfaceClose(candidate, false);
    }
    return true;
}

fn tabSelectedForClose(
    index: usize,
    target_index: usize,
    mode: apprt.action.CloseTabMode,
) bool {
    return switch (mode) {
        .this => index == target_index,
        .other => index != target_index,
        .right => index > target_index,
    };
}

fn closeOwnedWindow(self: *App, window: *Window) bool {
    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |surface| {
        const core = surface.core_surface orelse continue;
        if (!core.needsConfirmQuit()) continue;
        if (!confirmSurfaceClose(window.hwnd)) return true;
        break;
    }

    // Post every close before processing any of them so the surface list is
    // stable throughout this loop.
    surfaces = window.surfaceIterator();
    while (surfaces.next()) |surface| {
        self.requestSurfaceClose(surface, false);
    }
    return true;
}

fn closeAllWindows(self: *App) bool {
    if (self.windows.items.len == 0) return false;

    // Match the native app behavior: ask once for the complete operation,
    // rather than showing one confirmation for every running terminal.
    if (self.quitConfirmationHwnd()) |hwnd| {
        if (!confirmAllWindowsClose(hwnd)) return true;
    }

    // Closing is posted to the message queue. The list therefore remains
    // stable throughout this loop and each close follows normal teardown.
    for (self.windows.items) |window| {
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| {
            self.requestSurfaceClose(surface, false);
        }
    }
    return true;
}

/// The window that should own a quit confirmation dialog, or null when no
/// surface reports a running process that would be killed.
fn quitConfirmationHwnd(self: *App) ?win32.HWND {
    for (self.windows.items) |window| {
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| {
            const core = surface.core_surface orelse continue;
            if (core.needsConfirmQuit()) return window.hwnd;
        }
    }
    return null;
}

fn confirmAllWindowsClose(hwnd: win32.HWND) bool {
    const message = win32.L("All terminal sessions will be terminated. Close all windows?");
    const caption = win32.L("Close All Windows?");
    const style: win32.MESSAGEBOX_STYLE = .{
        // MB_ICONWARNING is the combined 0x30 value in Win32.
        .ICONHAND = 1,
        .ICONQUESTION = 1,
        .YESNO = 1,
        .DEFBUTTON2 = 1,
    };
    return win32.MessageBoxW(hwnd, message, caption, style) == win32.IDYES;
}

fn presentTerminal(target: apprt.Target) bool {
    const surface = targetSurface(target) orelse {
        log.warn("present_terminal targeted the application", .{});
        return false;
    };
    return presentSurface(surface);
}

fn presentSurface(surface: *Surface) bool {
    const hwnd = surface.windowHwnd();
    const state = windowStateSurface(surface);
    state.hidden_by_visibility_toggle = false;
    state.focused_before_visibility_toggle = false;
    if (win32.IsIconic(hwnd) != 0) {
        _ = win32.ShowWindow(hwnd, win32.SW_RESTORE);
    } else if (win32.IsWindowVisible(hwnd) == 0) {
        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    }

    // Windows can refuse foreground activation when another process owns the
    // foreground lock. The terminal was still presented, so this does not
    // make the action itself fail.
    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.SetFocus(surface.hwnd);
    return true;
}

fn toggleVisibility(self: *App) bool {
    var restore_any = false;
    for (self.windows.items) |window| {
        const state = window.stateSurface();
        if (state.hidden_by_visibility_toggle) {
            restore_any = true;
            break;
        }
    }

    if (restore_any) {
        var first: ?*Surface = null;
        var focus: ?*Surface = null;
        for (self.windows.items) |window| {
            const state = window.stateSurface();
            if (!state.hidden_by_visibility_toggle) continue;
            state.hidden_by_visibility_toggle = false;
            _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNA);
            if (first == null) first = window.focusedSurface();
            if (state.focused_before_visibility_toggle) focus = window.focusedSurface();
            state.focused_before_visibility_toggle = false;
        }
        if (focus orelse first) |surface| _ = presentSurface(surface);
        return true;
    }

    const focused = self.core_app.focusedSurface();
    if (focused) |core| {
        for (self.windows.items) |window| {
            var surfaces = window.surfaceIterator();
            while (surfaces.next()) |surface| {
                if (surface.core_surface != core) continue;
                if (window.stateSurface().fullscreen) return true;
                break;
            }
        }
    }

    var hidden_any = false;
    for (self.windows.items) |window| {
        const state = window.stateSurface();
        if (win32.IsWindowVisible(window.hwnd) == 0) continue;
        state.hidden_by_visibility_toggle = true;
        state.focused_before_visibility_toggle = if (focused) |core| focused_in_window: {
            var surfaces = window.surfaceIterator();
            while (surfaces.next()) |candidate| {
                if (candidate.core_surface == core) break :focused_in_window true;
            }
            break :focused_in_window false;
        } else false;
        _ = win32.ShowWindow(window.hwnd, win32.SW_HIDE);
        hidden_any = true;
    }
    return hidden_any;
}

fn gotoWindow(
    self: *App,
    target: apprt.Target,
    direction: apprt.action.GotoWindow,
) bool {
    const current = targetSurface(target) orelse {
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
        if (win32.IsWindowVisible(candidate.hwnd) == 0) continue;
        if (win32.IsIconic(candidate.hwnd) != 0) continue;
        return presentSurface(candidate.focusedSurface());
    }
    return false;
}

fn targetSurface(target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |surface| surface.rt_surface,
    };
}

/// Window-level state is kept on the first surface while Surface remains the
/// runtime-facing apprt type. All splits in a window must resolve through the
/// same state holder so actions don't depend on which child currently has
/// focus.
fn windowStateSurface(surface: *Surface) *Surface {
    const app = surface.rtApp();
    const window = app.windowForSurface(surface) orelse return surface;
    return window.stateSurface();
}

fn transferWindowState(from: *Surface, to: *Surface) void {
    std.debug.assert(from.windowHwnd() == to.windowHwnd());
    to.initial_client_size = from.initial_client_size;
    to.shown = from.shown;
    to.default_maximized = from.default_maximized;
    to.default_fullscreen = from.default_fullscreen;
    to.fullscreen = from.fullscreen;
    to.windowed_style = from.windowed_style;
    to.windowed_placement = from.windowed_placement;
    to.decorated = from.decorated;
    to.always_on_top = from.always_on_top;
    to.hidden_by_visibility_toggle = from.hidden_by_visibility_toggle;
    to.focused_before_visibility_toggle = from.focused_before_visibility_toggle;
}

fn toggleMaximize(target: apprt.Target) bool {
    const target_surface = targetSurface(target) orelse {
        log.warn("toggle_maximize targeted the application", .{});
        return false;
    };
    const surface = windowStateSurface(target_surface);
    if (surface.fullscreen) return true;
    const hwnd = surface.windowHwnd();

    _ = win32.ShowWindow(
        hwnd,
        if (win32.IsZoomed(hwnd) != 0)
            win32.SW_RESTORE
        else
            win32.SW_MAXIMIZE,
    );
    return true;
}

fn toggleFullscreen(
    target: apprt.Target,
    mode: apprt.action.Fullscreen,
) bool {
    _ = mode;
    const target_surface = targetSurface(target) orelse {
        log.warn("toggle_fullscreen targeted the application", .{});
        return false;
    };
    const surface = windowStateSurface(target_surface);
    return setFullscreen(surface, !surface.fullscreen);
}

fn setFullscreen(surface: *Surface, enabled: bool) bool {
    if (surface.fullscreen == enabled) return true;
    return if (enabled)
        enterFullscreen(surface)
    else
        leaveFullscreen(surface);
}

fn enterFullscreen(surface: *Surface) bool {
    const hwnd = surface.windowHwnd();
    var placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (win32.GetWindowPlacement(hwnd, &placement) == 0) {
        log.warn("GetWindowPlacement failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    const style = getWindowStyle(hwnd) orelse return false;

    const monitor = win32.MonitorFromWindow(
        hwnd,
        win32.MONITOR_DEFAULTTONEAREST,
    ) orelse {
        log.warn("MonitorFromWindow failed", .{});
        return false;
    };
    var info: win32.MONITORINFO = .{
        .cbSize = @sizeOf(win32.MONITORINFO),
        .rcMonitor = std.mem.zeroes(win32.RECT),
        .rcWork = std.mem.zeroes(win32.RECT),
        .dwFlags = 0,
    };
    if (win32.GetMonitorInfoW(monitor, &info) == 0) {
        log.warn("GetMonitorInfoW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    const fullscreen_style = styleWithDecorations(style, false);
    if (!setWindowStyle(hwnd, fullscreen_style)) return false;

    const rect = info.rcMonitor;
    if (win32.SetWindowPos(
        hwnd,
        if (surface.always_on_top) win32.HWND_TOPMOST else null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOOWNERZORDER = 1, .DRAWFRAME = 1 },
    ) == 0) {
        log.warn("SetWindowPos entering fullscreen failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        _ = setWindowStyle(hwnd, style);
        _ = win32.SetWindowPlacement(hwnd, &placement);
        _ = refreshWindowFrame(hwnd);
        return false;
    }

    surface.windowed_style = style;
    surface.windowed_placement = placement;
    surface.fullscreen = true;
    return true;
}

fn leaveFullscreen(surface: *Surface) bool {
    const hwnd = surface.windowHwnd();
    const saved_style = surface.windowed_style orelse {
        log.warn("fullscreen window has no saved style", .{});
        return false;
    };
    const placement = surface.windowed_placement orelse {
        log.warn("fullscreen window has no saved placement", .{});
        return false;
    };
    const current_style = getWindowStyle(hwnd) orelse return false;
    const restored_style = styleWithDecorations(
        saved_style,
        surface.decorated,
    );
    if (!setWindowStyle(hwnd, restored_style)) return false;

    if (win32.SetWindowPlacement(hwnd, &placement) == 0) {
        log.warn("SetWindowPlacement leaving fullscreen failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        _ = setWindowStyle(hwnd, current_style);
        return false;
    }
    if (!refreshWindowFrame(hwnd)) return false;

    surface.fullscreen = false;
    surface.windowed_style = null;
    surface.windowed_placement = null;
    return true;
}

fn toggleWindowDecorations(target: apprt.Target) bool {
    const target_surface = targetSurface(target) orelse {
        log.warn("toggle_window_decorations targeted the application", .{});
        return false;
    };
    const surface = windowStateSurface(target_surface);
    return setWindowDecorations(surface, !surface.decorated);
}

fn setWindowDecorations(surface: *Surface, decorated: bool) bool {
    if (surface.decorated == decorated) return true;

    // A fullscreen window is intentionally borderless. Remember the requested
    // state and apply it to the saved window style when fullscreen exits.
    if (surface.fullscreen) {
        surface.decorated = decorated;
        return true;
    }

    const hwnd = surface.windowHwnd();
    const old_style = getWindowStyle(hwnd) orelse return false;
    const new_style = styleWithDecorations(old_style, decorated);
    if (!setWindowStyle(hwnd, new_style)) return false;
    if (!refreshWindowFrame(hwnd)) {
        _ = setWindowStyle(hwnd, old_style);
        _ = refreshWindowFrame(hwnd);
        return false;
    }

    surface.decorated = decorated;
    return true;
}

fn styleWithDecorations(style: u32, decorated: bool) u32 {
    const mask: u32 = @bitCast(win32.WS_OVERLAPPEDWINDOW);
    return if (decorated) style | mask else style & ~mask;
}

fn getWindowStyle(hwnd: win32.HWND) ?u32 {
    win32.SetLastError(.NO_ERROR);
    const value = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);
    if (value == 0 and win32.GetLastError() != .NO_ERROR) {
        log.warn("GetWindowLongPtrW(GWL_STYLE) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return null;
    }
    return @truncate(@as(usize, @bitCast(value)));
}

fn setWindowStyle(hwnd: win32.HWND, style: u32) bool {
    win32.SetLastError(.NO_ERROR);
    const value = win32.SetWindowLongPtrW(
        hwnd,
        win32.GWL_STYLE,
        @bitCast(@as(usize, style)),
    );
    if (value == 0 and win32.GetLastError() != .NO_ERROR) {
        log.warn("SetWindowLongPtrW(GWL_STYLE) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    return true;
}

fn refreshWindowFrame(hwnd: win32.HWND) bool {
    if (win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        .{
            .NOMOVE = 1,
            .NOSIZE = 1,
            .NOZORDER = 1,
            .NOACTIVATE = 1,
            .DRAWFRAME = 1,
        },
    ) == 0) {
        log.warn("SetWindowPos refreshing frame failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    return true;
}

fn floatWindow(
    target: apprt.Target,
    mode: apprt.action.FloatWindow,
) bool {
    const target_surface = targetSurface(target) orelse {
        log.warn("float_window targeted the application", .{});
        return false;
    };
    const surface = windowStateSurface(target_surface);
    const enabled = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !surface.always_on_top,
    };
    if (enabled == surface.always_on_top) return true;

    return setAlwaysOnTop(surface, enabled);
}

fn setAlwaysOnTop(surface: *Surface, enabled: bool) bool {
    if (win32.SetWindowPos(
        surface.windowHwnd(),
        if (enabled) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        .{ .NOMOVE = 1, .NOSIZE = 1, .NOACTIVATE = 1 },
    ) == 0) {
        log.warn("SetWindowPos changing topmost state failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    surface.always_on_top = enabled;
    return true;
}

fn setInitialSize(
    target: apprt.Target,
    value: apprt.action.InitialSize,
) bool {
    const target_surface = targetSurface(target) orelse {
        log.warn("initial_size targeted the application", .{});
        return false;
    };
    if (value.width == 0 or value.height == 0) return false;

    const surface = windowStateSurface(target_surface);
    if (surface != target_surface) return true;

    surface.initial_client_size = value;
    if (!surface.shown) return resizeClientArea(surface, value);
    return true;
}

fn resetWindowSize(target: apprt.Target) bool {
    const target_surface = targetSurface(target) orelse {
        log.warn("reset_window_size targeted the application", .{});
        return false;
    };
    const surface = windowStateSurface(target_surface);
    if (surface.fullscreen) return false;

    if (surface.default_maximized) {
        _ = win32.ShowWindow(surface.windowHwnd(), win32.SW_MAXIMIZE);
        return true;
    }

    const size = surface.initial_client_size orelse return false;
    if (win32.IsZoomed(surface.windowHwnd()) != 0) {
        _ = win32.ShowWindow(surface.windowHwnd(), win32.SW_RESTORE);
    }
    return resizeClientArea(surface, size);
}

fn resizeClientArea(
    surface: *Surface,
    size: apprt.action.InitialSize,
) bool {
    const hwnd = surface.windowHwnd();
    const style_bits: u32 = @truncate(@as(
        usize,
        @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE)),
    ));
    const ex_style_bits: u32 = @truncate(@as(
        usize,
        @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE)),
    ));
    const style: win32.WINDOW_STYLE = @bitCast(style_bits);
    const ex_style: win32.WINDOW_EX_STYLE = @bitCast(ex_style_bits);

    const max_dimension: u32 = @intCast(std.math.maxInt(i32) / 2);
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(@min(size.width, max_dimension)),
        .bottom = @intCast(@min(size.height, max_dimension)),
    };
    const dpi = dpi: {
        const value = win32.GetDpiForWindow(hwnd);
        break :dpi if (value > 0) value else win32.USER_DEFAULT_SCREEN_DPI;
    };
    if (surface.rtApp().windowForSurface(surface)) |window| {
        if (tabBarVisible(surface.rtApp(), window)) {
            rect.bottom = @min(
                std.math.maxInt(i32),
                rect.bottom + TabBar.heightForDpi(dpi),
            );
        }
    }
    if (win32.AdjustWindowRectExForDpi(
        &rect,
        style,
        0,
        ex_style,
        dpi,
    ) == 0) {
        log.warn("AdjustWindowRectExForDpi failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }

    var outer = WindowExtent{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
    if (win32.MonitorFromWindow(
        hwnd,
        win32.MONITOR_DEFAULTTONEAREST,
    )) |monitor| {
        var info: win32.MONITORINFO = .{
            .cbSize = @sizeOf(win32.MONITORINFO),
            .rcMonitor = std.mem.zeroes(win32.RECT),
            .rcWork = std.mem.zeroes(win32.RECT),
            .dwFlags = 0,
        };
        if (win32.GetMonitorInfoW(monitor, &info) != 0) {
            outer = clampWindowExtent(outer, info.rcWork);
        } else {
            log.warn("GetMonitorInfoW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }

    if (win32.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        outer.width,
        outer.height,
        .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) {
        log.warn("SetWindowPos for client size failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return false;
    }
    return true;
}

const WindowExtent = struct {
    width: i32,
    height: i32,
};

fn clampWindowExtent(extent: WindowExtent, work_area: win32.RECT) WindowExtent {
    const work_width = @max(work_area.right - work_area.left, 1);
    const work_height = @max(work_area.bottom - work_area.top, 1);
    return .{
        .width = std.math.clamp(extent.width, 1, work_width),
        .height = std.math.clamp(extent.height, 1, work_height),
    };
}

fn openUrl(
    self: *App,
    target: apprt.Target,
    value: apprt.action.OpenUrl,
) bool {
    if (value.kind != .osc8) {
        self.shellOpen(target, value.url) catch |err| {
            log.warn("failed to open URL: {}", .{err});
            return false;
        };
        return true;
    }

    switch (classifyUntrustedUrl(value.url)) {
        .allow => self.shellOpen(target, value.url) catch |err| {
            log.warn("failed to open trusted OSC 8 URL: {}", .{err});
        },
        .confirm => if (self.confirmUntrustedUrl(target, value.url)) {
            self.shellOpen(target, value.url) catch |err| {
                log.warn("failed to open confirmed OSC 8 URL: {}", .{err});
            };
        },
        .deny => |reason| self.showBlockedUrl(target, reason, value.url),
    }

    // OSC 8 targets must never reach the unrestricted core fallback. Even a
    // rejected target is handled here so terminal output cannot bypass this
    // policy by making the platform handler return false.
    return true;
}

const UntrustedUrlDenial = enum {
    malformed_url,
    unsafe_characters,
    invalid_web_url,
    unsafe_file,

    fn message(self: UntrustedUrlDenial) []const u8 {
        return switch (self) {
            .malformed_url => "The target is not an absolute URL with a scheme.",
            .unsafe_characters => "The target contains invisible or line-breaking characters.",
            .invalid_web_url => "The web target does not contain a valid host.",
            .unsafe_file => "Opening local files from terminal output is blocked on Windows.",
        };
    }
};

const UntrustedUrlDecision = union(enum) {
    allow,
    confirm,
    deny: UntrustedUrlDenial,
};

fn classifyUntrustedUrl(url: []const u8) UntrustedUrlDecision {
    if (url.len == 0) return .{ .deny = .malformed_url };

    const view = std.unicode.Utf8View.init(url) catch
        return .{ .deny = .malformed_url };
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |cp| {
        if (isUnsafeUrlCodepoint(cp)) {
            return .{ .deny = .unsafe_characters };
        }
    }

    // RFC 3986 considers a drive letter to be a scheme, but on Windows this
    // spelling is a local path. Do not let it enter the custom-scheme prompt.
    if (url.len >= 3 and
        std.ascii.isAlphabetic(url[0]) and
        url[1] == ':' and
        (url[2] == '\\' or url[2] == '/'))
    {
        return .{ .deny = .malformed_url };
    }

    const uri = std.Uri.parse(url) catch
        return .{ .deny = .malformed_url };
    if (uri.scheme.len == 0) return .{ .deny = .malformed_url };

    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        const host = uri.host orelse
            return .{ .deny = .invalid_web_url };
        if (host.percent_encoded.len == 0) {
            return .{ .deny = .invalid_web_url };
        }
        return .allow;
    }

    if (std.ascii.eqlIgnoreCase(uri.scheme, "mailto")) {
        if (uri.path.percent_encoded.len == 0) {
            return .{ .deny = .malformed_url };
        }
        return .allow;
    }

    // ShellExecute may dispatch a local file to an executable handler. Until
    // Win32 has canonical-path and file-type checks equivalent to macOS, keep
    // every file URL supplied by terminal output out of the shell entirely.
    if (std.ascii.eqlIgnoreCase(uri.scheme, "file")) {
        return .{ .deny = .unsafe_file };
    }

    // Custom schemes may invoke any registered application, so require an
    // explicit user decision with Cancel as the default action.
    return .confirm;
}

fn isUnsafeUrlCodepoint(cp: u21) bool {
    return switch (cp) {
        0x00...0x1F,
        0x7F...0x9F,
        0x061C,
        0x200B...0x200F,
        0x2028...0x202E,
        0x2060,
        0x2066...0x2069,
        0xFEFF,
        => true,
        else => false,
    };
}

fn confirmUntrustedUrl(
    self: *App,
    target: apprt.Target,
    url: []const u8,
) bool {
    const message = std.fmt.allocPrint(
        self.alloc,
        "This link may open another application. Only continue if you recognize and trust the destination.\r\n\r\nTarget:\r\n{s}",
        .{url},
    ) catch |err| {
        log.warn("failed to format OSC 8 confirmation: {}", .{err});
        return false;
    };
    defer self.alloc.free(message);

    const message_wide = std.unicode.utf8ToUtf16LeAllocZ(
        self.alloc,
        message,
    ) catch |err| {
        log.warn("failed to convert OSC 8 confirmation: {}", .{err});
        return false;
    };
    defer self.alloc.free(message_wide);

    const caption = std.unicode.utf8ToUtf16LeStringLiteral(
        "Open Link from Terminal Output?",
    );
    const style: win32.MESSAGEBOX_STYLE = .{
        .YESNO = 1,
        .ICONQUESTION = 1,
        .DEFBUTTON2 = 1,
    };
    return win32.MessageBoxW(
        self.actionParentWindow(target),
        message_wide,
        caption,
        style,
    ) == win32.IDYES;
}

fn showBlockedUrl(
    self: *App,
    target: apprt.Target,
    reason: UntrustedUrlDenial,
    url: []const u8,
) void {
    const display = formatUntrustedUrlForDisplay(self.alloc, url) catch |err| {
        log.warn("failed to format blocked OSC 8 target: {}", .{err});
        return;
    };
    defer self.alloc.free(display);

    const message = std.fmt.allocPrint(
        self.alloc,
        "{s}\r\n\r\nTarget:\r\n{s}",
        .{ reason.message(), display },
    ) catch |err| {
        log.warn("failed to format blocked OSC 8 message: {}", .{err});
        return;
    };
    defer self.alloc.free(message);

    const message_wide = std.unicode.utf8ToUtf16LeAllocZ(
        self.alloc,
        message,
    ) catch |err| {
        log.warn("failed to convert blocked OSC 8 message: {}", .{err});
        return;
    };
    defer self.alloc.free(message_wide);

    const caption = std.unicode.utf8ToUtf16LeStringLiteral(
        "Ghostty Blocked This Link",
    );
    const style: win32.MESSAGEBOX_STYLE = .{ .ICONHAND = 1 };
    _ = win32.MessageBoxW(
        self.actionParentWindow(target),
        message_wide,
        caption,
        style,
    );
}

fn formatUntrustedUrlForDisplay(
    alloc: Allocator,
    url: []const u8,
) Allocator.Error![]u8 {
    const view = std.unicode.Utf8View.init(url) catch
        return try alloc.dupe(u8, "<invalid UTF-8 target>");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |cp| {
        if (isUnsafeUrlCodepoint(cp)) {
            buffer.writer.print("\\u{{{X}}}", .{cp}) catch
                return error.OutOfMemory;
        } else {
            buffer.writer.print("{u}", .{cp}) catch
                return error.OutOfMemory;
        }
    }
    return try buffer.toOwnedSlice();
}

/// Reload the configuration and apply it to either the complete application or
/// one surface. A hard reload finishes loading before any live state changes,
/// so a loading failure leaves the current configuration in place.
fn reloadConfig(
    self: *App,
    target: apprt.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    if (opts.soft) {
        try self.updateConfig(target, self.config);
        return;
    }

    var config = try Config.load(self.alloc);
    defer config.deinit();
    try self.updateConfig(target, &config);
    self.showConfigDiagnostics(target, &config);
}

fn updateConfig(
    self: *App,
    target: apprt.Target,
    config: *const Config,
) !void {
    switch (target) {
        .app => try self.core_app.updateConfig(self, config),
        .surface => |surface| try surface.updateConfig(config),
    }
}

/// Show configuration diagnostics after startup or a reload. Diagnostics do
/// not prevent valid configuration entries from being applied, matching the
/// behavior of the other application runtimes.
fn showConfigDiagnostics(
    self: *App,
    target: apprt.Target,
    config: *const Config,
) void {
    const hwnd = switch (target) {
        .app => if (self.windows.items.len > 0)
            self.windows.items[0].hwnd
        else
            return,
        .surface => |surface| surface.rt_surface.windowHwnd(),
    };

    const message = formatConfigDiagnostics(self.alloc, config) catch |err| {
        log.warn("failed to format configuration diagnostics: {}", .{err});
        return;
    } orelse return;
    defer self.alloc.free(message);

    const message_wide = std.unicode.utf8ToUtf16LeAllocZ(
        self.alloc,
        message,
    ) catch |err| {
        log.warn("failed to convert configuration diagnostics: {}", .{err});
        return;
    };
    defer self.alloc.free(message_wide);

    const caption = std.unicode.utf8ToUtf16LeStringLiteral(
        "Ghostty Configuration Error",
    );
    const style: win32.MESSAGEBOX_STYLE = .{ .ICONHAND = 1 };
    _ = win32.MessageBoxW(hwnd, message_wide, caption, style);
}

fn formatConfigDiagnostics(
    alloc: Allocator,
    config: *const Config,
) Allocator.Error!?[:0]u8 {
    const diagnostics = config._diagnostics.items();
    if (diagnostics.len == 0) return null;

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    buffer.writer.writeAll(
        "Ghostty found errors in the configuration:\r\n\r\n",
    ) catch return error.OutOfMemory;
    for (diagnostics, 0..) |*diagnostic, i| {
        if (i > 0) buffer.writer.writeAll("\r\n") catch
            return error.OutOfMemory;
        diagnostic.format(&buffer.writer) catch return error.OutOfMemory;
    }

    return try buffer.toOwnedSliceSentinel(0);
}

fn openConfig(
    self: *App,
    target: apprt.Target,
    mode: apprt.action.OpenConfig,
) !bool {
    switch (target) {
        .app => {},
        .surface => {
            log.warn("open_config targeted a surface", .{});
            return false;
        },
    }

    const path = configpkg.edit.openPath(self.alloc) catch |err| {
        log.warn("failed to get configuration path: {}", .{err});
        return false;
    };
    defer self.alloc.free(path);

    switch (mode) {
        .os_open => {
            self.shellOpen(target, path) catch |err| {
                log.warn("failed to open configuration: {}", .{err});
                return false;
            };
        },
        .new_window => {
            const command = self.configEditorCommand(path) catch |err| {
                log.warn("failed to build configuration editor command: {}", .{err});
                return false;
            };
            defer command.deinit(self.alloc);

            const title = try std.fmt.allocPrintSentinel(
                self.alloc,
                "Editing configuration file {s}",
                .{path},
                0,
            );
            defer self.alloc.free(title);

            try self.createWindow(.{
                .command = command,
                .title = title,
            });
        },
    }

    return true;
}

fn shellOpen(self: *App, target: apprt.Target, value: []const u8) !void {
    const value_wide = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, value);
    defer self.alloc.free(value_wide);

    const result = win32.ShellExecuteW(
        self.actionParentWindow(target),
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        value_wide,
        null,
        null,
        @bitCast(win32.SW_SHOWNORMAL),
    ) orelse return error.ShellExecuteFailed;

    if (@intFromPtr(result) <= 32) return error.ShellExecuteFailed;
}

fn actionParentWindow(self: *App, target: apprt.Target) ?win32.HWND {
    return switch (target) {
        .surface => |surface| surface.rt_surface.windowHwnd(),
        .app => if (self.windows.items.len > 0)
            self.windows.items[0].hwnd
        else
            null,
    };
}

fn configEditorCommand(
    self: *App,
    path: [:0]const u8,
) !configpkg.Command {
    const editor = editor: {
        if (try global.environ().containsUnempty(self.alloc, "VISUAL")) {
            break :editor try global.environ().getAlloc(self.alloc, "VISUAL");
        }
        if (try global.environ().containsUnempty(self.alloc, "EDITOR")) {
            break :editor try global.environ().getAlloc(self.alloc, "EDITOR");
        }
        return error.NoEditorConfigured;
    };
    defer self.alloc.free(editor);

    return parseWindowsEditorCommand(self.alloc, editor, path);
}

fn parseWindowsEditorCommand(
    alloc: Allocator,
    editor: []const u8,
    path: []const u8,
) !configpkg.Command {
    var iter = try std.process.Args.IteratorGeneral(.{}).init(alloc, editor);
    defer iter.deinit();

    var args: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (args.items) |arg| alloc.free(arg);
        args.deinit(alloc);
    }
    while (iter.next()) |arg| {
        const copy = try alloc.dupeZ(u8, arg);
        errdefer alloc.free(copy);
        try args.append(alloc, copy);
    }
    if (args.items.len == 0) return error.InvalidEditorCommand;
    {
        const path_copy = try alloc.dupeZ(u8, path);
        errdefer alloc.free(path_copy);
        try args.append(alloc, path_copy);
    }

    return .{ .direct = try args.toOwnedSlice(alloc) };
}

pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}

const WindowOptions = struct {
    command: ?configpkg.Command = null,
    title: ?[:0]const u8 = null,
};

fn initCoreSurface(
    self: *App,
    surface: *Surface,
    opts: WindowOptions,
    context: apprt.surface.NewSurfaceContext,
) !void {
    const alloc = self.alloc;

    const core_surface = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core_surface);

    try self.core_app.addSurface(surface);
    errdefer self.core_app.deleteSurface(surface);

    var config = try apprt.surface.newConfig(
        self.core_app,
        self.config,
        context,
    );
    defer config.deinit();

    if (opts.command) |command| {
        config.command = try command.clone(config.arenaAlloc());
        if (config.@"shell-integration" != .none) {
            config.@"shell-integration" = .detect;
        }
    }
    if (opts.title) |title| {
        config.title = try config.arenaAlloc().dupeZ(u8, title);
    }
    surface.file_drop_shell = try FileDrop.classify(
        config.arenaAlloc(),
        if (self.core_app.first) config.@"initial-command" orelse config.command else config.command,
    );
    if (context == .window) {
        surface.default_maximized = config.maximize;
        surface.default_fullscreen = config.fullscreen != .false;
        if (!setWindowDecorations(
            surface,
            config.@"window-decoration" != .none,
        )) {
            log.warn("failed to apply initial window-decoration setting", .{});
        }
        Titlebar.apply(surface.windowHwnd(), &config, self.high_contrast);
    }
    core_surface.init(
        alloc,
        &config,
        self.core_app,
        self,
        surface,
    ) catch |err| {
        log.err("failed to initialize core surface: {}", .{err});
        return err;
    };

    surface.core_surface = core_surface;

    // The initial_size action can resize the native windows while the core
    // surface is still initializing. The child's WM_SIZE arrives before
    // core_surface is set, so nothing forwards it, and the core would keep
    // the placeholder size it was created with: the terminal grid and the
    // ConPTY then cover only part of the window until the next manual
    // resize. Sync once here; the core ignores an unchanged size.
    core_surface.sizeCallback(.{
        .width = surface.width,
        .height = surface.height,
    }) catch |err| {
        log.warn("failed to sync the initial surface size: {}", .{err});
    };

    try self.configureScrollbar(surface, &config);

    updateWindowBackgroundBlur(surface, &config);
    log.info("core surface initialized successfully", .{});
}

fn createWindow(self: *App, opts: WindowOptions) !void {
    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);

    const window = try self.alloc.create(Window);
    errdefer self.alloc.destroy(window);

    const window_hwnd = try createNativeWindow();
    errdefer _ = win32.DestroyWindow(window_hwnd);

    const surface_hwnd = try createNativeSurfaceWindow(window_hwnd);
    errdefer _ = win32.DestroyWindow(surface_hwnd);

    try surface.init(self, window_hwnd, surface_hwnd);
    errdefer surface.deinit();

    window.* = try Window.init(self.alloc, window_hwnd, surface);
    errdefer window.deinit(self.alloc);

    // The tab bar is an auxiliary window. Every consumer tolerates a null
    // handle, so a creation failure (USER handle exhaustion, for example)
    // degrades to a window without a tab bar instead of no window at all.
    const tab_bar_hwnd: ?win32.HWND = createNativeTabBarWindow(window_hwnd) catch |err| tab_bar: {
        log.warn("tab bar unavailable for this window; continuing without it: {}", .{err});
        break :tab_bar null;
    };
    errdefer if (tab_bar_hwnd) |hwnd| {
        _ = win32.DestroyWindow(hwnd);
    };
    window.tab_bar_hwnd = tab_bar_hwnd;
    if (tab_bar_hwnd) |hwnd| {
        _ = win32.SetWindowLongPtrW(
            hwnd,
            win32.GWLP_USERDATA,
            @bitCast(@intFromPtr(window)),
        );
        if (TabBarAccessibility.create(hwnd, window)) |accessibility| {
            window.tab_bar_accessibility = @ptrCast(accessibility);
        } else |err| {
            log.warn("failed to create tab bar accessibility provider: {}", .{err});
        }
    }
    errdefer deinitTabBarAccessibility(window);

    _ = win32.SetWindowLongPtrW(
        window_hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(surface)),
    );
    _ = win32.SetWindowLongPtrW(
        surface_hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(surface)),
    );

    try self.windows.append(self.alloc, window);
    errdefer _ = self.removeWindow(window);

    try self.initCoreSurface(surface, opts, .window);
    self.syncTabBarAccessibility(window, false, false);
    self.layoutWindow(window);
    showWindow(surface);
}

fn newTab(self: *App, target: apprt.Target) !bool {
    const existing = targetSurface(target) orelse {
        log.warn("new_tab targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(existing) orelse {
        log.warn("new_tab targeted an unowned surface", .{});
        return false;
    };

    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);

    const surface_hwnd = try createNativeSurfaceWindow(window.hwnd);
    errdefer _ = win32.DestroyWindow(surface_hwnd);

    try surface.init(self, window.hwnd, surface_hwnd);
    errdefer surface.deinit();
    surface.shown = true;

    _ = win32.SetWindowLongPtrW(
        surface_hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(surface)),
    );

    try window.addTab(
        self.alloc,
        surface,
        self.config.@"window-new-tab-position" == .current,
    );
    errdefer {
        const index = window.tabIndexForSurface(surface) orelse unreachable;
        _ = window.removeTabAt(self.alloc, index) catch unreachable;
    }

    try self.initCoreSurface(surface, .{}, .tab);
    activateWindowTab(self, window);
    notifyTabBarAccessibilityEvent(window, event_object_reorder);
    log.info("created Win32 tab tabs={d}", .{window.tabCount()});
    return true;
}

fn gotoTab(
    self: *App,
    target: apprt.Target,
    value: apprt.action.GotoTab,
) bool {
    const surface = targetSurface(target) orelse {
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
            const raw = @intFromEnum(value);
            if (raw < 0) return false;
            break :raw .{ .n = @intCast(raw) };
        },
    };
    if (!window.selectTab(selection)) return false;
    activateWindowTab(self, window);
    return true;
}

fn moveTab(
    self: *App,
    target: apprt.Target,
    value: apprt.action.MoveTab,
) bool {
    const surface = targetSurface(target) orelse {
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
    if (old_state != new_state) transferWindowState(old_state, new_state);
    invalidateTabBar(window);
    self.syncTabBarAccessibility(window, false, true);
    return true;
}

fn activateWindowTab(self: *App, window: *Window) void {
    clearWindowSplitPointer(window);
    const focus = window.focusedSurface();
    _ = win32.SetWindowLongPtrW(
        window.hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(focus)),
    );
    self.layoutWindow(window);
    _ = win32.SetFocus(focus.hwnd);
    focus.syncTitle();
    self.syncTabBarAccessibility(window, true, false);
}

fn newSplit(
    self: *App,
    target: apprt.Target,
    direction: apprt.action.SplitDirection,
) !bool {
    const existing = targetSurface(target) orelse {
        log.warn("new_split targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(existing) orelse {
        log.warn("new_split targeted an unowned surface", .{});
        return false;
    };
    clearWindowSplitPointer(window);

    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);

    const surface_hwnd = try createNativeSurfaceWindow(window.hwnd);
    errdefer _ = win32.DestroyWindow(surface_hwnd);

    try surface.init(self, window.hwnd, surface_hwnd);
    errdefer surface.deinit();
    surface.shown = true;

    _ = win32.SetWindowLongPtrW(
        surface_hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(surface)),
    );

    try window.addSplit(
        self.alloc,
        existing,
        surface,
        switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        },
        direction == .right or direction == .down,
    );
    errdefer {
        _ = window.removeSurface(self.alloc, surface) catch |err| {
            log.err("failed to roll back split ownership: {}", .{err});
        };
    }

    try self.initCoreSurface(surface, .{}, .split);
    self.layoutWindow(window);
    _ = win32.SetFocus(surface.hwnd);
    log.info("created Win32 split direction={s} surfaces={d}", .{
        @tagName(direction),
        window.activeSurfaceCount(),
    });
    return true;
}

fn gotoSplit(
    self: *App,
    target: apprt.Target,
    direction: apprt.action.GotoSplit,
) bool {
    const current = targetSurface(target) orelse {
        log.warn("goto_split targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(current) orelse {
        log.warn("goto_split targeted an unowned surface", .{});
        return false;
    };

    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect for split focus failed: err={d}", .{@intFromEnum(win32.GetLastError())});
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
        windowContentBounds(self, window, client),
        splitDividerGap(window),
        rects,
    ) orelse return false;

    window.updateZoomForNavigation(
        focus,
        self.config.@"split-preserve-zoom".navigation,
    );
    self.layoutWindow(window);

    _ = window.setFocusedSurface(focus);
    _ = win32.SetWindowLongPtrW(
        window.hwnd,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(focus)),
    );
    _ = win32.SetFocus(focus.hwnd);
    focus.syncTitle();
    return true;
}

fn resizeSplit(
    self: *App,
    target: apprt.Target,
    value: apprt.action.ResizeSplit,
) bool {
    const current = targetSurface(target) orelse {
        log.warn("resize_split targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(current) orelse {
        log.warn("resize_split targeted an unowned surface", .{});
        return false;
    };

    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect for split resize failed: err={d}", .{@intFromEnum(win32.GetLastError())});
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
        windowContentBounds(self, window, client),
        splitDividerGap(window),
    );
    if (!changed) return false;
    self.layoutWindow(window);
    return true;
}

fn equalizeSplits(self: *App, target: apprt.Target) bool {
    const surface = targetSurface(target) orelse {
        log.warn("equalize_splits targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("equalize_splits targeted an unowned surface", .{});
        return false;
    };
    if (!window.equalizeSplits()) return false;
    self.layoutWindow(window);
    return true;
}

fn toggleSplitZoom(self: *App, target: apprt.Target) bool {
    const surface = targetSurface(target) orelse {
        log.warn("toggle_split_zoom targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("toggle_split_zoom targeted an unowned surface", .{});
        return false;
    };
    if (!window.toggleSplitZoom(surface)) return false;
    self.layoutWindow(window);
    return true;
}

/// Native search controls belong to a pane even while the terminal itself
/// has no keyboard focus. Keep window actions and cwd inheritance targeted
/// at that pane without sending terminal focus-in events for an edit control.
pub fn focusSearchPane(self: *App, surface: *Surface) void {
    const window = self.windowForSurface(surface) orelse return;
    _ = window.setFocusedSurface(surface);
    if (surface.core_surface) |core| self.core_app.focusSurface(core);
    _ = win32.SetWindowLongPtrW(window.hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(surface)));
    surface.syncTitle();
    invalidateTabBar(window);
}

fn layoutWindow(self: *App, window: *Window) void {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect for window layout failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    }

    const client_width = @max(0, client.right - client.left);
    const tab_height = if (tabBarVisible(self, window))
        TabBar.heightForDpi(windowDpi(window.hwnd))
    else
        0;
    updateTabBarViewport(window, client_width, tab_height);

    if (window.tab_bar_hwnd) |tab_bar| {
        if (tab_height > 0) {
            var origin: win32.POINT = .{ .x = 0, .y = 0 };
            if (win32.ClientToScreen(window.hwnd, &origin) == 0) {
                log.warn("ClientToScreen(tab bar) failed: err={d}", .{
                    @intFromEnum(win32.GetLastError()),
                });
                return;
            }
            if (win32.SetWindowPos(
                tab_bar,
                null,
                origin.x,
                origin.y,
                client_width,
                tab_height,
                .{ .NOZORDER = 1, .NOACTIVATE = 1, .SHOWWINDOW = 1 },
            ) == 0) {
                log.warn("SetWindowPos(tab bar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            }
            invalidateTabBar(window);
        } else {
            _ = win32.ShowWindow(tab_bar, win32.SW_HIDE);
        }
    }

    const rects = self.alloc.alloc(Window.LeafRect, window.activeSurfaceCount()) catch |err| {
        log.warn("failed to allocate window layout: {}", .{err});
        return;
    };
    defer self.alloc.free(rects);

    const content_bounds = windowContentBounds(self, window, client);
    const divider_gap = splitDividerGap(window);
    const count = window.layout(
        content_bounds,
        divider_gap,
        rects,
    );
    for (rects[0..count]) |entry| {
        const search_height = if (entry.view.search_bar) |bar|
            bar.layout(entry.rect.x, entry.rect.y, entry.rect.width, entry.rect.height, windowDpi(window.hwnd))
        else
            0;
        if (win32.SetWindowPos(
            entry.view.hwnd,
            null,
            entry.rect.x,
            entry.rect.y + search_height,
            entry.rect.width,
            entry.rect.height - search_height,
            .{ .NOZORDER = 1, .NOACTIVATE = 1 },
        ) == 0) {
            log.warn("SetWindowPos(surface layout) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        if (entry.view.scrollbar) |bar| {
            bar.layout(entry.rect.x, entry.rect.y + search_height, entry.rect.width, entry.rect.height - search_height, true);
        }
    }

    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |surface| {
        var visible = false;
        for (rects[0..count]) |entry| {
            if (entry.view == surface) {
                visible = true;
                break;
            }
        }
        _ = win32.ShowWindow(
            surface.hwnd,
            if (visible) win32.SW_SHOWNA else win32.SW_HIDE,
        );
        if (surface.search_bar) |bar| {
            _ = win32.ShowWindow(bar.hwnd.?, if (visible and bar.active) win32.SW_SHOWNA else win32.SW_HIDE);
        }
        if (!visible) {
            if (surface.scrollbar) |bar| bar.hide();
        }
    }

    self.layoutSplitDividers(window, content_bounds, divider_gap);
}

fn layoutSplitDividers(
    self: *App,
    window: *Window,
    bounds: Window.Rect,
    divider_gap: i32,
) void {
    const capacity = window.activeSurfaceCount() -| 1;
    const dividers = self.alloc.alloc(Window.Divider, capacity) catch |err| {
        log.warn("failed to allocate split divider layout: {}", .{err});
        hideSplitDividers(window, 0);
        return;
    };
    defer self.alloc.free(dividers);

    const count = window.dividers(bounds, divider_gap, dividers);
    window.split_dividers.clearRetainingCapacity();
    window.split_dividers.appendSlice(self.alloc, dividers[0..count]) catch |err| {
        log.warn("failed to retain split divider layout: {}", .{err});
        hideSplitDividers(window, 0);
        return;
    };

    while (window.split_divider_hwnds.items.len < count) {
        const hwnd = createNativeSplitDividerWindow(window.hwnd) catch break;
        window.split_divider_hwnds.append(self.alloc, hwnd) catch |err| {
            log.warn("failed to retain split divider window: {}", .{err});
            _ = win32.DestroyWindow(hwnd);
            break;
        };
        _ = win32.SetWindowLongPtrW(
            hwnd,
            win32.GWLP_USERDATA,
            @bitCast(@intFromPtr(window)),
        );
    }

    var origin: win32.POINT = .{ .x = 0, .y = 0 };
    if (win32.ClientToScreen(window.hwnd, &origin) == 0) {
        log.warn("ClientToScreen(split dividers) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        hideSplitDividers(window, 0);
        return;
    }

    const visible_count = @min(count, window.split_divider_hwnds.items.len);
    for (window.split_divider_hwnds.items[0..visible_count], dividers[0..visible_count]) |hwnd, divider| {
        if (win32.SetWindowPos(
            hwnd,
            null,
            origin.x + divider.rect.x,
            origin.y + divider.rect.y,
            @max(1, divider.rect.width),
            @max(1, divider.rect.height),
            .{ .NOZORDER = 1, .NOACTIVATE = 1, .SHOWWINDOW = 1 },
        ) == 0) {
            log.warn("SetWindowPos(split divider) failed: err={d}", .{
                @intFromEnum(win32.GetLastError()),
            });
        }
        _ = win32.InvalidateRect(hwnd, null, win32.TRUE);
    }
    hideSplitDividers(window, visible_count);
}

fn hideSplitDividers(window: *const Window, first: usize) void {
    const start = @min(first, window.split_divider_hwnds.items.len);
    for (window.split_divider_hwnds.items[start..]) |hwnd| {
        _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    }
}

fn tabBarVisible(self: *const App, window: *const Window) bool {
    return tabBarVisibleForMode(
        self.config.@"window-show-tab-bar",
        window.tabCount(),
        window.activeTabIsZoomed(),
    );
}

fn tabBarVisibleForMode(
    mode: Config.WindowShowTabBar,
    tab_count: usize,
    zoomed: bool,
) bool {
    return switch (mode) {
        .always => true,
        .auto => tab_count > 1 or zoomed,
        .never => false,
    };
}

fn windowContentBounds(
    self: *const App,
    window: *const Window,
    client: win32.RECT,
) Window.Rect {
    const tab_height = if (tabBarVisible(self, window))
        TabBar.heightForDpi(windowDpi(window.hwnd))
    else
        0;
    return .{
        .x = 0,
        .y = tab_height,
        .width = @max(0, client.right - client.left),
        .height = @max(0, client.bottom - client.top - tab_height),
    };
}

fn windowDpi(hwnd: win32.HWND) u32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    return if (dpi == 0) 96 else dpi;
}

fn highContrastEnabled() bool {
    var contrast: win32.HIGHCONTRASTW = .{
        .cbSize = @sizeOf(win32.HIGHCONTRASTW),
        .dwFlags = .{},
        .lpszDefaultScheme = null,
    };
    if (win32.SystemParametersInfoW(
        win32.SPI_GETHIGHCONTRAST,
        @sizeOf(win32.HIGHCONTRASTW),
        &contrast,
        .{},
    ) == 0) return false;
    return contrast.dwFlags.HIGHCONTRASTON != 0;
}

fn splitDividerGapForDpi(dpi: u32, high_contrast: bool) i32 {
    const logical = if (high_contrast)
        split_divider_high_contrast_logical_gap
    else
        split_divider_logical_gap;
    return @intCast(@max(
        1,
        @divTrunc(@as(i64, logical) * dpi + 48, 96),
    ));
}

fn splitDividerGap(window: *const Window) i32 {
    const app = window.focusedSurface().rtApp();
    return splitDividerGapForDpi(
        windowDpi(window.hwnd),
        app.high_contrast,
    );
}

fn invalidateTabBar(window: *const Window) void {
    const hwnd = window.tab_bar_hwnd orelse return;
    if (win32.InvalidateRect(hwnd, null, win32.TRUE) != 0) {
        _ = win32.UpdateWindow(hwnd);
    }
}

fn tabBarAccessibleName(
    alloc: Allocator,
    tab_count: usize,
    active_index: usize,
    active_title: []const u8,
) ![]u8 {
    const tab_word = if (tab_count == 1) "tab" else "tabs";
    return std.fmt.allocPrint(
        alloc,
        "Ghostty tabs. {d} {s}. Active tab {d}: {s}",
        .{ tab_count, tab_word, active_index + 1, active_title },
    );
}

fn syncTabBarAccessibility(
    self: *App,
    window: *const Window,
    selection_changed: bool,
    order_changed: bool,
) void {
    const hwnd = window.tab_bar_hwnd orelse return;
    const active_index = window.activeTabIndex();
    const active_surface = window.focusedSurface();
    const active_title = window.tabTitleAt(active_index) orelse
        active_surface.title orelse
        "Ghostty";
    const name = tabBarAccessibleName(
        self.alloc,
        window.tabCount(),
        active_index,
        active_title,
    ) catch |err| {
        log.warn("failed to allocate tab bar accessible name: {}", .{err});
        return;
    };
    defer self.alloc.free(name);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, name) catch |err| {
        log.warn("failed to encode tab bar accessible name: {}", .{err});
        return;
    };
    defer self.alloc.free(wide);

    if (win32.SetWindowTextW(hwnd, wide) == 0) {
        log.warn("SetWindowTextW(tab bar accessible name) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return;
    }
    notifyTabBarAccessibilityEvent(window, event_object_namechange);
    if (selection_changed) {
        notifyTabBarAccessibilityEvent(window, event_object_selection);
    }
    if (order_changed) {
        notifyTabBarAccessibilityEvent(window, event_object_reorder);
    }
}

fn notifyTabBarAccessibilityEvent(window: *const Window, event: u32) void {
    const hwnd = window.tab_bar_hwnd orelse return;
    const child_id: i32 = if (event == event_object_selection)
        @intCast(window.activeTabIndex() + 1)
    else
        childid_self;
    win32.NotifyWinEvent(event, hwnd, objid_client, child_id);
}

fn notifyTabBarChildNameChanged(window: *const Window, surface: *const Surface) void {
    const hwnd = window.tab_bar_hwnd orelse return;
    const index = window.tabIndexForSurface(surface) orelse return;
    win32.NotifyWinEvent(
        event_object_namechange,
        hwnd,
        objid_client,
        @intCast(index + 1),
    );
}

fn tabBarAccessibility(window: *const Window) ?*TabBarAccessibility {
    const raw = window.tab_bar_accessibility orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn deinitTabBarAccessibility(window: *Window) void {
    const accessibility = tabBarAccessibility(window) orelse return;
    window.tab_bar_accessibility = null;
    accessibility.detach();
}

fn invalidateSplitDividers(window: *const Window) void {
    for (window.split_divider_hwnds.items) |hwnd| {
        if (win32.InvalidateRect(hwnd, null, win32.TRUE) != 0) {
            _ = win32.UpdateWindow(hwnd);
        }
    }
}

fn splitDividerColor(config: *const Config, hovered: bool, high_contrast: bool) u32 {
    if (high_contrast) {
        return win32.GetSysColor(if (hovered)
            win32.COLOR_HIGHLIGHT
        else
            win32.COLOR_WINDOWTEXT);
    }

    const foreground = config.@"window-titlebar-foreground" orelse config.foreground;
    const percent: u16 = if (hovered) 65 else 30;
    return colorRef(mixColor(config.background, foreground, percent));
}

fn mixColor(background: Config.Color, foreground: Config.Color, percent: u16) Config.Color {
    return .{
        .r = mixColorChannel(background.r, foreground.r, percent),
        .g = mixColorChannel(background.g, foreground.g, percent),
        .b = mixColorChannel(background.b, foreground.b, percent),
    };
}

fn mixColorChannel(background: u8, foreground: u8, percent: u16) u8 {
    return @intCast((@as(u16, background) * (100 - percent) +
        @as(u16, foreground) * percent) / 100);
}

fn colorRef(color: Config.Color) u32 {
    return @as(u32, color.r) |
        (@as(u32, color.g) << 8) |
        (@as(u32, color.b) << 16);
}

fn updateTabBarViewport(window: *Window, width: i32, height: i32) void {
    window.tab_bar_first_visible = TabBar.ensureVisible(
        width,
        height,
        window.tabCount(),
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        window.activeTabIndex(),
    );
}

fn registerWindowClass() !void {
    const hinstance = win32.GetModuleHandleW(null) orelse {
        log.err("GetModuleHandleW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
    const icons = loadWindowIcons(hinstance);

    const wc: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = if (build_config.renderer == .opengl)
            .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 }
        else
            .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = icons.large,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = window_class_name,
        .hIconSm = icons.small,
    };

    if (win32.RegisterClassExW(&wc) == 0) {
        log.err("RegisterClassExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    const tab_bar_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1, .DBLCLKS = 1 },
        .lpfnWndProc = tabBarWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = tab_bar_class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&tab_bar_class) == 0) {
        log.err("RegisterClassExW(tab bar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    const split_divider_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = splitDividerWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = split_divider_class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&split_divider_class) == 0) {
        log.err("RegisterClassExW(split divider) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    const wakeup_class: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = wakeupWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = wakeup_class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&wakeup_class) == 0) {
        log.err("RegisterClassExW(wakeup) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }
}

const WindowIcons = struct {
    large: ?win32.HICON,
    small: ?win32.HICON,
};

/// Load the embedded application icon at the system large and small sizes.
/// A missing or unreadable icon resource is not fatal: the window class falls
/// back to the Windows default icon so the terminal still starts. Executables
/// without the Windows resource script, such as the unit test binary, take
/// this path.
fn loadWindowIcons(hinstance: win32.HINSTANCE) WindowIcons {
    const large_width = @max(1, win32.GetSystemMetrics(win32.SM_CXICON));
    const large_height = @max(1, win32.GetSystemMetrics(win32.SM_CYICON));
    const small_width = @max(1, win32.GetSystemMetrics(win32.SM_CXSMICON));
    const small_height = @max(1, win32.GetSystemMetrics(win32.SM_CYSMICON));

    const large = loadWindowIcon(hinstance, large_width, large_height) catch null;
    const small = loadWindowIcon(hinstance, small_width, small_height) catch null;
    if (large == null or small == null) {
        log.warn(
            "embedded window icon unavailable; using the Windows default icon",
            .{},
        );
    }

    return .{ .large = large, .small = small };
}

fn loadWindowIcon(
    hinstance: win32.HINSTANCE,
    width: i32,
    height: i32,
) !win32.HICON {
    const handle = win32.LoadImageW(
        hinstance,
        @ptrFromInt(icon_resource_id),
        .ICON,
        width,
        height,
        .{ .SHARED = 1 },
    ) orelse {
        log.warn("LoadImageW(icon {d}x{d}) failed: err={d}", .{
            width,
            height,
            @intFromEnum(win32.GetLastError()),
        });
        return error.Win32Error;
    };
    return @ptrCast(handle);
}

fn createNativeWindow() !win32.HWND {
    const hinstance = win32.GetModuleHandleW(null);

    return win32.CreateWindowExW(
        nativeWindowExStyle(),
        window_class_name,
        default_window_title,
        topLevelWindowStyle(),
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("CreateWindowExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
}

fn createNativeSurfaceWindow(window_hwnd: win32.HWND) !win32.HWND {
    const hinstance = win32.GetModuleHandleW(null);
    var rect: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window_hwnd, &rect) == 0) {
        log.err("GetClientRect for surface failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    return win32.CreateWindowExW(
        nativeWindowExStyle(),
        window_class_name,
        win32.L(""),
        surfaceWindowStyle(),
        0,
        0,
        @max(1, rect.right - rect.left),
        @max(1, rect.bottom - rect.top),
        window_hwnd,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("CreateWindowExW(surface) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
}

fn createNativeTabBarWindow(window_hwnd: win32.HWND) !win32.HWND {
    const popup: u32 = 0x80000000;
    const clip_siblings: u32 = 0x04000000;
    const hwnd = win32.CreateWindowExW(
        .{ .TOOLWINDOW = 1, .NOACTIVATE = 1 },
        tab_bar_class_name,
        win32.L(""),
        @bitCast(popup | clip_siblings),
        0,
        0,
        1,
        1,
        window_hwnd,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse {
        log.err("CreateWindowExW(tab bar) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
    errdefer _ = win32.DestroyWindow(hwnd);
    return hwnd;
}

fn createNativeSplitDividerWindow(window_hwnd: win32.HWND) !win32.HWND {
    const popup: u32 = 0x80000000;
    const clip_siblings: u32 = 0x04000000;
    return win32.CreateWindowExW(
        .{ .TOOLWINDOW = 1, .NOACTIVATE = 1, .TRANSPARENT = 1 },
        split_divider_class_name,
        win32.L(""),
        @bitCast(popup | clip_siblings),
        0,
        0,
        1,
        1,
        window_hwnd,
        null,
        win32.GetModuleHandleW(null),
        null,
    ) orelse {
        log.warn("CreateWindowExW(split divider) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };
}

fn topLevelWindowStyle() win32.WINDOW_STYLE {
    const clip_children: u32 = 0x02000000;
    return @bitCast(@as(u32, @bitCast(win32.WS_OVERLAPPEDWINDOW)) | clip_children);
}

fn surfaceWindowStyle() win32.WINDOW_STYLE {
    const child: u32 = 0x40000000;
    const visible: u32 = 0x10000000;
    const clip_siblings: u32 = 0x04000000;
    return @bitCast(child | visible | clip_siblings);
}

/// DirectComposition owns the complete client-area visual tree. Disabling the
/// legacy redirected bitmap lets the swap chain's premultiplied alpha reach
/// the desktop compositor instead of being flattened against an HWND surface.
fn nativeWindowExStyle() win32.WINDOW_EX_STYLE {
    return if (build_config.renderer == .d3d11)
        .{ .NOREDIRECTIONBITMAP = 1 }
    else
        .{};
}

/// Keep the native backdrop synchronized with the renderer's background
/// opacity and requested blur strength. Native backdrop composition is only
/// used with D3D11; OpenGL retains its existing transparent behavior.
fn updateWindowBackgroundBlur(surface: *Surface, config: *const Config) void {
    const radius = windowBackgroundBlurRadius(config);
    const app = surface.rtApp();
    const window = app.windowForSurface(surface) orelse {
        log.warn("background blur targeted an unowned surface", .{});
        return;
    };

    const value = radius orelse {
        disableWindowBackgroundBlur(window);
        return;
    };

    // A fixed DWM backdrop has no adjustable radius. It remains the fallback
    // for this window until blur is disabled and enabled again.
    if (window.dwm_backdrop_active) return;

    if (!window.host_backdrop_active) {
        Backdrop.setHostBackdrop(window.hwnd, true) catch |err| {
            log.warn("failed to enable Win32 host backdrop: {}", .{err});
            enableFallbackBackdrop(window);
            return;
        };
        window.host_backdrop_active = true;
    }

    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |candidate| {
        if (candidate.background_blur) |*backdrop| {
            backdrop.setRadius(value) catch |err| {
                log.warn("failed to update Win32 background blur: {}", .{err});
                fallbackFromGaussianBackdrop(window);
                return;
            };
            continue;
        }

        candidate.background_blur = Backdrop.init(
            candidate.hwnd,
            value,
            &app.backdrop_runtime,
        ) catch |err| {
            log.warn("failed to apply Win32 background blur: {}", .{err});
            fallbackFromGaussianBackdrop(window);
            return;
        };
    }
}

fn releaseSurfaceBackdrops(window: *Window) void {
    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |surface| {
        if (surface.background_blur) |*backdrop| backdrop.deinit();
        surface.background_blur = null;
    }
}

fn disableHostBackdrop(window: *Window) void {
    if (!window.host_backdrop_active) return;
    Backdrop.setHostBackdrop(window.hwnd, false) catch |err| {
        log.warn("failed to disable Win32 host backdrop: {}", .{err});
        return;
    };
    window.host_backdrop_active = false;
}

fn enableFallbackBackdrop(window: *Window) void {
    if (window.dwm_backdrop_active) return;
    Backdrop.setSystemBackdrop(window.hwnd, .transient_window) catch |err| {
        log.warn("failed to apply fixed Win32 Acrylic fallback: {}", .{err});
        return;
    };
    window.dwm_backdrop_active = true;
    log.warn("using fixed Win32 Acrylic because Gaussian backdrop is unavailable", .{});
}

fn fallbackFromGaussianBackdrop(window: *Window) void {
    releaseSurfaceBackdrops(window);
    disableHostBackdrop(window);
    enableFallbackBackdrop(window);
}

fn disableWindowBackgroundBlur(window: *Window) void {
    releaseSurfaceBackdrops(window);
    disableHostBackdrop(window);
    if (!window.dwm_backdrop_active) return;
    Backdrop.setSystemBackdrop(window.hwnd, .none) catch |err| {
        log.warn("failed to remove fixed Win32 Acrylic fallback: {}", .{err});
        return;
    };
    window.dwm_backdrop_active = false;
}

fn windowBackgroundBlurRadius(config: *const Config) ?u8 {
    if (build_config.renderer != .d3d11 or
        config.@"background-opacity" >= 1) return null;

    return switch (config.@"background-blur") {
        .false => null,
        .true, .@"macos-glass-regular", .@"macos-glass-clear" => 20,
        .radius => |value| if (value > 0) value else null,
    };
}

test "Win32 D3D11 windows bypass the legacy redirect bitmap" {
    const style = nativeWindowExStyle();
    try std.testing.expectEqual(
        @as(u1, @intFromBool(build_config.renderer == .d3d11)),
        style.NOREDIRECTIONBITMAP,
    );
}

test "Win32 background blur requires D3D11 and transparent background" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();

    config.@"background-opacity" = 0.75;
    config.@"background-blur" = .true;
    try std.testing.expectEqual(
        if (build_config.renderer == .d3d11) @as(?u8, 20) else null,
        windowBackgroundBlurRadius(&config),
    );

    config.@"background-opacity" = 1;
    try std.testing.expectEqual(@as(?u8, null), windowBackgroundBlurRadius(&config));

    config.@"background-opacity" = 0.75;
    config.@"background-blur" = .false;
    try std.testing.expectEqual(@as(?u8, null), windowBackgroundBlurRadius(&config));

    config.@"background-blur" = .{ .radius = 0 };
    try std.testing.expectEqual(@as(?u8, null), windowBackgroundBlurRadius(&config));

    config.@"background-blur" = .{ .radius = 12 };
    try std.testing.expectEqual(
        if (build_config.renderer == .d3d11) @as(?u8, 12) else null,
        windowBackgroundBlurRadius(&config),
    );
}

test "Win32 close tab mode selects the intended tab indexes" {
    const testing = std.testing;

    try testing.expect(tabSelectedForClose(1, 1, .this));
    try testing.expect(!tabSelectedForClose(0, 1, .this));
    try testing.expect(tabSelectedForClose(0, 1, .other));
    try testing.expect(!tabSelectedForClose(1, 1, .other));
    try testing.expect(!tabSelectedForClose(1, 1, .right));
    try testing.expect(tabSelectedForClose(2, 1, .right));
}

test "Win32 automatic tab bar exposes split zoom state" {
    try std.testing.expect(!tabBarVisibleForMode(.auto, 1, false));
    try std.testing.expect(tabBarVisibleForMode(.auto, 2, false));
    try std.testing.expect(tabBarVisibleForMode(.auto, 1, true));
    try std.testing.expect(!tabBarVisibleForMode(.never, 2, true));
    try std.testing.expect(tabBarVisibleForMode(.always, 1, false));
}

test "Win32 split divider thickness follows DPI and high contrast" {
    try std.testing.expectEqual(@as(i32, 1), splitDividerGapForDpi(96, false));
    try std.testing.expectEqual(@as(i32, 2), splitDividerGapForDpi(144, false));
    try std.testing.expectEqual(@as(i32, 2), splitDividerGapForDpi(96, true));
    try std.testing.expectEqual(@as(i32, 3), splitDividerGapForDpi(144, true));
    try std.testing.expectEqual(@as(i32, 4), splitDividerGapForDpi(192, true));
}

fn showWindow(surface: *Surface) void {
    const hwnd = surface.windowHwnd();
    _ = win32.ShowWindow(
        hwnd,
        if (surface.default_maximized)
            win32.SW_MAXIMIZE
        else
            win32.SW_SHOWNORMAL,
    );
    _ = win32.UpdateWindow(hwnd);
    surface.shown = true;
    if (surface.default_fullscreen and !setFullscreen(surface, true)) {
        log.warn("failed to enter configured fullscreen mode", .{});
    }
}

fn getSurface(hwnd: win32.HWND) ?*Surface {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn getTabBarWindow(hwnd: win32.HWND) ?*Window {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn getSplitDividerWindow(hwnd: win32.HWND) ?*Window {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn paintSplitDivider(window: *Window, hwnd: win32.HWND, hdc: win32.HDC) void {
    const index = for (window.split_divider_hwnds.items, 0..) |candidate, value| {
        if (candidate == hwnd) break value;
    } else return;
    if (index >= window.split_dividers.items.len) return;

    const divider = window.split_dividers.items[index];
    const hovered = if (window.split_divider_hover) |value|
        value.split == divider.split
    else
        false;
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(hwnd, &client) == 0) return;
    const app = window.focusedSurface().rtApp();
    const color = splitDividerColor(app.config, hovered, app.high_contrast);
    const brush = win32.CreateSolidBrush(color) orelse return;
    defer _ = win32.DeleteObject(brush);
    _ = win32.FillRect(hdc, &client, brush);
}

fn paintTabBar(self: *App, window: *Window, hdc: win32.HDC, width: i32, height: i32) void {
    updateTabBarViewport(window, width, height);
    const items = self.alloc.alloc(TabBar.Item, window.tabCount()) catch |err| {
        log.warn("failed to allocate tab bar labels: {}", .{err});
        return;
    };
    defer self.alloc.free(items);

    const active = window.activeTabIndex();
    for (items, 0..) |*item, index| {
        const surface = window.focusedSurfaceAt(index) orelse unreachable;
        item.* = .{
            .title = window.tabTitleAt(index) orelse surface.title orelse "Ghostty",
            .active = index == active,
        };
    }
    TabBar.paint(
        self.alloc,
        hdc,
        width,
        height,
        windowDpi(window.hwnd),
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
            if (window.selectTab(.{ .n = index + 1 })) activateWindowTab(self, window);
        },
        .close => |index| {
            const surface = window.focusedSurfaceAt(index) orelse return;
            const core = surface.core_surface orelse return;
            _ = self.closeTab(.{ .surface = core }, .this);
        },
        .scroll_previous => {
            if (window.selectTab(.previous)) activateWindowTab(self, window);
        },
        .scroll_next => {
            if (window.selectTab(.next)) activateWindowTab(self, window);
        },
        .new_tab => {
            const core = window.focusedSurface().core_surface orelse return;
            _ = self.newTab(.{ .surface = core }) catch |err| {
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
        if (window.selectTab(.{ .n = index + 1 })) activateWindowTab(self, window);
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
    self.handleTabBarClick(window, x, y);
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
    if (window.selectTab(.{ .n = index + 1 })) activateWindowTab(self, window);
    _ = self.promptTabTitle(window, index) catch |err| {
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
    if (old_state != new_state) transferWindowState(old_state, new_state);
    updateTabBarViewport(
        window,
        client.right - client.left,
        client.bottom - client.top,
    );
    window.tab_bar_hover = .{ .tab = destination };
    invalidateTabBar(window);
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

    const delta = wheelDelta(wparam);
    if (delta == 0) return;
    const selection: Window.SelectTab = if (msg == win32.WM_MOUSEHWHEEL)
        (if (delta > 0) .next else .previous)
    else if (delta > 0)
        .previous
    else
        .next;
    if (window.selectTab(selection)) activateWindowTab(self, window);
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
        invalidateTabBar(window);
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

fn getModifiers() input.Mods {
    var mods: input.Mods = .{};
    if (win32.GetKeyState(0x10) < 0) {
        mods.shift = true;
        mods.sides.shift = if (win32.GetKeyState(0xA1) < 0) .right else .left;
    }
    if (win32.GetKeyState(0x11) < 0) {
        mods.ctrl = true;
        mods.sides.ctrl = if (win32.GetKeyState(0xA3) < 0) .right else .left;
    }
    if (win32.GetKeyState(0x12) < 0) {
        mods.alt = true;
        mods.sides.alt = if (win32.GetKeyState(0xA5) < 0) .right else .left;
    }
    if (win32.GetKeyState(0x5B) < 0 or win32.GetKeyState(0x5C) < 0) {
        mods.super = true;
        mods.sides.super = if (win32.GetKeyState(0x5C) < 0) .right else .left;
    }

    mods.caps_lock = (win32.GetKeyState(0x14) & 1) != 0;
    mods.num_lock = (win32.GetKeyState(0x90) & 1) != 0;
    return mods;
}

fn keyAction(lparam: win32.LPARAM) input.Action {
    const bits: usize = @bitCast(lparam);
    return if ((bits & (@as(usize, 1) << 30)) != 0) .repeat else .press;
}

fn isExtendedKey(lparam: win32.LPARAM) bool {
    const bits: usize = @bitCast(lparam);
    return (bits & (@as(usize, 1) << 24)) != 0;
}

/// Hardware scan code carried in bits 16-23 of a keyboard message.
fn scanCode(lparam: win32.LPARAM) u32 {
    const bits: usize = @bitCast(lparam);
    return @intCast((bits >> 16) & 0xFF);
}

/// Scan code with the extended-key prefix folded in the way the Chromium
/// keycode table behind `input.keycodes` expects (0xE000 marks extended
/// keys). Zero means the message carried no scan code.
fn nativeKeycode(lparam: win32.LPARAM) u32 {
    const scan = scanCode(lparam);
    if (scan == 0) return 0;
    return if (isExtendedKey(lparam)) 0xE000 | scan else scan;
}

/// Physical key from the scan code. Scan codes identify key positions, so
/// the key at the US `[` position is `bracket_left` on every layout, which
/// is what `physical:` bindings and the default split bindings expect.
fn keyFromScanCode(lparam: win32.LPARAM) input.Key {
    const native = nativeKeycode(lparam);
    if (native == 0) return .unidentified;
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}

/// Resolve the physical key for a keyboard message. The scan code is
/// authoritative; messages synthesized without one (PostMessage from
/// automation, for example) fall back to the virtual-key table, which is
/// only exact for the US layout.
fn mapKey(wparam: win32.WPARAM, lparam: win32.LPARAM) input.Key {
    const key = keyFromScanCode(lparam);
    if (key != .unidentified) return key;
    return mapVirtualKey(wparam, lparam);
}

fn mapVirtualKey(vk: win32.WPARAM, lparam: win32.LPARAM) input.Key {
    return switch (vk) {
        0x41 => .key_a,
        0x42 => .key_b,
        0x43 => .key_c,
        0x44 => .key_d,
        0x45 => .key_e,
        0x46 => .key_f,
        0x47 => .key_g,
        0x48 => .key_h,
        0x49 => .key_i,
        0x4A => .key_j,
        0x4B => .key_k,
        0x4C => .key_l,
        0x4D => .key_m,
        0x4E => .key_n,
        0x4F => .key_o,
        0x50 => .key_p,
        0x51 => .key_q,
        0x52 => .key_r,
        0x53 => .key_s,
        0x54 => .key_t,
        0x55 => .key_u,
        0x56 => .key_v,
        0x57 => .key_w,
        0x58 => .key_x,
        0x59 => .key_y,
        0x5A => .key_z,
        0x30 => .digit_0,
        0x31 => .digit_1,
        0x32 => .digit_2,
        0x33 => .digit_3,
        0x34 => .digit_4,
        0x35 => .digit_5,
        0x36 => .digit_6,
        0x37 => .digit_7,
        0x38 => .digit_8,
        0x39 => .digit_9,
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => if (isExtendedKey(lparam)) .numpad_enter else .enter,
        0x10 => if (((@as(usize, @bitCast(lparam)) >> 16) & 0xFF) == 0x36)
            .shift_right
        else
            .shift_left,
        0x11 => if (isExtendedKey(lparam)) .control_right else .control_left,
        0x12 => if (isExtendedKey(lparam)) .alt_right else .alt_left,
        0x13 => .pause,
        0x14 => .caps_lock,
        0x15 => .kana_mode,
        0x1B => .escape,
        0x1C => .convert,
        0x1D => .non_convert,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .arrow_left,
        0x26 => .arrow_up,
        0x27 => .arrow_right,
        0x28 => .arrow_down,
        0x2C => .print_screen,
        0x2D => .insert,
        0x2E => .delete,
        0x5B => .meta_left,
        0x5C => .meta_right,
        0x5D => .context_menu,
        0x60 => .numpad_0,
        0x61 => .numpad_1,
        0x62 => .numpad_2,
        0x63 => .numpad_3,
        0x64 => .numpad_4,
        0x65 => .numpad_5,
        0x66 => .numpad_6,
        0x67 => .numpad_7,
        0x68 => .numpad_8,
        0x69 => .numpad_9,
        0x6A => .numpad_multiply,
        0x6B => .numpad_add,
        0x6C => .numpad_separator,
        0x6D => .numpad_subtract,
        0x6E => .numpad_decimal,
        0x6F => .numpad_divide,
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        0x7C => .f13,
        0x7D => .f14,
        0x7E => .f15,
        0x7F => .f16,
        0x80 => .f17,
        0x81 => .f18,
        0x82 => .f19,
        0x83 => .f20,
        0x84 => .f21,
        0x85 => .f22,
        0x86 => .f23,
        0x87 => .f24,
        0x90 => .num_lock,
        0x91 => .scroll_lock,
        0xBA => .semicolon,
        0xBB => .equal,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        0xC0 => .backquote,
        0xDB => .bracket_left,
        0xDC => .backslash,
        0xDD => .bracket_right,
        0xDE => .quote,
        else => .unidentified,
    };
}

fn isTextVirtualKey(vk: win32.WPARAM) bool {
    return switch (vk) {
        0x30...0x39,
        0x41...0x5A,
        0x20,
        0xBA...0xC0,
        // VK_OEM_4..VK_OEM_8 and VK_OEM_102: the last two only exist on
        // non-US layouts (for example the key left of Z on ISO keyboards).
        0xDB...0xDF,
        0xE2,
        // VK_NUMPAD0..VK_DIVIDE: with NumLock on, the numpad also produces
        // WM_CHAR. Dispatching the key press as well would send its digit or
        // operator twice, so it travels with the text like the main-row keys.
        // With NumLock off these keys arrive as navigation virtual keys.
        0x60...0x6F,
        => true,
        else => false,
    };
}

fn isAltGr(mods: input.Mods) bool {
    return mods.ctrl and mods.alt and mods.sides.alt == .right;
}

fn consumedTextModifiers(mods: input.Mods) input.Mods {
    var consumed: input.Mods = .{};
    if (isAltGr(mods)) {
        consumed.ctrl = true;
        consumed.alt = true;
    }
    if (mods.shift) {
        consumed.shift = true;
    }
    return consumed;
}

fn shouldDispatchKeyPress(vk: win32.WPARAM, mods: input.Mods) bool {
    if (!isTextVirtualKey(vk)) return true;
    if (mods.super) return true;
    if (mods.alt and !isAltGr(mods)) return true;
    if (mods.ctrl and !isAltGr(mods)) return true;
    return false;
}

/// Codepoint the key produces with no modifier held in the active keyboard
/// layout. Bindings written as `ctrl+;` must match the key that types `;`
/// on the user's layout, not the US position of VK_OEM_1.
fn unshiftedCodepoint(vk: win32.WPARAM, lparam: win32.LPARAM) u21 {
    if (layoutUnshiftedCodepoint(vk, lparam)) |codepoint| return codepoint;
    return unshiftedCodepointUS(vk);
}

/// Translate the key through the active layout with an empty modifier
/// state. Returns null for dead keys and keys without a text translation,
/// leaving the caller to decide on a fallback.
fn layoutUnshiftedCodepoint(vk: win32.WPARAM, lparam: win32.LPARAM) ?u21 {
    var key_state = [_]u8{0} ** 256;
    var buffer: [4:0]u16 = .{ 0, 0, 0, 0 };
    const layout = win32.GetKeyboardLayout(0);
    // Flag 0x4 (Windows 10 1607+) keeps the thread's dead-key state intact
    // so this lookup never swallows a pending accent.
    const written = win32.ToUnicodeEx(
        @intCast(vk),
        scanCode(lparam),
        &key_state,
        &buffer,
        buffer.len,
        0x4,
        layout,
    );
    if (written <= 0) return null;

    var pending: ?u16 = null;
    const codepoint = decodeUtf16CodeUnit(&pending, buffer[0]) orelse first: {
        if (written < 2) return null;
        break :first decodeUtf16CodeUnit(&pending, buffer[1]) orelse return null;
    };
    if (codepoint < 0x20 or codepoint == 0x7F) return null;
    return codepoint;
}

/// US layout fallback for the unshifted codepoint when the active layout
/// has no translation for the key.
fn unshiftedCodepointUS(vk: win32.WPARAM) u21 {
    return switch (vk) {
        0x41...0x5A => @intCast(vk + ('a' - 'A')),
        0x30...0x39 => @intCast(vk),
        0x20 => ' ',
        0xBA => ';',
        0xBB => '=',
        0xBC => ',',
        0xBD => '-',
        0xBE => '.',
        0xBF => '/',
        0xC0 => '`',
        0xDB => '[',
        0xDC => '\\',
        0xDD => ']',
        0xDE => '\'',
        else => 0,
    };
}

fn decodeUtf16CodeUnit(pending: *?u16, unit: u16) ?u21 {
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        pending.* = unit;
        return null;
    }

    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        const high = pending.* orelse return null;
        pending.* = null;
        return 0x10000 +
            (@as(u21, high - 0xD800) << 10) +
            @as(u21, unit - 0xDC00);
    }

    pending.* = null;
    return unit;
}

fn handleTextInput(surface: *Surface, wparam: win32.WPARAM) win32.LRESULT {
    const unit: u16 = @truncate(wparam);
    const codepoint = decodeUtf16CodeUnit(&surface.pending_high_surrogate, unit) orelse
        return 0;
    defer surface.pending_text_key = null;

    // Control characters are already represented by their WM_KEYDOWN event.
    if (codepoint < 0x20 or codepoint == 0x7F) return 0;

    const core = surface.core_surface orelse return 0;
    const pending = surface.pending_text_key;
    const mods = if (pending) |value| value.mods else getModifiers();

    // Left-Alt shortcuts were dispatched as physical key events. WM_SYSCHAR
    // must not send a second text event for the same keystroke.
    if (mods.alt and !isAltGr(mods) and pending == null) return 0;

    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch return 0;
    const consumed_mods = consumedTextModifiers(mods);

    const event: input.KeyEvent = .{
        .action = if (pending) |value| value.action else .press,
        .key = if (pending) |value| value.key else .unidentified,
        .mods = mods,
        .consumed_mods = consumed_mods,
        .utf8 = utf8_buf[0..len],
        .unshifted_codepoint = if (pending) |value|
            value.unshifted_codepoint
        else
            0,
    };
    _ = core.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
    return 0;
}

const MouseButtonEvent = struct {
    button: input.MouseButton,
    state: input.MouseButtonState,
    bit: u8,
    xbutton: bool = false,
};

fn mouseButtonEvent(msg: u32, wparam: win32.WPARAM) ?MouseButtonEvent {
    return switch (msg) {
        win32.WM_LBUTTONDOWN => .{ .button = .left, .state = .press, .bit = 1 << 0 },
        win32.WM_LBUTTONUP => .{ .button = .left, .state = .release, .bit = 1 << 0 },
        win32.WM_RBUTTONDOWN => .{ .button = .right, .state = .press, .bit = 1 << 1 },
        win32.WM_RBUTTONUP => .{ .button = .right, .state = .release, .bit = 1 << 1 },
        win32.WM_MBUTTONDOWN => .{ .button = .middle, .state = .press, .bit = 1 << 2 },
        win32.WM_MBUTTONUP => .{ .button = .middle, .state = .release, .bit = 1 << 2 },
        win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => x: {
            const xbutton: u16 = @truncate(wparam >> 16);
            const state: input.MouseButtonState = if (msg == win32.WM_XBUTTONDOWN)
                .press
            else
                .release;
            break :x switch (xbutton) {
                1 => .{ .button = .four, .state = state, .bit = 1 << 3, .xbutton = true },
                2 => .{ .button = .five, .state = state, .bit = 1 << 4, .xbutton = true },
                else => null,
            };
        },
        else => null,
    };
}

fn signedLowWord(value: usize) i16 {
    return @bitCast(@as(u16, @truncate(value)));
}

fn signedHighWord(value: usize) i16 {
    return @bitCast(@as(u16, @truncate(value >> 16)));
}

fn mousePoint(lparam: win32.LPARAM) apprt.CursorPos {
    const bits: usize = @bitCast(lparam);
    return .{
        .x = @floatFromInt(signedLowWord(bits)),
        .y = @floatFromInt(signedHighWord(bits)),
    };
}

fn mouseClientPoint(lparam: win32.LPARAM) win32.POINT {
    const bits: usize = @bitCast(lparam);
    return .{
        .x = signedLowWord(bits),
        .y = signedHighWord(bits),
    };
}

fn pointInWindowClient(
    surface: *Surface,
    source_hwnd: win32.HWND,
    local: win32.POINT,
) ?win32.POINT {
    var point = local;
    if (win32.ClientToScreen(source_hwnd, &point) == 0) {
        log.warn("ClientToScreen(split pointer) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return null;
    }
    if (win32.ScreenToClient(surface.windowHwnd(), &point) == 0) {
        log.warn("ScreenToClient(split pointer) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return null;
    }
    return point;
}

fn currentWindowContentBounds(
    app: *const App,
    window: *const Window,
) ?Window.Rect {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect(split pointer) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
        return null;
    }
    return windowContentBounds(app, window, client);
}

fn scaledSplitHitSlop(window: *const Window) i32 {
    const dpi: i64 = windowDpi(window.hwnd);
    return @intCast(@max(
        1,
        @divTrunc(@as(i64, split_divider_hit_slop) * dpi + 95, 96),
    ));
}

fn splitMinimumExtent(
    window: *const Window,
    direction: Window.ResizeDirection,
) i32 {
    var result: i64 = 1;
    const surfaces = window.surfacesAt(window.activeTabIndex()) orelse return 1;
    for (surfaces) |surface| {
        const core = surface.core_surface orelse continue;
        const extent: i64 = switch (direction) {
            .horizontal => @as(i64, core.size.cell.width) * CoreSurface.min_window_width_cells +
                core.size.padding.left + core.size.padding.right,
            .vertical => @as(i64, core.size.cell.height) * CoreSurface.min_window_height_cells +
                core.size.padding.top + core.size.padding.bottom,
        };
        result = @max(result, extent);
    }
    return @intCast(@min(result, std.math.maxInt(i32)));
}

fn setSplitCursor(direction: Window.ResizeDirection) void {
    const cursor = win32.LoadCursorW(
        null,
        switch (direction) {
            .horizontal => win32.IDC_SIZEWE,
            .vertical => win32.IDC_SIZENS,
        },
    );
    if (cursor) |handle| _ = win32.SetCursor(handle);
}

fn dividerAtPoint(
    surface: *Surface,
    window: *Window,
    point: win32.POINT,
) ?Window.Divider {
    const app = surface.rtApp();
    const bounds = currentWindowContentBounds(app, window) orelse return null;
    return window.dividerAt(
        bounds,
        splitDividerGap(window),
        point.x,
        point.y,
        scaledSplitHitSlop(window),
    );
}

fn setSplitDividerHover(window: *Window, value: ?Window.Divider) void {
    if (std.meta.eql(window.split_divider_hover, value)) return;
    window.split_divider_hover = value;
    invalidateSplitDividers(window);
}

fn trackSplitDividerMouseLeave(window: *Window, hwnd: win32.HWND) void {
    if (window.split_divider_tracking_mouse_leave) return;
    var event: win32.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (win32.TrackMouseEvent(&event) != 0) {
        window.split_divider_tracking_mouse_leave = true;
    }
}

fn updateSplitDividerPointer(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
) bool {
    const app = surface.rtApp();
    const window = app.windowForSurface(surface) orelse return false;
    const point = pointInWindowClient(
        surface,
        hwnd,
        mouseClientPoint(lparam),
    ) orelse return false;

    if (window.split_divider_drag) |*drag| {
        if (drag.capture_hwnd != hwnd) return false;
        const delta = switch (drag.divider.direction) {
            .horizontal => point.x - drag.last_x,
            .vertical => point.y - drag.last_y,
        };
        drag.last_x = point.x;
        drag.last_y = point.y;
        if (delta != 0) {
            const bounds = currentWindowContentBounds(app, window) orelse return true;
            if (window.resizeDivider(
                drag.divider,
                delta,
                bounds,
                splitDividerGap(window),
                splitMinimumExtent(window, drag.divider.direction),
            )) app.layoutWindow(window);
        }
        setSplitCursor(drag.divider.direction);
        return true;
    }

    setSplitDividerHover(window, dividerAtPoint(surface, window, point));
    if (window.split_divider_hover) |divider| {
        setSplitCursor(divider.direction);
        return true;
    }
    return false;
}

fn beginSplitDividerDrag(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
) bool {
    if (surface.mouse_buttons_down != 0) return false;
    const window = surface.rtApp().windowForSurface(surface) orelse return false;
    const point = pointInWindowClient(
        surface,
        hwnd,
        mouseClientPoint(lparam),
    ) orelse return false;
    const divider = dividerAtPoint(surface, window, point) orelse return false;

    setSplitDividerHover(window, divider);
    window.split_divider_drag = .{
        .divider = divider,
        .last_x = point.x,
        .last_y = point.y,
        .capture_hwnd = hwnd,
    };
    _ = win32.SetCapture(hwnd);
    setSplitCursor(divider.direction);
    return true;
}

fn endSplitDividerDrag(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
) bool {
    const window = surface.rtApp().windowForSurface(surface) orelse return false;
    const drag = window.split_divider_drag orelse return false;
    if (drag.capture_hwnd != hwnd) return false;

    window.split_divider_drag = null;
    if (pointInWindowClient(surface, hwnd, mouseClientPoint(lparam))) |point| {
        setSplitDividerHover(window, dividerAtPoint(surface, window, point));
    } else {
        setSplitDividerHover(window, null);
    }
    if (win32.GetCapture() == hwnd and win32.ReleaseCapture() == 0) {
        log.warn("ReleaseCapture(split divider) failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
    }
    return true;
}

fn cancelSplitDividerDrag(surface: *Surface, hwnd: win32.HWND) void {
    const window = surface.rtApp().windowForSurface(surface) orelse return;
    if (window.split_divider_drag) |drag| {
        if (drag.capture_hwnd != hwnd) return;
        window.split_divider_drag = null;
    }
    setSplitDividerHover(window, null);
}

fn clearWindowSplitPointer(window: *Window) void {
    const capture = if (window.split_divider_drag) |drag|
        drag.capture_hwnd
    else
        null;
    window.split_divider_drag = null;
    setSplitDividerHover(window, null);
    window.split_divider_tracking_mouse_leave = false;
    if (capture) |hwnd| {
        if (win32.GetCapture() == hwnd and win32.ReleaseCapture() == 0) {
            log.warn("ReleaseCapture(split reset) failed: err={d}", .{
                @intFromEnum(win32.GetLastError()),
            });
        }
    }
}

fn handleSplitDividerCursor(surface: *Surface) bool {
    const window = surface.rtApp().windowForSurface(surface) orelse return false;
    if (window.split_divider_drag) |drag| {
        setSplitCursor(drag.divider.direction);
        return true;
    }

    var point: win32.POINT = undefined;
    if (win32.GetCursorPos(&point) == 0 or
        win32.ScreenToClient(window.hwnd, &point) == 0)
    {
        return false;
    }
    setSplitDividerHover(window, dividerAtPoint(surface, window, point));
    if (window.split_divider_hover) |divider| {
        setSplitCursor(divider.direction);
        return true;
    }
    return false;
}

fn wheelDelta(wparam: win32.WPARAM) i16 {
    return signedHighWord(wparam);
}

fn dpiScale(wparam: win32.WPARAM) apprt.ContentScale {
    const default_dpi: f32 = @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI);
    const x: u16 = @truncate(wparam);
    const y: u16 = @truncate(wparam >> 16);
    return .{
        .x = @as(f32, @floatFromInt(x)) / default_dpi,
        .y = @as(f32, @floatFromInt(y)) / default_dpi,
    };
}

fn accumulateWheelTicks(remainder: *i32, delta: i16) i32 {
    remainder.* += delta;
    const wheel_delta: i32 = @intCast(win32.WHEEL_DELTA);
    const ticks = @divTrunc(remainder.*, wheel_delta);
    remainder.* -= ticks * wheel_delta;
    return ticks;
}

fn updateCursorPosition(
    surface: *Surface,
    pos: apprt.CursorPos,
    mods: input.Mods,
    force: bool,
) void {
    const previous = surface.cursor_pos;
    surface.cursor_pos = pos;
    if (!force and previous.x == pos.x and previous.y == pos.y) return;

    const core = surface.core_surface orelse return;
    core.cursorPosCallback(pos, mods) catch |err| {
        log.err("cursor position callback error: {}", .{err});
    };
}

fn trackMouseLeave(surface: *Surface, hwnd: win32.HWND) void {
    if (surface.tracking_mouse_leave) return;

    var event: win32.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
        .dwFlags = win32.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    if (win32.TrackMouseEvent(&event) == 0) {
        log.warn("TrackMouseEvent failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    }
    surface.tracking_mouse_leave = true;
}

fn handleMouseButton(
    surface: *Surface,
    hwnd: win32.HWND,
    event: MouseButtonEvent,
    lparam: win32.LPARAM,
) win32.LRESULT {
    const mods = getModifiers();
    updateCursorPosition(surface, mousePoint(lparam), mods, true);

    if (event.state == .press) {
        // Child windows never take keyboard focus on their own. Without this,
        // clicking an unfocused split leaves typing in the previously focused
        // pane, which makes the clicked pane look unresponsive. The surface
        // WM_SETFOCUS handler updates the window's active tab and focused
        // surface, so the tab bar follows along.
        if (win32.GetFocus() != hwnd) _ = win32.SetFocus(hwnd);

        if (surface.mouse_buttons_down == 0) _ = win32.SetCapture(hwnd);
        surface.mouse_buttons_down |= event.bit;
    } else {
        surface.mouse_buttons_down &= ~event.bit;
    }

    if (surface.core_surface) |core| {
        const consumed = core.mouseButtonCallback(event.state, event.button, mods) catch |err| consumed: {
            log.err("mouse button callback error: {}", .{err});
            break :consumed true;
        };

        // The core leaves a right press unconsumed when right-click-action
        // is context-menu and the program is not capturing the mouse. Like
        // other Windows applications, open the menu on release.
        if (event.button == .right and event.state == .press) {
            surface.context_menu_pending = !consumed;
        }
    }

    if (event.state == .release and surface.mouse_buttons_down == 0 and
        win32.GetCapture() == hwnd)
    {
        if (win32.ReleaseCapture() == 0) {
            log.warn("ReleaseCapture failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }

    if (event.state == .release and event.button == .right and surface.context_menu_pending) {
        surface.context_menu_pending = false;
        if (surface.core_surface) |core| {
            // The menu may close this surface, so nothing touches it afterwards.
            ContextMenu.show(surface.rtApp().alloc, hwnd, core, mouseClientPoint(lparam));
        }
        return 0;
    }

    // XBUTTON messages require TRUE to prevent further processing.
    return if (event.xbutton) 1 else 0;
}

fn releaseMouseButtons(surface: *Surface) void {
    const down = surface.mouse_buttons_down;
    if (down == 0) return;
    // Capture was taken away mid-click, so the right release that would open
    // the context menu is never coming.
    surface.context_menu_pending = false;
    surface.mouse_buttons_down = 0;

    const buttons = [_]struct { u8, input.MouseButton }{
        .{ 1 << 0, .left },
        .{ 1 << 1, .right },
        .{ 1 << 2, .middle },
        .{ 1 << 3, .four },
        .{ 1 << 4, .five },
    };
    const core = surface.core_surface orelse return;
    const mods = getModifiers();
    for (buttons) |entry| {
        if (down & entry[0] == 0) continue;
        _ = core.mouseButtonCallback(.release, entry[1], mods) catch |err| {
            log.err("mouse capture release callback error: {}", .{err});
        };
    }
}

fn updateWheelCursorPosition(
    surface: *Surface,
    hwnd: win32.HWND,
    lparam: win32.LPARAM,
    mods: input.Mods,
) void {
    const screen_pos = mousePoint(lparam);
    var point: win32.POINT = .{
        .x = @intFromFloat(screen_pos.x),
        .y = @intFromFloat(screen_pos.y),
    };
    if (win32.ScreenToClient(hwnd, &point) == 0) {
        log.warn("ScreenToClient failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    }
    updateCursorPosition(surface, .{
        .x = @floatFromInt(point.x),
        .y = @floatFromInt(point.y),
    }, mods, true);
}

fn handleMouseWheel(
    surface: *Surface,
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) void {
    const mods = getModifiers();
    updateWheelCursorPosition(surface, hwnd, lparam, mods);

    const core = surface.core_surface orelse return;
    const delta: i32 = wheelDelta(wparam);
    if (msg == win32.WM_MOUSEWHEEL) {
        if (surface.scrollbar) |bar| bar.reveal();
        const ticks = @as(f64, @floatFromInt(delta)) /
            @as(f64, @floatFromInt(win32.WHEEL_DELTA));
        core.scrollCallback(0, ticks, .{}) catch |err| {
            log.err("vertical scroll callback error: {}", .{err});
        };
        return;
    }

    const ticks = accumulateWheelTicks(&surface.horizontal_wheel_remainder, @intCast(delta));
    if (ticks == 0) return;
    core.scrollCallback(@floatFromInt(ticks), 0, .{}) catch |err| {
        log.err("horizontal scroll callback error: {}", .{err});
    };
}

fn handleDpiChanged(
    surface: *Surface,
    hwnd: win32.HWND,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) void {
    if (surface.core_surface) |core| {
        core.contentScaleCallback(dpiScale(wparam)) catch |err| {
            log.err("content scale callback error: {}", .{err});
        };
    }

    if (lparam == 0) return;
    const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (win32.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) {
        log.warn("SetWindowPos for DPI change failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

fn handleFocus(surface: *Surface, focused: bool) void {
    if (!focused) {
        surface.pending_text_key = null;
        surface.pending_high_surrogate = null;
        releaseMouseButtons(surface);
    }

    surface.rtApp().core_app.focusEvent(focused);
    if (surface.core_surface) |core| {
        core.focusCallback(focused) catch |err| {
            log.err("focus callback error: {}", .{err});
        };
    }
}

fn handleImeStartComposition(surface: *Surface, hwnd: win32.HWND) void {
    const core = surface.core_surface orelse return;

    const cursor = cursor: {
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        break :cursor core.renderer_state.terminal.screens.active.cursor;
    };

    const context = win32.ImmGetContext(hwnd) orelse {
        log.debug("IME composition started without an input context", .{});
        return;
    };
    defer _ = win32.ImmReleaseContext(hwnd, context);

    const point: win32.POINT = .{
        .x = @intCast(cursor.x * core.size.cell.width + core.size.padding.left),
        .y = @intCast(cursor.y * core.size.cell.height + core.size.padding.top),
    };
    var form: win32.COMPOSITIONFORM = .{
        .dwStyle = win32.CFS_POINT,
        .ptCurrentPos = point,
        .rcArea = std.mem.zeroes(win32.RECT),
    };
    if (win32.ImmSetCompositionWindow(context, &form) == 0) {
        log.warn("ImmSetCompositionWindow failed", .{});
    } else {
        log.debug("positioned IME composition window x={d} y={d}", .{ point.x, point.y });
    }
}

fn splitDividerWndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_ERASEBKGND => return 1,
        win32.WM_NCHITTEST => return win32.HTTRANSPARENT,
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = std.mem.zeroes(win32.PAINTSTRUCT);
            const hdc = win32.BeginPaint(hwnd, &ps) orelse {
                _ = win32.EndPaint(hwnd, &ps);
                return 0;
            };
            if (getSplitDividerWindow(hwnd)) |window| {
                paintSplitDivider(window, hwnd, hdc);
            }
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn tabBarWndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_GETOBJECT => {
            if (@as(i32, @truncate(lparam)) != objid_client) {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            const window = getTabBarWindow(hwnd) orelse {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            };
            const accessibility = tabBarAccessibility(window) orelse {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            };
            return accessibility.objectResult(wparam);
        },
        TabBarAccessibility.select_message => {
            const window = getTabBarWindow(hwnd) orelse return 0;
            if (wparam == 0 or wparam > window.tabCount()) return 0;
            if (window.selectTab(.{ .n = wparam })) {
                activateWindowTab(window.focusedSurface().rtApp(), window);
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
                    window.focusedSurface().rtApp().paintTabBar(
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
                window.focusedSurface().rtApp().handleTabBarButtonUp(
                    hwnd,
                    window,
                    signedLowWord(bits),
                    signedHighWord(bits),
                );
            }
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            if (getTabBarWindow(hwnd)) |window| {
                const bits: usize = @bitCast(lparam);
                window.focusedSurface().rtApp().handleTabBarButtonDown(
                    hwnd,
                    window,
                    signedLowWord(bits),
                    signedHighWord(bits),
                );
            }
            return 0;
        },
        win32.WM_LBUTTONDBLCLK => {
            if (getTabBarWindow(hwnd)) |window| {
                const bits: usize = @bitCast(lparam);
                window.focusedSurface().rtApp().handleTabBarDoubleClick(
                    hwnd,
                    window,
                    signedLowWord(bits),
                    signedHighWord(bits),
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
                    signedLowWord(bits),
                    signedHighWord(bits),
                );
                updateTabBarDrag(
                    window,
                    signedLowWord(bits),
                    signedHighWord(bits),
                );
            }
            return 0;
        },
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            if (getTabBarWindow(hwnd)) |window| {
                window.focusedSurface().rtApp().handleTabBarWheel(
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
                invalidateTabBar(window);
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

fn handleFileDrop(surface: *Surface, drop: win32.HDROP) !void {
    const core = surface.core_surface orelse return;
    const alloc = surface.rtApp().alloc;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const temp = arena.allocator();

    const count = win32.DragQueryFileW(drop, 0xffffffff, null, 0);
    if (count == 0) return;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (0..count) |index| {
        const length = win32.DragQueryFileW(drop, @intCast(index), null, 0);
        if (length == 0) return error.InvalidPath;
        const wide = try temp.allocSentinel(u16, length, 0);
        const copied = win32.DragQueryFileW(drop, @intCast(index), wide.ptr, length + 1);
        if (copied != length) return error.InvalidPath;
        try paths.append(temp, try std.unicode.utf16LeToUtf8Alloc(temp, wide[0..length]));
    }
    const formatted = try FileDrop.formatPaths(temp, surface.file_drop_shell, paths.items);
    core.pasteExternalText(formatted, false) catch |err| switch (err) {
        error.UnsafePaste => {
            const caption = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty File Drop");
            const message = std.unicode.utf8ToUtf16LeStringLiteral(
                "The dropped paths may contain unsafe text. Paste them into the terminal?",
            );
            const style: win32.MESSAGEBOX_STYLE = .{
                .YESNO = 1,
                .ICONQUESTION = 1,
                .DEFBUTTON2 = 1,
            };
            if (win32.MessageBoxW(surface.windowHwnd(), message, caption, style) != win32.IDYES) return;
            try core.pasteExternalText(formatted, true);
        },
        else => return err,
    };
}

fn showFileDropWarning(surface: *Surface, message: []const u8) void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(surface.rtApp().alloc, message) catch return;
    defer surface.rtApp().alloc.free(wide);
    const caption = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty File Drop");
    const style: win32.MESSAGEBOX_STYLE = .{ .ICONHAND = 1 };
    _ = win32.MessageBoxW(surface.windowHwnd(), wide, caption, style);
}

fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_DROPFILES => {
            const drop: win32.HDROP = @ptrFromInt(wparam);
            defer win32.DragFinish(drop);
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    handleFileDrop(surface, drop) catch |err| {
                        log.warn("file drop failed: {}", .{err});
                        showFileDropWarning(surface, switch (err) {
                            error.CmdExpansion => "cmd expands % and ! in paths. This file drop was rejected.",
                            error.UnsupportedShell => "File drop supports PowerShell and cmd startup shells.",
                            else => "The dropped files could not be pasted.",
                        });
                    };
                }
            }
            return 0;
        },
        win32.WM_CLOSE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    const app = surface.rtApp();
                    if (app.windowForHwnd(hwnd)) |window| {
                        _ = app.closeOwnedWindow(window);
                    }
                } else if (surface.core_surface) |core| {
                    core.close();
                } else {
                    surface.rtApp().requestSurfaceClose(surface, false);
                }
            } else {
                _ = win32.DestroyWindow(hwnd);
            }
            return 0;
        },
        WM_CLOSE_SURFACE => {
            if (lparam != 0) {
                // Resolve the app through the receiving window rather than
                // the posted pointer, and only dereference the pointer once
                // it is confirmed to be a live surface owned by this app.
                const owner = getSurface(hwnd) orelse return 0;
                const app = owner.rtApp();
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (app.windowForSurface(surface) == null) {
                    log.warn("ignoring close request for a surface that no longer exists", .{});
                    return 0;
                }
                // Allow a later request, for example after a declined
                // confirmation dialog.
                surface.close_requested = false;
                app.closeSurface(surface, wparam != 0);
            }
            return 0;
        },
        WM_SHOW_COMMAND_PALETTE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    surface.rtApp().showCommandPalette(surface) catch |err| {
                        log.warn("command palette failed: {}", .{err});
                    };
                }
            }
            return 0;
        },
        WM_TEST_RECOVER_RENDERER => {
            if (comptime !build_config.win32_test_hooks) {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            if (getSurface(hwnd)) |surface| {
                const app = surface.rtApp();
                if (app.test_device_recovery) {
                    if (surface.core_surface) |core| {
                        core.recoverRenderer() catch |err| {
                            log.err("failed to schedule test renderer recovery: {}", .{err});
                        };
                    }
                }
            }
            return 0;
        },
        WM_TEST_RECOVERY_STATUS => {
            if (comptime !build_config.win32_test_hooks) {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            if (getSurface(hwnd)) |surface| {
                if (surface.rtApp().test_device_recovery) {
                    // wparam 1 probes whether the hooks are compiled in and
                    // enabled, so scripts can fail early with a clear message
                    // instead of timing out against a release executable.
                    if (wparam == 1) return 1;
                    return @intCast(surface.gpu_recovery_count.load(.seq_cst));
                }
            }
            return 0;
        },
        win32.WM_POWERBROADCAST => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    surface.rtApp().handlePowerBroadcast(@intCast(wparam));
                }
            }
            return 1;
        },
        win32.WM_SIZE => {
            if (getSurface(hwnd)) |surface| {
                const width: u32 = @intCast(lparam & 0xFFFF);
                const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
                if (width > 0 and height > 0) {
                    if (hwnd == surface.windowHwnd()) {
                        const app = surface.rtApp();
                        if (app.windowForHwnd(hwnd)) |window| app.layoutWindow(window);
                    } else if (hwnd == surface.hwnd) {
                        surface.width = width;
                        surface.height = height;
                        if (surface.core_surface) |core| {
                            core.sizeCallback(.{
                                .width = width,
                                .height = height,
                            }) catch |err| {
                                log.err("size callback error: {}", .{err});
                            };
                        }
                    }
                }
            }
            return 0;
        },
        win32.WM_MOVE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    const app = surface.rtApp();
                    if (app.windowForHwnd(hwnd)) |window| {
                        app.layoutWindow(window);
                    }
                }
            }
            return 0;
        },
        win32.WM_DPICHANGED => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    const app = surface.rtApp();
                    if (app.windowForHwnd(hwnd)) |window| {
                        var surfaces = window.surfaceIterator();
                        while (surfaces.next()) |candidate| {
                            if (candidate == surface) continue;
                            if (candidate.core_surface) |core| {
                                core.contentScaleCallback(dpiScale(wparam)) catch |err| {
                                    log.err("content scale callback error: {}", .{err});
                                };
                            }
                        }
                        handleDpiChanged(surface, hwnd, wparam, lparam);
                        app.layoutWindow(window);
                        return 0;
                    }
                }
            }
            return 0;
        },
        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    if (msg == win32.WM_SETFOCUS) {
                        const focus = if (surface.rtApp().windowForHwnd(hwnd)) |window|
                            window.focusedSurface()
                        else
                            surface;
                        _ = win32.SetFocus(focus.hwnd);
                    }
                } else if (hwnd == surface.hwnd) {
                    if (msg == win32.WM_SETFOCUS) {
                        if (surface.rtApp().windowForSurface(surface)) |window| {
                            const previous_tab = window.active_tab;
                            _ = window.setFocusedSurface(surface);
                            invalidateTabBar(window);
                            if (window.active_tab != previous_tab) {
                                surface.rtApp().syncTabBarAccessibility(window, true, false);
                            }
                            _ = win32.SetWindowLongPtrW(
                                window.hwnd,
                                win32.GWLP_USERDATA,
                                @bitCast(@intFromPtr(surface)),
                            );
                        }
                        surface.syncTitle();
                    }
                    handleFocus(surface, msg == win32.WM_SETFOCUS);
                }
            }
            return 0;
        },
        win32.WM_SHOWWINDOW => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    const app = surface.rtApp();
                    const window = app.windowForHwnd(hwnd) orelse return 0;
                    if (wparam != 0) {
                        app.layoutWindow(window);
                    } else {
                        if (window.tab_bar_hwnd) |tab_bar| {
                            _ = win32.ShowWindow(tab_bar, win32.SW_HIDE);
                        }
                        hideSplitDividers(window, 0);
                    }
                    var surfaces = window.surfaceIterator();
                    while (surfaces.next()) |candidate| {
                        if (candidate.core_surface) |core| {
                            core.occlusionCallback(wparam != 0) catch |err| {
                                log.err("visibility callback error: {}", .{err});
                            };
                        }
                    }
                }
            }
            return 0;
        },
        win32.WM_SETTINGCHANGE, win32.WM_SYSCOLORCHANGE, win32.WM_THEMECHANGED => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    const app = surface.rtApp();
                    if (app.windowForHwnd(hwnd)) |window| {
                        app.high_contrast = highContrastEnabled();
                        Titlebar.apply(hwnd, app.config, app.high_contrast);
                        var bars = window.surfaceIterator();
                        while (bars.next()) |candidate| {
                            if (candidate.scrollbar) |bar| bar.setAppearance(app.config.background, app.high_contrast);
                        }
                        app.layoutWindow(window);
                        invalidateTabBar(window);
                        invalidateSplitDividers(window);
                    }
                }
            }
            return 0;
        },
        win32.WM_IME_STARTCOMPOSITION => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) handleImeStartComposition(surface, hwnd);
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_PAINT => {
            // Validate the update region here. The renderer thread owns the
            // WGL context and presents completed frames with SwapBuffers.
            var ps: win32.PAINTSTRUCT = std.mem.zeroes(win32.PAINTSTRUCT);
            _ = win32.BeginPaint(hwnd, &ps);
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        win32.WM_SETCURSOR => {
            if (getSurface(hwnd)) |surface| {
                if ((hwnd == surface.hwnd or hwnd == surface.windowHwnd()) and
                    handleSplitDividerCursor(surface))
                {
                    return 1;
                }
                if (hwnd == surface.hwnd and @as(u16, @truncate(@as(usize, @bitCast(lparam)))) == win32.HTCLIENT) {
                    Mouse.apply(surface);
                    return 1;
                }
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_MOUSEMOVE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    trackMouseLeave(surface, hwnd);
                    if (surface.scrollbar) |bar| bar.hoverAt(@intFromFloat(mousePoint(lparam).x));
                    if (updateSplitDividerPointer(surface, hwnd, lparam)) return 0;
                    updateCursorPosition(surface, mousePoint(lparam), getModifiers(), false);
                } else if (hwnd == surface.windowHwnd()) {
                    if (surface.rtApp().windowForSurface(surface)) |window| {
                        trackSplitDividerMouseLeave(window, hwnd);
                    }
                    _ = updateSplitDividerPointer(surface, hwnd, lparam);
                }
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    surface.tracking_mouse_leave = false;
                    if (surface.rtApp().windowForSurface(surface)) |window| {
                        if (window.split_divider_drag == null) {
                            setSplitDividerHover(window, null);
                        }
                    }
                    updateCursorPosition(surface, .{ .x = -1, .y = -1 }, getModifiers(), true);
                } else if (hwnd == surface.windowHwnd()) {
                    if (surface.rtApp().windowForSurface(surface)) |window| {
                        window.split_divider_tracking_mouse_leave = false;
                        if (window.split_divider_drag == null) {
                            setSplitDividerHover(window, null);
                        }
                    }
                }
            }
            return 0;
        },
        win32.WM_LBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_RBUTTONDOWN,
        win32.WM_RBUTTONUP,
        win32.WM_MBUTTONDOWN,
        win32.WM_MBUTTONUP,
        win32.WM_XBUTTONDOWN,
        win32.WM_XBUTTONUP,
        => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd or hwnd == surface.windowHwnd()) {
                    if (msg == win32.WM_LBUTTONDOWN and
                        beginSplitDividerDrag(surface, hwnd, lparam))
                    {
                        return 0;
                    }
                    if (msg == win32.WM_LBUTTONUP and
                        endSplitDividerDrag(surface, hwnd, lparam))
                    {
                        return 0;
                    }
                    if (hwnd == surface.hwnd) {
                        if (mouseButtonEvent(msg, wparam)) |event| {
                            return handleMouseButton(surface, hwnd, event, lparam);
                        }
                    }
                }
            }
            return 0;
        },
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) handleMouseWheel(surface, hwnd, msg, wparam, lparam);
            }
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd or hwnd == surface.windowHwnd()) {
                    cancelSplitDividerDrag(surface, hwnd);
                    if (hwnd == surface.hwnd) releaseMouseButtons(surface);
                }
            }
            return 0;
        },
        win32.WM_CHAR, win32.WM_SYSCHAR => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) return handleTextInput(surface, wparam);
            }
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            // Keystrokes the IME consumes arrive with the virtual key
            // replaced by VK_PROCESSKEY while the scan code still names the
            // physical key. Because keys are resolved from the scan code,
            // dispatching these would send the composition keys (Enter,
            // Backspace, Tab, arrows) to the terminal on top of the IME's own
            // handling. Hand them to the IME instead, and drop pending key
            // metadata: the text the IME commits later belongs to the
            // composition, not to one physical keystroke.
            if (wparam == vk_processkey) {
                if (getSurface(hwnd)) |surface| {
                    if (hwnd == surface.hwnd) surface.pending_text_key = null;
                }
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }

            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    if (surface.core_surface) |core| {
                        const mods = getModifiers();
                        const key = mapKey(wparam, lparam);

                        if (!shouldDispatchKeyPress(wparam, mods)) {
                            surface.pending_text_key = .{
                                .action = keyAction(lparam),
                                .key = key,
                                .mods = mods,
                                .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                            };
                            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                        }

                        surface.pending_text_key = null;
                        if (key != .unidentified) {
                            const effect = core.keyCallback(.{
                                .action = keyAction(lparam),
                                .key = key,
                                .mods = mods,
                                .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                            }) catch |err| {
                                log.err("key callback error: {}", .{err});
                                return 0;
                            };
                            if (effect == .consumed or effect == .closed) return 0;
                        }
                    }
                }
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            // See the VK_PROCESSKEY note on WM_KEYDOWN.
            if (wparam == vk_processkey) {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }

            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    if (surface.core_surface) |core| {
                        const key = mapKey(wparam, lparam);
                        if (key != .unidentified) {
                            _ = core.keyCallback(.{
                                .action = .release,
                                .key = key,
                                .mods = getModifiers(),
                                .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                            }) catch |err| {
                                log.err("key release callback error: {}", .{err});
                            };
                        }
                    }
                }
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test "map Win32 virtual keys" {
    try std.testing.expectEqual(input.Key.key_a, mapVirtualKey(0x41, 0));
    try std.testing.expectEqual(input.Key.arrow_left, mapVirtualKey(0x25, 0));
    try std.testing.expectEqual(input.Key.bracket_left, mapVirtualKey(0xDB, 0));
    try std.testing.expectEqual(input.Key.bracket_right, mapVirtualKey(0xDD, 0));
    try std.testing.expectEqual(input.Key.numpad_enter, mapVirtualKey(0x0D, 1 << 24));
    try std.testing.expectEqual(input.Key.control_right, mapVirtualKey(0x11, 1 << 24));
    try std.testing.expectEqual(input.Key.unidentified, mapVirtualKey(0xFF, 0));
}

test "map Win32 scan codes to physical keys" {
    const scan = struct {
        fn lparam(code: usize, extended: bool) win32.LPARAM {
            var bits: usize = code << 16;
            if (extended) bits |= @as(usize, 1) << 24;
            return @bitCast(bits);
        }
    };

    // Layout independent positions from the Chromium table.
    try std.testing.expectEqual(input.Key.key_a, keyFromScanCode(scan.lparam(0x1E, false)));
    try std.testing.expectEqual(input.Key.bracket_left, keyFromScanCode(scan.lparam(0x1A, false)));
    try std.testing.expectEqual(input.Key.semicolon, keyFromScanCode(scan.lparam(0x27, false)));
    try std.testing.expectEqual(input.Key.control_left, keyFromScanCode(scan.lparam(0x1D, false)));
    try std.testing.expectEqual(input.Key.control_right, keyFromScanCode(scan.lparam(0x1D, true)));
    try std.testing.expectEqual(input.Key.numpad_enter, keyFromScanCode(scan.lparam(0x1C, true)));
    try std.testing.expectEqual(input.Key.backquote, keyFromScanCode(scan.lparam(0x29, false)));
    try std.testing.expectEqual(input.Key.unidentified, keyFromScanCode(0));

    // The scan code wins over a virtual key that disagrees with it: on a
    // German layout VK_OEM_1 sits on the physical `;` position, but here the
    // scan code says the key is at the US `[` position.
    try std.testing.expectEqual(input.Key.bracket_left, mapKey(0xBA, scan.lparam(0x1A, false)));

    // Messages without a scan code keep the virtual-key fallback.
    try std.testing.expectEqual(input.Key.f5, mapKey(0x74, 0));
    try std.testing.expectEqual(@as(u32, 0), nativeKeycode(0));
    try std.testing.expectEqual(@as(u32, 0xE01D), nativeKeycode(scan.lparam(0x1D, true)));

    // The active layout translates the letter key without modifiers to a
    // lowercase letter (never the uppercase form MapVirtualKey would give),
    // and non-text keys have no translation.
    const letter = layoutUnshiftedCodepoint(0x41, scan.lparam(0x1E, false)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(letter >= 0x20);
    try std.testing.expect(!(letter >= 'A' and letter <= 'Z'));
    try std.testing.expectEqual(@as(?u21, null), layoutUnshiftedCodepoint(0x25, scan.lparam(0x4B, true)));
    try std.testing.expectEqual(@as(u21, 0), unshiftedCodepoint(0x25, scan.lparam(0x4B, true)));
}

test "Win32 IME process keys are not terminal keys" {
    const scan = struct {
        fn lparam(code: usize) win32.LPARAM {
            return @bitCast(code << 16);
        }
    };

    // VK_PROCESSKEY messages keep the physical scan code, so the key mapping
    // resolves them to real keys. That is exactly why the message handlers
    // must reject them before mapping: otherwise every key the IME consumes
    // would also reach the terminal.
    try std.testing.expectEqual(
        input.Key.enter,
        mapKey(vk_processkey, scan.lparam(0x1C)),
    );
    try std.testing.expectEqual(
        input.Key.backspace,
        mapKey(vk_processkey, scan.lparam(0x0E)),
    );

    // The dispatch gate does not stop them either: VK_PROCESSKEY is not a
    // text virtual key, so it takes the "send to the core" path.
    try std.testing.expect(shouldDispatchKeyPress(vk_processkey, .{}));

    try std.testing.expectEqual(@as(win32.WPARAM, 0xE5), vk_processkey);
}

test "classify Win32 text keys" {
    try std.testing.expect(isTextVirtualKey(0x41));
    try std.testing.expect(isTextVirtualKey(0xDE));
    try std.testing.expect(!isTextVirtualKey(0x25));

    // Numpad digits and operators produce WM_CHAR, so their key press is
    // held for the text instead of being dispatched on its own.
    for ([_]win32.WPARAM{ 0x60, 0x65, 0x69, 0x6A, 0x6B, 0x6D, 0x6E, 0x6F }) |vk| {
        try std.testing.expect(isTextVirtualKey(vk));
        try std.testing.expect(!shouldDispatchKeyPress(vk, .{}));
    }
    // With NumLock off the numpad reports navigation keys (VK_INSERT,
    // VK_END), which have no text and are still dispatched.
    try std.testing.expect(shouldDispatchKeyPress(0x2D, .{}));
    try std.testing.expect(shouldDispatchKeyPress(0x23, .{}));

    try std.testing.expectEqual(input.Action.press, keyAction(0));
    try std.testing.expectEqual(input.Action.repeat, keyAction(1 << 30));
    try std.testing.expectEqual(@as(u21, 'a'), unshiftedCodepointUS(0x41));

    var altgr: input.Mods = .{ .ctrl = true, .alt = true };
    altgr.sides.alt = .right;
    try std.testing.expect(!shouldDispatchKeyPress(0x41, altgr));

    var left_alt: input.Mods = .{ .alt = true };
    left_alt.sides.alt = .left;
    try std.testing.expect(shouldDispatchKeyPress(0x41, left_alt));
}

test "Win32 consumed text modifiers" {
    const shift: input.Mods = .{ .shift = true };
    try std.testing.expect(consumedTextModifiers(shift).shift);
    try std.testing.expect(!consumedTextModifiers(shift).ctrl);

    var altgr: input.Mods = .{ .ctrl = true, .alt = true };
    altgr.sides.alt = .right;
    const consumed_altgr = consumedTextModifiers(altgr);
    try std.testing.expect(consumed_altgr.ctrl);
    try std.testing.expect(consumed_altgr.alt);
    try std.testing.expect(!consumed_altgr.shift);

    var altgr_shift = altgr;
    altgr_shift.shift = true;
    const consumed_both = consumedTextModifiers(altgr_shift);
    try std.testing.expect(consumed_both.ctrl);
    try std.testing.expect(consumed_both.alt);
    try std.testing.expect(consumed_both.shift);
}

test "decode Win32 UTF-16 input" {
    var pending: ?u16 = null;
    try std.testing.expectEqual(@as(?u21, 'A'), decodeUtf16CodeUnit(&pending, 'A'));
    try std.testing.expectEqual(@as(?u21, null), decodeUtf16CodeUnit(&pending, 0xD83D));
    try std.testing.expectEqual(@as(?u21, 0x1F600), decodeUtf16CodeUnit(&pending, 0xDE00));
    try std.testing.expectEqual(@as(?u16, null), pending);
}

test "decode Win32 mouse coordinates and wheel delta" {
    const point = mousePoint(@bitCast(@as(usize, 0xFFEC_000A)));
    try std.testing.expectEqual(@as(f32, 10), point.x);
    try std.testing.expectEqual(@as(f32, -20), point.y);

    try std.testing.expectEqual(@as(i16, 120), wheelDelta(@as(usize, 120) << 16));
    try std.testing.expectEqual(@as(i16, -120), wheelDelta(@as(usize, 0xFF88) << 16));
}

test "map Win32 mouse buttons" {
    const left = mouseButtonEvent(win32.WM_LBUTTONDOWN, 0).?;
    try std.testing.expectEqual(input.MouseButton.left, left.button);
    try std.testing.expectEqual(input.MouseButtonState.press, left.state);

    const x2 = mouseButtonEvent(win32.WM_XBUTTONUP, @as(usize, 2) << 16).?;
    try std.testing.expectEqual(input.MouseButton.five, x2.button);
    try std.testing.expectEqual(input.MouseButtonState.release, x2.state);
    try std.testing.expect(x2.xbutton);
}

test "accumulate partial Win32 horizontal wheel ticks" {
    var remainder: i32 = 0;
    try std.testing.expectEqual(@as(i32, 0), accumulateWheelTicks(&remainder, 30));
    try std.testing.expectEqual(@as(i32, 30), remainder);
    try std.testing.expectEqual(@as(i32, 0), accumulateWheelTicks(&remainder, 60));
    try std.testing.expectEqual(@as(i32, 90), remainder);
    try std.testing.expectEqual(@as(i32, 1), accumulateWheelTicks(&remainder, 30));
    try std.testing.expectEqual(@as(i32, 0), remainder);
    try std.testing.expectEqual(@as(i32, -2), accumulateWheelTicks(&remainder, -240));
    try std.testing.expectEqual(@as(i32, 0), remainder);
}

test "decode Win32 DPI scale" {
    const wparam = @as(usize, 192) << 16 | 144;
    try std.testing.expectEqual(
        apprt.ContentScale{ .x = 1.5, .y = 2.0 },
        dpiScale(wparam),
    );
}

test "Win32 power resume event classification" {
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMECRITICAL));
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMESUSPEND));
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMESTANDBY));
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMEAUTOMATIC));
    try std.testing.expect(!isPowerResumeEvent(win32.PBT_APMSUSPEND));
    try std.testing.expect(!isPowerResumeEvent(0));
}

test "clamp Win32 window size to monitor work area" {
    const work_area: win32.RECT = .{
        .left = 0,
        .top = 40,
        .right = 1920,
        .bottom = 1080,
    };

    try std.testing.expectEqual(
        WindowExtent{ .width = 800, .height = 600 },
        clampWindowExtent(.{ .width = 800, .height = 600 }, work_area),
    );
    try std.testing.expectEqual(
        WindowExtent{ .width = 1920, .height = 1040 },
        clampWindowExtent(.{ .width = 3000, .height = 2000 }, work_area),
    );
    try std.testing.expectEqual(
        WindowExtent{ .width = 1, .height = 1 },
        clampWindowExtent(.{ .width = 0, .height = -1 }, work_area),
    );
}

test "toggle Win32 decoration style bits" {
    const base: u32 = @bitCast(win32.WINDOW_STYLE{
        .VISIBLE = 1,
        .MAXIMIZE = 1,
        .BORDER = 1,
        .DLGFRAME = 1,
        .SYSMENU = 1,
        .THICKFRAME = 1,
        .GROUP = 1,
        .TABSTOP = 1,
    });
    const undecorated: win32.WINDOW_STYLE = @bitCast(
        styleWithDecorations(base, false),
    );
    try std.testing.expectEqual(@as(u1, 1), undecorated.VISIBLE);
    try std.testing.expectEqual(@as(u1, 1), undecorated.MAXIMIZE);
    try std.testing.expectEqual(@as(u1, 0), undecorated.BORDER);
    try std.testing.expectEqual(@as(u1, 0), undecorated.DLGFRAME);
    try std.testing.expectEqual(@as(u1, 0), undecorated.SYSMENU);
    try std.testing.expectEqual(@as(u1, 0), undecorated.THICKFRAME);

    const decorated: win32.WINDOW_STYLE = @bitCast(styleWithDecorations(
        @bitCast(undecorated),
        true,
    ));
    try std.testing.expectEqual(@as(u1, 1), decorated.VISIBLE);
    try std.testing.expectEqual(@as(u1, 1), decorated.MAXIMIZE);
    try std.testing.expectEqual(@as(u1, 1), decorated.BORDER);
    try std.testing.expectEqual(@as(u1, 1), decorated.DLGFRAME);
    try std.testing.expectEqual(@as(u1, 1), decorated.SYSMENU);
    try std.testing.expectEqual(@as(u1, 1), decorated.THICKFRAME);
}

test "Win32 window icons fall back without an embedded resource" {
    // The unit test executable does not link the Windows resource script,
    // so the icon lookup must degrade to the default icon instead of
    // failing window class registration.
    const hinstance = win32.GetModuleHandleW(null) orelse return error.Win32Error;
    const icons = loadWindowIcons(hinstance);
    try std.testing.expect(icons.large == null);
    try std.testing.expect(icons.small == null);
}

test "restore Win32 native window state after fullscreen" {
    try registerWindowClass();
    defer _ = win32.UnregisterClassW(
        window_class_name,
        win32.GetModuleHandleW(null),
    );

    const hwnd = try createNativeWindow();
    defer _ = win32.DestroyWindow(hwnd);
    var surface: Surface = .{ .hwnd = hwnd, .window_hwnd = hwnd };

    var presenter = try DirectComposition.init(hwnd, 800, 600);
    defer presenter.deinit();
    try std.testing.expectEqual(win32.FALSE, win32.IsWindowVisible(hwnd));
    const swap_chain_desc = try presenter.getSwapChainDescription();
    try std.testing.expectEqual(@as(u32, 800), swap_chain_desc.Width);
    try std.testing.expectEqual(@as(u32, 600), swap_chain_desc.Height);
    try std.testing.expectEqual(
        win32.DXGI_ALPHA_MODE_PREMULTIPLIED,
        swap_chain_desc.AlphaMode,
    );

    var target = try presenter.createTarget(800, 600);
    defer target.deinit();
    target.bind(presenter.context);
    target.clear(presenter.context, .{ 0.0, 0.0, 0.0, 0.0 });
    try presenter.presentTarget(&target, 0);
    try presenter.resize(320, 240);
    const resized_desc = try presenter.getSwapChainDescription();
    try std.testing.expectEqual(@as(u32, 320), resized_desc.Width);
    try std.testing.expectEqual(@as(u32, 240), resized_desc.Height);
    try std.testing.expectError(
        error.TargetSizeMismatch,
        presenter.presentTarget(&target, 0),
    );
    var resized_target = try presenter.createTarget(320, 240);
    defer resized_target.deinit();
    resized_target.bind(presenter.context);
    resized_target.clear(presenter.context, .{ 0.0, 0.0, 0.0, 0.0 });
    try presenter.presentTarget(&resized_target, 0);

    const TestBuffer = d3d11_buffer.Buffer(u32);
    var buffer = try TestBuffer.init(.{
        .device = presenter.device,
        .context = presenter.context,
        .bind_flags = .{ .VERTEX_BUFFER = 1 },
    }, 1);
    defer buffer.deinit();
    try buffer.sync(&.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(usize, 8), buffer.len);

    var structured_buffer = try TestBuffer.init(.{
        .device = presenter.device,
        .context = presenter.context,
        .bind_flags = .{ .SHADER_RESOURCE = 1 },
        .structured = true,
    }, 4);
    defer structured_buffer.deinit();
    try structured_buffer.sync(&.{ 1, 2, 3, 4 });
    try std.testing.expect(structured_buffer.buffer.shader_view != null);

    const ConstantBuffer = d3d11_buffer.Buffer(D3D11Shaders.Uniforms);
    var constant_buffer = try ConstantBuffer.init(.{
        .device = presenter.device,
        .context = presenter.context,
        .bind_flags = .{ .CONSTANT_BUFFER = 1 },
    }, 1);
    defer constant_buffer.deinit();
    var uniforms = std.mem.zeroes(D3D11Shaders.Uniforms);
    uniforms.projection_matrix = math.ortho2d(0, 320, 240, 0);
    uniforms.screen_size = .{ 320, 240 };
    uniforms.cell_size = .{ 10, 20 };
    uniforms.grid_size = .{ 2, 2 };
    uniforms.cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) };
    uniforms.cursor_color = .{ 255, 255, 255, 255 };
    uniforms.bg_color = .{ 0, 0, 0, 0 };
    try constant_buffer.sync(&.{uniforms});

    const texture_data = [_]u8{
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };
    const texture = try D3D11Texture.init(.{
        .device = presenter.device,
        .context = presenter.context,
        .format = win32.DXGI_FORMAT_B8G8R8A8_UNORM,
        .render_target = true,
    }, 2, 2, &texture_data);
    defer texture.deinit();
    try texture.replaceRegion(1, 1, 1, 1, &.{ 0, 0, 0, 0 });

    const sampler = try D3D11Sampler.init(.{ .device = presenter.device });
    defer sampler.deinit();

    const CellTextBuffer = d3d11_buffer.Buffer(D3D11Shaders.CellText);
    var cell_buffer = try CellTextBuffer.init(.{
        .device = presenter.device,
        .context = presenter.context,
        .bind_flags = .{ .VERTEX_BUFFER = 1 },
    }, 1);
    defer cell_buffer.deinit();
    try cell_buffer.sync(&.{.{
        .glyph_pos = .{ 4, 8 },
        .glyph_size = .{ 10, 16 },
        .bearings = .{ 1, -2 },
        .grid_pos = .{ 1, 1 },
        .color = .{ 64, 32, 0, 128 },
        .atlas = .color,
        .bools = .{ .is_cursor_glyph = true },
    }});

    var shaders = try D3D11Shaders.Shaders.init(presenter.device);
    defer shaders.deinit(std.testing.allocator);

    const pass = D3D11RenderPass.init(.{
        .context = presenter.context,
        .target = &resized_target,
        .clear_color = .{ 0, 0, 0, 0 },
    });
    pass.setPipeline(&shaders.pipelines.cell_text);
    pass.setVertexBuffer(cell_buffer.buffer.resource, shaders.pipelines.cell_text.stride);
    pass.setUniformBuffer(1, constant_buffer.buffer.resource);
    var vertex_resources = [_]?*win32.ID3D11ShaderResourceView{
        structured_buffer.buffer.shader_view.?,
    };
    pass.setVertexShaderResources(0, &vertex_resources);
    var pixel_resources = [_]?*win32.ID3D11ShaderResourceView{
        texture.shader_view,
        texture.shader_view,
    };
    pass.setPixelShaderResources(0, &pixel_resources);
    var samplers = [_]?*win32.ID3D11SamplerState{sampler.sampler};
    pass.setPixelSamplers(0, &samplers);
    pass.draw(4, 1);
    pass.complete();
    try presenter.presentTarget(&resized_target, 0);

    const original_style = getWindowStyle(hwnd).?;
    try std.testing.expect(setWindowDecorations(&surface, false));
    try std.testing.expect(!surface.decorated);
    try std.testing.expectEqual(
        styleWithDecorations(original_style, false),
        getWindowStyle(hwnd).?,
    );

    try std.testing.expect(setWindowDecorations(&surface, true));
    try std.testing.expect(surface.decorated);
    try std.testing.expectEqual(original_style, getWindowStyle(hwnd).?);

    try std.testing.expect(setAlwaysOnTop(&surface, true));
    try std.testing.expect(surface.always_on_top);
    try std.testing.expect(setAlwaysOnTop(&surface, false));
    try std.testing.expect(!surface.always_on_top);

    try std.testing.expect(enterFullscreen(&surface));
    try std.testing.expect(surface.fullscreen);
    try std.testing.expectEqual(
        styleWithDecorations(original_style, false),
        getWindowStyle(hwnd).?,
    );

    // A decoration toggle made in fullscreen is deferred until restoration.
    // Keep this test-only native window hidden when its placement is applied.
    if (surface.windowed_placement) |*placement| {
        placement.showCmd = win32.SW_HIDE;
    }
    try std.testing.expect(setWindowDecorations(&surface, false));
    try std.testing.expect(leaveFullscreen(&surface));
    try std.testing.expect(!surface.fullscreen);
    try std.testing.expectEqual(
        styleWithDecorations(original_style, false),
        getWindowStyle(hwnd).?,
    );
}

test "format Win32 config diagnostics for display" {
    const testing = std.testing;

    var config = try Config.default(testing.allocator);
    defer config.deinit();
    try config.addDiagnosticFmt("first error", .{});
    try config.addDiagnosticFmt("second error", .{});

    const message = (try formatConfigDiagnostics(
        testing.allocator,
        &config,
    )).?;
    defer testing.allocator.free(message);

    try testing.expectEqualStrings(
        "Ghostty found errors in the configuration:\r\n\r\n" ++
            "first error\r\nsecond error",
        message,
    );
}

test "omit empty Win32 config diagnostics" {
    const testing = std.testing;

    var config = try Config.default(testing.allocator);
    defer config.deinit();

    try testing.expectEqual(
        @as(?[:0]u8, null),
        try formatConfigDiagnostics(testing.allocator, &config),
    );
}

test "classify safe Win32 OSC 8 URLs" {
    try std.testing.expectEqual(
        UntrustedUrlDecision.allow,
        classifyUntrustedUrl("https://example.com/path"),
    );
    try std.testing.expectEqual(
        UntrustedUrlDecision.allow,
        classifyUntrustedUrl("HTTP://EXAMPLE.COM"),
    );
    try std.testing.expectEqual(
        UntrustedUrlDecision.allow,
        classifyUntrustedUrl("mailto:user@example.com"),
    );
    try std.testing.expectEqual(
        UntrustedUrlDecision.confirm,
        classifyUntrustedUrl("vscode://file/C:/project/main.zig"),
    );
}

test "block unsafe Win32 OSC 8 URLs" {
    const testing = std.testing;

    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl(""),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl("C:\\payload.exe"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl("/tmp/payload"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .invalid_web_url },
        classifyUntrustedUrl("https:relative"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .malformed_url },
        classifyUntrustedUrl("mailto:"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .unsafe_file },
        classifyUntrustedUrl("file:///C:/payload.exe"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .unsafe_characters },
        classifyUntrustedUrl("https://example.com/a\nb"),
    );
    try testing.expectEqual(
        UntrustedUrlDecision{ .deny = .unsafe_characters },
        classifyUntrustedUrl("https://example.com/a\xE2\x80\xAEb"),
    );
}

test "escape unsafe Win32 OSC 8 URL display characters" {
    const testing = std.testing;
    const display = try formatUntrustedUrlForDisplay(
        testing.allocator,
        "https://example.com/a\n\xE2\x80\xAEb",
    );
    defer testing.allocator.free(display);

    try testing.expectEqualStrings(
        "https://example.com/a\\u{A}\\u{202E}b",
        display,
    );
}

test "parse Win32 editor command with quoted executable" {
    const testing = std.testing;

    const command = try parseWindowsEditorCommand(
        testing.allocator,
        "\"C:\\Program Files\\Editor\\editor.exe\" --wait",
        "C:\\Users\\test user\\config.ghostty",
    );
    defer command.deinit(testing.allocator);

    const args = command.direct;
    try testing.expectEqual(@as(usize, 3), args.len);
    try testing.expectEqualStrings(
        "C:\\Program Files\\Editor\\editor.exe",
        args[0],
    );
    try testing.expectEqualStrings("--wait", args[1]);
    try testing.expectEqualStrings(
        "C:\\Users\\test user\\config.ghostty",
        args[2],
    );
}

test "reject empty Win32 editor command" {
    try std.testing.expectError(
        error.InvalidEditorCommand,
        parseWindowsEditorCommand(
            std.testing.allocator,
            "",
            "C:\\config.ghostty",
        ),
    );
}

test "format Win32 tab bar accessible name" {
    const name = try tabBarAccessibleName(
        std.testing.allocator,
        3,
        1,
        "PowerShell",
    );
    defer std.testing.allocator.free(name);

    try std.testing.expectEqualStrings(
        "Ghostty tabs. 3 tabs. Active tab 2: PowerShell",
        name,
    );

    const singular = try tabBarAccessibleName(
        std.testing.allocator,
        1,
        0,
        "Command Prompt",
    );
    defer std.testing.allocator.free(singular);
    try std.testing.expectEqualStrings(
        "Ghostty tabs. 1 tab. Active tab 1: Command Prompt",
        singular,
    );
}
