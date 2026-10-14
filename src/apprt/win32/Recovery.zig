//! Win32 renderer recovery: bounded GPU recovery cycles, power notifications,
//! and the opt-in regression messages. App and Surface retain recovery state.

const std = @import("std");
const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const rendererpkg = @import("../../renderer.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32);

/// Renderer recovery cycles the app schedules for one surface before it
/// stops and leaves the surface blank. Each cycle is a bounded, backed-off
/// series of attempts on the renderer thread. A later power resume resets
/// the budget.
const gpu_recovery_max_cycles: u32 = 3;
/// Test-only request used by the Windows regression script. It is ignored
/// unless the process explicitly enables GHOSTTY_TEST_DEVICE_RECOVERY.
pub const WM_TEST_RECOVER_RENDERER = win32.WM_USER + 3;
pub const WM_TEST_RECOVERY_STATUS = win32.WM_USER + 4;

pub fn recoverRenderer(target: apprt.Target, health: rendererpkg.Health) !bool {
    if (comptime build_config.renderer != .d3d11) return false;

    const surface = App.targetSurface(target) orelse {
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

pub fn testRecoverRenderer(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    if (comptime !build_config.win32_test_hooks) {
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    if (App.getSurface(hwnd)) |surface| {
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
}

pub fn testRecoveryStatus(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) win32.LRESULT {
    if (comptime !build_config.win32_test_hooks) {
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    if (App.getSurface(hwnd)) |surface| {
        if (surface.rtApp().test_device_recovery) {
            // wparam 1 probes whether the hooks are compiled in and
            // enabled, so scripts can fail early with a clear message
            // instead of timing out against a release executable.
            if (wparam == 1) return 1;
            return @intCast(surface.gpu_recovery_count.load(.seq_cst));
        }
    }
    return 0;
}

pub fn powerBroadcast(
    hwnd: win32.HWND,
    wparam: win32.WPARAM,
) win32.LRESULT {
    if (App.getSurface(hwnd)) |surface| {
        if (hwnd == surface.windowHwnd()) {
            handlePowerBroadcast(surface.rtApp(), @intCast(wparam));
        }
    }
    return 1;
}

test "Win32 power resume event classification" {
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMECRITICAL));
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMESUSPEND));
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMESTANDBY));
    try std.testing.expect(isPowerResumeEvent(win32.PBT_APMRESUMEAUTOMATIC));
    try std.testing.expect(!isPowerResumeEvent(win32.PBT_APMSUSPEND));
    try std.testing.expect(!isPowerResumeEvent(0));
}
