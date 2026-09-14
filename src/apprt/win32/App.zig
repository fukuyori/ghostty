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
const d3d11_buffer = @import("../../renderer/d3d11/buffer.zig");
const D3D11RenderPass = @import("../../renderer/d3d11/RenderPass.zig");
const D3D11Sampler = @import("../../renderer/d3d11/Sampler.zig");
const D3D11Shaders = @import("../../renderer/d3d11/shaders.zig");
const D3D11Texture = @import("../../renderer/d3d11/Texture.zig");
const Backdrop = @import("Backdrop.zig");
const DirectComposition = @import("DirectComposition.zig");
const Surface = @import("Surface.zig");
const Titlebar = @import("Titlebar.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);
const WindowList = std.ArrayListUnmanaged(*Window);
const window_class_name = win32.L("GhosttyWindow");
const default_window_title = win32.L("Ghostty");

/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP = win32.WM_USER + 1;

/// A surface can request closure from a core callback. Route it through the
/// window thread so confirmation and native resource teardown happen there.
const WM_CLOSE_SURFACE = win32.WM_USER + 2;

core_app: *CoreApp,
config: *Config,
alloc: Allocator,
running: bool = true,
thread_id: u32,
windows: WindowList = .empty,
backdrop_runtime: Backdrop.Runtime = .{},

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

    self.* = .{
        .core_app = core_app,
        .config = config_ptr,
        .alloc = alloc,
        .thread_id = win32.GetCurrentThreadId(),
    };
    errdefer self.windows.deinit(self.alloc);
    errdefer self.backdrop_runtime.deinit();

    try registerWindowClass();
    try self.createWindow(.{});
    self.showConfigDiagnostics(.app, self.config);
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
        if (msg.hwnd == null and msg.message == WM_WAKEUP) {
            self.core_app.tick(self) catch |err| {
                log.err("core app tick failed: {}", .{err});
            };
            continue;
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    while (self.windows.pop()) |window| {
        for (window.surfaces.items) |surface| {
            surface.deinit();
            if (win32.DestroyWindow(surface.hwnd) == 0) {
                log.warn("DestroyWindow(surface) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            }
        }
        if (win32.DestroyWindow(window.hwnd) == 0) {
            log.warn("DestroyWindow(window) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        for (window.surfaces.items) |surface| self.alloc.destroy(surface);
        window.deinit(self.alloc);
        self.alloc.destroy(window);
    }
    self.windows.deinit(self.alloc);
    self.backdrop_runtime.deinit();
    self.config.deinit();
    self.alloc.destroy(self.config);
}

pub fn wakeup(self: *App) void {
    if (win32.PostThreadMessageW(self.thread_id, WM_WAKEUP, 0, 0) == 0) {
        log.warn("PostThreadMessage(WM_WAKEUP) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

pub fn requestSurfaceClose(_: *App, surface: *Surface, confirm: bool) void {
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
    const close_window = window.surfaces.items.len == 1;
    const was_state_surface = window.surfaces.items[0] == surface;
    const next_focus = if (close_window)
        null
    else
        window.removeSurface(self.alloc, surface) catch |err| {
            log.warn("failed to remove surface from its window: {}", .{err});
            return;
        };

    if (!close_window and was_state_surface) {
        transferWindowState(surface, window.surfaces.items[0]);
    }

    if (next_focus) |focus| {
        _ = win32.SetWindowLongPtrW(
            window.hwnd,
            win32.GWLP_USERDATA,
            @bitCast(@intFromPtr(focus)),
        );
    }

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
    _ = win32.SetFocus(focus.hwnd);
    self.layoutWindow(window);
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
        .new_window => {
            try self.createWindow(.{});
            return true;
        },
        .new_split => return try self.newSplit(target, value),
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
        .config_change => {
            switch (target) {
                .surface => |core| {
                    const state = windowStateSurface(core.rt_surface);
                    const decorated = value.config.@"window-decoration" != .none;
                    if (!setWindowDecorations(state, decorated)) {
                        log.warn("failed to apply window-decoration setting", .{});
                    }
                    Titlebar.apply(state.windowHwnd(), value.config);
                    updateWindowBackgroundBlur(state, value.config);
                },
                .app => {
                    const config = try value.config.clone(self.alloc);
                    self.config.deinit();
                    self.config.* = config;
                },
            }
            return true;
        },
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

fn closeOwnedWindow(self: *App, window: *Window) bool {
    for (window.surfaces.items) |surface| {
        const core = surface.core_surface orelse continue;
        if (!core.needsConfirmQuit()) continue;
        if (!confirmSurfaceClose(window.hwnd)) return true;
        break;
    }

    // Post every close before processing any of them so the surface list is
    // stable throughout this loop.
    for (window.surfaces.items) |surface| {
        self.requestSurfaceClose(surface, false);
    }
    return true;
}

fn closeAllWindows(self: *App) bool {
    if (self.windows.items.len == 0) return false;

    // Match the native app behavior: ask once for the complete operation,
    // rather than showing one confirmation for every running terminal.
    var confirm_hwnd: ?win32.HWND = null;
    for (self.windows.items) |window| {
        for (window.surfaces.items) |surface| {
            const core = surface.core_surface orelse continue;
            if (core.needsConfirmQuit()) {
                confirm_hwnd = window.hwnd;
                break;
            }
        }
        if (confirm_hwnd != null) break;
    }
    if (confirm_hwnd) |hwnd| {
        if (!confirmAllWindowsClose(hwnd)) return true;
    }

    // Closing is posted to the message queue. The list therefore remains
    // stable throughout this loop and each close follows normal teardown.
    for (self.windows.items) |window| {
        for (window.surfaces.items) |surface| {
            self.requestSurfaceClose(surface, false);
        }
    }
    return true;
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
        const state = window.surfaces.items[0];
        if (state.hidden_by_visibility_toggle) {
            restore_any = true;
            break;
        }
    }

    if (restore_any) {
        var first: ?*Surface = null;
        var focus: ?*Surface = null;
        for (self.windows.items) |window| {
            const state = window.surfaces.items[0];
            if (!state.hidden_by_visibility_toggle) continue;
            state.hidden_by_visibility_toggle = false;
            _ = win32.ShowWindow(window.hwnd, win32.SW_SHOWNA);
            if (first == null) first = window.focused_surface;
            if (state.focused_before_visibility_toggle) focus = window.focused_surface;
            state.focused_before_visibility_toggle = false;
        }
        if (focus orelse first) |surface| _ = presentSurface(surface);
        return true;
    }

    const focused = self.core_app.focusedSurface();
    if (focused) |core| {
        for (self.windows.items) |window| {
            for (window.surfaces.items) |surface| {
                if (surface.core_surface != core) continue;
                if (window.surfaces.items[0].fullscreen) return true;
                break;
            }
        }
    }

    var hidden_any = false;
    for (self.windows.items) |window| {
        const state = window.surfaces.items[0];
        if (win32.IsWindowVisible(window.hwnd) == 0) continue;
        state.hidden_by_visibility_toggle = true;
        state.focused_before_visibility_toggle = if (focused) |core| focused_in_window: {
            for (window.surfaces.items) |candidate| {
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
        return presentSurface(candidate.focused_surface);
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
    return window.surfaces.items[0];
}

fn transferWindowState(from: *Surface, to: *Surface) void {
    std.debug.assert(from.windowHwnd() == to.windowHwnd());
    std.debug.assert(to.background_blur == null);

    to.background_blur = from.background_blur;
    from.background_blur = null;
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
    if (context == .window) {
        surface.default_maximized = config.maximize;
        surface.default_fullscreen = config.fullscreen != .false;
        if (!setWindowDecorations(
            surface,
            config.@"window-decoration" != .none,
        )) {
            log.warn("failed to apply initial window-decoration setting", .{});
        }
        Titlebar.apply(surface.windowHwnd(), &config);
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
    if (context == .window) updateWindowBackgroundBlur(surface, &config);
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
    self.layoutWindow(window);
    showWindow(surface);
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
        window.surfaces.items.len,
    });
    return true;
}

fn layoutWindow(self: *App, window: *Window) void {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(window.hwnd, &client) == 0) {
        log.warn("GetClientRect for window layout failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return;
    }

    const rects = self.alloc.alloc(Window.LeafRect, window.surfaces.items.len) catch |err| {
        log.warn("failed to allocate window layout: {}", .{err});
        return;
    };
    defer self.alloc.free(rects);

    const count = window.layout(
        .{
            .x = 0,
            .y = 0,
            .width = @max(0, client.right - client.left),
            .height = @max(0, client.bottom - client.top),
        },
        1,
        rects,
    );
    for (rects[0..count]) |entry| {
        if (win32.SetWindowPos(
            entry.view.hwnd,
            null,
            entry.rect.x,
            entry.rect.y,
            entry.rect.width,
            entry.rect.height,
            .{ .NOZORDER = 1, .NOACTIVATE = 1 },
        ) == 0) {
            log.warn("SetWindowPos(surface layout) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }
}

fn registerWindowClass() !void {
    const hinstance = win32.GetModuleHandleW(null);

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
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = window_class_name,
        .hIconSm = null,
    };

    if (win32.RegisterClassExW(&wc) == 0) {
        log.err("RegisterClassExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }
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
    if (radius) |value| {
        if (surface.background_blur) |*backdrop| {
            backdrop.setRadius(value) catch |err|
                log.warn("failed to update Win32 background blur: {}", .{err});
            return;
        }

        surface.background_blur = Backdrop.init(
            surface.windowHwnd(),
            value,
            &surface.rtApp().backdrop_runtime,
        ) catch |err| {
            // Older Windows versions don't recognize the system-backdrop
            // attribute. Keep rendering with ordinary transparency.
            log.warn("failed to apply Win32 background blur: {}", .{err});
            return;
        };
    } else if (surface.background_blur) |*backdrop| {
        backdrop.deinit();
        surface.background_blur = null;
    }
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
        0xDB...0xDE,
        => true,
        else => false,
    };
}

fn isAltGr(mods: input.Mods) bool {
    return mods.ctrl and mods.alt and mods.sides.alt == .right;
}

fn shouldDispatchKeyPress(vk: win32.WPARAM, mods: input.Mods) bool {
    if (!isTextVirtualKey(vk)) return true;
    if (mods.super) return true;
    if (mods.alt and !isAltGr(mods)) return true;
    if (mods.ctrl and !isAltGr(mods)) return true;
    return false;
}

fn unshiftedCodepoint(vk: win32.WPARAM) u21 {
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
    var consumed_mods: input.Mods = .{};
    if (isAltGr(mods)) {
        consumed_mods.ctrl = true;
        consumed_mods.alt = true;
    }

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
        if (surface.mouse_buttons_down == 0) _ = win32.SetCapture(hwnd);
        surface.mouse_buttons_down |= event.bit;
    } else {
        surface.mouse_buttons_down &= ~event.bit;
    }

    if (surface.core_surface) |core| {
        _ = core.mouseButtonCallback(event.state, event.button, mods) catch |err| {
            log.err("mouse button callback error: {}", .{err});
        };
    }

    if (event.state == .release and surface.mouse_buttons_down == 0 and
        win32.GetCapture() == hwnd)
    {
        if (win32.ReleaseCapture() == 0) {
            log.warn("ReleaseCapture failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }

    // XBUTTON messages require TRUE to prevent further processing.
    return if (event.xbutton) 1 else 0;
}

fn releaseMouseButtons(surface: *Surface) void {
    const down = surface.mouse_buttons_down;
    if (down == 0) return;
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

fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (msg) {
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
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(lparam)));
                surface.rtApp().closeSurface(surface, wparam != 0);
            }
            return 0;
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
        win32.WM_DPICHANGED => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    if (surface.rtApp().windowForHwnd(hwnd)) |window| {
                        for (window.surfaces.items) |candidate| {
                            if (candidate == surface) continue;
                            if (candidate.core_surface) |core| {
                                core.contentScaleCallback(dpiScale(wparam)) catch |err| {
                                    log.err("content scale callback error: {}", .{err});
                                };
                            }
                        }
                    }
                    handleDpiChanged(surface, hwnd, wparam, lparam);
                }
            }
            return 0;
        },
        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    if (msg == win32.WM_SETFOCUS) {
                        const focus = if (surface.rtApp().windowForHwnd(hwnd)) |window|
                            window.focused_surface
                        else
                            surface;
                        _ = win32.SetFocus(focus.hwnd);
                    }
                } else if (hwnd == surface.hwnd) {
                    if (msg == win32.WM_SETFOCUS) {
                        if (surface.rtApp().windowForSurface(surface)) |window| {
                            window.focused_surface = surface;
                            _ = win32.SetWindowLongPtrW(
                                window.hwnd,
                                win32.GWLP_USERDATA,
                                @bitCast(@intFromPtr(surface)),
                            );
                        }
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
                    for (window.surfaces.items) |candidate| {
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
        win32.WM_MOUSEMOVE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    trackMouseLeave(surface, hwnd);
                    updateCursorPosition(surface, mousePoint(lparam), getModifiers(), false);
                }
            }
            return 0;
        },
        win32.WM_MOUSELEAVE => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    surface.tracking_mouse_leave = false;
                    updateCursorPosition(surface, .{ .x = -1, .y = -1 }, getModifiers(), true);
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
                if (hwnd == surface.hwnd) {
                    if (mouseButtonEvent(msg, wparam)) |event| {
                        return handleMouseButton(surface, hwnd, event, lparam);
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
                if (hwnd == surface.hwnd) releaseMouseButtons(surface);
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
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    if (surface.core_surface) |core| {
                        const mods = getModifiers();
                        const key = mapVirtualKey(wparam, lparam);

                        if (!shouldDispatchKeyPress(wparam, mods)) {
                            surface.pending_text_key = .{
                                .action = keyAction(lparam),
                                .key = key,
                                .mods = mods,
                                .unshifted_codepoint = unshiftedCodepoint(wparam),
                            };
                            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                        }

                        surface.pending_text_key = null;
                        if (key != .unidentified) {
                            const effect = core.keyCallback(.{
                                .action = keyAction(lparam),
                                .key = key,
                                .mods = mods,
                                .unshifted_codepoint = unshiftedCodepoint(wparam),
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
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.hwnd) {
                    if (surface.core_surface) |core| {
                        const key = mapVirtualKey(wparam, lparam);
                        if (key != .unidentified) {
                            _ = core.keyCallback(.{
                                .action = .release,
                                .key = key,
                                .mods = getModifiers(),
                                .unshifted_codepoint = unshiftedCodepoint(wparam),
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
    try std.testing.expectEqual(input.Key.numpad_enter, mapVirtualKey(0x0D, 1 << 24));
    try std.testing.expectEqual(input.Key.control_right, mapVirtualKey(0x11, 1 << 24));
    try std.testing.expectEqual(input.Key.unidentified, mapVirtualKey(0xFF, 0));
}

test "classify Win32 text keys" {
    try std.testing.expect(isTextVirtualKey(0x41));
    try std.testing.expect(isTextVirtualKey(0xDE));
    try std.testing.expect(!isTextVirtualKey(0x25));

    try std.testing.expectEqual(input.Action.press, keyAction(0));
    try std.testing.expectEqual(input.Action.repeat, keyAction(1 << 30));
    try std.testing.expectEqual(@as(u21, 'a'), unshiftedCodepoint(0x41));

    var altgr: input.Mods = .{ .ctrl = true, .alt = true };
    altgr.sides.alt = .right;
    try std.testing.expect(!shouldDispatchKeyPress(0x41, altgr));

    var left_alt: input.Mods = .{ .alt = true };
    left_alt.sides.alt = .left;
    try std.testing.expect(shouldDispatchKeyPress(0x41, left_alt));
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
