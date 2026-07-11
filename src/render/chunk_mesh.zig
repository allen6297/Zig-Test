//! Turn a `Chunk` of blocks into renderable geometry via **greedy meshing**.
//!
//! Instead of one quad per visible block face, greedy meshing merges adjacent
//! coplanar faces of the same block into large quads. A flat 16×16 slab's top
//! becomes ONE quad instead of 256. Combined with interior-face culling, this
//! collapses typical terrain dramatically.
//!
//! The algorithm sweeps each of the 3 axes. For every grid plane perpendicular
//! to the axis, it builds a 2D mask of the faces that live on that plane (a face
//! exists where a solid block meets air across the plane), then greedily grows
//! same-block rectangles out of the mask and emits one quad each. Faces on
//! opposite sides of the plane point opposite ways, so the mask records the face
//! direction too and only merges matching faces.
//!
//! Pure and allocator-driven (no Vulkan beyond the vertex format) — fully
//! testable on its own.

const std = @import("std");
const zig_test = @import("zig_test");
const World = zig_test.world.World;
const size = zig_test.chunk.size;
const mesh = @import("mesh.zig");
const Vertex = mesh.Vertex;
const Face = mesh.Face;

/// A meshed chunk: unique vertices plus indices that stitch them into triangles.
pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};

/// Face tag for the +axis and −axis direction of each axis (x, y, z).
const pos_faces = [3]Face{ .pos_x, .pos_y, .pos_z };
const neg_faces = [3]Face{ .neg_x, .neg_y, .neg_z };

/// One cell of the per-plane mask: which face (if any) sits here.
const MaskCell = struct {
    present: bool = false,
    face: Face = .pos_x,
    block: u32 = 0,
};

fn merges(a: MaskCell, b: MaskCell) bool {
    return a.present and b.present and a.face == b.face and a.block == b.block;
}

/// Mesh the chunk at grid coordinate (`cx`,`cy`,`cz`) of `world` into freshly-
/// allocated vertex + index slices (caller frees via `Mesh.deinit`). Vertices are
/// **chunk-local** (0..16); the caller positions the chunk with its world origin.
/// Faces are culled against neighbouring chunks (via `world.blockAt`), so chunk
/// seams don't produce interior walls. Each merged quad is 4 vertices, 6 indices.
pub fn build(allocator: std.mem.Allocator, world: *const World, cx: i32, cy: i32, cz: i32) !Mesh {
    var verts = std.ArrayList(Vertex).empty;
    errdefer verts.deinit(allocator);
    var indices = std.ArrayList(u32).empty;
    errdefer indices.deinit(allocator);

    // World-space offset of this chunk's minimum corner.
    const origin = [3]i32{ cx * size, cy * size, cz * size };

    var mask: [size * size]MaskCell = undefined;

    // Sweep each axis d, with u and v the two in-plane axes.
    var d: usize = 0;
    while (d < 3) : (d += 1) {
        const u = (d + 1) % 3;
        const v = (d + 2) % 3;

        // Each grid plane sits between blocks at x[d]=slice and x[d]=slice+1.
        var slice: i32 = -1;
        while (slice < size) : (slice += 1) {
            // Build the mask for this plane.
            var j: usize = 0;
            while (j < size) : (j += 1) {
                var i: usize = 0;
                while (i < size) : (i += 1) {
                    // World coordinates of the two blocks straddling this plane.
                    var wa = origin;
                    wa[u] += @intCast(i);
                    wa[v] += @intCast(j);
                    wa[d] += slice;
                    var wb = wa;
                    wb[d] += 1;

                    const a = world.blockAt(wa[0], wa[1], wa[2]);
                    const b = world.blockAt(wb[0], wb[1], wb[2]);
                    // A face exists only where solid meets air; it belongs to the
                    // solid block and faces toward the air side.
                    mask[i + j * size] = if (a.isSolid() and !b.isSolid())
                        .{ .present = true, .face = pos_faces[d], .block = @intFromEnum(a) }
                    else if (b.isSolid() and !a.isSolid())
                        .{ .present = true, .face = neg_faces[d], .block = @intFromEnum(b) }
                    else
                        .{};
                }
            }

            // Greedily merge rectangles out of the mask and emit quads.
            const plane: u32 = @intCast(slice + 1);
            var mj: usize = 0;
            while (mj < size) : (mj += 1) {
                var mi: usize = 0;
                while (mi < size) {
                    const cell = mask[mi + mj * size];
                    if (!cell.present) {
                        mi += 1;
                        continue;
                    }
                    // Grow width along u, then height along v while cells match.
                    var w: usize = 1;
                    while (mi + w < size and merges(mask[mi + w + mj * size], cell)) : (w += 1) {}
                    var h: usize = 1;
                    grow: while (mj + h < size) {
                        var k: usize = 0;
                        while (k < w) : (k += 1) {
                            if (!merges(mask[mi + k + (mj + h) * size], cell)) break :grow;
                        }
                        h += 1;
                    }

                    try emitQuad(allocator, &verts, &indices, d, u, v, plane, mi, mj, w, h, cell);

                    // Consume the merged cells so we don't revisit them.
                    var l: usize = 0;
                    while (l < h) : (l += 1) {
                        var k: usize = 0;
                        while (k < w) : (k += 1) mask[mi + k + (mj + l) * size] = .{};
                    }
                    mi += w;
                }
            }
        }
    }

    return .{
        .vertices = try verts.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
    };
}

fn emitQuad(
    allocator: std.mem.Allocator,
    verts: *std.ArrayList(Vertex),
    indices: *std.ArrayList(u32),
    d: usize,
    u: usize,
    v: usize,
    plane: u32,
    i: usize,
    j: usize,
    w: usize,
    h: usize,
    cell: MaskCell,
) !void {
    var base = [3]u32{ 0, 0, 0 };
    base[d] = plane;
    base[u] = @intCast(i);
    base[v] = @intCast(j);
    const wq: u32 = @intCast(w);
    const hq: u32 = @intCast(h);

    // Four corners of the merged rectangle, spanning w along u and h along v.
    const corners = [4][3]u32{
        corner(base, u, v, 0, 0),
        corner(base, u, v, wq, 0),
        corner(base, u, v, wq, hq),
        corner(base, u, v, 0, hq),
    };

    const start: u32 = @intCast(verts.items.len);
    for (corners) |p| {
        try verts.append(allocator, mesh.pack(p[0], p[1], p[2], cell.face, cell.block));
    }
    // Two triangles: 0-1-2 and 0-2-3.
    try indices.appendSlice(allocator, &.{ start, start + 1, start + 2, start, start + 2, start + 3 });
}

fn corner(base: [3]u32, u: usize, v: usize, du: u32, dv: u32) [3]u32 {
    var p = base;
    p[u] += du;
    p[v] += dv;
    return p;
}

// --- tests -----------------------------------------------------------------

//region tests
const testing = std.testing;

test "empty chunk meshes to nothing" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();
    var m = try build(testing.allocator, &world, 0, 0, 0);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), m.vertices.len);
    try testing.expectEqual(@as(usize, 0), m.indices.len);
}

test "a lone block emits 6 unmergeable faces" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();
    try world.setBlock(8, 8, 8, .stone);
    var m = try build(testing.allocator, &world, 0, 0, 0);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6 * 4), m.vertices.len);
    try testing.expectEqual(@as(usize, 6 * 6), m.indices.len);
}

test "two adjacent blocks: shared faces culled, side faces merged" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();
    try world.setBlock(8, 8, 8, .stone);
    try world.setBlock(9, 8, 8, .stone);
    var m = try build(testing.allocator, &world, 0, 0, 0);
    defer m.deinit(testing.allocator);
    // +x and −x are single faces; top/bottom/front/back each merge across both
    // blocks into one quad → 6 quads total (down from 10 unmerged faces).
    try testing.expectEqual(@as(usize, 6 * 4), m.vertices.len);
}

test "a full 16x16 slab merges to 6 quads" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();
    var x: i32 = 0;
    while (x < size) : (x += 1) {
        var z: i32 = 0;
        while (z < size) : (z += 1) try world.setBlock(x, 0, z, .stone);
    }
    var m = try build(testing.allocator, &world, 0, 0, 0);
    defer m.deinit(testing.allocator);
    // Top + bottom (16×16 each) + four 16×1 side strips = 6 merged quads,
    // versus 576 faces unmerged. This is the whole point of greedy meshing.
    try testing.expectEqual(@as(usize, 6 * 4), m.vertices.len);
    try testing.expectEqual(@as(usize, 6 * 6), m.indices.len);
}

test "faces are culled against neighbouring chunks" {
    var world = World.init(testing.allocator, null);
    defer world.deinit();
    // Two blocks touching across the chunk-0 / chunk-1 seam.
    try world.setBlock(size - 1, 8, 8, .stone); // chunk 0, last column
    try world.setBlock(size, 8, 8, .stone); // chunk 1, first column
    var m = try build(testing.allocator, &world, 0, 0, 0);
    defer m.deinit(testing.allocator);
    // Chunk 0's block hides its +x face against chunk 1 → 5 faces, not 6.
    try testing.expectEqual(@as(usize, 5 * 4), m.vertices.len);
}
//endregion
