#version 450

// Avatar (remote player) geometry, vertex stage. Draws the shared unit-cube mesh
// as a player-sized box at an entity's feet, writing the same G-buffer varyings
// as the terrain (so it reuses gbuffer.frag and gets lit + shadowed identically).
// Per-entity position + colour come from a push constant; one draw per avatar.

layout(binding = 0) uniform Uniforms {
    mat4 viewproj;
    mat4 inv_viewproj;
    mat4 prev_viewproj;
    vec4 light_pos;
    vec4 light_color;
    vec4 camera_pos;
    vec4 params; // xy = resolution (px), zw = jitter (NDC)
    vec4 taa;
    vec4 shadow_origin;
    vec4 shadow_dim;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 sky_zenith;
    vec4 sky_horizon;
    vec4 fog;
} u;

layout(push_constant) uniform Push {
    vec4 pos;      // xyz = feet position this frame
    vec4 prev_pos; // xyz = feet position last frame (motion vectors)
    vec4 color;    // rgb = avatar colour
} pc;

layout(location = 0) in vec3 in_pos;    // unit cube 0..1
layout(location = 1) in vec3 in_normal;

layout(location = 0) out vec3 v_normal;
layout(location = 1) out vec3 v_albedo;
layout(location = 2) out float v_ao;
layout(location = 3) out vec2 v_motion;

// Player AABB: 0.6 wide/deep, 1.8 tall, centred on x/z, feet at pos.y.
const vec3 player_size = vec3(0.6, 1.8, 0.6);

void main() {
    vec3 local = (in_pos - vec3(0.5, 0.0, 0.5)) * player_size;
    vec3 world = pc.pos.xyz + local;
    vec3 prev_world = pc.prev_pos.xyz + local;

    // Motion vector includes the avatar's own movement (not just the camera), so
    // TAA reprojects moving players correctly instead of ghosting them.
    vec4 clip = u.viewproj * vec4(world, 1.0);
    vec4 prev_clip = u.prev_viewproj * vec4(prev_world, 1.0);
    vec2 curr_uv = (clip.xy / clip.w) * 0.5 + 0.5;
    vec2 prev_uv = (prev_clip.xy / prev_clip.w) * 0.5 + 0.5;
    v_motion = prev_uv - curr_uv;

    clip.xy += u.params.zw * clip.w; // same sub-pixel TAA jitter as the terrain
    gl_Position = clip;

    v_normal = in_normal;
    v_albedo = pc.color.rgb;
    v_ao = 1.0; // no baked AO on avatars
}
