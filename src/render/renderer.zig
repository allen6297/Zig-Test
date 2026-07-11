//! The frame renderer: records and submits the per-frame GPU work, using
//! **dynamic rendering**. It now draws a 3D cube from a vertex buffer, with a
//! per-frame model-view-projection matrix (from the camera) supplied via a
//! uniform buffer, and depth testing so the cube's faces occlude correctly.
//!
//! The rhythm of a Vulkan frame:
//!   1. wait for this frame slot's fence (the GPU finished using it last time),
//!   2. acquire the next swapchain image (GPU signals a semaphore when ready),
//!   3. upload this frame's MVP, then record: transitions → clear+draw → present,
//!   4. submit (wait on "image available", signal "render finished", fence),
//!   5. present (wait on "render finished").

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;
const Swapchain = @import("swapchain.zig").Swapchain;
const Pipeline = @import("pipeline.zig").Pipeline;
const buffer = @import("buffer.zig");
const Buffer = buffer.Buffer;
const mesh = @import("mesh.zig");
const Vertex = mesh.Vertex;
const Mesh = @import("chunk_mesh.zig").Mesh;
const Pool = @import("mesh_pool.zig").Pool;
const Culler = @import("cull.zig").Culler;

/// A chunk's geometry as it lives in the pool: which slot and how many indices.
/// (Its origin lives in the slot-indexed `chunk_data` buffer, written on add.)
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
const depth_format: vk.Format = .d32_sfloat;
/// 4× MSAA. Colour and depth attachments must share this sample count.
const msaa_samples: vk.SampleCountFlags = .{ .@"4_bit" = true };

const Frame = struct {
    cmd: vk.CommandBuffer,
    image_available: vk.Semaphore,
    in_flight: vk.Fence,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    command_pool: vk.CommandPool,
    frames: [max_frames_in_flight]Frame,
    render_finished: []vk.Semaphore,
    current_frame: usize = 0,

    pipeline: Pipeline,

    // Geometry: all chunk meshes share one pooled vertex/index buffer; `chunks`
    // is the live set (added/removed as the world streams). Changes bump
    // `active_gen`; each frame lazily rebuilds its own command buffer to match
    // (see drawFrame) — no device-wide stall on residency change.
    pool: Pool,
    chunks: std.ArrayList(ChunkSlot),
    capacity: u32,
    dirty: bool,
    active_gen: u32,
    frame_gen: [max_frames_in_flight]u32,
    pending_free: std.ArrayList(PendingFree),
    /// Scratch command list, rebuilt per frame (sized to capacity).
    scratch_commands: []vk.DrawIndexedIndirectCommand,
    uniform_buffers: [max_frames_in_flight]Buffer,
    set_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [max_frames_in_flight]vk.DescriptorSet,

    // Indirect drawing: per-chunk origins (read as gl_InstanceIndex) + a GPU
    // frustum culler that owns the per-frame indirect command buffers.
    chunk_data_buffer: Buffer,
    culler: Culler,

    // Shared depth buffer (window isn't resizable, so one is enough).
    depth_image: vk.Image,
    depth_memory: vk.DeviceMemory,
    depth_view: vk.ImageView,

    // Multisampled colour target. We render into this at `msaa_samples` and
    // resolve it down into the single-sample swapchain image at end-of-pass.
    msaa_color_image: vk.Image,
    msaa_color_memory: vk.DeviceMemory,
    msaa_color_view: vk.ImageView,

    /// `capacity` = max simultaneously-resident chunks; `max_verts`/`max_indices`
    /// = per-chunk pool slot size. Starts with no chunks — the streamer adds them.
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

        //region descriptor layout + pipeline
        // Binding 0: per-frame uniforms (viewproj + light). Binding 1: per-chunk
        // origins storage buffer, indexed by gl_DrawID during indirect drawing.
        const set_layout = try vkd.createDescriptorSetLayout(dev, &.{
            .binding_count = 2,
            .p_bindings = &.{
                .{ .binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true } },
                .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true } },
            },
        }, null);
        errdefer vkd.destroyDescriptorSetLayout(dev, set_layout, null);

        const pipeline = try Pipeline.init(ctx, swapchain.format, depth_format, set_layout, msaa_samples);
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

        //region chunk geometry (pooled) + uniform buffers
        // Empty pool + buffers sized for `capacity` chunks; the streamer fills
        // slots at runtime. chunk_data (origins) and the culler's indirect
        // buffers are all capacity-sized and rebuilt in `commit`.
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

        // One uniform buffer per in-flight frame (updated every frame).
        var uniform_buffers: [max_frames_in_flight]Buffer = undefined;
        for (&uniform_buffers) |*ub| {
            ub.* = try Buffer.init(ctx, @sizeOf(mesh.Uniforms), .{ .uniform_buffer_bit = true });
        }
        //endregion

        //region descriptor pool + sets
        const descriptor_pool = try vkd.createDescriptorPool(dev, &.{
            .max_sets = max_frames_in_flight,
            .pool_size_count = 2,
            .p_pool_sizes = &.{
                .{ .type = .uniform_buffer, .descriptor_count = max_frames_in_flight },
                .{ .type = .storage_buffer, .descriptor_count = max_frames_in_flight },
            },
        }, null);
        errdefer vkd.destroyDescriptorPool(dev, descriptor_pool, null);

        const layouts = [_]vk.DescriptorSetLayout{set_layout} ** max_frames_in_flight;
        var descriptor_sets: [max_frames_in_flight]vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(dev, &.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = max_frames_in_flight,
            .p_set_layouts = &layouts,
        }, &descriptor_sets);

        // Each set points at its frame's uniform buffer (binding 0) and the shared
        // per-chunk origins storage buffer (binding 1). WHOLE_SIZE = rest of buffer.
        const cd_range = vk.WHOLE_SIZE;
        for (descriptor_sets, uniform_buffers) |set, ub| {
            vkd.updateDescriptorSets(dev, &.{
                .{
                    .dst_set = set,
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .uniform_buffer,
                    .p_buffer_info = &.{.{ .buffer = ub.handle, .offset = 0, .range = @sizeOf(mesh.Uniforms) }},
                    .p_image_info = &.{},
                    .p_texel_buffer_view = &.{},
                },
                .{
                    .dst_set = set,
                    .dst_binding = 1,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_buffer_info = &.{.{ .buffer = chunk_data_buffer.handle, .offset = 0, .range = cd_range }},
                    .p_image_info = &.{},
                    .p_texel_buffer_view = &.{},
                },
            }, null);
        }
        //endregion

        //region depth buffer
        // Depth is multisampled to match the MSAA colour target (Vulkan requires
        // colour and depth attachments to share a sample count).
        const depth_image = try vkd.createImage(dev, &.{
            .image_type = .@"2d",
            .format = depth_format,
            .extent = .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = msaa_samples,
            .tiling = .optimal,
            // Transient: contents never leave the tile (store_op = dont_care), so
            // on Apple Silicon this stays in tile memory and never hits RAM.
            .usage = .{ .depth_stencil_attachment_bit = true, .transient_attachment_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer vkd.destroyImage(dev, depth_image, null);

        const depth_reqs = vkd.getImageMemoryRequirements(dev, depth_image);
        const depth_memory = try vkd.allocateMemory(dev, &.{
            .allocation_size = depth_reqs.size,
            .memory_type_index = try buffer.findTransientMemoryType(ctx, depth_reqs.memory_type_bits),
        }, null);
        errdefer vkd.freeMemory(dev, depth_memory, null);
        try vkd.bindImageMemory(dev, depth_image, depth_memory, 0);

        const depth_view = try vkd.createImageView(dev, &.{
            .image = depth_image,
            .view_type = .@"2d",
            .format = depth_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        //endregion

        //region MSAA colour target
        // The multisampled colour image we actually render into; it's resolved
        // down to the swapchain image each frame. Same format as the swapchain.
        const msaa_color_image = try vkd.createImage(dev, &.{
            .image_type = .@"2d",
            .format = swapchain.format,
            .extent = .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = msaa_samples,
            .tiling = .optimal,
            // Transient: we resolve out of it (store_op = dont_care), so the 4×
            // samples stay in tile memory and never get written to RAM.
            .usage = .{ .color_attachment_bit = true, .transient_attachment_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer vkd.destroyImage(dev, msaa_color_image, null);

        const msaa_reqs = vkd.getImageMemoryRequirements(dev, msaa_color_image);
        const msaa_color_memory = try vkd.allocateMemory(dev, &.{
            .allocation_size = msaa_reqs.size,
            .memory_type_index = try buffer.findTransientMemoryType(ctx, msaa_reqs.memory_type_bits),
        }, null);
        errdefer vkd.freeMemory(dev, msaa_color_memory, null);
        try vkd.bindImageMemory(dev, msaa_color_image, msaa_color_memory, 0);

        const msaa_color_view = try vkd.createImageView(dev, &.{
            .image = msaa_color_image,
            .view_type = .@"2d",
            .format = swapchain.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        //endregion

        return .{
            .allocator = allocator,
            .command_pool = command_pool,
            .frames = frames,
            .render_finished = render_finished,
            .pipeline = pipeline,
            .pool = pool,
            .chunks = chunks,
            .capacity = capacity,
            .dirty = false,
            .active_gen = 1,
            .frame_gen = .{0} ** max_frames_in_flight,
            .pending_free = std.ArrayList(PendingFree).empty,
            .scratch_commands = scratch_commands,
            .chunk_data_buffer = chunk_data_buffer,
            .culler = culler,
            .uniform_buffers = uniform_buffers,
            .set_layout = set_layout,
            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,
            .depth_image = depth_image,
            .depth_memory = depth_memory,
            .depth_view = depth_view,
            .msaa_color_image = msaa_color_image,
            .msaa_color_memory = msaa_color_memory,
            .msaa_color_view = msaa_color_view,
        };
    }

    pub fn deinit(self: *Renderer, ctx: *const Context) void {
        const vkd = ctx.vkd;
        const dev = ctx.device;
        vkd.deviceWaitIdle(dev) catch {};

        vkd.destroyImageView(dev, self.msaa_color_view, null);
        vkd.destroyImage(dev, self.msaa_color_image, null);
        vkd.freeMemory(dev, self.msaa_color_memory, null);

        vkd.destroyImageView(dev, self.depth_view, null);
        vkd.destroyImage(dev, self.depth_image, null);
        vkd.freeMemory(dev, self.depth_memory, null);

        vkd.destroyDescriptorPool(dev, self.descriptor_pool, null);
        vkd.destroyDescriptorSetLayout(dev, self.set_layout, null);
        for (&self.uniform_buffers) |*ub| ub.deinit(ctx);
        self.culler.deinit(ctx);
        self.chunk_data_buffer.deinit(ctx);
        self.pool.deinit(ctx);
        self.chunks.deinit(self.allocator);
        self.pending_free.deinit(self.allocator);
        self.allocator.free(self.scratch_commands);

        self.pipeline.deinit(ctx);
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
    /// the pool is full or the mesh exceeds a slot's capacity. The origin is
    /// written to the slot's stable `chunk_data` entry immediately — safe because
    /// a free slot is referenced by no in-flight frame. Call `commit` after a
    /// batch of add/remove.
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

    /// Mark the active set changed. Cheap — no GPU work and no stall; each frame
    /// rebuilds its own command buffer lazily (see drawFrame).
    pub fn commit(self: *Renderer, ctx: *const Context) !void {
        _ = ctx;
        if (!self.dirty) return;
        self.active_gen +%= 1;
        self.dirty = false;
    }

    /// Rebuild this frame's indirect commands from the current active set. Called
    /// in drawFrame only after the frame's fence is waited, so writing its buffer
    /// is safe. Each command's `firstInstance` = its pool slot (how the shader
    /// finds the chunk's origin).
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

    /// Age the deferred-free list; release slots whose in-flight frames are done.
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

    /// Render and present one frame with the given per-frame uniforms and camera
    /// frustum `planes` (used by the GPU cull to skip off-screen chunks).
    pub fn drawFrame(self: *Renderer, ctx: *const Context, swapchain: *const Swapchain, uniforms: mesh.Uniforms, planes: [6][4]f32) !void {
        const vkd = ctx.vkd;
        const dev = ctx.device;
        const frame = self.frames[self.current_frame];

        _ = try vkd.waitForFences(dev, &.{frame.in_flight}, vk.Bool32.true, std.math.maxInt(u64));

        // This frame's previous GPU work is now done, so it's safe to: recycle
        // pool slots whose deferred-free window has elapsed, and rebuild this
        // frame's indirect commands if the resident set changed since it last ran.
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

        // Upload this frame's uniforms (coherent memory, no flush needed).
        var frame_uniforms = uniforms;
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
    }

    /// Record one frame: cull chunks on the GPU, then (in the render pass)
    /// clear + indirect-draw the world via dynamic rendering, and transition the
    /// colour image to a presentable layout.
    fn recordFrame(self: *Renderer, ctx: *const Context, cmd: vk.CommandBuffer, swapchain: *const Swapchain, image_index: u32, planes: [6][4]f32) !void {
        const vkd = ctx.vkd;
        try vkd.beginCommandBuffer(cmd, &.{});

        // GPU frustum cull first — must be outside the render pass. It rewrites
        // this frame's indirect commands (instanceCount 0/1) with a barrier so
        // the draw below sees the result.
        self.culler.dispatch(ctx, cmd, self.current_frame, planes);

        // MSAA colour target (what we render into): UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL.
        imageBarrier(vkd, cmd, self.msaa_color_image, .{
            .aspect = .{ .color_bit = true },
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .src_stage = .{ .top_of_pipe_bit = true },
            .dst_stage = .{ .color_attachment_output_bit = true },
            .src_access = .{},
            .dst_access = .{ .color_attachment_write_bit = true },
        });
        // Swapchain image (the resolve target): UNDEFINED -> COLOR_ATTACHMENT_OPTIMAL.
        imageBarrier(vkd, cmd, swapchain.images[image_index], .{
            .aspect = .{ .color_bit = true },
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .src_stage = .{ .top_of_pipe_bit = true },
            .dst_stage = .{ .color_attachment_output_bit = true },
            .src_access = .{},
            .dst_access = .{ .color_attachment_write_bit = true },
        });
        // Depth image: UNDEFINED -> DEPTH_ATTACHMENT_OPTIMAL (contents discarded).
        imageBarrier(vkd, cmd, self.depth_image, .{
            .aspect = .{ .depth_bit = true },
            .old_layout = .undefined,
            .new_layout = .depth_attachment_optimal,
            .src_stage = .{ .top_of_pipe_bit = true },
            .dst_stage = .{ .early_fragment_tests_bit = true },
            .src_access = .{},
            .dst_access = .{ .depth_stencil_attachment_write_bit = true },
        });

        // Render into the multisampled image and resolve (average the samples)
        // into the single-sample swapchain image at end-of-pass. `store_op` is
        // dont_care because only the resolved result is needed for present.
        const color_attachment = vk.RenderingAttachmentInfo{
            .image_view = self.msaa_color_view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{ .average_bit = true },
            .resolve_image_view = swapchain.image_views[image_index],
            .resolve_image_layout = .color_attachment_optimal,
            .load_op = .clear,
            .store_op = .dont_care,
            .clear_value = .{ .color = .{ .float_32 = .{ 0.01, 0.01, 0.03, 1.0 } } },
        };
        const depth_attachment = vk.RenderingAttachmentInfo{
            .image_view = self.depth_view,
            .image_layout = .depth_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .dont_care, // depth isn't needed after the frame
            .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };

        const rendering_info = vk.RenderingInfo{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = &.{color_attachment},
            .p_depth_attachment = &depth_attachment,
        };
        beginRendering(vkd, cmd, &rendering_info);

        vkd.cmdSetViewport(cmd, 0, &.{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(swapchain.extent.width),
            .height = @floatFromInt(swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        vkd.cmdSetScissor(cmd, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent }});
        vkd.cmdBindPipeline(cmd, .graphics, self.pipeline.handle);
        vkd.cmdBindDescriptorSets(cmd, .graphics, self.pipeline.layout, 0, &.{self.descriptor_sets[self.current_frame]}, null);

        // Everything is in shared buffers, so the whole world draws in a single
        // indirect call: one command per chunk, each pointing at its pool slot.
        // The shader reads each chunk's origin via gl_DrawID.
        vkd.cmdBindVertexBuffers(cmd, 0, &.{self.pool.vertex_buffer.handle}, &.{0});
        vkd.cmdBindIndexBuffer(cmd, self.pool.index_buffer.handle, 0, .uint32);
        vkd.cmdDrawIndexedIndirect(cmd, self.culler.indirectBuffer(self.current_frame), 0, self.culler.drawCount(self.current_frame), @sizeOf(vk.DrawIndexedIndirectCommand));

        endRendering(vkd, cmd);

        // Colour image: COLOR_ATTACHMENT_OPTIMAL -> PRESENT_SRC_KHR.
        imageBarrier(vkd, cmd, swapchain.images[image_index], .{
            .aspect = .{ .color_bit = true },
            .old_layout = .color_attachment_optimal,
            .new_layout = .present_src_khr,
            .src_stage = .{ .color_attachment_output_bit = true },
            .dst_stage = .{ .bottom_of_pipe_bit = true },
            .src_access = .{ .color_attachment_write_bit = true },
            .dst_access = .{},
        });

        try vkd.endCommandBuffer(cmd);
    }
};

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
