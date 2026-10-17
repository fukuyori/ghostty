/// Win32 application runtime for Ghostty. This is a minimal native Windows
/// application using the Win32 API with D3D11 or OpenGL rendering.
const App = @This();

const std = @import("std");
const TestHooks = @import("LifecycleTestHooks.zig");
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
const Actions = @import("Actions.zig");
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
const WndProc = @import("WndProc.zig");
const ShellOpen = @import("ShellOpen.zig");
const CommandPalette = @import("CommandPalette.zig");
const FileDrop = @import("FileDrop.zig");
const Keyboard = @import("Keyboard.zig");
const Mouse = @import("Mouse.zig");
const NativeWindow = @import("NativeWindow.zig");
const Recovery = @import("Recovery.zig");
const TaskbarProgress = @import("TaskbarProgress.zig");
const IpcHandler = @import("IpcHandler.zig");
const IpcProtocol = @import("IpcProtocol.zig");
const IpcTransport = @import("IpcTransport.zig");

comptime {
    _ = Actions;
    _ = IpcHandler;
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
    _ = TaskbarProgress;
    _ = WindowAppearance;
    _ = WindowLayout;
    _ = WindowCommands;
    _ = WindowLifecycle;
    _ = WndProc;
    _ = SplitDivider;
    _ = brand;
}

const log = std.log.scoped(.win32);
const WindowList = std.ArrayListUnmanaged(*Window);
/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP = win32.WM_USER + 1;

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
taskbar_progress_runtime: TaskbarProgress.Runtime = .{},
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

    TestHooks.init(if (comptime build_config.win32_test_hooks)
        if (environ.get(brand.env_prefix ++ "TEST_LIFECYCLE")) |value| std.mem.eql(u8, value, "1") else false
    else
        false);

    @import("ImeDiagnostics.zig").init(if (environ.get(brand.env_prefix ++ "TEST_IME_TRACE")) |value|
        std.mem.eql(u8, value, "1")
    else
        false);

    self.* = .{
        .core_app = core_app,
        .config = config_ptr,
        .alloc = alloc,
        .thread_id = win32.GetCurrentThreadId(),
        .high_contrast = WindowAppearance.highContrastEnabled(),
        .test_device_recovery = test_device_recovery,
        .test_device_recovery_failures = test_device_recovery_failures,
    };
    self.taskbar_progress_runtime.init();
    errdefer self.windows.deinit(self.alloc);
    errdefer self.backdrop_runtime.deinit();
    errdefer self.taskbar_progress_runtime.deinit();

    try registerWindowClass();
    self.wakeup_hwnd = createWakeupWindow(self) catch |err| wakeup: {
        log.warn("wakeup window unavailable; falling back to thread messages: {}", .{err});
        break :wakeup null;
    };
    errdefer self.destroyWakeupWindow();
    self.ipc_server = IpcTransport.Server.init(self.alloc, self, IpcHandler.ipcHandler) catch |err| server: {
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
    if (msg == IpcHandler.WM_IPC_REQUEST and lparam != 0) return IpcHandler.dispatch(hwnd, lparam);
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
    IpcHandler.discardPendingIpcRequests(self);
    ShellOpen.discardPending(self);
    ConfigActions.discardDiagnostics(self);
    DeferredActions.discard(self);
    WindowLifecycle.destroyAll(self);
    self.destroyWakeupWindow();
    self.taskbar_progress_runtime.deinit();
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
    WindowLifecycle.requestSurfaceClose(surface, confirm);
}

pub fn windowForSurface(self: *App, surface: *const Surface) ?*Window {
    for (self.windows.items) |window| {
        if (window.contains(surface)) return window;
    }
    return null;
}

pub fn updateTaskbarProgress(self: *App, window: *Window) void {
    if (!self.config.@"progress-style") {
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| surface.taskbar_progress = null;
    }
    var combined: ?TaskbarProgress.Report = null;
    if (self.config.@"progress-style") {
        var surfaces = window.surfaceIterator();
        while (surfaces.next()) |surface| {
            combined = TaskbarProgress.combine(combined, surface.taskbar_progress);
        }
    }
    if (window.taskbar_progress_applied_valid and TaskbarProgress.eql(window.taskbar_progress_applied, combined)) return;
    if (self.taskbar_progress_runtime.update(window.hwnd, combined)) {
        window.taskbar_progress_applied = combined;
        window.taskbar_progress_applied_valid = true;
    }
}

pub fn setTaskbarProgress(
    self: *App,
    surface: *Surface,
    report: @import("../../terminal/osc.zig").Command.ProgressReport,
) bool {
    if (!self.config.@"progress-style") return true;
    const previous = surface.taskbar_progress;
    surface.taskbar_progress = if (report.state == .remove) null else .{
        .state = report.state,
        .progress = switch (report.state) {
            .set => report.progress orelse 0,
            .indeterminate => if (previous) |old| old.progress else 0,
            .@"error", .pause => blk: {
                const supplied = report.progress orelse 0;
                if (supplied > 0) break :blk supplied;
                break :blk if (previous) |old| if (old.progress > 0) old.progress else 10 else 10;
            },
            .remove => 0,
        },
    };
    if (self.windowForSurface(surface)) |window| self.updateTaskbarProgress(window);
    return true;
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
    return Actions.perform(self, target, action, value);
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

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) anyerror!bool {
    return IpcHandler.performIpc(alloc, target, action, value);
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
        .window = WndProc.wndProc,
        .tab_bar = TabBarController.wndProc,
        .split_divider = SplitDivider.wndProc,
        .wakeup = wakeupWndProc,
    });
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
