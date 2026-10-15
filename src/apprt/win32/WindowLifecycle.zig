//! Window, tab, and split lifecycle for the Win32 runtime: creation
//! (including core surface initialization and its rollback), close requests
//! and confirmation, teardown, and tab/window removal.

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const ConfigActions = @import("ConfigActions.zig");
const DeferredActions = @import("DeferredActions.zig");
const FileDrop = @import("FileDrop.zig");
const NativeWindow = @import("NativeWindow.zig");
const Overrides = @import("Overrides.zig");
const SplitDivider = @import("SplitDivider.zig");
const Surface = @import("Surface.zig");
const TabBarAccessibility = @import("TabBarAccessibility.zig");
const TabBarController = @import("TabBarController.zig");
const Titlebar = @import("Titlebar.zig");
const Window = @import("Window.zig");
const WindowAppearance = @import("WindowAppearance.zig");
const WindowLayout = @import("WindowLayout.zig");
const WindowState = @import("WindowState.zig");

const log = std.log.scoped(.win32);

/// A surface can request closure from a core callback. Route it through the
/// window thread so confirmation and native resource teardown happen there.
pub const WM_CLOSE_SURFACE = win32.WM_USER + 2;

pub const Options = struct {
    command: ?configpkg.Command = null,
    shell_integration: ?configpkg.Config.ShellIntegration = null,
    working_directory: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,

    pub fn fromOverrides(overrides: Overrides) Options {
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
    opts: Options,
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

pub fn createWindow(self: *App, opts: Options) !void {
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
    errdefer _ = removeWindow(self, window);

    try initCoreSurface(self, surface, opts, .window);
    TabBarAccessibility.sync(self, window, false, false);
    WindowLayout.layoutWindow(self, window);
    App.showWindow(surface);
}

pub fn newTab(self: *App, target: apprt.Target) !bool {
    return newTabWithOptions(self, target, .{});
}

pub fn newTabWithOptions(self: *App, target: apprt.Target, opts: Options) !bool {
    const existing = App.targetSurface(target) orelse {
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

    try initCoreSurface(self, surface, opts, .tab);
    TabBarAccessibility.notifyEvent(window, TabBarAccessibility.event_object_reorder);
    App.activateWindowTab(self, window);
    log.info("created Win32 tab tabs={d}", .{window.tabCount()});
    return true;
}

pub fn newSplit(
    self: *App,
    target: apprt.Target,
    direction: apprt.action.SplitDirection,
) !bool {
    const existing = App.targetSurface(target) orelse {
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

    try initCoreSurface(self, surface, .{}, .split);
    WindowLayout.layoutWindow(self, window);
    _ = win32.SetFocus(surface.hwnd);
    log.info("created Win32 split direction={s} surfaces={d}", .{
        @tagName(direction),
        window.activeSurfaceCount(),
    });
    return true;
}

pub fn requestSurfaceClose(surface: *Surface, confirm: bool) void {
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

pub fn closeSurface(self: *App, surface: *Surface, confirm: bool) void {
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
        _ = destroyTabAt(self, window, index);
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
        App.transferWindowState(surface, window.stateSurface());
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
        std.debug.assert(removeWindow(self, window));
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
    if (state_will_close) App.transferWindowState(old_state, window.stateSurface());

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

/// Destroys every window at shutdown. Like closeSurface, each surface's
/// renderer and core are torn down before its child HWND is destroyed.
pub fn destroyAll(self: *App) void {
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
}

pub fn closeWindow(self: *App, target: apprt.Target) bool {
    const surface = App.targetSurface(target) orelse {
        log.warn("close_window targeted the application", .{});
        return false;
    };
    const window = self.windowForSurface(surface) orelse {
        log.warn("close_window targeted an unowned surface", .{});
        return false;
    };
    return closeOwnedWindow(self, window);
}

pub fn closeTab(
    self: *App,
    target: apprt.Target,
    mode: apprt.action.CloseTabMode,
) bool {
    const surface = App.targetSurface(target) orelse {
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
        return closeOwnedWindow(self, window);
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

pub fn closeOwnedWindow(self: *App, window: *Window) bool {
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

pub fn closeAllWindows(self: *App) bool {
    if (self.windows.items.len == 0) return false;
    return queueCloseAll(self, false);
}

pub fn queueCloseAll(self: *App, quit: bool) bool {
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

test "Win32 close tab mode selects the intended tab indexes" {
    const testing = std.testing;

    try testing.expect(tabSelectedForClose(1, 1, .this));
    try testing.expect(!tabSelectedForClose(0, 1, .this));
    try testing.expect(tabSelectedForClose(0, 1, .other));
    try testing.expect(!tabSelectedForClose(1, 1, .other));
    try testing.expect(!tabSelectedForClose(1, 1, .right));
    try testing.expect(tabSelectedForClose(2, 1, .right));
}
