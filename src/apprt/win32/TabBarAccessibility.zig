//! Microsoft Active Accessibility provider for the custom Win32 tab bar.
//!
//! The tab bar is custom-drawn so the standard HWND proxy cannot discover its
//! individual tabs. This provider exposes them as simple MSAA child elements
//! while keeping the existing drawing and pointer behavior unchanged.

const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");

pub const select_message = win32.WM_USER + 3;

interface: win32.IAccessible = .{ .vtable = &vtable },
references: std.atomic.Value(u32) = .init(1),
standard: *win32.IAccessible,
hwnd: win32.HWND,
window: ?*Window,

pub fn create(hwnd: win32.HWND, window: *Window) !*Self {
    var raw: ?*anyopaque = null;
    const result = win32.CreateStdAccessibleObject(
        hwnd,
        objid_client,
        win32.IID_IAccessible,
        &raw,
    );
    if (win32.FAILED(result) or raw == null) return error.Unavailable;

    const self = std.heap.page_allocator.create(Self) catch {
        const standard: *win32.IAccessible = @ptrCast(@alignCast(raw.?));
        _ = standard.IUnknown.Release();
        return error.OutOfMemory;
    };
    self.* = .{
        .standard = @ptrCast(@alignCast(raw.?)),
        .hwnd = hwnd,
        .window = window,
    };
    return self;
}

pub fn detach(self: *Self) void {
    self.window = null;
    _ = self.release();
}

pub fn objectResult(self: *Self, wparam: win32.WPARAM) win32.LRESULT {
    return win32.LresultFromObject(
        win32.IID_IAccessible,
        wparam,
        &self.interface.IUnknown,
    );
}

fn addRef(self: *Self) u32 {
    return self.references.fetchAdd(1, .monotonic) + 1;
}

fn release(self: *Self) u32 {
    const previous = self.references.fetchSub(1, .acq_rel);
    std.debug.assert(previous > 0);
    if (previous != 1) return previous - 1;

    _ = self.standard.IUnknown.Release();
    std.heap.page_allocator.destroy(self);
    return 0;
}

fn currentWindow(self: *const Self) ?*Window {
    const expected = self.window orelse return null;
    if (win32.IsWindow(self.hwnd) == 0) return null;
    const stored = win32.GetWindowLongPtrW(self.hwnd, win32.GWLP_USERDATA);
    if (stored == 0 or @as(usize, @bitCast(stored)) != @intFromPtr(expected)) return null;
    return expected;
}

fn childIndex(self: *const Self, value: win32.VARIANT) ?usize {
    const window = self.currentWindow() orelse return null;
    if (value.Anonymous.Anonymous.vt != win32.VT_I4) return null;
    const child = value.Anonymous.Anonymous.Anonymous.lVal;
    if (child <= 0) return null;
    const index: usize = @intCast(child - 1);
    return if (index < window.tabCount()) index else null;
}

fn isSelf(value: win32.VARIANT) bool {
    return value.Anonymous.Anonymous.vt == win32.VT_I4 and
        value.Anonymous.Anonymous.Anonymous.lVal == childid_self;
}

fn setVariantEmpty(output: ?*win32.VARIANT) win32.HRESULT {
    const result = output orelse return win32.E_INVALIDARG;
    result.* = std.mem.zeroes(win32.VARIANT);
    result.Anonymous.Anonymous.vt = win32.VT_EMPTY;
    return win32.S_OK;
}

fn setVariantI4(output: ?*win32.VARIANT, value: i32) win32.HRESULT {
    const result = output orelse return win32.E_INVALIDARG;
    result.* = std.mem.zeroes(win32.VARIANT);
    result.Anonymous.Anonymous.vt = win32.VT_I4;
    result.Anonymous.Anonymous.Anonymous.lVal = value;
    return win32.S_OK;
}

fn setBstr(output: ?*?win32.BSTR, value: []const u8) win32.HRESULT {
    const result = output orelse return win32.E_INVALIDARG;
    result.* = null;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(
        std.heap.page_allocator,
        value,
    ) catch return win32.E_OUTOFMEMORY;
    defer std.heap.page_allocator.free(wide);
    result.* = win32.SysAllocString(wide.ptr) orelse return win32.E_OUTOFMEMORY;
    return win32.S_OK;
}

fn interfaceSelf(value: anytype) *Self {
    const accessible: *const win32.IAccessible = @ptrCast(value);
    return @constCast(@fieldParentPtr("interface", accessible));
}

fn guidEqual(a: *const win32.Guid, b: *const win32.Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn queryInterface(
    value: *const win32.IUnknown,
    iid: *const win32.Guid,
    output: **anyopaque,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    const result: *?*anyopaque = @ptrCast(output);
    result.* = if (guidEqual(iid, win32.IID_IUnknown) or
        guidEqual(iid, win32.IID_IDispatch) or
        guidEqual(iid, win32.IID_IAccessible))
        @ptrCast(&self.interface)
    else
        null;
    if (result.* == null) return win32.E_NOINTERFACE;
    _ = self.addRef();
    return win32.S_OK;
}

fn unknownAddRef(value: *const win32.IUnknown) callconv(.winapi) u32 {
    return interfaceSelf(value).addRef();
}

fn unknownRelease(value: *const win32.IUnknown) callconv(.winapi) u32 {
    return interfaceSelf(value).release();
}

fn getTypeInfoCount(
    value: *const win32.IDispatch,
    count: ?*u32,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.IDispatch.GetTypeInfoCount(count);
}

fn getTypeInfo(
    value: *const win32.IDispatch,
    index: u32,
    locale: u32,
    info: ?*?*win32.ITypeInfo,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.IDispatch.GetTypeInfo(index, locale, info);
}

fn getIdsOfNames(
    value: *const win32.IDispatch,
    iid: ?*const win32.Guid,
    names: [*]?win32.PWSTR,
    name_count: u32,
    locale: u32,
    ids: [*]i32,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.IDispatch.GetIDsOfNames(
        iid,
        names,
        name_count,
        locale,
        ids,
    );
}

fn invoke(
    value: *const win32.IDispatch,
    member: i32,
    _: ?*const win32.Guid,
    locale: u32,
    flags: u16,
    params: ?*win32.DISPPARAMS,
    result: ?*win32.VARIANT,
    exception: ?*win32.EXCEPINFO,
    argument_error: ?*u32,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    var type_info: ?*win32.ITypeInfo = null;
    const result_code = self.standard.IDispatch.GetTypeInfo(0, locale, &type_info);
    if (win32.FAILED(result_code) or type_info == null) return result_code;
    defer _ = type_info.?.IUnknown.Release();
    return type_info.?.vtable.Invoke(
        type_info.?,
        @ptrCast(&self.interface),
        member,
        flags,
        params,
        result,
        exception,
        argument_error,
    );
}

fn getAccParent(
    value: *const win32.IAccessible,
    parent: ?*?*win32.IDispatch,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.get_accParent(parent);
}

fn getAccChildCount(
    value: *const win32.IAccessible,
    count: ?*i32,
) callconv(.winapi) win32.HRESULT {
    const result = count orelse return win32.E_INVALIDARG;
    const window = interfaceSelf(value).currentWindow() orelse return win32.E_FAIL;
    result.* = @intCast(window.tabCount());
    return win32.S_OK;
}

fn getAccChild(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    dispatch: ?*?*win32.IDispatch,
) callconv(.winapi) win32.HRESULT {
    const result = dispatch orelse return win32.E_INVALIDARG;
    result.* = null;
    if (interfaceSelf(value).childIndex(child) == null) return win32.E_INVALIDARG;
    return win32.S_FALSE;
}

fn getAccName(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    name: ?*?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    if (isSelf(child)) return self.standard.get_accName(child, name);
    const window = self.currentWindow() orelse return win32.E_FAIL;
    const index = self.childIndex(child) orelse return win32.E_INVALIDARG;
    return setBstr(name, window.tabTitleAt(index) orelse "Ghostty");
}

fn getAccValue(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    result: ?*?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.get_accValue(child, result);
}

fn getAccDescription(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    description: ?*?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    if (isSelf(child)) return setBstr(description, "Ghostty tab bar");
    const window = self.currentWindow() orelse return win32.E_FAIL;
    const index = self.childIndex(child) orelse return win32.E_INVALIDARG;
    const text = std.fmt.allocPrint(
        std.heap.page_allocator,
        "Tab {d} of {d}",
        .{ index + 1, window.tabCount() },
    ) catch return win32.E_OUTOFMEMORY;
    defer std.heap.page_allocator.free(text);
    return setBstr(description, text);
}

fn getAccRole(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    role: ?*win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    if (isSelf(child)) return setVariantI4(role, @intCast(win32.ROLE_SYSTEM_PAGETABLIST));
    if (self.childIndex(child) == null) return win32.E_INVALIDARG;
    return setVariantI4(role, @intCast(win32.ROLE_SYSTEM_PAGETAB));
}

fn getAccState(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    state: ?*win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    if (isSelf(child)) return self.standard.get_accState(child, state);
    const window = self.currentWindow() orelse return win32.E_FAIL;
    const index = self.childIndex(child) orelse return win32.E_INVALIDARG;
    var flags: u32 = win32.STATE_SYSTEM_SELECTABLE;
    if (index == window.activeTabIndex()) flags |= win32.STATE_SYSTEM_SELECTED;
    if (tabRect(self, window, index) == null) {
        flags |= @intFromEnum(win32.STATE_SYSTEM_INVISIBLE);
        flags |= @intFromEnum(win32.STATE_SYSTEM_OFFSCREEN);
    }
    return setVariantI4(state, @bitCast(flags));
}

fn getAccHelp(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    help: ?*?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.get_accHelp(child, help);
}

fn getAccHelpTopic(
    value: *const win32.IAccessible,
    help_file: ?*?win32.BSTR,
    child: win32.VARIANT,
    topic: ?*i32,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.get_accHelpTopic(help_file, child, topic);
}

fn getAccKeyboardShortcut(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    shortcut: ?*?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).standard.get_accKeyboardShortcut(child, shortcut);
}

fn getAccFocus(
    _: *const win32.IAccessible,
    child: ?*win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    return setVariantEmpty(child);
}

fn getAccSelection(
    value: *const win32.IAccessible,
    child: ?*win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    const window = interfaceSelf(value).currentWindow() orelse return win32.E_FAIL;
    return setVariantI4(child, @intCast(window.activeTabIndex() + 1));
}

fn getAccDefaultAction(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
    action: ?*?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    if (interfaceSelf(value).childIndex(child) == null) return win32.E_INVALIDARG;
    return setBstr(action, "Switch");
}

fn selectChild(self: *Self, child: win32.VARIANT) win32.HRESULT {
    const index = self.childIndex(child) orelse return win32.E_INVALIDARG;
    return if (win32.PostMessageW(
        self.hwnd,
        select_message,
        index + 1,
        0,
    ) != 0) win32.S_OK else win32.E_FAIL;
}

fn accSelect(
    value: *const win32.IAccessible,
    flags: i32,
    child: win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    if ((@as(u32, @bitCast(flags)) & win32.SELFLAG_TAKESELECTION) == 0) {
        return win32.E_INVALIDARG;
    }
    return interfaceSelf(value).selectChild(child);
}

fn tabRect(self: *const Self, window: *const Window, index: usize) ?win32.RECT {
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(self.hwnd, &client) == 0) return null;
    return TabBar.tabRect(
        client.right - client.left,
        client.bottom - client.top,
        window.tabCount(),
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        index,
    );
}

fn accLocation(
    value: *const win32.IAccessible,
    left: ?*i32,
    top: ?*i32,
    width: ?*i32,
    height: ?*i32,
    child: win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    const out_left = left orelse return win32.E_INVALIDARG;
    const out_top = top orelse return win32.E_INVALIDARG;
    const out_width = width orelse return win32.E_INVALIDARG;
    const out_height = height orelse return win32.E_INVALIDARG;
    const self = interfaceSelf(value);
    const window = self.currentWindow() orelse return win32.E_FAIL;
    var rect: win32.RECT = if (isSelf(child)) raw: {
        var result: win32.RECT = std.mem.zeroes(win32.RECT);
        if (win32.GetWindowRect(self.hwnd, &result) == 0) return win32.E_FAIL;
        break :raw result;
    } else self.tabRect(window, self.childIndex(child) orelse return win32.E_INVALIDARG) orelse
        std.mem.zeroes(win32.RECT);
    if (!isSelf(child)) {
        var top_left: win32.POINT = .{ .x = rect.left, .y = rect.top };
        var bottom_right: win32.POINT = .{ .x = rect.right, .y = rect.bottom };
        if (win32.ClientToScreen(self.hwnd, &top_left) == 0 or
            win32.ClientToScreen(self.hwnd, &bottom_right) == 0) return win32.E_FAIL;
        rect = .{
            .left = top_left.x,
            .top = top_left.y,
            .right = bottom_right.x,
            .bottom = bottom_right.y,
        };
    }
    out_left.* = rect.left;
    out_top.* = rect.top;
    out_width.* = @max(0, rect.right - rect.left);
    out_height.* = @max(0, rect.bottom - rect.top);
    return win32.S_OK;
}

fn accNavigate(
    value: *const win32.IAccessible,
    direction: i32,
    start: win32.VARIANT,
    destination: ?*win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    const window = self.currentWindow() orelse return win32.E_FAIL;
    const count = window.tabCount();
    if (count == 0) return win32.S_FALSE;

    const target: ?usize = if (isSelf(start)) switch (@as(u32, @bitCast(direction))) {
        win32.NAVDIR_FIRSTCHILD => 0,
        win32.NAVDIR_LASTCHILD => count - 1,
        else => null,
    } else if (self.childIndex(start)) |index| switch (@as(u32, @bitCast(direction))) {
        win32.NAVDIR_NEXT => if (index + 1 < count) index + 1 else null,
        win32.NAVDIR_PREVIOUS => if (index > 0) index - 1 else null,
        else => null,
    } else null;
    if (target) |index| return setVariantI4(destination, @intCast(index + 1));
    _ = setVariantEmpty(destination);
    return win32.S_FALSE;
}

fn accHitTest(
    value: *const win32.IAccessible,
    screen_x: i32,
    screen_y: i32,
    child: ?*win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    const self = interfaceSelf(value);
    const window = self.currentWindow() orelse return win32.E_FAIL;
    var point: win32.POINT = .{ .x = screen_x, .y = screen_y };
    if (win32.ScreenToClient(self.hwnd, &point) == 0) return win32.E_FAIL;
    var client: win32.RECT = std.mem.zeroes(win32.RECT);
    if (win32.GetClientRect(self.hwnd, &client) == 0) return win32.E_FAIL;
    const index = TabBar.tabAt(
        client.right - client.left,
        client.bottom - client.top,
        window.tabCount(),
        window.activeTabIsZoomed(),
        window.tab_bar_first_visible,
        point.x,
        point.y,
    );
    return setVariantI4(child, if (index) |result|
        @intCast(result + 1)
    else
        childid_self);
}

fn accDoDefaultAction(
    value: *const win32.IAccessible,
    child: win32.VARIANT,
) callconv(.winapi) win32.HRESULT {
    return interfaceSelf(value).selectChild(child);
}

fn putAccName(
    _: *const win32.IAccessible,
    _: win32.VARIANT,
    _: ?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    return win32.E_NOTIMPL;
}

fn putAccValue(
    _: *const win32.IAccessible,
    _: win32.VARIANT,
    _: ?win32.BSTR,
) callconv(.winapi) win32.HRESULT {
    return win32.E_NOTIMPL;
}

const vtable: win32.IAccessible.VTable = .{
    .base = .{
        .base = .{
            .QueryInterface = queryInterface,
            .AddRef = unknownAddRef,
            .Release = unknownRelease,
        },
        .GetTypeInfoCount = getTypeInfoCount,
        .GetTypeInfo = getTypeInfo,
        .GetIDsOfNames = getIdsOfNames,
        .Invoke = invoke,
    },
    .get_accParent = getAccParent,
    .get_accChildCount = getAccChildCount,
    .get_accChild = getAccChild,
    .get_accName = getAccName,
    .get_accValue = getAccValue,
    .get_accDescription = getAccDescription,
    .get_accRole = getAccRole,
    .get_accState = getAccState,
    .get_accHelp = getAccHelp,
    .get_accHelpTopic = getAccHelpTopic,
    .get_accKeyboardShortcut = getAccKeyboardShortcut,
    .get_accFocus = getAccFocus,
    .get_accSelection = getAccSelection,
    .get_accDefaultAction = getAccDefaultAction,
    .accSelect = accSelect,
    .accLocation = accLocation,
    .accNavigate = accNavigate,
    .accHitTest = accHitTest,
    .accDoDefaultAction = accDoDefaultAction,
    .put_accName = putAccName,
    .put_accValue = putAccValue,
};

const objid_client: i32 = -4;
const childid_self: i32 = 0;
