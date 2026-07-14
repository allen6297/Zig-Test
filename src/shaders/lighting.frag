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
    vec4 params;        // xy = resolution (px), zw = jitter (NDC)
    vec4 taa;           // x = history valid
    vec4 shadow_origin; // xyz = world min corner of the shadow voxel volume
    vec4 shadow_dim;    // xyz = shadow volume size in voxels
    vec4 sun_dir;       // xyz = direction toward the sun (normalized)
} u;

layout(binding = 1) uniform sampler2D g_albedo;
layout(binding = 2) uniform sampler2D g_normal;
layout(binding = 3) uniform sampler2D g_depth;
layout(binding = 4) uniform sampler3D shadow_vol; // r = solidity (1 = solid)

layout(location = 0) out vec4 out_color;

const vec3 sky_color = vec3(0.01, 0.01, 0.03);

// Reconstruct world position from screen UV + non-linear depth via inv(viewproj).
vec3 reconstruct(vec2 uv, float depth) {
    vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world = u.inv_viewproj * clip;
    return world.xyz / world.w;
}

// DDA a shadow ray from world point `p` toward `dir` through the voxel volume
// (Amanatides–Woo grid traversal). Returns 0 if a solid voxel is hit before the
// ray leaves the volume (shadowed), 1 otherwise (lit). Marches in volume-local
// voxel space; `texelFetch` reads solidity per voxel, so no filtering artefacts.
float sunShadow(vec3 p, vec3 dir) {
    vec3 dim = u.shadow_dim.xyz;
    vec3 local = p - u.shadow_origin.xyz; // world → volume-local (1 voxel/unit)
    ivec3 vox = ivec3(floor(local));
    ivec3 vstep = ivec3(sign(dir));

    // Distance (in ray-t) to the next voxel boundary on each axis, and the t-span
    // of one voxel. Guard axes with ~zero direction so they never trigger.
    vec3 inv = 1.0 / max(abs(dir), vec3(1e-6));
    vec3 tmax;
    tmax.x = (dir.x > 0.0 ? (float(vox.x + 1) - local.x) : (local.x - float(vox.x))) * inv.x;
    tmax.y = (dir.y > 0.0 ? (float(vox.y + 1) - local.y) : (local.y - float(vox.y))) * inv.y;
    tmax.z = (dir.z > 0.0 ? (float(vox.z + 1) - local.z) : (local.z - float(vox.z))) * inv.z;
    vec3 tdelta = inv;

    // Step voxel-by-voxel. The starting voxel is skipped (we advance first), which
    // avoids self-shadowing the surface's own block.
    for (int i = 0; i < 128; i++) {
        if (tmax.x < tmax.y && tmax.x < tmax.z) {
            vox.x += vstep.x;
            tmax.x += tdelta.x;
        } else if (tmax.y < tmax.z) {
            vox.y += vstep.y;
            tmax.y += tdelta.y;
        } else {
            vox.z += vstep.z;
            tmax.z += tdelta.z;
        }
        if (any(lessThan(vox, ivec3(0))) || any(greaterThanEqual(vox, ivec3(dim)))) return 1.0; // left volume
        if (texelFetch(shadow_vol, vox, 0).r > 0.5) return 0.0; // hit solid
    }
    return 1.0;
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

    // Hemispherical ambient: a dim, cool sky fill from above fading to a much
    // darker ground bounce below, so surfaces the sun doesn't reach fall into
    // shadow instead of being flatly lit. `ao*ao` deepens creases. Kept low
    // overall so unlit areas read as genuinely dark (contrast/mood).
    vec3 sky_ambient = vec3(0.09, 0.11, 0.15);
    vec3 ground_ambient = vec3(0.015, 0.015, 0.02);
    float hemi = N.y * 0.5 + 0.5; // 1 up, 0 down
    vec3 ambient = mix(ground_ambient, sky_ambient, hemi) * (ao * ao);

    // Dynamic point light (the player's headlamp) with inverse-square-ish falloff.
    vec3 to_light = u.light_pos.xyz - P;
    float dist = length(to_light);
    vec3 L = to_light / max(dist, 1e-4);
    float atten = 1.0 / (1.0 + 0.03 * dist * dist);
    float ndl = max(dot(N, L), 0.0);
    vec3 point = u.light_color.rgb * u.light_color.w * ndl * atten;

    // Directional sun (warm), with a raymarched hard shadow: march a ray through
    // the voxel volume toward the sun and kill the sun term if a solid block
    // occludes it. Biased off the surface along the normal to avoid acne. The sun
    // direction is live-tunable from the debug overlay.
    //
    // The headlamp *fills* the shadow it reaches so we don't see hard sun-shadows
    // right where the light is. The fill is **distance-only** (`atten`), not
    // `ndl·atten` — an ndl-based fill wrongly spared viewer-facing side faces
    // (bright normals) while shadowing top faces, so shadows showed on tops but
    // not sides. Distance-only treats every face the same. Far from the light,
    // shadows stay full-strength.
    vec3 sun_dir = normalize(u.sun_dir.xyz);
    vec3 sun_col = vec3(1.0, 0.96, 0.86);
    float shadow = max(sunShadow(P + N * 0.05, sun_dir), atten);
    float sun = max(dot(N, sun_dir), 0.0) * 0.9 * shadow;

    vec3 color = albedo * (ambient + sun_col * sun + point);
    out_color = vec4(color, 1.0);
}
