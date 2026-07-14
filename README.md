# Zig Voxel Test

A 3D voxel game experiment inspired by [Cubyz](https://github.com/PixelGuys/Cubyz).

This is my first time coding in Zig, and this is only a test — a sandbox to try out
ideas and learn the language, not the final project.

## Goals
- Use open source libraries
- Vulkan rendering pipeline
- Easy modding support

## Rendering
- Chunk LODs
- Immersive lighting
- Raytracing (experimental)

## Build & Run

Requires [Zig](https://ziglang.org/download/) 0.16.0 or newer.

```sh
zig build run    # build and run the app
zig build test   # run the tests
```

## Dependencies

Planned libraries, added on demand as each milestone needs them. Nothing is wired
into `build.zig.zon` yet — this is the shortlist. Versions/URLs still need to be
checked against Zig 0.16 before adding.

### Core
- **[SDL3](https://github.com/libsdl-org/SDL)** — window, input (keyboard/mouse/
  gamepad), events, and later audio, all in one library. Used **directly via Zig's
  C interop** (`@cImport` the headers, link `libSDL3`) rather than a binding
  package — fewer moving parts and a good way to learn Zig↔C interop. Feeds the
  Vulkan surface + required instance extensions to vulkan-zig via
  `SDL_Vulkan_CreateSurface` / `SDL_Vulkan_GetInstanceExtensions`.
- **[vulkan-zig](https://github.com/Snektron/vulkan-zig)** — type-safe Vulkan
  bindings generated from the official registry. The rendering backbone.
- **Math** (`zmath` or `zalgebra`) — vectors, matrices, quaternions for the camera
  and projection. May hand-roll `Vec3`/`Mat4` instead as a learning exercise.
- **[znoise](https://github.com/zig-gamedev/znoise)** — Perlin/Simplex noise for
  terrain generation.

### Soon after
- **zstbi** — image loading (`stb_image`) for block textures.
- **glslc / shaderc** — compile GLSL shaders to the SPIR-V that Vulkan expects
  (start with a `glslc` build step).

### Optional / later
- **zgui** (Dear ImGui) — debug UI: live-tweak lighting, chunk stats, FPS.
- **Audio** — SDL3's built-in audio subsystem (already a dependency), so no extra
  library needed once there's gameplay to hear.

### Not needed
- **Modding data** uses the standard library — `std.zon` (native ZON parsing in
  Zig 0.16) or `std.json` — no external dependency required.

> **Alternative:** GLFW (`mach-glfw` / `zglfw`) is a lighter windowing-only option
> if the full SDL3 surface area feels like too much — but it would need a separate
> audio library later. SDL3 is the primary choice here.

> Several of the libraries above (`zmath`, `znoise`, `zstbi`, `zgui`) are bundled
> and co-versioned by [zig-gamedev](https://github.com/zig-gamedev). Using that set
> avoids version mismatches; picking à la carte gives more control.

## Roadmap

A rough milestone path, ordered so each step builds on the last and introduces new
Zig concepts along the way.

### 1. Foundations
- [x] Chunk data structure (`[16][16][16]` block array)
- [x] Block registry (enum / struct table of block types)
- [ ] Chunk manager with explicit allocator (leak-checked)

### 2. Core engine
- [x] SDL3 window + game loop (delta time, held-key input) via C interop
- [x] Fly camera (position + yaw/pitch → view matrix, WASD + mouse-look)
- [x] Greedy chunk meshing with packed u32 vertices + index buffer (`src/render/chunk_mesh.zig`)
- [x] Vulkan pipeline rendering a single chunk
- [x] GPU frustum culling + chunk streaming (unbounded world, load/unload
      around the camera — `src/world.zig`, `src/render/stream.zig`)
- [ ] Procedural terrain (real noise instead of the sine heightmap → 3D caves)

### 3. Gameplay
- [ ] Break / place blocks via raycasting
- [ ] AABB collision + gravity
- [ ] Day/night cycle

### 4. Immersive rendering
- [ ] Vertex-baked ambient occlusion
- [ ] Flood-fill lighting
- [ ] Chunk LODs
- [ ] Raytracing (experimental)

### 5. Modding
- [ ] Data-driven blocks/textures (JSON or ZON loaded at runtime)

**First target:** a single noise-generated chunk you can fly around — this forces
chunk storage → meshing → Vulkan pipeline → camera/input all at once.

## Vulkan bring-up

The "Vulkan pipeline" milestone above is by far the largest step, so it gets its
own checklist. Each item is independently verifiable — get one green before
starting the next. Target: a cleared screen, then a triangle, then a chunk.

**Prerequisites**
- [x] Install MoltenVK / the LunarG Vulkan SDK (installed at `~/VulkanSDK`,
      bundles MoltenVK + validation layers; run `source
      ~/VulkanSDK/<version>/setup-env.sh` to set the loader env vars)
- [x] Flip the window flag back to `c.SDL_WINDOW_VULKAN`
- [x] Add `vulkan-zig` as a dependency (pinned to its `zig-0.16-compat` branch;
      bindings generated from the SDK's `vk.xml`)

**Instance & device** — in `src/render/vulkan.zig` (SDL-agnostic `Context`)
- [x] Load Vulkan and create an instance
      (portability extension + flag enabled on Apple *when available*; window
      extensions from `SDL_Vulkan_GetInstanceExtensions`)
- [x] Enable validation layers + a debug messenger (Debug builds, when supported)
- [x] Create the window surface via `SDL_Vulkan_CreateSurface`
- [x] Pick a physical device (needs graphics + present + swapchain; prefers discrete)
- [x] Find graphics + present queue families
- [x] Create the logical device and retrieve queues

**Swapchain & pipeline** — swapchain in `src/render/swapchain.zig`
- [x] Create the swapchain + image views (format/present-mode/extent selection)
- [x] Command pool, command buffers, and sync objects (semaphores/fences)
      — in `src/render/renderer.zig`
- [x] Dynamic rendering (no render pass/framebuffer; `VK_KHR_dynamic_rendering`)
- [x] Compile GLSL → SPIR-V (a `glslc` build step) and embed the shader modules
- [x] Build the graphics pipeline (`src/render/pipeline.zig`, dynamic viewport/scissor)

**Draw**
- [x] Render loop that clears the screen to a colour (proves the whole chain)
- [x] Draw a hard-coded triangle (RGB gradient, vertices baked into the shader)
- [x] Draw from a vertex buffer (cube in `src/render/mesh.zig`, `buffer.zig` helper)
- [x] Camera-driven MVP via uniform buffer + descriptor sets; depth buffer;
      `Mat4.perspectiveVulkan` (Y-flip / 0..1 depth) — **fly around a 3D cube**
- [x] 4× MSAA via dynamic-rendering resolve (render into a multisampled colour
      image, resolve into the swapchain image at end-of-pass). Colour + depth
      share the sample count, and both are **transient + lazily-allocated
      (memoryless)** so the 4× samples stay in tile memory and never hit RAM —
      near-free MSAA on the M2 (`buffer.findTransientMemoryType`).
- [x] Feed it a meshed chunk — culled mesher in `src/render/chunk_mesh.zig`
      (interior faces skipped, ~16× fewer faces) with a **packed u32 vertex**
      (position + face + block id in 4 bytes, decoded in the vertex shader)

🎯 **First target reached:** a heightmap-terrain chunk (grass/dirt/stone) you can
fly around with WASD + mouse-look.

**Rendering-performance ladder** (in order — each step builds on the last):
1. [x] Index buffer (4 verts + 6 indices per face; ~33% fewer vertices)
2. [x] Greedy meshing (merge coplanar same-block faces into big quads;
   classic slice-mask + rectangle-grow algorithm in `src/render/chunk_mesh.zig`;
   heightmap terrain 1368→475 faces, a flat 16×16 slab 576→6). Binary
   mask-building is a drop-in generation-speed optimisation later (same output).
3. [x] Multi-chunk world (`src/world.zig`): a grid of chunks, neighbour-aware
   meshing (faces culled across chunk seams via `world.blockAt`), per-chunk
   world origin delivered as a **push constant** (vertices stay chunk-local 4-byte
   packed). One vertex+index buffer and one draw call per chunk for now — a 4×2×4
   world renders 30 chunks / ~5k faces cleanly.
   - [x] **Vertex pooling** (`src/render/mesh_pool.zig`): one big vertex + index
     buffer carved into fixed-size slots + a free list. Two GPU allocations
     total, buffers bound once per frame; chunk indices stay slot-local (rebased
     via `cmdDrawIndexed`'s `vertexOffset`).
   - [x] **Streaming** (`src/world.zig` lazy-generated chunk cache;
     `src/render/stream.zig` residency manager): unbounded world, chunks
     generated on demand and loaded/unloaded around the camera via the pool's
     `acquire`/`release`.
     - **Hitch-free** (no per-crossing `deviceWaitIdle`): per-chunk origins are
       slot-stable (written once to a free slot); indirect commands are per-frame
       and each frame lazily rebuilds its own after its fence is waited; freed
       pool slots are reused only after a deferred-free TTL (in-flight frames may
       still reference them). Loads are **budgeted** (`load_budget`/frame) so a
       boundary crossing spreads over frames instead of stalling on a whole ring.
     - TODO: threaded meshing (move generate+mesh off the main thread) for
       zero-impact streaming; device-local pool buffers with a staging queue.
4. [x] Multi-draw indirect (`vkCmdDrawIndexedIndirect`): the whole world draws in
   **one call**, one command per chunk in an indirect buffer; per-chunk origins
   in a storage buffer indexed by **`gl_InstanceIndex`** (each command's
   `firstInstance` = chunk index).
   - MoltenVK gotcha (confirmed): `gl_DrawID` / `shaderDrawParameters` reports
     supported but fails SPIR-V→MSL conversion (`DrawIndex is not supported in
     MSL`). Worked around with `firstInstance` + `drawIndirectFirstInstance`,
     which Metal does support.
5. [x] GPU frustum culling (`src/render/cull.zig`, `src/shaders/cull.comp`): a
   compute shader tests each chunk's AABB against the camera frustum
   (`math.frustumPlanes`, Gribb–Hartmann) and sets each indirect command's
   `instanceCount` to 0/1; a barrier makes the writes visible to the indirect
   draw. Culled chunks cost nothing. Per-frame indirect buffers avoid in-flight
   hazards. First compute shader in the project.

## Lighting

Goal: **real dynamic, coloured lights** — not baked/Minecraft-style flood-fill.
Two orthogonal problems: (a) shading efficiently with many lights, (b) shadows /
visibility. Because the world is voxels, it's already a ray-acceleration
structure — we raymarch the grid (DDA) rather than use hardware RT (MoltenVK's
`VK_KHR_ray_tracing` support is unreliable; software raymarching suits voxels
better anyway). Reference point: Teardown (voxels + raymarched lighting + temporal
accumulation, no RT hardware).

Phased plan (each independently visible):
1. [x] **Real per-pixel lighting** — N·L Lambert from one dynamic coloured point
   light with inverse-square falloff (real normals + world position in the
   shaders; uniforms carry `model`, `light_pos`, `light_color`). A warm light
   orbits the terrain.
2. **Clustered forward** — froxel light grid + compute cull → hundreds of dynamic
   coloured point lights; works with transparency (water).
3. **Raymarched shadows** — upload the voxel volume to the GPU (3D texture /
   storage buffer, later a brickmap/SDF), DDA shadow rays for hard dynamic shadows.
4. **Temporal GI** — coloured bounce + emissive blocks (lava/lamps), accumulated
   and denoised over frames.

Note: fully dynamic lighting bakes *nothing* into the mesh, so it removes the
per-vertex-AO constraint on greedy meshing — the two plans reinforce each other.

## Contraptions (moving block assemblies) — later feature

Goal: Create / Create: Aeronautics-style **contraptions** — groups of blocks that
detach from the world grid and move as a unit (mechanical platforms, and
eventually free-flying block-ships). Deeper reference: **Valkyrien Skies** (block
assemblies as real rigid bodies; it uses a custom solver, "Krunch", rather than an
off-the-shelf engine).

Key architectural insight: a contraption is **a small self-contained voxel grid +
a transform** — structurally the same as a chunk. The rendering is nearly free
given the indirect-draw system: swap each object's `vec3` origin for a full `mat4`
transform in the per-object storage buffer. The renderer already treats the world
as "objects positioned by per-draw data."

The hard part is physics, which splits in two:
1. **Kinematic contraptions** (most of base Create): motion along *constrained*
   paths (rotate about an axis, translate along a rail). Just transform animation
   + swept collision — **no physics engine needed**. Build this tier first.
2. **Dynamic contraptions** (Aeronautics / Valkyrien Skies): true 6-DOF rigid
   bodies — inertia tensor from block layout, force/torque integration, quaternion
   orientation, and **collision between an oriented voxel body and the static
   voxel world** (the genuinely hard bit).

On physics engines: for the dynamic tier, `zphysics` (zig-gamedev's Jolt binding)
is viable for the rigid-body core — represent a contraption as a **compound of box
shapes** (greedy-merged boxes map well). The catch is generating static
world-collision geometry around contraptions on the fly; VS wrote a custom solver
for exactly this reason, so keep that option open. Aerodynamics (lift/drag from
block surfaces + orientation) is a custom force model regardless of engine. Skip a
physics engine for player-vs-world collision — that stays custom swept-AABB-vs-grid
(see Gameplay roadmap).

## UI / GUI

Two different problems, two different tools — don't make one do both:

**Dev / debug UI** → **Dear ImGui** (`zgui`, zig-gamedev). Immediate-mode: FPS
graphs, chunk stats, live light/tweak panels. *The* standard for game tooling;
has a Vulkan backend that supports dynamic rendering (fits our no-render-pass
setup as a second pass after the 3D scene). Utilitarian look — great for tools,
not for shipping as player UI. Worth adding early for dev velocity.

**Player-facing UI** (HUD, hotbar, inventory, menus) → **custom 2D**. The common
voxel-game path (Minecraft's UI is fully custom): an orthographic, alpha-blended
pass drawing textured quads over the 3D scene, with a font atlas for text
(`stb_truetype` → texture; sibling of the `zstbi` we already plan). Optionally
pair with a **layout-only** lib so we don't hand-roll layout math:
- **Clay** — tiny single-header C, flexbox-like, emits render commands we draw
  ourselves (keeps full rendering control; good Zig fit).
- **microui** — ~1k-line immediate-mode, very hackable. (Nuklear / RmlUi are
  heavier alternatives.)

Integration notes: needs a **blend-enabled** pipeline variant (current one has
blend off) and a 2D/ortho pipeline (pos+uv+color, no depth, drawn last); the font
atlas is the fiddly part.

**Modding angle:** make the player UI **data-driven** — define layouts/widgets in
ZON or JSON (both parse natively) and load at runtime, so mods add UI without
touching code. This is a reason to keep player UI custom (ImGui is code-driven).

Plan: add `zgui` for tools now; build the custom data-driven UI (optionally
Clay-backed) for the game later.

=)
