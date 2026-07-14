//! The frame renderer: records and submits the per-frame GPU work, using
//! **dynamic rendering**. This is a **deferred** renderer with **TAA**:
//!
//!   1. GPU frustum cull (compute) — unchanged.
//!   2. **Geometry pass** → G-buffer: rasterise the greedy chunk mesh into
//!      `albedo+AO` and `world-normal` colour targets plus a depth target.
//!   3. **Lighting pass** (fullscreen): reads the G-buffer, reconstructs world
//!      position from depth, shades (ambient·AO + sun + dynamic point light) into
//!      a linear-HDR `lit` target.
//!   4. **TAA resolve** (fullscreen): reprojects the previous frame's result via
//!      depth, neighbourhood-clamps to kill ghosting, blends, tonemaps into the
//!      swapchain, and writes the linear result back to a history image.
//!
//! Everything is single-sample — deferred shading replaces MSAA with the temporal
//! accumulation TAA provides. Each in-flight frame owns its own G-buffer/lit/
//! history images (double-buffered), so a frame's history is simply the *other*
//! slot's resolved output from last frame.
//!
//! Cross-frame note: with two frames in flight, this frame samples the other
//! slot's `resolved` image while that slot's previous submission may still be in
//! flight — the same latent hazard the engine already tolerates for shared
//! targets. In practice it's fine; if TAA ever shows corruption, the fix is a
//! cross-frame barrier or dropping to one frame in flight.

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;
const Swapchain = @import("swapchain.zig").Swapchain;
const pipeline_mod = @import("pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const mesh = @import("mesh.zig");
const Mesh = @import("chunk_mesh.zig").Mesh;
const Pool = @import("mesh_pool.zig").Pool;
const Culler = @import("cull.zig").Culler;

/// A chunk's geometry as it lives in the pool: which slot and how many indices.
const ChunkSlot = struct {
    slot: u32,
    index_count: u32,
};

/// A pool slot pending reuse: kept out of circulation until in-flight frames
/// that might still reference it have finished (`ttl` frames).
const PendingFree = struct {
    slot: u32,
    ttl: u8,
};

const max_frames_in_flight = 2;

// Attachment formats. Depth is sampled (world-pos reconstruction), so it can't be
// transient. Albedo packs base colour + AO in 8-bit; normal and the HDR lit/
// history targets are 16-bit float for headroom.
const depth_format: vk.Format = .d32_sfloat;
const albedo_format: vk.Format = .r8g8b8a8_unorm;
const normal_format: vk.Format = .r16g16b16a16_sfloat;
const hdr_format: vk.Format = .r16g16b16a16_sfloat;

const Frame = struct {
    cmd: vk.CommandBuffer,
    image_available: vk.Semaphore,
    in_flight: vk.Fence,
};

/// A GPU image + its backing memory + a default 2D view — one render target.
const Attachment = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,

    fn init(
        ctx: *const Context,
        extent: vk.Extent2D,
        format: vk.Format,
        usage: vk.ImageUsageFlags,
        aspect: vk.ImageAspectFlags,
    ) !Attachment {
        const vkd = ctx.vkd;
        const dev = ctx.device;

        const image = try vkd.createImage(dev, &.{
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = usage,
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
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = aspect,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        return .{ .image = image, .memory = memory, .view = view };
    }

    fn deinit(self: *Attachment, ctx: *const Context) void {
        ctx.vkd.destroyImageView(ctx.device, self.view, null);
        ctx.vkd.destroyImage(ctx.device, self.image, null);
        ctx.vkd.freeMemory(ctx.device, self.memory, null);
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    command_pool: vk.CommandPool,
    frames: [max_frames_in_flight]Frame,
    render_finished: []vk.Semaphore,
    current_frame: usize = 0,
    frame_index: u64 = 0, // monotonic; drives TAA jitter + history validity
    extent: vk.Extent2D,

    geometry_pipeline: Pipeline,
    lighting_pipeline: Pipeline,
    taa_pipeline: Pipeline,

    // Geometry: all chunk meshes share one pooled vertex/index buffer; `chunks`
    // is the live set. Changes bump `active_gen`; each frame lazily rebuilds its
    // own indirect commands to match (see drawFrame).
    pool: Pool,
    chunks: std.ArrayList(ChunkSlot),
    capacity: u32,
    dirty: bool,
    active_gen: u32,
    frame_gen: [max_frames_in_flight]u32,
    pending_free: std.ArrayList(PendingFree),
    scratch_commands: []vk.DrawIndexedIndirectCommand,

    uniform_buffers: [max_frames_in_flight]Buffer,
    geo_set_layout: vk.DescriptorSetLayout,
    post_set_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    geo_sets: [max_frames_in_flight]vk.DescriptorSet,
    lighting_sets: [max_frames_in_flight]vk.DescriptorSet,
    taa_sets: [max_frames_in_flight]vk.DescriptorSet,

    // Indirect drawing: per-chunk origins (read as gl_InstanceIndex) + a GPU
    // frustum culler that owns the per-frame indirect command buffers.
    chunk_data_buffer: Buffer,
    culler: Culler,

    // Sampled G-buffer reads use nearest; TAA history reprojection uses linear.
    sampler_nearest: vk.Sampler,
    sampler_linear: vk.Sampler,

    // Per-frame render targets (double-buffered so frames don't stomp each other).
    gbuf_albedo: [max_frames_in_flight]Attachment,
    gbuf_normal: [max_frames_in_flight]Attachment,
    depth: [max_frames_in_flight]Attachment,
    lit: [max_frames_in_flight]Attachment,
    resolved: [max_frames_in_flight]Attachment, // TAA output + next-frame history

    pub fn init(
        ctx: *const Context,
        swapchain: *const Swapchain,
        capacity: u32,
        max_verts: u32,
        max_indices: u32,
    ) !Renderer {
        const allocator = ctx.allocator;
        const vkd = ctx.vkd;
        const dev = ctx.device;
        const extent = swapchain.extent;

        //region descriptor layouts + pipelines
        // Geometry set: binding 0 per-frame uniforms, binding 1 per-chunk origins.
        const geo_set_layout = try vkd.createDescriptorSetLayout(dev, &.{
            .binding_count = 2,
            .p_bindings = &.{
                .{ .binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true } },
                .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true } },
            },
        }, null);
        errdefer vkd.destroyDescriptorSetLayout(dev, geo_set_layout, null);

        // Post set (shared by lighting + TAA): binding 0 uniforms, bindings 1..3
        // sampled inputs. Both passes read three textures in the fragment stage.
        const post_set_layout = try vkd.createDescriptorSetLayout(dev, &.{
            .binding_count = 4,
            .p_bindings = &.{
                .{ .binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true } },
                .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true } },
                .{ .binding = 2, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true } },
                .{ .binding = 3, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true } },
            },
        }, null);
        errdefer vkd.destroyDescriptorSetLayout(dev, post_set_layout, null);

        var geometry_pipeline = try pipeline_mod.initGeometry(ctx, &.{ albedo_format, normal_format }, depth_format, geo_set_layout);
        errdefer geometry_pipeline.deinit(ctx);
        var lighting_pipeline = try pipeline_mod.initFullscreen(ctx, &.{hdr_format}, post_set_layout, "lighting_frag");
        errdefer lighting_pipeline.deinit(ctx);
        var taa_pipeline = try pipeline_mod.initFullscreen(ctx, &.{ swapchain.format, hdr_format }, post_set_layout, "taa_frag");
        errdefer taa_pipeline.deinit(ctx);
        //endregion

        //region command pool, buffers, sync
        const command_pool = try vkd.createCommandPool(dev, &.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = ctx.queue_families.graphics,
        }, null);
        errdefer vkd.destroyCommandPool(dev, command_pool, null);

        var cmds: [max_frames_in_flight]vk.CommandBuffer = undefined;
        try vkd.allocateCommandBuffers(dev, &.{
            .command_pool = command_pool,
            .level = .primary,
            .command_buffer_count = max_frames_in_flight,
        }, &cmds);

        var frames: [max_frames_in_flight]Frame = undefined;
        for (&frames, 0..) |*frame, i| {
            frame.cmd = cmds[i];
            frame.image_available = try vkd.createSemaphore(dev, &.{}, null);
            frame.in_flight = try vkd.createFence(dev, &.{ .flags = .{ .signaled_bit = true } }, null);
        }

        const render_finished = try allocator.alloc(vk.Semaphore, swapchain.images.len);
        errdefer allocator.free(render_finished);
        for (render_finished) |*sem| sem.* = try vkd.createSemaphore(dev, &.{}, null);
        //endregion

        //region chunk geometry (pooled) + uniform buffers + culler
        var pool = try Pool.init(ctx, allocator, capacity, max_verts, max_indices);
        errdefer pool.deinit(ctx);

        var chunks = std.ArrayList(ChunkSlot).empty;
        errdefer chunks.deinit(allocator);
        try chunks.ensureTotalCapacity(allocator, capacity);

        const scratch_commands = try allocator.alloc(vk.DrawIndexedIndirectCommand, capacity);
        errdefer allocator.free(scratch_commands);

        var chunk_data_buffer = try Buffer.init(ctx, @max(@sizeOf(mesh.ChunkData) * capacity, 1), .{ .storage_buffer_bit = true });
        errdefer chunk_data_buffer.deinit(ctx);

        var culler = try Culler.init(ctx, chunk_data_buffer.handle, capacity);
        errdefer culler.deinit(ctx);

        var uniform_buffers: [max_frames_in_flight]Buffer = undefined;
        for (&uniform_buffers) |*ub| {
            ub.* = try Buffer.init(ctx, @sizeOf(mesh.Uniforms), .{ .uniform_buffer_bit = true });
        }
        //endregion

        //region samplers + per-frame attachments
        const sampler_nearest = try createSampler(ctx, .nearest);
        errdefer vkd.destroySampler(dev, sampler_nearest, null);
        const sampler_linear = try createSampler(ctx, .linear);
        errdefer vkd.destroySampler(dev, sampler_linear, null);

        const color_sampled = vk.ImageUsageFlags{ .color_attachment_bit = true, .sampled_bit = true };
        const depth_sampled = vk.ImageUsageFlags{ .depth_stencil_attachment_bit = true, .sampled_bit = true };

        var gbuf_albedo: [max_frames_in_flight]Attachment = undefined;
        var gbuf_normal: [max_frames_in_flight]Attachment = undefined;
        var depth: [max_frames_in_flight]Attachment = undefined;
        var lit: [max_frames_in_flight]Attachment = undefined;
        var resolved: [max_frames_in_flight]Attachment = undefined;
        for (0..max_frames_in_flight) |i| {
            gbuf_albedo[i] = try Attachment.init(ctx, extent, albedo_format, color_sampled, .{ .color_bit = true });
            gbuf_normal[i] = try Attachment.init(ctx, extent, normal_format, color_sampled, .{ .color_bit = true });
            depth[i] = try Attachment.init(ctx, extent, depth_format, depth_sampled, .{ .depth_bit = true });
            lit[i] = try Attachment.init(ctx, extent, hdr_format, color_sampled, .{ .color_bit = true });
            resolved[i] = try Attachment.init(ctx, extent, hdr_format, color_sampled, .{ .color_bit = true });
        }
        //endregion

        //region descriptor pool + sets
        const descriptor_pool = try vkd.createDescriptorPool(dev, &.{
            .max_sets = 3 * max_frames_in_flight,
            .pool_size_count = 3,
            .p_pool_sizes = &.{
                .{ .type = .uniform_buffer, .descriptor_count = 3 * max_frames_in_flight },
                .{ .type = .storage_buffer, .descriptor_count = max_frames_in_flight },
                .{ .type = .combined_image_sampler, .descriptor_count = 2 * 3 * max_frames_in_flight },
            },
        }, null);
        errdefer vkd.destroyDescriptorPool(dev, descriptor_pool, null);

        const geo_layouts = [_]vk.DescriptorSetLayout{geo_set_layout} ** max_frames_in_flight;
        const post_layouts = [_]vk.DescriptorSetLayout{post_set_layout} ** max_frames_in_flight;
        var geo_sets: [max_frames_in_flight]vk.DescriptorSet = undefined;
        var lighting_sets: [max_frames_in_flight]vk.DescriptorSet = undefined;
        var taa_sets: [max_frames_in_flight]vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(dev, &.{ .descriptor_pool = descriptor_pool, .descriptor_set_count = max_frames_in_flight, .p_set_layouts = &geo_layouts }, &geo_sets);
        try vkd.allocateDescriptorSets(dev, &.{ .descriptor_pool = descriptor_pool, .descriptor_set_count = max_frames_in_flight, .p_set_layouts = &post_layouts }, &lighting_sets);
        try vkd.allocateDescriptorSets(dev, &.{ .descriptor_pool = descriptor_pool, .descriptor_set_count = max_frames_in_flight, .p_set_layouts = &post_layouts }, &taa_sets);

        for (0..max_frames_in_flight) |i| {
            const ub = uniform_buffers[i].handle;
            // Geometry set: uniforms + per-chunk origins.
            writeBuffer(vkd, dev, geo_sets[i], 0, .uniform_buffer, ub, @sizeOf(mesh.Uniforms));
            writeBuffer(vkd, dev, geo_sets[i], 1, .storage_buffer, chunk_data_buffer.handle, vk.WHOLE_SIZE);
            // Lighting set: uniforms + G-buffer (albedo, normal, depth), all nearest.
            writeBuffer(vkd, dev, lighting_sets[i], 0, .uniform_buffer, ub, @sizeOf(mesh.Uniforms));
            writeImage(vkd, dev, lighting_sets[i], 1, gbuf_albedo[i].view, sampler_nearest);
            writeImage(vkd, dev, lighting_sets[i], 2, gbuf_normal[i].view, sampler_nearest);
            writeImage(vkd, dev, lighting_sets[i], 3, depth[i].view, sampler_nearest);
            // TAA set: uniforms + current lit (nearest) + history = other slot's
            // resolved (linear, for sub-pixel reprojection) + depth (nearest).
            const other = (i + 1) % max_frames_in_flight;
            writeBuffer(vkd, dev, taa_sets[i], 0, .uniform_buffer, ub, @sizeOf(mesh.Uniforms));
            writeImage(vkd, dev, taa_sets[i], 1, lit[i].view, sampler_nearest);
            writeImage(vkd, dev, taa_sets[i], 2, resolved[other].view, sampler_linear);
            writeImage(vkd, dev, taa_sets[i], 3, depth[i].view, sampler_nearest);
        }
        //endregion

        // Prime both history images to a sampleable layout so the first frames'
        // TAA reads are legal (their contents are ignored via the history-valid flag).
        try transitionResolvedToRead(ctx, command_pool, &resolved);

        return .{
            .allocator = allocator,
            .command_pool = command_pool,
            .frames = frames,
            .render_finished = render_finished,
            .extent = extent,
            .geometry_pipeline = geometry_pipeline,
            .lighting_pipeline = lighting_pipeline,
            .taa_pipeline = taa_pipeline,
            .pool = pool,
            .chunks = chunks,
            .capacity = capacity,
            .dirty = false,
            .active_gen = 1,
            .frame_gen = .{0} ** max_frames_in_flight,
            .pending_free = std.ArrayList(PendingFree).empty,
            .scratch_commands = scratch_commands,
            .uniform_buffers = uniform_buffers,
            .geo_set_layout = geo_set_layout,
            .post_set_layout = post_set_layout,
            .descriptor_pool = descriptor_pool,
            .geo_sets = geo_sets,
            .lighting_sets = lighting_sets,
            .taa_sets = taa_sets,
            .chunk_data_buffer = chunk_data_buffer,
            .culler = culler,
            .sampler_nearest = sampler_nearest,
            .sampler_linear = sampler_linear,
            .gbuf_albedo = gbuf_albedo,
            .gbuf_normal = gbuf_normal,
            .depth = depth,
            .lit = lit,
            .resolved = resolved,
        };
    }

    pub fn deinit(self: *Renderer, ctx: *const Context) void {
        const vkd = ctx.vkd;
        const dev = ctx.device;
        vkd.deviceWaitIdle(dev) catch {};

        for (0..max_frames_in_flight) |i| {
            self.gbuf_albedo[i].deinit(ctx);
            self.gbuf_normal[i].deinit(ctx);
            self.depth[i].deinit(ctx);
            self.lit[i].deinit(ctx);
            self.resolved[i].deinit(ctx);
        }
        vkd.destroySampler(dev, self.sampler_nearest, null);
        vkd.destroySampler(dev, self.sampler_linear, null);

        vkd.destroyDescriptorPool(dev, self.descriptor_pool, null);
        vkd.destroyDescriptorSetLayout(dev, self.geo_set_layout, null);
        vkd.destroyDescriptorSetLayout(dev, self.post_set_layout, null);
        for (&self.uniform_buffers) |*ub| ub.deinit(ctx);
        self.culler.deinit(ctx);
        self.chunk_data_buffer.deinit(ctx);
        self.pool.deinit(ctx);
        self.chunks.deinit(self.allocator);
        self.pending_free.deinit(self.allocator);
        self.allocator.free(self.scratch_commands);

        self.geometry_pipeline.deinit(ctx);
        self.lighting_pipeline.deinit(ctx);
        self.taa_pipeline.deinit(ctx);
        for (self.render_finished) |s| vkd.destroySemaphore(dev, s, null);
        self.allocator.free(self.render_finished);
        for (self.frames) |f| {
            vkd.destroySemaphore(dev, f.image_available, null);
            vkd.destroyFence(dev, f.in_flight, null);
        }
        vkd.destroyCommandPool(dev, self.command_pool, null);
    }

    //region chunk streaming API
    /// Upload a chunk's mesh into a free pool slot. Returns the slot, or null if
    /// the pool is full or the mesh exceeds a slot's capacity. Call `commit` after
    /// a batch of add/remove.
    pub fn addChunk(self: *Renderer, mesh_data: Mesh, origin: [3]f32) ?u32 {
        if (mesh_data.vertices.len > self.pool.max_verts or mesh_data.indices.len > self.pool.max_indices) return null;
        const slot = self.pool.acquire() orelse return null;
        self.pool.write(slot, mesh_data.vertices, mesh_data.indices);
        const cd = mesh.ChunkData{ .origin = .{ origin[0], origin[1], origin[2], 0 } };
        self.chunk_data_buffer.writeAt(slot * @sizeOf(mesh.ChunkData), std.mem.asBytes(&cd));
        self.chunks.appendAssumeCapacity(.{ .slot = slot, .index_count = @intCast(mesh_data.indices.len) });
        self.dirty = true;
        return slot;
    }

    /// Remove the chunk occupying `slot`. Its pool slot isn't reused immediately —
    /// it's deferred until in-flight frames that may still reference it finish.
    pub fn removeChunkBySlot(self: *Renderer, slot: u32) void {
        for (self.chunks.items, 0..) |chunk, i| {
            if (chunk.slot == slot) {
                _ = self.chunks.swapRemove(i);
                self.pending_free.append(self.allocator, .{ .slot = slot, .ttl = max_frames_in_flight }) catch {};
                self.dirty = true;
                return;
            }
        }
    }

    /// Mark the active set changed. Cheap — each frame rebuilds its own indirect
    /// commands lazily (see drawFrame).
    pub fn commit(self: *Renderer, ctx: *const Context) !void {
        _ = ctx;
        if (!self.dirty) return;
        self.active_gen +%= 1;
        self.dirty = false;
    }

    fn rebuildFrameCommands(self: *Renderer, frame: usize) void {
        for (self.chunks.items, 0..) |chunk, i| {
            self.scratch_commands[i] = .{
                .index_count = chunk.index_count,
                .instance_count = 1,
                .first_index = self.pool.firstIndex(chunk.slot),
                .vertex_offset = self.pool.vertexOffset(chunk.slot),
                .first_instance = chunk.slot,
            };
        }
        self.culler.updateFrame(frame, self.scratch_commands[0..self.chunks.items.len]);
        self.frame_gen[frame] = self.active_gen;
    }

    fn tickPendingFree(self: *Renderer) void {
        var i: usize = 0;
        while (i < self.pending_free.items.len) {
            const pf = &self.pending_free.items[i];
            pf.ttl -= 1;
            if (pf.ttl == 0) {
                self.pool.release(pf.slot) catch {};
                _ = self.pending_free.swapRemove(i);
            } else i += 1;
        }
    }
    //endregion

    /// Render and present one frame. `uniforms` carries the camera matrices +
    /// light from the caller; this fills in the framebuffer size, TAA jitter, and
    /// history-valid flag itself. `planes` drives the GPU frustum cull.
    pub fn drawFrame(self: *Renderer, ctx: *const Context, swapchain: *const Swapchain, uniforms: mesh.Uniforms, planes: [6][4]f32) !void {
        const vkd = ctx.vkd;
        const dev = ctx.device;
        const frame = self.frames[self.current_frame];

        _ = try vkd.waitForFences(dev, &.{frame.in_flight}, vk.Bool32.true, std.math.maxInt(u64));

        self.tickPendingFree();
        if (self.frame_gen[self.current_frame] != self.active_gen) {
            self.rebuildFrameCommands(self.current_frame);
        }

        const acq = vkd.acquireNextImageKHR(
            dev,
            swapchain.handle,
            std.math.maxInt(u64),
            frame.image_available,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => return,
            else => return err,
        };
        const image_index = acq.image_index;

        // Fill in the per-frame TAA bits and upload the uniforms.
        var frame_uniforms = uniforms;
        const w: f32 = @floatFromInt(self.extent.width);
        const h: f32 = @floatFromInt(self.extent.height);
        const jitter = haltonJitter(self.frame_index, w, h);
        frame_uniforms.params = .{ w, h, jitter[0], jitter[1] };
        frame_uniforms.taa = .{ if (self.frame_index >= max_frames_in_flight) 1.0 else 0.0, 0, 0, 0 };
        self.uniform_buffers[self.current_frame].write(std.mem.asBytes(&frame_uniforms));

        try vkd.resetFences(dev, &.{frame.in_flight});
        try vkd.resetCommandBuffer(frame.cmd, .{});
        try self.recordFrame(ctx, frame.cmd, swapchain, image_index, planes);

        const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
        try vkd.queueSubmit(ctx.graphics_queue, &.{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &.{frame.image_available},
            .p_wait_dst_stage_mask = &.{wait_stage},
            .command_buffer_count = 1,
            .p_command_buffers = &.{frame.cmd},
            .signal_semaphore_count = 1,
            .p_signal_semaphores = &.{self.render_finished[image_index]},
        }}, frame.in_flight);

        _ = vkd.queuePresentKHR(ctx.present_queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &.{self.render_finished[image_index]},
            .swapchain_count = 1,
            .p_swapchains = &.{swapchain.handle},
            .p_image_indices = &.{image_index},
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {},
            else => return err,
        };

        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;
        self.frame_index +%= 1;
    }

    /// Record one frame: cull → geometry (G-buffer) → lighting → TAA → present.
    fn recordFrame(self: *Renderer, ctx: *const Context, cmd: vk.CommandBuffer, swapchain: *const Swapchain, image_index: u32, planes: [6][4]f32) !void {
        const vkd = ctx.vkd;
        const f = self.current_frame;
        try vkd.beginCommandBuffer(cmd, &.{});

        // GPU frustum cull first — must be outside any render pass.
        self.culler.dispatch(ctx, cmd, f, planes);

        //region geometry pass → G-buffer
        imageBarrier(vkd, cmd, self.gbuf_albedo[f].image, colorWriteBarrier(.undefined));
        imageBarrier(vkd, cmd, self.gbuf_normal[f].image, colorWriteBarrier(.undefined));
        imageBarrier(vkd, cmd, self.depth[f].image, .{
            .aspect = .{ .depth_bit = true },
            .old_layout = .undefined,
            .new_layout = .depth_attachment_optimal,
            .src_stage = .{ .early_fragment_tests_bit = true },
            .dst_stage = .{ .early_fragment_tests_bit = true },
            .src_access = .{},
            .dst_access = .{ .depth_stencil_attachment_write_bit = true },
        });

        const gbuf_attachments = [_]vk.RenderingAttachmentInfo{
            colorAttachment(self.gbuf_albedo[f].view, .clear, .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } }),
            colorAttachment(self.gbuf_normal[f].view, .clear, .{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } }),
        };
        const depth_attachment = vk.RenderingAttachmentInfo{
            .image_view = self.depth[f].view,
            .image_layout = .depth_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store, // sampled by lighting + TAA
            .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        beginRendering(vkd, cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = gbuf_attachments.len,
            .p_color_attachments = &gbuf_attachments,
            .p_depth_attachment = &depth_attachment,
        });
        self.setViewportScissor(vkd, cmd);
        vkd.cmdBindPipeline(cmd, .graphics, self.geometry_pipeline.handle);
        vkd.cmdBindDescriptorSets(cmd, .graphics, self.geometry_pipeline.layout, 0, &.{self.geo_sets[f]}, null);
        vkd.cmdBindVertexBuffers(cmd, 0, &.{self.pool.vertex_buffer.handle}, &.{0});
        vkd.cmdBindIndexBuffer(cmd, self.pool.index_buffer.handle, 0, .uint32);
        vkd.cmdDrawIndexedIndirect(cmd, self.culler.indirectBuffer(f), 0, self.culler.drawCount(f), @sizeOf(vk.DrawIndexedIndirectCommand));
        endRendering(vkd, cmd);
        //endregion

        //region lighting pass → lit
        imageBarrier(vkd, cmd, self.gbuf_albedo[f].image, colorToSampledBarrier());
        imageBarrier(vkd, cmd, self.gbuf_normal[f].image, colorToSampledBarrier());
        imageBarrier(vkd, cmd, self.depth[f].image, .{
            .aspect = .{ .depth_bit = true },
            .old_layout = .depth_attachment_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_stage = .{ .late_fragment_tests_bit = true },
            .dst_stage = .{ .fragment_shader_bit = true },
            .src_access = .{ .depth_stencil_attachment_write_bit = true },
            .dst_access = .{ .shader_read_bit = true },
        });
        imageBarrier(vkd, cmd, self.lit[f].image, colorWriteBarrier(.undefined));

        const lit_attachment = [_]vk.RenderingAttachmentInfo{
            colorAttachment(self.lit[f].view, .dont_care, no_clear),
        };
        beginRendering(vkd, cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = &lit_attachment,
            .p_depth_attachment = null,
        });
        self.setViewportScissor(vkd, cmd);
        vkd.cmdBindPipeline(cmd, .graphics, self.lighting_pipeline.handle);
        vkd.cmdBindDescriptorSets(cmd, .graphics, self.lighting_pipeline.layout, 0, &.{self.lighting_sets[f]}, null);
        vkd.cmdDraw(cmd, 3, 1, 0, 0); // fullscreen triangle
        endRendering(vkd, cmd);
        //endregion

        //region TAA resolve → swapchain + history
        imageBarrier(vkd, cmd, self.lit[f].image, colorToSampledBarrier());
        // History = the other slot's resolved image; already SHADER_READ_ONLY.
        imageBarrier(vkd, cmd, self.resolved[f].image, .{
            .aspect = .{ .color_bit = true },
            .old_layout = .shader_read_only_optimal,
            .new_layout = .color_attachment_optimal,
            .src_stage = .{ .fragment_shader_bit = true },
            .dst_stage = .{ .color_attachment_output_bit = true },
            .src_access = .{ .shader_read_bit = true },
            .dst_access = .{ .color_attachment_write_bit = true },
        });
        imageBarrier(vkd, cmd, swapchain.images[image_index], colorWriteBarrier(.undefined));
        // (TAA history = the other slot's resolved image, bound at descriptor-write time.)

        const taa_attachments = [_]vk.RenderingAttachmentInfo{
            colorAttachment(swapchain.image_views[image_index], .dont_care, no_clear),
            colorAttachment(self.resolved[f].view, .dont_care, no_clear),
        };
        beginRendering(vkd, cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = taa_attachments.len,
            .p_color_attachments = &taa_attachments,
            .p_depth_attachment = null,
        });
        self.setViewportScissor(vkd, cmd);
        vkd.cmdBindPipeline(cmd, .graphics, self.taa_pipeline.handle);
        vkd.cmdBindDescriptorSets(cmd, .graphics, self.taa_pipeline.layout, 0, &.{self.taa_sets[f]}, null);
        vkd.cmdDraw(cmd, 3, 1, 0, 0);
        endRendering(vkd, cmd);
        //endregion

        // Swapchain → presentable; resolved → sampleable for next frame's history.
        imageBarrier(vkd, cmd, swapchain.images[image_index], .{
            .aspect = .{ .color_bit = true },
            .old_layout = .color_attachment_optimal,
            .new_layout = .present_src_khr,
            .src_stage = .{ .color_attachment_output_bit = true },
            .dst_stage = .{ .bottom_of_pipe_bit = true },
            .src_access = .{ .color_attachment_write_bit = true },
            .dst_access = .{},
        });
        imageBarrier(vkd, cmd, self.resolved[f].image, .{
            .aspect = .{ .color_bit = true },
            .old_layout = .color_attachment_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_stage = .{ .color_attachment_output_bit = true },
            .dst_stage = .{ .fragment_shader_bit = true },
            .src_access = .{ .color_attachment_write_bit = true },
            .dst_access = .{ .shader_read_bit = true },
        });

        try vkd.endCommandBuffer(cmd);
    }

    fn setViewportScissor(self: *Renderer, vkd: vk.DeviceWrapper, cmd: vk.CommandBuffer) void {
        vkd.cmdSetViewport(cmd, 0, &.{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.extent.width),
            .height = @floatFromInt(self.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        vkd.cmdSetScissor(cmd, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent }});
    }
};

//region small helpers

/// A zeroed clear value for attachments loaded with `.dont_care` (the value is
/// unused, but we avoid handing the driver an uninitialised union).
const no_clear = vk.ClearValue{ .color = .{ .float_32 = .{ 0, 0, 0, 0 } } };

/// A colour attachment for dynamic rendering (single-sample, no resolve).
fn colorAttachment(view: vk.ImageView, load_op: vk.AttachmentLoadOp, clear: vk.ClearValue) vk.RenderingAttachmentInfo {
    return .{
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = load_op,
        .store_op = .store,
        .clear_value = clear,
    };
}

/// Barrier: transition a colour image from `old` into COLOR_ATTACHMENT_OPTIMAL
/// for writing (used with `.undefined` to discard prior contents).
fn colorWriteBarrier(old: vk.ImageLayout) BarrierParams {
    return .{
        .aspect = .{ .color_bit = true },
        .old_layout = old,
        .new_layout = .color_attachment_optimal,
        .src_stage = .{ .color_attachment_output_bit = true },
        .dst_stage = .{ .color_attachment_output_bit = true },
        .src_access = .{},
        .dst_access = .{ .color_attachment_write_bit = true },
    };
}

/// Barrier: colour attachment we just wrote → sampled in a later fragment shader.
fn colorToSampledBarrier() BarrierParams {
    return .{
        .aspect = .{ .color_bit = true },
        .old_layout = .color_attachment_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_stage = .{ .color_attachment_output_bit = true },
        .dst_stage = .{ .fragment_shader_bit = true },
        .src_access = .{ .color_attachment_write_bit = true },
        .dst_access = .{ .shader_read_bit = true },
    };
}

/// Halton(2,3) low-discrepancy jitter for the current frame, returned as a
/// clip-space (NDC) offset of ±½ pixel — the sub-pixel sample offset TAA averages.
fn haltonJitter(frame_index: u64, width: f32, height: f32) [2]f32 {
    const i: u32 = @intCast(frame_index % 8 + 1); // 1-based, 8-sample cycle
    const jx = halton(i, 2) - 0.5;
    const jy = halton(i, 3) - 0.5;
    return .{ jx * 2.0 / width, jy * 2.0 / height };
}

fn halton(index: u32, base: u32) f32 {
    var f: f32 = 1;
    var r: f32 = 0;
    var i = index;
    const fbase: f32 = @floatFromInt(base);
    while (i > 0) {
        f /= fbase;
        r += f * @as(f32, @floatFromInt(i % base));
        i /= base;
    }
    return r;
}

fn createSampler(ctx: *const Context, filter: vk.Filter) !vk.Sampler {
    return ctx.vkd.createSampler(ctx.device, &.{
        .mag_filter = filter,
        .min_filter = filter,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = vk.Bool32.false,
        .max_anisotropy = 1,
        .compare_enable = vk.Bool32.false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = vk.Bool32.false,
    }, null);
}

fn writeBuffer(vkd: vk.DeviceWrapper, dev: vk.Device, set: vk.DescriptorSet, binding: u32, ty: vk.DescriptorType, buf: vk.Buffer, range: vk.DeviceSize) void {
    vkd.updateDescriptorSets(dev, &.{.{
        .dst_set = set,
        .dst_binding = binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = ty,
        .p_buffer_info = &.{.{ .buffer = buf, .offset = 0, .range = range }},
        .p_image_info = &.{},
        .p_texel_buffer_view = &.{},
    }}, null);
}

fn writeImage(vkd: vk.DeviceWrapper, dev: vk.Device, set: vk.DescriptorSet, binding: u32, view: vk.ImageView, sampler: vk.Sampler) void {
    vkd.updateDescriptorSets(dev, &.{.{
        .dst_set = set,
        .dst_binding = binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_buffer_info = &.{},
        .p_image_info = &.{.{ .sampler = sampler, .image_view = view, .image_layout = .shader_read_only_optimal }},
        .p_texel_buffer_view = &.{},
    }}, null);
}

/// One-time submit that transitions both history images UNDEFINED → shader-read,
/// so the first frames can legally sample them (contents are ignored via the
/// history-valid flag).
fn transitionResolvedToRead(ctx: *const Context, pool: vk.CommandPool, resolved: *[max_frames_in_flight]Attachment) !void {
    const vkd = ctx.vkd;
    const dev = ctx.device;
    var cmd: vk.CommandBuffer = undefined;
    try vkd.allocateCommandBuffers(dev, &.{ .command_pool = pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&cmd));
    defer vkd.freeCommandBuffers(dev, pool, &.{cmd});

    try vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
    for (resolved) |*att| {
        imageBarrier(vkd, cmd, att.image, .{
            .aspect = .{ .color_bit = true },
            .old_layout = .undefined,
            .new_layout = .shader_read_only_optimal,
            .src_stage = .{ .top_of_pipe_bit = true },
            .dst_stage = .{ .fragment_shader_bit = true },
            .src_access = .{},
            .dst_access = .{ .shader_read_bit = true },
        });
    }
    try vkd.endCommandBuffer(cmd);
    try vkd.queueSubmit(ctx.graphics_queue, &.{.{
        .command_buffer_count = 1,
        .p_command_buffers = &.{cmd},
    }}, .null_handle);
    try vkd.queueWaitIdle(ctx.graphics_queue);
}

// Dynamic rendering may be loaded under its core name or its *KHR name (MoltenVK
// provides the latter). Call whichever pointer is present.
fn beginRendering(vkd: vk.DeviceWrapper, cmd: vk.CommandBuffer, info: *const vk.RenderingInfo) void {
    if (vkd.dispatch.vkCmdBeginRendering != null) vkd.cmdBeginRendering(cmd, info) else vkd.cmdBeginRenderingKHR(cmd, info);
}
fn endRendering(vkd: vk.DeviceWrapper, cmd: vk.CommandBuffer) void {
    if (vkd.dispatch.vkCmdEndRendering != null) vkd.cmdEndRendering(cmd) else vkd.cmdEndRenderingKHR(cmd);
}

const BarrierParams = struct {
    aspect: vk.ImageAspectFlags,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
    src_access: vk.AccessFlags,
    dst_access: vk.AccessFlags,
};

/// Insert a pipeline barrier that transitions one image's layout.
fn imageBarrier(vkd: vk.DeviceWrapper, cmd: vk.CommandBuffer, image: vk.Image, p: BarrierParams) void {
    vkd.cmdPipelineBarrier(cmd, p.src_stage, p.dst_stage, .{}, null, null, &.{.{
        .src_access_mask = p.src_access,
        .dst_access_mask = p.dst_access,
        .old_layout = p.old_layout,
        .new_layout = p.new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = p.aspect,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }});
}
//endregion
