//! ENet transport — the reliable-UDP layer that will carry the client↔server
//! protocol over a real socket. ENet is vendored (zpl-c/enet) and wrapped by a
//! thin C shim (vendor/enet/net_shim.*) so Zig only sees plain types, never the
//! macOS system headers ENet pulls in.
//!
//! For now this is the integration + a loopback self-test; the protocol
//! (de)serialisation and the networked Connection backing sit on top next.

const std = @import("std");
const zig_test = @import("zig_test");
const protocol = zig_test.protocol;

pub const c = @cImport({
    @cInclude("net_shim.h");
});

/// Default UDP port for the game server.
pub const default_port: u16 = 45123;

pub fn init() !void {
    if (c.nz_init() != 0) return error.EnetInit;
}

pub fn deinit() void {
    c.nz_deinit();
}

/// A client's ENet connection to a server. `connect` begins the handshake; the
/// connection is live once a CONNECT event arrives while servicing `host`.
pub const NetClient = struct {
    host: *c.NzHost,
    peer: *c.NzPeer,

    pub fn connect(ip: [*:0]const u8, port: u16) !NetClient {
        const host = c.nz_client() orelse return error.ClientHost;
        errdefer c.nz_host_destroy(host);
        const peer = c.nz_connect(host, ip, port) orelse return error.Connect;
        return .{ .host = host, .peer = peer };
    }

    pub fn deinit(self: *NetClient) void {
        c.nz_disconnect(self.peer);
        _ = c.nz_flush(self.host);
        c.nz_host_destroy(self.host);
    }

    /// Send an action to the server (reliable).
    pub fn sendAction(self: *NetClient, action: protocol.Action) void {
        var buf: [protocol.block_msg_len]u8 = undefined;
        const bytes = protocol.encodeAction(action, &buf);
        _ = c.nz_send(self.peer, bytes.ptr, bytes.len);
    }
};

/// End-to-end smoke test with no window and no second process: stand up a server
/// host and a client host in-process, connect over loopback, and round-trip a
/// reliable ping/pong. Proves the ENet integration compiles, links, and works.
/// Invoked by `--nettest`.
pub fn selfTest() !void {
    try init();
    defer deinit();

    const port: u16 = 45123;

    const server = c.nz_server(port, 4) orelse return error.ServerHostCreate;
    defer c.nz_host_destroy(server);

    const client = c.nz_client() orelse return error.ClientHostCreate;
    defer c.nz_host_destroy(client);

    const peer = c.nz_connect(client, "127.0.0.1", port) orelse return error.Connect;

    var connected = false;
    var server_got_ping = false;
    var client_got_pong = false;

    var iter: u32 = 0;
    while (iter < 200 and !client_got_pong) : (iter += 1) {
        var ev: c.NzEvent = undefined;

        while (c.nz_service(server, &ev, 5) > 0) {
            if (ev.kind == c.NZ_RECEIVE) {
                server_got_ping = true;
                _ = c.nz_send(ev.peer, "pong", 4);
                c.nz_free_packet(&ev);
            }
        }

        while (c.nz_service(client, &ev, 5) > 0) {
            if (ev.kind == c.NZ_CONNECT) {
                connected = true;
                _ = c.nz_send(peer, "ping", 4);
            } else if (ev.kind == c.NZ_RECEIVE) {
                client_got_pong = true;
                c.nz_free_packet(&ev);
            }
        }
    }

    if (!connected) return error.NeverConnected;
    if (!server_got_ping) return error.ServerNeverGotPing;
    if (!client_got_pong) return error.ClientNeverGotPong;
    std.debug.print("nettest: OK — loopback connect + reliable ping/pong round-trip succeeded\n", .{});
}

/// Headless client-side protocol test against a running `--server` on 127.0.0.1:
/// connect, receive the world snapshot, send a set_block action, and verify the
/// server echoes back the matching block_changed event. Exercises the full
/// multiplayer path minus rendering. Invoked by `--clienttest`.
pub fn clientTest(port: u16) !void {
    try init();
    defer deinit();

    var nc = try NetClient.connect("127.0.0.1", port);
    defer nc.deinit();

    const edit = protocol.BlockChange{ .x = 3, .y = 4, .z = 5, .block = .stone };
    var got_snapshot = false;
    var sent = false;
    var got_echo = false;

    var iter: u32 = 0;
    while (iter < 300 and !got_echo) : (iter += 1) {
        var ev: c.NzEvent = undefined;
        while (c.nz_service(nc.host, &ev, 10) > 0) {
            if (ev.kind == c.NZ_RECEIVE and ev.len > 0) {
                if (protocol.decodeServerMessage(ev.data[0..ev.len])) |msg| switch (msg) {
                    .snapshot => got_snapshot = true,
                    .block_changed => |b| {
                        if (b.x == edit.x and b.y == edit.y and b.z == edit.z and b.block == edit.block) got_echo = true;
                    },
                };
            }
            c.nz_free_packet(&ev);
        }
        if (got_snapshot and !sent) {
            nc.sendAction(.{ .set_block = edit });
            sent = true;
        }
    }

    if (!got_snapshot) return error.NoSnapshot;
    if (!got_echo) return error.NoEcho;
    std.debug.print("clienttest: OK — connected, synced snapshot, set_block echoed back\n", .{});
}
