//! Host-side data layouts consumed by the D3D11 terminal shaders.

const std = @import("std");
const win32 = @import("win32").everything;
const math = @import("../../math.zig");
const Pipeline = @import("Pipeline.zig");

const source = @embedFile("shaders/terminal.hlsl");

/// Global values shared by all terminal shader stages. The explicit
/// alignments mirror HLSL constant-buffer packing.
pub const Uniforms = extern struct {
    projection_matrix: math.Mat align(16),
    screen_size: [2]f32 align(8),
    cell_size: [2]f32 align(8),
    grid_size: [2]u16 align(4),
    grid_padding: [4]f32 align(16),
    padding_extend: PaddingExtend align(4),
    min_contrast: f32 align(4),
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),
    bg_color: [4]u8 align(4),
    bools: Bools align(4),

    pub const Bools = packed struct(u32) {
        cursor_wide: bool = false,
        use_display_p3: bool = false,
        use_linear_blending: bool = false,
        use_linear_correction: bool = false,
        _padding: u28 = 0,
    };

    pub const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// Per-instance parameters for terminal glyph rendering.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1) = .grayscale,
    bools: Bools align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    pub const Bools = packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    };
};

/// One packed RGBA color consumed by the cell-background shader.
pub const CellBg = [4]u8;

/// Per-instance parameters for terminal image rendering.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Per-instance parameters for background-image rendering.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

pub const PipelineCollection = struct {
    bg_color: Pipeline,
    cell_bg: Pipeline,
    cell_text: Pipeline,
    image: Pipeline,
    bg_image: Pipeline,
};

/// Pipelines used by the generic terminal renderer.
pub const Shaders = struct {
    pipelines: PipelineCollection,
    defunct: bool = false,

    pub fn init(device: *win32.ID3D11Device) Pipeline.Error!Shaders {
        const bg_color = try Pipeline.init(null, .{
            .device = device,
            .vertex_source = source,
            .pixel_source = source,
            .vertex_entrypoint = "full_screen_vertex",
            .pixel_entrypoint = "bg_color_pixel",
            .blending = false,
        });
        errdefer bg_color.deinit();

        const cell_bg = try Pipeline.init(null, .{
            .device = device,
            .vertex_source = source,
            .pixel_source = source,
            .vertex_entrypoint = "full_screen_vertex",
            .pixel_entrypoint = "cell_bg_pixel",
        });
        errdefer cell_bg.deinit();

        const cell_text = try Pipeline.init(CellText, .{
            .device = device,
            .vertex_source = source,
            .pixel_source = source,
            .vertex_entrypoint = "cell_text_vertex",
            .pixel_entrypoint = "cell_text_pixel",
            .step_fn = .per_instance,
            .topology = win32.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
        });
        errdefer cell_text.deinit();

        const image = try Pipeline.init(Image, .{
            .device = device,
            .vertex_source = source,
            .pixel_source = source,
            .vertex_entrypoint = "image_vertex",
            .pixel_entrypoint = "image_pixel",
            .step_fn = .per_instance,
            .topology = win32.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
        });
        errdefer image.deinit();

        const bg_image = try Pipeline.init(BgImage, .{
            .device = device,
            .vertex_source = source,
            .pixel_source = source,
            .vertex_entrypoint = "bg_image_vertex",
            .pixel_entrypoint = "bg_image_pixel",
            .step_fn = .per_instance,
        });
        errdefer bg_image.deinit();

        return .{ .pipelines = .{
            .bg_color = bg_color,
            .cell_bg = cell_bg,
            .cell_text = cell_text,
            .image = image,
            .bg_image = bg_image,
        } };
    }

    pub fn deinit(self: *Shaders) void {
        if (self.defunct) return;
        self.pipelines.bg_image.deinit();
        self.pipelines.image.deinit();
        self.pipelines.cell_text.deinit();
        self.pipelines.cell_bg.deinit();
        self.pipelines.bg_color.deinit();
        self.defunct = true;
    }
};

test "D3D11 shader data layouts remain tightly packed" {
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(Uniforms));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(Uniforms, "grid_padding"));
    try std.testing.expectEqual(@as(usize, 132), @offsetOf(Uniforms, "bools"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CellText));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(CellBg));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Image));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(BgImage));
}

test "D3D11 terminal shader contains every production entrypoint" {
    inline for (.{
        "full_screen_vertex",
        "bg_color_pixel",
        "cell_bg_pixel",
        "cell_text_vertex",
        "cell_text_pixel",
        "image_vertex",
        "image_pixel",
        "bg_image_vertex",
        "bg_image_pixel",
    }) |entrypoint| {
        try std.testing.expect(std.mem.indexOf(u8, source, entrypoint) != null);
    }
}
