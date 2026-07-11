//! A vertex/index **pool**: two big pre-allocated buffers carved into fixed-size
//! slots, with a free list. Chunk meshes live in slots instead of each owning a
//! buffer, so we make two GPU allocations total (not two per chunk) and bind the
//! buffers once per frame instead of once per chunk. It's also the prerequisite
//! for indirect drawing (all geometry must share a buffer).
//!
//! Fixed-size slots are the simplest scheme; they waste space when chunks vary in
//! size (internal fragmentation). A variable-size sub-allocator would be tighter,
//! but fixed slots + a free list is the textbook starting point and matches how
//! streaming (acquire on load, release on unload) will use it.

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;
const Buffer = @import("buffer.zig").Buffer;
const Vertex = @import("mesh.zig").Vertex;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: Buffer,
    index_buffer: Buffer,
    /// Capacity of one slot.
    max_verts: u32,
    max_indices: u32,
    /// Stack of currently-free slot indices.
    free: std.ArrayList(u32),

    pub fn init(
        ctx: *const Context,
        allocator: std.mem.Allocator,
        slot_count: u32,
        max_verts: u32,
        max_indices: u32,
    ) !Pool {
        var vertex_buffer = try Buffer.init(ctx, @sizeOf(Vertex) * max_verts * slot_count, .{ .vertex_buffer_bit = true });
        errdefer vertex_buffer.deinit(ctx);
        var index_buffer = try Buffer.init(ctx, @sizeOf(u32) * max_indices * slot_count, .{ .index_buffer_bit = true });
        errdefer index_buffer.deinit(ctx);

        var free = std.ArrayList(u32).empty;
        errdefer free.deinit(allocator);
        // Push in reverse so `acquire` hands out 0, 1, 2, … in order.
        var i = slot_count;
        while (i > 0) {
            i -= 1;
            try free.append(allocator, i);
        }

        return .{
            .allocator = allocator,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .max_verts = max_verts,
            .max_indices = max_indices,
            .free = free,
        };
    }

    pub fn deinit(self: *Pool, ctx: *const Context) void {
        self.vertex_buffer.deinit(ctx);
        self.index_buffer.deinit(ctx);
        self.free.deinit(self.allocator);
    }

    /// Claim a free slot, or null if the pool is full.
    pub fn acquire(self: *Pool) ?u32 {
        return self.free.pop();
    }

    /// Return a slot to the pool (for chunk unloading later).
    pub fn release(self: *Pool, slot: u32) !void {
        try self.free.append(self.allocator, slot);
    }

    /// Upload a chunk's geometry into `slot`. Indices are chunk-local (0-based);
    /// the draw uses `vertexOffset` to rebase them, so no rewriting is needed.
    pub fn write(self: *Pool, slot: u32, vertices: []const Vertex, indices: []const u32) void {
        std.debug.assert(vertices.len <= self.max_verts);
        std.debug.assert(indices.len <= self.max_indices);
        self.vertex_buffer.writeAt(slot * self.max_verts * @sizeOf(Vertex), std.mem.sliceAsBytes(vertices));
        self.index_buffer.writeAt(slot * self.max_indices * @sizeOf(u32), std.mem.sliceAsBytes(indices));
    }

    /// The value to pass as `cmdDrawIndexed`'s `vertex_offset` for `slot`.
    pub fn vertexOffset(self: *const Pool, slot: u32) i32 {
        return @intCast(slot * self.max_verts);
    }

    /// The value to pass as `cmdDrawIndexed`'s `first_index` for `slot`.
    pub fn firstIndex(self: *const Pool, slot: u32) u32 {
        return slot * self.max_indices;
    }
};
