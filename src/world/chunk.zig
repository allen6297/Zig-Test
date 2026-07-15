//! A chunk: a fixed cube of blocks, the basic unit of world storage.
//!
//! Everything is kept intentionally plain for milestone 1 — no meshing, no
//! rendering, just storage plus a couple of helpers you can print and test.

const std = @import("std");
const BlockId = @import("block.zig").BlockId;

/// Edge length of a chunk in blocks. 16 is the classic voxel choice: a power of
/// two (so index math is cheap) and small enough to load/unload many at once.
pub const size = 16;

/// Total number of blocks in a chunk. `comptime` so it is computed once, at
/// compile time, and usable as an array length.
pub const volume = size * size * size;

pub const Chunk = struct {
    /// Flat, dense storage. A flat array (rather than `[size][size][size]`) is
    /// friendlier to the CPU cache and trivial to iterate over in one loop.
    blocks: [volume]BlockId,

    /// A brand-new chunk full of air. Returned by value — a `Chunk` is a plain
    /// value type with no heap allocation of its own, so no allocator needed.
    pub fn initAir() Chunk {
        return .{ .blocks = [_]BlockId{.air} ** volume };
    }

    /// Convert 3D coordinates into an index into `blocks`.
    ///
    /// `x + y*size + z*size*size` is the standard row-major layout. Keeping this
    /// in one place means the ordering is defined exactly once.
    pub fn index(x: usize, y: usize, z: usize) usize {
        std.debug.assert(x < size and y < size and z < size);
        return x + y * size + z * size * size;
    }

    pub fn get(self: *const Chunk, x: usize, y: usize, z: usize) BlockId {
        return self.blocks[index(x, y, z)];
    }

    pub fn set(self: *Chunk, x: usize, y: usize, z: usize, block: BlockId) void {
        self.blocks[index(x, y, z)] = block;
    }

    /// Count blocks matching `block` — a tiny helper mostly useful for tests
    /// and debug output while there is nothing to render yet.
    pub fn count(self: *const Chunk, block: BlockId) usize {
        var n: usize = 0;
        for (self.blocks) |b| {
            if (b == block) n += 1;
        }
        return n;
    }
};

test "a fresh chunk is all air" {
    const chunk = Chunk.initAir();
    try std.testing.expectEqual(volume, chunk.count(.air));
}

test "set and get a block" {
    var chunk = Chunk.initAir();
    chunk.set(1, 2, 3, .stone);

    try std.testing.expectEqual(BlockId.stone, chunk.get(1, 2, 3));
    // Everything else is untouched.
    try std.testing.expectEqual(volume - 1, chunk.count(.air));
    try std.testing.expectEqual(@as(usize, 1), chunk.count(.stone));
}

test "index is unique for every coordinate" {
    // Walk every cell and make sure no two map to the same slot — cheap proof
    // the layout math is a bijection.
    var seen = [_]bool{false} ** volume;
    var z: usize = 0;
    while (z < size) : (z += 1) {
        var y: usize = 0;
        while (y < size) : (y += 1) {
            var x: usize = 0;
            while (x < size) : (x += 1) {
                const i = Chunk.index(x, y, z);
                try std.testing.expect(!seen[i]);
                seen[i] = true;
            }
        }
    }
}
