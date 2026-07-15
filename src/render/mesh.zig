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

/// Per-frame shader data, shared by every chunk and by the deferred lighting /
/// TAA passes. Laid out to match the shaders' std140 uniform block (mat4 = 64 B,
/// vec4 = 16 B, everything 16-byte aligned, so the fields pack with no padding).
///   - `viewproj`      : **unjittered** projection × view. The geometry pass adds
///                       the sub-pixel TAA jitter itself (`params.zw`), so this
///                       stays clean and `inv_viewproj` is its exact inverse.
///   - `inv_viewproj`  : inverse of `viewproj` — reconstructs a fragment's world
///                       position from its depth in the lighting + TAA passes.
///   - `prev_viewproj` : previous frame's unjittered view × proj — used by TAA to
///                       reproject a world point into last frame's screen.
///   - `light_pos`     : world-space point-light position (xyz; w unused).
///   - `light_color`   : light colour (rgb) × intensity in w.
///   - `camera_pos`    : world-space eye position (xyz; w unused).
///   - `params`        : xy = framebuffer size in px; zw = current jitter (NDC).
///   - `taa`           : x = history-valid flag (0 on the first frames / after a
///                       resize, else 1); yzw reserved.
///   - `shadow_origin` : world-space minimum corner of the shadow voxel volume
///                       (xyz; w unused). The volume is 1 voxel per world unit.
///   - `shadow_dim`    : shadow volume size in voxels (xyz; w unused).
pub const Uniforms = extern struct {
    viewproj: [16]f32,
    inv_viewproj: [16]f32,
    prev_viewproj: [16]f32,
    light_pos: [4]f32,
    light_color: [4]f32,
    camera_pos: [4]f32,
    params: [4]f32,
    taa: [4]f32,
    shadow_origin: [4]f32,
    shadow_dim: [4]f32,
    sun_dir: [4]f32, // xyz = direction toward the sun (normalized); w unused
};

/// Per-chunk data, stored in a storage buffer and indexed by `gl_DrawID` during
/// indirect drawing. `origin` is the chunk's world-space minimum corner.
pub const ChunkData = extern struct {
    origin: [4]f32, // xyz used, w padding
};

// --- entity (player avatar) rendering ---
//
// Remote players are drawn as lit boxes in the G-buffer. A shared unit-cube mesh
// is sized/positioned per entity in the vertex shader from a push constant.

/// A vertex of the avatar cube: local position (0..1) + flat face normal.
pub const EntityVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,

    pub const binding = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(EntityVertex),
        .input_rate = .vertex,
    };
    pub const attributes = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = 0 },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(EntityVertex, "normal") },
    };
};

/// Per-avatar push constant: feet position + colour.
pub const EntityPush = extern struct {
    pos: [4]f32, // xyz = feet position; w unused
    color: [4]f32, // rgb = avatar colour; a unused
};

/// A remote player to draw this frame (built by the client from replicated state).
pub const EntityInstance = struct {
    pos: [3]f32,
    color: [3]f32,
};

/// Unit-cube (0..1) mesh, 36 vertices, flat per-face normals. The entity vertex
/// shader scales it to a player-sized box (0.6 × 1.8 × 0.6) at the entity's feet.
pub const cube_vertices = blk: {
    const CubeFace = struct { n: [3]f32, c: [4][3]f32 };
    const faces = [6]CubeFace{
        .{ .n = .{ 1, 0, 0 }, .c = .{ .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 1, 0, 1 } } },
        .{ .n = .{ -1, 0, 0 }, .c = .{ .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 }, .{ 0, 0, 0 } } },
        .{ .n = .{ 0, 1, 0 }, .c = .{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 } } },
        .{ .n = .{ 0, -1, 0 }, .c = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 } } },
        .{ .n = .{ 0, 0, 1 }, .c = .{ .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 }, .{ 0, 0, 1 } } },
        .{ .n = .{ 0, 0, -1 }, .c = .{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 0 } } },
    };
    var v: [36]EntityVertex = undefined;
    var i: usize = 0;
    for (faces) |f| {
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |ci| {
            v[i] = .{ .pos = f.c[ci], .normal = f.n };
            i += 1;
        }
    }
    break :blk v;
};
