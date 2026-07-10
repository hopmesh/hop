// hop_main.c - the ESP-IDF entrypoint for the hop-sensor full client (core-ffi-03).
//
// This is the on-chip counterpart to ../main.c (the host demo). It runs a REAL Hop node on an
// ESP32-class MCU by binding ONLY libhop's C ABI (hop.h) - no UniFFI, no SQLite, no Rust on the call
// site. It boots a node, publishes its prekey, and periodically POSTs a (stubbed) sensor reading to a
// hops:// "weather" service, draining/feeding whatever bearer the integrator wires in.
//
// The ONE piece of hardware-specific code an integrator must supply is a bearer: something that
//   (a) calls hop_link_up / hop_bytes_received / hop_link_down as a radio (BLE and/or LoRa) forms,
//       receives on, and loses links, and
//   (b) ships every packet handed to the hop_drain_outgoing callback out over that radio.
// Everything above the bearer is this file, unchanged from a deployment. The bearer seam below is
// stubbed with clearly-marked TODOs so the project builds and links today; flashing it and wiring a
// real radio is the only remaining (on-hardware) step.

#include "hop.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const char *TAG = "hop-sensor";

// --- bearer seam (integrator-supplied) --------------------------------------------------------
//
// Replace these two stubs with your radio. `bearer_send` is the drain callback hop_drain_outgoing
// invokes for each outbound packet; on real hardware you would enqueue `bytes` onto the BLE/LoRa TX
// path for `link`. When the radio receives a frame you call hop_bytes_received(node, link, buf, len)
// from your RX task, and hop_link_up / hop_link_down as connections form and drop.

static void bearer_send(void *ctx, uint64_t link, const uint8_t *bytes, size_t len) {
    (void)ctx;
    // TODO(bearer): ship `len` bytes out over the radio for `link` (BLE GATT/L2CAP or LoRa frame).
    ESP_LOGD(TAG, "bearer TX link=%llu len=%u", (unsigned long long)link, (unsigned)len);
}

// --- hops:// response capture ------------------------------------------------------------------

typedef struct {
    int got;
    uint16_t status;
} report_ack_t;

static void on_response(void *ctx, const uint8_t *from, const uint8_t *rid, uint16_t status,
                        const uint8_t *body, size_t len) {
    (void)from;
    (void)rid;
    (void)body;
    (void)len;
    report_ack_t *r = (report_ack_t *)ctx;
    r->status = status;
    r->got = 1;
}

// --- app -------------------------------------------------------------------------------------

// The cloud weather service's Hop address. On a real deployment you resolve this via HNS
// (hops://weather.example.com -> hop_resolve_hns) or ship it provisioned; here it is a placeholder
// the integrator fills in. Left zeroed so the build is self-contained.
static const uint8_t WEATHER_SERVICE_ADDR[32] = {0};

static uint64_t now_ms(void) {
    // ESP-IDF gives a millisecond tick via FreeRTOS; that is all hop_node_tick needs.
    return (uint64_t)(xTaskGetTickCount() * portTICK_PERIOD_MS);
}

void app_main(void) {
    ESP_LOGI(TAG, "libhop ABI version %u", (unsigned)hop_abi_version());

    // A full Hop node with ephemeral (in-memory) storage - the `minimal` libhop has no SQLite.
    // Persist identity across reboots by saving hop_node_secret() to NVS and passing it to
    // hop_node_with_secret() on the next boot.
    const HopNode *node = hop_node_new();
    if (!node) {
        ESP_LOGE(TAG, "hop_node_new failed");
        return;
    }
    hop_node_set_name(node, "weather-esp32");

    uint64_t t = now_ms();
    hop_node_tick(node, t);
    hop_publish_prekey(node);

    // A real integrator brings a bearer link up here once the radio has a peer:
    //   hop_link_up(node, /*link*/1, HopLinkRole_Dialer);
    // and pumps RX frames in from the radio task via hop_bytes_received(...).

    report_ack_t ack = {0};
    uint32_t report_seq = 0;

    for (;;) {
        t = now_ms();
        hop_node_tick(node, t);

        // Drain anything the node wants to send and hand it to the bearer.
        hop_drain_outgoing(node, bearer_send, NULL);

        // Pull any hops:// responses (delivery acks for our reports).
        hop_poll_service_responses(node, on_response, &ack);
        if (ack.got) {
            ESP_LOGI(TAG, "weather/report ack status=%u", (unsigned)ack.status);
            ack.got = 0;
        }

        // Once per ~30s, POST a reading to the weather service.
        if ((report_seq++ % 300) == 0) {
            char reading[48];
            // A real build reads a sensor here; stub a plausible payload.
            int n = snprintf(reading, sizeof(reading), "{\"tempF\":72,\"seq\":%u}",
                             (unsigned)report_seq);
            uint8_t rid[32];
            hop_send_service_request(node, WEATHER_SERVICE_ADDR, "weather", "report",
                                     (const uint8_t *)reading, (size_t)n, rid);
            ESP_LOGI(TAG, "POST weather/report seq=%u", (unsigned)report_seq);
        }

        vTaskDelay(pdMS_TO_TICKS(100));
    }

    // Unreachable in the loop above, but a clean-shutdown path would:
    // hop_node_free(node);
}
