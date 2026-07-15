//! ENet transport — the reliable-UDP layer that will carry the client↔server
//! protocol over a real socket. ENet is vendored (zpl-c/enet) and wrapped by a
//! thin C shim (vendor/enet/net_shim.*) so Zig only sees plain types, never the
//! macOS system headers ENet pulls in.
//!
//! For now this is the integration + a loopback self-test; the protocol
//! (de)serialisation and the networked Connection backing sit on top next.

const std = @import("std");

pub const c = @cImport({
    @cInclude("net_shim.h");
});

pub fn init() !void {
    if (c.nz_init() != 0) return error.EnetInit;
}

pub fn deinit() void {
    c.nz_deinit();
}

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
