//! Vulkan context: instance, validation, surface, device, and queues.
//!
//! This module is deliberately **decoupled from SDL** (and any windowing
//! system). It receives the platform-specific bits it can't produce itself — a
//! `vkGetInstanceProcAddr` loader, the instance extensions the window needs, and
//! (later) a surface handle — and does everything else in pure Vulkan. Swap SDL
//! for anything else and this file doesn't change.
//!
//! Setup happens in two phases because of a chicken-and-egg ordering:
//!   1. `init`       — create the instance (needed before a surface can exist).
//!   2. `initDevice` — given a surface (created by the platform layer from our
//!                     instance), pick a GPU and create the logical device.
//!
//! Platform note: on macOS, Vulkan runs through MoltenVK, a "portable"
//! (non-conformant) implementation. Instance creation opts in via
//! `VK_KHR_portability_enumeration`, and the device enables
//! `VK_KHR_portability_subset` — both gated on the target OS / availability so
//! other platforms are unaffected.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

const validation_layer_name: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
const want_validation = builtin.mode == .Debug;
const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

/// Indices of the queue families we need. They are often the same family, but
/// the spec doesn't guarantee it, so we track both.
pub const QueueFamilies = struct {
    graphics: u32,
    present: u32,
};

pub const Context = struct {
    allocator: std.mem.Allocator,

    // Instance-level (phase 1)
    vkb: vk.BaseWrapper,
    instance: vk.Instance,
    vki: vk.InstanceWrapper,
    debug_messenger: vk.DebugUtilsMessengerEXT,

    // Device-level (phase 2) — `.null_handle` until `initDevice` runs.
    surface: vk.SurfaceKHR = .null_handle,
    physical_device: vk.PhysicalDevice = .null_handle,
    physical_device_props: vk.PhysicalDeviceProperties = undefined,
    device: vk.Device = .null_handle,
    vkd: vk.DeviceWrapper = undefined,
    queue_families: QueueFamilies = undefined,
    graphics_queue: vk.Queue = .null_handle,
    present_queue: vk.Queue = .null_handle,

    //region Phase 1: instance
    pub fn init(
        allocator: std.mem.Allocator,
        get_proc_addr: vk.PfnGetInstanceProcAddr,
        surface_extensions: []const [*:0]const u8,
    ) !Context {
        const vkb = vk.BaseWrapper.load(get_proc_addr);

        // Query support up front; requesting a missing layer/extension makes
        // instance creation fail. This also keeps us portable — the portability
        // extension is a loader feature that may not be present everywhere.
        const avail_exts = try vkb.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
        defer allocator.free(avail_exts);

        const has_debug_utils = extensionListed(avail_exts, vk.extensions.ext_debug_utils.name);
        const enable_validation = want_validation and has_debug_utils and
            try validationLayerAvailable(vkb, allocator);

        var extensions = std.ArrayList([*:0]const u8).empty;
        defer extensions.deinit(allocator);
        try extensions.appendSlice(allocator, surface_extensions);
        if (enable_validation) {
            try extensions.append(allocator, vk.extensions.ext_debug_utils.name);
        }
        var flags: vk.InstanceCreateFlags = .{};
        if (is_apple and extensionListed(avail_exts, vk.extensions.khr_portability_enumeration.name)) {
            try extensions.append(allocator, vk.extensions.khr_portability_enumeration.name);
            flags.enumerate_portability_bit_khr = true;
        }

        const app_info = vk.ApplicationInfo{
            .p_application_name = "zig voxel test",
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .p_engine_name = "zig-test",
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_1),
        };
        const layers: []const [*:0]const u8 =
            if (enable_validation) &.{validation_layer_name} else &.{};

        const instance = try vkb.createInstance(&.{
            .flags = flags,
            .p_application_info = &app_info,
            .enabled_layer_count = @intCast(layers.len),
            .pp_enabled_layer_names = layers.ptr,
            .enabled_extension_count = @intCast(extensions.items.len),
            .pp_enabled_extension_names = extensions.items.ptr,
        }, null);

        const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
        errdefer vki.destroyInstance(instance, null);

        const debug_messenger = if (enable_validation)
            try vki.createDebugUtilsMessengerEXT(instance, &debugMessengerInfo(), null)
        else
            .null_handle;

        return .{
            .allocator = allocator,
            .vkb = vkb,
            .instance = instance,
            .vki = vki,
            .debug_messenger = debug_messenger,
        };
    }
    //endregion

    //region Phase 2: surface, device, queues
    /// Given a `surface` (created by the platform layer from `self.instance`),
    /// pick a suitable GPU and create the logical device and its queues. Takes
    /// ownership of `surface` — it is destroyed in `deinit`.
    pub fn initDevice(self: *Context, surface: vk.SurfaceKHR) !void {
        self.surface = surface;

        const picked = try self.pickPhysicalDevice(surface);
        self.physical_device = picked.device;
        self.queue_families = picked.families;
        self.physical_device_props = self.vki.getPhysicalDeviceProperties(picked.device);

        // One DeviceQueueCreateInfo per *unique* family. All queues get the same
        // priority; the pointer must outlive the create call, so keep it local.
        const priority = [_]f32{1.0};
        var queue_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        var queue_count: u32 = 1;
        queue_infos[0] = .{
            .queue_family_index = picked.families.graphics,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        };
        if (picked.families.present != picked.families.graphics) {
            queue_infos[1] = .{
                .queue_family_index = picked.families.present,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            };
            queue_count = 2;
        }

        // Device extensions: the swapchain (to present to the window) plus, on
        // Apple, the portability subset MoltenVK requires.
        var dev_exts = std.ArrayList([*:0]const u8).empty;
        defer dev_exts.deinit(self.allocator);
        try dev_exts.append(self.allocator, vk.extensions.khr_swapchain.name);
        const avail = try self.vki.enumerateDeviceExtensionPropertiesAlloc(picked.device, null, self.allocator);
        defer self.allocator.free(avail);
        if (is_apple and extensionListed(avail, vk.extensions.khr_portability_subset.name)) {
            try dev_exts.append(self.allocator, vk.extensions.khr_portability_subset.name);
        }
        // Dynamic rendering (Vulkan 1.3 core; the `VK_KHR_dynamic_rendering`
        // extension before that). We use it instead of render passes/framebuffers.
        // MoltenVK exposes it as the extension even though it reports 1.3, so we
        // enable the extension whenever it's advertised — the renderer then calls
        // whichever function pointer (core or *KHR) actually loaded.
        if (extensionListed(avail, vk.extensions.khr_dynamic_rendering.name)) {
            try dev_exts.append(self.allocator, vk.extensions.khr_dynamic_rendering.name);
        }

        // Dynamic rendering, requested via the pNext chain.
        var dynamic_rendering = vk.PhysicalDeviceDynamicRenderingFeatures{
            .dynamic_rendering = vk.Bool32.true,
        };
        // Core features for indirect drawing:
        //   - `multiDrawIndirect`: one indirect call issues many draws (per chunk).
        //   - `drawIndirectFirstInstance`: lets each draw set a non-zero
        //     `firstInstance`, which we use as the per-chunk index via
        //     `gl_InstanceIndex`. (We index by instance rather than `gl_DrawID`
        //     because MoltenVK's Metal backend can't translate the DrawIndex
        //     builtin — the `shaderDrawParameters` feature reports true but the
        //     shader fails to compile.)
        const features = vk.PhysicalDeviceFeatures{
            .multi_draw_indirect = vk.Bool32.true,
            .draw_indirect_first_instance = vk.Bool32.true,
        };

        const device = try self.vki.createDevice(picked.device, &.{
            .p_next = &dynamic_rendering,
            .queue_create_info_count = queue_count,
            .p_queue_create_infos = &queue_infos,
            .enabled_extension_count = @intCast(dev_exts.items.len),
            .pp_enabled_extension_names = dev_exts.items.ptr,
            .p_enabled_features = &features,
        }, null);

        self.vkd = vk.DeviceWrapper.load(device, self.vki.dispatch.vkGetDeviceProcAddr.?);
        self.device = device;
        self.graphics_queue = self.vkd.getDeviceQueue(device, picked.families.graphics, 0);
        self.present_queue = self.vkd.getDeviceQueue(device, picked.families.present, 0);
    }

    const PickedDevice = struct { device: vk.PhysicalDevice, families: QueueFamilies };

    /// Choose the best GPU that can both render and present to `surface`.
    fn pickPhysicalDevice(self: *Context, surface: vk.SurfaceKHR) !PickedDevice {
        const devices = try self.vki.enumeratePhysicalDevicesAlloc(self.instance, self.allocator);
        defer self.allocator.free(devices);

        var best: ?PickedDevice = null;
        var best_score: u32 = 0;
        for (devices) |device| {
            const families = try self.findQueueFamilies(device, surface) orelse continue;
            if (!try self.supportsSwapchain(device)) continue;

            const props = self.vki.getPhysicalDeviceProperties(device);
            const score: u32 = switch (props.device_type) {
                .discrete_gpu => 3,
                .integrated_gpu => 2,
                else => 1,
            };
            if (best == null or score > best_score) {
                best = .{ .device = device, .families = families };
                best_score = score;
            }
        }
        return best orelse error.NoSuitableGpu;
    }

    /// Find a graphics-capable queue family and a present-capable one for this
    /// device+surface. Returns null if either is missing (device unusable).
    fn findQueueFamilies(self: *Context, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !?QueueFamilies {
        const families = try self.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(device, self.allocator);
        defer self.allocator.free(families);

        var graphics: ?u32 = null;
        var present: ?u32 = null;
        for (families, 0..) |family, i| {
            const index: u32 = @intCast(i);
            if (family.queue_flags.graphics_bit) graphics = graphics orelse index;
            const present_ok = try self.vki.getPhysicalDeviceSurfaceSupportKHR(device, index, surface);
            if (present_ok == vk.Bool32.true) present = present orelse index;
        }
        if (graphics != null and present != null) {
            return .{ .graphics = graphics.?, .present = present.? };
        }
        return null;
    }

    fn supportsSwapchain(self: *Context, device: vk.PhysicalDevice) !bool {
        const exts = try self.vki.enumerateDeviceExtensionPropertiesAlloc(device, null, self.allocator);
        defer self.allocator.free(exts);
        return extensionListed(exts, vk.extensions.khr_swapchain.name);
    }
    //endregion

    pub fn deinit(self: *Context) void {
        if (self.device != .null_handle) self.vkd.destroyDevice(self.device, null);
        if (self.surface != .null_handle) self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        if (self.debug_messenger != .null_handle) {
            self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        }
        self.vki.destroyInstance(self.instance, null);
    }

    /// The selected GPU's name (valid only after `initDevice`).
    pub fn deviceName(self: *const Context) []const u8 {
        return std.mem.sliceTo(&self.physical_device_props.device_name, 0);
    }
};

//region helpers
/// Whether an extension with the given name appears in a properties list.
fn extensionListed(exts: []const vk.ExtensionProperties, name: [*:0]const u8) bool {
    const wanted = std.mem.span(name);
    for (exts) |ext| {
        if (std.mem.eql(u8, wanted, std.mem.sliceTo(&ext.extension_name, 0))) return true;
    }
    return false;
}

/// Check whether the Khronos validation layer is present on this system.
fn validationLayerAvailable(vkb: vk.BaseWrapper, allocator: std.mem.Allocator) !bool {
    const layers = try vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(layers);
    const wanted = std.mem.span(validation_layer_name);
    for (layers) |layer| {
        if (std.mem.eql(u8, wanted, std.mem.sliceTo(&layer.layer_name, 0))) return true;
    }
    return false;
}

/// The create-info for our debug messenger: which severities/types to report,
/// and the callback that prints them.
fn debugMessengerInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .message_severity = .{ .warning_bit_ext = true, .error_bit_ext = true },
        .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
        .pfn_user_callback = debugCallback,
    };
}

/// Called by the validation layer for every message. Must use Vulkan's calling
/// convention. We just print to stderr; returning FALSE means "don't abort".
fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    msg_type: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = msg_type;
    _ = p_user_data;
    const msg = if (p_callback_data) |data| data.p_message else null;
    const tag = if (severity.error_bit_ext) "ERROR" else "WARN";
    std.debug.print("[vulkan:{s}] {?s}\n", .{ tag, msg });
    return vk.Bool32.false;
}
//endregion
