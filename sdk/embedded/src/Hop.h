// Hop for Embedded: a thin, idiomatic Arduino / ESP-IDF C++ wrapper over the libhop C ABI.
//
// libhop is the Hop client core (Rust) exposed as a flat C ABI (hop.h). This class wraps the handful
// of those functions an MCU client needs behind a small C++ surface: begin() opens a node, tick()
// pumps it, send() addresses a message, onMessage() hands you what arrives, and address() is your
// identity on the mesh. The wrapper owns no radio: you feed it link events and ship its outbound
// bytes over whatever bearer you have (BLE, LoRa, Wi-Fi). See README.md.
//
// The C ABI is poll model: the core never calls you asynchronously. Everything happens inside tick(),
// which you call about once a second (and after feeding inbound bytes). Pointers handed to your
// callbacks are valid ONLY for the duration of the callback; copy anything you keep.

#ifndef HOP_EMBEDDED_HOP_H
#define HOP_EMBEDDED_HOP_H

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

// The ABI version this wrapper was written against. begin() asserts the loaded libhop reports the
// same value via hop_abi_version(), so a wrapper paired with a mismatched prebuilt archive fails
// loudly at startup instead of drifting silently. Keep it in step with HOP_ABI_VERSION in hop.h.
#ifndef HOP_EMBEDDED_ABI_VERSION
#define HOP_EMBEDDED_ABI_VERSION 3
#endif

// Opaque handle to the running node, owned by libhop. Declared here so the class can hold a pointer
// without pulling in the full C ABI header (the release build stages hop.h alongside libhop.a).
struct HopNode;

namespace hop {

// Which side of a bearer link dialed out, mirroring HopLinkRole in hop.h. The side that initiated the
// connection (BLE central, TCP connect, Wi-Fi inviter) is the Dialer; the side that accepted is the
// Acceptor. This selects the Noise handshake role, so it must be reported honestly per link.
enum class LinkRole : uint32_t {
  Dialer = 0,
  Acceptor = 1,
};

// One message that arrived for this node. All pointers are borrowed for the callback only: `from` is
// 32 address bytes, `service` and `method` are NUL-terminated UTF-8, `payload` is `payload_len` bytes.
struct Message {
  const uint8_t *from;    // 32-byte sender address
  const char *service;    // e.g. "weather"
  const char *method;     // e.g. "report"
  const uint8_t *payload; // request body
  size_t payload_len;
};

// A packet the core wants shipped over your radio, handed to the OutgoingHandler during tick().
// `link` is the bearer link id you reported to linkUp(); `data`/`len` is one opaque frame. The bytes
// are borrowed for the call only.
using OutgoingHandler = std::function<void(uint64_t link, const uint8_t *data, size_t len)>;

// Called once per message that arrives, from inside tick().
using MessageHandler = std::function<void(const Message &msg)>;

// A Hop node for a microcontroller. Not copyable: it owns one libhop handle.
class Hop {
public:
  Hop() = default;
  ~Hop();

  Hop(const Hop &) = delete;
  Hop &operator=(const Hop &) = delete;

  // Open a node with a FRESH identity and in-memory storage (the minimal build has no SQLite). Returns
  // false if the loaded libhop's ABI version does not match this wrapper, or if the node fails to open.
  bool begin();

  // Open a node from a saved 32-byte identity `secret` (32 bytes). Persist the value from secret() into
  // NVS / flash and pass it here on the next boot to keep the same mesh address across reboots.
  bool begin(const uint8_t *secret, size_t secret_len);

  // True once a node is open.
  bool ready() const { return node_ != nullptr; }

  // Advance the node: expire adverts, retransmit, publish our prekey once the clock is real, drain
  // outbound packets to the OutgoingHandler, and deliver arrivals to the MessageHandler. Call about
  // once a second, and again right after feeding a batch of inbound bytes. `now_ms` is a millisecond
  // clock (Arduino millis(), or esp_timer_get_time() / 1000 under ESP-IDF).
  void tick(uint64_t now_ms);

  // Register interest in a service topic so requests for it are delivered to onMessage(). Call after
  // begin(). Matches hop_subscribe.
  void subscribe(const char *topic);

  // Send a hops:// request: invoke `method` on `service` at the 32-byte address `dst`, carrying
  // `payload`. Returns true if the request was queued. Any reply arrives later via onMessage on the
  // far side; this is store-and-forward, so it also works when the peer is not currently connected.
  bool send(const uint8_t *dst, const char *service, const char *method, const uint8_t *payload,
            size_t payload_len);

  // Convenience: `dst` as a base58 address string, `payload` as text.
  bool send(const std::string &dst_base58, const char *service, const char *method,
            const std::string &payload);

  // Set the callback invoked (inside tick()) for each message that arrives.
  void onMessage(MessageHandler handler) { on_message_ = std::move(handler); }

  // Set the callback invoked (inside tick()) for each outbound packet, so you can ship it over your
  // radio. Without it, outbound packets are dropped and nothing leaves the device.
  void onOutgoing(OutgoingHandler handler) { on_outgoing_ = std::move(handler); }

  // Bearer seam: your radio calls these as links form, carry frames, and drop.
  void linkUp(uint64_t link, LinkRole role);
  void bytesReceived(uint64_t link, const uint8_t *data, size_t len);
  void linkDown(uint64_t link);

  // This node's 32-byte address into `out` (room for 32 bytes). False before begin().
  bool addressBytes(uint8_t *out) const;

  // This node's address as a base58 string (empty before begin()). Publish this so peers can reach you.
  std::string address() const;

  // This node's 32-byte identity secret into `out` (room for 32 bytes). Save it to NVS and restore the
  // same identity next boot with begin(secret, 32). Returns bytes written (32), or 0 before begin().
  size_t secret(uint8_t *out) const;

  // Human-readable name reported via presence.
  void setName(const char *name);

private:
  // Trampolines: the C ABI sinks are plain C function pointers taking a void* context. Each casts the
  // context back to this Hop and calls the stored std::function.
  static void outgoingTrampoline(void *ctx, uint64_t link, const uint8_t *bytes, size_t len);
  static void requestTrampoline(void *ctx, const uint8_t *from, const uint8_t *request_id,
                                const char *service, const char *method, const uint8_t *args,
                                size_t args_len);

  const HopNode *node_ = nullptr;
  bool prekey_published_ = false;
  MessageHandler on_message_;
  OutgoingHandler on_outgoing_;
};

} // namespace hop

#endif // HOP_EMBEDDED_HOP_H
