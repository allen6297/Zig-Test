/* net_shim.h — a thin C API over ENet.
 *
 * ENet's header pulls in system socket/mach headers that Zig's translate-c can't
 * digest on macOS. So instead of `@cImport`-ing enet.h, we expose only this
 * minimal surface — plain integer types and opaque handles — which translate-c
 * handles cleanly. net_shim.c implements it against ENet.
 */
#ifndef NET_SHIM_H
#define NET_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef struct NzHost NzHost; /* opaque ENetHost */
typedef struct NzPeer NzPeer; /* opaque ENetPeer */

/* Event kinds returned by nz_service. */
enum {
    NZ_NONE = 0,
    NZ_CONNECT = 1,
    NZ_DISCONNECT = 2,
    NZ_RECEIVE = 3,
};

typedef struct {
    int kind;      /* one of NZ_* */
    NzPeer *peer;  /* the peer this event is from */
    uint8_t *data; /* received bytes (RECEIVE only), valid until nz_free_packet */
    size_t len;    /* received length (RECEIVE only) */
    void *packet;  /* opaque ENetPacket* to free after a RECEIVE */
} NzEvent;

int nz_init(void);   /* 0 on success */
void nz_deinit(void);

NzHost *nz_server(uint16_t port, size_t max_clients); /* listening host, or NULL */
NzHost *nz_client(void);                              /* client host, or NULL */
void nz_host_destroy(NzHost *host);

NzPeer *nz_connect(NzHost *host, const char *ip, uint16_t port); /* peer, or NULL */
void nz_disconnect(NzPeer *peer);

/* Poll one event, waiting up to timeout_ms. Returns 1 if `out` was written, 0 if
 * no event, <0 on error. Free RECEIVE packets with nz_free_packet. */
int nz_service(NzHost *host, NzEvent *out, uint32_t timeout_ms);
void nz_free_packet(NzEvent *ev);

int nz_send(NzPeer *peer, const uint8_t *data, size_t len);       /* reliable; 0 = ok */
void nz_broadcast(NzHost *host, const uint8_t *data, size_t len); /* reliable, all peers */
void nz_flush(NzHost *host);

#endif /* NET_SHIM_H */
