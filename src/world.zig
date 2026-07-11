//! An unbounded world: a cache of chunks keyed by chunk coordinate, generated on
//! demand. Streaming loads chunks near the camera and evicts far ones (see
//! src/stream.zig), so the world can be effectively infinite without holding it
//! all in memory.
//!
//! Chunks are heap-allocated (`*Chunk`) so their pointers stay stable in the map.
//! An optional `generator` fills a new chunk from its coordinate; with none, new
//! chunks are air (used by tests, which place blocks explicitly).

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const chunk_size = chunk_mod.size;
const BlockId = @import("block.zig").BlockId;

pub const Coord = struct { x: i32, y: i32, z: i32 };

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: std.AutoHashMap(Coord, *Chunk),
    /// Fills a freshly-allocated chunk from its coordinate. Null → air chunks.
    generator: ?*const fn (Coord, *Chunk) void = null,

    pub fn init(allocator: std.mem.Allocator, generator: ?*const fn (Coord, *Chunk) void) World {
        return .{
            .allocator = allocator,
            .chunks = std.AutoHashMap(Coord, *Chunk).init(allocator),
            .generator = generator,
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |chunk| self.allocator.destroy(chunk.*);
        self.chunks.deinit();
    }

    /// Generate (if needed) and return the chunk at a coordinate.
    pub fn ensure(self: *World, coord: Coord) !*Chunk {
        const gop = try self.chunks.getOrPut(coord);
        if (!gop.found_existing) {
            const chunk = try self.allocator.create(Chunk);
            chunk.* = Chunk.initAir();
            if (self.generator) |gen| gen(coord, chunk);
            gop.value_ptr.* = chunk;
        }
        return gop.value_ptr.*;
    }

    /// Free the cached chunk at a coordinate, if present.
    pub fn evict(self: *World, coord: Coord) void {
        if (self.chunks.fetchRemove(coord)) |kv| self.allocator.destroy(kv.value);
    }

    /// Evict cached chunks outside a box around `center` (horizontal radius
    /// `horiz`, vertical `y_lo..y_hi`), bounding memory as the camera moves.
    /// Best-effort — silently skips on allocation failure.
    pub fn trim(self: *World, center: Coord, horiz: i32, y_lo: i32, y_hi: i32) void {
        var to_evict = std.ArrayList(Coord).empty;
        defer to_evict.deinit(self.allocator);
        var it = self.chunks.keyIterator();
        while (it.next()) |coord| {
            const c = coord.*;
            if (@abs(c.x - center.x) > horiz or @abs(c.z - center.z) > horiz or c.y < y_lo or c.y > y_hi) {
                to_evict.append(self.allocator, c) catch return;
            }
        }
        for (to_evict.items) |c| self.evict(c);
    }

    pub fn isResident(self: *const World, coord: Coord) bool {
        return self.chunks.contains(coord);
    }

    /// The block at a global block coordinate, reading only *cached* chunks
    /// (air if the containing chunk isn't loaded). Const: the mesher calls this,
    /// and relies on the streamer having `ensure`d neighbours first.
    pub fn blockAt(self: *const World, wx: i32, wy: i32, wz: i32) BlockId {
        const coord = Coord{
            .x = @divFloor(wx, chunk_size),
            .y = @divFloor(wy, chunk_size),
            .z = @divFloor(wz, chunk_size),
        };
        const chunk = self.chunks.get(coord) orelse return .air;
        return chunk.get(
            @intCast(@mod(wx, chunk_size)),
            @intCast(@mod(wy, chunk_size)),
            @intCast(@mod(wz, chunk_size)),
        );
    }

    /// Set a block at a global coordinate, generating its chunk if needed.
    pub fn setBlock(self: *World, wx: i32, wy: i32, wz: i32, block: BlockId) !void {
        const chunk = try self.ensure(.{
            .x = @divFloor(wx, chunk_size),
            .y = @divFloor(wy, chunk_size),
            .z = @divFloor(wz, chunk_size),
        });
        chunk.set(
            @intCast(@mod(wx, chunk_size)),
            @intCast(@mod(wy, chunk_size)),
            @intCast(@mod(wz, chunk_size)),
            block,
        );
    }
};

test "blockAt reads across chunk boundaries and returns air outside" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();
    try world.setBlock(chunk_size - 1, 0, 0, .stone); // last column of chunk 0
    try world.setBlock(chunk_size, 0, 0, .dirt); // first column of chunk 1

    try std.testing.expectEqual(BlockId.stone, world.blockAt(chunk_size - 1, 0, 0));
    try std.testing.expectEqual(BlockId.dirt, world.blockAt(chunk_size, 0, 0));
    try std.testing.expectEqual(BlockId.air, world.blockAt(-1, 0, 0)); // unloaded → air
    try std.testing.expectEqual(BlockId.air, world.blockAt(9999, 0, 0)); // unloaded → air
}

test "evict frees a chunk" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();
    try world.setBlock(0, 0, 0, .stone);
    try std.testing.expect(world.isResident(.{ .x = 0, .y = 0, .z = 0 }));
    world.evict(.{ .x = 0, .y = 0, .z = 0 });
    try std.testing.expect(!world.isResident(.{ .x = 0, .y = 0, .z = 0 }));
}
