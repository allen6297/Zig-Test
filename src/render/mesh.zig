//! Vertex format for voxel meshes. Each vertex is packed into a single `u32`
//! and decoded in the vertex shader — voxel data is tiny (positions are small
//! integers, there are only 6 face normals), so spending 24 bytes on floats
//! would waste memory bandwidth, the main render bottleneck. Packing gives a
//! 6× cut versus a naive `pos[3]f32 + color[3]f32` vertex.
//!
//! Bit layout of the `u32`:
//!   bits  0..5   x   (0..63, chunk-local)
//!   bits  6..11  y
//!   bits 12..17  z
//!   bits 18..20  normal / face direction (0..5)
//!   bits 21..28  block id (0..255)
//!   bits 29..30  ambient occlusion (0 = darkest .. 3 = brightest)
//!   bit  31      spare

const vk = @import("vulkan");

pub const Vertex = extern struct {
    data: u32,

    pub const binding = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    /// A single integer attribute — the shader unpacks it.
    pub const attributes = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32_uint, .offset = 0 },
    };
};

/// Face directions, matching the `normal` field encoding. Order is fixed —
/// the shader's shading table and the mesher's corner table both rely on it.
pub const Face = enum(u3) {
    pos_x = 0,
    neg_x = 1,
    pos_y = 2,
    neg_y = 3,
    pos_z = 4,
    neg_z = 5,
};

/// Pack one vertex. Coordinates are chunk-local (0..16); `ao` is 0..3.
pub fn pack(x: u32, y: u32, z: u32, face: Face, block: u32, ao: u32) Vertex {
    return .{ .data = x | (y << 6) | (z << 12) |
        (@as(u32, @intFromEnum(face)) << 18) | (block << 21) | (ao << 29) };
}

/// Per-frame shader data, shared by every chunk. Laid out to match the shader's
/// std140 uniform block (mat4 = 64 B, vec4 = 16 B, all 16-byte aligned).
///   - `viewproj`    : projection × view (the per-chunk model offset is a push
///                     constant instead — see `PushConstants`).
///   - `light_pos`   : world-space point-light position (xyz; w unused).
///   - `light_color` : light colour (rgb) × intensity in w.
pub const Uniforms = extern struct {
    viewproj: [16]f32,
    light_pos: [4]f32,
    light_color: [4]f32,
};

/// Per-chunk data, stored in a storage buffer and indexed by `gl_DrawID` during
/// indirect drawing. `origin` is the chunk's world-space minimum corner.
pub const ChunkData = extern struct {
    origin: [4]f32, // xyz used, w padding
};
