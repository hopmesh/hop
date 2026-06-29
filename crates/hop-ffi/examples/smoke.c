// smoke.c — proves libhop's C ABI runs the real Hop protocol end to end, in pure C.
//
// Two in-memory nodes (A, B) are wired by a "loopback bearer": each node's drained outbound bytes
// are fed straight into the other's hop_bytes_received. We pump that loop while ticking the clock,
// which carries the Noise handshake + §25 prekey gossip; then A sends B an untraceable (§39) message
// and we poll B's inbox until it arrives. No radio, no Swift/Kotlin — just hop.h.
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

static void on_message(void *ctx, const uint8_t *from, const char *content_type,
                       const uint8_t *body, size_t body_len, uint8_t hops, uint64_t created_at) {
    (void)from; (void)content_type; (void)created_at;
    Inbox *in = (Inbox *)ctx;
    size_t n = body_len < sizeof(in->text) - 1 ? body_len : sizeof(in->text) - 1;
    memcpy(in->text, body, n);
    in->text[n] = '\0';
    in->hops = hops;
    in->got = 1;
}

int main(void) {
    const HopNode *a = hop_node_new();
    const HopNode *b = hop_node_new();
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
    if (!hop_send_message(a, b_addr, "text/plain", (const uint8_t *)text, strlen(text), 0, msg_id)) {
        printf("FAIL: send_message returned false\n"); return 1;
    }

    // Pump until B receives it (or we give up).
    for (int i = 0; i < 200 && !inbox.got; i++) {
        hop_drain_outgoing(a, forward, &to_b);
        hop_drain_outgoing(b, forward, &to_a);
        hop_poll_inbox(b, on_message, &inbox);
        now += 100; hop_node_tick(a, now); hop_node_tick(b, now);
    }

    int ok = inbox.got && strcmp(inbox.text, text) == 0;
    printf("%s: B inbox got=%d text=\"%s\" hops=%u\n", ok ? "PASS" : "FAIL", inbox.got, inbox.text, inbox.hops);

    hop_node_free(a);
    hop_node_free(b);
    return ok ? 0 : 1;
}
