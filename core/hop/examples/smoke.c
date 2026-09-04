// smoke.c: proves libhop's C ABI runs the real Hop protocol end to end, in pure C.
//
// Two in-memory nodes (A, B) are wired by a "loopback bearer": each node's drained outbound bytes
// are fed straight into the other's hop_bytes_received. We pump that loop while ticking the clock,
// which carries the Noise handshake + §25 prekey gossip; then A sends B an untraceable (§39) message
// and we poll B's inbox until it arrives, A calls a §33 hops:// service B hosts, and A hosts a §32
// hps:// channel that B joins and reads a publication from. No radio, no Swift/Kotlin, just hop.h.
//
// Build+run is driven by smoke.sh.

#include "hop.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

// A pump endpoint: feed bytes drained from one node into the peer node on link id 1.
typedef struct { const HopNode *peer; } Pipe;

static void forward(void *ctx, uint64_t link, const uint8_t *bytes, size_t len) {
    (void)link;
    Pipe *p = (Pipe *)ctx;
    hop_bytes_received(p->peer, 1, bytes, len);  // each node has exactly one link, id 1
}

// Inbox capture.
typedef struct { int got; char text[256]; uint8_t hops; } Inbox;

static bool on_message(void *ctx, const uint8_t *inbox_id, const uint8_t *from,
                       const char *content_type, const uint8_t *body, size_t body_len,
                       uint8_t hops, uint64_t created_at) {
    (void)inbox_id; (void)from; (void)content_type; (void)created_at;
    Inbox *in = (Inbox *)ctx;
    size_t n = body_len < sizeof(in->text) - 1 ? body_len : sizeof(in->text) - 1;
    memcpy(in->text, body, n);
    in->text[n] = '\0';
    in->hops = hops;
    in->got = 1;
    return true;
}

// hops:// host-side: capture one inbound service request (so we can seal a reply to its caller).
typedef struct { int got, answered; uint8_t from[32], req_id[32]; char service[64], method[64]; } ReqCap;

static void on_request(void *ctx, const uint8_t *from, const uint8_t *request_id,
                       const char *service, const char *method, const uint8_t *args, size_t args_len) {
    (void)args; (void)args_len;
    ReqCap *r = (ReqCap *)ctx;
    if (r->got) return;
    memcpy(r->from, from, 32); memcpy(r->req_id, request_id, 32);
    snprintf(r->service, sizeof(r->service), "%s", service);
    snprintf(r->method, sizeof(r->method), "%s", method);
    r->got = 1;
}

// hops:// caller-side: capture the response sealed back to us.
typedef struct { int got; uint16_t status; char body[256]; } RespCap;

static bool on_response(void *ctx, const uint8_t *from, const uint8_t *for_request_id,
                        uint16_t status, const uint8_t *body, size_t body_len) {
    (void)from; (void)for_request_id;
    RespCap *r = (RespCap *)ctx;
    size_t n = body_len < sizeof(r->body) - 1 ? body_len : sizeof(r->body) - 1;
    memcpy(r->body, body, n); r->body[n] = '\0';
    r->status = status; r->got = 1;
    return true;
}

// hps:// subscriber-side: capture one publication flooded to a channel we joined (§32).
typedef struct { int got; char text[256]; char path[64]; uint8_t sender[32]; } HpsCap;

static bool on_publication(void *ctx, const uint8_t *id, const char *path,
                           const uint8_t *sender, const uint8_t *body, size_t body_len) {
    (void)id;
    HpsCap *h = (HpsCap *)ctx;
    size_t n = body_len < sizeof(h->text) - 1 ? body_len : sizeof(h->text) - 1;
    memcpy(h->text, body, n); h->text[n] = '\0';
    snprintf(h->path, sizeof(h->path), "%s", path);
    memcpy(h->sender, sender, 32);
    h->got = 1;
    return true;  // synchronous acceptance: core durably drops the row
}

int main(void) {
    // Both nodes share one app secret. §32 hps:// join proofs and discovery adverts are keyed to the
    // app fabric, so two nodes on different (or absent) app secrets can link and still never key each
    // other for a channel. ":memory:" keeps the store ephemeral, as hop_node_new would.
    const uint8_t app_secret[32] = { 0x60 };
    const HopNode *a = hop_node_open(":memory:", NULL, 0, app_secret, sizeof(app_secret));
    const HopNode *b = hop_node_open(":memory:", NULL, 0, app_secret, sizeof(app_secret));
    if (!a || !b) { printf("FAIL: node create\n"); return 1; }

    uint64_t now = 1700000000000ULL;  // a real clock so prekey adverts aren't judged expired
    hop_node_tick(a, now);
    hop_node_tick(b, now);
    hop_publish_prekey(a);
    hop_publish_prekey(b);

    uint8_t b_addr[32];
    if (!hop_node_address(b, b_addr)) { printf("FAIL: address\n"); return 1; }

    // Link up: A dialed (initiator), B accepted (responder). Same link id 1 each side.
    hop_link_up(a, 1, HopLinkRole_Dialer);
    hop_link_up(b, 1, HopLinkRole_Acceptor);

    Pipe to_b = { b }, to_a = { a };
    Inbox inbox = { 0 };

    // Pump the handshake + prekey gossip a bit before sending.
    for (int i = 0; i < 50; i++) {
        hop_drain_outgoing(a, forward, &to_b);
        hop_drain_outgoing(b, forward, &to_a);
        now += 100; hop_node_tick(a, now); hop_node_tick(b, now);
    }

    uint8_t msg_id[32];
    const char *text = "hello over the C ABI";
    // request_ack=1 so B seals a private delivery-ACK back to A (§39), proves the return path too.
    if (!hop_send_message(a, b_addr, "text/plain", (const uint8_t *)text, strlen(text), 1, msg_id)) {
        printf("FAIL: send_message returned false\n"); return 1;
    }

    // Pump until B receives it AND A sees it delivered (the ACK flowed back), or we give up.
    bool delivered = false; uint32_t relayed = 0, ms = 0; uint8_t dhops = 0;
    for (int i = 0; i < 400 && !(inbox.got && delivered); i++) {
        hop_drain_outgoing(a, forward, &to_b);
        hop_drain_outgoing(b, forward, &to_a);
        hop_poll_inbox(b, on_message, &inbox);
        hop_message_status(a, msg_id, &relayed, &delivered, &dhops, &ms);
        now += 100; hop_node_tick(a, now); hop_node_tick(b, now);
    }

    int ok = inbox.got && strcmp(inbox.text, text) == 0 && delivered;
    printf("%s: B inbox got=%d text=\"%s\" hops=%u | A sees delivered=%d fwd_hops=%u\n",
           ok ? "PASS" : "FAIL", inbox.got, inbox.text, inbox.hops, delivered, dhops);

    // Exercise the base58 round-trip helper too.
    char b58[64]; uint8_t back[32];
    size_t blen = hop_address_to_base58(b_addr, b58, sizeof(b58));
    int b58_ok = blen > 0 && hop_address_from_base58(b58, back) && memcmp(b_addr, back, 32) == 0;
    printf("%s: base58 round-trip (%s)\n", b58_ok ? "PASS" : "FAIL", b58);

    // hops:// FULL round trip: A requests a service B hosts; B replies; A reads the response.
    // (Unlike the datagram above, this needs HDP in BOTH directions.)
    uint8_t reqId[32];
    const char *args = "zip=80202";
    hop_send_service_request(a, b_addr, "weather", "report", (const uint8_t *)args, strlen(args), reqId);
    ReqCap req = {0}; RespCap resp = {0};
    for (int i = 0; i < 400 && !resp.got; i++) {
        hop_drain_outgoing(a, forward, &to_b);
        hop_drain_outgoing(b, forward, &to_a);
        hop_poll_service_requests(b, on_request, &req);     // B (host) sees the request...
        if (req.got && !req.answered) {                     // ...and seals a response back to its caller
            req.answered = 1;
            const char *reply = "72F sunny";
            hop_send_service_response(b, req.from, req.req_id, 200, (const uint8_t *)reply, strlen(reply));
        }
        hop_poll_service_responses(a, on_response, &resp);  // A (caller) reads the reply
        now += 100; hop_node_tick(a, now); hop_node_tick(b, now);
    }
    int svc_ok = resp.got && resp.status == 200 && strcmp(resp.body, "72F sunny") == 0;
    printf("%s: hops:// service round-trip status=%u body=\"%s\"\n", svc_ok ? "PASS" : "FAIL", resp.status, resp.body);

    // §32 hps:// GROUP round trip: A hosts an open channel, B joins it by (host address, path), A
    // publishes ONCE, and B reads the publication. This is not fan-out and not a multicast bundle:
    // one content-key-encrypted, writer-signed publication is flooded once, and membership is a
    // property of the topic's key handoff (here Open, so A hands B the keys on request).
    //
    // PLAT-005: none of this was reachable from C before version 6 of the C ABI. The C ABI had no hps exports at all,
    // so a client on it could not host, join or post to a channel, which is why this section exists.
    uint8_t a_addr[32];
    if (!hop_node_address(a, a_addr)) { printf("FAIL: host address\n"); return 1; }
    size_t pubkey_len = 0;
    int hosted = hop_hps_register(a, "lobby", HopHpsKind_Channel, HopHpsAccess_Open,
                                  HopHpsVisibility_Private, NULL, 0, &pubkey_len);
    // A channel has no service key, so a zero length here is correct; the bool is what says it hosted.
    int joined = hop_hps_subscribe(b, a_addr, "lobby", NULL);
    HpsCap hps = {0};
    int published = 0;
    const char *post = "first post in the lobby";
    for (int i = 0; i < 400 && !hps.got; i++) {
        hop_drain_outgoing(a, forward, &to_b);
        hop_drain_outgoing(b, forward, &to_a);
        // Publish once the join request has had a chance to reach A and be keyed back to B.
        if (i == 40 && !published) {
            published = hop_hps_publish(a, "lobby", (const uint8_t *)post, strlen(post), NULL);
        }
        hop_poll_hps_messages(b, on_publication, &hps);
        now += 100; hop_node_tick(a, now); hop_node_tick(b, now);
    }
    // The host also sees B as a member, which is the key-handoff side of the same event.
    size_t members = hop_hps_members(a, "lobby", NULL, NULL);
    int hps_ok = hosted && joined && published && hps.got && pubkey_len == 0 &&
                 strcmp(hps.text, post) == 0 && strcmp(hps.path, "lobby") == 0 &&
                 memcmp(hps.sender, a_addr, 32) == 0 && members >= 1;
    printf("%s: hps:// channel round-trip path=\"%s\" body=\"%s\" members=%zu\n",
           hps_ok ? "PASS" : "FAIL", hps.path, hps.text, members);
    // An accepted publication is durably removed, so a second poll must be empty.
    HpsCap again = {0};
    hop_poll_hps_messages(b, on_publication, &again);
    int accept_ok = !again.got;
    printf("%s: hps:// accepted publication is not redelivered\n", accept_ok ? "PASS" : "FAIL");

    hop_node_free(a);
    hop_node_free(b);
    return (ok && b58_ok && svc_ok && hps_ok && accept_ok) ? 0 : 1;
}
