//! The graphics pipeline: the big immutable object that ties the shader stages
//! together with all the fixed-function state (how to assemble primitives,
//! rasterise, blend, etc.). Most of it here is boilerplate set to sensible
//! defaults — the interesting bits are the shaders and that we configure it for
//! **dynamic rendering** (via `PipelineRenderingCreateInfo`) instead of a render
//! pass.
//!
//! Viewport and scissor are left *dynamic* (set each frame in the command
//! buffer) so the pipeline doesn't bake in the window size.

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;
const mesh = @import("mesh.zig");
const Vertex = mesh.Vertex;

pub const Pipeline = struct {
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,

    /// Build the pipeline. `color_format`/`depth_format` must match the render
    /// targets (dynamic rendering needs to know them), and `set_layout` is the
    /// descriptor set layout for the uniform buffer.
    pub fn init(
        ctx: *const Context,
        color_format: vk.Format,
        depth_format: vk.Format,
        set_layout: vk.DescriptorSetLayout,
        samples: vk.SampleCountFlags,
    ) !Pipeline {
        const vkd = ctx.vkd;
        const dev = ctx.device;

        // Compile-time-embedded SPIR-V (produced by the build's glslc step).
        const vert = try createShaderModule(vkd, dev, "triangle_vert");
        defer vkd.destroyShaderModule(dev, vert, null);
        const frag = try createShaderModule(vkd, dev, "triangle_frag");
        defer vkd.destroyShaderModule(dev, frag, null);

        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex_bit = true }, .module = vert, .p_name = "main" },
            .{ .stage = .{ .fragment_bit = true }, .module = frag, .p_name = "main" },
        };

        // Describe the vertex buffer layout to the pipeline (one binding, two
        // attributes: position and colour).
        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = &.{Vertex.binding},
            .vertex_attribute_description_count = Vertex.attributes.len,
            .p_vertex_attribute_descriptions = &Vertex.attributes,
        };
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.Bool32.false,
        };

        // Counts fixed at 1; the actual rectangles are set dynamically per frame.
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        };
        const rasterization = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.Bool32.false,
            .rasterizer_discard_enable = vk.Bool32.false,
            .polygon_mode = .fill,
            .cull_mode = .{}, // don't cull — keep it simple for now
            .front_face = .clockwise,
            .depth_bias_enable = vk.Bool32.false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };
        const multisample = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = samples,
            .sample_shading_enable = vk.Bool32.false,
            .min_sample_shading = 0,
            .alpha_to_coverage_enable = vk.Bool32.false,
            .alpha_to_one_enable = vk.Bool32.false,
        };
        const blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = vk.Bool32.false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
        const color_blend = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.Bool32.false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &.{blend_attachment},
            .blend_constants = .{ 0, 0, 0, 0 },
        };

        // Depth testing so nearer faces of the cube occlude farther ones.
        const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.Bool32.true,
            .depth_write_enable = vk.Bool32.true,
            .depth_compare_op = .less, // smaller depth = closer = wins
            .depth_bounds_test_enable = vk.Bool32.false,
            .stencil_test_enable = vk.Bool32.false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
        };

        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        // Layout binds our descriptor set (uniform buffer + per-chunk origins
        // storage buffer). Per-chunk data is indexed by gl_DrawID, so no push
        // constants are needed.
        const layout = try vkd.createPipelineLayout(dev, &.{
            .set_layout_count = 1,
            .p_set_layouts = &.{set_layout},
        }, null);
        errdefer vkd.destroyPipelineLayout(dev, layout, null);

        // Dynamic rendering: instead of a render pass, tell the pipeline the
        // colour and depth formats it will render into.
        var rendering_info = vk.PipelineRenderingCreateInfo{
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachment_formats = &.{color_format},
            .depth_attachment_format = depth_format,
            .stencil_attachment_format = .undefined,
        };

        var handle: vk.Pipeline = .null_handle;
        _ = try vkd.createGraphicsPipelines(dev, .null_handle, &.{.{
            .p_next = &rendering_info,
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterization,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = &depth_stencil,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic_state,
            .layout = layout,
            .subpass = 0,
            .base_pipeline_index = -1,
        }}, null, @ptrCast(&handle));
        errdefer vkd.destroyPipeline(dev, handle, null);

        return .{ .layout = layout, .handle = handle };
    }

    pub fn deinit(self: *Pipeline, ctx: *const Context) void {
        ctx.vkd.destroyPipeline(ctx.device, self.handle, null);
        ctx.vkd.destroyPipelineLayout(ctx.device, self.layout, null);
    }
};

/// Wrap embedded SPIR-V bytes in a shader module. The bytes are copied into a
/// 4-byte-aligned array because Vulkan wants the code as `u32`s.
fn createShaderModule(vkd: vk.DeviceWrapper, dev: vk.Device, comptime name: []const u8) !vk.ShaderModule {
    const code align(@alignOf(u32)) = @embedFile(name).*;
    return vkd.createShaderModule(dev, &.{
        .code_size = code.len,
        .p_code = @ptrCast(&code),
    }, null);
}
