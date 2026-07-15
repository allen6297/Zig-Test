//! Small hand-rolled coherent noise for terrain: value noise on an integer
//! lattice, smoothly interpolated, plus fractal Brownian motion (fBm) that sums
//! octaves for natural detail. Pure Zig, no dependency — plenty for voxel terrain
//! (swap for `znoise`/FastNoiseLite later if we want simplex + domain warp).
//!
//! All generators are deterministic functions of their coordinates + a `seed`, so
//! any chunk regenerates identically on demand (matches the world's design).

const std = @import("std");

/// Hash an integer lattice point to a pseudo-random value in [0,1). A cheap
/// integer bit-mix (xorshift-multiply) — not cryptographic, just well-scrambled
/// so neighbouring cells look uncorrelated.
fn hash(xi: i32, yi: i32, zi: i32, seed: u32) f32 {
    var h: u32 = seed ^ 0x9E3779B1;
    h = (h ^ @as(u32, @bitCast(xi))) *% 0x85EBCA77;
    h = (h ^ @as(u32, @bitCast(yi))) *% 0xC2B2AE3D;
    h = (h ^ @as(u32, @bitCast(zi))) *% 0x27D4EB2F;
    h ^= h >> 15;
    h *%= 0x85EBCA77;
    h ^= h >> 13;
    return @as(f32, @floatFromInt(h & 0xFFFFFF)) / @as(f32, 0x1000000);
}

/// Quintic fade curve (Perlin's): smooth with zero 1st/2nd derivatives at 0 and 1.
fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// 2D value noise in [0,1]. Interpolates the four surrounding lattice values.
pub fn value2(x: f32, y: f32, seed: u32) f32 {
    const xi: i32 = @intFromFloat(@floor(x));
    const yi: i32 = @intFromFloat(@floor(y));
    const xf = x - @floor(x);
    const yf = y - @floor(y);
    const u = fade(xf);
    const v = fade(yf);
    const v00 = hash(xi, yi, 0, seed);
    const v10 = hash(xi + 1, yi, 0, seed);
    const v01 = hash(xi, yi + 1, 0, seed);
    const v11 = hash(xi + 1, yi + 1, 0, seed);
    return lerp(lerp(v00, v10, u), lerp(v01, v11, u), v);
}

/// 3D value noise in [0,1]. Interpolates the eight surrounding lattice values.
pub fn value3(x: f32, y: f32, z: f32, seed: u32) f32 {
    const xi: i32 = @intFromFloat(@floor(x));
    const yi: i32 = @intFromFloat(@floor(y));
    const zi: i32 = @intFromFloat(@floor(z));
    const u = fade(x - @floor(x));
    const v = fade(y - @floor(y));
    const w = fade(z - @floor(z));
    const c000 = hash(xi, yi, zi, seed);
    const c100 = hash(xi + 1, yi, zi, seed);
    const c010 = hash(xi, yi + 1, zi, seed);
    const c110 = hash(xi + 1, yi + 1, zi, seed);
    const c001 = hash(xi, yi, zi + 1, seed);
    const c101 = hash(xi + 1, yi, zi + 1, seed);
    const c011 = hash(xi, yi + 1, zi + 1, seed);
    const c111 = hash(xi + 1, yi + 1, zi + 1, seed);
    const x00 = lerp(c000, c100, u);
    const x10 = lerp(c010, c110, u);
    const x01 = lerp(c001, c101, u);
    const x11 = lerp(c011, c111, u);
    return lerp(lerp(x00, x10, v), lerp(x01, x11, v), w);
}

/// Fractal Brownian motion: sum `octaves` of `value2` at doubling frequency and
/// halving amplitude, normalised to [0,1]. Higher octaves add finer detail.
pub fn fbm2(x: f32, y: f32, seed: u32, octaves: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1;
    var freq: f32 = 1;
    var norm: f32 = 0;
    var o: u32 = 0;
    while (o < octaves) : (o += 1) {
        sum += amp * value2(x * freq, y * freq, seed +% o);
        norm += amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    return sum / norm;
}

/// 3D fractal Brownian motion (for caves / volumetric features).
pub fn fbm3(x: f32, y: f32, z: f32, seed: u32, octaves: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1;
    var freq: f32 = 1;
    var norm: f32 = 0;
    var o: u32 = 0;
    while (o < octaves) : (o += 1) {
        sum += amp * value3(x * freq, y * freq, z * freq, seed +% o);
        norm += amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    return sum / norm;
}

//region tests
const expect = std.testing.expect;

test "value noise stays in range and is deterministic" {
    var y: f32 = 0;
    while (y < 8) : (y += 0.37) {
        var x: f32 = 0;
        while (x < 8) : (x += 0.37) {
            const a = value2(x, y, 1234);
            const b = value2(x, y, 1234);
            try expect(a == b); // deterministic
            try expect(a >= 0.0 and a <= 1.0); // in range
            try expect(fbm2(x, y, 1234, 4) >= 0.0 and fbm2(x, y, 1234, 4) <= 1.0);
            try expect(value3(x, y, x + y, 7) >= 0.0 and value3(x, y, x + y, 7) <= 1.0);
        }
    }
}

test "integer lattice points reproduce their hashed value" {
    // At integer coordinates the interpolation weights are 0, so value2 returns
    // exactly the corner hash — a good smoke test that the lattice lines up.
    try expect(value2(3, 5, 42) == hash(3, 5, 0, 42));
}
//endregion
