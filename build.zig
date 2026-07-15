const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zig_test", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zig_test",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zig_test" is the name you will use in your source code to
                // import this module (e.g. `@import("zig_test")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zig_test", .module = mod },
            },
        }),
    });

    //region SDL3 (via C interop)
    // We call SDL's C API directly (see `@cImport` in src/main.zig) rather than
    // using a Zig binding package, so we must link libC (SDL is a C library) and
    // the system-installed SDL3 shared library. Include/library search paths are
    // platform-specific: on macOS Homebrew (Apple Silicon) they live under
    // /opt/homebrew; on Linux/Windows the system paths (or pkg-config, which
    // `linkSystemLibrary` consults) usually suffice. This keeps the build working
    // as the project grows toward being multiplatform.
    exe.root_module.link_libc = true;
    switch (target.result.os.tag) {
        .macos => {
            exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        },
        else => {}, // rely on system search paths / pkg-config
    }
    exe.root_module.linkSystemLibrary("SDL3", .{});
    //endregion

    //region vulkan-zig (generated bindings)
    // vulkan-zig generates the whole Vulkan API as Zig code from the official
    // registry (vk.xml). We hand it the registry from the installed Vulkan SDK;
    // the package then exposes the generated code as its "vulkan-zig" module,
    // which we import in source as "vulkan".
    //
    // Note: no libvulkan link needed — we load Vulkan's entry point dynamically
    // from SDL at runtime (SDL_Vulkan_GetVkGetInstanceProcAddr), so the bindings
    // are pure Zig with no link-time dependency.
    const vulkan = b.dependency("vulkan", .{
        .registry = vulkanRegistryPath(b),
    });
    exe.root_module.addImport("vulkan", vulkan.module("vulkan-zig"));
    //endregion

    //region zgui (Dear ImGui — debug UI)
    // Dear ImGui via zig-gamedev's zgui binding, built with the sdl3_vulkan
    // backend to match our stack. That backend compiles ImGui's C++ SDL3 +
    // Vulkan implementations into a static lib we link here; we drive it with
    // dynamic rendering (a final UI pass over the swapchain — see renderer.zig).
    // imgui_impl_vulkan.cpp needs the Vulkan headers, hence `vulkan_include`.
    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3_vulkan,
        .vulkan_include = vulkanIncludePath(b),
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.root_module.linkLibrary(zgui.artifact("imgui"));
    //endregion

    //region ENet (reliable UDP — the multiplayer transport)
    // Vendored single-header ENet (zpl-c/enet, MIT). One C TU compiles the
    // implementation; source `@cImport`s the header for declarations. Pure BSD
    // sockets on macOS/Linux, so no extra system libs to link here.
    // A thin C shim (net_shim.c) implements a minimal API over ENet and compiles
    // ENet itself. Source `@cImport`s net_shim.h — not enet.h — so translate-c
    // never has to digest macOS system socket/mach headers. `-w` silences ENet's
    // own C warnings; `-fno-sanitize=undefined` because ENet's retransmit logic
    // does a benign `1u << 32` shift that Debug UBSan would otherwise abort on.
    exe.root_module.addIncludePath(b.path("vendor/enet"));
    exe.root_module.addCSourceFile(.{ .file = b.path("vendor/enet/net_shim.c"), .flags = &.{ "-w", "-fno-sanitize=undefined" } });
    //endregion

    //region shaders (GLSL -> SPIR-V)
    // Vulkan consumes SPIR-V, not GLSL, so each shader is compiled at build time
    // with `glslc` and embedded into the binary. In source, `@embedFile(name)`
    // pulls in the compiled bytes (see src/render/pipeline.zig).
    addShader(b, exe, "src/shaders/gbuffer.vert", "gbuffer_vert");
    addShader(b, exe, "src/shaders/gbuffer.frag", "gbuffer_frag");
    addShader(b, exe, "src/shaders/fullscreen.vert", "fullscreen_vert");
    addShader(b, exe, "src/shaders/lighting.frag", "lighting_frag");
    addShader(b, exe, "src/shaders/taa.frag", "taa_frag");
    addShader(b, exe, "src/shaders/cull.comp", "cull_comp");
    //endregion

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // Make `zig build run` find the Vulkan loader + MoltenVK ICD at runtime even
    // from a shell that hasn't sourced the SDK's setup-env.sh (the loader lives in
    // the SDK, not a system path on macOS). Only affects this run step, not the
    // installed binary.
    if (target.result.os.tag == .macos) {
        const sdk = macosVulkanSdk(b); // the SDK's macOS dir
        run_cmd.setEnvironmentVariable("DYLD_LIBRARY_PATH", b.pathJoin(&.{ sdk, "lib" }));
        run_cmd.setEnvironmentVariable("VK_ICD_FILENAMES", b.pathJoin(&.{ sdk, "share", "vulkan", "icd.d", "MoltenVK_icd.json" }));
    }

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    //region savdump (decode .sav files)
    // Convenience step: `zig build savdump` runs the standalone Python decoder
    // in tools/decode_sav.py, which pretty-prints player.sav / world.sav. Run
    // from the project root so it finds the save files there. Extra args pass
    // through, e.g. `zig build savdump -- path/to/world.sav`.
    const savdump_cmd = b.addSystemCommand(&.{ "python3", "tools/decode_sav.py" });
    savdump_cmd.setCwd(b.path("."));
    if (b.args) |args| savdump_cmd.addArgs(args);
    const savdump_step = b.step("savdump", "Decode the .sav files to text");
    savdump_step.dependOn(&savdump_cmd.step);
    //endregion

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// Compile a GLSL shader to SPIR-V with `glslc` and expose the result to source
/// as an embeddable module named `import_name` (used via `@embedFile`).
fn addShader(b: *std.Build, exe: *std.Build.Step.Compile, src: []const u8, import_name: []const u8) void {
    const cmd = b.addSystemCommand(&.{glslcPath(b)});
    cmd.addArg("-o");
    const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{import_name}));
    cmd.addFileArg(b.path(src)); // glslc infers the stage from the .vert/.frag extension
    exe.root_module.addAnonymousImport(import_name, .{ .root_source_file = spv });
}

/// Path to the Vulkan headers directory (`.../include`), for compiling ImGui's
/// Vulkan backend. Prefers `$VULKAN_SDK/include`; falls back to this dev machine.
fn vulkanIncludePath(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| return b.pathJoin(&.{ sdk, "include" });
    return "/Users/kalob/VulkanSDK/1.4.341.1/macOS/include";
}

/// The Vulkan SDK's macOS directory (holds `lib/` and the MoltenVK ICD). When the
/// SDK's setup-env.sh is sourced, `$VULKAN_SDK` already points here; otherwise
/// fall back to this dev machine's install.
fn macosVulkanSdk(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| return sdk;
    return "/Users/kalob/VulkanSDK/1.4.341.1/macOS";
}

/// Locate `glslc`. Prefer the one in the Vulkan SDK (`$VULKAN_SDK/bin`); fall
/// back to a bare `glslc` on PATH. Keeps the build working across machines.
fn glslcPath(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| {
        return b.pathJoin(&.{ sdk, "bin", "glslc" });
    }
    return "glslc";
}

/// Resolve the path to the Vulkan registry (vk.xml) used to generate bindings.
/// Resolution order, most explicit first, so it works across machines/OSes:
///   1. `-Dvulkan-registry=/path/to/vk.xml` on the build command line
///   2. the `VULKAN_SDK` environment variable (set by the SDK's setup-env.sh)
///   3. a hardcoded fallback for this dev machine (with a warning)
fn vulkanRegistryPath(b: *std.Build) std.Build.LazyPath {
    if (b.option([]const u8, "vulkan-registry", "Path to the Vulkan registry (vk.xml)")) |p| {
        return .{ .cwd_relative = p };
    }
    if (b.graph.environ_map.get("VULKAN_SDK")) |sdk| {
        return .{ .cwd_relative = b.pathJoin(&.{ sdk, "share", "vulkan", "registry", "vk.xml" }) };
    }
    const fallback = "/Users/kalob/VulkanSDK/1.4.341.1/macOS/share/vulkan/registry/vk.xml";
    std.log.warn(
        "VULKAN_SDK not set and -Dvulkan-registry not given; falling back to {s}",
        .{fallback},
    );
    return .{ .cwd_relative = fallback };
}
