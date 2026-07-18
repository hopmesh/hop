// blink_send: the smallest honest forward-secret Hop messenger for an ESP32.
//
// Connect Wi-Fi or another trusted time source before configTime() can complete. The radio carrying
// Hop frames is still integrator-supplied at the TODO(bearer) points. A clockless device may bring up
// hardware and wait, but this sketch does not publish or send Hop state until Unix time is trusted.

#include <Arduino.h>
#include <Hop.h>

#include <sys/time.h>
#include <time.h>

static const int kButtonPin = 0;
static const char *kPeerAddress = "PASTE_A_PEER_ADDRESS_HERE";

static hop::Hop node;
static int lastButton = HIGH;
static hop::ClockStatus lastClockStatus = hop::ClockStatus::NotInitialized;

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
  delay(200);
  pinMode(kButtonPin, INPUT_PULLUP);

  // TODO(clock transport): connect Wi-Fi before this call, or replace SNTP with a trusted RTC/GNSS
  // provider. configTime() starts synchronization; the provider above stays false until it succeeds.
  configTime(0, 0, "pool.ntp.org", "time.cloudflare.com");

  if (!node.begin()) {
    Serial.println("Hop: begin() failed (ABI mismatch or out of memory). Halting.");
    while (true) {
      delay(1000);
    }
  }
  node.setUnixTimeProvider(synchronizedUnixEpochMs);
  node.setName("blink-send");

  node.onMessage([](const hop::Message &message) {
    Serial.print("message from address byte ");
    Serial.print(message.from[0], HEX);
    Serial.print(": ");
    Serial.write(message.body.data(), message.body.size());
    Serial.println();
    return true; // accepted; libhop may remove it and emit its delivery acknowledgement
  });

  node.onOutgoing([](uint64_t link, const uint8_t *data, size_t len) {
    (void)link;
    (void)data;
    (void)len;
    // TODO(bearer): transmit these `len` opaque bytes over BLE, LoRa, or Wi-Fi for `link`.
  });

  Serial.print("Hop address: ");
  Serial.println(node.address().c_str());

  // After node.ready() becomes true, report links and frames through the bearer seam:
  //   node.linkUp(linkId, hop::LinkRole::Dialer);
  //   node.bytesReceived(linkId, frame, frameLen);
  //   node.linkDown(linkId);
}

void loop() {
  // millis() is used only as a wrapping monotonic cadence counter. Unix protocol time comes from
  // synchronizedUnixEpochMs; tick() never treats uptime as an epoch.
  hop::ClockStatus clock_status = node.tick(static_cast<uint32_t>(millis()));
  if (clock_status != lastClockStatus) {
    if (clock_status == hop::ClockStatus::Ready) {
      Serial.println("Hop: Unix clock synchronized; protocol ready.");
    } else {
      Serial.println("Hop: waiting for a trusted Unix clock; protocol remains gated.");
    }
    lastClockStatus = clock_status;
  }

  int button = digitalRead(kButtonPin);
  if (lastButton == HIGH && button == LOW) {
    hop::SendResult result =
        node.sendMessage(kPeerAddress, "hello from blink_send", true, "text/plain");
    if (result.status == hop::OperationStatus::Ok) {
      Serial.println("message sent with Double Ratchet protection");
    } else if (result.status == hop::OperationStatus::Deferred) {
      Serial.println("message safely deferred until the peer prekey arrives");
    } else if (result.status == hop::OperationStatus::ClockNotReady) {
      Serial.println("message blocked: waiting for trusted Unix time");
    } else {
      Serial.println("message failed: set a valid peer address and check node status");
    }
    delay(50);
  }
  lastButton = button;

  delay(10);
}
