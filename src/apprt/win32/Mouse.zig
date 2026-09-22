const win32 = @import("win32").everything;
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");

/// Shared system cursors follow the user's pointer theme and size. Shapes
/// without a Windows equivalent use the nearest available system cursor.
pub fn cursor(shape: terminal.MouseShape) ?win32.HCURSOR {
    return win32.LoadCursorW(null, switch (shape) {
        .default, .context_menu, .alias, .copy, .zoom_in, .zoom_out => win32.IDC_ARROW,
        .help => win32.IDC_HELP,
        .pointer, .grab, .grabbing => win32.IDC_HAND,
        .progress => win32.IDC_APPSTARTING,
        .wait => win32.IDC_WAIT,
        .cell, .crosshair => win32.IDC_CROSS,
        .text, .vertical_text => win32.IDC_IBEAM,
        .move, .all_scroll => win32.IDC_SIZEALL,
        .no_drop, .not_allowed => win32.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => win32.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => win32.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => win32.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => win32.IDC_SIZENWSE,
    });
}

pub fn apply(surface: *Surface) void {
    _ = win32.SetCursor(if (surface.mouse_visible) cursor(surface.mouse_shape) else null);
}

/// Refresh only while the pointer belongs to this pane. Never alter the
/// process-wide ShowCursor counter or hide the cursor over native controls.
pub fn refresh(surface: *Surface) void {
    var point: win32.POINT = undefined;
    if (win32.GetCursorPos(&point) == 0 or win32.WindowFromPoint(point) != surface.hwnd) return;
    _ = win32.SendMessageW(surface.hwnd, win32.WM_SETCURSOR, @intFromPtr(surface.hwnd), win32.HTCLIENT);
}
