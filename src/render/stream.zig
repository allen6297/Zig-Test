//! Chunk streaming: keep the chunks near the camera resident on the GPU, load
//! new ones as the camera moves, and unload far ones. Runs only when the camera
//! crosses into a new chunk, so the per-frame cost is ~zero.
//!
//! Residency (`coord → pool slot`) is tracked here; the actual GPU work goes
//! through the renderer's `addChunk`/`removeChunkBySlot`/`commit` API and the
//! pool's slot recycling. The world generates + caches chunk blocks on demand.

const std = @import("std");
const zig_test = @import("zig_test");
const World = zig_test.world.World;
const Coord = zig_test.world.Coord;
const Vec3 = zig_test.math.Vec3;
const chunk_size = zig_test.chunk.size;
const chunkMesh = @import("chunk_mesh.zig");
const Renderer = @import("renderer.zig").Renderer;
const Context = @import("vulkan.zig").Context;

/// Sentinel slot for a resident-but-empty (all-air) chunk: tracked so we don't
/// re-mesh it every time, but it holds no GPU slot.
const empty_slot: u32 = std.math.maxInt(u32);
/// Sentinel for a chunk that's queued to load but not meshed yet.
const pending_slot: u32 = std.math.maxInt(u32) - 1;
/// Max chunks generated + meshed + uploaded per frame — spreads the work so a
/// boundary crossing doesn't stall on a whole ring of chunks at once. Lower =
/// smoother but slower to fill in. (Threaded meshing would remove this cost from
/// the frame entirely — a future step.)
const load_budget = 4;

pub const Stream = struct {
    allocator: std.mem.Allocator,
    world: *World,
    renderer: *Renderer,
    /// Horizontal load radius, in chunks.
    radius: i32,
    /// Inclusive vertical chunk range.
    y_min: i32,
    y_max: i32,
    resident: std.AutoHashMap(Coord, u32),
    /// Coords queued to load, drained a few per frame (`load_budget`).
    load_queue: std.ArrayList(Coord),
    center: Coord,
    initialized: bool,

    pub fn init(allocator: std.mem.Allocator, world: *World, renderer: *Renderer, radius: i32, y_min: i32, y_max: i32) Stream {
        return .{
            .allocator = allocator,
            .world = world,
            .renderer = renderer,
            .radius = radius,
            .y_min = y_min,
            .y_max = y_max,
            .resident = std.AutoHashMap(Coord, u32).init(allocator),
            .load_queue = std.ArrayList(Coord).empty,
            .center = .{ .x = 0, .y = 0, .z = 0 },
            .initialized = false,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.resident.deinit();
        self.load_queue.deinit(self.allocator);
    }

    /// Update residency for the current camera position. On a chunk-boundary
    /// crossing it (cheaply) recomputes what should load/unload; every frame it
    /// drains a bounded number of queued loads so work is spread out, never a hitch.
    pub fn update(self: *Stream, ctx: *const Context, cam_pos: Vec3) !void {
        const center = Coord{
            .x = @divFloor(@as(i32, @intFromFloat(cam_pos.x)), chunk_size),
            .y = 0,
            .z = @divFloor(@as(i32, @intFromFloat(cam_pos.z)), chunk_size),
        };
        if (!self.initialized or center.x != self.center.x or center.z != self.center.z) {
            self.center = center;
            self.initialized = true;
            try self.unloadFar(center);
            try self.enqueueNear(center);
            self.world.trim(center, self.radius + 1, self.y_min - 1, self.y_max + 1);
        }

        try self.drainQueue();
        try self.renderer.commit(ctx); // no-op unless something changed
    }

    fn unloadFar(self: *Stream, center: Coord) !void {
        var to_remove = std.ArrayList(Coord).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.resident.keyIterator();
        while (it.next()) |coord| {
            if (!self.inRange(coord.*, center)) try to_remove.append(self.allocator, coord.*);
        }
        for (to_remove.items) |coord| {
            const slot = self.resident.get(coord).?;
            if (slot != empty_slot and slot != pending_slot) self.renderer.removeChunkBySlot(slot);
            _ = self.resident.remove(coord); // a pending coord's queue entry goes stale (skipped at drain)
        }
    }

    /// Queue every in-range chunk that isn't already resident/pending.
    fn enqueueNear(self: *Stream, center: Coord) !void {
        var cy = self.y_min;
        while (cy <= self.y_max) : (cy += 1) {
            var cz = center.z - self.radius;
            while (cz <= center.z + self.radius) : (cz += 1) {
                var cx = center.x - self.radius;
                while (cx <= center.x + self.radius) : (cx += 1) {
                    const coord = Coord{ .x = cx, .y = cy, .z = cz };
                    if (self.resident.contains(coord)) continue;
                    try self.resident.put(coord, pending_slot);
                    try self.load_queue.append(self.allocator, coord);
                }
            }
        }
    }

    /// Generate + mesh + upload up to `load_budget` queued chunks this frame.
    fn drainQueue(self: *Stream) !void {
        var loaded: u32 = 0;
        while (loaded < load_budget and self.load_queue.items.len > 0) {
            const coord = self.load_queue.pop().?;
            // Skip stale entries (unloaded before we got to them, or superseded).
            if (self.resident.get(coord) != pending_slot) continue;

            try self.ensureForMesh(coord);
            var m = try chunkMesh.build(self.allocator, self.world, coord.x, coord.y, coord.z);
            defer m.deinit(self.allocator);
            loaded += 1;

            if (m.indices.len == 0) {
                try self.resident.put(coord, empty_slot);
                continue;
            }
            const origin = [3]f32{
                @floatFromInt(coord.x * chunk_size),
                @floatFromInt(coord.y * chunk_size),
                @floatFromInt(coord.z * chunk_size),
            };
            const slot = self.renderer.addChunk(m, origin) orelse {
                std.log.warn("chunk pool full or mesh too big; skipping chunk", .{});
                _ = self.resident.remove(coord);
                continue;
            };
            try self.resident.put(coord, slot);
        }
    }

    /// Ensure the chunk and its 6 face-neighbours are generated, so the mesher
    /// can cull faces against them correctly.
    fn ensureForMesh(self: *Stream, c: Coord) !void {
        _ = try self.world.ensure(c);
        _ = try self.world.ensure(.{ .x = c.x + 1, .y = c.y, .z = c.z });
        _ = try self.world.ensure(.{ .x = c.x - 1, .y = c.y, .z = c.z });
        _ = try self.world.ensure(.{ .x = c.x, .y = c.y + 1, .z = c.z });
        _ = try self.world.ensure(.{ .x = c.x, .y = c.y - 1, .z = c.z });
        _ = try self.world.ensure(.{ .x = c.x, .y = c.y, .z = c.z + 1 });
        _ = try self.world.ensure(.{ .x = c.x, .y = c.y, .z = c.z - 1 });
    }

    fn inRange(self: *const Stream, coord: Coord, center: Coord) bool {
        return @abs(coord.x - center.x) <= self.radius and
            @abs(coord.z - center.z) <= self.radius and
            coord.y >= self.y_min and coord.y <= self.y_max;
    }

    /// Number of chunks currently holding a GPU slot (for stats).
    pub fn residentCount(self: *const Stream) usize {
        return self.renderer.chunks.items.len;
    }
};
