//! Voxel raycast — steps a ray through the block grid (Amanatides & Woo DDA) to
//! find the first solid block it hits, and which face. Used for block editing
//! (aim → break/place), and the same grid-stepping powers raymarched lighting
//! later. Reads only cached chunks, so cast within the loaded region.

const std = @import("std");
const World = @import("world.zig").World;
const Vec3 = @import("../math.zig").Vec3;

pub const Hit = struct {
    /// The solid block the ray hit.
    block: [3]i32,
    /// Face normal (points back toward the ray). `block + normal` is the empty
    /// cell in front of that face — where a placed block goes.
    normal: [3]i32,
};

/// Cast from `origin` along `dir` up to `max_dist` blocks. Null if nothing hit.
pub fn raycastVoxel(world: *const World, origin: Vec3, dir: Vec3, max_dist: f32) ?Hit {
    const len = dir.length();
    if (len == 0) return null;
    const d = [3]f32{ dir.x / len, dir.y / len, dir.z / len };
    const o = [3]f32{ origin.x, origin.y, origin.z };

    var voxel = [3]i32{ ifloor(o[0]), ifloor(o[1]), ifloor(o[2]) };
    var step = [3]i32{ 0, 0, 0 };
    var t_max = [3]f32{ 0, 0, 0 };
    var t_delta = [3]f32{ 0, 0, 0 };
    const inf = std.math.inf(f32);

    for (0..3) |a| {
        if (d[a] > 0) {
            step[a] = 1;
            t_delta[a] = 1.0 / d[a];
            t_max[a] = (@floor(o[a]) + 1.0 - o[a]) / d[a];
        } else if (d[a] < 0) {
            step[a] = -1;
            t_delta[a] = -1.0 / d[a];
            t_max[a] = (o[a] - @floor(o[a])) / -d[a];
        } else {
            t_delta[a] = inf;
            t_max[a] = inf;
        }
    }

    var normal = [3]i32{ 0, 0, 0 };
    var t: f32 = 0;
    while (t <= max_dist) {
        if (world.blockAt(voxel[0], voxel[1], voxel[2]).isSolid()) {
            return .{ .block = voxel, .normal = normal };
        }
        // Advance across the nearest voxel boundary.
        var a: usize = 0;
        if (t_max[1] < t_max[a]) a = 1;
        if (t_max[2] < t_max[a]) a = 2;
        voxel[a] += step[a];
        t = t_max[a];
        t_max[a] += t_delta[a];
        normal = .{ 0, 0, 0 };
        normal[a] = -step[a]; // we entered the new voxel through this face
    }
    return null;
}

fn ifloor(x: f32) i32 {
    return @intFromFloat(@floor(x));
}

test "raycast hits a block straight ahead and reports the near face" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();
    try world.setBlock(5, 0, 0, .stone);

    // Fire from x=0 toward +x; should hit block (5,0,0) on its −x face.
    const hit = raycastVoxel(&world, .{ .x = 0.5, .y = 0.5, .z = 0.5 }, .{ .x = 1, .y = 0, .z = 0 }, 10);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual([3]i32{ 5, 0, 0 }, hit.?.block);
    try std.testing.expectEqual([3]i32{ -1, 0, 0 }, hit.?.normal);
}

test "raycast misses into empty space" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();
    const hit = raycastVoxel(&world, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 }, 10);
    try std.testing.expect(hit == null);
}
