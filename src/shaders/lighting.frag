#version 450

// Deferred lighting pass. Reads the G-buffer (albedo+AO, normal, depth),
// reconstructs each fragment's world position from its depth, and shades it:
// AO-modulated ambient + a soft directional "sun" + one dynamic point light with
// falloff. Writes linear HDR colour into the `lit` target (TAA resolves + tonemaps
// it afterwards). Fog and richer lighting slot in here later.

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

layout(binding = 1) uniform sampler2D g_albedo;
layout(binding = 2) uniform sampler2D g_normal;
layout(binding = 3) uniform sampler2D g_depth;

layout(location = 0) out vec4 out_color;

const vec3 sky_color = vec3(0.01, 0.01, 0.03);

// Reconstruct world position from screen UV + non-linear depth via inv(viewproj).
vec3 reconstruct(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u.inv_viewproj * clip;
    return world.xyz / world.w;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u.params.xy;
    float depth = texture(g_depth, uv).r;
    if (depth >= 1.0) { // cleared depth → no geometry → sky
        out_color = vec4(sky_color, 1.0);
        return;
    }

    vec4 a = texture(g_albedo, uv);
    vec3 albedo = a.rgb;
    float ao = a.a;
    vec3 N = normalize(texture(g_normal, uv).xyz);
    vec3 P = reconstruct(uv, depth);

    // Ambient sky fill, gated by baked AO so crevices stay dark.
    vec3 ambient = vec3(0.20) * ao;

    // Soft directional sun for overall readability (warm, from above).
    vec3 sun_dir = normalize(vec3(0.4, 1.0, 0.3));
    vec3 sun_col = vec3(1.0, 0.96, 0.86);
    float sun = max(dot(N, sun_dir), 0.0) * 0.6;

    // Dynamic point light with inverse-square-ish falloff.
    vec3 to_light = u.light_pos.xyz - P;
    float dist = length(to_light);
    vec3 L = to_light / max(dist, 1e-4);
    float atten = 1.0 / (1.0 + 0.03 * dist * dist);
    float ndl = max(dot(N, L), 0.0);
    vec3 point = u.light_color.rgb * u.light_color.w * ndl * atten;

    vec3 color = albedo * (ambient + sun_col * sun + point);
    out_color = vec4(color, 1.0);
}
