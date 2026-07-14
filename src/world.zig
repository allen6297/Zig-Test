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

/// Player edits for one chunk, keyed by local block index (lx + ly*16 + lz*256).
/// Applied on top of generated terrain, so edits survive chunk eviction and can
/// be saved to disk. This is the world's *diff* from its deterministic gen.
const ChunkEdits = std.AutoHashMap(u16, BlockId);

fn localIndex(lx: usize, ly: usize, lz: usize) u16 {
    return @intCast(lx + ly * chunk_size + lz * chunk_size * chunk_size);
}

pub const World = struct {
    allocator: std.mem.Allocator,
    chunks: std.AutoHashMap(Coord, *Chunk),
    /// Persistent per-chunk edits (survive eviction; saved/loaded to disk).
    edits: std.AutoHashMap(Coord, ChunkEdits),
    /// Fills a freshly-allocated chunk from its coordinate. Null → air chunks.
    generator: ?*const fn (Coord, *Chunk) void = null,

    pub fn init(allocator: std.mem.Allocator, generator: ?*const fn (Coord, *Chunk) void) World {
        return .{
            .allocator = allocator,
            .chunks = std.AutoHashMap(Coord, *Chunk).init(allocator),
            .edits = std.AutoHashMap(Coord, ChunkEdits).init(allocator),
            .generator = generator,
        };
    }

    pub fn deinit(self: *World) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |chunk| self.allocator.destroy(chunk.*);
        self.chunks.deinit();
        var eit = self.edits.valueIterator();
        while (eit.next()) |em| em.deinit();
        self.edits.deinit();
    }

    /// Generate (if needed) and return the chunk at a coordinate. Generated
    /// terrain has this chunk's saved edits re-applied on top.
    pub fn ensure(self: *World, coord: Coord) !*Chunk {
        const gop = try self.chunks.getOrPut(coord);
        if (!gop.found_existing) {
            const chunk = try self.allocator.create(Chunk);
            chunk.* = Chunk.initAir();
            if (self.generator) |gen| gen(coord, chunk);
            if (self.edits.get(coord)) |em| {
                var it = em.iterator();
                while (it.next()) |e| {
                    const idx = e.key_ptr.*;
                    chunk.set(idx % chunk_size, (idx / chunk_size) % chunk_size, idx / (chunk_size * chunk_size), e.value_ptr.*);
                }
            }
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

    /// Set a block at a global coordinate, generating its chunk if needed, and
    /// record it as a persistent edit.
    pub fn setBlock(self: *World, wx: i32, wy: i32, wz: i32, block: BlockId) !void {
        const coord = Coord{
            .x = @divFloor(wx, chunk_size),
            .y = @divFloor(wy, chunk_size),
            .z = @divFloor(wz, chunk_size),
        };
        const lx: usize = @intCast(@mod(wx, chunk_size));
        const ly: usize = @intCast(@mod(wy, chunk_size));
        const lz: usize = @intCast(@mod(wz, chunk_size));

        const chunk = try self.ensure(coord);
        chunk.set(lx, ly, lz, block);

        // Record the edit so it survives eviction and can be saved.
        const gop = try self.edits.getOrPut(coord);
        if (!gop.found_existing) gop.value_ptr.* = ChunkEdits.init(self.allocator);
        try gop.value_ptr.put(localIndex(lx, ly, lz), block);
    }

    /// Serialize all edits to a compact binary diff (caller frees). Cheap — only
    /// *changes* are stored; the deterministic generator reproduces the rest.
    /// Pure (no file I/O) so `World` stays independent of the platform layer;
    /// `main` writes the bytes to disk.
    pub fn serialize(self: *World, allocator: std.mem.Allocator) ![]u8 {
        var bytes = std.ArrayList(u8).empty;
        errdefer bytes.deinit(allocator);
        var cit = self.edits.iterator();
        while (cit.next()) |entry| {
            const coord = entry.key_ptr.*;
            const em = entry.value_ptr;
            try appendInt(&bytes, allocator, i32, coord.x);
            try appendInt(&bytes, allocator, i32, coord.y);
            try appendInt(&bytes, allocator, i32, coord.z);
            try appendInt(&bytes, allocator, u32, em.count());
            var it = em.iterator();
            while (it.next()) |e| {
                try appendInt(&bytes, allocator, u16, e.key_ptr.*);
                try appendInt(&bytes, allocator, u16, @intFromEnum(e.value_ptr.*));
            }
        }
        return bytes.toOwnedSlice(allocator);
    }

    /// Load edits from serialized bytes (from `serialize`).
    pub fn deserialize(self: *World, data: []const u8) !void {
        var i: usize = 0;
        while (i + 16 <= data.len) {
            const coord = Coord{
                .x = readInt(data, &i, i32),
                .y = readInt(data, &i, i32),
                .z = readInt(data, &i, i32),
            };
            const count = readInt(data, &i, u32);
            const gop = try self.edits.getOrPut(coord);
            if (!gop.found_existing) gop.value_ptr.* = ChunkEdits.init(self.allocator);
            var n: u32 = 0;
            while (n < count and i + 4 <= data.len) : (n += 1) {
                const idx = readInt(data, &i, u16);
                const block: BlockId = @enumFromInt(readInt(data, &i, u16));
                try gop.value_ptr.put(idx, block);
            }
        }
    }
};

fn appendInt(list: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try list.appendSlice(gpa, &buf);
}

fn readInt(data: []const u8, i: *usize, comptime T: type) T {
    const v = std.mem.readInt(T, data[i.*..][0..@sizeOf(T)], .little);
    i.* += @sizeOf(T);
    return v;
}

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

test "edits survive chunk eviction (regenerated with the edit)" {
    var world = World.init(std.testing.allocator, null); // null gen → air chunks
    defer world.deinit();
    try world.setBlock(5, 5, 5, .stone);
    world.evict(.{ .x = 0, .y = 0, .z = 0 }); // drop the cached chunk
    _ = try world.ensure(.{ .x = 0, .y = 0, .z = 0 }); // regenerate (air) + re-apply edit
    try std.testing.expectEqual(BlockId.stone, world.blockAt(5, 5, 5));
}

test "edits round-trip through serialize/deserialize" {
    const a = std.testing.allocator;
    var w1 = World.init(a, null);
    defer w1.deinit();
    try w1.setBlock(3, 4, 5, .dirt);
    try w1.setBlock(-1, 20, -33, .grass); // spans negative + multiple chunks
    const bytes = try w1.serialize(a);
    defer a.free(bytes);

    var w2 = World.init(a, null);
    defer w2.deinit();
    try w2.deserialize(bytes);
    // Generate the containing chunks so the loaded edits get applied.
    _ = try w2.ensure(.{ .x = 0, .y = 0, .z = 0 });
    _ = try w2.ensure(.{ .x = -1, .y = 1, .z = -3 });
    try std.testing.expectEqual(BlockId.dirt, w2.blockAt(3, 4, 5));
    try std.testing.expectEqual(BlockId.grass, w2.blockAt(-1, 20, -33));
}
