//! Windows taskbar progress integration for OSC 9;4 reports.

const std = @import("std");
const win32 = @import("win32").everything;
const ProgressReport = @import("../../terminal/osc.zig").Command.ProgressReport;

const log = std.log.scoped(.win32_taskbar_progress);

pub const Report = struct {
    state: ProgressReport.State,
    progress: u8 = 0,

    fn priority(self: Report) u8 {
        return switch (self.state) {
            .@"error" => 1,
            .pause => 2,
            .set => 3,
            .indeterminate => 4,
            .remove => 5,
        };
    }
};

pub fn eql(lhs: ?Report, rhs: ?Report) bool {
    if (lhs) |left| {
        const right = rhs orelse return false;
        return left.state == right.state and left.progress == right.progress;
    }
    return rhs == null;
}

/// Windows Terminal selects the highest-priority report across all panes.
pub fn combine(current: ?Report, candidate: ?Report) ?Report {
    const lhs = current orelse return candidate;
    const rhs = candidate orelse return current;
    return if (rhs.priority() < lhs.priority()) rhs else lhs;
}

pub const Runtime = struct {
    taskbar: ?*win32.ITaskbarList3 = null,
    owns_com: bool = false,

    pub fn init(self: *Runtime) void {
        const com_hr = win32.CoInitializeEx(null, .{ .APARTMENTTHREADED = 1, .DISABLE_OLE1DDE = 1 });
        self.owns_com = com_hr >= 0;
        if (com_hr < 0 and @as(u32, @bitCast(com_hr)) != 0x80010106) {
            log.warn("CoInitializeEx for taskbar progress failed: HRESULT=0x{x}", .{@as(u32, @bitCast(com_hr))});
            return;
        }

        var object: ?*anyopaque = null;
        const create_hr = win32.CoCreateInstance(
            win32.CLSID_TaskbarList,
            null,
            .{ .INPROC_SERVER = 1 },
            win32.IID_ITaskbarList3,
            @ptrCast(&object),
        );
        if (create_hr < 0 or object == null) {
            log.warn("CoCreateInstance(ITaskbarList3) failed: HRESULT=0x{x}", .{@as(u32, @bitCast(create_hr))});
            return;
        }
        const taskbar: *win32.ITaskbarList3 = @ptrCast(@alignCast(object.?));
        const base: *win32.ITaskbarList = @ptrCast(taskbar);
        const init_hr = base.HrInit();
        if (init_hr < 0) {
            _ = taskbar.IUnknown.Release();
            log.warn("ITaskbarList3.HrInit failed: HRESULT=0x{x}", .{@as(u32, @bitCast(init_hr))});
            return;
        }
        self.taskbar = taskbar;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.taskbar) |taskbar| _ = taskbar.IUnknown.Release();
        self.taskbar = null;
        if (self.owns_com) win32.CoUninitialize();
        self.owns_com = false;
    }

    pub fn update(self: *Runtime, hwnd: win32.HWND, report: ?Report) bool {
        const taskbar = self.taskbar orelse return false;
        const state = if (report) |value| switch (value.state) {
            .remove => win32.TBPF_NOPROGRESS,
            .set => win32.TBPF_NORMAL,
            .@"error" => win32.TBPF_ERROR,
            .indeterminate => win32.TBPF_INDETERMINATE,
            .pause => win32.TBPF_PAUSED,
        } else win32.TBPF_NOPROGRESS;

        if (report != null and report.?.state == .indeterminate) {
            // Windows Terminal clears the old percentage before indeterminate mode.
            const clear_hr = taskbar.SetProgressState(hwnd, win32.TBPF_NOPROGRESS);
            if (clear_hr < 0) {
                log.warn("ITaskbarList3.SetProgressState(clear) failed: HRESULT=0x{x}", .{@as(u32, @bitCast(clear_hr))});
                return false;
            }
        }
        const hr = taskbar.SetProgressState(hwnd, state);
        if (hr < 0) {
            log.warn("ITaskbarList3.SetProgressState failed: HRESULT=0x{x}", .{@as(u32, @bitCast(hr))});
            return false;
        }
        if (report) |value| switch (value.state) {
            .set, .@"error", .pause => {
                const value_hr = taskbar.SetProgressValue(hwnd, value.progress, 100);
                if (value_hr < 0) {
                    log.warn("ITaskbarList3.SetProgressValue failed: HRESULT=0x{x}", .{@as(u32, @bitCast(value_hr))});
                    return false;
                }
            },
            .remove, .indeterminate => {},
        };
        return true;
    }
};

test "taskbar progress aggregation follows Windows Terminal priority" {
    const set: Report = .{ .state = .set, .progress = 50 };
    const err: Report = .{ .state = .@"error" };
    const pause: Report = .{ .state = .pause };
    const indeterminate: Report = .{ .state = .indeterminate };
    try std.testing.expectEqual(err, combine(set, err).?);
    try std.testing.expectEqual(pause, combine(indeterminate, pause).?);
    try std.testing.expectEqual(set, combine(set, indeterminate).?);
    try std.testing.expectEqual(set, combine(set, null).?);
    try std.testing.expect(eql(set, set));
    try std.testing.expect(!eql(set, .{ .state = .set, .progress = 51 }));
    try std.testing.expect(eql(null, null));
}
