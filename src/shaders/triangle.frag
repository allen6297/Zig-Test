#version 450

// Real per-pixel lighting: one dynamic coloured point light with inverse-square
// distance attenuation, plus a small ambient term so shadowed faces aren't pure
// black. This replaces the old fake per-face brightness. Shadows (occlusion)
// come in a later phase — for now every surface sees the light.

layout(binding = 0) uniform Uniforms {
    mat4 viewproj;
    vec4 light_pos;
    vec4 light_color;
} u;

layout(location = 0) in vec3 world_pos;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec3 albedo;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(normal);

    // Direction to the light and its distance.
    vec3 to_light = u.light_pos.xyz - world_pos;
    float dist = length(to_light);
    vec3 l = to_light / max(dist, 0.0001);

    // Lambert diffuse term, attenuated by inverse-square falloff. `light_color.w`
    // scales overall intensity so the light reaches across the chunk.
    float diffuse = max(dot(n, l), 0.0);
    float attenuation = u.light_color.w / (1.0 + 0.05 * dist * dist);

    vec3 ambient = vec3(0.08);
    vec3 lit = albedo * (ambient + u.light_color.rgb * diffuse * attenuation);

    out_color = vec4(lit, 1.0);
}
