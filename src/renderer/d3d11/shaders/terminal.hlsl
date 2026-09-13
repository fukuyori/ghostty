cbuffer Globals : register(b1) {
    column_major float4x4 projection_matrix;
    float2 global_screen_size;
    float2 cell_size;
    uint grid_size_packed_2u16;
    float4 grid_padding;
    uint padding_extend;
    float min_contrast;
    uint cursor_pos_packed_2u16;
    uint cursor_color_packed_4u8;
    uint bg_color_packed_4u8;
    uint global_bools;
};

static const uint CURSOR_WIDE = 1u;
static const uint USE_LINEAR_BLENDING = 4u;
static const uint USE_LINEAR_CORRECTION = 8u;
static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

uint4 unpack4u8(uint value) {
    return uint4(
        (value >> 0) & 0xffu,
        (value >> 8) & 0xffu,
        (value >> 16) & 0xffu,
        (value >> 24) & 0xffu
    );
}

uint2 unpack2u16(uint value) {
    return uint2(value & 0xffffu, (value >> 16) & 0xffffu);
}

float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float contrastRatio(float3 first, float3 second) {
    float first_luminance = luminance(first) + 0.05;
    float second_luminance = luminance(second) + 0.05;
    return max(first_luminance, second_luminance) /
        min(first_luminance, second_luminance);
}

float4 contrastedColor(float minimum, float4 foreground, float4 background) {
    if (contrastRatio(foreground.rgb, background.rgb) < minimum) {
        float white_ratio = contrastRatio(1.0.xxx, background.rgb);
        float black_ratio = contrastRatio(0.0.xxx, background.rgb);
        return white_ratio > black_ratio ? 1.0.xxxx : float4(0.0, 0.0, 0.0, 1.0);
    }
    return foreground;
}

float linearizeChannel(float value) {
    return value <= 0.04045
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4);
}

float4 linearizeColor(float4 color) {
    return float4(
        linearizeChannel(color.r),
        linearizeChannel(color.g),
        linearizeChannel(color.b),
        color.a
    );
}

float unlinearizeChannel(float value) {
    return value <= 0.0031308
        ? value * 12.92
        : pow(value, 1.0 / 2.4) * 1.055 - 0.055;
}

float4 unlinearizeColor(float4 color) {
    return float4(
        unlinearizeChannel(color.r),
        unlinearizeChannel(color.g),
        unlinearizeChannel(color.b),
        color.a
    );
}

float4 loadColor(uint4 input_color, bool linear_blending) {
    float4 color = float4(input_color) / 255.0;
    if (linear_blending) color = linearizeColor(color);
    color.rgb *= color.a;
    return color;
}

struct FullScreenOutput {
    float4 position : SV_POSITION;
};

FullScreenOutput full_screen_vertex(uint vertex_id : SV_VertexID) {
    FullScreenOutput output;
    output.position = float4(
        vertex_id == 2 ? 3.0 : -1.0,
        vertex_id == 0 ? -3.0 : 1.0,
        1.0,
        1.0
    );
    return output;
}

float4 bg_color_pixel(FullScreenOutput input) : SV_TARGET {
    bool linear_blending = (global_bools & USE_LINEAR_BLENDING) != 0;
    return loadColor(unpack4u8(bg_color_packed_4u8), linear_blending);
}

StructuredBuffer<uint> cell_bg_cells : register(t0);

float4 cell_bg_pixel(FullScreenOutput input) : SV_TARGET {
    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    int2 grid_pos = int2(floor(
        (input.position.xy - float2(grid_padding.w, grid_padding.x)) / cell_size
    ));

    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) grid_pos.x = 0;
        else return 0.0.xxxx;
    } else if (grid_pos.x >= int(grid_size.x)) {
        if ((padding_extend & EXTEND_RIGHT) != 0) grid_pos.x = int(grid_size.x) - 1;
        else return 0.0.xxxx;
    }

    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) grid_pos.y = 0;
        else return 0.0.xxxx;
    } else if (grid_pos.y >= int(grid_size.y)) {
        if ((padding_extend & EXTEND_DOWN) != 0) grid_pos.y = int(grid_size.y) - 1;
        else return 0.0.xxxx;
    }

    bool linear_blending = (global_bools & USE_LINEAR_BLENDING) != 0;
    uint index = uint(grid_pos.y) * grid_size.x + uint(grid_pos.x);
    return loadColor(unpack4u8(cell_bg_cells[index]), linear_blending);
}

struct CellTextInput {
    uint2 glyph_pos : ATTR0;
    uint2 glyph_size : ATTR1;
    int2 bearings : ATTR2;
    uint2 grid_pos : ATTR3;
    uint4 color : ATTR4;
    uint atlas : ATTR5;
    uint glyph_bools : ATTR6;
};

struct CellTextOutput {
    float4 position : SV_POSITION;
    nointerpolation uint atlas : TEXCOORD0;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 bg_color : COLOR1;
    float2 tex_coord : TEXCOORD1;
};

StructuredBuffer<uint> cell_text_bg_cells : register(t0);

CellTextOutput cell_text_vertex(CellTextInput input, uint vertex_id : SV_VertexID) {
    static const uint NO_MIN_CONTRAST = 1u;
    static const uint IS_CURSOR_GLYPH = 2u;

    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (global_bools & CURSOR_WIDE) != 0;
    bool linear_blending = (global_bools & USE_LINEAR_BLENDING) != 0;

    float2 corner = float2(
        vertex_id == 1 || vertex_id == 3,
        vertex_id == 2 || vertex_id == 3
    );
    float2 size = float2(input.glyph_size);
    float2 offset = float2(input.bearings);
    offset.y = cell_size.y - offset.y;
    float2 position = cell_size * float2(input.grid_pos) + size * corner + offset;

    CellTextOutput output;
    output.position = mul(projection_matrix, float4(position, 0.0, 1.0));
    output.atlas = input.atlas;
    output.tex_coord = float2(input.glyph_pos) + size * corner;
    output.color = loadColor(input.color, true);

    uint bg_index = input.grid_pos.y * grid_size.x + input.grid_pos.x;
    output.bg_color = loadColor(unpack4u8(cell_text_bg_cells[bg_index]), true);
    float4 global_bg = loadColor(unpack4u8(bg_color_packed_4u8), true);
    output.bg_color += global_bg * (1.0 - output.bg_color.a);

    if (min_contrast > 1.0 && (input.glyph_bools & NO_MIN_CONTRAST) == 0) {
        output.color = contrastedColor(min_contrast, output.color, output.bg_color);
    }

    bool cursor_column = input.grid_pos.x == cursor_pos.x ||
        (cursor_wide && input.grid_pos.x == cursor_pos.x + 1);
    bool cursor_cell = cursor_column && input.grid_pos.y == cursor_pos.y;
    if ((input.glyph_bools & IS_CURSOR_GLYPH) == 0 && cursor_cell) {
        output.color = loadColor(
            unpack4u8(cursor_color_packed_4u8),
            linear_blending
        );
    }
    return output;
}

Texture2D<float4> atlas_grayscale : register(t0);
Texture2D<float4> atlas_color : register(t1);
SamplerState atlas_sampler : register(s0);

float4 cell_text_pixel(CellTextOutput input) : SV_TARGET {
    static const uint ATLAS_COLOR = 1u;
    bool linear_blending = (global_bools & USE_LINEAR_BLENDING) != 0;

    uint width;
    uint height;
    if (input.atlas == ATLAS_COLOR) {
        atlas_color.GetDimensions(width, height);
        float4 color = atlas_color.Sample(
            atlas_sampler,
            input.tex_coord / float2(width, height)
        );
        if (!linear_blending && color.a > 0.0) {
            color.rgb /= color.a;
            color = unlinearizeColor(color);
            color.rgb *= color.a;
        }
        return color;
    }

    atlas_grayscale.GetDimensions(width, height);
    float4 color = input.color;
    if (!linear_blending && color.a > 0.0) {
        color.rgb /= color.a;
        color = unlinearizeColor(color);
        color.rgb *= color.a;
    }

    float alpha = atlas_grayscale.Sample(
        atlas_sampler,
        input.tex_coord / float2(width, height)
    ).r;
    if ((global_bools & USE_LINEAR_CORRECTION) != 0) {
        float foreground_luminance = luminance(color.rgb);
        float background_luminance = luminance(input.bg_color.rgb);
        if (abs(foreground_luminance - background_luminance) > 0.001) {
            float blended_luminance = linearizeChannel(
                unlinearizeChannel(foreground_luminance) * alpha +
                unlinearizeChannel(background_luminance) * (1.0 - alpha)
            );
            alpha = saturate(
                (blended_luminance - background_luminance) /
                (foreground_luminance - background_luminance)
            );
        }
    }
    return color * alpha;
}

struct ImageInput {
    float2 grid_pos : ATTR0;
    float2 cell_offset : ATTR1;
    float4 source_rect : ATTR2;
    float2 dest_size : ATTR3;
};

struct ImageOutput {
    float4 position : SV_POSITION;
    float2 tex_coord : TEXCOORD0;
};

ImageOutput image_vertex(ImageInput input, uint vertex_id : SV_VertexID) {
    float2 corner = float2(
        vertex_id == 1 || vertex_id == 3,
        vertex_id == 2 || vertex_id == 3
    );
    float2 image_position = cell_size * input.grid_pos + input.cell_offset;
    image_position += input.dest_size * corner;

    ImageOutput output;
    output.position = mul(projection_matrix, float4(image_position, 1.0, 1.0));
    output.tex_coord = input.source_rect.xy + input.source_rect.zw * corner;
    return output;
}

Texture2D<float4> image_texture : register(t0);
SamplerState image_sampler : register(s0);

float4 image_pixel(ImageOutput input) : SV_TARGET {
    uint width;
    uint height;
    image_texture.GetDimensions(width, height);
    float4 color = image_texture.Sample(
        image_sampler,
        input.tex_coord / float2(width, height)
    );
    if ((global_bools & USE_LINEAR_BLENDING) == 0) {
        color = unlinearizeColor(color);
    }
    color.rgb *= color.a;
    return color;
}

struct BgImageInput {
    float opacity : ATTR0;
    uint info : ATTR1;
};

struct BgImageOutput {
    float4 position : SV_POSITION;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset : TEXCOORD0;
    nointerpolation float2 scale : TEXCOORD1;
    nointerpolation float opacity : TEXCOORD2;
    nointerpolation uint repeat_image : TEXCOORD3;
};

Texture2D<float4> bg_image_texture : register(t0);
SamplerState bg_image_sampler : register(s0);

BgImageOutput bg_image_vertex(BgImageInput input, uint vertex_id : SV_VertexID) {
    static const uint POSITION_MASK = 15u;
    static const uint FIT_MASK = 3u << 4;
    static const uint FIT_CONTAIN = 0u << 4;
    static const uint FIT_COVER = 1u << 4;
    static const uint FIT_STRETCH = 2u << 4;
    static const uint REPEAT_IMAGE = 1u << 6;

    uint texture_width;
    uint texture_height;
    bg_image_texture.GetDimensions(texture_width, texture_height);
    float2 texture_size = float2(texture_width, texture_height);
    float2 destination_size = texture_size;

    switch (input.info & FIT_MASK) {
        case FIT_CONTAIN: {
            float factor = min(
                global_screen_size.x / texture_size.x,
                global_screen_size.y / texture_size.y
            );
            destination_size = texture_size * factor;
            break;
        }
        case FIT_COVER: {
            float factor = max(
                global_screen_size.x / texture_size.x,
                global_screen_size.y / texture_size.y
            );
            destination_size = texture_size * factor;
            break;
        }
        case FIT_STRETCH:
            destination_size = global_screen_size;
            break;
    }

    float2 start = 0.0.xx;
    float2 middle = (global_screen_size - destination_size) / 2.0;
    float2 end = global_screen_size - destination_size;
    float2 destination_offset = middle;
    switch (input.info & POSITION_MASK) {
        case 0u: destination_offset = float2(start.x, start.y); break;
        case 1u: destination_offset = float2(middle.x, start.y); break;
        case 2u: destination_offset = float2(end.x, start.y); break;
        case 3u: destination_offset = float2(start.x, middle.y); break;
        case 4u: destination_offset = float2(middle.x, middle.y); break;
        case 5u: destination_offset = float2(end.x, middle.y); break;
        case 6u: destination_offset = float2(start.x, end.y); break;
        case 7u: destination_offset = float2(middle.x, end.y); break;
        case 8u: destination_offset = float2(end.x, end.y); break;
    }

    uint4 unpacked_bg = unpack4u8(bg_color_packed_4u8);
    bool linear_blending = (global_bools & USE_LINEAR_BLENDING) != 0;
    float4 opaque_bg = loadColor(
        uint4(unpacked_bg.rgb, 255u),
        linear_blending
    );

    BgImageOutput output;
    output.position = float4(
        vertex_id == 2 ? 3.0 : -1.0,
        vertex_id == 0 ? -3.0 : 1.0,
        1.0,
        1.0
    );
    output.bg_color = float4(opaque_bg.rgb, float(unpacked_bg.a) / 255.0);
    output.offset = destination_offset;
    output.scale = texture_size / destination_size;
    output.opacity = input.opacity;
    output.repeat_image = input.info & REPEAT_IMAGE;
    return output;
}

float4 bg_image_pixel(BgImageOutput input) : SV_TARGET {
    uint texture_width;
    uint texture_height;
    bg_image_texture.GetDimensions(texture_width, texture_height);
    float2 texture_size = float2(texture_width, texture_height);
    float2 texture_coord = (input.position.xy - input.offset) * input.scale;

    if (input.repeat_image != 0) {
        texture_coord = fmod(fmod(texture_coord, texture_size) + texture_size, texture_size);
    }

    float4 color = 0.0.xxxx;
    if (!any(texture_coord < 0.0.xx) && !any(texture_coord > texture_size)) {
        color = bg_image_texture.Sample(
            bg_image_sampler,
            texture_coord / texture_size
        );
        if ((global_bools & USE_LINEAR_BLENDING) == 0) {
            color = unlinearizeColor(color);
        }
        color.rgb *= color.a;
    }

    color *= min(input.opacity, 1.0 / input.bg_color.a);
    color += max(0.0.xxxx, float4(input.bg_color.rgb, 1.0) * (1.0 - color.a));
    return color * input.bg_color.a;
}
