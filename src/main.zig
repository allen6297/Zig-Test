const std = @import("std");
const zig_test = @import("zig_test");
const vk = @import("vulkan");
const VulkanContext = @import("render/vulkan.zig").Context;
const Swapchain = @import("render/swapchain.zig").Swapchain;
const Renderer = @import("render/renderer.zig").Renderer;
const chunkMesh = @import("render/chunk_mesh.zig");
const Stream = @import("render/stream.zig").Stream;

//region SDL (C interop)
// Pull SDL's C header straight into Zig. `@cImport` runs the C preprocessor and
// translates the declarations, so everything below is reachable as `c.SDL_...`.
// No binding package — this IS the C-interop path we chose.
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_vulkan.h");
});
//endregion

/// Entry point — kept deliberately small: bring SDL up, open a window, run the
/// loop, and let `defer` tear everything down in reverse order. The real work
/// lives in the functions below, each a self-contained (and foldable) unit.
pub fn main(init: std.process.Init) !void {
    _ = init;

    // Bring up SDL's video subsystem. SDL3 returns `true` on success (SDL2
    // returned 0 — the API flipped), so a falsy result means failure.
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInit;
    }
    defer c.SDL_Quit();

    const window = try createWindow();
    defer c.SDL_DestroyWindow(window);

    // A general-purpose debug allocator with leak detection — handy while learning.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var vulkan = try initVulkan(gpa.allocator(), window);
    defer vulkan.deinit();
    std.debug.print("vulkan: using GPU \"{s}\" (graphics q{d}, present q{d})\n", .{
        vulkan.deviceName(),
        vulkan.queue_families.graphics,
        vulkan.queue_families.present,
    });

    // Build the swapchain sized to the window's pixel dimensions (which differ
    // from logical size on high-DPI displays — Vulkan wants pixels).
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &w, &h);
    var swapchain = try Swapchain.init(&vulkan, .{ .width = @intCast(w), .height = @intCast(h) });
    defer swapchain.deinit(&vulkan);
    std.debug.print("swapchain: {d} images, {d}x{d}, format {s}\n", .{
        swapchain.images.len,
        swapchain.extent.width,
        swapchain.extent.height,
        @tagName(swapchain.format),
    });

    // An unbounded, streamed world: chunks are generated on demand and loaded/
    // unloaded around the camera. The renderer is sized for the max resident set.
    const alloc = gpa.allocator();
    const radius = 6; // horizontal load radius in chunks
    const y_min = 0;
    const y_max = 2; // world is 3 chunks (48 blocks) tall for now
    const capacity: u32 = @intCast((2 * radius + 1) * (2 * radius + 1) * (y_max - y_min + 1));

    var world = zig_test.world.World.init(alloc, genChunk);
    defer world.deinit();

    var renderer = try Renderer.init(&vulkan, &swapchain, capacity, 16384, 24576);
    defer renderer.deinit(&vulkan);

    var stream = Stream.init(alloc, &world, &renderer, radius, y_min, y_max);
    defer stream.deinit();
    std.debug.print("world: streaming, radius {d} chunks, capacity {d}\n", .{ radius, capacity });

    try runLoop(window, &vulkan, &swapchain, &renderer, &stream);
}

/// Deterministic terrain generator: fills a chunk from its world coordinate with
/// a rolling heightmap. A pure function of the coordinate, so any chunk can be
/// regenerated identically on demand. (Real noise-based terrain is a later step.)
fn genChunk(coord: zig_test.world.Coord, chunk: *zig_test.chunk.Chunk) void {
    const size = zig_test.chunk.size;
    var lx: usize = 0;
    while (lx < size) : (lx += 1) {
        var lz: usize = 0;
        while (lz < size) : (lz += 1) {
            const wx: f32 = @floatFromInt(coord.x * size + @as(i32, @intCast(lx)));
            const wz: f32 = @floatFromInt(coord.z * size + @as(i32, @intCast(lz)));
            const height: i32 = @intFromFloat(18.0 + 6.0 * @sin(wx * 0.08) + 6.0 * @cos(wz * 0.07));
            var ly: usize = 0;
            while (ly < size) : (ly += 1) {
                const wy: i32 = coord.y * size + @as(i32, @intCast(ly));
                if (wy >= height) continue;
                const block: zig_test.block.BlockId =
                    if (wy + 1 == height) .grass else if (wy + 3 >= height) .dirt else .stone;
                chunk.set(lx, ly, lz, block);
            }
        }
    }
}

/// Bring up Vulkan: gather the platform bits SDL provides (loader + extensions),
/// create the instance, then create the window surface and finish device setup.
/// The surface is the one place SDL and Vulkan must meet, so it lives here.
fn initVulkan(allocator: std.mem.Allocator, window: *c.SDL_Window) !VulkanContext {
    // SDL returns a generic function pointer; cast it to Vulkan's loader type.
    const get_proc_addr: vk.PfnGetInstanceProcAddr =
        @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return error.NoVulkanLoader);

    // The window-system extensions SDL needs enabled (e.g. VK_KHR_surface and a
    // platform surface extension). Returns a C array of C strings + a count,
    // which we reinterpret as a Zig slice of null-terminated strings.
    var count: u32 = 0;
    const sdl_exts = c.SDL_Vulkan_GetInstanceExtensions(&count) orelse return error.NoVulkanExtensions;
    const extensions = @as([*]const [*:0]const u8, @ptrCast(sdl_exts))[0..count];

    var vulkan = try VulkanContext.init(allocator, get_proc_addr, extensions);
    errdefer vulkan.deinit();

    // Ask SDL to create the surface for our instance. SDL speaks in C Vulkan
    // handle types (opaque pointers); vulkan-zig uses enums over the same bits,
    // so we bridge with int<->enum/ptr casts.
    const c_instance: c.VkInstance = @ptrFromInt(@intFromEnum(vulkan.instance));
    var c_surface: c.VkSurfaceKHR = null;
    if (!c.SDL_Vulkan_CreateSurface(window, c_instance, null, &c_surface)) {
        std.debug.print("SDL_Vulkan_CreateSurface failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlSurface;
    }
    const surface: vk.SurfaceKHR = @enumFromInt(@intFromPtr(c_surface));

    try vulkan.initDevice(surface);
    return vulkan;
}

/// Create the application window and return it, or an error on failure.
fn createWindow() !*c.SDL_Window {
    // The last arg is a bitmask of flags. `SDL_WINDOW_VULKAN` makes SDL load the
    // Vulkan library and prepare the window to host a Vulkan surface. This works
    // now that MoltenVK is present (via the LunarG SDK at ~/VulkanSDK). C strings
    // are null-terminated, exactly what Zig's `"..."` literals already are.
    return c.SDL_CreateWindow("zig voxel test", 1280, 720, c.SDL_WINDOW_VULKAN) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    };
}

/// The main game loop: set up per-frame state, then run until the user quits.
fn runLoop(
    window: *c.SDL_Window,
    vulkan: *VulkanContext,
    swapchain: *Swapchain,
    renderer: *Renderer,
    stream: *Stream,
) !void {
    //region Setup (timing, camera, mouse capture)
    // A high-resolution counter that ticks `freq` times per second. Dividing a
    // tick delta by `freq` gives seconds. We store `freq` as a float once so the
    // per-frame math is a plain division.
    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    var last_tick = c.SDL_GetPerformanceCounter();
    var elapsed: f32 = 0; // seconds since start, for the clear-colour cycle

    // Simple stat: accumulate time and frames to print an FPS line once a second,
    // so we can *see* delta-time working without any rendering yet.
    var fps_accum: f64 = 0;
    var fps_frames: u32 = 0;

    // The camera, above the (streamed, unbounded) terrain. Fly around and chunks
    // load/unload around you. Faster move speed to cover ground.
    var cam = zig_test.camera.Camera{ .position = .{ .x = 0, .y = 45, .z = 30 }, .move_speed = 24 };

    // Capture the mouse so motion turns the camera (like any FPS). This hides
    // the cursor and lets us read raw relative motion instead of an absolute
    // position pinned to the window edge.
    _ = c.SDL_SetWindowRelativeMouseMode(window, true);
    //endregion

    var running = true;
    while (running) {
        // 1. Timing: how long did the previous frame take, in seconds?
        const now = c.SDL_GetPerformanceCounter();
        const dt: f64 = @as(f64, @floatFromInt(now - last_tick)) / freq;
        last_tick = now;

        // 2. Events: handle discrete, one-shot things (quit, window close) and
        //    mouse motion. Held-movement keys are handled separately via key
        //    STATE below.
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_ESCAPE) running = false;
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    // `xrel`/`yrel` are how far the mouse moved since last event.
                    cam.look(event.motion.xrel, event.motion.yrel);
                },
                else => {},
            }
        }

        // 3. Input state: a snapshot array of every key, indexed by scancode.
        //    Unlike events, this tells us what's held RIGHT NOW — exactly what
        //    continuous movement needs. SDL owns the array; we just read it.
        const keys = c.SDL_GetKeyboardState(null);
        const move = readMovement(keys);

        // 4. Update: drive the camera from input. `move.x` strafes, and forward
        //    is -move.z (W set z to -1). dt keeps speed frame-rate independent.
        cam.move(move.x, -move.z, move.y, move.sprint, @floatCast(dt));

        // 4b. Stream: load/unload chunks around the camera. Cheap no-op unless
        //     the camera crossed into a new chunk.
        try stream.update(vulkan, cam.position);

        // 5. Render: build the shared per-frame uniforms and draw the world.
        //    Vertices are chunk-local; each chunk's world origin is a push
        //    constant, so we only need view × projection here (no model matrix).
        elapsed += @floatCast(dt);
        const math = zig_test.math;
        const aspect: f32 = @as(f32, @floatFromInt(swapchain.extent.width)) /
            @as(f32, @floatFromInt(swapchain.extent.height));
        const proj = math.Mat4.perspectiveVulkan(std.math.degreesToRadians(60.0), aspect, 0.1, 500.0);
        const viewproj = proj.mul(cam.view());

        // A single dynamic point light orbiting above the camera, so the terrain
        // under you is always lit and the lighting is visibly *moving*.
        const light = zig_test.math.Vec3{
            .x = cam.position.x + 30.0 * @sin(elapsed * 0.5),
            .y = 45.0,
            .z = cam.position.z + 30.0 * @cos(elapsed * 0.5),
        };
        const planes = math.frustumPlanes(viewproj);
        try renderer.drawFrame(vulkan, swapchain, .{
            .viewproj = viewproj.m,
            .light_pos = .{ light.x, light.y, light.z, 1.0 },
            .light_color = .{ 1.0, 0.85, 0.6, 600.0 }, // warm light, intensity in w
        }, planes);

        // Once-a-second readout: FPS plus the camera's position and look angles,
        // so we can watch WASD + mouse actually driving the camera with no
        // renderer yet.
        fps_accum += dt;
        fps_frames += 1;
        if (fps_accum >= 1.0) {
            std.debug.print(
                "fps: {d} | pos ({d:.1}, {d:.1}, {d:.1}) | yaw {d:.2} pitch {d:.2}\n",
                .{ fps_frames, cam.position.x, cam.position.y, cam.position.z, cam.yaw, cam.pitch },
            );
            fps_accum = 0;
            fps_frames = 0;
        }
    }
}

// Pull the render-module tests (e.g. the chunk mesher's) into `zig build test` —
// they live in the exe module, so nothing else references them during testing.
test {
    std.testing.refAllDecls(chunkMesh);
}

//region Input helpers
/// A 2D movement intent on the ground plane, in the range [-1, 1] per axis.
/// This is deliberately decoupled from SDL so the camera code later doesn't
/// care where the input came from.
const Movement = struct { x: f32, y: f32, z: f32, sprint: bool};

/// Translate the raw keyboard-state array into WASD movement intent.
/// `keys` is SDL's snapshot: index by scancode, non-zero means held.
fn readMovement(keys: [*c]const bool) Movement {
    var m = Movement{ .x = 0, .y = 0, .z = 0, .sprint = false };
    if (keys[c.SDL_SCANCODE_W]) m.z -= 1; // forward (-z)
    if (keys[c.SDL_SCANCODE_S]) m.z += 1; // back
    if (keys[c.SDL_SCANCODE_A]) m.x -= 1; // left
    if (keys[c.SDL_SCANCODE_D]) m.x += 1; // right
    if (keys[c.SDL_SCANCODE_SPACE]) m.y -= 1; // up
    if (keys[c.SDL_SCANCODE_LSHIFT]) m.y += 1; // down
    if (keys[c.SDL_SCANCODE_LCTRL]) m.sprint = true;
    return m;
}
//endregion
