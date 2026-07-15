#version 450

// Temporal anti-aliasing resolve. Blends the current frame's lighting with the
// reprojected history of previous frames, so the per-frame sub-pixel jitter
// (applied in the geometry pass) averages out into smooth edges over time.
//
// Reprojection uses the **motion-vector** G-buffer target: each pixel stores where
// its surface was on screen last frame, so both camera motion *and* moving players
// reproject correctly (no avatar ghosting). A 3×3 neighbourhood colour clamp on
// the history suppresses ghosting where reprojection is wrong (disocclusions).
//
// Writes two targets: location 0 → the sRGB swapchain (tonemapped; the sRGB
// format applies gamma on write), location 1 → the history image fed back next
// frame (linear, un-tonemapped, so accumulation stays in a consistent space).

layout(binding = 0) uniform Uniforms {
    mat4 viewproj;
    mat4 inv_viewproj;
    mat4 prev_viewproj;
    vec4 light_pos;
    vec4 light_color;
    vec4 camera_pos;
    vec4 params; // xy = resolution (px), zw = jitter (NDC)
    vec4 taa;    // x = history valid
    vec4 shadow_origin;
    vec4 shadow_dim;
    vec4 sun_dir;
} u;

layout(binding = 1) uniform sampler2D lit;     // current frame lighting (linear HDR)
layout(binding = 2) uniform sampler2D history; // previous resolved frame (linear HDR)
layout(binding = 3) uniform sampler2D g_depth;
layout(binding = 5) uniform sampler2D g_motion; // screen-space motion (prev_uv - curr_uv)

layout(location = 0) out vec4 out_swapchain; // tonemapped (sRGB target)
layout(location = 1) out vec4 out_history;   // linear, fed back next frame

const float history_weight = 0.9; // how much of the accumulated history to keep

// ACES filmic tonemap (Narkowicz fit). Maps linear HDR → displayable [0,1].
vec3 tonemap(vec3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec2 res = u.params.xy;
    vec2 uv = gl_FragCoord.xy / res;
    vec2 texel = 1.0 / res;

    vec3 current = texture(lit, uv).rgb;

    // Neighbourhood colour AABB — history is clamped into this to kill ghosting.
    vec3 mn = current;
    vec3 mx = current;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            vec3 s = texture(lit, uv + vec2(x, y) * texel).rgb;
            mn = min(mn, s);
            mx = max(mx, s);
        }
    }

    vec3 result = current;
    float depth = texture(g_depth, uv).r;
    if (u.taa.x > 0.5 && depth < 1.0) {
        // Where this surface was last frame = current uv + its motion vector.
        vec2 prev_uv = uv + texture(g_motion, uv).rg;
        if (all(greaterThanEqual(prev_uv, vec2(0.0))) && all(lessThanEqual(prev_uv, vec2(1.0)))) {
            vec3 hist = clamp(texture(history, prev_uv).rgb, mn, mx);
            result = mix(current, hist, history_weight);
        }
    }

    out_history = vec4(result, 1.0);
    out_swapchain = vec4(tonemap(result), 1.0);
}
