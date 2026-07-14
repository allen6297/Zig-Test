#version 450

// Flat shading for now (dynamic light removed): baked per-vertex AO plus a fixed
// sky-ish face shade (top brightest, bottom darkest) so voxels still read in 3D
// without any light. Real lighting returns with the deferred + raymarched path.

layout(location = 0) in vec3 world_pos; // currently unused (kept for varying match)
layout(location = 1) in vec3 normal;
layout(location = 2) in vec3 albedo;
layout(location = 3) in float ao;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(normal);

    // Fixed directional shade: n.y = +1 (up) → 1.0, −1 (down) → 0.55, sides ≈ 0.78.
    float shade = 0.55 + 0.45 * (n.y * 0.5 + 0.5);

    out_color = vec4(albedo * ao * shade, 1.0);
}
