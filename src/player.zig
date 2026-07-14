//! A walking player: an axis-aligned box that gravity pulls down and that
//! collides with the voxel world. Movement resolves one axis at a time (so you
//! slide along walls instead of sticking), sub-stepped so you can't tunnel
//! through blocks. Runs on a fixed timestep for stability (variable `dt` makes
//! collision unreliable).
//!
//! `pos` is the **feet** position: centred on x/z, at the bottom on y.

const std = @import("std");
const World = @import("world.zig").World;
const Vec3 = @import("math.zig").Vec3;

pub const Player = struct {
    pos: Vec3,
    vel: Vec3 = Vec3.zero,
    on_ground: bool = false,

    const half_width = 0.3; // AABB is 0.6 wide/deep
    const height = 1.8;
    const eye_height = 1.6;
    const walk_speed = 5.0;
    const sprint_speed = 8.5;
    const gravity = 25.0;
    const jump_speed = 8.5;

    /// The camera/eye position (top-ish of the box).
    pub fn eye(self: Player) Vec3 {
        return .{ .x = self.pos.x, .y = self.pos.y + eye_height, .z = self.pos.z };
    }

    /// Advance one fixed step. `advance` is forward(+)/back(−), `strafe` is
    /// right(+)/left(−), each in [-1,1]; `yaw` is the look yaw (camera angle).
    pub fn step(self: *Player, world: *const World, advance: f32, strafe: f32, jump: bool, sprint: bool, yaw: f32, dt: f32) void {
        // Horizontal move direction from the look yaw (no pitch — you walk flat).
        const fwd = Vec3{ .x = @cos(yaw), .y = 0, .z = @sin(yaw) };
        const right = Vec3{ .x = -@sin(yaw), .y = 0, .z = @cos(yaw) };
        var wish = fwd.scale(advance).add(right.scale(strafe));
        const wlen = wish.length();
        const speed: f32 = if (sprint) sprint_speed else walk_speed;
        if (wlen > 0) wish = wish.scale(speed / wlen) else wish = Vec3.zero;
        self.vel.x = wish.x;
        self.vel.z = wish.z;

        // Gravity + jump.
        self.vel.y -= gravity * dt;
        if (jump and self.on_ground) self.vel.y = jump_speed;
        self.on_ground = false;

        // Move + collide per axis (y last, so landing sets on_ground).
        self.sweep(world, "x", self.vel.x * dt);
        self.sweep(world, "z", self.vel.z * dt);
        self.sweep(world, "y", self.vel.y * dt);
    }

    /// Move along one axis in small increments, stopping at the first collision.
    fn sweep(self: *Player, world: *const World, comptime field: []const u8, delta: f32) void {
        const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(delta) / 0.1))));
        const inc = delta / @as(f32, @floatFromInt(n));
        var k: usize = 0;
        while (k < n) : (k += 1) {
            @field(self.pos, field) += inc;
            if (self.collides(world)) {
                @field(self.pos, field) -= inc;
                @field(self.vel, field) = 0;
                if (comptime std.mem.eql(u8, field, "y")) {
                    if (delta < 0) self.on_ground = true; // stopped while falling → grounded
                }
                return;
            }
        }
    }

    /// Does the player's AABB overlap any solid block?
    fn collides(self: *const Player, world: *const World) bool {
        const min_x = ifloor(self.pos.x - half_width);
        const max_x = ifloor(self.pos.x + half_width);
        const min_y = ifloor(self.pos.y);
        const max_y = ifloor(self.pos.y + height);
        const min_z = ifloor(self.pos.z - half_width);
        const max_z = ifloor(self.pos.z + half_width);
        var bx = min_x;
        while (bx <= max_x) : (bx += 1) {
            var by = min_y;
            while (by <= max_y) : (by += 1) {
                var bz = min_z;
                while (bz <= max_z) : (bz += 1) {
                    if (world.blockAt(bx, by, bz).isSolid()) return true;
                }
            }
        }
        return false;
    }
};

fn ifloor(x: f32) i32 {
    return @intFromFloat(@floor(x));
}

test "player falls onto a floor and stops" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();
    // A floor of stone at y=0 across a small area.
    var x: i32 = -2;
    while (x <= 2) : (x += 1) {
        var z: i32 = -2;
        while (z <= 2) : (z += 1) try world.setBlock(x, 0, z, .stone);
    }
    _ = try world.ensure(.{ .x = 0, .y = 0, .z = 0 });

    var player = Player{ .pos = .{ .x = 0.5, .y = 5, .z = 0.5 } };
    var i: usize = 0;
    while (i < 200) : (i += 1) player.step(&world, 0, 0, false, false, 0, 1.0 / 60.0);

    try std.testing.expect(player.on_ground);
    // Feet rest just above the floor's top (y=1), within a sub-step.
    try std.testing.expect(player.pos.y >= 1.0 and player.pos.y < 1.2);
}
