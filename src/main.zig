const std = @import("std");
const zig_test = @import("zig_test");
const vk = @import("vulkan");
const VulkanContext = @import("render/vulkan.zig").Context;
const Swapchain = @import("render/swapchain.zig").Swapchain;
const Renderer = @import("render/renderer.zig").Renderer;
const chunkMesh = @import("render/chunk_mesh.zig");
const mesh = @import("render/mesh.zig");
const Stream = @import("render/stream.zig").Stream;
const ui = @import("ui.zig");
const net = @import("net/net.zig");
const net_server = @import("net/net_server.zig");

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
    const io = init.io; // for world save/load file I/O

    // Parse CLI: run mode + networking options.
    //   (default)          single-player (integrated client+server, in-process)
    //   --server [--port N] dedicated headless server (no window)
    //   --connect <host>    client connecting to a server
    //   --nettest           headless ENet loopback self-test, then exit
    var mode: enum { single_player, server, client } = .single_player;
    var port: u16 = net.default_port;
    var host_buf: [64]u8 = undefined;
    var connect_host: [:0]const u8 = "127.0.0.1";
    var client_test = false;
    {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        defer it.deinit();
        _ = it.skip(); // program name
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--nettest")) return net.selfTest();
            if (std.mem.eql(u8, arg, "--clienttest")) {
                client_test = true;
            } else if (std.mem.eql(u8, arg, "--server")) {
                mode = .server;
            } else if (std.mem.eql(u8, arg, "--connect")) {
                mode = .client;
                if (it.next()) |h| connect_host = std.fmt.bufPrintZ(&host_buf, "{s}", .{h}) catch connect_host;
            } else if (std.mem.eql(u8, arg, "--port")) {
                if (it.next()) |p| port = std.fmt.parseInt(u16, p, 10) catch port;
            }
        }
    }

    // Headless client protocol test against a running --server (port parsed above).
    if (client_test) return net.clientTest(port);

    // Dedicated server: no window, no rendering — just the world + sim + ENet.
    if (mode == .server) {
        var sgpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = sgpa.deinit();
        return net_server.run(sgpa.allocator(), port, genChunk);
    }
    const is_client = mode == .client;

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
    // Single-player owns the world save file; a client's world is authoritative on
    // the server and synced over the network, so it doesn't touch the local file.
    if (!is_client) loadWorld(io, alloc, &world) catch |err| std.log.warn("world load failed: {}", .{err});
    defer if (!is_client) saveWorld(io, alloc, &world) catch |err| std.log.warn("world save failed: {}", .{err});

    // Single-player: authoritative server + in-process connection in one process.
    // The client (the run loop) never mutates the world directly — it sends
    // actions through the connection, and the server applies them on its fixed
    // tick and emits events back. In multiplayer the connection is an ENet socket
    // to a remote server instead (see below); these stay unused then.
    var conn = zig_test.connection.Connection.init(alloc);
    defer conn.deinit();
    var server = zig_test.server.Server.init(&world, &conn);

    // Client: connect to the server and sync the world edit-diff *before* we start
    // rendering, so streamed chunks mesh the correct (already-edited) world.
    var net_client: ?net.NetClient = null;
    if (is_client) {
        try net.init();
        net_client = try net.NetClient.connect(connect_host.ptr, port);
        std.debug.print("client: connecting to {s}:{d}\n", .{ connect_host, port });
        syncFromServer(&net_client.?, &world);
    }
    defer if (is_client) net.deinit();
    defer if (net_client) |*nc| nc.deinit();

    var renderer = try Renderer.init(&vulkan, &swapchain, capacity, 16384, 24576);
    defer renderer.deinit(&vulkan);

    // Debug overlay (Dear ImGui). Drawn as a final pass over the swapchain; input
    // is fed from the event loop. Deinit runs before the device is destroyed.
    ui.init(alloc, &vulkan, &swapchain, @ptrCast(window));
    defer ui.deinit();

    var stream = Stream.init(alloc, &world, &renderer, radius, y_min, y_max);
    defer stream.deinit();
    std.debug.print("world: streaming, radius {d} chunks, capacity {d}\n", .{ radius, capacity });

    var nc_ptr: ?*net.NetClient = null;
    if (net_client) |*nc| nc_ptr = nc;
    try runLoop(io, window, &vulkan, &swapchain, &renderer, &stream, &server, &conn, nc_ptr);
}

/// A remote player the client renders as an avatar. Fixed-size table (server caps
/// clients), keyed by the server-assigned entity id.
const max_entities = 32;
const RemoteEntity = struct {
    id: u32,
    state: zig_test.protocol.PlayerState,
    prev_pos: [3]f32, // position last rendered frame (for motion vectors)
    active: bool,
};

/// Create/update a remote entity's state.
fn upsertEntity(entities: []RemoteEntity, id: u32, state: zig_test.protocol.PlayerState) void {
    for (entities) |*e| if (e.active and e.id == id) {
        e.state = state;
        return;
    };
    for (entities) |*e| if (!e.active) {
        // New avatar: prev_pos = current so it doesn't fling a huge motion vector.
        e.* = .{ .id = id, .state = state, .prev_pos = .{ state.x, state.y, state.z }, .active = true };
        return;
    };
}

fn removeEntity(entities: []RemoteEntity, id: u32) void {
    for (entities) |*e| if (e.active and e.id == id) {
        e.active = false;
        return;
    };
}

/// A distinct avatar colour per player, cycled from a small palette by entity id.
fn entityColor(id: u32) [3]f32 {
    const palette = [_][3]f32{
        .{ 0.90, 0.30, 0.30 }, .{ 0.30, 0.85, 0.40 }, .{ 0.40, 0.55, 0.95 },
        .{ 0.95, 0.80, 0.30 }, .{ 0.80, 0.40, 0.90 }, .{ 0.30, 0.85, 0.90 },
    };
    return palette[id % palette.len];
}

/// Client join sync: pump the connection until the server's world snapshot
/// arrives (the edit-diff), and apply it to the local world. Times out after a
/// few seconds and continues with locally-generated terrain if none comes.
fn syncFromServer(nc: *net.NetClient, world: *zig_test.world.World) void {
    var iter: u32 = 0;
    while (iter < 500) : (iter += 1) {
        var ev: net.c.NzEvent = undefined;
        while (net.c.nz_service(nc.host, &ev, 10) > 0) {
            var synced = false;
            if (ev.kind == net.c.NZ_RECEIVE and ev.len > 0) {
                if (zig_test.protocol.decodeServerMessage(ev.data[0..ev.len])) |msg| switch (msg) {
                    .snapshot => |s| {
                        world.deserialize(s) catch |e| std.log.warn("snapshot apply failed: {}", .{e});
                        std.debug.print("client: synced {d} edit bytes from server\n", .{s.len});
                        synced = true;
                    },
                    else => {},
                };
            }
            net.c.nz_free_packet(&ev);
            if (synced) return;
        }
    }
    std.debug.print("client: no snapshot received; using local terrain\n", .{});
}

/// Where player edits are persisted (a compact diff from the generated world).
const save_path = "world.sav";

/// Generate the 3×3×3 chunks around the player so collision has real ground even
/// before the (budgeted) streamer has loaded them — otherwise the player falls
/// through the world on spawn or when moving into freshly-entered chunks.
/// `ensure` is a cheap cache hit once a chunk exists.
fn ensurePlayerChunks(world: *zig_test.world.World, pos: zig_test.math.Vec3) void {
    const size = zig_test.chunk.size;
    const cx = @divFloor(@as(i32, @intFromFloat(@floor(pos.x))), size);
    const cy = @divFloor(@as(i32, @intFromFloat(@floor(pos.y))), size);
    const cz = @divFloor(@as(i32, @intFromFloat(@floor(pos.z))), size);
    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dz: i32 = -1;
            while (dz <= 1) : (dz += 1) {
                _ = world.ensure(.{ .x = cx + dx, .y = cy + dy, .z = cz + dz }) catch {};
            }
        }
    }
}

/// Read the save file (if any) and load its edits into the world.
fn loadWorld(io: std.Io, alloc: std.mem.Allocator, world: *zig_test.world.World) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, save_path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return, // first run
        else => return err,
    };
    defer alloc.free(data);
    try world.deserialize(data);
}

/// Serialize the world's edits and write them to the save file.
fn saveWorld(io: std.Io, alloc: std.mem.Allocator, world: *zig_test.world.World) !void {
    const data = try world.serialize(alloc);
    defer alloc.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = save_path, .data = data });
}

const player_save_path = "player.sav";

/// Persisted player state: feet position + look angles.
const PlayerSave = extern struct { x: f32, y: f32, z: f32, yaw: f32, pitch: f32 };

/// Restore player position + look from disk (no-op if there's no save).
fn loadPlayer(io: std.Io, player: *zig_test.player.Player, cam: *zig_test.camera.Camera) void {
    var buf: [64]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(io, player_save_path, &buf) catch return;
    if (data.len < @sizeOf(PlayerSave)) return;
    var s: PlayerSave = undefined;
    @memcpy(std.mem.asBytes(&s), data[0..@sizeOf(PlayerSave)]);
    player.pos = .{ .x = s.x, .y = s.y, .z = s.z };
    cam.yaw = s.yaw;
    cam.pitch = s.pitch;
}

/// Write player position + look to disk.
fn savePlayer(io: std.Io, player: *const zig_test.player.Player, cam: *const zig_test.camera.Camera) !void {
    const s = PlayerSave{ .x = player.pos.x, .y = player.pos.y, .z = player.pos.z, .yaw = cam.yaw, .pitch = cam.pitch };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = player_save_path, .data = std.mem.asBytes(&s) });
}

/// Deterministic terrain generator. A pure function of the world coordinate (so
/// any chunk regenerates identically on demand): a fractal-noise heightmap for
/// rolling hills, grass/dirt/stone layering, and 3D noise carving out caves.
const gen_seed: u32 = 1337;

fn genChunk(coord: zig_test.world.Coord, chunk: *zig_test.chunk.Chunk) void {
    const noise = zig_test.noise;
    const size = zig_test.chunk.size;
    var lx: usize = 0;
    while (lx < size) : (lx += 1) {
        var lz: usize = 0;
        while (lz < size) : (lz += 1) {
            const wx: f32 = @floatFromInt(coord.x * size + @as(i32, @intCast(lx)));
            const wz: f32 = @floatFromInt(coord.z * size + @as(i32, @intCast(lz)));

            // Surface height from fBm: a low base plus noise-driven relief. The low
            // frequency (0.008) gives broad hills; 5 octaves add finer bumps. Kept
            // within the 3-chunk-tall world (0..48).
            const h = noise.fbm2(wx * 0.008, wz * 0.008, gen_seed, 5);
            const height: i32 = 10 + @as(i32, @intFromFloat(h * 34.0));

            var ly: usize = 0;
            while (ly < size) : (ly += 1) {
                const wy: i32 = coord.y * size + @as(i32, @intCast(ly));
                if (wy >= height) continue;

                // Caves: 3D noise carves hollows. The carve threshold is
                // depth-graduated — roomy caves deep down (fBm > 0.60 ≈ 20% of
                // voxels), getting rarer toward the surface (up to > 0.72 ≈ 4%) so
                // they occasionally break through as cave mouths instead of pocking
                // the whole surface with holes.
                const depth = @min(height - wy, 4); // 1 at surface .. 4 deep
                const threshold = 0.60 + 0.04 * @as(f32, @floatFromInt(4 - depth));
                const cave = noise.fbm3(wx * 0.045, @as(f32, @floatFromInt(wy)) * 0.045, wz * 0.045, gen_seed +% 99, 3);
                if (cave > threshold) continue; // hollow

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
    // `SDL_WINDOW_VULKAN` prepares the window to host a Vulkan surface;
    // `MAXIMIZED` (+ `RESIZABLE`, required for maximize) opens it filling the
    // screen. The 1280×720 is just the restored (un-maximized) size. The
    // swapchain sizes itself from the surface's actual extent, so the render
    // targets match whatever the window opens at.
    // NOTE: live resizing isn't handled yet (no swapchain recreation) — resizing
    // the window mid-run freezes rendering until it's back to the original size.
    const flags = c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_MAXIMIZED | c.SDL_WINDOW_RESIZABLE;
    return c.SDL_CreateWindow("zig voxel test", 1280, 720, flags) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindow;
    };
}

/// The main game loop: set up per-frame state, then run until the user quits.
fn runLoop(
    io: std.Io,
    window: *c.SDL_Window,
    vulkan: *VulkanContext,
    swapchain: *Swapchain,
    renderer: *Renderer,
    stream: *Stream,
    server: *zig_test.server.Server,
    conn: *zig_test.connection.Connection,
    net_client: ?*net.NetClient,
) !void {
    //region Setup (timing, camera, mouse capture)
    // A high-resolution counter that ticks `freq` times per second. Dividing a
    // tick delta by `freq` gives seconds. We store `freq` as a float once so the
    // per-frame math is a plain division.
    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    var last_tick = c.SDL_GetPerformanceCounter();

    // Simple stat: accumulate time and frames to print an FPS line once a second,
    // so we can *see* delta-time working without any rendering yet.
    var fps_accum: f64 = 0;
    var fps_frames: u32 = 0;

    // Camera holds the look direction (yaw/pitch); its position is driven by the
    // player each frame. A walking player above the terrain — it falls to the
    // ground and collides with blocks. Physics runs on a fixed timestep.
    var cam = zig_test.camera.Camera{};
    var player = zig_test.player.Player{ .pos = .{ .x = 0, .y = 45, .z = 30 } };
    // Restore saved position + look (no-op on first run); save on exit.
    loadPlayer(io, &player, &cam);
    defer savePlayer(io, &player, &cam) catch |err| std.log.warn("player save failed: {}", .{err});
    var phys_accum: f32 = 0;
    const phys_step: f32 = 1.0 / 60.0;

    // Previous frame's (unjittered) view-projection, for TAA reprojection. Seeded
    // to identity; the first frame has its history flagged invalid anyway.
    var prev_viewproj = zig_test.math.Mat4.identity;

    // Debug-overlay state. `ui_focus` releases the mouse for the UI (` toggles);
    // the light colour/intensity are live-edited in the overlay; FPS is smoothed.
    var ui_focus = false;
    var creative = false; // fly + noclip debug mode (toggle: F or the overlay)
    var light_rgb = [3]f32{ 1.0, 0.85, 0.6 };
    var light_intensity: f32 = 3.0;
    // Sun direction as azimuth (around the horizon) + elevation (above it), in
    // degrees — live-tuned in the overlay, drives the shadow angle.
    var sun_azimuth: f32 = 40;
    var sun_elevation: f32 = 55;
    var fps_smooth: f32 = 60.0;
    var fps_window: f64 = 0; // time since the displayed FPS was last refreshed

    // Shadow-volume sync: rebuild on chunk crossings, plus a debounced refresh
    // while the resident set is still changing (chunks streaming in).
    var last_shadow_chunks: usize = 0;
    var shadow_timer: u32 = 0;

    // Multiplayer entity state (client mode): our own server-assigned id (0 until
    // assigned), the other players we render, and a throttle for position reports.
    var own_id: u32 = 0;
    var entities = [_]RemoteEntity{.{ .id = 0, .state = undefined, .prev_pos = undefined, .active = false }} ** max_entities;
    var pos_send_accum: f32 = 0;

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
            // Let ImGui see every event first (mouse/keyboard for the overlay).
            _ = ui.processEvent(&event);
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_ESCAPE) running = false;
                    // Backtick (`) releases the mouse to interact with the overlay
                    // (and back). Kept off Tab, which ImGui uses for widget nav.
                    // Scancode, so it fires on the physical key with or without shift.
                    if (event.key.scancode == c.SDL_SCANCODE_GRAVE) {
                        ui_focus = !ui_focus;
                        _ = c.SDL_SetWindowRelativeMouseMode(window, !ui_focus);
                    }
                    // F toggles creative mode (fly + noclip) for debugging.
                    if (event.key.scancode == c.SDL_SCANCODE_F and !ui_focus) creative = !creative;
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    // `xrel`/`yrel` are how far the mouse moved since last event.
                    if (!ui_focus) cam.look(event.motion.xrel, event.motion.yrel);
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    // Aim a ray from the camera; left = break, right = place.
                    // Skipped while the overlay has the mouse.
                    if (!ui_focus) {
                        // Don't edit the world here — send an action to the server,
                        // which validates + applies it and emits an event we react
                        // to below. The raycast only *reads* the world (allowed).
                        // In single-player the action goes to the in-process server;
                        // as a client it goes over the socket.
                        if (zig_test.raycast.raycastVoxel(stream.world, cam.position, cam.forward(), 6.0)) |h| {
                            const maybe_action: ?zig_test.protocol.Action = if (event.button.button == c.SDL_BUTTON_LEFT)
                                .{ .set_block = .{ .x = h.block[0], .y = h.block[1], .z = h.block[2], .block = .air } }
                            else if (event.button.button == c.SDL_BUTTON_RIGHT)
                                .{ .set_block = .{
                                    .x = h.block[0] + h.normal[0],
                                    .y = h.block[1] + h.normal[1],
                                    .z = h.block[2] + h.normal[2],
                                    .block = .stone,
                                } }
                            else
                                null;
                            if (maybe_action) |action| {
                                if (net_client) |nc| nc.sendAction(action) else conn.sendAction(action);
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // 2b. Client/server round-trip: get block-change events and apply them to
        //     the view. Single-player advances the in-process server and drains its
        //     connection; a networked client instead pumps events off the socket
        //     (and must update its own replicated world, which the local server
        //     would otherwise have done).
        if (net_client) |nc| {
            var nev: net.c.NzEvent = undefined;
            while (net.c.nz_service(nc.host, &nev, 0) > 0) {
                if (nev.kind == net.c.NZ_RECEIVE and nev.len > 0) {
                    if (zig_test.protocol.decodeServerMessage(nev.data[0..nev.len])) |msg| switch (msg) {
                        .block_changed => |b| {
                            stream.world.setBlock(b.x, b.y, b.z, b.block) catch {};
                            stream.applyBlockChange(vulkan, b.x, b.y, b.z) catch {};
                            renderer.editShadowVoxel(stream.world, b.x, b.y, b.z);
                        },
                        .assign_id => |id| own_id = id,
                        .entity_moved => |e| if (e.id != own_id) upsertEntity(&entities, e.id, e.state),
                        .entity_despawn => |id| removeEntity(&entities, id),
                        .snapshot => {}, // initial sync happens before the loop
                    };
                }
                net.c.nz_free_packet(&nev);
            }
        } else {
            server.tick(@floatCast(dt));
            for (conn.eventsSlice()) |ev| switch (ev) {
                .block_changed => |b| {
                    stream.applyBlockChange(vulkan, b.x, b.y, b.z) catch |err| std.log.warn("remesh failed: {}", .{err});
                    renderer.editShadowVoxel(stream.world, b.x, b.y, b.z);
                },
            };
            conn.clearEvents();
        }

        // 3. Input state: a snapshot array of every key, indexed by scancode.
        //    Unlike events, this tells us what's held RIGHT NOW — exactly what
        //    continuous movement needs. SDL owns the array; we just read it.
        const keys = c.SDL_GetKeyboardState(null);
        // No player movement while the overlay has focus (so typing/clicks don't walk).
        const move = if (ui_focus) Movement{ .x = 0, .y = 0, .z = 0, .sprint = false } else readMovement(keys);

        // 4. Movement. Creative: free flight + noclip — move the feet position
        //    directly along the look direction (W/S), strafe (A/D), and world-up
        //    (space/shift), no gravity or collision. Normal: step the player on a
        //    fixed timestep (stable collision), advancing/strafing by yaw with
        //    space to jump. Either way, the camera rides the player's eyes.
        //    Collision/ground reads the world grid, but streaming loads chunks
        //    lazily — so we generate the chunks around the player up front (cheap,
        //    cached) to guarantee there's ground under them (else they fall on spawn).
        if (creative) {
            ensurePlayerChunks(stream.world, player.pos);
            const speed: f32 = if (move.sprint) 40.0 else 16.0;
            const fwd = cam.forward(); // includes pitch, so you fly where you look
            const right = cam.right();
            var wish = fwd.scale(-move.z).add(right.scale(move.x));
            wish.y += -move.y; // space (move.y = -1) up, shift (move.y = +1) down
            if (wish.length() > 0) {
                wish = wish.normalize().scale(speed * @as(f32, @floatCast(dt)));
                player.pos = player.pos.add(wish);
            }
            player.vel = zig_test.math.Vec3.zero;
            player.on_ground = false;
            phys_accum = 0; // don't accumulate physics debt while flying
        } else {
            phys_accum += @floatCast(dt);
            while (phys_accum >= phys_step) : (phys_accum -= phys_step) {
                ensurePlayerChunks(stream.world, player.pos);
                player.step(stream.world, -move.z, move.x, move.y < 0, move.sprint, cam.yaw, phys_step);
            }
        }
        cam.position = player.eye();

        // 4a2. Multiplayer: report our position to the server a few dozen times a
        //      second so it can relay it to the other players' clients.
        if (net_client) |nc| {
            pos_send_accum += @floatCast(dt);
            if (pos_send_accum >= 0.033) {
                pos_send_accum = 0;
                nc.sendPlayerState(.{ .x = player.pos.x, .y = player.pos.y, .z = player.pos.z, .yaw = cam.yaw });
            }
        }

        // 4b. Stream: load/unload chunks around the player. Cheap no-op unless
        //     the player crossed into a new chunk.
        try stream.update(vulkan, cam.position);

        // 4c. Shadow volume: re-anchor on chunk crossings; also force a debounced
        //     rebuild while chunks are still streaming in (resident count moving).
        shadow_timer += 1;
        const shadow_chunks = renderer.chunkCount();
        const force_shadows = shadow_chunks != last_shadow_chunks and shadow_timer >= 30;
        if (renderer.recenterShadows(stream.world, .{ cam.position.x, cam.position.y, cam.position.z }, force_shadows)) {
            last_shadow_chunks = shadow_chunks;
            shadow_timer = 0;
        }

        // 5. Render: build the shared per-frame uniforms and draw the world.
        //    Vertices are chunk-local; each chunk's world origin is a push
        //    constant, so we only need view × projection here (no model matrix).
        // Debug overlay: start an ImGui frame and build the window. Must be paired
        // with the `ui.record` callback in drawFrame below (which finalises it).
        // `fps_smooth` is a windowed average (updated below), not a per-frame 1/dt —
        // so a stall (e.g. a chunk-load rebuild) and its vsync catch-up frames
        // average out instead of spiking the reading.
        ui.beginFrame(swapchain.extent.width, swapchain.extent.height);
        ui.debugWindow(.{
            .fps = fps_smooth,
            .cam_pos = .{ cam.position.x, cam.position.y, cam.position.z },
            .yaw = cam.yaw,
            .pitch = cam.pitch,
            .chunks = renderer.chunkCount(),
            .creative = &creative,
            .light_rgb = &light_rgb,
            .light_intensity = &light_intensity,
            .sun_azimuth = &sun_azimuth,
            .sun_elevation = &sun_elevation,
        });

        // Sun direction from the overlay's azimuth/elevation (points toward the sun).
        const el = std.math.degreesToRadians(sun_elevation);
        const az = std.math.degreesToRadians(sun_azimuth);
        const cos_el = @cos(el);
        const sun_dir = [3]f32{ cos_el * @cos(az), @sin(el), cos_el * @sin(az) };

        const math = zig_test.math;
        const aspect: f32 = @as(f32, @floatFromInt(swapchain.extent.width)) /
            @as(f32, @floatFromInt(swapchain.extent.height));
        const proj = math.Mat4.perspectiveVulkan(std.math.degreesToRadians(60.0), aspect, 0.1, 500.0);
        const viewproj = proj.mul(cam.view());

        // Deferred lighting: the shader reconstructs each fragment's world
        // position from depth (needs the inverse view-proj) and TAA reprojects it
        // through last frame's view-proj (`prev_viewproj`). A warm point light
        // rides the camera (a headlamp) so lighting is visibly dynamic; the
        // renderer fills in framebuffer size + TAA jitter itself.
        // Build the remote-player avatars to draw this frame (empty in SP), and
        // advance each one's prev_pos for next frame's motion vector.
        var entity_instances: [max_entities]mesh.EntityInstance = undefined;
        var entity_n: usize = 0;
        for (&entities) |*e| if (e.active) {
            const p = [3]f32{ e.state.x, e.state.y, e.state.z };
            entity_instances[entity_n] = .{ .pos = p, .prev_pos = e.prev_pos, .color = entityColor(e.id) };
            entity_n += 1;
            e.prev_pos = p;
        };

        const planes = math.frustumPlanes(viewproj);
        try renderer.drawFrame(vulkan, swapchain, .{
            .viewproj = viewproj.m,
            .inv_viewproj = viewproj.inverse().m,
            .prev_viewproj = prev_viewproj.m,
            .light_pos = .{ cam.position.x, cam.position.y, cam.position.z, 0 },
            .light_color = .{ light_rgb[0], light_rgb[1], light_rgb[2], light_intensity },
            .camera_pos = .{ cam.position.x, cam.position.y, cam.position.z, 0 },
            .params = .{ 0, 0, 0, 0 },
            .taa = .{ 0, 0, 0, 0 },
            // Filled in by the renderer from its shadow volume.
            .shadow_origin = .{ 0, 0, 0, 0 },
            .shadow_dim = .{ 0, 0, 0, 0 },
            .sun_dir = .{ sun_dir[0], sun_dir[1], sun_dir[2], 0 },
        }, planes, entity_instances[0..entity_n], ui.record);
        prev_viewproj = viewproj;

        // Windowed FPS: average frames over a short interval (steady, unlike a
        // per-frame 1/dt), used by the overlay and the once-a-second console line.
        fps_accum += dt;
        fps_frames += 1;
        fps_window += dt;
        if (fps_window >= 0.25) {
            fps_smooth = @as(f32, @floatFromInt(fps_frames)) / @as(f32, @floatCast(fps_accum));
            fps_window = 0;
        }
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
const Movement = struct { x: f32, y: f32, z: f32, sprint: bool };

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
