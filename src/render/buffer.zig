//! A small helper for GPU buffers backed by host-visible memory.
//!
//! "Host-visible, host-coherent" memory can be written directly by the CPU and
//! the writes are seen by the GPU without explicit flushing — the simplest
//! choice for small, frequently-updated data (uniforms) and for uploading small
//! static data (our cube). Larger/static data would eventually use device-local
//! memory + a staging copy, but that's an optimisation for later.

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;

pub const Buffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,
    /// Persistent CPU mapping (valid for the buffer's whole lifetime).
    mapped: [*]u8,

    /// Create a host-visible, host-coherent buffer of `size` bytes for `usage`,
    /// and leave it permanently mapped for easy CPU writes.
    pub fn init(ctx: *const Context, size: vk.DeviceSize, usage: vk.BufferUsageFlags) !Buffer {
        const vkd = ctx.vkd;
        const dev = ctx.device;

        const handle = try vkd.createBuffer(dev, &.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);
        errdefer vkd.destroyBuffer(dev, handle, null);

        const reqs = vkd.getBufferMemoryRequirements(dev, handle);
        const memory = try vkd.allocateMemory(dev, &.{
            .allocation_size = reqs.size,
            .memory_type_index = try findMemoryType(ctx, reqs.memory_type_bits, .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            }),
        }, null);
        errdefer vkd.freeMemory(dev, memory, null);

        try vkd.bindBufferMemory(dev, handle, memory, 0);

        const ptr = try vkd.mapMemory(dev, memory, 0, size, .{});
        return .{
            .handle = handle,
            .memory = memory,
            .size = size,
            .mapped = @ptrCast(ptr.?),
        };
    }

    /// Copy `bytes` into the buffer (coherent memory needs no flush).
    pub fn write(self: *Buffer, bytes: []const u8) void {
        @memcpy(self.mapped[0..bytes.len], bytes);
    }

    /// Copy `bytes` into the buffer starting at `byte_offset`.
    pub fn writeAt(self: *Buffer, byte_offset: usize, bytes: []const u8) void {
        @memcpy(self.mapped[byte_offset..][0..bytes.len], bytes);
    }

    pub fn deinit(self: *Buffer, ctx: *const Context) void {
        ctx.vkd.destroyBuffer(ctx.device, self.handle, null);
        ctx.vkd.freeMemory(ctx.device, self.memory, null);
    }
};

/// Memory for a transient (render-only) attachment. Prefers **lazily-allocated**
/// memory: on a tile-based GPU (Apple Silicon) such an attachment lives in tile
/// memory and never gets backed by RAM — near-free MSAA / depth. Falls back to
/// device-local where lazy allocation isn't offered. The image must be created
/// with `transient_attachment_bit` usage to use this.
pub fn findTransientMemoryType(ctx: *const Context, type_bits: u32) !u32 {
    return findMemoryType(ctx, type_bits, .{ .lazily_allocated_bit = true }) catch
        findMemoryType(ctx, type_bits, .{ .device_local_bit = true });
}

/// Find a memory type index that satisfies `type_bits` (from the buffer's
/// requirements) and has all the requested `props`.
pub fn findMemoryType(ctx: *const Context, type_bits: u32, props: vk.MemoryPropertyFlags) !u32 {
    const mem_props = ctx.vki.getPhysicalDeviceMemoryProperties(ctx.physical_device);
    const want: u32 = @bitCast(props);
    for (0..mem_props.memory_type_count) |i| {
        const suitable_type = (type_bits & (@as(u32, 1) << @intCast(i))) != 0;
        const has_props = (@as(u32, @bitCast(mem_props.memory_types[i].property_flags)) & want) == want;
        if (suitable_type and has_props) return @intCast(i);
    }
    return error.NoSuitableMemoryType;
}
