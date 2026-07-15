<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop for Embedded</h1>

<p align="center">
  <b>The Hop mesh on a microcontroller.</b><br>
  A small Arduino / ESP-IDF C++ class over the <code>libhop</code> C ABI, for ESP32 and friends.
</p>

<p align="center">
  <a href="https://registry.platformio.org/libraries/hopmesh/Hop"><img src="https://img.shields.io/badge/PlatformIO-Hop-orange" alt="PlatformIO"></a>
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/platform-ESP32-6ea8fe" alt="ESP32">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
LoRa, and Wi-Fi, until they reach the person or service you meant. Held, never dropped.

**Hop for Embedded** puts a real Hop node on a microcontroller. It wraps the same `libhop` C ABI every
Hop SDK binds in a tiny C++ class: `begin()` opens a node, `tick()` pumps it, `send()` addresses a
message, `onMessage()` hands you what arrives. The library owns no radio, you feed it link events and
ship its outbound bytes over whatever bearer you have, so it drops onto BLE, a LoRa module, or Wi-Fi
without caring which. ESP32 today; more MCUs as the cross-compiles land.

## Install

In your `platformio.ini`:

```ini
[env:esp32dev]
platform = espressif32
framework = arduino
lib_deps = hopmesh/Hop
```

The library ships `Hop.h` plus a prebuilt `libhop` static archive per ESP32 architecture (xtensa and
riscv), so there is no Rust toolchain to install on your machine.

## Quick start

```cpp
#include <Hop.h>

hop::Hop node;

void setup() {
  Serial.begin(115200);
  node.begin();                          // fresh identity, in-memory (the minimal build has no SQLite)
  node.subscribe("chat");                // deliver "chat" requests to onMessage
  node.onOutgoing([](uint64_t link, const uint8_t *data, size_t len) {
    radioSend(link, data, len);          // ship this frame over YOUR bearer (BLE / LoRa / Wi-Fi)
  });
  node.onMessage([](const hop::Message &m) {
    Serial.printf("from %.8s: %.*s\n", m.service, (int)m.payload_len, m.payload);
  });
  Serial.println(node.address().c_str()); // publish this; peers reach you by it
}

void loop() {
  // feed inbound bytes from your radio: node.bytesReceived(link, buf, n);
  node.tick(millis());                    // poll-model: everything happens here, ~1 Hz
  delay(1000);
}
```

`req.from` is a **cryptographically verified** identity, not a spoofable header, and delivery is durable
store-and-forward, so a message sent to a peer that is not currently connected is held and delivered when
a path appears.

## The bearer seam

Hop does not touch your radio. As links form, carry frames, and drop, you call:

```cpp
node.linkUp(linkId, hop::LinkRole::Dialer);   // you dialed out (BLE central, Wi-Fi inviter)
node.bytesReceived(linkId, frame, frameLen);  // an inbound frame arrived
node.linkDown(linkId);                         // the link dropped
```

and the `onOutgoing` handler receives the frames Hop wants sent. The core owns all crypto; you move
opaque bytes.

## Keeping your address across reboots

`begin()` mints a fresh identity. To keep the same mesh address, save the secret once and restore it:

```cpp
uint8_t secret[32];
node.secret(secret);            // save these 32 bytes to NVS / flash
// next boot:
node.begin(secret, sizeof(secret));
```

## How it maps to the core

This is a `hop-core` node in client mode, over the same C ABI (`hop.h`) that binds every other Hop SDK,
with zero core changes. `send` is `hop_send_service_request`, `onMessage` is `hop_subscribe` +
`hop_poll_service_requests`, the bearer seam is `hop_link_up` / `hop_bytes_received` /
`hop_drain_outgoing`, and `tick` is `hop_node_tick`. `begin()` asserts `hop_abi_version()` matches, so a
wrapper paired with a mismatched prebuilt archive fails loudly at startup.

## Status

Prototype. The wrapper surface (node lifecycle, send, receive, the bearer seam, identity persistence) is
built against the real C ABI. ESP32 (xtensa and riscv) is the first target; the cross-compile pipeline
brings other MCUs as it grows. LoRa and BLE bearers are yours to wire to the seam today.

## The Hop family

`Hop for Embedded` is one of several SDKs over the same C ABI. Same protocol, your platform:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
[android](https://github.com/hopmesh/hop-sdk-android).
The protocol core is [libhop](https://github.com/hopmesh/libhop) / [hop-core](https://github.com/hopmesh/hop-core).

## License

[Apache-2.0](./LICENSE.md), use it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
