//! Root source file for the `zig_test` package — re-exports the game modules.
const std = @import("std");

pub const block = @import("block.zig");
pub const chunk = @import("chunk.zig");
pub const world = @import("world.zig");
pub const math = @import("math.zig");
pub const camera = @import("camera.zig");
pub const raycast = @import("raycast.zig");
pub const player = @import("player.zig");
pub const noise = @import("noise.zig");

// Ensure the tests inside the game modules are discovered and run by
// `zig build test`, not just the ones written directly in this file.
test {
    std.testing.refAllDecls(block);
    std.testing.refAllDecls(chunk);
    std.testing.refAllDecls(world);
    std.testing.refAllDecls(math);
    std.testing.refAllDecls(camera);
    std.testing.refAllDecls(raycast);
    std.testing.refAllDecls(player);
    std.testing.refAllDecls(noise);
}
