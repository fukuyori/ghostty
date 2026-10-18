//! Windows toast notifications for desktop notifications (OSC 9 / OSC 777)
//! and command-finished notifications.
//!
//! Toasts are sent under the AppUserModelID in `brand.windows`, registered
//! per user under HKCU\Software\Classes\AppUserModelId when the first
//! notification is shown. The process and its shortcuts keep their default
//! identity, so taskbar grouping and pins do not change. A click is received
//! through the in-process Activated event while Ghostty runs; the event
//! arrives on a worker thread and is posted to the wakeup window, which
//! presents the originating surface on the UI thread. Notifications are
//! grouped by surface ID, removed when their surface closes, and cleared on
//! exit, since a click after exit cannot reach Ghostty.
const Notifications = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const brand = @import("../../brand.zig");
const configpkg = @import("../../config.zig");

const log = std.log.scoped(.win32);

/// Posted to the wakeup window with the activated surface ID in WPARAM.
pub const WM_NOTIFICATION_ACTIVATED = win32.WM_USER + 0x60;

const aumid = std.unicode.utf8ToUtf16LeStringLiteral(brand.windows.app_user_model_id);

state: enum { uninitialized, ready, unavailable } = .uninitialized,
ro_initialized: bool = false,
aumid_string: ?win32.HSTRING = null,
notifier: ?*IToastNotifier = null,
history: ?*IToastNotificationHistory = null,
factory: ?*IToastNotificationFactory = null,
/// Receives activation messages; the wakeup window.
target_hwnd: ?win32.HWND = null,
/// Surface groups this process has shown. Another Ghostty process can use
/// the same AppUserModelID, so exit removes only these, not the whole
/// history.
groups: std.ArrayListUnmanaged(u64) = .empty,
/// Last notifier setting reported as disabled, to log each change once.
reported_setting: ?i32 = null,

/// Activation handlers run on worker threads. Teardown closes this gate
/// before the wakeup window is destroyed, so a late click posts nothing.
var activation_gate: struct {
    lock: win32.RTL_SRWLOCK = .{ .Ptr = null },
    open: bool = true,
} = .{};

/// Show a toast for a surface. Failures are logged; a setup failure is
/// logged once and disables toasts for the rest of the session.
pub fn show(
    self: *Notifications,
    target_hwnd: ?win32.HWND,
    surface_id: u64,
    title: []const u8,
    body: []const u8,
) void {
    if (self.state == .uninitialized) {
        self.target_hwnd = target_hwnd;
        self.setup() catch |err| {
            log.warn("desktop notifications unavailable: {}", .{err});
            self.release();
            self.state = .unavailable;
            return;
        };
        self.state = .ready;
    }
    if (self.state != .ready) return;
    self.showToast(surface_id, title, body) catch |err| {
        log.warn("failed to show desktop notification: {}", .{err});
    };
}

/// Remove the notifications of a closed surface from Notification Center.
/// A group whose removal fails stays tracked so exit retries it.
pub fn removeSurface(self: *Notifications, surface_id: u64) void {
    const index = std.mem.indexOfScalar(u64, self.groups.items, surface_id) orelse return;
    if (self.removeGroup(surface_id)) _ = self.groups.swapRemove(index);
}

fn removeGroup(self: *Notifications, surface_id: u64) bool {
    const history = self.history orelse return false;
    var group_buf: [17]u16 = undefined;
    const group_string = createString(groupFor(&group_buf, surface_id)) catch return false;
    defer _ = win32.WindowsDeleteString(group_string);
    const result = history.vtable.RemoveGroupWithId(history, group_string, self.aumid_string);
    if (!win32.SUCCEEDED(result)) {
        log.warn("removing notifications of surface {x} failed: hresult=0x{x}", .{ surface_id, @as(u32, @bitCast(result)) });
        return false;
    }
    return true;
}

/// Final teardown. Toasts are not set up again afterwards, so the closed
/// activation gate stays closed for handlers of this process lifetime.
pub fn deinit(self: *Notifications) void {
    setGate(false);
    for (self.groups.items) |surface_id| _ = self.removeGroup(surface_id);
    self.groups.deinit(std.heap.page_allocator);
    self.groups = .empty;
    self.release();
    self.state = .unavailable;
}

fn setGate(open: bool) void {
    win32.AcquireSRWLockExclusive(&activation_gate.lock);
    defer win32.ReleaseSRWLockExclusive(&activation_gate.lock);
    activation_gate.open = open;
}

fn release(self: *Notifications) void {
    if (self.factory) |factory| _ = factory.IUnknown.Release();
    if (self.history) |history| _ = history.IUnknown.Release();
    if (self.notifier) |notifier| _ = notifier.IUnknown.Release();
    if (self.aumid_string) |value| _ = win32.WindowsDeleteString(value);
    self.factory = null;
    self.history = null;
    self.notifier = null;
    self.aumid_string = null;
    if (self.ro_initialized) {
        win32.RoUninitialize();
        self.ro_initialized = false;
    }
}

const Error = error{
    InitializeWinRT,
    RegisterAppUserModelId,
    CreateString,
    ActivationFactory,
    CreateNotifier,
    QueryInterface,
    History,
    ActivateXmlDocument,
    LoadXml,
    CreateNotification,
    SetGroup,
    AddActivated,
    Show,
    OutOfMemory,
};

fn setup(self: *Notifications) Error!void {
    const init_result = win32.RoInitialize(win32.RO_INIT_SINGLETHREADED);
    if (win32.SUCCEEDED(init_result)) {
        self.ro_initialized = true;
    } else if (init_result != rpc_e_changed_mode) {
        return failed(init_result, error.InitializeWinRT, "RoInitialize");
    }

    try registerAppUserModelId();
    self.aumid_string = try createString(aumid);

    const manager = try activationFactory(
        IToastNotificationManagerStatics,
        "Windows.UI.Notifications.ToastNotificationManager",
        &iid_toast_notification_manager_statics,
    );
    defer _ = manager.IUnknown.Release();
    var notifier: *IToastNotifier = undefined;
    try check(
        manager.vtable.CreateToastNotifierWithId(manager, self.aumid_string, &notifier),
        error.CreateNotifier,
        "CreateToastNotifierWithId",
    );
    self.notifier = notifier;

    const manager2 = try queryInterface(IToastNotificationManagerStatics2, &manager.IUnknown, &iid_toast_notification_manager_statics2);
    defer _ = manager2.IUnknown.Release();
    var history: *IToastNotificationHistory = undefined;
    try check(manager2.vtable.get_History(manager2, &history), error.History, "get_History");
    self.history = history;

    self.factory = try activationFactory(
        IToastNotificationFactory,
        "Windows.UI.Notifications.ToastNotification",
        &iid_toast_notification_factory,
    );
}

fn showToast(self: *Notifications, surface_id: u64, title: []const u8, body: []const u8) Error!void {
    const notifier = self.notifier.?;
    // Windows accepts toasts it will not show; report why instead.
    var setting: i32 = 0;
    if (win32.SUCCEEDED(notifier.vtable.get_Setting(notifier, &setting)) and setting != 0) {
        if (self.reported_setting != setting) {
            log.warn("desktop notification not shown: notifications are {s}", .{settingName(setting)});
            self.reported_setting = setting;
        }
        return;
    }
    self.reported_setting = null;

    var buffer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer buffer.deinit();
    toastXml(&buffer.writer, if (title.len == 0) brand.display_name else title, body) catch return error.OutOfMemory;
    const xml_wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, buffer.written()) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(xml_wide);

    const document = try activateInstance("Windows.Data.Xml.Dom.XmlDocument");
    defer _ = document.IUnknown.Release();
    const document_io = try queryInterface(IXmlDocumentIO, &document.IUnknown, &iid_xml_document_io);
    defer _ = document_io.IUnknown.Release();
    const xml_string = try createString(xml_wide);
    defer _ = win32.WindowsDeleteString(xml_string);
    try check(document_io.vtable.LoadXml(document_io, xml_string), error.LoadXml, "IXmlDocumentIO.LoadXml");
    const xml_document = try queryInterface(win32.IInspectable, &document.IUnknown, &iid_xml_document);
    defer _ = xml_document.IUnknown.Release();

    const factory = self.factory.?;
    var toast: *IToastNotification = undefined;
    try check(
        factory.vtable.CreateToastNotification(factory, xml_document, &toast),
        error.CreateNotification,
        "CreateToastNotification",
    );
    defer _ = toast.IUnknown.Release();

    var group_buf: [17]u16 = undefined;
    const group_string = try createString(groupFor(&group_buf, surface_id));
    defer _ = win32.WindowsDeleteString(group_string);
    const toast2 = try queryInterface(IToastNotification2, &toast.IUnknown, &iid_toast_notification2);
    defer _ = toast2.IUnknown.Release();
    try check(toast2.vtable.put_Group(toast2, group_string), error.SetGroup, "IToastNotification2.put_Group");

    const activated = try ToastHandler.create(.activated, self.target_hwnd, surface_id);
    defer _ = activated.release();
    var token: i64 = 0;
    try check(toast.vtable.add_Activated(toast, activated, &token), error.AddActivated, "add_Activated");
    const failed_handler = try ToastHandler.create(.failed, null, surface_id);
    defer _ = failed_handler.release();
    try check(toast.vtable.add_Failed(toast, failed_handler, &token), error.AddActivated, "add_Failed");

    if (std.mem.indexOfScalar(u64, self.groups.items, surface_id) == null) {
        self.groups.append(std.heap.page_allocator, surface_id) catch return error.OutOfMemory;
    }
    try check(notifier.vtable.Show(notifier, toast), error.Show, "IToastNotifier.Show");
}

fn settingName(setting: i32) []const u8 {
    return switch (setting) {
        1 => "turned off for this application",
        2 => "turned off for this user",
        3 => "turned off by group policy",
        4 => "turned off by the application manifest",
        else => "unavailable",
    };
}

/// Register the AppUserModelID for the current user. Without it an
/// unpackaged process cannot create a toast notifier. Rewritten on every
/// startup so the icon path follows a moved or upgraded installation.
fn registerAppUserModelId() Error!void {
    const key_path = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\AppUserModelId\\" ++ brand.windows.app_user_model_id);
    var key: ?win32.HKEY = null;
    const created = win32.RegCreateKeyExW(
        win32.HKEY_CURRENT_USER,
        key_path,
        0,
        null,
        @bitCast(@as(u32, 0)),
        @bitCast(@as(u32, 0x0002)), // KEY_SET_VALUE
        null,
        &key,
        null,
    );
    if (created != .NO_ERROR) {
        log.warn("RegCreateKeyExW(AppUserModelId) failed: err={d}", .{@intFromEnum(created)});
        return error.RegisterAppUserModelId;
    }
    defer _ = win32.RegCloseKey(key);

    try setString(key, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"), std.unicode.utf8ToUtf16LeStringLiteral(brand.display_name));
    var icon_buf: [win32.MAX_PATH * 2]u16 = undefined;
    if (iconPath(&icon_buf)) |icon| {
        try setString(key, std.unicode.utf8ToUtf16LeStringLiteral("IconUri"), icon);
    }
}

fn setString(key: ?win32.HKEY, name: [*:0]const u16, value: [:0]const u16) Error!void {
    const bytes: u32 = @intCast((value.len + 1) * @sizeOf(u16));
    const result = win32.RegSetValueExW(key, name, 0, win32.REG_SZ, @ptrCast(value.ptr), bytes);
    if (result != .NO_ERROR) {
        log.warn("RegSetValueExW(AppUserModelId) failed: err={d}", .{@intFromEnum(result)});
        return error.RegisterAppUserModelId;
    }
}

/// `<exe dir>\..\share\ghostty\ghostty.ico`, if it exists.
fn iconPath(buf: []u16) ?[:0]const u16 {
    const len = win32.GetModuleFileNameW(null, @ptrCast(buf.ptr), @intCast(buf.len));
    if (len == 0 or len >= buf.len) return null;
    var end: usize = len;
    // Drop "ghostty.exe" and "bin".
    for (0..2) |_| {
        end = std.mem.lastIndexOfScalar(u16, buf[0..end], '\\') orelse return null;
    }
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\share\\" ++ brand.identifier ++ "\\" ++ brand.identifier ++ ".ico");
    if (end + suffix.len + 1 > buf.len) return null;
    @memcpy(buf[end..][0..suffix.len], suffix);
    buf[end + suffix.len] = 0;
    const path: [:0]const u16 = buf[0 .. end + suffix.len :0];
    if (win32.GetFileAttributesW(path) == win32.INVALID_FILE_ATTRIBUTES) return null;
    return path;
}

/// The notification group of a surface: its ID as 16 hexadecimal digits,
/// within the 64-character group limit.
fn groupFor(buf: *[17]u16, surface_id: u64) [:0]const u16 {
    var ascii: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&ascii, "{x:0>16}", .{surface_id}) catch unreachable;
    for (ascii, 0..) |c, i| buf[i] = c;
    buf[16] = 0;
    return buf[0..16 :0];
}

/// Toast XML with escaped text. Control characters other than tab and
/// newlines are invalid in XML and are replaced with spaces.
pub fn toastXml(writer: *std.Io.Writer, title: []const u8, body: []const u8) !void {
    try writer.writeAll("<toast><visual><binding template=\"ToastGeneric\"><text>");
    try writeEscaped(writer, title);
    try writer.writeAll("</text><text>");
    try writeEscaped(writer, body);
    try writer.writeAll("</text></binding></visual></toast>");
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        '\t', '\n', '\r' => try writer.writeByte(c),
        0...8, 11, 12, 14...31, 127 => try writer.writeByte(' '),
        else => try writer.writeByte(c),
    };
}

/// Policy for `notify-on-command-finish`: whether a finished command
/// produces the configured bell or notification. The threshold is
/// inclusive, like macOS.
pub fn commandFinishedApplies(
    policy: configpkg.Config.NotifyOnCommandFinish,
    focused: bool,
    duration: configpkg.Config.Duration,
    after: configpkg.Config.Duration,
) bool {
    switch (policy) {
        .never => return false,
        .unfocused => if (focused) return false,
        .always => {},
    }
    return duration.duration >= after.duration;
}

pub fn commandFinishedTitle(exit_code: ?u8) []const u8 {
    const code = exit_code orelse return "Command Finished";
    return if (code == 0) "Command Succeeded" else "Command Failed";
}

pub fn commandFinishedBody(
    alloc: std.mem.Allocator,
    exit_code: ?u8,
    duration: configpkg.Config.Duration,
) ![]u8 {
    const rounded = duration.round(std.time.ns_per_ms);
    const code = exit_code orelse return std.fmt.allocPrint(alloc, "Command took {f}.", .{rounded});
    return std.fmt.allocPrint(alloc, "Command took {f} and exited with code {d}.", .{ rounded, code });
}

fn createString(value: [:0]const u16) Error!win32.HSTRING {
    var result: ?win32.HSTRING = null;
    try check(win32.WindowsCreateString(value, @intCast(value.len), &result), error.CreateString, "WindowsCreateString");
    return result.?;
}

fn activationFactory(comptime T: type, comptime class: []const u8, iid: *const win32.Guid) Error!*T {
    const name = try createString(std.unicode.utf8ToUtf16LeStringLiteral(class));
    defer _ = win32.WindowsDeleteString(name);
    var result: *anyopaque = undefined;
    try check(win32.RoGetActivationFactory(name, iid, &result), error.ActivationFactory, "RoGetActivationFactory(" ++ class ++ ")");
    return @ptrCast(@alignCast(result));
}

fn activateInstance(comptime class: []const u8) Error!*win32.IInspectable {
    const name = try createString(std.unicode.utf8ToUtf16LeStringLiteral(class));
    defer _ = win32.WindowsDeleteString(name);
    var result: *win32.IInspectable = undefined;
    try check(win32.RoActivateInstance(name, &result), error.ActivateXmlDocument, "RoActivateInstance(" ++ class ++ ")");
    return result;
}

fn queryInterface(comptime T: type, source: *win32.IUnknown, iid: *const win32.Guid) Error!*T {
    var result: *anyopaque = undefined;
    try check(source.QueryInterface(iid, &result), error.QueryInterface, "QueryInterface(" ++ @typeName(T) ++ ")");
    return @ptrCast(@alignCast(result));
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    return failed(result, err, operation);
}

fn failed(result: win32.HRESULT, err: Error, operation: []const u8) Error {
    log.warn("{s} failed: hresult=0x{x}", .{ operation, @as(u32, @bitCast(result)) });
    return err;
}

/// COM object implementing the toast's Activated
/// (TypedEventHandler<ToastNotification, Object>) or Failed
/// (TypedEventHandler<ToastNotification, ToastFailedEventArgs>) delegate.
/// Windows invokes it on a worker thread and may release it from any
/// thread, so it is reference counted atomically. Activation only posts the
/// surface ID, under the shutdown gate; failure only logs.
const ToastHandler = extern struct {
    vtable: *const VTable,
    refs: u32,
    kind: Kind,
    target_hwnd: ?win32.HWND,
    surface_id: u64,

    const Kind = enum(u32) { activated, failed };

    const VTable = extern struct {
        QueryInterface: *const fn (*ToastHandler, *const win32.Guid, *?*anyopaque) callconv(.winapi) win32.HRESULT,
        AddRef: *const fn (*ToastHandler) callconv(.winapi) u32,
        Release: *const fn (*ToastHandler) callconv(.winapi) u32,
        Invoke: *const fn (*ToastHandler, ?*anyopaque, ?*win32.IUnknown) callconv(.winapi) win32.HRESULT,
    };

    const vtable_value: VTable = .{
        .QueryInterface = queryInterfaceImpl,
        .AddRef = addRef,
        .Release = releaseImpl,
        .Invoke = invoke,
    };

    fn create(kind: Kind, target_hwnd: ?win32.HWND, surface_id: u64) Error!*ToastHandler {
        const self = std.heap.page_allocator.create(ToastHandler) catch return error.OutOfMemory;
        self.* = .{ .vtable = &vtable_value, .refs = 1, .kind = kind, .target_hwnd = target_hwnd, .surface_id = surface_id };
        return self;
    }

    fn release(self: *ToastHandler) u32 {
        return releaseImpl(self);
    }

    fn delegateIid(self: *const ToastHandler) *const win32.Guid {
        return switch (self.kind) {
            .activated => &iid_typed_event_handler_toast_activated,
            .failed => &iid_typed_event_handler_toast_failed,
        };
    }

    fn queryInterfaceImpl(self: *ToastHandler, iid: *const win32.Guid, out: *?*anyopaque) callconv(.winapi) win32.HRESULT {
        if (guidEql(iid, self.delegateIid()) or
            guidEql(iid, win32.IID_IUnknown) or
            guidEql(iid, &iid_agile_object))
        {
            _ = addRef(self);
            out.* = self;
            return win32.S_OK;
        }
        out.* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(self: *ToastHandler) callconv(.winapi) u32 {
        return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
    }

    fn releaseImpl(self: *ToastHandler) callconv(.winapi) u32 {
        const remaining = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) - 1;
        if (remaining == 0) std.heap.page_allocator.destroy(self);
        return remaining;
    }

    fn invoke(self: *ToastHandler, _: ?*anyopaque, args: ?*win32.IUnknown) callconv(.winapi) win32.HRESULT {
        switch (self.kind) {
            .activated => {
                win32.AcquireSRWLockExclusive(&activation_gate.lock);
                defer win32.ReleaseSRWLockExclusive(&activation_gate.lock);
                if (!activation_gate.open) return win32.S_OK;
                if (self.target_hwnd) |hwnd| {
                    _ = win32.PostMessageW(hwnd, WM_NOTIFICATION_ACTIVATED, @intCast(self.surface_id), 0);
                }
            },
            .failed => {
                var code: win32.HRESULT = 0;
                if (args) |unknown| {
                    var result: *anyopaque = undefined;
                    if (win32.SUCCEEDED(unknown.QueryInterface(&iid_toast_failed_event_args, &result))) {
                        const failed_args: *IToastFailedEventArgs = @ptrCast(@alignCast(result));
                        defer _ = failed_args.IUnknown.Release();
                        _ = failed_args.vtable.get_ErrorCode(failed_args, &code);
                    }
                }
                log.warn("desktop notification failed: hresult=0x{x}", .{@as(u32, @bitCast(code))});
            },
        }
        return win32.S_OK;
    }
};

fn guidEql(a: *const win32.Guid, b: *const win32.Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// Interface layouts and IIDs were read from the Windows.UI.Notifications and
// Windows.Data.Xml.Dom metadata; methods follow the IInspectable entries.

const IToastNotificationManagerStatics = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        CreateToastNotifier: *const anyopaque,
        CreateToastNotifierWithId: *const fn (*const IToastNotificationManagerStatics, ?win32.HSTRING, **IToastNotifier) callconv(.winapi) win32.HRESULT,
        GetTemplateContent: *const anyopaque,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IToastNotificationManagerStatics2 = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        get_History: *const fn (*const IToastNotificationManagerStatics2, **IToastNotificationHistory) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IToastNotificationHistory = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        RemoveGroup: *const anyopaque,
        RemoveGroupWithId: *const fn (*const IToastNotificationHistory, ?win32.HSTRING, ?win32.HSTRING) callconv(.winapi) win32.HRESULT,
        RemoveGroupedTagWithId: *const anyopaque,
        RemoveGroupedTag: *const anyopaque,
        Remove: *const anyopaque,
        Clear: *const anyopaque,
        ClearWithId: *const fn (*const IToastNotificationHistory, ?win32.HSTRING) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IToastFailedEventArgs = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        get_ErrorCode: *const fn (*const IToastFailedEventArgs, *win32.HRESULT) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IToastNotifier = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        Show: *const fn (*const IToastNotifier, *IToastNotification) callconv(.winapi) win32.HRESULT,
        Hide: *const anyopaque,
        get_Setting: *const fn (*const IToastNotifier, *i32) callconv(.winapi) win32.HRESULT,
        AddToSchedule: *const anyopaque,
        RemoveFromSchedule: *const anyopaque,
        GetScheduledToastNotifications: *const anyopaque,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IToastNotificationFactory = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        CreateToastNotification: *const fn (*const IToastNotificationFactory, *win32.IInspectable, **IToastNotification) callconv(.winapi) win32.HRESULT,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IToastNotification = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        get_Content: *const anyopaque,
        put_ExpirationTime: *const anyopaque,
        get_ExpirationTime: *const anyopaque,
        add_Dismissed: *const anyopaque,
        remove_Dismissed: *const anyopaque,
        add_Activated: *const fn (*const IToastNotification, *ToastHandler, *i64) callconv(.winapi) win32.HRESULT,
        remove_Activated: *const anyopaque,
        add_Failed: *const fn (*const IToastNotification, *ToastHandler, *i64) callconv(.winapi) win32.HRESULT,
        remove_Failed: *const anyopaque,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IToastNotification2 = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        put_Tag: *const anyopaque,
        get_Tag: *const anyopaque,
        put_Group: *const fn (*const IToastNotification2, ?win32.HSTRING) callconv(.winapi) win32.HRESULT,
        get_Group: *const anyopaque,
        put_SuppressPopup: *const anyopaque,
        get_SuppressPopup: *const anyopaque,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const IXmlDocumentIO = extern union {
    const VTable = extern struct {
        base: win32.IInspectable.VTable,
        LoadXml: *const fn (*const IXmlDocumentIO, ?win32.HSTRING) callconv(.winapi) win32.HRESULT,
        LoadXmlWithSettings: *const anyopaque,
        SaveToFileAsync: *const anyopaque,
    };
    vtable: *const VTable,
    IUnknown: win32.IUnknown,
};

const iid_toast_notification_manager_statics = win32.Guid.initString("50AC103F-D235-4598-BBEF-98FE4D1A3AD4");
const iid_toast_notification_manager_statics2 = win32.Guid.initString("7AB93C52-0E48-4750-BA9D-1A4113981847");
const iid_toast_notification_factory = win32.Guid.initString("04124B20-82C6-4229-B109-FD9ED4662B53");
const iid_toast_notification2 = win32.Guid.initString("9DFB9FD1-143A-490E-90BF-B9FBA7132DE7");
const iid_xml_document_io = win32.Guid.initString("6CD0E74E-EE65-4489-9EBF-CA43E87BA637");
const iid_xml_document = win32.Guid.initString("F7F3A506-1E87-42D6-BCFB-B8C809FA5494");
const iid_typed_event_handler_toast_activated = win32.Guid.initString("AB54DE2D-97D9-5528-B6AD-105AFE156530");
const iid_typed_event_handler_toast_failed = win32.Guid.initString("95E3E803-C969-5E3A-9753-EA2AD22A9A33");
const iid_toast_failed_event_args = win32.Guid.initString("35176862-CFD4-44F8-AD64-F500FD896C3B");
const iid_agile_object = win32.Guid.initString("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90");
const rpc_e_changed_mode: win32.HRESULT = @bitCast(@as(u32, 0x80010106));

test "Win32 toast XML escapes text" {
    const testing = std.testing;
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try toastXml(&buffer.writer, "a<b>&\"c'", "line 1\nline\x07 2 日本語");
    try testing.expectEqualStrings(
        "<toast><visual><binding template=\"ToastGeneric\"><text>a&lt;b&gt;&amp;&quot;c&apos;</text>" ++
            "<text>line 1\nline  2 日本語</text></binding></visual></toast>",
        buffer.written(),
    );
}

test "Win32 command-finished notification policy" {
    const testing = std.testing;
    const five: configpkg.Config.Duration = .{ .duration = 5 * std.time.ns_per_s };
    const four: configpkg.Config.Duration = .{ .duration = 4 * std.time.ns_per_s };
    try testing.expect(!commandFinishedApplies(.never, false, five, five));
    try testing.expect(!commandFinishedApplies(.unfocused, true, five, five));
    try testing.expect(commandFinishedApplies(.unfocused, false, five, five));
    try testing.expect(commandFinishedApplies(.always, true, five, five));
    // The threshold is inclusive (macOS); shorter commands are ignored.
    try testing.expect(!commandFinishedApplies(.always, false, four, five));
}

test "Win32 command-finished notification text" {
    const testing = std.testing;
    try testing.expectEqualStrings("Command Succeeded", commandFinishedTitle(0));
    try testing.expectEqualStrings("Command Failed", commandFinishedTitle(7));
    try testing.expectEqualStrings("Command Finished", commandFinishedTitle(null));
    const duration: configpkg.Config.Duration = .{ .duration = 65 * std.time.ns_per_s + 123_456_789 };
    const body = try commandFinishedBody(testing.allocator, 7, duration);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("Command took 1m 5s 123ms and exited with code 7.", body);
}

test "Win32 notification group is the hexadecimal surface ID" {
    var buf: [17]u16 = undefined;
    const group = groupFor(&buf, 0x1234);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("0000000000001234"), group);
}
