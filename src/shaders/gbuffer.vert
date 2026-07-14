#version 450

// Deferred geometry pass, vertex stage. Decodes the packed voxel vertex (bit
// layout in src/render/mesh.zig) into the attributes the G-buffer fragment
// shader stores: world-space normal, base (albedo) colour, and baked AO.
//
// Drawn with a single indirect multi-draw. Each command sets its `firstInstance`
// to the chunk index, so `gl_InstanceIndex` identifies the chunk and looks up its
// world origin. (Instance index, not gl_DrawID: MoltenVK can't translate DrawIndex.)
//
// TAA jitter is applied here in clip space (`params.zw`) so the geometry pass is
// sub-pixel jittered while `viewproj`/`inv_viewproj` in the uniform block stay
// unjittered — keeping world-position reconstruction in the later passes exact.

layout(binding = 0) uniform Uniforms {
    mat4 viewproj;
    mat4 inv_viewproj;
    mat4 prev_viewproj;
    vec4 light_pos;
    vec4 light_color;
    vec4 camera_pos;
    vec4 params; // xy = resolution (px), zw = jitter (NDC)
    vec4 taa;    // x = history valid
} u;

layout(std430, binding = 1) readonly buffer ChunkOrigins {
    vec4 origins[]; // one per chunk (xyz = world-space minimum corner)
};

layout(location = 0) in uint packed;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec3 v_albedo;
layout(location = 2) out float v_ao;

// Base colour per block id (index matches BlockId in src/block.zig).
const vec3 block_colors[6] = vec3[](
    vec3(0.0),                 // 0 air (never drawn)
    vec3(0.55, 0.55, 0.58),    // 1 stone
    vec3(0.45, 0.31, 0.20),    // 2 dirt
    vec3(0.30, 0.65, 0.25),    // 3 grass
    vec3(0.80, 0.74, 0.50),    // 4 sand
    vec3(0.20, 0.40, 0.80)     // 5 water
);

// Face normal per direction (order matches mesh.Face): +x,-x,+y,-y,+z,-z.
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
    uint ao_bits = (packed >> 29) & 3u;
    // Map 0..3 → a brightness multiplier (darkest corners keep some ambient).
    v_ao = mix(0.35, 1.0, float(ao_bits) / 3.0);

    vec3 origin = origins[gl_InstanceIndex].xyz;
    vec3 world_pos = origin + vec3(x, y, z);

    vec4 clip = u.viewproj * vec4(world_pos, 1.0);
    clip.xy += u.params.zw * clip.w; // sub-pixel TAA jitter (clip space)
    gl_Position = clip;

    v_normal = face_normals[face]; // axis-aligned voxel faces; no normal matrix needed
    v_albedo = block_colors[block];
}
