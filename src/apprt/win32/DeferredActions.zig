//! Modal user actions run only from App.run, after core callbacks unwind.
//! Requests own their text and identify terminals by core ID, never by a
//! retained Surface pointer, tab index, or reusable native window handle.
const std = @import("std");
const win32 = @import("win32").everything;
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabTitles = @import("TabTitles.zig");
const FileDrop = @import("FileDrop.zig");
const log = std.log.scoped(.win32);

pub const Close = struct {
    ids: std.ArrayListUnmanaged(u64) = .empty,
    confirm: bool = false,
    all: bool = false,
    quit: bool = false,
    snapshot_session: bool = false,

    pub fn add(self: *Close, alloc: std.mem.Allocator, surface: *Surface) !void {
        const core = surface.core_surface orelse return;
        try self.ids.append(alloc, core.id);
        self.confirm = self.confirm or core.needsConfirmQuit();
    }

    pub fn deinit(self: *Close, alloc: std.mem.Allocator) void {
        self.ids.deinit(alloc);
        self.* = .{};
    }
};

pub const Request = union(enum) {
    close: Close,
    rename: u64,
    paste: struct { id: u64, text: []u8 },
    warning: struct { id: u64, text: []u8 },

    fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .close => |*value| value.deinit(alloc),
            .paste => |value| alloc.free(value.text),
            .warning => |value| alloc.free(value.text),
            .rename => {},
        }
    }
};

pub const Queue = std.ArrayListUnmanaged(Request);
const timer_id: usize = 0x3603;

/// A close without a dialog can still post destruction immediately. This is
/// essential when a shell exits or WM_CLOSE arrives inside another modal loop.
pub fn requestClose(app: *App, value: Close) bool {
    if (value.confirm) return enqueue(app, .{ .close = value });
    var request = value;
    defer request.deinit(app.alloc);
    close(app, request);
    return true;
}

/// Takes ownership even if the allocation fails.
pub fn enqueue(app: *App, value: Request) bool {
    var request = value;
    app.pending_actions.append(app.alloc, request) catch |err| {
        request.deinit(app.alloc);
        log.warn("failed to queue modal action: {}", .{err});
        return false;
    };
    if (app.wakeup_hwnd) |hwnd| {
        if (win32.SetTimer(hwnd, timer_id, 50, null) != 0) return true;
    }
    app.wakeup();
    return true;
}

pub fn resolve(app: *App, id: u64) ?*Surface {
    const core = app.core_app.findSurfaceByID(id) orelse return null;
    const surface = core.rt_surface;
    if (app.windowForSurface(surface) == null) return null;
    return surface;
}

pub fn discard(app: *App) void {
    if (app.wakeup_hwnd) |hwnd| _ = win32.KillTimer(hwnd, timer_id);
    for (app.pending_actions.items) |*request| request.deinit(app.alloc);
    app.pending_actions.deinit(app.alloc);
    app.pending_actions = .empty;
}

pub fn drain(app: *App) void {
    if (app.pending_actions.items.len == 0) return;
    defer if (app.wakeup_hwnd) |hwnd| {
        _ = win32.KillTimer(hwnd, timer_id);
    };
    while (app.pending_actions.items.len > 0) {
        var msg: win32.MSG = undefined;
        if (!app.running or win32.PeekMessageW(&msg, null, win32.WM_QUIT, win32.WM_QUIT, .{}) != 0) {
            discard(app);
            return;
        }
        var request = app.pending_actions.orderedRemove(0);
        defer request.deinit(app.alloc);
        switch (request) {
            .close => |value| close(app, value),
            .rename => |id| TabTitles.showPrompt(app, id) catch |err| {
                log.warn("tab title dialog failed: {}", .{err});
            },
            .paste => |value| FileDrop.pasteQueued(app, value.id, value.text) catch |err| {
                log.warn("file drop paste failed: {}", .{err});
                FileDrop.showQueuedWarning(app, value.id, "The dropped files could not be pasted.");
            },
            .warning => |value| FileDrop.showQueuedWarning(app, value.id, value.text),
        }
    }
}

fn close(app: *App, request: Close) void {
    const parent = parent: {
        for (request.ids.items) |id| {
            if (resolve(app, id)) |surface| break :parent surface.windowHwnd();
        }
        break :parent null;
    };
    if (parent) |hwnd| {
        if (request.confirm) {
            const caption = if (request.all) win32.L("Close All Windows?") else win32.L("Close Terminal?");
            const message = if (request.all)
                win32.L("All terminal sessions will be terminated. Close all windows?")
            else
                win32.L("The terminal still has a running process. If you close the terminal the process will be killed.");
            const style: win32.MESSAGEBOX_STYLE = .{ .YESNO = 1, .ICONHAND = 1, .ICONQUESTION = 1, .DEFBUTTON2 = 1 };
            if (win32.MessageBoxW(hwnd, message, caption, style) != win32.IDYES) return;
        }
    }
    if (request.snapshot_session) {
        app.persistSession();
        for (request.ids.items) |id| {
            const surface = resolve(app, id) orelse continue;
            if (app.windowForSurface(surface)) |window| window.session_close_snapshot = true;
        }
    }
    if (request.quit) {
        win32.PostQuitMessage(0);
        return;
    }
    // A modal loop can remove/reorder tabs or destroy/recreate windows. Close
    // only surviving members of the original selection, using stable IDs.
    for (request.ids.items) |id| {
        if (resolve(app, id)) |surface| app.requestSurfaceClose(surface, false);
    }
}

test "Win32 deferred actions release owned requests" {
    const alloc = std.testing.allocator;
    var close_request: Request = .{ .close = .{} };
    try close_request.close.ids.append(alloc, 12);
    close_request.deinit(alloc);
    var paste: Request = .{ .paste = .{ .id = 12, .text = try alloc.dupe(u8, "path") } };
    paste.deinit(alloc);
    var warning: Request = .{ .warning = .{ .id = 12, .text = try alloc.dupe(u8, "warning") } };
    warning.deinit(alloc);
}
