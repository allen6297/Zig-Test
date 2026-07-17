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
    vec4 sun_color;     // rgb = sun colour × intensity (0 at night)
    vec4 sky_zenith;    // rgb = sky straight up
    vec4 sky_horizon;   // rgb = sky at the horizon (also the fog colour)
    vec4 fog;           // w = fog density
} u;

layout(binding = 1) uniform sampler2D g_albedo;
layout(binding = 2) uniform sampler2D g_normal;
layout(binding = 3) uniform sampler2D g_depth;
layout(binding = 4) uniform sampler3D shadow_vol; // r = solidity (1 = solid)

layout(location = 0) out vec4 out_color;

// Sky colour along a world-space view ray: horizon→zenith gradient, a warm glow
// toward the sun (sunrise/sunset bloom + sun disk), and — as the sun drops below
// the horizon — a moon and a field of stars fading in.
vec3 skyColor(vec3 dir) {
    float up = clamp(dir.y, 0.0, 1.0);
    vec3 col = mix(u.sky_horizon.rgb, u.sky_zenith.rgb, pow(up, 0.5));

    float sun_amt = max(dot(dir, u.sun_dir.xyz), 0.0);
    col += u.sun_color.rgb * (0.2 * pow(sun_amt, 8.0) + pow(sun_amt, 256.0));

    // Night sky: fades in as the sun sinks; only above the horizon.
    float night = 1.0 - smoothstep(-0.1, 0.2, u.sun_dir.y);
    if (night > 0.0 && dir.y > 0.0) {
        // Moon: a soft disk opposite the sun (rises as the sun sets).
        vec3 moon_dir = -normalize(u.sun_dir.xyz);
        float md = dot(dir, moon_dir);
        float moon = smoothstep(0.9993, 0.9997, md) + 0.4 * pow(max(md, 0.0), 500.0);
        col += vec3(0.85, 0.87, 1.0) * moon * night;

        // Stars: sparse hashed points, denser toward the zenith.
        vec3 cell = floor(dir * 260.0);
        float h = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
        float star = smoothstep(0.9968, 0.999, h) * smoothstep(0.02, 0.2, dir.y);
        col += vec3(star) * night;
    }
    return col;
}

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

// Reflective water: an animated ripple normal, a Fresnel blend between a deep
// tint (looking straight down) and the reflected sky (grazing angles), and a
// sharp sun glint. `shadow` dims the glint where the sun is occluded.
vec3 waterShade(vec3 P, vec3 N, float shadow) {
    vec3 V = normalize(u.camera_pos.xyz - P);
    float t = u.fog.x; // elapsed seconds (wave animation)

    // Small moving ripples perturbing the surface normal (x/z only, keeps it up).
    vec3 Nw = normalize(N + vec3(
        0.10 * sin(P.x * 0.8 + t * 1.6) + 0.06 * sin(P.z * 1.7 - t * 1.1),
        0.0,
        0.10 * cos(P.z * 0.9 + t * 1.4) + 0.06 * cos(P.x * 1.5 + t * 0.9)));

    const vec3 deep = vec3(0.02, 0.09, 0.16);
    float fres = pow(1.0 - max(dot(Nw, V), 0.0), 4.0);
    vec3 refl = skyColor(normalize(reflect(-V, Nw)));
    vec3 col = mix(deep, refl, clamp(0.05 + 0.9 * fres, 0.0, 1.0));

    // Sun glint: reflect the sun over the ripple normal toward the eye.
    float spec = pow(max(dot(reflect(-u.sun_dir.xyz, Nw), V), 0.0), 200.0);
    col += u.sun_color.rgb * spec * shadow;
    return col;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u.params.xy;
    float depth = texture(g_depth, uv).r;

    // Background: no geometry → draw the gradient sky along the pixel's view ray.
    if (depth >= 1.0) {
        vec3 far = reconstruct(uv, 1.0);
        vec3 dir = normalize(far - u.camera_pos.xyz);
        out_color = vec4(skyColor(dir), 1.0);
        return;
    }

    vec4 a = texture(g_albedo, uv);
    vec3 albedo = a.rgb;
    float ao = a.a;
    vec4 nm = texture(g_normal, uv);
    vec3 N = normalize(nm.xyz);
    float is_water = nm.a; // material flag (1 = water)
    vec3 P = reconstruct(uv, depth);

    // Hemispherical ambient from the current sky: zenith tint above fading to a
    // darker ground bounce below, so unlit surfaces pick up the time-of-day colour
    // and go genuinely dark at night. `ao*ao` deepens creases.
    float hemi = N.y * 0.5 + 0.5; // 1 up, 0 down
    vec3 sky_ambient = u.sky_zenith.rgb * 0.30;
    vec3 ground_ambient = u.sky_horizon.rgb * 0.08;
    vec3 ambient = mix(ground_ambient, sky_ambient, hemi) * (ao * ao);

    // Dynamic point light (the player's headlamp) with inverse-square-ish falloff.
    vec3 to_light = u.light_pos.xyz - P;
    float dist = length(to_light);
    vec3 L = to_light / max(dist, 1e-4);
    float atten = 1.0 / (1.0 + 0.03 * dist * dist);
    float ndl = max(dot(N, L), 0.0);
    vec3 point = u.light_color.rgb * u.light_color.w * ndl * atten;

    // Directional sun (time-of-day colour), with a raymarched hard shadow. The
    // headlamp *fills* the shadow it reaches (distance-only) so we don't see hard
    // sun-shadows right under the light.
    vec3 sun_dir = normalize(u.sun_dir.xyz);
    float shadow = max(sunShadow(P + N * 0.05, sun_dir), atten);
    float sun = max(dot(N, sun_dir), 0.0) * shadow;

    vec3 color;
    if (is_water > 0.5) {
        color = waterShade(P, N, shadow) + point;
    } else {
        color = albedo * (ambient + point) + albedo * u.sun_color.rgb * sun;
    }

    // Distance fog: fade toward the horizon sky colour so far terrain melts into
    // the sky (and hides the streaming edge). Exponential by view distance.
    float view_dist = length(P - u.camera_pos.xyz);
    float f = 1.0 - exp(-view_dist * u.fog.w);
    color = mix(color, u.sky_horizon.rgb, f);

    out_color = vec4(color, 1.0);
}
