//! A first-person "fly" camera. Pure logic: it turns a position + look angles
//! into a view matrix, and moves/turns in response to input. No SDL, no Vulkan,
//! so it's completely testable on its own — which is why we build it before the
//! renderer that will eventually use it.

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

/// World up. Y-up is a common convention; every "which way is up" question
/// resolves against this single vector.
const world_up = Vec3{ .x = 0, .y = 1, .z = 0 };

pub const Camera = struct {
    /// Where the camera is in the world.
    position: Vec3 = Vec3.zero,

    /// Look angles in radians. `yaw` turns left/right around the Y axis,
    /// `pitch` tilts up/down. Default yaw points the camera down -Z (see
    /// `forward` below for why -pi/2).
    yaw: f32 = -std.math.pi / 2.0,
    pitch: f32 = 0,

    /// How fast movement and mouse-look are. Movement is in world units
    /// (blocks) per second; `sensitivity` is radians of turn per input unit.
    move_speed: f32 = 8.0,
    sensitivity: f32 = 0.0025,

    /// How much faster to move when sprinting.
    sprint_modifier: f32 = 2.0,

    /// Unit vector the camera is looking along, built from yaw/pitch.
    ///
    /// With yaw = -pi/2 and pitch = 0 this yields (0, 0, -1) — straight down -Z,
    /// matching the identity-view case tested in math.zig.
    pub fn forward(self: Camera) Vec3 {
        const cp = std.math.cos(self.pitch);
        return Vec3.normalize(.{
            .x = cp * std.math.cos(self.yaw),
            .y = std.math.sin(self.pitch),
            .z = cp * std.math.sin(self.yaw),
        });
    }

    /// The camera's rightward axis — perpendicular to forward and world-up.
    pub fn right(self: Camera) Vec3 {
        return Vec3.normalize(self.forward().cross(world_up));
    }

    /// The camera's upward axis — perpendicular to forward and right.
    pub fn up(self: Camera) Vec3 {
        return Vec3.normalize(self.forward().cross(self.right()));
    }

    /// Apply a mouse-look delta. `dx`/`dy` are raw pointer movement; pitch is
    /// clamped just shy of straight up/down so the view can't flip over (a
    /// gimbal-flip that feels awful and breaks the "up" reference).
    pub fn look(self: *Camera, dx: f32, dy: f32) void {
        self.yaw += dx * self.sensitivity;
        self.pitch -= dy * self.sensitivity; // screen-y grows downward
        const limit = std.math.degreesToRadians(89.0);
        self.pitch = std.math.clamp(self.pitch, -limit, limit);
    }

    /// Move for one frame. `strafe` is right(+)/left(-), `advance` is
    /// forward(+)/back(-), each expected in [-1, 1]. Multiplying by `dt` makes
    /// speed frame-rate independent (the reason we set up delta time earlier).
    pub fn move(self: *Camera, strafe: f32, advance: f32, float: f32, sprint: bool, dt: f32) void {
        // Combine the two intents into a single direction, then normalize so
        // moving diagonally isn't faster than moving straight.
        var dir = self.forward().scale(advance).add(self.right().scale(strafe).add(self.up().scale(float)));
        if (dir.length() == 0) return; // no keys held
        dir = dir.normalize();

        if (sprint) {
            self.position = self.position.add(dir.scale(self.move_speed * dt * self.sprint_modifier));
        } else {
            self.position = self.position.add(dir.scale(self.move_speed * dt));
        }
    }

    /// The view matrix for this camera — feed this to the shader (later).
    pub fn view(self: Camera) Mat4 {
        return Mat4.lookAt(self.position, self.position.add(self.forward()), world_up);
    }
};

//region tests

const expectApprox = std.testing.expectApproxEqAbs;

test "default camera looks down -Z" {
    const cam = Camera{};
    const f = cam.forward();
    try expectApprox(f.x, 0.0, 1e-5);
    try expectApprox(f.y, 0.0, 1e-5);
    try expectApprox(f.z, -1.0, 1e-5);
}

test "moving forward advances along the look direction" {
    var cam = Camera{ .move_speed = 10 };
    cam.move(0, 1, 0, false, 0.5); // advance for half a second at speed 10 -> 5 units
    // Default forward is -Z, so we should have moved to z = -5.
    try expectApprox(cam.position.x, 0.0, 1e-5);
    try expectApprox(cam.position.y, 0.0, 1e-5);
    try expectApprox(cam.position.z, -5.0, 1e-5);
}

test "diagonal movement is not faster than straight" {
    var straight = Camera{ .move_speed = 10 };
    straight.move(0, 1, 0, false, 1.0);

    var diagonal = Camera{ .move_speed = 10 };
    diagonal.move(1, 1, 0, false, 1.0); // forward + strafe at once

    // Both should travel exactly move_speed units, never more.
    try expectApprox(straight.position.length(), 10.0, 1e-5);
    try expectApprox(diagonal.position.length(), 10.0, 1e-5);
}

test "pitch is clamped so the view can't flip" {
    var cam = Camera{};
    cam.look(0, -100000); // yank the mouse way up
    const limit = std.math.degreesToRadians(89.0);
    try expectApprox(cam.pitch, limit, 1e-5);
}
//endregion
