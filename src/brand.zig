//! Product identity of this fork, kept in one place.
//!
//! The Windows runtime, the build, and the PowerShell distribution tooling
//! (through `brand.json`) read the product name from here instead of
//! spelling it out, so that the rename
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

/// File name of the executable, without the platform extension. It must
/// equal `identifier`: the installed shell integration and completions
/// (src/build/brand_rewrite.zig) use one name for both.
pub const exe_name = identifier;

comptime {
    if (!@import("std").mem.eql(u8, exe_name, identifier)) {
        @compileError("brand.exe_name must equal brand.identifier");
    }
}

/// Directory under `share/` that holds the installed resources.
pub const resources_dir_name = identifier;

/// Directory, under the platform configuration root, that holds the
/// configuration, and the name of the configuration file in it.
pub const config_dir_name = identifier;
pub const config_file_name = "config." ++ identifier;

/// The terminfo entry name and the `TERM` value the terminal sets.
pub const terminfo_name = "xterm-" ++ identifier;

/// The `TERM_PROGRAM` value the terminal sets.
pub const term_program = identifier;

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

    /// Inno Setup AppId of the installer. A new product gets a new AppId,
    /// so that it installs beside the old one instead of upgrading it.
    pub const installer_app_id = "{6F0C5B4E-2B6D-4E4A-9C2E-3A1D5F7B8C90}";
};

/// The values above as the build writes them to `brand.json` in the install
/// prefix, for the PowerShell release, installer and test scripts. Bump
/// `schema` when a field is removed or changes meaning.
pub const Manifest = struct {
    schema: u32,
    display_name: []const u8,
    identifier: []const u8,
    env_prefix: []const u8,
    exe_name: []const u8,
    resources_dir_name: []const u8,
    config_dir_name: []const u8,
    config_file_name: []const u8,
    terminfo_name: []const u8,
    term_program: []const u8,
    window_class_prefix: []const u8,
    ipc_pipe_prefix: []const u8,
    app_user_model_id: []const u8,
    installer_app_id: []const u8,
};

pub const manifest: Manifest = .{
    .schema = 1,
    .display_name = display_name,
    .identifier = identifier,
    .env_prefix = env_prefix,
    .exe_name = exe_name,
    .resources_dir_name = resources_dir_name,
    .config_dir_name = config_dir_name,
    .config_file_name = config_file_name,
    .terminfo_name = terminfo_name,
    .term_program = term_program,
    .window_class_prefix = windows.window_class_prefix,
    .ipc_pipe_prefix = windows.ipc_pipe_prefix,
    .app_user_model_id = windows.app_user_model_id,
    .installer_app_id = windows.installer_app_id,
};

test {
    _ = @import("config/config_template.zig");
}

test "brand values are unchanged until the rename" {
    const testing = @import("std").testing;
    try testing.expectEqualStrings("Ghostty", display_name);
    try testing.expectEqualStrings("ghostty", identifier);
    try testing.expectEqualStrings("GHOSTTY_", env_prefix);
    try testing.expectEqualStrings("ghostty", exe_name);
    try testing.expectEqualStrings("ghostty", resources_dir_name);
    try testing.expectEqualStrings("ghostty", config_dir_name);
    try testing.expectEqualStrings("config.ghostty", config_file_name);
    try testing.expectEqualStrings("xterm-ghostty", terminfo_name);
    try testing.expectEqualStrings("ghostty", term_program);
    try testing.expectEqualStrings(
        "{6F0C5B4E-2B6D-4E4A-9C2E-3A1D5F7B8C90}",
        windows.installer_app_id,
    );
    try testing.expectEqualStrings("GhosttyWindow", windows.window_class_prefix ++ "Window");
    try testing.expectEqualStrings(
        "\\\\.\\pipe\\fukuyori.ghostty.win32-ipc",
        windows.ipc_pipe_prefix,
    );
    try testing.expectEqualStrings("GHTYIPC1", windows.ipc_magic);
    try testing.expectEqualStrings("Ghostty.GaussianBlurEffect", windows.gaussian_effect_class);
    try testing.expectEqualStrings("fukuyori.Ghostty", windows.app_user_model_id);
}
