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
const WindowState = @import("WindowState.zig");

const log = std.log.scoped(.win32);

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

/// Show configuration diagnostics after startup or a reload. Diagnostics do
/// not prevent valid configuration entries from being applied, matching the
/// behavior of the other application runtimes.
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

    const message_wide = std.unicode.utf8ToUtf16LeAllocZ(
        self.alloc,
        message,
    ) catch |err| {
        log.warn("failed to convert configuration diagnostics: {}", .{err});
        return;
    };
    defer self.alloc.free(message_wide);

    const caption = std.unicode.utf8ToUtf16LeStringLiteral(
        brand.display_name ++ " Configuration Error",
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
            App.updateWindowBackgroundBlur(state, value.config);
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
