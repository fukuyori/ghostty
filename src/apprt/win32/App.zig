/// Win32 application runtime for Ghostty. This is a minimal native Windows
/// application using the Win32 API with D3D11 or OpenGL rendering.
const App = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const build_config = @import("../../build_config.zig");
const brand = @import("../../brand.zig");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const math = @import("../../math.zig");
const d3d11_buffer = @import("../../renderer/d3d11/buffer.zig");
const D3D11RenderPass = @import("../../renderer/d3d11/RenderPass.zig");
const D3D11Sampler = @import("../../renderer/d3d11/Sampler.zig");
const D3D11Shaders = @import("../../renderer/d3d11/shaders.zig");
const D3D11Texture = @import("../../renderer/d3d11/Texture.zig");
const Backdrop = @import("Backdrop.zig");
const ConfigActions = @import("ConfigActions.zig");
const DeferredActions = @import("DeferredActions.zig");
const DirectComposition = @import("DirectComposition.zig");
const Surface = @import("Surface.zig");
const SplitDivider = @import("SplitDivider.zig");
const TabBarController = @import("TabBarController.zig");
const TabBarAccessibility = @import("TabBarAccessibility.zig");
const TabTitles = @import("TabTitles.zig");
const Titlebar = @import("Titlebar.zig");
const Window = @import("Window.zig");
const WindowState = @import("WindowState.zig");
const WindowAppearance = @import("WindowAppearance.zig");
const WindowLayout = @import("WindowLayout.zig");
const SearchBar = @import("SearchBar.zig");
const ShellOpen = @import("ShellOpen.zig");
const CommandPalette = @import("CommandPalette.zig");
const FileDrop = @import("FileDrop.zig");
const Mouse = @import("Mouse.zig");
const NativeWindow = @import("NativeWindow.zig");
const Recovery = @import("Recovery.zig");
const Overrides = @import("Overrides.zig");
const IpcProtocol = @import("IpcProtocol.zig");
const IpcTransport = @import("IpcTransport.zig");

comptime {
    _ = IpcProtocol;
    _ = IpcTransport;
    _ = WindowState;
    _ = ShellOpen;
    _ = TabTitles;
    _ = TabBarAccessibility;
    _ = TabBarController;
    _ = ConfigActions;
    _ = CommandPalette;
    _ = FileDrop;
    _ = Mouse;
    _ = NativeWindow;
    _ = Recovery;
    _ = WindowAppearance;
    _ = WindowLayout;
    _ = SplitDivider;
    _ = brand;
}

const log = std.log.scoped(.win32);
const WindowList = std.ArrayListUnmanaged(*Window);
/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP = win32.WM_USER + 1;

/// A surface can request closure from a core callback. Route it through the
/// window thread so confirmation and native resource teardown happen there.
const WM_CLOSE_SURFACE = win32.WM_USER + 2;

const WM_IPC_REQUEST = win32.WM_USER + 6;
const ipc_ui_timeout_ms: u32 = 5000;

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
ipc_server: ?*IpcTransport.Server = null,
/// open_url requests run by the message loop. See ShellOpen.openUrl.
pending_opens: ShellOpen.Queue = .empty,
/// Owned diagnostic text displayed only after core callbacks have returned.
pending_config_diagnostics: ConfigActions.DiagnosticQueue = .{},
pending_actions: DeferredActions.Queue = .empty,

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
        if (environ.get(brand.env_prefix ++ "TEST_DEVICE_RECOVERY")) |value|
            std.mem.eql(u8, value, "1")
        else
            false
    else
        false;
    const test_device_recovery_failures = if (test_device_recovery)
        if (environ.get(brand.env_prefix ++ "TEST_DEVICE_RECOVERY_FAILURES")) |value|
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
        .high_contrast = WindowAppearance.highContrastEnabled(),
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
    self.ipc_server = IpcTransport.Server.init(self.alloc, self, ipcHandler) catch |err| server: {
        log.warn("IPC service unavailable: {}", .{err});
        break :server null;
    };
    errdefer if (self.ipc_server) |server| server.deinit();
    try self.createWindow(.{});
    ConfigActions.showConfigDiagnostics(self, .app, self.config);
}

fn createWakeupWindow(self: *App) !win32.HWND {
    const hwnd = try NativeWindow.createWakeup();
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
    if (msg == WM_IPC_REQUEST and lparam != 0) {
        const request: *IpcUiRequest = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
        if (ptr != 0) {
            const app: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            app.processIpcRequest(request);
            request.complete();
        } else {
            // The request cannot be completed without its App. Release the UI
            // ownership; the worker remains responsible for its own reference
            // until timeout or shutdown.
            request.release();
        }
        return 0;
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn run(self: *App) !void {
    log.info("starting Win32 event loop", .{});

    while (self.running) {
        // Here the core is not inside a callback and holds no lock.
        ConfigActions.drainDiagnostics(self);
        ShellOpen.drain(self);
        DeferredActions.drain(self);

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
    if (self.ipc_server) |server| {
        self.ipc_server = null;
        server.deinit();
    }
    self.discardPendingIpcRequests();
    ShellOpen.discardPending(self);
    ConfigActions.discardDiagnostics(self);
    DeferredActions.discard(self);
    while (self.windows.pop()) |window| {
        WindowAppearance.disableWindowBackgroundBlur(window);
        TabBarAccessibility.deinitForWindow(window);
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

fn discardPendingIpcRequests(self: *App) void {
    const hwnd = self.wakeup_hwnd orelse return;
    var msg: win32.MSG = undefined;
    while (win32.PeekMessageW(
        &msg,
        hwnd,
        WM_IPC_REQUEST,
        WM_IPC_REQUEST,
        .{ .REMOVE = 1 },
    ) != 0) {
        if (msg.lParam != 0) {
            const request: *IpcUiRequest = @ptrFromInt(@as(usize, @bitCast(msg.lParam)));
            request.release();
        }
    }
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
        surface.close_requested = false;
        log.warn("PostMessage(WM_CLOSE_SURFACE) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

fn closeSurface(self: *App, surface: *Surface, confirm: bool) void {
    if (confirm) {
        var request: DeferredActions.Close = .{ .confirm = true };
        request.add(self.alloc, surface) catch |err| {
            request.deinit(self.alloc);
            log.warn("failed to queue surface close: {}", .{err});
            return;
        };
        _ = DeferredActions.enqueue(self, .{ .close = request });
        return;
    }

    const window = self.windowForSurface(surface) orelse {
        log.warn("close requested for an unowned surface", .{});
        return;
    };
    SplitDivider.clearPointer(window);
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

    if (close_window) WindowAppearance.disableWindowBackgroundBlur(window);
    if (close_window) TabBarAccessibility.deinitForWindow(window);

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
        TabBarController.invalidate(window);
    }
    WindowLayout.layoutWindow(self, window);
}

fn destroyTabAt(self: *App, window: *Window, index: usize) bool {
    SplitDivider.clearPointer(window);
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

    WindowLayout.layoutWindow(self, window);
    _ = win32.SetFocus(focus.hwnd);
    focus.syncTitle();
    TabBarAccessibility.sync(self, window, true, true);
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

pub fn windowForSurface(self: *App, surface: *const Surface) ?*Window {
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
    TabTitles.tabTitleChanged(self, surface);
}

pub fn syncWindowTitle(self: *App, surface: *Surface) void {
    TabTitles.syncWindowTitle(self, surface);
}

pub fn windowForHwnd(self: *App, hwnd: win32.HWND) ?*Window {
    for (self.windows.items) |window| {
        if (window.hwnd == hwnd) return window;
    }
    return null;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => return self.queueCloseAll(true),
        .quit_timer => {
            if (value == .start) win32.PostQuitMessage(0);
            return true;
        },
        .set_title => return try TabTitles.setTitle(target, value),
        .set_tab_title => return try TabTitles.setTabTitle(self, target, value),
        .start_search => return try SearchBar.startSearch(self, target, value),
        .end_search => return SearchBar.endSearch(self, target),
        .search_total, .search_selected => return SearchBar.updateResults(target, action, value),
        .scrollbar => {
            const surface = targetSurface(target) orelse return false;
            if (surface.scrollbar) |bar| bar.update(value);
            return true;
        },
        .mouse_shape => return Mouse.setShape(target, value),
        .mouse_visibility => return Mouse.setVisibility(target, value),
        .prompt_title => return try TabTitles.promptTitle(self, target, value),
        .toggle_command_palette => return CommandPalette.requestShow(target),
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
        .toggle_maximize => return WindowState.toggleMaximize(target),
        .toggle_fullscreen => return WindowState.toggleFullscreen(target, value),
        .toggle_window_decorations => return WindowState.toggleWindowDecorations(target),
        .float_window => return WindowState.floatWindow(target, value),
        .initial_size => return WindowState.setInitialSize(target, value),
        .reset_window_size => return WindowState.resetWindowSize(target),
        .resize_window => return WindowState.resizeWindow(target, value),
        .open_url => return ShellOpen.openUrl(self, target, value),
        .open_config => return try ConfigActions.openConfig(self, target, value),
        .reload_config => {
            try ConfigActions.reloadConfig(self, target, value);
            return true;
        },
        .renderer_health => return try Recovery.recoverRenderer(target, value),
        .config_change => return try ConfigActions.configChange(self, target, value),
        else => return false,
    }
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

pub fn closeTab(
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

    var request: DeferredActions.Close = .{};
    for (0..window.tabCount()) |index| {
        if (!tabSelectedForClose(index, target_index, mode)) continue;
        const surfaces = window.surfacesAt(index) orelse continue;
        for (surfaces) |candidate| {
            request.add(self.alloc, candidate) catch |err| {
                request.deinit(self.alloc);
                log.warn("failed to snapshot tab close: {}", .{err});
                return false;
            };
        }
    }
    if (request.ids.items.len == 0) {
        request.deinit(self.alloc);
        return false;
    }
    return DeferredActions.requestClose(self, request);
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
    var request: DeferredActions.Close = .{};
    var surfaces = window.surfaceIterator();
    while (surfaces.next()) |surface| {
        request.add(self.alloc, surface) catch |err| {
            request.deinit(self.alloc);
            log.warn("failed to snapshot window close: {}", .{err});
            return false;
        };
    }
    return DeferredActions.requestClose(self, request);
}

fn closeAllWindows(self: *App) bool {
    if (self.windows.items.len == 0) return false;
    return self.queueCloseAll(false);
}

fn queueCloseAll(self: *App, quit: bool) bool {
    var request: DeferredActions.Close = .{ .all = true, .quit = quit };
    for (self.windows.items) |window| {
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| {
            request.add(self.alloc, surface) catch |err| {
                request.deinit(self.alloc);
                log.warn("failed to snapshot application close: {}", .{err});
                return false;
            };
        }
    }
    return DeferredActions.requestClose(self, request);
}

fn presentTerminal(target: apprt.Target) bool {
    const surface = targetSurface(target) orelse {
        log.warn("present_terminal targeted the application", .{});
        return false;
    };
    return presentSurface(surface);
}

pub fn presentSurface(surface: *Surface) bool {
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

pub fn targetSurface(target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |surface| surface.rt_surface,
    };
}

/// Window-level state is kept on the first surface while Surface remains the
/// runtime-facing apprt type. All splits in a window must resolve through the
/// same state holder so actions don't depend on which child currently has
/// focus.
pub fn windowStateSurface(surface: *Surface) *Surface {
    const app = surface.rtApp();
    const window = app.windowForSurface(surface) orelse return surface;
    return window.stateSurface();
}

pub fn transferWindowState(from: *Surface, to: *Surface) void {
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

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) anyerror!bool {
    if (action != .new_tab) return false;
    if (target == .class) {
        std.debug.print("+new-tab --class is not supported on Windows.\n", .{});
        return error.IPCFailed;
    }
    const payload = try IpcProtocol.encodeRequest(alloc, .{
        .action = .new_tab,
        .surface_id = value.surface_id,
        .arguments = value.arguments orelse &.{},
    });
    defer alloc.free(payload);
    const response_payload = IpcTransport.clientExchange(alloc, payload) catch |err| {
        switch (err) {
            error.ServerUnavailable => std.debug.print(
                "No running " ++ brand.display_name ++ " instance was found.\n",
                .{},
            ),
            error.ConnectTimeout => std.debug.print(
                brand.display_name ++ " is busy processing another request.\n",
                .{},
            ),
            error.AccessDenied => std.debug.print(
                "Access to the running " ++ brand.display_name ++ " instance was denied; check whether it is running with different privileges.\n",
                .{},
            ),
            error.IoTimeout => std.debug.print(
                "Timed out waiting for " ++ brand.display_name ++ "; the tab may still be created.\n",
                .{},
            ),
            error.ConnectFailed => std.debug.print(
                "Unable to connect to the running " ++ brand.display_name ++ " instance.\n",
                .{},
            ),
            else => std.debug.print(brand.display_name ++ " IPC failed: {}\n", .{err}),
        }
        return error.IPCFailed;
    };
    defer alloc.free(response_payload);
    const response = IpcProtocol.decodeResponse(response_payload) catch |err| {
        std.debug.print("The " ++ brand.display_name ++ " IPC response was invalid: {}\n", .{err});
        return error.IPCFailed;
    };

    return switch (response.status) {
        .success => true,
        .target_fallback => success: {
            std.debug.print(brand.display_name ++ " used a fallback window for the new tab.\n", .{});
            break :success true;
        },
        else => failure: {
            std.debug.print(brand.display_name ++ " could not create the tab: {s}\n", .{response.message});
            break :failure error.IPCFailed;
        },
    };
}

const IpcUiRequest = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    request: IpcProtocol.Request,
    completion: win32.HANDLE,
    refs: std.atomic.Value(u32) = .init(2),
    status: IpcProtocol.Status = .internal_error,

    fn release(self: *IpcUiRequest) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = win32.CloseHandle(self.completion);
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    fn complete(self: *IpcUiRequest) void {
        _ = win32.SetEvent(self.completion);
        self.release();
    }
};

fn ipcHandler(
    context: *anyopaque,
    alloc: Allocator,
    shutdown_event: win32.HANDLE,
    payload: []const u8,
) ![]u8 {
    const app: *App = @ptrCast(@alignCast(context));
    var arena: std.heap.ArenaAllocator = .init(alloc);
    const request = IpcProtocol.decodeRequest(arena.allocator(), payload) catch |err| {
        arena.deinit();
        if (err == error.OutOfMemory) return err;
        return IpcProtocol.encodeResponse(alloc, .{
            .status = if (err == error.UnsupportedVersion) .unsupported_version else .invalid_request,
            .message = if (err == error.UnsupportedVersion)
                "unsupported IPC protocol version"
            else
                "invalid IPC request",
        });
    };

    const ui_request = alloc.create(IpcUiRequest) catch |err| {
        arena.deinit();
        return err;
    };
    ui_request.* = .{
        .alloc = alloc,
        .arena = arena,
        .request = request,
        .completion = win32.CreateEventW(null, 1, 0, null) orelse {
            alloc.destroy(ui_request);
            arena.deinit();
            return error.CreateEventFailed;
        },
    };
    defer ui_request.release();

    const hwnd = app.wakeup_hwnd orelse {
        ui_request.release();
        return error.UiWindowUnavailable;
    };
    if (win32.PostMessageW(
        hwnd,
        WM_IPC_REQUEST,
        0,
        @bitCast(@intFromPtr(ui_request)),
    ) == 0) {
        ui_request.release();
        return error.PostMessageFailed;
    }

    const handles = [_]?win32.HANDLE{ ui_request.completion, shutdown_event };
    const wait_result = win32.WaitForMultipleObjects(
        handles.len,
        &handles,
        0,
        ipc_ui_timeout_ms,
    );
    const status: IpcProtocol.Status = if (@intFromEnum(wait_result) == 0)
        ui_request.status
    else if (@intFromEnum(wait_result) == 1)
        return error.Shutdown
    else if (wait_result == .WAIT_TIMEOUT)
        .timeout
    else
        return error.WaitFailed;

    return IpcProtocol.encodeResponse(alloc, .{
        .status = status,
        .message = switch (status) {
            .success => "tab created",
            .target_fallback => "tab created using fallback target",
            .invalid_request => "invalid IPC request",
            .unsupported_version => "unsupported IPC protocol version",
            .internal_error => "unable to create tab",
            .timeout => "completion unknown; the tab may be created later",
        },
    });
}

fn processIpcRequest(self: *App, request: *IpcUiRequest) void {
    const overrides = Overrides.parse(
        request.arena.allocator(),
        request.request.arguments,
    ) catch {
        request.status = .invalid_request;
        return;
    };
    const opts = WindowOptions.fromOverrides(overrides);

    var fallback = false;
    const target = if (request.request.surface_id != 0) target: {
        if (self.core_app.findSurfaceByID(request.request.surface_id)) |surface|
            break :target surface;
        fallback = true;
        log.warn("new-tab: unable to find surface 0x{x:0>16}; using fallback", .{
            request.request.surface_id,
        });
        break :target self.core_app.focusedSurface();
    } else self.core_app.focusedSurface();

    if (target) |surface| {
        if (!(self.newTabWithOptions(.{ .surface = surface }, opts) catch false)) {
            request.status = .internal_error;
            return;
        }
    } else {
        self.createWindow(opts) catch {
            request.status = .internal_error;
            return;
        };
    }
    request.status = if (fallback) .target_fallback else .success;
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}

const WindowOptions = struct {
    command: ?configpkg.Command = null,
    shell_integration: ?configpkg.Config.ShellIntegration = null,
    working_directory: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,

    fn fromOverrides(overrides: Overrides) WindowOptions {
        return .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        };
    }
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
        if (opts.shell_integration) |shell_integration| {
            config.@"shell-integration" = shell_integration;
        } else if (config.@"shell-integration" != .none) {
            config.@"shell-integration" = .detect;
        }
    } else if (opts.shell_integration) |shell_integration| {
        config.@"shell-integration" = shell_integration;
    }
    if (opts.working_directory) |working_directory| {
        config.@"working-directory" = .{
            .path = try config.arenaAlloc().dupe(u8, working_directory),
        };
        try config.@"working-directory".?.finalize(config.arenaAlloc());
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
        if (!WindowState.setWindowDecorations(
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

    try ConfigActions.configureScrollbar(self, surface, &config);

    WindowAppearance.updateWindowBackgroundBlur(surface, &config);
    log.info("core surface initialized successfully", .{});
}

pub fn createWindow(self: *App, opts: WindowOptions) !void {
    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);

    const window = try self.alloc.create(Window);
    errdefer self.alloc.destroy(window);

    const window_hwnd = try NativeWindow.createWindow();
    errdefer _ = win32.DestroyWindow(window_hwnd);

    const surface_hwnd = try NativeWindow.createSurface(window_hwnd);
    errdefer _ = win32.DestroyWindow(surface_hwnd);

    try surface.init(self, window_hwnd, surface_hwnd);
    errdefer surface.deinit();

    window.* = try Window.init(self.alloc, window_hwnd, surface);
    errdefer window.deinit(self.alloc);

    // The tab bar is an auxiliary window. Every consumer tolerates a null
    // handle, so a creation failure (USER handle exhaustion, for example)
    // degrades to a window without a tab bar instead of no window at all.
    const tab_bar_hwnd: ?win32.HWND = NativeWindow.createTabBar(window_hwnd) catch |err| tab_bar: {
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
    errdefer TabBarAccessibility.deinitForWindow(window);

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
    TabBarAccessibility.sync(self, window, false, false);
    WindowLayout.layoutWindow(self, window);
    showWindow(surface);
}

pub fn newTab(self: *App, target: apprt.Target) !bool {
    return self.newTabWithOptions(target, .{});
}

fn newTabWithOptions(self: *App, target: apprt.Target, opts: WindowOptions) !bool {
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

    const surface_hwnd = try NativeWindow.createSurface(window.hwnd);
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

    try self.initCoreSurface(surface, opts, .tab);
    TabBarAccessibility.notifyEvent(window, TabBarAccessibility.event_object_reorder);
    activateWindowTab(self, window);
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
    _ = win32.SetFocus(focus.hwnd);
    TabBarAccessibility.sync(self, window, true, false);
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
    SplitDivider.clearPointer(window);

    const surface = try self.alloc.create(Surface);
    errdefer self.alloc.destroy(surface);

    const surface_hwnd = try NativeWindow.createSurface(window.hwnd);
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
    WindowLayout.layoutWindow(self, window);
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
        WindowLayout.windowContentBounds(self, window, client),
        SplitDivider.gap(window),
    );
    if (!changed) return false;
    WindowLayout.layoutWindow(self, window);
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
    WindowLayout.layoutWindow(self, window);
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
    WindowLayout.layoutWindow(self, window);
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
    TabBarController.invalidate(window);
}

fn registerWindowClass() !void {
    try NativeWindow.registerClasses(.{
        .window = wndProc,
        .tab_bar = TabBarController.wndProc,
        .split_divider = SplitDivider.wndProc,
        .wakeup = wakeupWndProc,
    });
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
    if (surface.default_fullscreen and !WindowState.setFullscreen(surface, true)) {
        log.warn("failed to enter configured fullscreen mode", .{});
    }
}

pub fn getSurface(hwnd: win32.HWND) ?*Surface {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

pub fn getModifiers() input.Mods {
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

fn keyRepeatCount(lparam: win32.LPARAM) u16 {
    const bits: usize = @bitCast(lparam);
    const count: u16 = @truncate(bits);
    return if (count == 0) 1 else count;
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

/// Identity shared by a key message and the character messages generated for
/// it. Repeat and key-state bits deliberately do not participate: one keydown
/// can produce multiple UTF-16 code units, all carrying the same scan code and
/// extended-key flag.
fn characterMessageKey(lparam: win32.LPARAM) ?u32 {
    const native = nativeKeycode(lparam);
    return if (native == 0) null else native;
}

fn shouldSuppressCharacter(expected: ?u32, lparam: win32.LPARAM) bool {
    const actual = characterMessageKey(lparam) orelse return false;
    return expected != null and expected.? == actual;
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

fn win32ControlKeyState(mods: input.Mods, lparam: win32.LPARAM) u16 {
    var state: u16 = 0;
    if (mods.alt) state |= if (mods.sides.alt == .right) 0x0001 else 0x0002;
    if (mods.ctrl) state |= if (mods.sides.ctrl == .right) 0x0004 else 0x0008;
    if (mods.shift) state |= 0x0010;
    if (mods.num_lock) state |= 0x0020;
    if ((win32.GetKeyState(0x91) & 1) != 0) state |= 0x0040;
    if (mods.caps_lock) state |= 0x0080;
    if (isExtendedKey(lparam)) state |= 0x0100;
    return state;
}

const Win32Unicode = struct {
    units: [2]u16 = .{ 0, 0 },
    len: u2 = 1,
};

fn unicodeFromCodepoint(codepoint: u21) Win32Unicode {
    if (codepoint <= 0xFFFF) return .{ .units = .{ @intCast(codepoint), 0 } };
    const value: u21 = codepoint - 0x10000;
    return .{
        .units = .{
            @intCast(0xD800 + (value >> 10)),
            @intCast(0xDC00 + (value & 0x3FF)),
        },
        .len = 2,
    };
}

/// Translate a physical key with its actual modifier state without changing
/// the thread's dead-key state. This mirrors the character value that conhost
/// places in a KEY_EVENT_RECORD for Ctrl/Alt-modified key events.
fn modifiedUnicode(vk: win32.WPARAM, lparam: win32.LPARAM, mods: input.Mods) Win32Unicode {
    var key_state = [_]u8{0} ** 256;
    if (mods.shift) {
        key_state[0x10] = 0x80;
        key_state[if (mods.sides.shift == .right) 0xA1 else 0xA0] = 0x80;
    }
    if (mods.ctrl) {
        key_state[0x11] = 0x80;
        key_state[if (mods.sides.ctrl == .right) 0xA3 else 0xA2] = 0x80;
    }
    if (mods.alt) {
        key_state[0x12] = 0x80;
        key_state[if (mods.sides.alt == .right) 0xA5 else 0xA4] = 0x80;
    }
    if (mods.caps_lock) key_state[0x14] = 0x01;
    if (mods.num_lock) key_state[0x90] = 0x01;
    if ((win32.GetKeyState(0x91) & 1) != 0) key_state[0x91] = 0x01;

    var buffer: [4:0]u16 = .{ 0, 0, 0, 0 };
    const written = win32.ToUnicodeEx(
        @intCast(vk),
        scanCode(lparam),
        &key_state,
        &buffer,
        buffer.len,
        0x4,
        win32.GetKeyboardLayout(0),
    );
    if (written <= 0) return .{};
    return .{
        .units = .{ buffer[0], if (written > 1) buffer[1] else 0 },
        .len = if (written > 1) 2 else 1,
    };
}

fn win32KeyMetadata(
    vk: win32.WPARAM,
    lparam: win32.LPARAM,
    mods: input.Mods,
    action: input.Action,
) input.KeyEvent.Win32 {
    const unicode = modifiedUnicode(vk, lparam, mods);
    return .{
        .virtual_key = @truncate(vk),
        .scan_code = @intCast(scanCode(lparam)),
        .unicode = unicode.units,
        .unicode_len = unicode.len,
        .key_down = action != .release,
        .control_key_state = win32ControlKeyState(mods, lparam),
        .repeat_count = keyRepeatCount(lparam),
    };
}

fn virtualKeyForText(lparam: win32.LPARAM, codepoint: u21) u16 {
    const layout = win32.GetKeyboardLayout(0);
    if (scanCode(lparam) != 0) {
        const mapped = win32.MapVirtualKeyExW(nativeKeycode(lparam), 3, layout);
        if (mapped != 0) return @truncate(mapped);
    }
    if (codepoint <= 0xFFFF) {
        const mapped = win32.VkKeyScanExW(@intCast(codepoint), layout);
        if (mapped != -1) return @as(u16, @bitCast(mapped)) & 0xFF;
    }
    return 0;
}

fn win32TextMetadata(
    pending: ?Surface.PendingTextKey,
    lparam: win32.LPARAM,
    mods: input.Mods,
    codepoint: u21,
) input.KeyEvent.Win32 {
    var native = if (pending) |value|
        value.win32
    else
        win32KeyMetadata(virtualKeyForText(lparam, codepoint), lparam, mods, .press);
    const unicode = unicodeFromCodepoint(codepoint);
    native.unicode = unicode.units;
    native.unicode_len = unicode.len;
    return native;
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

fn handleTextInput(
    surface: *Surface,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    if (shouldSuppressCharacter(surface.suppressed_char_keycode, lparam)) {
        surface.pending_text_key = null;
        surface.pending_high_surrogate = null;
        return 0;
    }

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
        .win32 = win32TextMetadata(pending, lparam, mods, codepoint),
    };
    _ = core.keyCallback(event) catch |err| {
        log.err("key callback error: {}", .{err});
    };
    return 0;
}

fn handleFocus(surface: *Surface, focused: bool) void {
    if (!focused) {
        surface.pending_text_key = null;
        surface.pending_high_surrogate = null;
        surface.suppressed_char_keycode = null;
        Mouse.releaseMouseButtons(surface);
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
                    FileDrop.handleDrop(surface, drop) catch |err| {
                        log.warn("file drop failed: {}", .{err});
                        FileDrop.showWarning(surface, switch (err) {
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
        CommandPalette.WM_SHOW_COMMAND_PALETTE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    CommandPalette.showForSurface(surface.rtApp(), surface) catch |err| {
                        log.warn("command palette failed: {}", .{err});
                    };
                }
            }
            return 0;
        },
        Recovery.WM_TEST_RECOVER_RENDERER => return Recovery.testRecoverRenderer(hwnd, msg, wparam, lparam),
        Recovery.WM_TEST_RECOVERY_STATUS => return Recovery.testRecoveryStatus(hwnd, msg, wparam, lparam),
        win32.WM_POWERBROADCAST => return Recovery.powerBroadcast(hwnd, wparam),
        win32.WM_SIZE => return WindowLayout.sizeChanged(hwnd, lparam),
        win32.WM_MOVE => return WindowLayout.moved(hwnd),
        win32.WM_DPICHANGED => return WindowLayout.dpiChanged(hwnd, wparam, lparam),
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
                            TabBarController.invalidate(window);
                            if (window.active_tab != previous_tab) {
                                TabBarAccessibility.sync(surface.rtApp(), window, true, false);
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
                        WindowLayout.layoutWindow(app, window);
                    } else {
                        if (window.tab_bar_hwnd) |tab_bar| {
                            _ = win32.ShowWindow(tab_bar, win32.SW_HIDE);
                        }
                        SplitDivider.hide(window, 0);
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
        win32.WM_SETTINGCHANGE, win32.WM_SYSCOLORCHANGE, win32.WM_THEMECHANGED => return WindowAppearance.refreshTheme(hwnd),
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
                    SplitDivider.handleCursor(surface))
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
                    Mouse.trackMouseLeave(surface, hwnd);
                    if (surface.scrollbar) |bar| bar.hoverAt(@intFromFloat(Mouse.mousePoint(lparam).x));
                    if (SplitDivider.updatePointer(surface, hwnd, lparam)) return 0;
                    Mouse.updateCursorPosition(surface, Mouse.mousePoint(lparam), getModifiers(), false);
                } else if (hwnd == surface.windowHwnd()) {
                    if (surface.rtApp().windowForSurface(surface)) |window| {
                        SplitDivider.trackMouseLeave(window, hwnd);
                    }
                    _ = SplitDivider.updatePointer(surface, hwnd, lparam);
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
                            SplitDivider.setHover(window, null);
                        }
                    }
                    Mouse.updateCursorPosition(surface, .{ .x = -1, .y = -1 }, getModifiers(), true);
                } else if (hwnd == surface.windowHwnd()) {
                    if (surface.rtApp().windowForSurface(surface)) |window| {
                        window.split_divider_tracking_mouse_leave = false;
                        if (window.split_divider_drag == null) {
                            SplitDivider.setHover(window, null);
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
                        SplitDivider.beginDrag(surface, hwnd, lparam))
                    {
                        return 0;
                    }
                    if (msg == win32.WM_LBUTTONUP and
                        SplitDivider.endDrag(surface, hwnd, lparam))
                    {
                        return 0;
                    }
                    if (hwnd == surface.hwnd) {
                        if (Mouse.mouseButtonEvent(msg, wparam)) |event| {
                            return Mouse.handleMouseButton(surface, hwnd, event, lparam);
                        }
                    }
                }
            }
            return 0;
        },
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) Mouse.handleMouseWheel(surface, hwnd, msg, wparam, lparam);
            }
            return 0;
        },
        win32.WM_CAPTURECHANGED => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd or hwnd == surface.windowHwnd()) {
                    SplitDivider.cancelDrag(surface, hwnd);
                    if (hwnd == surface.hwnd) Mouse.releaseMouseButtons(surface);
                }
            }
            return 0;
        },
        win32.WM_CHAR, win32.WM_SYSCHAR => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) return handleTextInput(surface, wparam, lparam);
            }
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) surface.suppressed_char_keycode = null;
            }

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
                        const action = keyAction(lparam);
                        const native = win32KeyMetadata(wparam, lparam, mods, action);

                        if (!shouldDispatchKeyPress(wparam, mods)) {
                            surface.pending_text_key = .{
                                .action = action,
                                .key = key,
                                .mods = mods,
                                .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                                .win32 = native,
                            };
                            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                        }

                        surface.pending_text_key = null;
                        const effect = core.keyCallback(.{
                            .action = action,
                            .key = key,
                            .mods = mods,
                            .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                            .win32 = native,
                        }) catch |err| {
                            log.err("key callback error: {}", .{err});
                            return 0;
                        };
                        if (effect == .consumed or effect == .closed) {
                            surface.suppressed_char_keycode = characterMessageKey(lparam);
                            return 0;
                        }
                    }
                }
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) surface.suppressed_char_keycode = null;
            }

            // See the VK_PROCESSKEY note on WM_KEYDOWN.
            if (wparam == vk_processkey) {
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }

            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    if (surface.core_surface) |core| {
                        const key = mapKey(wparam, lparam);
                        const mods = getModifiers();
                        _ = core.keyCallback(.{
                            .action = .release,
                            .key = key,
                            .mods = mods,
                            .unshifted_codepoint = unshiftedCodepoint(wparam, lparam),
                            .win32 = win32KeyMetadata(wparam, lparam, mods, .release),
                        }) catch |err| {
                            log.err("key release callback error: {}", .{err});
                        };
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

test "Win32 input metadata for Ctrl+Space" {
    const lparam: win32.LPARAM = @bitCast(
        @as(usize, 1) |
            (@as(usize, 0x39) << 16),
    );
    const mods: input.Mods = .{ .ctrl = true };
    const native = win32KeyMetadata(0x20, lparam, mods, .press);
    try std.testing.expectEqual(@as(u16, 0x20), native.virtual_key);
    try std.testing.expectEqual(@as(u16, 0x39), native.scan_code);
    try std.testing.expectEqual(@as(u16, 0x20), native.unicode[0]);
    try std.testing.expectEqual(@as(u2, 1), native.unicode_len);
    try std.testing.expect(native.key_down);
    try std.testing.expectEqual(@as(u16, 0x08), native.control_key_state & ~@as(u16, 0x40));
    try std.testing.expectEqual(@as(u16, 1), native.repeat_count);
    try std.testing.expectEqual(@as(u16, 0x20), virtualKeyForText(lparam, ' '));
}

test "Win32 input metadata preserves supplementary Unicode" {
    const native = unicodeFromCodepoint(0x1F600);
    try std.testing.expectEqual(@as(u2, 2), native.len);
    try std.testing.expectEqual(@as(u16, 0xD83D), native.units[0]);
    try std.testing.expectEqual(@as(u16, 0xDE00), native.units[1]);
}

test "Win32 text metadata uses the WM_CHAR Unicode value" {
    const lparam: win32.LPARAM = @bitCast(
        @as(usize, 1) |
            (@as(usize, 0x1E) << 16),
    );
    const pending: Surface.PendingTextKey = .{
        .action = .press,
        .key = .key_a,
        .mods = .{ .shift = true },
        .unshifted_codepoint = 'a',
        .win32 = .{
            .virtual_key = 0x41,
            .scan_code = 0x1E,
            .unicode = .{ 'a', 0 },
            .control_key_state = 0x10,
        },
    };
    const text = win32TextMetadata(pending, lparam, pending.mods, 'A');
    try std.testing.expectEqual(@as(u16, 0x41), text.virtual_key);
    try std.testing.expectEqual(@as(u16, 0x1E), text.scan_code);
    try std.testing.expectEqual(@as(u16, 'A'), text.unicode[0]);
    try std.testing.expectEqual(@as(u16, 0x10), text.control_key_state);

    // A committed character without a pending physical key follows the same
    // path and derives the best available virtual key from the character.
    const committed = win32TextMetadata(null, 0, .{}, ' ');
    try std.testing.expectEqual(@as(u16, 0x20), committed.virtual_key);
    try std.testing.expectEqual(@as(u16, ' '), committed.unicode[0]);
}

test "match Win32 character messages to consumed physical keys" {
    const scan = struct {
        fn lparam(code: usize, extended: bool, repeat: usize) win32.LPARAM {
            return @bitCast(
                (repeat & 0xFFFF) |
                    (code << 16) |
                    (@as(usize, @intFromBool(extended)) << 24),
            );
        }
    };

    const space = scan.lparam(0x39, false, 1);
    const expected = characterMessageKey(space);
    try std.testing.expectEqual(@as(?u32, 0x39), expected);
    try std.testing.expect(shouldSuppressCharacter(expected, space));

    // Repeat count and other key-state bits do not change the identity.
    try std.testing.expect(shouldSuppressCharacter(
        expected,
        scan.lparam(0x39, false, 3),
    ));

    try std.testing.expect(!shouldSuppressCharacter(
        expected,
        scan.lparam(0x39, true, 1),
    ));
    try std.testing.expect(!shouldSuppressCharacter(
        expected,
        scan.lparam(0x1E, false, 1),
    ));
    try std.testing.expect(!shouldSuppressCharacter(null, space));
    try std.testing.expect(!shouldSuppressCharacter(expected, 0));
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

test "restore Win32 native window state after fullscreen" {
    try registerWindowClass();
    defer _ = win32.UnregisterClassW(
        NativeWindow.window_class_name,
        win32.GetModuleHandleW(null),
    );

    const hwnd = try NativeWindow.createWindow();
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

    const original_style = WindowState.getWindowStyle(hwnd).?;
    try std.testing.expect(WindowState.setWindowDecorations(&surface, false));
    try std.testing.expect(!surface.decorated);
    try std.testing.expectEqual(
        WindowState.styleWithDecorations(original_style, false),
        WindowState.getWindowStyle(hwnd).?,
    );

    try std.testing.expect(WindowState.setWindowDecorations(&surface, true));
    try std.testing.expect(surface.decorated);
    try std.testing.expectEqual(original_style, WindowState.getWindowStyle(hwnd).?);

    try std.testing.expect(WindowState.setAlwaysOnTop(&surface, true));
    try std.testing.expect(surface.always_on_top);
    try std.testing.expect(WindowState.setAlwaysOnTop(&surface, false));
    try std.testing.expect(!surface.always_on_top);

    try std.testing.expect(WindowState.enterFullscreen(&surface));
    try std.testing.expect(surface.fullscreen);
    try std.testing.expectEqual(
        WindowState.styleWithDecorations(original_style, false),
        WindowState.getWindowStyle(hwnd).?,
    );

    // A decoration toggle made in fullscreen is deferred until restoration.
    // Keep this test-only native window hidden when its placement is applied.
    if (surface.windowed_placement) |*placement| {
        placement.showCmd = win32.SW_HIDE;
    }
    try std.testing.expect(WindowState.setWindowDecorations(&surface, false));
    try std.testing.expect(WindowState.leaveFullscreen(&surface));
    try std.testing.expect(!surface.fullscreen);
    try std.testing.expectEqual(
        WindowState.styleWithDecorations(original_style, false),
        WindowState.getWindowStyle(hwnd).?,
    );
}
