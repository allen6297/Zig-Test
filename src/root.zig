//! Root source file for the `zig_test` package — re-exports the game modules.
const std = @import("std");

pub const block = @import("world/block.zig");
pub const chunk = @import("world/chunk.zig");
pub const world = @import("world/world.zig");
pub const math = @import("math.zig");
pub const camera = @import("game/camera.zig");
pub const raycast = @import("world/raycast.zig");
pub const player = @import("game/player.zig");
pub const noise = @import("world/noise.zig");
pub const protocol = @import("net/protocol.zig");
pub const connection = @import("net/connection.zig");
pub const server = @import("net/server.zig");

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
    std.testing.refAllDecls(protocol);
    std.testing.refAllDecls(server);
}
