//! The authoritative server: the single owner of world truth. It runs the game
//! simulation on a **fixed tick**, decoupled from the client's variable-rate
//! rendering, applies validated client actions, and emits events describing what
//! changed. In single-player it lives in the same process as the client; in
//! multiplayer it's the same code behind a socket.
//!
//! `simulate()` is the seam everything world-side hangs off — block updates,
//! fluids, mob AI, entity/contraption physics all land here later. It's kept as a
//! clean boundary even while nearly empty.

const std = @import("std");
const World = @import("world.zig").World;
const Connection = @import("connection.zig").Connection;
const protocol = @import("protocol.zig");

/// Simulation tick rate. Fixed and modest — world logic doesn't need frame rate.
pub const tick_hz = 30;
pub const tick_dt: f32 = 1.0 / @as(f32, @floatFromInt(tick_hz));

pub const Server = struct {
    world: *World,
    conn: *Connection,
    accumulator: f32 = 0,

    pub fn init(world: *World, conn: *Connection) Server {
        return .{ .world = world, .conn = conn };
    }

    /// Advance by real elapsed time `dt`, running `simulate` on the fixed tick.
    /// Zero or more ticks per call, so the sim stays deterministic regardless of
    /// frame rate (the classic accumulator loop).
    pub fn tick(self: *Server, dt: f32) void {
        self.accumulator += dt;
        // Clamp so a long stall (e.g. a chunk-load hitch) doesn't spiral into a
        // burst of catch-up ticks.
        if (self.accumulator > 0.25) self.accumulator = 0.25;
        while (self.accumulator >= tick_dt) : (self.accumulator -= tick_dt) {
            self.simulate(tick_dt);
        }
    }

    /// One fixed simulation step: apply the client's pending actions (the only
    /// path to mutating the world), then run world systems. Systems are empty for
    /// now — this is where block updates, fluids, mob AI, and entity physics go.
    fn simulate(self: *Server, dt: f32) void {
        _ = dt;
        for (self.conn.actionsSlice()) |action| self.applyAction(action);
        self.conn.clearActions();
        // TODO: tick world systems here.
    }

    /// Validate + apply one action, emitting an event for the client on success.
    /// The client never mutates the world — this is the only place `setBlock`
    /// happens in normal play. (Reach/permission validation lands here later.)
    fn applyAction(self: *Server, action: protocol.Action) void {
        switch (action) {
            .set_block => |b| {
                self.world.setBlock(b.x, b.y, b.z, b.block) catch return;
                self.conn.emitEvent(.{ .block_changed = b });
            },
        }
    }
};

test "server applies a set_block action on tick and emits an event" {
    const testing = std.testing;
    var world = World.init(testing.allocator, null); // null gen → air chunks
    defer world.deinit();
    var conn = Connection.init(testing.allocator);
    defer conn.deinit();
    var server = Server.init(&world, &conn);

    conn.sendAction(.{ .set_block = .{ .x = 5, .y = 6, .z = 7, .block = .stone } });
    server.tick(1.0); // plenty of ticks; action processed on the first

    try testing.expectEqual(@import("block.zig").BlockId.stone, world.blockAt(5, 6, 7));
    try testing.expectEqual(@as(usize, 1), conn.eventsSlice().len);
    try testing.expectEqual(@as(usize, 0), conn.actionsSlice().len); // drained
}
