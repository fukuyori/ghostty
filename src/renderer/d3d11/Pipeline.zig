//! D3D11 shader and fixed-function pipeline state.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Shader = @import("Shader.zig");

const log = std.log.scoped(.d3d11_pipeline);

pub const Options = struct {
    device: *win32.ID3D11Device,
    vertex_source: []const u8,
    pixel_source: []const u8,
    vertex_entrypoint: [:0]const u8 = "main",
    pixel_entrypoint: [:0]const u8 = "main",
    step_fn: StepFunction = .per_vertex,
    blending: bool = true,
    topology: win32.D3D_PRIMITIVE_TOPOLOGY =
        win32.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST,

    pub const StepFunction = enum {
        per_vertex,
        per_instance,
    };
};

pub const Error = Shader.Error || error{
    CreateVertexShader,
    CreatePixelShader,
    CreateInputLayout,
    CreateBlendState,
};

vertex_shader: *win32.ID3D11VertexShader,
pixel_shader: *win32.ID3D11PixelShader,
input_layout: ?*win32.ID3D11InputLayout,
blend_state: *win32.ID3D11BlendState,
topology: win32.D3D_PRIMITIVE_TOPOLOGY,
stride: u32,

pub fn init(comptime VertexAttributes: ?type, opts: Options) Error!Self {
    const vertex_code = try Shader.compile(
        opts.vertex_source,
        opts.vertex_entrypoint,
        .vertex,
    );
    defer vertex_code.deinit();
    const pixel_code = try Shader.compile(
        opts.pixel_source,
        opts.pixel_entrypoint,
        .pixel,
    );
    defer pixel_code.deinit();

    const vertex_bytes = vertex_code.bytes();
    var vertex_shader: *win32.ID3D11VertexShader = undefined;
    try check(
        opts.device.CreateVertexShader(
            vertex_bytes.ptr,
            vertex_bytes.len,
            null,
            &vertex_shader,
        ),
        error.CreateVertexShader,
        "ID3D11Device.CreateVertexShader",
    );
    errdefer _ = vertex_shader.IUnknown.Release();

    var input_layout: ?*win32.ID3D11InputLayout = null;
    if (VertexAttributes) |Attributes| {
        const elements = inputElements(Attributes, opts.step_fn);
        var layout: *win32.ID3D11InputLayout = undefined;
        try check(
            opts.device.CreateInputLayout(
                &elements,
                elements.len,
                vertex_bytes.ptr,
                vertex_bytes.len,
                &layout,
            ),
            error.CreateInputLayout,
            "ID3D11Device.CreateInputLayout",
        );
        input_layout = layout;
    }
    errdefer {
        if (input_layout) |layout| _ = layout.IUnknown.Release();
    }

    const pixel_bytes = pixel_code.bytes();
    var pixel_shader: *win32.ID3D11PixelShader = undefined;
    try check(
        opts.device.CreatePixelShader(
            pixel_bytes.ptr,
            pixel_bytes.len,
            null,
            &pixel_shader,
        ),
        error.CreatePixelShader,
        "ID3D11Device.CreatePixelShader",
    );
    errdefer _ = pixel_shader.IUnknown.Release();

    const blend_desc = blendDescription(opts.blending);
    var blend_state: *win32.ID3D11BlendState = undefined;
    try check(
        opts.device.CreateBlendState(&blend_desc, &blend_state),
        error.CreateBlendState,
        "ID3D11Device.CreateBlendState",
    );

    return .{
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .input_layout = input_layout,
        .blend_state = blend_state,
        .topology = opts.topology,
        .stride = if (VertexAttributes) |Attributes| @sizeOf(Attributes) else 0,
    };
}

pub fn deinit(self: Self) void {
    _ = self.blend_state.IUnknown.Release();
    if (self.input_layout) |layout| _ = layout.IUnknown.Release();
    _ = self.pixel_shader.IUnknown.Release();
    _ = self.vertex_shader.IUnknown.Release();
}

pub fn bind(self: *const Self, context: *win32.ID3D11DeviceContext) void {
    context.IASetInputLayout(self.input_layout);
    context.IASetPrimitiveTopology(self.topology);
    context.VSSetShader(self.vertex_shader, null, 0);
    context.PSSetShader(self.pixel_shader, null, 0);

    const blend_factor = [_]f32{ 0, 0, 0, 0 };
    context.OMSetBlendState(self.blend_state, &blend_factor[0], std.math.maxInt(u32));
}

fn inputElements(
    comptime T: type,
    step_fn: Options.StepFunction,
) [@typeInfo(T).@"struct".fields.len]win32.D3D11_INPUT_ELEMENT_DESC {
    const fields = @typeInfo(T).@"struct".fields;
    var result: [fields.len]win32.D3D11_INPUT_ELEMENT_DESC = undefined;

    const input_class, const step_rate: u32 = switch (step_fn) {
        .per_vertex => .{ win32.D3D11_INPUT_PER_VERTEX_DATA, 0 },
        .per_instance => .{ win32.D3D11_INPUT_PER_INSTANCE_DATA, 1 },
    };

    inline for (fields, 0..) |field, i| {
        result[i] = .{
            .SemanticName = "ATTR",
            .SemanticIndex = i,
            .Format = inputFormat(field.type),
            .InputSlot = 0,
            .AlignedByteOffset = @offsetOf(T, field.name),
            .InputSlotClass = input_class,
            .InstanceDataStepRate = step_rate,
        };
    }
    return result;
}

fn inputFormat(comptime T: type) win32.DXGI_FORMAT {
    const FieldType = switch (@typeInfo(T)) {
        .@"struct" => |info| info.backing_integer orelse
            @compileError("D3D11 vertex structs must have an integer backing type"),
        .@"enum" => |info| info.tag_type,
        else => T,
    };
    const count, const Scalar = switch (@typeInfo(FieldType)) {
        .array => |info| .{ info.len, info.child },
        else => .{ 1, FieldType },
    };

    return switch (Scalar) {
        u8 => switch (count) {
            1 => win32.DXGI_FORMAT_R8_UINT,
            2 => win32.DXGI_FORMAT_R8G8_UINT,
            4 => win32.DXGI_FORMAT_R8G8B8A8_UINT,
            else => unsupportedFormat(T),
        },
        i8 => switch (count) {
            1 => win32.DXGI_FORMAT_R8_SINT,
            2 => win32.DXGI_FORMAT_R8G8_SINT,
            4 => win32.DXGI_FORMAT_R8G8B8A8_SINT,
            else => unsupportedFormat(T),
        },
        u16 => switch (count) {
            1 => win32.DXGI_FORMAT_R16_UINT,
            2 => win32.DXGI_FORMAT_R16G16_UINT,
            4 => win32.DXGI_FORMAT_R16G16B16A16_UINT,
            else => unsupportedFormat(T),
        },
        i16 => switch (count) {
            1 => win32.DXGI_FORMAT_R16_SINT,
            2 => win32.DXGI_FORMAT_R16G16_SINT,
            4 => win32.DXGI_FORMAT_R16G16B16A16_SINT,
            else => unsupportedFormat(T),
        },
        u32 => switch (count) {
            1 => win32.DXGI_FORMAT_R32_UINT,
            2 => win32.DXGI_FORMAT_R32G32_UINT,
            3 => win32.DXGI_FORMAT_R32G32B32_UINT,
            4 => win32.DXGI_FORMAT_R32G32B32A32_UINT,
            else => unsupportedFormat(T),
        },
        i32 => switch (count) {
            1 => win32.DXGI_FORMAT_R32_SINT,
            2 => win32.DXGI_FORMAT_R32G32_SINT,
            3 => win32.DXGI_FORMAT_R32G32B32_SINT,
            4 => win32.DXGI_FORMAT_R32G32B32A32_SINT,
            else => unsupportedFormat(T),
        },
        f16 => switch (count) {
            1 => win32.DXGI_FORMAT_R16_FLOAT,
            2 => win32.DXGI_FORMAT_R16G16_FLOAT,
            4 => win32.DXGI_FORMAT_R16G16B16A16_FLOAT,
            else => unsupportedFormat(T),
        },
        f32 => switch (count) {
            1 => win32.DXGI_FORMAT_R32_FLOAT,
            2 => win32.DXGI_FORMAT_R32G32_FLOAT,
            3 => win32.DXGI_FORMAT_R32G32B32_FLOAT,
            4 => win32.DXGI_FORMAT_R32G32B32A32_FLOAT,
            else => unsupportedFormat(T),
        },
        else => unsupportedFormat(T),
    };
}

fn unsupportedFormat(comptime T: type) noreturn {
    @compileError("unsupported D3D11 vertex field type: " ++ @typeName(T));
}

fn blendDescription(enabled: bool) win32.D3D11_BLEND_DESC {
    var desc = std.mem.zeroes(win32.D3D11_BLEND_DESC);
    desc.RenderTarget[0] = .{
        .BlendEnable = @intFromBool(enabled),
        .SrcBlend = win32.D3D11_BLEND_ONE,
        .DestBlend = win32.D3D11_BLEND_INV_SRC_ALPHA,
        .BlendOp = win32.D3D11_BLEND_OP_ADD,
        .SrcBlendAlpha = win32.D3D11_BLEND_ONE,
        .DestBlendAlpha = win32.D3D11_BLEND_INV_SRC_ALPHA,
        .BlendOpAlpha = win32.D3D11_BLEND_OP_ADD,
        .RenderTargetWriteMask = @intFromEnum(win32.D3D11_COLOR_WRITE_ENABLE_ALL),
    };
    return desc;
}

fn check(result: win32.HRESULT, err: Error, operation: []const u8) Error!void {
    if (win32.SUCCEEDED(result)) return;
    log.err("{s} failed: hresult=0x{x}", .{
        operation,
        @as(u32, @bitCast(result)),
    });
    return err;
}

test "D3D11 pipeline uses premultiplied alpha blending" {
    const desc = blendDescription(true);
    const target = desc.RenderTarget[0];
    try std.testing.expect(target.BlendEnable != 0);
    try std.testing.expectEqual(win32.D3D11_BLEND_ONE, target.SrcBlend);
    try std.testing.expectEqual(win32.D3D11_BLEND_INV_SRC_ALPHA, target.DestBlend);
    try std.testing.expectEqual(win32.D3D11_BLEND_ONE, target.SrcBlendAlpha);
    try std.testing.expectEqual(win32.D3D11_BLEND_INV_SRC_ALPHA, target.DestBlendAlpha);
}

test "D3D11 pipeline maps terminal cell input per instance" {
    const shaders = @import("shaders.zig");
    const elements = inputElements(shaders.CellText, .per_instance);

    try std.testing.expectEqual(@as(usize, 7), elements.len);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R32G32_UINT, elements[0].Format);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R16G16_SINT, elements[2].Format);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R16G16_UINT, elements[3].Format);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R8G8B8A8_UINT, elements[4].Format);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R8_UINT, elements[5].Format);
    try std.testing.expectEqual(@as(u32, 29), elements[6].AlignedByteOffset);
    try std.testing.expectEqual(
        win32.D3D11_INPUT_PER_INSTANCE_DATA,
        elements[6].InputSlotClass,
    );
    try std.testing.expectEqual(@as(u32, 1), elements[6].InstanceDataStepRate);

    const image_elements = inputElements(shaders.Image, .per_instance);
    try std.testing.expectEqual(@as(usize, 4), image_elements.len);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R32G32_FLOAT, image_elements[0].Format);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R32G32B32A32_FLOAT, image_elements[2].Format);
    try std.testing.expectEqual(@as(u32, 32), image_elements[3].AlignedByteOffset);

    const bg_image_elements = inputElements(shaders.BgImage, .per_instance);
    try std.testing.expectEqual(@as(usize, 2), bg_image_elements.len);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R32_FLOAT, bg_image_elements[0].Format);
    try std.testing.expectEqual(win32.DXGI_FORMAT_R8_UINT, bg_image_elements[1].Format);
    try std.testing.expectEqual(@as(u32, 4), bg_image_elements[1].AlignedByteOffset);
}
