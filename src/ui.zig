//! Dear ImGui debug overlay, via zig-gamedev's zgui (sdl3_vulkan backend).
//!
//! The overlay is drawn as a final dynamic-rendering pass over the swapchain
//! image, after the deferred renderer's TAA resolve (see renderer.zig). ImGui's
//! Vulkan backend is created for dynamic rendering (no render pass) and manages
//! its own descriptor pool. Input is fed from the SDL event loop in main.
//!
//! Flow each frame: `beginFrame` → build widgets (`debugWindow`) → the renderer
//! calls `record` inside the UI render pass to emit ImGui's draw commands.

const std = @import("std");
const vk = @import("vulkan");
const zgui = @import("zgui");
const Context = @import("render/vulkan.zig").Context;
const Swapchain = @import("render/swapchain.zig").Swapchain;

// ImGui's Vulkan backend loads its function pointers through a C callback with no
// user context of its own, so the loader reads these globals.
var g_gipa: vk.PfnGetInstanceProcAddr = undefined;
var g_instance: vk.Instance = .null_handle;
var g_ctx: *const Context = undefined;

fn vkLoader(name: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = user_data;
    if (g_gipa(g_instance, name)) |fp| {
        const p: *const anyopaque = @ptrCast(fp);
        return @constCast(p);
    }
    return null;
}

/// A vulkan-zig handle → ImGui's opaque `VkHandle`. Our handles are `enum(usize)`
/// wrapping the raw Vulkan pointer/id, so this just reinterprets the bits.
fn handle(h: anytype) zgui.backend.VkHandle {
    return @ptrFromInt(@intFromEnum(h));
}

/// Bring up ImGui with the Vulkan + SDL3 backends. `window` is the `SDL_Window*`.
pub fn init(allocator: std.mem.Allocator, ctx: *const Context, swapchain: *const Swapchain, window: *anyopaque) void {
    zgui.init(allocator);

    g_ctx = ctx;
    g_gipa = ctx.vkb.dispatch.vkGetInstanceProcAddr.?;
    g_instance = ctx.instance;
    _ = zgui.backend.loadFunctions(@bitCast(vk.API_VERSION_1_3), vkLoader, null);

    // Must outlive the init call: ImGui reads it while building its pipeline.
    const color_formats = [_]c_int{@intCast(@intFromEnum(swapchain.format))};
    const init_info = zgui.backend.ImGui_ImplVulkan_InitInfo{
        .api_version = @bitCast(vk.API_VERSION_1_3),
        .instance = handle(ctx.instance),
        .physical_device = handle(ctx.physical_device),
        .device = handle(ctx.device),
        .queue_family = ctx.queue_families.graphics,
        .queue = handle(ctx.graphics_queue),
        .descriptor_pool = null, // let ImGui create its own (DescriptorPoolSize below)
        .render_pass = null, // dynamic rendering
        .min_image_count = @intCast(swapchain.images.len),
        .image_count = @intCast(swapchain.images.len),
        .msaa_samples = 1, // VK_SAMPLE_COUNT_1_BIT
        .descriptor_pool_size = 16, // ≥ IMGUI_IMPL_VULKAN_MINIMUM_IMAGE_SAMPLER_POOL_SIZE (8)
        .use_dynamic_rendering = true,
        .pipeline_rendering_create_info = .{
            // ImGui asserts this is set (zgui defaults it to 0).
            .s_type = @intCast(@intFromEnum(vk.StructureType.pipeline_rendering_create_info)),
            .color_attachment_count = 1,
            .p_color_attachment_formats = &color_formats,
        },
    };
    zgui.backend.init(init_info, window);
}

pub fn deinit() void {
    // ImGui frees its Vulkan objects on shutdown; make sure the GPU is done first.
    g_ctx.vkd.deviceWaitIdle(g_ctx.device) catch {};
    zgui.backend.deinit();
    zgui.deinit();
}

/// Forward an SDL event to ImGui. Returns true if ImGui consumed it.
pub fn processEvent(event: *const anyopaque) bool {
    return zgui.backend.processEvent(event);
}

/// Start a new ImGui frame (call before building widgets). `w`/`h` = framebuffer size.
pub fn beginFrame(w: u32, h: u32) void {
    zgui.backend.newFrame(w, h);
}

/// Record ImGui's draw commands into `cmd` — called by the renderer inside the
/// UI render pass. Also finalises the ImGui frame (`gui.render` runs internally).
pub fn record(cmd: vk.CommandBuffer) void {
    zgui.backend.render(handle(cmd));
}

pub fn wantMouse() bool {
    return zgui.io.getWantCaptureMouse();
}

/// State the debug window reads (values) and writes (pointers) each frame.
pub const Debug = struct {
    fps: f32,
    cam_pos: [3]f32,
    yaw: f32,
    pitch: f32,
    chunks: usize,
    creative: *bool, // fly + noclip debug mode
    light_rgb: *[3]f32,
    light_intensity: *f32,
    time_of_day: *f32, // hours, 0..24
    animate_day: *bool,
    day_length: *f32, // real seconds per full day
    fog_density: *f32,
};

/// Build the debug window. Widgets that mutate state write through the pointers.
pub fn debugWindow(d: Debug) void {
    if (zgui.begin("Debug", .{})) {
        zgui.text("FPS: {d:.0}", .{d.fps});
        zgui.text("Pos: {d:.1}, {d:.1}, {d:.1}", .{ d.cam_pos[0], d.cam_pos[1], d.cam_pos[2] });
        zgui.text("Yaw: {d:.2}  Pitch: {d:.2}", .{ d.yaw, d.pitch });
        zgui.text("Chunks resident: {d}", .{d.chunks});
        zgui.separator();
        _ = zgui.checkbox("Creative (fly + noclip)", .{ .v = d.creative });
        zgui.separator();
        _ = zgui.colorEdit3("Light color", .{ .col = d.light_rgb });
        _ = zgui.sliderFloat("Light intensity", .{ .v = d.light_intensity, .min = 0, .max = 10 });
        zgui.separator();
        _ = zgui.checkbox("Animate day", .{ .v = d.animate_day });
        _ = zgui.sliderFloat("Time of day", .{ .v = d.time_of_day, .min = 0, .max = 24 });
        _ = zgui.sliderFloat("Day length (s)", .{ .v = d.day_length, .min = 10, .max = 600 });
        _ = zgui.sliderFloat("Fog", .{ .v = d.fog_density, .min = 0, .max = 0.03 });
        zgui.separator();
        zgui.textUnformatted("` (backtick): toggle mouse / UI    F: creative mode");
    }
    zgui.end();
}
