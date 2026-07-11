//! Block types and their static properties.
//!
//! Milestone 1 keeps this deliberately simple: a fixed set of blocks described
//! by a compile-time table. Later (milestone 5) this can be replaced by data
//! loaded from a file at runtime for modding.

const std = @import("std");

/// The identity of a block. Backed by `u16` so a chunk can store 4096 of these
/// cheaply, and so we have room to grow well past the handful defined here.
///
/// Using an enum (instead of a raw integer) means the compiler catches typos
/// and unhandled cases for us — a nice property to lean on while learning.
pub const BlockId = enum(u16) {
    air,
    stone,
    dirt,
    grass,
    sand,
    water,

    /// Look up the static properties for this block. Because `properties` is a
    /// compile-time table, this compiles down to a simple array index.
    pub fn info(self: BlockId) Properties {
        return table[@intFromEnum(self)];
    }

    /// A block you can see through / walk into. Meshing skips faces that touch
    /// a non-solid neighbour, so knowing this early matters for performance.
    pub fn isSolid(self: BlockId) bool {
        return self.info().solid;
    }
};

/// Static, per-block-type data. This is the row shape of the `table` below.
pub const Properties = struct {
    /// Human-readable name — handy for debug output and, later, mod files.
    name: []const u8,
    /// Whether the block blocks movement and occludes neighbouring faces.
    solid: bool,
};

/// The property table, indexed by `@intFromEnum(BlockId)`. The order here MUST
/// match the order the tags are declared in `BlockId` above.
///
/// `std.enums.directEnumArray` would enforce that automatically; we spell it
/// out as a plain array to keep the example approachable.
const table = [_]Properties{
    .{ .name = "air", .solid = false },
    .{ .name = "stone", .solid = true },
    .{ .name = "dirt", .solid = true },
    .{ .name = "grass", .solid = true },
    .{ .name = "sand", .solid = true },
    .{ .name = "water", .solid = false },
};

test "table lines up with the enum" {
    // If you add a BlockId tag but forget a table row (or vice versa), this
    // fails at test time instead of silently reading the wrong row.
    try std.testing.expectEqual(
        @typeInfo(BlockId).@"enum".fields.len,
        table.len,
    );
}

test "block properties" {
    try std.testing.expect(!BlockId.air.isSolid());
    try std.testing.expect(BlockId.stone.isSolid());
    try std.testing.expect(!BlockId.water.isSolid());
    try std.testing.expectEqualStrings("grass", BlockId.grass.info().name);
}
