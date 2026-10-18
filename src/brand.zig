//! Product identity of this fork, kept in one place.
//!
//! The Windows runtime, and later the build and distribution tooling, read
//! the product name from here instead of spelling it out, so that the rename
//! planned in docs/windows-rebranding-plan.md changes values in this file
//! only. Every value is still the original Ghostty name; changing them is a
//! later phase of that plan.
//!
//! Only names that identify the product belong here. Source and type names,
//! attribution, and upstream URLs keep the Ghostty name.

/// The product name as shown to people: window titles, dialog captions,
/// accessible names, and messages.
pub const display_name = "Ghostty";

/// The lowercase product identifier used in machine-readable names.
pub const identifier = "ghostty";

/// Prefix of environment variables the product reads.
pub const env_prefix = "GHOSTTY_";

/// Names used only by the Windows runtime.
pub const windows = struct {
    /// Prefix of the Win32 window class names (`<prefix>Window`, ...).
    pub const window_class_prefix = display_name;

    /// Named pipe of the single-instance IPC server, before the session,
    /// SID, and channel suffix.
    pub const ipc_pipe_prefix = "\\\\.\\pipe\\fukuyori." ++ identifier ++ ".win32-ipc";

    /// Signature at the start of every IPC message. Clients and servers of
    /// different builds compare it, so it changes only with a protocol
    /// decision, not with the product name.
    pub const ipc_magic = "GHTYIPC1";

    /// Runtime class name the Gaussian blur effect reports to Direct2D.
    pub const gaussian_effect_class = display_name ++ ".GaussianBlurEffect";

    /// AppUserModelID that toast notifications are sent under. It is
    /// registered per user when the first notification is shown; the process
    /// itself and its shortcuts keep the default identity, so taskbar
    /// grouping and pins are unchanged.
    pub const app_user_model_id = "fukuyori." ++ display_name;
};

test "brand values are unchanged until the rename" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings("Ghostty", display_name);
    try testing.expectEqualStrings("ghostty", identifier);
    try testing.expectEqualStrings("GHOSTTY_", env_prefix);
    try testing.expectEqualStrings("GhosttyWindow", windows.window_class_prefix ++ "Window");
    try testing.expectEqualStrings(
        "\\\\.\\pipe\\fukuyori.ghostty.win32-ipc",
        windows.ipc_pipe_prefix,
    );
    try testing.expectEqualStrings("GHTYIPC1", windows.ipc_magic);
    try testing.expectEqualStrings("Ghostty.GaussianBlurEffect", windows.gaussian_effect_class);
    try testing.expectEqualStrings("fukuyori.Ghostty", windows.app_user_model_id);
}
