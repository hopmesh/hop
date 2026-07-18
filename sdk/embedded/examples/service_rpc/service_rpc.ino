// service_rpc: complete addressed hops:// request and response handling.
//
// RPC is statically sealed by design and is separate from forward-secret user messaging. Use
// sendMessage/onMessage for chat or other user content.

#include <Arduino.h>
#include <Hop.h>

#include <sys/time.h>
#include <time.h>

static const char *kServiceAddress = "PASTE_A_SERVICE_ADDRESS_HERE";
static hop::Hop node;
static bool requestSent = false;

static bool synchronizedUnixEpochMs(uint64_t &unix_epoch_ms) {
  struct tm time_info;
  if (!getLocalTime(&time_info, 0)) {
    return false;
  }
  struct timeval now;
  if (gettimeofday(&now, nullptr) != 0) {
    return false;
  }
  unix_epoch_ms = static_cast<uint64_t>(now.tv_sec) * 1000ULL +
                  static_cast<uint64_t>(now.tv_usec) / 1000ULL;
  return true;
}

void setup() {
  Serial.begin(115200);

  // TODO(clock transport): connect Wi-Fi first, or replace SNTP with a trusted RTC/GNSS provider.
  configTime(0, 0, "pool.ntp.org", "time.cloudflare.com");

  if (!node.begin()) {
    Serial.println("Hop begin failed");
    return;
  }
  node.setUnixTimeProvider(synchronizedUnixEpochMs);
  node.subscribe("weather");

  node.onServiceRequest([](const hop::ServiceRequest &request) {
    Serial.printf("RPC request %s/%s: ", request.service.c_str(), request.method.c_str());
    Serial.write(request.body.data(), request.body.size());
    Serial.println();

    hop::OperationStatus status = node.sendServiceResponse(request, 202, "stored ok");
    if (status != hop::OperationStatus::Ok) {
      Serial.println("RPC response failed");
    }
  });

  node.onServiceResponse([](const hop::ServiceResponse &response) {
    Serial.printf("RPC response correlation=%02x status=%u: ", response.correlationId[0],
                  static_cast<unsigned>(response.status));
    Serial.write(response.body.data(), response.body.size());
    Serial.println();
    return true;
  });

  node.onOutgoing([](uint64_t link, const uint8_t *data, size_t len) {
    (void)link;
    (void)data;
    (void)len;
    // TODO(bearer): transmit the opaque frame, and feed received frames to bytesReceived().
  });
}

void loop() {
  node.tick(static_cast<uint32_t>(millis())); // local monotonic cadence only

  if (node.ready() && !requestSent) {
    hop::SendResult result =
        node.sendServiceRequest(kServiceAddress, "weather", "report", "{\"tempF\":72}");
    requestSent = result.accepted();
    if (requestSent) {
      Serial.printf("RPC request queued, id=%02x\n", result.id[0]);
    }
  }

  delay(10);
}
