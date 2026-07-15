//! Dedicated (headless) server: owns the authoritative world, runs the sim on
//! its fixed tick, and bridges the in-process `Server`/`Connection` seam to ENet.
//! No window, no rendering.
//!
//! Flow: a client connects → the server sends it the world edit-diff (a snapshot;
//! terrain is deterministic so only edits cross the wire) → the client sends
//! `set_block` actions → the server applies them on tick and broadcasts the
//! resulting `block_changed` events to every client.
//!
//! World edits live in memory only for now (no server-side save file yet).

const std = @import("std");
const zig_test = @import("zig_test");
const net = @import("net.zig");
const c = net.c;
const protocol = zig_test.protocol;
const World = zig_test.world.World;
const Coord = zig_test.world.Coord;
const Chunk = zig_test.chunk.Chunk;

pub fn run(gpa: std.mem.Allocator, port: u16, gen: *const fn (Coord, *Chunk) void) !void {
    try net.init();
    defer net.deinit();

    const host = c.nz_server(port, 32) orelse return error.ServerHostCreate;
    defer c.nz_host_destroy(host);

    var world = World.init(gpa, gen);
    defer world.deinit();

    var conn = zig_test.connection.Connection.init(gpa);
    defer conn.deinit();
    var server = zig_test.server.Server.init(&world, &conn);

    std.debug.print("server: listening on udp/{d} (Ctrl-C to stop)\n", .{port});

    while (true) {
        // 1. Network: receive client actions, greet new clients with a snapshot.
        //    The 5 ms service timeout also paces the loop.
        var ev: c.NzEvent = undefined;
        while (c.nz_service(host, &ev, 5) > 0) {
            switch (ev.kind) {
                c.NZ_CONNECT => {
                    std.debug.print("server: client connected\n", .{});
                    sendSnapshot(gpa, ev.peer, &world);
                },
                c.NZ_RECEIVE => {
                    if (ev.len > 0) {
                        if (protocol.decodeAction(ev.data[0..ev.len])) |action| conn.sendAction(action);
                    }
                    c.nz_free_packet(&ev);
                },
                c.NZ_DISCONNECT => std.debug.print("server: client disconnected\n", .{}),
                else => {},
            }
        }

        // 2. Simulate: apply queued actions, producing events. simulate() only
        //    drains actions for now (no time-dependent systems), so we advance one
        //    fixed tick per loop rather than chase a wall clock. Wire a real
        //    monotonic clock here once fluids/mobs need accurate dt.
        server.tick(zig_test.server.tick_dt);

        // 3. Broadcast the resulting block changes to all connected clients.
        for (conn.eventsSlice()) |event| {
            var buf: [protocol.block_msg_len]u8 = undefined;
            const bytes = protocol.encodeEvent(event, &buf);
            c.nz_broadcast(host, bytes.ptr, bytes.len);
        }
        conn.clearEvents();
    }
}

/// Send the current world edit-diff to a freshly-connected peer so it syncs.
fn sendSnapshot(gpa: std.mem.Allocator, peer: ?*c.NzPeer, world: *World) void {
    const edits = world.serialize(gpa) catch return;
    defer gpa.free(edits);
    const buf = gpa.alloc(u8, edits.len + 1) catch return;
    defer gpa.free(buf);
    buf[0] = protocol.tag_snapshot;
    @memcpy(buf[1..], edits);
    _ = c.nz_send(peer, buf.ptr, buf.len);
    std.debug.print("server: sent snapshot ({d} edit bytes)\n", .{edits.len});
}
