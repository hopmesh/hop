// Hop for Embedded: a thin Arduino / ESP-IDF C++ wrapper over the libhop C ABI.
//
// tick() takes a wrapping monotonic millisecond counter only for local cadence. Authenticated Hop
// records use Unix epoch milliseconds from setUnixTimeProvider() or synchronizeClock(); uptime is
// never passed to the protocol clock. Until that clock is trusted, the node may be configured but
// will not publish, send, receive, or drain protocol state.

#ifndef HOP_EMBEDDED_HOP_H
#define HOP_EMBEDDED_HOP_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <utility>
#include <vector>

// The ABI version this wrapper was written against. begin() asserts the loaded libhop reports the
// same value via hop_abi_version(), so a wrapper paired with a mismatched prebuilt archive fails
// loudly at startup instead of drifting silently. Keep it in step with HOP_ABI_VERSION in hop.h.
#ifndef HOP_EMBEDDED_ABI_VERSION
#define HOP_EMBEDDED_ABI_VERSION 4
#endif

// Opaque handle to the running node, owned by libhop. Declared here so the class can hold a pointer
// without pulling in the full C ABI header (the release build stages hop.h alongside libhop.a).
struct HopNode;

namespace hop {

constexpr size_t kIdSize = 32;
constexpr uint64_t kMinPlausibleUnixEpochMs = 1577836800000ULL; // 2020-01-01 UTC
constexpr uint64_t kMaxPlausibleUnixEpochMs = 4102444800000ULL; // 2100-01-01 UTC

// The protocol clock gate. WaitingForSync is the safe bootstrap state after begin(). A clock error
// closes the gate until a later valid, non-regressing Unix time is supplied.
enum class ClockStatus : uint8_t {
  NotInitialized,
  WaitingForSync,
  Ready,
  Implausible,
  Regressed,
  Stale,
};

// Result of an operation that can cross the C ABI. Deferred is specific to sendMessage(): libhop
// accepted the content into its local queue, but cannot emit it until the peer's prekey arrives and a
// Double Ratchet session can be opened. The minimal embedded store is in-memory, so that queue does
// not survive a device restart.
enum class OperationStatus : uint8_t {
  Ok,
  Deferred,
  NotInitialized,
  ClockNotReady,
  InvalidArgument,
  CoreError,
};

struct SendResult {
  OperationStatus status;
  std::array<uint8_t, kIdSize> id;

  bool accepted() const {
    return status == OperationStatus::Ok || status == OperationStatus::Deferred;
  }
};

// Which side of a bearer link dialed out, mirroring HopLinkRole in hop.h. The side that initiated the
// connection (BLE central, TCP connect, Wi-Fi inviter) is the Dialer; the side that accepted is the
// Acceptor. This selects the Noise handshake role, so it must be reported honestly per link.
enum class LinkRole : uint32_t {
  Dialer = 0,
  Acceptor = 1,
};

// One forward-secret user message. Every field owns its bytes, so a callback may copy or retain this
// value after the C callback returns.
struct Message {
  std::array<uint8_t, kIdSize> id;
  std::array<uint8_t, kIdSize> from;
  std::string contentType;
  std::vector<uint8_t> body;
  uint8_t hops;
  uint64_t createdAtMs;
};

// One addressed hops:// request delivered to this node acting as a service. This is statically
// sealed RPC, not the Double Ratchet user-message path.
struct ServiceRequest {
  std::array<uint8_t, kIdSize> from;
  std::array<uint8_t, kIdSize> requestId;
  std::string service;
  std::string method;
  std::vector<uint8_t> body;
};

// One addressed hops:// response delivered to this node acting as a caller. correlationId is the
// request id returned by sendServiceRequest().
struct ServiceResponse {
  std::array<uint8_t, kIdSize> from;
  std::array<uint8_t, kIdSize> correlationId;
  uint16_t status;
  std::vector<uint8_t> body;
};

// A packet the core wants shipped over your radio, handed to the OutgoingHandler during tick().
// `link` is the bearer link id you reported to linkUp(); `data`/`len` is one opaque frame. The bytes
// are borrowed for the call only.
using OutgoingHandler = std::function<void(uint64_t link, const uint8_t *data, size_t len)>;

// Return true only after the application has accepted the copied message. False leaves it queued in
// libhop for redelivery on a later tick.
using MessageHandler = std::function<bool(const Message &msg)>;
using ServiceRequestHandler = std::function<void(const ServiceRequest &request)>;
// Return true for synchronous acceptance. Return false after copying the response for asynchronous
// work, then call acceptServiceResponse() when that work is durable.
using ServiceResponseHandler = std::function<bool(const ServiceResponse &response)>;
using UnixTimeProvider = std::function<bool(uint64_t &unix_epoch_ms)>;

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

  // True once the C node is open. ready() additionally requires a trusted protocol clock.
  bool initialized() const { return node_ != nullptr; }
  bool ready() const { return node_ != nullptr && clock_status_ == ClockStatus::Ready; }
  ClockStatus clockStatus() const { return clock_status_; }

  // Supply a trusted Unix epoch-millisecond source. tick() samples it synchronously. Once a valid
  // sample has anchored the clock, temporary provider unavailability is bridged by monotonic elapsed
  // time. An implausible, stale, or regressing sample closes the protocol gate safely.
  void setUnixTimeProvider(UnixTimeProvider provider) { unix_time_provider_ = std::move(provider); }

  // Explicitly anchor protocol time after an RTC, GNSS, host, or SNTP synchronization event. The
  // monotonic value is a local wrapping millisecond counter, such as Arduino millis(); it is never
  // treated as an epoch. A valid anchor ticks the core immediately and enables protocol operations.
  ClockStatus synchronizeClock(uint64_t unix_epoch_ms, uint32_t monotonic_ms);

  // Pump the poll-model core. `monotonic_ms` is only local cadence and may wrap. The authenticated
  // protocol timestamp comes from the trusted anchor/provider. With no trusted epoch, this returns
  // WaitingForSync (or the clock error) without entering time-dependent C functions.
  ClockStatus tick(uint32_t monotonic_ms);

  // Register interest in a service topic so addressed requests are delivered to onServiceRequest().
  // Call after begin(). Matches hop_subscribe.
  void subscribe(const char *topic);

  // Send forward-secret user content through hop_send_message. Ok means a ratcheted bundle was
  // emitted; Deferred means it was safely queued pending the peer's prekey/session. Both return a
  // stable 32-byte id. This path never falls back to addressed service RPC.
  SendResult sendMessage(const uint8_t *dst, size_t dst_len, const char *content_type,
                         const uint8_t *body, size_t body_len, bool request_ack = false);

  template <size_t N>
  SendResult sendMessage(const uint8_t (&dst)[N], const char *content_type, const uint8_t *body,
                         size_t body_len, bool request_ack = false) {
    return sendMessage(dst, N, content_type, body, body_len, request_ack);
  }

  // Convenience: base58 destination and text body.
  SendResult sendMessage(const std::string &dst_base58, const std::string &body,
                         bool request_ack = false, const char *content_type = "text/plain");

  // Addressed hops:// RPC. This is intentionally named and separate from user messaging.
  SendResult sendServiceRequest(const uint8_t *dst, size_t dst_len, const char *service,
                                const char *method, const uint8_t *body, size_t body_len);

  template <size_t N>
  SendResult sendServiceRequest(const uint8_t (&dst)[N], const char *service, const char *method,
                                const uint8_t *body, size_t body_len) {
    return sendServiceRequest(dst, N, service, method, body, body_len);
  }

  SendResult sendServiceRequest(const std::string &dst_base58, const char *service,
                                const char *method, const std::string &body);

  OperationStatus sendServiceResponse(const uint8_t *to, size_t to_len,
                                      const uint8_t *request_id, size_t request_id_len,
                                      uint16_t status, const uint8_t *body, size_t body_len);

  template <size_t ToN, size_t RequestN>
  OperationStatus sendServiceResponse(const uint8_t (&to)[ToN],
                                      const uint8_t (&request_id)[RequestN], uint16_t status,
                                      const uint8_t *body, size_t body_len) {
    return sendServiceResponse(to, ToN, request_id, RequestN, status, body, body_len);
  }

  OperationStatus sendServiceResponse(const ServiceRequest &request, uint16_t status,
                                      const std::string &body);

  bool acceptServiceResponse(const uint8_t *request_id, size_t request_id_len);

  template <size_t N> bool acceptServiceResponse(const uint8_t (&request_id)[N]) {
    return acceptServiceResponse(request_id, N);
  }

  bool acceptServiceResponse(const ServiceResponse &response) {
    return acceptServiceResponse(response.correlationId.data(), response.correlationId.size());
  }

  // Set the callback invoked (inside tick()) for each message that arrives.
  void onMessage(MessageHandler handler) { on_message_ = std::move(handler); }

  void onServiceRequest(ServiceRequestHandler handler) {
    on_service_request_ = std::move(handler);
  }

  void onServiceResponse(ServiceResponseHandler handler) {
    on_service_response_ = std::move(handler);
  }

  // Set the callback invoked (inside tick()) for each outbound packet, so you can ship it over your
  // radio. Without it, outbound packets are dropped and nothing leaves the device.
  void onOutgoing(OutgoingHandler handler) { on_outgoing_ = std::move(handler); }

  // Bearer seam: initialize the radio whenever needed, but do not enter the Hop protocol until the
  // clock gate is ready. linkDown remains available after a later clock fault so links can be cleaned
  // up safely.
  OperationStatus linkUp(uint64_t link, LinkRole role);
  OperationStatus bytesReceived(uint64_t link, const uint8_t *data, size_t len);
  OperationStatus linkDown(uint64_t link);

  // This node's 32-byte address into `out` (room for 32 bytes). False before begin().
  bool addressBytes(uint8_t *out, size_t out_len) const;

  template <size_t N> bool addressBytes(uint8_t (&out)[N]) const {
    return addressBytes(out, N);
  }

  // This node's address as a base58 string (empty before begin()). Publish this so peers can reach you.
  std::string address() const;

  // This node's 32-byte identity secret into `out` (room for 32 bytes). Save it to NVS and restore the
  // same identity next boot with begin(secret, 32). Returns bytes written (32), or 0 before begin().
  size_t secret(uint8_t *out, size_t out_len) const;

  template <size_t N> size_t secret(uint8_t (&out)[N]) const { return secret(out, N); }

  // Human-readable name reported via presence.
  void setName(const char *name);

private:
  // Trampolines: the C ABI sinks are plain C function pointers taking a void* context. Each casts the
  // context back to this Hop and calls the stored std::function.
  static void outgoingTrampoline(void *ctx, uint64_t link, const uint8_t *bytes, size_t len);
  static bool messageTrampoline(void *ctx, const uint8_t *inbox_id, const uint8_t *from,
                                const char *content_type, const uint8_t *body, size_t body_len,
                                uint8_t hops, uint64_t created_at_ms);
  static void requestTrampoline(void *ctx, const uint8_t *from, const uint8_t *request_id,
                                 const char *service, const char *method, const uint8_t *args,
                                 size_t args_len);
  static bool responseTrampoline(void *ctx, const uint8_t *from, const uint8_t *request_id,
                                 uint16_t status, const uint8_t *body, size_t body_len);

  void resetNode();
  void resetClock();
  ClockStatus acceptUnixTime(uint64_t unix_epoch_ms, uint32_t monotonic_ms,
                             bool trusted_wall_sample);
  void pump();
  static SendResult result(OperationStatus status);

  const HopNode *node_ = nullptr;
  bool prekey_published_ = false;
  bool monotonic_anchored_ = false;
  bool wall_sample_anchored_ = false;
  uint32_t last_monotonic_ms_ = 0;
  uint64_t last_unix_epoch_ms_ = 0;
  uint64_t last_wall_sample_ms_ = 0;
  ClockStatus clock_status_ = ClockStatus::NotInitialized;
  UnixTimeProvider unix_time_provider_;
  MessageHandler on_message_;
  ServiceRequestHandler on_service_request_;
  ServiceResponseHandler on_service_response_;
  OutgoingHandler on_outgoing_;
};

} // namespace hop

#endif // HOP_EMBEDDED_HOP_H
