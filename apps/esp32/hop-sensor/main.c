// hop-sensor: an EXAMPLE full Hop client in pure C, the kind an ESP32 IoT device would run: it
// makes a node, reaches the mesh over a bearer, and POSTs a sensor reading to a hops:// service,
// then reads the response. It binds ONLY libhop's C ABI (hop.h), with no UniFFI or Rust on the call
// site, which is exactly why an embedded target can be a first-class client.
//
// On a real ESP32 (ESP-IDF) you would: (1) build libhop for the Xtensa/RISC-V target and link it;
// (2) plug in a real bearer (BLE and/or LoRa) that calls hop_link_up / hop_bytes_received /
// hop_link_down and ships hop_drain_outgoing's bytes over the radio; (3) keep the loop below. See
// README.md. HERE, so the example RUNS on a dev host, the "cloud service" is a second in-process node
// wired by a loopback bearer. The only difference from a deployment is where the bytes travel. The
// fixed epoch below simulates already-synchronized wall time; it is deliberately not host uptime.

#include "hop.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef struct { const HopNode *peer; } Pipe;
static void forward(void *ctx, uint64_t link, const uint8_t *b, size_t n) { (void)link; hop_bytes_received(((Pipe *)ctx)->peer, 1, b, n); }

// The cloud weather service captures the request and what to reply. ABI 7: returning true accepts
// the request synchronously; a duplicate delivery after capture is left queued (false).
typedef struct { int got, answered; uint8_t from[32], req_id[32]; } Req;
static bool on_request(void *ctx, const uint8_t *from, const uint8_t *rid, const char *svc, const char *method,
                       const uint8_t *args, size_t alen) {
    Req *r = (Req *)ctx;
    if (r->got) return false;
    memcpy(r->from, from, 32); memcpy(r->req_id, rid, 32); r->got = 1;
    printf("[cloud] request %s/%s args=\"%.*s\"\n", svc, method, (int)alen, (const char *)args);
    return true;
}
typedef struct { int got; uint16_t status; char body[128]; } Resp;
static bool on_response(void *ctx, const uint8_t *from, const uint8_t *rid, uint16_t status, const uint8_t *b, size_t n) {
    (void)from; (void)rid; Resp *r = (Resp *)ctx;
    size_t k = n < sizeof(r->body) - 1 ? n : sizeof(r->body) - 1; memcpy(r->body, b, k); r->body[k] = 0;
    r->status = status; r->got = 1;
    return true;
}

int main(void) {
    // The sensor node (this would be the ESP32) and, for the demo, the cloud service node.
    const HopNode *sensor = hop_node_new();
    const HopNode *cloud  = hop_node_new();

    uint64_t now = 1700000000000ULL;
    hop_node_tick(sensor, now); hop_node_tick(cloud, now);
    hop_publish_prekey(sensor); hop_publish_prekey(cloud);
    hop_node_set_name(sensor, "weather-esp32");

    uint8_t cloud_addr[32];
    hop_node_address(cloud, cloud_addr);

    // A bearer brings the link up (on a real device this is BLE/LoRa discovering the gateway).
    hop_link_up(sensor, 1, HopLinkRole_Dialer);
    hop_link_up(cloud,  1, HopLinkRole_Acceptor);

    Pipe to_cloud = { cloud }, to_sensor = { sensor };
    Req req = {0}; Resp resp = {0};
    #define PUMP() do { hop_drain_outgoing(sensor, forward, &to_cloud); hop_drain_outgoing(cloud, forward, &to_sensor); \
                        now += 100; hop_node_tick(sensor, now); hop_node_tick(cloud, now); } while (0)

    for (int i = 0; i < 50; i++) PUMP();  // let the link secure (Noise + prekey gossip)

    // POST the reading to the cloud weather service over hops:// (a full request/response).
    const char *reading = "{\"tempF\":72,\"humidity\":41}";
    uint8_t rid[32];
    hop_send_service_request(sensor, cloud_addr, "weather", "report", (const uint8_t *)reading, strlen(reading), rid);
    printf("[sensor] POST weather/report -> hops://%.8s...\n", "cloud");

    for (int i = 0; i < 400 && !resp.got; i++) {
        PUMP();
        hop_poll_service_requests(cloud, on_request, &req);
        if (req.got && !req.answered) {                       // the cloud service stores it + acks
            req.answered = 1;
            const char *ack = "stored ok";
            hop_send_service_response(cloud, req.from, req.req_id, 202, (const uint8_t *)ack, strlen(ack));
        }
        hop_poll_service_responses(sensor, on_response, &resp);
    }

    int ok = resp.got && resp.status == 202;
    printf("%s: [sensor] hops:// response status=%u body=\"%s\"\n", ok ? "PASS" : "FAIL", resp.status, resp.body);

    hop_node_free(sensor); hop_node_free(cloud);
    return ok ? 0 : 1;
}
