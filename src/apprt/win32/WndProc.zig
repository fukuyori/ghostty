//! Window procedure for the Win32 runtime's parent and terminal windows:
//! userdata lookup and message dispatch, delegating each message to the
//! module that owns it.

const std = @import("std");
const TestHooks = @import("LifecycleTestHooks.zig");
const win32 = @import("win32").everything;
const CommandPalette = @import("CommandPalette.zig");
const FileDrop = @import("FileDrop.zig");
const Keyboard = @import("Keyboard.zig");
const Mouse = @import("Mouse.zig");
const NativeWindow = @import("NativeWindow.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Recovery = @import("Recovery.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const SplitDivider = @import("SplitDivider.zig");
const Surface = @import("Surface.zig");
const TabBarAccessibility = @import("TabBarAccessibility.zig");
const TabBarController = @import("TabBarController.zig");
const WindowAppearance = @import("WindowAppearance.zig");
const WindowLayout = @import("WindowLayout.zig");
const WindowLifecycle = @import("WindowLifecycle.zig");

const log = std.log.scoped(.win32);

const WM_CLOSE_SURFACE = WindowLifecycle.WM_CLOSE_SURFACE;
pub fn getSurface(hwnd: win32.HWND) ?*Surface {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

const QuickTerminalWindow = struct { app: *App, window: *Window };

/// The quick terminal, if `hwnd` is its top-level window.
fn quickTerminalWindow(hwnd: win32.HWND) ?QuickTerminalWindow {
    const surface = getSurface(hwnd) orelse return null;
    if (hwnd != surface.windowHwnd()) return null;
    const app = surface.rtApp();
    const window = app.windowForHwnd(hwnd) orelse return null;
    if (!window.quick) return null;
    return .{ .app = app, .window = window };
}

fn refreshQuickTerminal(hwnd: win32.HWND) void {
    const quick = quickTerminalWindow(hwnd) orelse return;
    QuickTerminal.refresh(quick.app, quick.window);
}

pub fn wndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (comptime @import("../../build_config.zig").win32_test_hooks) {
        if (getSurface(hwnd)) |surface| {
            if (hwnd == surface.hwnd) @import("ImeDiagnostics.zig").message(surface, msg, wparam, lparam);
        }
    }
    switch (msg) {
        TestHooks.WM_CONTROL => return TestHooks.control(hwnd, wparam, lparam),
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
        win32.WM_DPICHANGED => {
            NativeWindow.updateWindowIcons(hwnd);
            const result = WindowLayout.dpiChanged(hwnd, wparam, lparam);
            refreshQuickTerminal(hwnd);
            return result;
        },
        win32.WM_NCDESTROY => {
            NativeWindow.releaseWindowIcons(hwnd);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_DISPLAYCHANGE => {
            refreshQuickTerminal(hwnd);
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_ACTIVATE => {
            if (quickTerminalWindow(hwnd)) |quick| {
                const state: u16 = @truncate(wparam);
                const other: ?win32.HWND = if (lparam == 0) null else @ptrFromInt(@as(usize, @bitCast(lparam)));
                QuickTerminal.activationChanged(quick.app, quick.window, state != win32.WA_INACTIVE, other);
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_MOUSEACTIVATE => {
            if (getSurface(hwnd)) |surface| {
                const app = surface.rtApp();
                if (app.windowForSurface(surface)) |window| {
                    if (QuickTerminal.keyboardDisabled(app, window)) return win32.MA_NOACTIVATE;
                }
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_INPUTLANGCHANGE => {
            // Global keybindings were translated with the previous keyboard
            // layout. The notification reaches the focused terminal child,
            // and DefWindowProc forwards it only downward, so every window
            // checks; the layout comparison keeps this to one registration.
            if (getSurface(hwnd)) |surface| {
                const app = surface.rtApp();
                if (app.global_hotkeys.layoutChanged()) app.reregisterGlobalHotkeys();
            }
            return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
            if (getSurface(hwnd)) |surface| {
                if (hwnd == surface.windowHwnd()) {
                    if (msg == win32.WM_SETFOCUS) {
                        const focus = if (surface.rtApp().windowForHwnd(hwnd)) |window|
                            window.focusedSurface()
                        else
                            surface;
                        if (QuickTerminal.allowsFocus(focus)) _ = win32.SetFocus(focus.hwnd);
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
        win32.WM_SETTINGCHANGE, win32.WM_SYSCOLORCHANGE, win32.WM_THEMECHANGED => {
            // WM_SETTINGCHANGE also reports work-area (taskbar) changes.
            if (msg == win32.WM_SETTINGCHANGE) refreshQuickTerminal(hwnd);
            return WindowAppearance.refreshTheme(hwnd);
        },
        win32.WM_IME_STARTCOMPOSITION,
        win32.WM_IME_COMPOSITION,
        win32.WM_IME_ENDCOMPOSITION,
        => return Keyboard.imeComposition(hwnd, msg, wparam, lparam),
        win32.WM_TIMER => {
            if (Keyboard.imeTimer(hwnd, wparam)) return 0;
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
