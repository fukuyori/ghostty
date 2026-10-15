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
const global = @import("../../global.zig");
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
const Window = @import("Window.zig");
const WindowState = @import("WindowState.zig");
const WindowAppearance = @import("WindowAppearance.zig");
const WindowLayout = @import("WindowLayout.zig");
const WindowCommands = @import("WindowCommands.zig");
const WindowLifecycle = @import("WindowLifecycle.zig");
const SearchBar = @import("SearchBar.zig");
const ShellOpen = @import("ShellOpen.zig");
const CommandPalette = @import("CommandPalette.zig");
const FileDrop = @import("FileDrop.zig");
const Keyboard = @import("Keyboard.zig");
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
    _ = Keyboard;
    _ = Mouse;
    _ = NativeWindow;
    _ = Recovery;
    _ = WindowAppearance;
    _ = WindowLayout;
    _ = WindowCommands;
    _ = WindowLifecycle;
    _ = SplitDivider;
    _ = brand;
}

const log = std.log.scoped(.win32);
const WindowList = std.ArrayListUnmanaged(*Window);
/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP = win32.WM_USER + 1;

const WM_CLOSE_SURFACE = WindowLifecycle.WM_CLOSE_SURFACE;

const WM_IPC_REQUEST = win32.WM_USER + 6;
const ipc_ui_timeout_ms: u32 = 5000;

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
    try WindowLifecycle.createWindow(self, .{});
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
    WindowLifecycle.destroyAll(self);
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
    WindowLifecycle.requestSurfaceClose(surface, confirm);
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
        .quit => return WindowLifecycle.queueCloseAll(self, true),
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
            try WindowLifecycle.createWindow(self, .{});
            return true;
        },
        .new_tab => return try WindowLifecycle.newTab(self, target),
        .close_tab => return WindowLifecycle.closeTab(self, target, value),
        .goto_tab => return WindowCommands.gotoTab(self, target, value),
        .move_tab => return WindowCommands.moveTab(self, target, value),
        .new_split => return try WindowLifecycle.newSplit(self, target, value),
        .goto_split => return WindowCommands.gotoSplit(self, target, value),
        .resize_split => return WindowCommands.resizeSplit(self, target, value),
        .equalize_splits => return WindowCommands.equalizeSplits(self, target),
        .toggle_split_zoom => return WindowCommands.toggleSplitZoom(self, target),
        .close_window => return WindowLifecycle.closeWindow(self, target),
        .close_all_windows => return WindowLifecycle.closeAllWindows(self),
        .goto_window => return WindowCommands.gotoWindow(self, target, value),
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
    const opts = WindowLifecycle.Options.fromOverrides(overrides);

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
        if (!(WindowLifecycle.newTabWithOptions(self, .{ .surface = surface }, opts) catch false)) {
            request.status = .internal_error;
            return;
        }
    } else {
        WindowLifecycle.createWindow(self, opts) catch {
            request.status = .internal_error;
            return;
        };
    }
    request.status = if (fallback) .target_fallback else .success;
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
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

pub fn showWindow(surface: *Surface) void {
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
                        _ = WindowLifecycle.closeOwnedWindow(app, window);
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
                WindowLifecycle.closeSurface(app, surface, wparam != 0);
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
                    Keyboard.handleFocus(surface, msg == win32.WM_SETFOCUS);
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
        win32.WM_IME_STARTCOMPOSITION => return Keyboard.imeStartComposition(hwnd, msg, wparam, lparam),
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
                    Mouse.updateCursorPosition(surface, Mouse.mousePoint(lparam), Keyboard.getModifiers(), false);
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
                    Mouse.updateCursorPosition(surface, .{ .x = -1, .y = -1 }, Keyboard.getModifiers(), true);
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
        win32.WM_CHAR, win32.WM_SYSCHAR => return Keyboard.character(hwnd, wparam, lparam),
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => return Keyboard.keyDown(hwnd, msg, wparam, lparam),
        win32.WM_KEYUP, win32.WM_SYSKEYUP => return Keyboard.keyUp(hwnd, msg, wparam, lparam),
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
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
