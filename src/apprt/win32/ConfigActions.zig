//! Win32 configuration actions: reload and update, diagnostics, editor launch,
//! and scrollbar configuration. App retains ownership of the active config.

const std = @import("std");
const win32 = @import("win32").everything;
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const brand = @import("../../brand.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const global = @import("../../global.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Scrollbar = @import("Scrollbar.zig");
const ShellOpen = @import("ShellOpen.zig");
const Titlebar = @import("Titlebar.zig");
const WindowAppearance = @import("WindowAppearance.zig");
const WindowState = @import("WindowState.zig");

const log = std.log.scoped(.win32);

const DiagnosticRequest = struct {
    parent: win32.HWND,
    message: [:0]u16,
};

/// Each request owns its text, independent of the temporary reload config.
/// No Surface or core pointer survives until the modal dialog is displayed.
pub const DiagnosticQueue = struct {
    pending: std.ArrayListUnmanaged(DiagnosticRequest) = .empty,

    fn add(self: *DiagnosticQueue, alloc: Allocator, parent: win32.HWND, message: []const u8) !void {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, message);
        errdefer alloc.free(wide);
        try self.pending.append(alloc, .{ .parent = parent, .message = wide });
    }

    fn take(self: *DiagnosticQueue) ?DiagnosticRequest {
        if (self.pending.items.len == 0) return null;
        return self.pending.orderedRemove(0);
    }

    fn deinit(self: *DiagnosticQueue, alloc: Allocator) void {
        for (self.pending.items) |request| alloc.free(request.message);
        self.pending.deinit(alloc);
        self.* = .{};
    }
};

/// Reload the configuration and apply it to either the complete application or
/// one surface. A hard reload finishes loading before any live state changes,
/// so a loading failure leaves the current configuration in place.
pub fn reloadConfig(
    self: *App,
    target: apprt.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    if (opts.soft) {
        try updateConfig(self, target, self.config);
        return;
    }

    var config = try Config.load(self.alloc);
    defer config.deinit();
    try updateConfig(self, target, &config);
    showConfigDiagnostics(self, target, &config);
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

/// Queue configuration diagnostics after startup or a reload. Opening a modal
/// dialog here would let its message loop close the Surface while the calling
/// key callback still needs it. Only drainDiagnostics may display the dialog.
/// Valid configuration entries are still applied before diagnostics are queued.
pub fn showConfigDiagnostics(
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

    self.pending_config_diagnostics.add(self.alloc, hwnd, message) catch |err| {
        log.warn("failed to queue configuration diagnostics: {}", .{err});
        return;
    };
    armDiagnosticsTimer(self);
}

// Like ShellOpen's drain timer, keep waking the outer loop even if a modal
// loop consumes the initial wakeup. This timer never opens a dialog itself.
const diagnostics_timer_id: usize = 0x3602;

fn armDiagnosticsTimer(self: *App) void {
    if (self.wakeup_hwnd) |hwnd| {
        if (win32.SetTimer(hwnd, diagnostics_timer_id, 50, null) != 0) return;
        log.warn("SetTimer for configuration diagnostics failed: err={d}", .{
            @intFromEnum(win32.GetLastError()),
        });
    }
    self.wakeup();
}

/// Called only by App.run, never by a window procedure or core callback.
/// Reloads inside a diagnostic dialog append requests without nesting dialogs.
pub fn drainDiagnostics(self: *App) void {
    if (self.pending_config_diagnostics.pending.items.len == 0) return;
    defer if (self.wakeup_hwnd) |hwnd| {
        _ = win32.KillTimer(hwnd, diagnostics_timer_id);
    };

    while (self.pending_config_diagnostics.pending.items.len > 0) {
        var msg: win32.MSG = undefined;
        if (!self.running or win32.PeekMessageW(
            &msg,
            null,
            win32.WM_QUIT,
            win32.WM_QUIT,
            .{},
        ) != 0) {
            discardDiagnostics(self);
            return;
        }

        const request = self.pending_config_diagnostics.take().?;
        defer self.alloc.free(request.message);
        // A shell or close request may have destroyed the owner while this
        // request waited. Never parent a dialog to another app or keep a dead
        // window's diagnostics open without an owner.
        if (self.windowForHwnd(request.parent) == null) continue;
        displayDiagnostic(request);
    }
}

pub fn discardDiagnostics(self: *App) void {
    if (self.wakeup_hwnd) |hwnd| {
        _ = win32.KillTimer(hwnd, diagnostics_timer_id);
    }
    self.pending_config_diagnostics.deinit(self.alloc);
}

fn displayDiagnostic(request: DiagnosticRequest) void {
    const caption = std.unicode.utf8ToUtf16LeStringLiteral(
        brand.display_name ++ " Configuration Error",
    );
    const style: win32.MESSAGEBOX_STYLE = .{ .ICONHAND = 1 };
    _ = win32.MessageBoxW(request.parent, request.message, caption, style);
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
        brand.display_name ++ " found errors in the configuration:\r\n\r\n",
    ) catch return error.OutOfMemory;
    for (diagnostics, 0..) |*diagnostic, i| {
        if (i > 0) buffer.writer.writeAll("\r\n") catch
            return error.OutOfMemory;
        diagnostic.format(&buffer.writer) catch return error.OutOfMemory;
    }

    return try buffer.toOwnedSliceSentinel(0);
}

pub fn openConfig(
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
            ShellOpen.shellOpen(self, path) catch |err| {
                log.warn("failed to open configuration: {}", .{err});
                return false;
            };
        },
        .new_window => {
            const command = configEditorCommand(self, path) catch |err| {
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

pub fn configChange(
    self: *App,
    target: apprt.Target,
    value: apprt.action.ConfigChange,
) !bool {
    switch (target) {
        .surface => |core| {
            const state = App.windowStateSurface(core.rt_surface);
            const decorated = value.config.@"window-decoration" != .none;
            if (!WindowState.setWindowDecorations(state, decorated)) {
                log.warn("failed to apply window-decoration setting", .{});
            }
            Titlebar.apply(state.windowHwnd(), value.config, self.high_contrast);
            WindowAppearance.updateWindowBackgroundBlur(state, value.config);
            try configureScrollbar(self, core.rt_surface, value.config);
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
}

pub fn configureScrollbar(self: *App, surface: *Surface, config: *const Config) !void {
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

test "Win32 diagnostic queue owns text and preserves request order" {
    const alloc = std.testing.allocator;
    var queue: DiagnosticQueue = .{};
    defer queue.deinit(alloc);
    const first_parent: win32.HWND = @ptrFromInt(1);
    const second_parent: win32.HWND = @ptrFromInt(2);
    var source = [_]u8{ 'b', 'a', 'd' };
    try queue.add(alloc, first_parent, &source);
    @memset(&source, 'x');
    try queue.add(alloc, second_parent, "設定エラー");

    const first = queue.take().?;
    defer alloc.free(first.message);
    try std.testing.expectEqual(first_parent, first.parent);
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'a', 'd' }, first.message);
    const second = queue.take().?;
    defer alloc.free(second.message);
    try std.testing.expectEqual(second_parent, second.parent);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("設定エラー"), second.message);
    try std.testing.expect(queue.take() == null);
}

test "Win32 diagnostic queue discards pending text and can be reused" {
    const alloc = std.testing.allocator;
    var queue: DiagnosticQueue = .{};
    defer queue.deinit(alloc);
    const parent: win32.HWND = @ptrFromInt(1);
    try queue.add(alloc, parent, "first");
    try queue.add(alloc, parent, "second");
    queue.deinit(alloc);
    try std.testing.expect(queue.take() == null);
    try queue.add(alloc, parent, "third");
    try std.testing.expectEqual(@as(usize, 1), queue.pending.items.len);
}

test "Win32 diagnostic queue leaves pending requests intact on invalid UTF-8" {
    const alloc = std.testing.allocator;
    var queue: DiagnosticQueue = .{};
    defer queue.deinit(alloc);
    const parent: win32.HWND = @ptrFromInt(1);
    try queue.add(alloc, parent, "valid");
    try std.testing.expectError(error.InvalidUtf8, queue.add(alloc, parent, "\xff"));
    try std.testing.expectEqual(@as(usize, 1), queue.pending.items.len);
}

test "Win32 diagnostic queue frees text when allocation fails" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing.allocator();
        var queue: DiagnosticQueue = .{};
        defer queue.deinit(alloc);
        if (queue.add(alloc, @ptrFromInt(1), "configuration error")) |_| {
            try std.testing.expect(!failing.has_induced_failure);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(queue.take() == null);
        }
    }
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
        brand.display_name ++ " found errors in the configuration:\r\n\r\n" ++
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
