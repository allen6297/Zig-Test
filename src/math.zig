//! A minimal 3D math module — just enough for a camera. Hand-rolled on purpose:
//! voxel math is simple, and writing `Vec3`/`Mat4` yourself is a great way to
//! learn both the linear algebra and Zig. Can be swapped for a library later.
//!
//! Matrices are stored **column-major** (`m[col * 4 + row]`), which is what
//! GLSL / Vulkan expect, so they can be uploaded to a shader as-is.

const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero = Vec3{ .x = 0, .y = 0, .z = 0 };

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    /// The vector perpendicular to both `a` and `b`. Order matters: `cross(a,b)`
    /// points opposite `cross(b,a)`. This is how we derive the camera's "right"
    /// and "up" axes from its forward direction.
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }

    /// Return `a` scaled to length 1. A zero-length vector has no direction, so
    /// we return it unchanged rather than dividing by zero.
    pub fn normalize(a: Vec3) Vec3 {
        const len = a.length();
        if (len == 0) return a;
        return a.scale(1.0 / len);
    }
};

/// A 4x4 matrix in column-major order.
pub const Mat4 = struct {
    m: [16]f32,

    pub const identity = Mat4{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    /// A translation matrix — moves points by `t`. Column-major, so the
    /// translation lives in the last column.
    pub fn translation(t: Vec3) Mat4 {
        var m = identity;
        m.m[12] = t.x;
        m.m[13] = t.y;
        m.m[14] = t.z;
        return m;
    }

    /// Matrix product `a * b`. Reads a bit dense, but it's the textbook
    /// column-major multiply: each output column is `a` applied to a column of `b`.
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                out.m[col * 4 + row] = sum;
            }
        }
        return out;
    }

    /// A right-handed "look at" view matrix: positions the world so that `eye`
    /// sits at the origin looking toward `center`, with `up` roughly upward.
    /// This is the classic gluLookAt construction.
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize(); // forward
        const s = f.cross(up).normalize(); // right
        const u = s.cross(f); // recomputed true up

        return .{ .m = .{
            s.x,         u.x,         -f.x,       0,
            s.y,         u.y,         -f.y,       0,
            s.z,         u.z,         -f.z,       0,
            -s.dot(eye), -u.dot(eye), f.dot(eye), 1,
        } };
    }

    /// A right-handed perspective projection, OpenGL-style (clip depth −1..1,
    /// +Y up). Kept for reference/tests; rendering uses `perspectiveVulkan`.
    pub fn perspective(fovy_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const t = std.math.tan(fovy_radians / 2.0);
        var out = Mat4{ .m = .{0} ** 16 };
        out.m[0] = 1.0 / (aspect * t);
        out.m[5] = 1.0 / t;
        out.m[10] = -(far + near) / (far - near);
        out.m[11] = -1.0;
        out.m[14] = -(2.0 * far * near) / (far - near);
        return out;
    }

    /// A right-handed perspective projection for **Vulkan**: clip depth 0..1 and
    /// a flipped Y (Vulkan's clip-space Y points down, opposite OpenGL). This is
    /// the "Y-flip / 0..1 depth correction" we flagged when writing the camera.
    pub fn perspectiveVulkan(fovy_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / std.math.tan(fovy_radians / 2.0);
        var out = Mat4{ .m = .{0} ** 16 };
        out.m[0] = f / aspect;
        out.m[5] = -f; // negative: flip Y for Vulkan
        out.m[10] = far / (near - far);
        out.m[11] = -1.0;
        out.m[14] = (near * far) / (near - far);
        return out;
    }

    /// Full 4x4 inverse (cofactor / adjugate method, the classic MESA
    /// `gluInvertMatrix`). Used to reconstruct a fragment's world position from
    /// its depth in the deferred lighting pass: `inv(viewproj) * clip = world`.
    /// Returns `identity` for a singular (non-invertible) matrix rather than
    /// producing NaNs — callers only feed it well-formed view-projections.
    pub fn inverse(a: Mat4) Mat4 {
        const m = a.m;
        var inv: [16]f32 = undefined;

        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];

        const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
        if (det == 0) return identity;
        const inv_det = 1.0 / det;
        var out: Mat4 = undefined;
        for (inv, 0..) |v, i| out.m[i] = v * inv_det;
        return out;
    }
};

/// Extract the 6 frustum planes from a view-projection matrix (Gribb–Hartmann).
/// Each plane is `(a, b, c, d)` with `a·x + b·y + c·z + d >= 0` inside the
/// frustum. Uses the Vulkan clip convention (depth 0..1: near = row2, not
/// row3+row2). Planes aren't normalised — only the sign matters for an
/// inside/outside test. Order: left, right, bottom, top, near, far.
pub fn frustumPlanes(viewproj: Mat4) [6][4]f32 {
    const m = viewproj.m;
    // Rows of the matrix (column-major storage: element[row][col] = m[col*4+row]).
    const r0 = [4]f32{ m[0], m[4], m[8], m[12] };
    const r1 = [4]f32{ m[1], m[5], m[9], m[13] };
    const r2 = [4]f32{ m[2], m[6], m[10], m[14] };
    const r3 = [4]f32{ m[3], m[7], m[11], m[15] };

    const add = struct {
        fn f(a: [4]f32, b: [4]f32) [4]f32 {
            return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
        }
    }.f;
    const sub = struct {
        fn f(a: [4]f32, b: [4]f32) [4]f32 {
            return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3] };
        }
    }.f;

    return .{
        add(r3, r0), // left
        sub(r3, r0), // right
        add(r3, r1), // bottom
        sub(r3, r1), // top
        r2, // near (Vulkan 0..1 depth)
        sub(r3, r2), // far
    };
}

//region tests

const expect = std.testing.expect;
const expectApprox = std.testing.expectApproxEqAbs;

fn approxVec(a: Vec3, b: Vec3) !void {
    try expectApprox(a.x, b.x, 1e-5);
    try expectApprox(a.y, b.y, 1e-5);
    try expectApprox(a.z, b.z, 1e-5);
}

test "vector basics" {
    const a = Vec3{ .x = 1, .y = 2, .z = 3 };
    const b = Vec3{ .x = 4, .y = 5, .z = 6 };
    try approxVec(a.add(b), .{ .x = 5, .y = 7, .z = 9 });
    try approxVec(a.sub(b), .{ .x = -3, .y = -3, .z = -3 });
    try expectApprox(a.dot(b), 32.0, 1e-5);
    try expectApprox(Vec3.length(.{ .x = 3, .y = 4, .z = 0 }), 5.0, 1e-5);
}

test "cross product is perpendicular and right-handed" {
    const x = Vec3{ .x = 1, .y = 0, .z = 0 };
    const y = Vec3{ .x = 0, .y = 1, .z = 0 };
    // x cross y = z, the defining right-handed relationship.
    try approxVec(x.cross(y), .{ .x = 0, .y = 0, .z = 1 });
}

test "normalize yields unit length" {
    const n = Vec3.normalize(.{ .x = 0, .y = 3, .z = 4 });
    try expectApprox(n.length(), 1.0, 1e-5);
}

test "identity is the multiplicative identity" {
    const a = Mat4{ .m = .{
        2, 0, 0, 0,
        0, 3, 0, 0,
        0, 0, 4, 0,
        5, 6, 7, 1,
    } };
    const r = a.mul(Mat4.identity);
    for (a.m, r.m) |expected, got| try expectApprox(got, expected, 1e-5);
}

test "lookAt down -Z with +Y up is the identity" {
    // A camera at the origin looking straight down -Z is already in view space,
    // so its view matrix should be the identity.
    const v = Mat4.lookAt(
        Vec3.zero,
        .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 0, .y = 1, .z = 0 },
    );
    for (Mat4.identity.m, v.m) |expected, got| try expectApprox(got, expected, 1e-5);
}

test "inverse composes with the original to the identity" {
    const proj = Mat4.perspectiveVulkan(std.math.degreesToRadians(60.0), 1.6, 0.1, 100.0);
    const view = Mat4.lookAt(.{ .x = 3, .y = 4, .z = 5 }, Vec3.zero, .{ .x = 0, .y = 1, .z = 0 });
    const vp = proj.mul(view);
    const round_trip = vp.mul(vp.inverse());
    for (Mat4.identity.m, round_trip.m) |expected, got| try expectApprox(got, expected, 1e-4);
}

fn insideFrustum(planes: [6][4]f32, p: Vec3) bool {
    for (planes) |pl| {
        if (pl[0] * p.x + pl[1] * p.y + pl[2] * p.z + pl[3] < 0) return false;
    }
    return true;
}

test "frustum planes classify points correctly" {
    const proj = Mat4.perspectiveVulkan(std.math.degreesToRadians(60.0), 1.0, 0.1, 100.0);
    const view = Mat4.lookAt(Vec3.zero, .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 1, .z = 0 });
    const planes = frustumPlanes(proj.mul(view));

    // Straight ahead, in range → inside all planes.
    try expect(insideFrustum(planes, .{ .x = 0, .y = 0, .z = -10 }));
    // Behind the camera → outside (near plane).
    try expect(!insideFrustum(planes, .{ .x = 0, .y = 0, .z = 10 }));
    // Far off to the side at close range → outside (left/right plane).
    try expect(!insideFrustum(planes, .{ .x = 100, .y = 0, .z = -1 }));
}
//endregion
