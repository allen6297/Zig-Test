//! The swapchain: the set of images we render into and hand to the window system
//! for display. This is the bridge between "we have a device" and "pixels show
//! up on screen."
//!
//! Building one is a series of negotiations with the surface:
//!   - which pixel **format** / color space to use,
//!   - which **present mode** (how frames are queued/shown — vsync, etc.),
//!   - the image **extent** (size, usually the window's pixel size),
//!   - how many images to buffer.
//! Then we create the swapchain and an "image view" for each image (a view is
//! how shaders/attachments actually reference an image).

const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vulkan.zig").Context;

pub const Swapchain = struct {
    allocator: std.mem.Allocator,
    handle: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,
    images: []vk.Image,
    image_views: []vk.ImageView,

    /// Create a swapchain sized to `desired_extent` (typically the window's
    /// pixel size). Borrows the device/surface/queues from `ctx`.
    pub fn init(ctx: *const Context, desired_extent: vk.Extent2D) !Swapchain {
        const allocator = ctx.allocator;
        const pdev = ctx.physical_device;
        const surface = ctx.surface;

        const caps = try ctx.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(pdev, surface);
        const surface_format = try chooseFormat(ctx, allocator);
        const present_mode = try choosePresentMode(ctx, allocator);
        const extent = chooseExtent(caps, desired_extent);

        // Ask for one more than the minimum so we're less likely to wait on the
        // driver. Respect the maximum (0 means "no maximum").
        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0 and image_count > caps.max_image_count) {
            image_count = caps.max_image_count;
        }

        // If graphics and present are different families, let both access the
        // images (concurrent); otherwise exclusive is faster.
        const families = ctx.queue_families;
        const indices = [_]u32{ families.graphics, families.present };
        const concurrent = families.graphics != families.present;

        const handle = try ctx.vkd.createSwapchainKHR(ctx.device, &.{
            .surface = surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = if (concurrent) .concurrent else .exclusive,
            .queue_family_index_count = if (concurrent) 2 else 0,
            .p_queue_family_indices = if (concurrent) &indices else null,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.Bool32.true,
        }, null);
        errdefer ctx.vkd.destroySwapchainKHR(ctx.device, handle, null);

        const images = try ctx.vkd.getSwapchainImagesAllocKHR(ctx.device, handle, allocator);
        errdefer allocator.free(images);

        const image_views = try createImageViews(ctx, images, surface_format.format);

        return .{
            .allocator = allocator,
            .handle = handle,
            .format = surface_format.format,
            .extent = extent,
            .images = images,
            .image_views = image_views,
        };
    }

    pub fn deinit(self: *Swapchain, ctx: *const Context) void {
        for (self.image_views) |view| ctx.vkd.destroyImageView(ctx.device, view, null);
        self.allocator.free(self.image_views);
        self.allocator.free(self.images);
        ctx.vkd.destroySwapchainKHR(ctx.device, self.handle, null);
    }
};

//region selection helpers
/// Prefer 32-bit BGRA sRGB, the most common and correctly color-managed choice.
/// Fall back to whatever the surface lists first (there's always at least one).
fn chooseFormat(ctx: *const Context, allocator: std.mem.Allocator) !vk.SurfaceFormatKHR {
    const formats = try ctx.vki.getPhysicalDeviceSurfaceFormatsAllocKHR(ctx.physical_device, ctx.surface, allocator);
    defer allocator.free(formats);
    for (formats) |f| {
        if (f.format == .b8g8r8a8_srgb and f.color_space == .srgb_nonlinear_khr) return f;
    }
    return formats[0];
}

/// Prefer mailbox (low-latency triple buffering) if available; otherwise FIFO,
/// which is the only mode guaranteed to exist (standard vsync).
fn choosePresentMode(ctx: *const Context, allocator: std.mem.Allocator) !vk.PresentModeKHR {
    const modes = try ctx.vki.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.physical_device, ctx.surface, allocator);
    defer allocator.free(modes);
    for (modes) |m| {
        if (m == .mailbox_khr) return m;
    }
    return .fifo_khr;
}

/// The surface usually dictates the extent (`current_extent`). When it defers to
/// us (width == 0xFFFFFFFF), use our desired size clamped to the allowed range.
fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR, desired: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    return .{
        .width = std.math.clamp(desired.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(desired.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

/// One image view per swapchain image — a plain 2D color view of the whole image.
fn createImageViews(ctx: *const Context, images: []vk.Image, format: vk.Format) ![]vk.ImageView {
    const views = try ctx.allocator.alloc(vk.ImageView, images.len);
    errdefer ctx.allocator.free(views);

    var created: usize = 0;
    errdefer for (views[0..created]) |v| ctx.vkd.destroyImageView(ctx.device, v, null);

    for (images, 0..) |image, i| {
        views[i] = try ctx.vkd.createImageView(ctx.device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        created = i + 1;
    }
    return views;
}
//endregion
