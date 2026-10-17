//! Action dispatch for the Win32 runtime: the body of `App.performAction`.
//! Each action is forwarded to the module that owns it.

const win32 = @import("win32").everything;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const CommandPalette = @import("CommandPalette.zig");
const ConfigActions = @import("ConfigActions.zig");
const Mouse = @import("Mouse.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Recovery = @import("Recovery.zig");
const SearchBar = @import("SearchBar.zig");
const ShellOpen = @import("ShellOpen.zig");
const TabTitles = @import("TabTitles.zig");
const WindowCommands = @import("WindowCommands.zig");
const WindowLifecycle = @import("WindowLifecycle.zig");
const WindowState = @import("WindowState.zig");

pub fn perform(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    // The quick terminal's geometry and frame come from its settings.
    switch (action) {
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .float_window,
        .initial_size,
        .reset_window_size,
        .resize_window,
        => if (quickTarget(self, target)) return false,
        else => {},
    }

    switch (action) {
        .quit => return WindowLifecycle.queueCloseAll(self, true),
        .quit_timer => {
            // With a working global keybinding the application keeps running
            // without windows unless configured to quit, so the binding can
            // still summon the quick terminal.
            const stay = !self.config.@"quit-after-last-window-closed" and
                self.global_hotkeys.count() > 0;
            if (value == .start and !stay) win32.PostQuitMessage(0);
            return true;
        },
        .toggle_quick_terminal => return try QuickTerminal.toggle(self),
        .set_title => return try TabTitles.setTitle(target, value),
        .set_tab_title => return try TabTitles.setTabTitle(self, target, value),
        .start_search => return try SearchBar.startSearch(self, target, value),
        .end_search => return SearchBar.endSearch(self, target),
        .search_total, .search_selected => return SearchBar.updateResults(target, action, value),
        .scrollbar => {
            const surface = App.targetSurface(target) orelse return false;
            if (surface.scrollbar) |bar| bar.update(value);
            return true;
        },
        .mouse_shape => return Mouse.setShape(target, value),
        .mouse_visibility => return Mouse.setVisibility(target, value),
        .prompt_title => return try TabTitles.promptTitle(self, target, value),
        .toggle_command_palette => return CommandPalette.requestShow(target),
        .new_window => {
            try WindowLifecycle.createWindow(self, .{});
            return true;
        },
        .new_tab => return try WindowLifecycle.newTab(self, target),
        .close_tab => return WindowLifecycle.closeTab(self, target, value),
        .goto_tab => return WindowCommands.gotoTab(self, target, value),
        .move_tab => return WindowCommands.moveTab(self, target, value),
        .new_split => return try WindowLifecycle.newSplit(self, target, value),
        .goto_split => return WindowCommands.gotoSplit(self, target, value),
        .resize_split => return WindowCommands.resizeSplit(self, target, value),
        .equalize_splits => return WindowCommands.equalizeSplits(self, target),
        .toggle_split_zoom => return WindowCommands.toggleSplitZoom(self, target),
        .close_window => return WindowLifecycle.closeWindow(self, target),
        .close_all_windows => return WindowLifecycle.closeAllWindows(self),
        .goto_window => return WindowCommands.gotoWindow(self, target, value),
        .present_terminal => return WindowState.presentTerminal(target),
        .toggle_visibility => return WindowState.toggleVisibility(self),
        .toggle_maximize => return WindowState.toggleMaximize(target),
        .toggle_fullscreen => return WindowState.toggleFullscreen(target, value),
        .toggle_window_decorations => return WindowState.toggleWindowDecorations(target),
        .float_window => return WindowState.floatWindow(target, value),
        .initial_size => return WindowState.setInitialSize(target, value),
        .reset_window_size => return WindowState.resetWindowSize(target),
        .resize_window => return WindowState.resizeWindow(target, value),
        .open_url => return ShellOpen.openUrl(self, target, value),
        .open_config => return try ConfigActions.openConfig(self, target, value),
        .reload_config => {
            try ConfigActions.reloadConfig(self, target, value);
            return true;
        },
        .renderer_health => return try Recovery.recoverRenderer(target, value),
        .progress_report => {
            const surface = App.targetSurface(target) orelse return false;
            return self.setTaskbarProgress(surface, value);
        },
        .config_change => return try ConfigActions.configChange(self, target, value),
        else => return false,
    }
}

fn quickTarget(self: *App, target: apprt.Target) bool {
    const surface = App.targetSurface(target) orelse return false;
    const window = self.windowForSurface(surface) orelse return false;
    return window.quick;
}
