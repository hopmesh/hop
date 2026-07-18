// hop_main.c: the ESP-IDF entrypoint for the hop-sensor full client.
//
// This binds only libhop's C ABI. The integrator supplies two platform facilities:
//   1. a bearer that moves opaque Hop frames over BLE, LoRa, or Wi-Fi; and
//   2. trusted Unix wall-clock synchronization through SNTP, RTC, GNSS, or a provisioned host.
//
// FreeRTOS ticks are used only for local scheduling. gettimeofday() supplies Unix epoch milliseconds
// after synchronization. Until that gate opens, no hop_node_tick, prekey, bearer protocol, request,
// response poll, or outgoing drain is entered.

#include "hop.h"

#include "esp_log.h"
#include "esp_sntp.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>

static const char *TAG = "hop-sensor";

static const uint64_t MIN_PLAUSIBLE_UNIX_MS = 1577836800000ULL;
static const uint64_t MAX_PLAUSIBLE_UNIX_MS = 4102444800000ULL;
static const uint64_t MAX_CLOCK_LAG_MS = 1000ULL;

typedef enum {
    CLOCK_WAITING,
    CLOCK_READY,
    CLOCK_IMPLAUSIBLE,
    CLOCK_REGRESSED,
    CLOCK_STALE,
} protocol_clock_status_t;

static bool clock_anchored;
static atomic_bool clock_sync_confirmed = ATOMIC_VAR_INIT(false);
static uint64_t last_protocol_unix_ms;
static uint64_t last_wall_sample_ms;
static TickType_t last_monotonic_tick;

// ESP-IDF SNTP invokes this only after receiving synchronized wall time. RTC/GNSS integrations call
// hop_sensor_mark_clock_synchronized() after they have set and validated the system wall clock.
static void on_sntp_time_sync(struct timeval *time_value) {
    (void)time_value;
    atomic_store_explicit(&clock_sync_confirmed, true, memory_order_release);
}

void hop_sensor_mark_clock_synchronized(void) {
    atomic_store_explicit(&clock_sync_confirmed, true, memory_order_release);
}

static protocol_clock_status_t synchronized_unix_epoch_ms(TickType_t monotonic_tick,
                                                            uint64_t *out_unix_ms) {
    if (!atomic_load_explicit(&clock_sync_confirmed, memory_order_acquire)) {
        return CLOCK_WAITING;
    }
    struct timeval now;
    if (gettimeofday(&now, NULL) != 0) {
        return CLOCK_WAITING;
    }

    uint64_t unix_ms = (uint64_t)now.tv_sec * 1000ULL + (uint64_t)now.tv_usec / 1000ULL;
    if (unix_ms < MIN_PLAUSIBLE_UNIX_MS || unix_ms >= MAX_PLAUSIBLE_UNIX_MS) {
        return CLOCK_IMPLAUSIBLE;
    }
    if (clock_anchored && unix_ms < last_wall_sample_ms) {
        return CLOCK_REGRESSED;
    }
    uint64_t protocol_unix_ms = unix_ms;
    if (clock_anchored) {
        TickType_t elapsed_ticks = monotonic_tick - last_monotonic_tick;
        uint64_t elapsed_ms = (uint64_t)elapsed_ticks * (uint64_t)portTICK_PERIOD_MS;
        uint64_t expected_ms = last_protocol_unix_ms + elapsed_ms;
        if (unix_ms < expected_ms && expected_ms - unix_ms > MAX_CLOCK_LAG_MS) {
            return CLOCK_STALE;
        }
        if (expected_ms > protocol_unix_ms) {
            protocol_unix_ms = expected_ms;
        }
    }
    if (protocol_unix_ms >= MAX_PLAUSIBLE_UNIX_MS) {
        return CLOCK_IMPLAUSIBLE;
    }

    clock_anchored = true;
    last_protocol_unix_ms = protocol_unix_ms;
    last_wall_sample_ms = unix_ms;
    last_monotonic_tick = monotonic_tick;
    *out_unix_ms = protocol_unix_ms;
    return CLOCK_READY;
}

static const char *clock_status_name(protocol_clock_status_t status) {
    switch (status) {
        case CLOCK_WAITING:
            return "waiting for synchronization";
        case CLOCK_READY:
            return "ready";
        case CLOCK_IMPLAUSIBLE:
            return "implausible Unix time";
        case CLOCK_REGRESSED:
            return "wall clock regressed";
        case CLOCK_STALE:
            return "wall clock stopped advancing";
    }
    return "unknown";
}

// Replace this stub with a non-blocking queue into the real radio TX path.
static void bearer_send(void *ctx, uint64_t link, const uint8_t *bytes, size_t len) {
    (void)ctx;
    (void)bytes;
    ESP_LOGD(TAG, "bearer TX link=%llu len=%u", (unsigned long long)link, (unsigned)len);
}

typedef struct {
    bool got;
    uint8_t from[32];
    uint8_t correlation_id[32];
    uint16_t status;
    uint8_t body[96];
    size_t body_len;
} report_ack_t;

static bool on_response(void *ctx, const uint8_t *from, const uint8_t *correlation_id,
                        uint16_t status, const uint8_t *body, size_t len) {
    report_ack_t *ack = (report_ack_t *)ctx;
    size_t copied = len < sizeof(ack->body) ? len : sizeof(ack->body);
    memcpy(ack->from, from, sizeof(ack->from));
    memcpy(ack->correlation_id, correlation_id, sizeof(ack->correlation_id));
    if (copied != 0) {
        memcpy(ack->body, body, copied);
    }
    ack->body_len = copied;
    ack->status = status;
    ack->got = true;
    return true;
}

// Resolve this through HNS or provision a real service address before deployment.
static const uint8_t WEATHER_SERVICE_ADDR[32] = {0};

void app_main(void) {
    ESP_LOGI(TAG, "libhop ABI version %u", (unsigned)hop_abi_version());

    const HopNode *node = hop_node_new();
    if (node == NULL) {
        ESP_LOGE(TAG, "hop_node_new failed");
        return;
    }
    hop_node_set_name(node, "weather-esp32");

    esp_sntp_set_time_sync_notification_cb(on_sntp_time_sync);

    // Initialize Wi-Fi and ESP-IDF SNTP in the platform layer. The callback above explicitly opens
    // the synchronization gate after the first SNTP result. A trusted RTC/GNSS path sets the system
    // clock and calls hop_sensor_mark_clock_synchronized() instead. Radio hardware may initialize
    // now, but do not call hop_link_up or feed frames until this gate returns CLOCK_READY.

    report_ack_t ack = {0};
    uint8_t pending_request_id[32] = {0};
    bool request_pending = false;
    bool prekey_published = false;
    bool first_report = true;
    uint32_t report_seq = 0;
    TickType_t last_report_tick = 0;
    protocol_clock_status_t last_clock_status = CLOCK_READY;

    for (;;) {
        TickType_t monotonic_tick = xTaskGetTickCount();
        uint64_t unix_ms = 0;
        protocol_clock_status_t clock_status =
            synchronized_unix_epoch_ms(monotonic_tick, &unix_ms);

        if (clock_status != CLOCK_READY) {
            if (clock_status != last_clock_status) {
                ESP_LOGW(TAG, "protocol gated: %s", clock_status_name(clock_status));
                last_clock_status = clock_status;
            }
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        if (last_clock_status != CLOCK_READY) {
            ESP_LOGI(TAG, "trusted Unix clock synchronized; protocol ready");
            last_clock_status = CLOCK_READY;
        }

        hop_node_tick(node, unix_ms);
        if (!prekey_published) {
            prekey_published = hop_publish_prekey(node);
        }

        // Once ready, a bearer may report a link and feed frames:
        //   hop_link_up(node, 1, HopLinkRole_Dialer);
        //   hop_bytes_received(node, 1, frame, frame_len);
        //   hop_link_down(node, 1);
        hop_drain_outgoing(node, bearer_send, NULL);

        hop_poll_service_responses(node, on_response, &ack);
        if (ack.got) {
            bool correlated = request_pending &&
                              memcmp(ack.correlation_id, pending_request_id,
                                     sizeof(pending_request_id)) == 0;
            ESP_LOGI(TAG, "weather/report response status=%u correlated=%s body=%.*s",
                     (unsigned)ack.status, correlated ? "yes" : "no", (int)ack.body_len,
                     (const char *)ack.body);
            ack.got = false;
            if (correlated) {
                request_pending = false;
            }
        }

        TickType_t report_interval = pdMS_TO_TICKS(30000);
        if (first_report || monotonic_tick - last_report_tick >= report_interval) {
            first_report = false;
            last_report_tick = monotonic_tick;
            char reading[48];
            ++report_seq;
            int written = snprintf(reading, sizeof(reading), "{\"tempF\":72,\"seq\":%u}",
                                   (unsigned)report_seq);
            if (written > 0 && (size_t)written < sizeof(reading) &&
                hop_send_service_request(node, WEATHER_SERVICE_ADDR, "weather", "report",
                                         (const uint8_t *)reading, (size_t)written,
                                         pending_request_id)) {
                request_pending = true;
                ESP_LOGI(TAG, "POST weather/report seq=%u", (unsigned)report_seq);
            } else {
                ESP_LOGW(TAG, "weather/report request was not queued");
            }
        }

        vTaskDelay(pdMS_TO_TICKS(100));
    }
}
