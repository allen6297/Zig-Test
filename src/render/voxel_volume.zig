//! A GPU voxel volume for raymarched shadows: a single R8 3D texture holding
//! per-voxel *solidity* (1 = solid, 0 = empty) for a box of world around the
//! player. The deferred lighting pass DDA-marches shadow rays through it (see
//! lighting.frag).
//!
//! Kept in sync with the CPU world: fully rebuilt when the box re-centres (the
//! player crosses a chunk), and a single texel is patched on a block edit. The
//! box is chunk-aligned, so a rebuild fills it chunk-by-chunk (one hashmap lookup
//! per chunk) rather than per-voxel.
//!
//! Uploads are **asynchronous**: a rebuild/edit only fills the host-visible
//! staging buffer and sets `dirty`; the renderer records the staging→image copy
//! into the frame's command buffer (`recordUpload`) before the lighting pass, so
//! there's no `queueWaitIdle` stall. The volume image is shared across in-flight
//! frames, so a copy on a dirty frame can overlap the other frame still sampling
//! it — a benign cross-frame hazard (at worst a one-frame partial-shadow glitch,
//! smoothed by TAA), the same class the renderer already tolerates elsewhere.

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const zt = @import("zig_test");
const World = zt.world.World;
const Coord = zt.world.Coord;
const chunk = zt.chunk;

// Volume size in voxels (= world units). Covers the streamed region (radius-6
// chunks ≈ 208 blocks wide, 3 chunks tall) with margin. 256·64·256 = 4 MiB.
pub const dim_x: u32 = 256;
pub const dim_y: u32 = 64;
pub const dim_z: u32 = 256;
const voxel_count = dim_x * dim_y * dim_z;
const cs = chunk.size; // 16

pub const VoxelVolume = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    staging: Buffer,
    layout: vk.ImageLayout,
    /// Set when the staging buffer has changes not yet copied to the image; the
    /// renderer records the copy on the next frame (see `recordUpload`).
    dirty: bool,
    /// World-space minimum corner of the box (chunk-aligned). Sentinel until the
    /// first `recenter`, so the first call always rebuilds.
    origin: [3]i32,

    pub fn init(ctx: *const Context) !VoxelVolume {
        const vkd = ctx.vkd;
        const dev = ctx.device;

        const image = try vkd.createImage(dev, &.{
            .image_type = .@"3d",
            .format = .r8_unorm,
            .extent = .{ .width = dim_x, .height = dim_y, .depth = dim_z },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .sampled_bit = true, .transfer_dst_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer vkd.destroyImage(dev, image, null);

        const reqs = vkd.getImageMemoryRequirements(dev, image);
        const memory = try vkd.allocateMemory(dev, &.{
            .allocation_size = reqs.size,
            .memory_type_index = try buffer.findMemoryType(ctx, reqs.memory_type_bits, .{ .device_local_bit = true }),
        }, null);
        errdefer vkd.freeMemory(dev, memory, null);
        try vkd.bindImageMemory(dev, image, memory, 0);

        const view = try vkd.createImageView(dev, &.{
            .image = image,
            .view_type = .@"3d",
            .format = .r8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }, null);
        errdefer vkd.destroyImageView(dev, view, null);

        var staging = try Buffer.init(ctx, voxel_count, .{ .transfer_src_bit = true });
        errdefer staging.deinit(ctx);

        var self = VoxelVolume{
            .image = image,
            .memory = memory,
            .view = view,
            .staging = staging,
            .layout = .undefined,
            .dirty = true, // frame 1 uploads the primed (all-empty) contents
            .origin = .{ std.math.minInt(i32), 0, std.math.minInt(i32) },
        };

        // Prime the staging buffer (all-empty); the first frame's `recordUpload`
        // gets it into a sampleable layout, and the first `recenter` fills it.
        @memset(self.staging.mapped[0..voxel_count], 0);
        return self;
    }

    pub fn deinit(self: *VoxelVolume, ctx: *const Context) void {
        ctx.vkd.destroyImageView(ctx.device, self.view, null);
        ctx.vkd.destroyImage(ctx.device, self.image, null);
        ctx.vkd.freeMemory(ctx.device, self.memory, null);
        self.staging.deinit(ctx);
    }

    /// Re-anchor the box on the player and rebuild. Rebuilds when the box moved to
    /// a new chunk, or when `force` is set (e.g. chunks streamed in at the same
    /// position). Returns true if a rebuild happened.
    pub fn recenter(self: *VoxelVolume, world: *World, pos: [3]f32, force: bool) bool {
        const pcx = @divFloor(@as(i32, @intFromFloat(@floor(pos[0]))), cs);
        const pcz = @divFloor(@as(i32, @intFromFloat(@floor(pos[2]))), cs);
        const half_x: i32 = @intCast(dim_x / cs / 2); // half the box width, in chunks
        const half_z: i32 = @intCast(dim_z / cs / 2);
        const new_origin = [3]i32{ (pcx - half_x) * cs, 0, (pcz - half_z) * cs };
        const moved = new_origin[0] != self.origin[0] or new_origin[2] != self.origin[2];
        if (!moved and !force) return false;
        self.origin = new_origin;
        self.rebuild(world);
        return true;
    }

    /// Refill the whole box from the world at the current origin (into staging);
    /// the copy to the image is deferred to `recordUpload`.
    fn rebuild(self: *VoxelVolume, world: *World) void {
        const ocx = @divFloor(self.origin[0], cs);
        const ocz = @divFloor(self.origin[2], cs);
        const buf = self.staging.mapped;

        var ccz: u32 = 0;
        while (ccz < dim_z / cs) : (ccz += 1) {
            var ccy: u32 = 0;
            while (ccy < dim_y / cs) : (ccy += 1) {
                var ccx: u32 = 0;
                while (ccx < dim_x / cs) : (ccx += 1) {
                    const coord = Coord{ .x = ocx + @as(i32, @intCast(ccx)), .y = @as(i32, @intCast(ccy)), .z = ocz + @as(i32, @intCast(ccz)) };
                    const maybe_chunk = world.chunks.get(coord);
                    var lz: u32 = 0;
                    while (lz < cs) : (lz += 1) {
                        var ly: u32 = 0;
                        while (ly < cs) : (ly += 1) {
                            var lx: u32 = 0;
                            while (lx < cs) : (lx += 1) {
                                const gx = ccx * cs + lx;
                                const gy = ccy * cs + ly;
                                const gz = ccz * cs + lz;
                                const solid = if (maybe_chunk) |ch| ch.get(lx, ly, lz).isSolid() else false;
                                buf[gx + gy * dim_x + gz * dim_x * dim_y] = if (solid) 255 else 0;
                            }
                        }
                    }
                }
            }
        }
        self.dirty = true;
    }

    /// Patch a single voxel's solidity (call after a block edit). No-op if the
    /// voxel is outside the current box. Marks the volume dirty; the whole staging
    /// buffer is re-copied on the next frame (edits are rare, so this is cheap).
    pub fn setVoxel(self: *VoxelVolume, world: *World, wx: i32, wy: i32, wz: i32) void {
        const lx = wx - self.origin[0];
        const ly = wy - self.origin[1];
        const lz = wz - self.origin[2];
        if (lx < 0 or ly < 0 or lz < 0 or lx >= dim_x or ly >= dim_y or lz >= dim_z) return;
        const idx: usize = @intCast(lx + ly * @as(i32, dim_x) + lz * @as(i32, dim_x * dim_y));
        self.staging.mapped[idx] = if (world.blockAt(wx, wy, wz).isSolid()) 255 else 0;
        self.dirty = true;
    }

    /// If dirty, record a staging→image copy into `cmd` (called by the renderer at
    /// the start of a frame, outside any render pass). Transitions the image to
    /// TRANSFER_DST and back to SHADER_READ_ONLY, then clears `dirty`.
    pub fn recordUpload(self: *VoxelVolume, vkd: vk.DeviceWrapper, cmd: vk.CommandBuffer) void {
        if (!self.dirty) return;
        const src = layoutSrc(self.layout);
        barrier(vkd, cmd, self.image, self.layout, .transfer_dst_optimal, src.stage, .{ .transfer_bit = true }, src.access, .{ .transfer_write_bit = true });
        vkd.cmdCopyBufferToImage(cmd, self.staging.handle, self.image, .transfer_dst_optimal, &.{fullRegion()});
        barrier(vkd, cmd, self.image, .transfer_dst_optimal, .shader_read_only_optimal, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{ .transfer_write_bit = true }, .{ .shader_read_bit = true });
        self.layout = .shader_read_only_optimal;
        self.dirty = false;
    }
};

fn fullRegion() vk.BufferImageCopy {
    return .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = dim_x, .height = dim_y, .depth = dim_z },
    };
}

const Src = struct { stage: vk.PipelineStageFlags, access: vk.AccessFlags };
fn layoutSrc(old: vk.ImageLayout) Src {
    return switch (old) {
        .undefined => .{ .stage = .{ .top_of_pipe_bit = true }, .access = .{} },
        else => .{ .stage = .{ .fragment_shader_bit = true }, .access = .{ .shader_read_bit = true } },
    };
}

fn barrier(
    vkd: vk.DeviceWrapper,
    cmd: vk.CommandBuffer,
    image: vk.Image,
    old: vk.ImageLayout,
    new: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
    src_access: vk.AccessFlags,
    dst_access: vk.AccessFlags,
) void {
    vkd.cmdPipelineBarrier(cmd, src_stage, dst_stage, .{}, null, null, &.{.{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = old,
        .new_layout = new,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    }});
}
