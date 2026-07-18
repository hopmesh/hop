<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop for Embedded</h1>

<p align="center">
  <b>The Hop mesh on a microcontroller.</b><br>
  A small Arduino / ESP-IDF C++ class over the <code>libhop</code> C ABI, for ESP32 and friends.
</p>

Hop for Embedded runs a real Hop node on a microcontroller. It exposes forward-secret user messaging,
addressed `hops://` RPC, identity persistence, and a radio-neutral bearer seam over the same `libhop`
C ABI used by the other SDKs.

## Install

```ini
[env:esp32dev]
platform = espressif32
framework = arduino
lib_deps = hopmesh/Hop
```

The package supplies `Hop.h` and a prebuilt `libhop` archive for each exact supported Rust target.
Each archive is bound to the canonical repository, full source SHA, tag/version, builder workflow/run,
target, size, and SHA-256 by a detached-signed manifest. `link-libhop.py` verifies the signature and
archive inventory before extracting only the target mapped to the selected MCU. The PlatformIO build
does not need the network after the signed package has been installed.

For a source checkout or an offline mirror, stage the same verified release payload with:

```sh
python3 install-libhop.py --version v0.0.1
# or: python3 install-libhop.py --bundle /path/to/release-assets
```

Use repeated `--target <exact-triple>` options to install only the boards this checkout builds.

## Clock Contract

Hop protocol time is authenticated data. Bundle creation, advert expiry, rotating prekeys, mailbox
epochs, and receiver beacons require plausible Unix epoch milliseconds. Device uptime is not Unix
time.

After `begin()`, the node is initialized but intentionally not protocol-ready. Supply time in one of
two ways:

```cpp
node.setUnixTimeProvider([](uint64_t &unixEpochMs) {
  // Return false until SNTP, GNSS, a trusted host, or an RTC has synchronized.
  return readTrustedUnixEpochMilliseconds(unixEpochMs);
});
```

or anchor a one-time trusted sample for offline operation:

```cpp
node.synchronizeClock(trustedUnixEpochMs, static_cast<uint32_t>(millis()));
```

Then pump with a local monotonic counter:

```cpp
hop::ClockStatus status = node.tick(static_cast<uint32_t>(millis()));
if (status != hop::ClockStatus::Ready) {
  // Keep transports initialized, but wait. No authenticated Hop state is emitted.
}
```

`millis()` is used only to advance elapsed local time and remains safe across rollover. It is never
used as the Unix epoch origin. A provider sample outside 2020 through 2099, behind the last accepted
time, or stale relative to monotonic progress closes the gate. A later valid sample reopens it. Every
restart begins in `WaitingForSync`; a prior process's clock anchor is not trusted implicitly.

For ESP32, obtain epoch time from `gettimeofday()` only after an explicit SNTP/RTC synchronization
gate. Do not use `esp_timer_get_time()`, FreeRTOS ticks, or Arduino uptime as protocol epoch time.

## Forward-Secret Messaging

User content uses `sendMessage`, which calls `hop_send_message`. It never falls back to statically
sealed service requests.

```cpp
node.onMessage([](const hop::Message &message) {
  consume(message.from, message.contentType, message.body);
  return true; // synchronous acceptance; false requests redelivery
});

hop::SendResult result = node.sendMessage(peerAddress, "hello", true);
if (result.status == hop::OperationStatus::Deferred) {
  // Accepted locally, waiting for the peer prekey and a Double Ratchet session.
}
```

`Ok` means a ratcheted bundle was emitted. `Deferred` means libhop accepted the message into its local
queue but has not emitted user content because no peer prekey/session is available yet. The minimal
embedded store is in-memory, so deferred state does not survive a device restart.

Every `Message` owns copies of its id, sender, content type, and body. Retaining or copying it after the
callback returns is safe.

## Addressed RPC

`hops://` service RPC is statically sealed by design and has explicit names so it cannot be mistaken
for chat:

```cpp
node.subscribe("weather");

node.onServiceRequest([](const hop::ServiceRequest &request) {
  // request.from and request.requestId are owned 32-byte values.
  node.sendServiceResponse(request, 202, "stored ok");
});

hop::SendResult request =
    node.sendServiceRequest(serviceAddress, "weather", "report", "{\"tempF\":72}");

node.onServiceResponse([](const hop::ServiceResponse &response) {
  // response.from, response.status, response.body, and response.correlationId are owned values.
  return true; // synchronous processing is complete
});
```

For asynchronous work, copy the response and return `false`; call
`node.acceptServiceResponse(response)` only after that work is durable.

See `examples/service_rpc` for the complete caller and service flow. Use `examples/blink_send` for
forward-secret user messaging.

## Bearer Seam

Hop does not own a radio. Once `ready()` is true, report links and frames:

```cpp
node.linkUp(linkId, hop::LinkRole::Dialer);
node.bytesReceived(linkId, frame, frameLen);
node.linkDown(linkId);
```

`onOutgoing` receives opaque frames to transmit. `linkUp` and `bytesReceived` return
`ClockNotReady` before trusted epoch time, preventing inbound work from creating near-zero protocol
records. `linkDown` remains available for cleanup after a later clock fault.

## Identity Persistence

```cpp
uint8_t secret[32];
node.secret(secret); // save to NVS or flash

// On the next boot, before supplying a fresh trusted clock:
node.begin(secret, sizeof(secret));
```

## C ABI Mapping

| C++ surface | C ABI |
| --- | --- |
| `sendMessage` / `onMessage` | `hop_send_message` / `hop_poll_inbox` |
| `sendServiceRequest` | `hop_send_service_request` |
| `sendServiceResponse` | `hop_send_service_response` |
| `acceptServiceResponse` | `hop_accept_service_response` |
| `onServiceRequest` / `onServiceResponse` | `hop_poll_service_requests` / `hop_poll_service_responses` |
| `tick` after clock validation | `hop_node_tick` |
| bearer seam | `hop_link_up` / `hop_bytes_received` / `hop_drain_outgoing` |

`begin()` asserts ABI 4 through `hop_abi_version()` so a stale prebuilt archive fails at startup.
Every wrapper input consumed by C as exactly 32 bytes is size-checked before that pointer enters C.

## Host Tests

The mock-C host suite compiles the wrapper with strict warnings and proves clock gating, rollover,
restart behavior, exact symbol routing, complete RPC correlation, fixed-width rejection, and callback
byte ownership:

```sh
bash test/run-host-tests.sh
```

## License

[Apache-2.0](./LICENSE.md). The protocol core (`hop-core`) is FSL-1.1-ALv2 and converts to Apache-2.0
after two years.
