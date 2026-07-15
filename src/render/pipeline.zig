//! The graphics pipelines for the **deferred** renderer. Three of them, all set
//! up for **dynamic rendering** (no render passes) with dynamic viewport/scissor:
//!
//!   1. `initGeometry` — the G-buffer pass. Rasterises the greedy chunk mesh and
//!      writes albedo+AO and world-normal to two colour attachments, with depth
//!      testing. This is the only pass with a vertex buffer.
//!   2. `initFullscreen` — a screen-covering pass with no vertex input (the vertex
//!      shader synthesises a fullscreen triangle). Used for both the lighting pass
//!      (reads the G-buffer → one HDR colour target) and the TAA resolve (reads
//!      lit + history → swapchain + history). The colour-attachment formats and
//!      the fragment shader are parameters.
//!
//! Everything is single-sample: deferred shading replaces MSAA with TAA.

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;
const mesh = @import("mesh.zig");
const Vertex = mesh.Vertex;

/// Up to this many colour attachments in one pass (TAA writes 2: swapchain +
/// history). Bumped only if a future pass needs a wider G-buffer.
const max_color_attachments = 4;

pub const Pipeline = struct {
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,

    pub fn deinit(self: *Pipeline, ctx: *const Context) void {
        ctx.vkd.destroyPipeline(ctx.device, self.handle, null);
        ctx.vkd.destroyPipelineLayout(ctx.device, self.layout, null);
    }
};

/// The G-buffer geometry pipeline: packed-voxel vertex in, albedo+normal out,
/// depth-tested. `color_formats` are the two G-buffer colour formats (albedo,
/// normal); `depth_format` the depth attachment; `set_layout` binds the uniform
/// block + per-chunk origins storage buffer (same as the forward renderer).
pub fn initGeometry(
    ctx: *const Context,
    color_formats: []const vk.Format,
    depth_format: vk.Format,
    set_layout: vk.DescriptorSetLayout,
) !Pipeline {
    const vkd = ctx.vkd;
    const dev = ctx.device;
    const vert = try createShaderModule(vkd, dev, "gbuffer_vert");
    defer vkd.destroyShaderModule(dev, vert, null);
    const frag = try createShaderModule(vkd, dev, "gbuffer_frag");
    defer vkd.destroyShaderModule(dev, frag, null);

    const vertex_input = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = &.{Vertex.binding},
        .vertex_attribute_description_count = Vertex.attributes.len,
        .p_vertex_attribute_descriptions = &Vertex.attributes,
    };
    return build(ctx, .{
        .vert = vert,
        .frag = frag,
        .set_layout = set_layout,
        .vertex_input = &vertex_input,
        .color_formats = color_formats,
        .depth_format = depth_format,
        .depth_test = true,
    });
}

/// The avatar pipeline: draws the shared cube mesh (mesh.EntityVertex) into the
/// G-buffer, positioned/coloured per entity via an `EntityPush` push constant.
/// Same attachments + depth test as the geometry pass, so avatars are lit and
/// shadowed like the world (reusing gbuffer.frag).
pub fn initEntity(
    ctx: *const Context,
    color_formats: []const vk.Format,
    depth_format: vk.Format,
    set_layout: vk.DescriptorSetLayout,
) !Pipeline {
    const vkd = ctx.vkd;
    const dev = ctx.device;
    const vert = try createShaderModule(vkd, dev, "entity_vert");
    defer vkd.destroyShaderModule(dev, vert, null);
    const frag = try createShaderModule(vkd, dev, "gbuffer_frag");
    defer vkd.destroyShaderModule(dev, frag, null);

    const vertex_input = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = &.{mesh.EntityVertex.binding},
        .vertex_attribute_description_count = mesh.EntityVertex.attributes.len,
        .p_vertex_attribute_descriptions = &mesh.EntityVertex.attributes,
    };
    return build(ctx, .{
        .vert = vert,
        .frag = frag,
        .set_layout = set_layout,
        .vertex_input = &vertex_input,
        .color_formats = color_formats,
        .depth_format = depth_format,
        .depth_test = true,
        .push_constant_size = @sizeOf(mesh.EntityPush),
    });
}

/// A fullscreen post pass: no vertex input (the vertex shader builds the
/// triangle from `gl_VertexIndex`), no depth. `color_formats` lists the colour
/// attachments this pass writes (1 for lighting, 2 for TAA); `frag` names the
/// embedded fragment shader; `set_layout` binds the uniform block + sampled
/// inputs.
pub fn initFullscreen(
    ctx: *const Context,
    color_formats: []const vk.Format,
    set_layout: vk.DescriptorSetLayout,
    comptime frag_name: []const u8,
) !Pipeline {
    const vkd = ctx.vkd;
    const dev = ctx.device;
    const vert = try createShaderModule(vkd, dev, "fullscreen_vert");
    defer vkd.destroyShaderModule(dev, vert, null);
    const frag = try createShaderModule(vkd, dev, frag_name);
    defer vkd.destroyShaderModule(dev, frag, null);

    const empty_input = vk.PipelineVertexInputStateCreateInfo{};
    return build(ctx, .{
        .vert = vert,
        .frag = frag,
        .set_layout = set_layout,
        .vertex_input = &empty_input,
        .color_formats = color_formats,
        .depth_format = .undefined,
        .depth_test = false,
    });
}

const BuildParams = struct {
    vert: vk.ShaderModule,
    frag: vk.ShaderModule,
    set_layout: vk.DescriptorSetLayout,
    vertex_input: *const vk.PipelineVertexInputStateCreateInfo,
    color_formats: []const vk.Format,
    depth_format: vk.Format,
    depth_test: bool,
    push_constant_size: u32 = 0, // 0 = no push constants (vertex stage if > 0)
};

/// Shared pipeline construction. Most of this is boilerplate fixed-function
/// state; the per-pass variation is the shaders, vertex input, attachment
/// formats, and whether depth testing is on.
fn build(ctx: *const Context, p: BuildParams) !Pipeline {
    const vkd = ctx.vkd;
    const dev = ctx.device;
    std.debug.assert(p.color_formats.len <= max_color_attachments);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = p.vert, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = p.frag, .p_name = "main" },
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.Bool32.false,
    };
    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };
    const rasterization = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.Bool32.false,
        .rasterizer_discard_enable = vk.Bool32.false,
        .polygon_mode = .fill,
        .cull_mode = .{}, // don't cull — voxel faces are already outward-only
        .front_face = .clockwise,
        .depth_bias_enable = vk.Bool32.false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisample = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.Bool32.false,
        .min_sample_shading = 0,
        .alpha_to_coverage_enable = vk.Bool32.false,
        .alpha_to_one_enable = vk.Bool32.false,
    };

    // One (blend-disabled) attachment state per colour target.
    var blend_attachments: [max_color_attachments]vk.PipelineColorBlendAttachmentState = undefined;
    for (blend_attachments[0..p.color_formats.len]) |*ba| {
        ba.* = .{
            .blend_enable = vk.Bool32.false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
    }
    const color_blend = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.Bool32.false,
        .logic_op = .copy,
        .attachment_count = @intCast(p.color_formats.len),
        .p_attachments = &blend_attachments,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .depth_test_enable = if (p.depth_test) vk.Bool32.true else vk.Bool32.false,
        .depth_write_enable = if (p.depth_test) vk.Bool32.true else vk.Bool32.false,
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

    const push_ranges = [_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex_bit = true }, .offset = 0, .size = p.push_constant_size }};
    const layout = try vkd.createPipelineLayout(dev, &.{
        .set_layout_count = 1,
        .p_set_layouts = &.{p.set_layout},
        .push_constant_range_count = if (p.push_constant_size > 0) 1 else 0,
        .p_push_constant_ranges = &push_ranges,
    }, null);
    errdefer vkd.destroyPipelineLayout(dev, layout, null);

    // Dynamic rendering: declare the colour + depth formats instead of a render pass.
    var rendering_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = @intCast(p.color_formats.len),
        .p_color_attachment_formats = p.color_formats.ptr,
        .depth_attachment_format = p.depth_format,
        .stencil_attachment_format = .undefined,
    };

    var handle: vk.Pipeline = .null_handle;
    _ = try vkd.createGraphicsPipelines(dev, .null_handle, &.{.{
        .p_next = &rendering_info,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = p.vertex_input,
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

/// Wrap embedded SPIR-V bytes in a shader module. The bytes are copied into a
/// 4-byte-aligned array because Vulkan wants the code as `u32`s.
fn createShaderModule(vkd: vk.DeviceWrapper, dev: vk.Device, comptime name: []const u8) !vk.ShaderModule {
    const code align(@alignOf(u32)) = @embedFile(name).*;
    return vkd.createShaderModule(dev, &.{
        .code_size = code.len,
        .p_code = @ptrCast(&code),
    }, null);
}
