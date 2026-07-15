/* net_shim.c — implements net_shim.h against ENet, and compiles the ENet
   single-header implementation (this is the one TU that defines it). */
#define ENET_IPV4_ONLY
#define ENET_IMPLEMENTATION
#include "enet.h"

#include "net_shim.h"
#include <string.h>
#include <arpa/inet.h>

int nz_init(void) { return enet_initialize(); }
void nz_deinit(void) { enet_deinitialize(); }

NzHost *nz_server(uint16_t port, size_t max_clients) {
    /* host left zeroed = 0.0.0.0 (any interface). We fill addresses with
       inet_pton directly — this fork's enet_address_set_host_ip helper is broken
       in IPv4-only mode (returns -1 without setting the host). */
    ENetAddress addr;
    memset(&addr, 0, sizeof addr);
    addr.port = port;
    return (NzHost *)enet_host_create(&addr, max_clients, 2, 0, 0);
}

NzHost *nz_client(void) {
    return (NzHost *)enet_host_create(NULL, 1, 2, 0, 0);
}

void nz_host_destroy(NzHost *host) {
    if (host) enet_host_destroy((ENetHost *)host);
}

NzPeer *nz_connect(NzHost *host, const char *ip, uint16_t port) {
    ENetAddress addr;
    memset(&addr, 0, sizeof addr);
    if (inet_pton(AF_INET, ip, &addr.host) != 1) return NULL; /* bad IP */
    addr.port = port;
    return (NzPeer *)enet_host_connect((ENetHost *)host, &addr, 2, 0);
}

void nz_disconnect(NzPeer *peer) {
    if (peer) enet_peer_disconnect((ENetPeer *)peer, 0);
}

int nz_service(NzHost *host, NzEvent *out, uint32_t timeout_ms) {
    ENetEvent ev;
    int r = enet_host_service((ENetHost *)host, &ev, timeout_ms);
    if (r <= 0) return r;

    out->peer = (NzPeer *)ev.peer;
    out->data = NULL;
    out->len = 0;
    out->packet = NULL;
    switch (ev.type) {
        case ENET_EVENT_TYPE_CONNECT:
            out->kind = NZ_CONNECT;
            break;
        case ENET_EVENT_TYPE_DISCONNECT:
        case ENET_EVENT_TYPE_DISCONNECT_TIMEOUT:
            out->kind = NZ_DISCONNECT;
            break;
        case ENET_EVENT_TYPE_RECEIVE:
            out->kind = NZ_RECEIVE;
            out->data = ev.packet->data;
            out->len = ev.packet->dataLength;
            out->packet = ev.packet;
            break;
        default:
            out->kind = NZ_NONE;
            break;
    }
    return 1;
}

void nz_free_packet(NzEvent *ev) {
    if (ev->packet) {
        enet_packet_destroy((ENetPacket *)ev->packet);
        ev->packet = NULL;
    }
}

int nz_send(NzPeer *peer, const uint8_t *data, size_t len) {
    ENetPacket *pkt = enet_packet_create(data, len, ENET_PACKET_FLAG_RELIABLE);
    return enet_peer_send((ENetPeer *)peer, 0, pkt);
}

void nz_broadcast(NzHost *host, const uint8_t *data, size_t len) {
    ENetPacket *pkt = enet_packet_create(data, len, ENET_PACKET_FLAG_RELIABLE);
    enet_host_broadcast((ENetHost *)host, 0, pkt);
}

void nz_flush(NzHost *host) { enet_host_flush((ENetHost *)host); }
