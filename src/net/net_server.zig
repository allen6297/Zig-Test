//! Dedicated (headless) server: owns the authoritative world, runs the sim on
//! its fixed tick, and bridges the in-process `Server`/`Connection` seam to ENet.
//! No window, no rendering.
//!
//! Flow: a client connects → it's assigned an entity id and sent the world
//! edit-diff (a snapshot; terrain is deterministic, so only edits cross the wire)
//! → the client sends `set_block` actions and periodic position reports → the
//! server applies edits on tick and broadcasts block changes, and relays every
//! client's position to the others so they can render each other's avatars.
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

/// A connected client: its ENet peer, assigned entity id, and last reported state.
const Client = struct {
    peer: ?*c.NzPeer,
    id: u32,
    state: protocol.PlayerState,
    has_state: bool,
};

/// Relay a client's position to others this often (in loop iterations). The loop
/// paces at ~5 ms, so ~6 iterations ≈ 30 ms ≈ 33 Hz position updates.
const entity_broadcast_period = 6;

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

    var clients = std.ArrayList(Client).empty;
    defer clients.deinit(gpa);
    var next_id: u32 = 1;
    var broadcast_counter: u32 = 0;

    std.debug.print("server: listening on udp/{d} (Ctrl-C to stop)\n", .{port});

    while (true) {
        // 1. Network: greet new clients (id + snapshot), receive actions + position
        //    reports, and despawn disconnecting clients. The 5 ms service timeout
        //    also paces the loop.
        var ev: c.NzEvent = undefined;
        while (c.nz_service(host, &ev, 5) > 0) {
            switch (ev.kind) {
                c.NZ_CONNECT => {
                    const id = next_id;
                    next_id += 1;
                    clients.append(gpa, .{ .peer = ev.peer, .id = id, .state = undefined, .has_state = false }) catch {};
                    sendSnapshot(gpa, ev.peer, &world);
                    var b: [protocol.id_msg_len]u8 = undefined;
                    _ = c.nz_send(ev.peer, protocol.encodeIdMessage(protocol.tag_assign_id, id, &b).ptr, protocol.id_msg_len);
                    std.debug.print("server: client connected (entity {d})\n", .{id});
                },
                c.NZ_RECEIVE => {
                    if (ev.len > 0) {
                        if (protocol.decodeClientMessage(ev.data[0..ev.len])) |msg| switch (msg) {
                            .set_block => |b| conn.sendAction(.{ .set_block = b }),
                            .player_state => |ps| {
                                if (findClient(clients.items, ev.peer)) |cl| {
                                    cl.state = ps;
                                    cl.has_state = true;
                                }
                            },
                        };
                    }
                    c.nz_free_packet(&ev);
                },
                c.NZ_DISCONNECT => {
                    if (removeClient(&clients, ev.peer)) |id| {
                        var b: [protocol.id_msg_len]u8 = undefined;
                        c.nz_broadcast(host, protocol.encodeIdMessage(protocol.tag_entity_despawn, id, &b).ptr, protocol.id_msg_len);
                        std.debug.print("server: client disconnected (entity {d})\n", .{id});
                    }
                },
                else => {},
            }
        }

        // 2. Simulate: apply queued block actions, producing events. simulate()
        //    only drains actions for now (no time-dependent systems), so we advance
        //    one fixed tick per loop rather than chase a wall clock.
        server.tick(zig_test.server.tick_dt);

        // 3. Broadcast the resulting block changes to all clients.
        for (conn.eventsSlice()) |event| {
            var buf: [protocol.block_msg_len]u8 = undefined;
            const bytes = protocol.encodeEvent(event, &buf);
            c.nz_broadcast(host, bytes.ptr, bytes.len);
        }
        conn.clearEvents();

        // 4. Relay entity positions (throttled). Every client's state goes to
        //    everyone; each client ignores its own id (told to it by assign_id).
        broadcast_counter += 1;
        if (broadcast_counter >= entity_broadcast_period) {
            broadcast_counter = 0;
            for (clients.items) |cl| {
                if (!cl.has_state) continue;
                var buf: [protocol.entity_moved_len]u8 = undefined;
                const bytes = protocol.encodeEntityMoved(.{ .id = cl.id, .state = cl.state }, &buf);
                c.nz_broadcast(host, bytes.ptr, bytes.len);
            }
        }
    }
}

fn findClient(items: []Client, peer: ?*c.NzPeer) ?*Client {
    for (items) |*cl| {
        if (cl.peer == peer) return cl;
    }
    return null;
}

/// Remove the client for `peer`; returns its entity id (for a despawn) or null.
fn removeClient(clients: *std.ArrayList(Client), peer: ?*c.NzPeer) ?u32 {
    for (clients.items, 0..) |cl, i| {
        if (cl.peer == peer) {
            const id = cl.id;
            _ = clients.swapRemove(i);
            return id;
        }
    }
    return null;
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
