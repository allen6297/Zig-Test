#version 450

// Decodes the packed voxel vertex (see src/render/mesh.zig for the bit layout)
// and passes the fragment shader everything it needs for real per-pixel
// lighting: world-space position, face normal, and base (albedo) colour.
//
// Drawn with a single indirect multi-draw call. Each draw command sets its
// `firstInstance` to the chunk index, so `gl_InstanceIndex` identifies the chunk
// and looks up its world origin from a storage buffer. (We use the instance
// index rather than gl_DrawID because MoltenVK can't translate DrawIndex.)

layout(binding = 0) uniform Uniforms {
    mat4 viewproj;
    vec4 light_pos;
    vec4 light_color;
} u;

layout(std430, binding = 1) readonly buffer ChunkOrigins {
    vec4 origins[]; // one per chunk (xyz = world-space minimum corner)
};

layout(location = 0) in uint packed;

layout(location = 0) out vec3 world_pos;
layout(location = 1) out vec3 normal;
layout(location = 2) out vec3 albedo;

// Base colour per block id (index matches BlockId in src/block.zig).
const vec3 block_colors[6] = vec3[](
    vec3(0.0),                 // 0 air (never drawn)
    vec3(0.55, 0.55, 0.58),    // 1 stone
    vec3(0.45, 0.31, 0.20),    // 2 dirt
    vec3(0.30, 0.65, 0.25),    // 3 grass
    vec3(0.80, 0.74, 0.50),    // 4 sand
    vec3(0.20, 0.40, 0.80)     // 5 water
);

// Face normal per direction (order matches mesh.Face):
// +x, -x, +y, -y, +z, -z. Voxel faces are axis-aligned, so these are exact.
const vec3 face_normals[6] = vec3[](
    vec3( 1, 0, 0), vec3(-1, 0, 0),
    vec3( 0, 1, 0), vec3( 0,-1, 0),
    vec3( 0, 0, 1), vec3( 0, 0,-1)
);

void main() {
    float x = float(packed & 63u);
    float y = float((packed >> 6) & 63u);
    float z = float((packed >> 12) & 63u);
    uint face = (packed >> 18) & 7u;
    uint block = (packed >> 21) & 255u;

    // Chunk-local position → world position by adding this chunk's origin,
    // looked up by the per-chunk instance index.
    vec3 origin = origins[gl_InstanceIndex].xyz;
    world_pos = origin + vec3(x, y, z);
    gl_Position = u.viewproj * vec4(world_pos, 1.0);
    normal = face_normals[face]; // axis-aligned voxel faces; no normal matrix needed
    albedo = block_colors[block];
}
