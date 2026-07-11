//! GPU frustum culling. Each frame, a compute shader tests every chunk's AABB
//! against the camera frustum and writes each chunk's indirect-draw
//! `instanceCount` to 1 (visible) or 0 (culled). The subsequent indirect draw
//! then skips culled chunks for free. This is the payoff of indirect drawing:
//! visibility is decided on the GPU without the CPU touching per-chunk state.
//!
//! The indirect command buffers are owned here (one per in-flight frame) because
//! the compute shader rewrites them every frame; the base commands are supplied
//! once at init and only `instanceCount` changes.

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;
const Buffer = @import("buffer.zig").Buffer;

/// Must match renderer's `max_frames_in_flight`.
const frames_in_flight = 2;
const local_size = 64;

/// std140 layout matching the compute shader's `Cull` uniform block.
const CullUniform = extern struct {
    planes: [6][4]f32,
    count: u32,
    _pad: [3]u32 = .{ 0, 0, 0 },
};

pub const Culler = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    set_layout: vk.DescriptorSetLayout,
    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [frames_in_flight]vk.DescriptorSet,
    cull_uniforms: [frames_in_flight]Buffer,
    /// Per-frame indirect buffers (storage for compute + source for the draw).
    indirect_buffers: [frames_in_flight]Buffer,
    /// Command count per frame — each frame's commands are rebuilt independently
    /// (as the resident set changes) so no global stall is needed.
    draw_counts: [frames_in_flight]u32,

    /// `capacity` is the maximum number of chunks (draw commands) that can be
    /// active at once; the indirect buffers are sized for it. `update` fills in
    /// the actual commands (starts empty: draw_count 0).
    pub fn init(
        ctx: *const Context,
        origins_buffer: vk.Buffer,
        capacity: u32,
    ) !Culler {
        const vkd = ctx.vkd;
        const dev = ctx.device;

        //region compute pipeline
        const shader = try createShaderModule(vkd, dev, "cull_comp");
        defer vkd.destroyShaderModule(dev, shader, null);

        // b0: origins (read), b1: commands (read/write), b2: cull uniform.
        const set_layout = try vkd.createDescriptorSetLayout(dev, &.{
            .binding_count = 3,
            .p_bindings = &.{
                .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true } },
                .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true } },
                .{ .binding = 2, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true } },
            },
        }, null);
        errdefer vkd.destroyDescriptorSetLayout(dev, set_layout, null);

        const layout = try vkd.createPipelineLayout(dev, &.{
            .set_layout_count = 1,
            .p_set_layouts = &.{set_layout},
        }, null);
        errdefer vkd.destroyPipelineLayout(dev, layout, null);

        var pipeline: vk.Pipeline = .null_handle;
        _ = try vkd.createComputePipelines(dev, .null_handle, &.{.{
            .stage = .{ .stage = .{ .compute_bit = true }, .module = shader, .p_name = "main" },
            .layout = layout,
            .base_pipeline_index = -1,
        }}, null, @ptrCast(&pipeline));
        errdefer vkd.destroyPipeline(dev, pipeline, null);
        //endregion

        //region per-frame buffers + descriptors
        var cull_uniforms: [frames_in_flight]Buffer = undefined;
        for (&cull_uniforms) |*ub| ub.* = try Buffer.init(ctx, @sizeOf(CullUniform), .{ .uniform_buffer_bit = true });

        var indirect_buffers: [frames_in_flight]Buffer = undefined;
        const indirect_bytes = @max(@sizeOf(vk.DrawIndexedIndirectCommand) * capacity, 1);
        for (&indirect_buffers) |*ib| {
            ib.* = try Buffer.init(ctx, indirect_bytes, .{ .storage_buffer_bit = true, .indirect_buffer_bit = true });
        }

        const descriptor_pool = try vkd.createDescriptorPool(dev, &.{
            .max_sets = frames_in_flight,
            .pool_size_count = 2,
            .p_pool_sizes = &.{
                .{ .type = .storage_buffer, .descriptor_count = 2 * frames_in_flight },
                .{ .type = .uniform_buffer, .descriptor_count = frames_in_flight },
            },
        }, null);
        errdefer vkd.destroyDescriptorPool(dev, descriptor_pool, null);

        const layouts = [_]vk.DescriptorSetLayout{set_layout} ** frames_in_flight;
        var descriptor_sets: [frames_in_flight]vk.DescriptorSet = undefined;
        try vkd.allocateDescriptorSets(dev, &.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = frames_in_flight,
            .p_set_layouts = &layouts,
        }, &descriptor_sets);

        for (descriptor_sets, 0..) |set, f| {
            // WHOLE_SIZE = "rest of the buffer", avoiding per-binding size math.
            vkd.updateDescriptorSets(dev, &.{
                bufferWrite(set, 0, .storage_buffer, origins_buffer),
                bufferWrite(set, 1, .storage_buffer, indirect_buffers[f].handle),
                bufferWrite(set, 2, .uniform_buffer, cull_uniforms[f].handle),
            }, null);
        }
        //endregion

        return .{
            .pipeline = pipeline,
            .layout = layout,
            .set_layout = set_layout,
            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,
            .cull_uniforms = cull_uniforms,
            .indirect_buffers = indirect_buffers,
            .draw_counts = .{0} ** frames_in_flight,
        };
    }

    pub fn deinit(self: *Culler, ctx: *const Context) void {
        const vkd = ctx.vkd;
        const dev = ctx.device;
        for (&self.indirect_buffers) |*ib| ib.deinit(ctx);
        for (&self.cull_uniforms) |*ub| ub.deinit(ctx);
        vkd.destroyDescriptorPool(dev, self.descriptor_pool, null);
        vkd.destroyDescriptorSetLayout(dev, self.set_layout, null);
        vkd.destroyPipelineLayout(dev, self.layout, null);
        vkd.destroyPipeline(dev, self.pipeline, null);
    }

    /// The per-frame indirect buffer the draw should read.
    pub fn indirectBuffer(self: *const Culler, frame: usize) vk.Buffer {
        return self.indirect_buffers[frame].handle;
    }

    pub fn drawCount(self: *const Culler, frame: usize) u32 {
        return self.draw_counts[frame];
    }

    /// Rewrite **one frame's** base draw commands. Only ever called after that
    /// frame's fence is waited (its GPU work is done), so no device-wide stall is
    /// needed — the other frame is untouched.
    pub fn updateFrame(self: *Culler, frame: usize, commands: []const vk.DrawIndexedIndirectCommand) void {
        self.draw_counts[frame] = @intCast(commands.len);
        self.indirect_buffers[frame].write(std.mem.sliceAsBytes(commands));
    }

    /// Record the cull dispatch for `frame` with the given frustum `planes`, then
    /// a barrier so the indirect draw sees the updated commands. Must run OUTSIDE
    /// a render pass (compute isn't allowed inside dynamic-rendering).
    pub fn dispatch(self: *Culler, ctx: *const Context, cmd: vk.CommandBuffer, frame: usize, planes: [6][4]f32) void {
        const vkd = ctx.vkd;
        const count = self.draw_counts[frame];
        if (count == 0) return; // nothing resident yet
        var uniform = CullUniform{ .planes = planes, .count = count };
        self.cull_uniforms[frame].write(std.mem.asBytes(&uniform));

        vkd.cmdBindPipeline(cmd, .compute, self.pipeline);
        vkd.cmdBindDescriptorSets(cmd, .compute, self.layout, 0, &.{self.descriptor_sets[frame]}, null);
        const groups = (count + local_size - 1) / local_size;
        vkd.cmdDispatch(cmd, groups, 1, 1);

        // Compute's writes to the indirect buffer must be visible to the draw's
        // indirect-command fetch.
        vkd.cmdPipelineBarrier(
            cmd,
            .{ .compute_shader_bit = true },
            .{ .draw_indirect_bit = true },
            .{},
            &.{.{ .src_access_mask = .{ .shader_write_bit = true }, .dst_access_mask = .{ .indirect_command_read_bit = true } }},
            null,
            null,
        );
    }
};

fn bufferWrite(set: vk.DescriptorSet, binding: u32, kind: vk.DescriptorType, buffer: vk.Buffer) vk.WriteDescriptorSet {
    return .{
        .dst_set = set,
        .dst_binding = binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = kind,
        .p_buffer_info = &.{.{ .buffer = buffer, .offset = 0, .range = vk.WHOLE_SIZE }},
        .p_image_info = &.{},
        .p_texel_buffer_view = &.{},
    };
}

fn createShaderModule(vkd: vk.DeviceWrapper, dev: vk.Device, comptime name: []const u8) !vk.ShaderModule {
    const code align(@alignOf(u32)) = @embedFile(name).*;
    return vkd.createShaderModule(dev, &.{ .code_size = code.len, .p_code = @ptrCast(&code) }, null);
}
