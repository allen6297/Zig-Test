#version 450

// Deferred geometry pass, fragment stage. Writes the G-buffer: albedo + baked AO
// in one target, the world-space normal in another. No lighting happens here —
// that's the lighting pass's job, reading these targets. Depth is written by the
// fixed-function depth test into the (separately bound) depth attachment.

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec3 v_albedo;
layout(location = 2) in float v_ao;
layout(location = 3) in vec2 v_motion;
layout(location = 4) in float v_material;

layout(location = 0) out vec4 g_albedo; // rgb = albedo, a = baked AO
layout(location = 1) out vec4 g_normal; // rgb = world normal, a = material (1 = water)
layout(location = 2) out vec2 g_motion; // screen-space motion (prev_uv - curr_uv)

void main() {
    g_albedo = vec4(v_albedo, v_ao);
    g_normal = vec4(normalize(v_normal), v_material);
    g_motion = v_motion;
}
