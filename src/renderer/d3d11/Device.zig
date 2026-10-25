//! The app-scoped render device for Direct3D 11.
//!
//! Each surface still creates its own D3D11 device and DirectComposition
//! presenter (see `D3D11.init`). This type only satisfies the app-scoped
//! `renderer.Device` interface and holds no state.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Options used when creating the device. There are none.
pub const Options = struct {};

pub fn init(alloc: Allocator, options: Options) !*Device {
    _ = options;
    return try alloc.create(Device);
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    alloc.destroy(self);
}
