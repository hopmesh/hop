// Implementation of the Hop for Embedded wrapper. The libhop functions it calls are declared in the
// extern "C" block below, exactly as they appear in the C ABI header (hop.h). The wrapper does not
// #include hop.h so it builds before the release step stages the header; it links against the prebuilt
// libhop.a for the target chip. Keep these signatures in step with hop.h.

#include "Hop.h"

#include <algorithm>

extern "C" {

// Version + lifecycle.
uint32_t hop_abi_version(void);
const HopNode *hop_node_new(void);
const HopNode *hop_node_with_secret(const uint8_t *secret, uintptr_t secret_len);
void hop_node_free(const HopNode *node);

// Identity + presence.
bool hop_node_address(const HopNode *node, uint8_t *out);
uintptr_t hop_node_secret(const HopNode *node, uint8_t *out);
void hop_node_set_name(const HopNode *node, const char *name);

// Time + prekey.
void hop_node_tick(const HopNode *node, uint64_t now_ms);
bool hop_publish_prekey(const HopNode *node);

// Forward-secret messaging.
bool hop_send_message(const HopNode *node, const uint8_t *dst, const char *content_type,
                      const uint8_t *body, uintptr_t body_len, bool request_ack, uint8_t *out_id);
bool hop_is_secured(const HopNode *node, const uint8_t *addr);
void hop_poll_inbox(const HopNode *node,
                    bool (*sink)(void *ctx, const uint8_t *inbox_id, const uint8_t *from,
                                 const char *content_type, const uint8_t *body, uintptr_t body_len,
                                 uint8_t hops, uint64_t created_at_ms),
                    void *ctx);

// Directory + addressed service RPC.
void hop_subscribe(const HopNode *node, const char *topic);
bool hop_send_service_request(const HopNode *node, const uint8_t *dst, const char *service,
                               const char *method, const uint8_t *args, uintptr_t args_len,
                               uint8_t *out_id);
bool hop_send_service_response(const HopNode *node, const uint8_t *to,
                                const uint8_t *for_request_id, uint16_t status,
                                const uint8_t *body, uintptr_t body_len);
bool hop_accept_service_response(const HopNode *node, const uint8_t *for_request_id);
void hop_poll_service_requests(const HopNode *node,
                               void (*sink)(void *ctx, const uint8_t *from, const uint8_t *request_id,
                                             const char *service, const char *method,
                                             const uint8_t *args, uintptr_t args_len),
                               void *ctx);
void hop_poll_service_responses(const HopNode *node,
                                 bool (*sink)(void *ctx, const uint8_t *from,
                                              const uint8_t *for_request_id, uint16_t status,
                                              const uint8_t *body, uintptr_t body_len),
                                 void *ctx);

// Bearer seam.
void hop_link_up(const HopNode *node, uint64_t link, uint32_t role);
void hop_bytes_received(const HopNode *node, uint64_t link, const uint8_t *data, uintptr_t len);
void hop_link_down(const HopNode *node, uint64_t link);
void hop_drain_outgoing(const HopNode *node,
                        void (*sink)(void *ctx, uint64_t link, const uint8_t *bytes, uintptr_t len),
                        void *ctx);

// Address encoding.
uintptr_t hop_address_to_base58(const uint8_t *addr, char *out, uintptr_t out_cap);
bool hop_address_from_base58(const char *text, uint8_t *out32);

} // extern "C"

namespace hop {

namespace {

constexpr uint64_t kProviderLagToleranceMs = 1000;

std::array<uint8_t, kIdSize> copyId(const uint8_t *bytes) {
  std::array<uint8_t, kIdSize> result = {};
  if (bytes != nullptr) {
    std::copy(bytes, bytes + kIdSize, result.begin());
  }
  return result;
}

std::vector<uint8_t> copyBytes(const uint8_t *bytes, size_t len) {
  if (bytes == nullptr || len == 0) {
    return std::vector<uint8_t>();
  }
  return std::vector<uint8_t>(bytes, bytes + len);
}

} // namespace

Hop::~Hop() {
  resetNode();
}

bool Hop::begin() {
  resetNode();
  resetClock();
  if (hop_abi_version() != HOP_EMBEDDED_ABI_VERSION) {
    return false;
  }
  node_ = hop_node_new();
  clock_status_ = node_ == nullptr ? ClockStatus::NotInitialized : ClockStatus::WaitingForSync;
  return node_ != nullptr;
}

bool Hop::begin(const uint8_t *secret, size_t secret_len) {
  if (secret == nullptr || secret_len != kIdSize) {
    return false;
  }
  resetNode();
  resetClock();
  if (hop_abi_version() != HOP_EMBEDDED_ABI_VERSION) {
    return false;
  }
  node_ = hop_node_with_secret(secret, static_cast<uintptr_t>(secret_len));
  clock_status_ = node_ == nullptr ? ClockStatus::NotInitialized : ClockStatus::WaitingForSync;
  return node_ != nullptr;
}

ClockStatus Hop::synchronizeClock(uint64_t unix_epoch_ms, uint32_t monotonic_ms) {
  if (node_ == nullptr) {
    clock_status_ = ClockStatus::NotInitialized;
    return clock_status_;
  }
  return acceptUnixTime(unix_epoch_ms, monotonic_ms, true);
}

ClockStatus Hop::tick(uint32_t monotonic_ms) {
  if (node_ == nullptr) {
    clock_status_ = ClockStatus::NotInitialized;
    return clock_status_;
  }

  uint64_t provided_unix_ms = 0;
  if (unix_time_provider_ && unix_time_provider_(provided_unix_ms)) {
    if (acceptUnixTime(provided_unix_ms, monotonic_ms, true) != ClockStatus::Ready) {
      return clock_status_;
    }
  } else if (clock_status_ == ClockStatus::Implausible ||
             clock_status_ == ClockStatus::Regressed || clock_status_ == ClockStatus::Stale) {
    return clock_status_;
  } else if (!monotonic_anchored_) {
    clock_status_ = ClockStatus::WaitingForSync;
    return clock_status_;
  } else {
    const uint32_t elapsed_ms = monotonic_ms - last_monotonic_ms_;
    if (acceptUnixTime(last_unix_epoch_ms_ + elapsed_ms, monotonic_ms, false) !=
        ClockStatus::Ready) {
      return clock_status_;
    }
  }

  pump();
  return clock_status_;
}

void Hop::subscribe(const char *topic) {
  if (node_ != nullptr) {
    hop_subscribe(node_, topic);
  }
}

SendResult Hop::sendMessage(const uint8_t *dst, size_t dst_len, const char *content_type,
                            const uint8_t *body, size_t body_len, bool request_ack) {
  if (node_ == nullptr) {
    return result(OperationStatus::NotInitialized);
  }
  if (!ready()) {
    return result(OperationStatus::ClockNotReady);
  }
  if (dst == nullptr || dst_len != kIdSize || content_type == nullptr ||
      (body == nullptr && body_len != 0)) {
    return result(OperationStatus::InvalidArgument);
  }

  SendResult send_result = result(OperationStatus::CoreError);
  if (!hop_send_message(node_, dst, content_type, body, static_cast<uintptr_t>(body_len),
                        request_ack, send_result.id.data())) {
    return send_result;
  }
  send_result.status = hop_is_secured(node_, dst) ? OperationStatus::Ok : OperationStatus::Deferred;
  return send_result;
}

SendResult Hop::sendMessage(const std::string &dst_base58, const std::string &body,
                            bool request_ack, const char *content_type) {
  uint8_t dst[kIdSize];
  if (!hop_address_from_base58(dst_base58.c_str(), dst)) {
    return result(OperationStatus::InvalidArgument);
  }
  return sendMessage(dst, sizeof(dst), content_type,
                     reinterpret_cast<const uint8_t *>(body.data()), body.size(), request_ack);
}

SendResult Hop::sendServiceRequest(const uint8_t *dst, size_t dst_len, const char *service,
                                   const char *method, const uint8_t *body, size_t body_len) {
  if (node_ == nullptr) {
    return result(OperationStatus::NotInitialized);
  }
  if (!ready()) {
    return result(OperationStatus::ClockNotReady);
  }
  if (dst == nullptr || dst_len != kIdSize || service == nullptr || method == nullptr ||
      (body == nullptr && body_len != 0)) {
    return result(OperationStatus::InvalidArgument);
  }

  SendResult send_result = result(OperationStatus::CoreError);
  if (hop_send_service_request(node_, dst, service, method, body,
                               static_cast<uintptr_t>(body_len), send_result.id.data())) {
    send_result.status = OperationStatus::Ok;
  }
  return send_result;
}

SendResult Hop::sendServiceRequest(const std::string &dst_base58, const char *service,
                                   const char *method, const std::string &body) {
  uint8_t dst[kIdSize];
  if (!hop_address_from_base58(dst_base58.c_str(), dst)) {
    return result(OperationStatus::InvalidArgument);
  }
  return sendServiceRequest(dst, sizeof(dst), service, method,
                            reinterpret_cast<const uint8_t *>(body.data()), body.size());
}

OperationStatus Hop::sendServiceResponse(const uint8_t *to, size_t to_len,
                                         const uint8_t *request_id, size_t request_id_len,
                                         uint16_t status, const uint8_t *body, size_t body_len) {
  if (node_ == nullptr) {
    return OperationStatus::NotInitialized;
  }
  if (!ready()) {
    return OperationStatus::ClockNotReady;
  }
  if (to == nullptr || to_len != kIdSize || request_id == nullptr ||
      request_id_len != kIdSize || (body == nullptr && body_len != 0)) {
    return OperationStatus::InvalidArgument;
  }
  return hop_send_service_response(node_, to, request_id, status, body,
                                   static_cast<uintptr_t>(body_len))
             ? OperationStatus::Ok
             : OperationStatus::CoreError;
}

OperationStatus Hop::sendServiceResponse(const ServiceRequest &request, uint16_t status,
                                         const std::string &body) {
  return sendServiceResponse(request.from.data(), request.from.size(), request.requestId.data(),
                             request.requestId.size(), status,
                             reinterpret_cast<const uint8_t *>(body.data()), body.size());
}

bool Hop::acceptServiceResponse(const uint8_t *request_id, size_t request_id_len) {
  if (!ready() || request_id == nullptr || request_id_len != kIdSize) {
    return false;
  }
  return hop_accept_service_response(node_, request_id);
}

OperationStatus Hop::linkUp(uint64_t link, LinkRole role) {
  if (node_ == nullptr) {
    return OperationStatus::NotInitialized;
  }
  if (!ready()) {
    return OperationStatus::ClockNotReady;
  }
  hop_link_up(node_, link, static_cast<uint32_t>(role));
  return OperationStatus::Ok;
}

OperationStatus Hop::bytesReceived(uint64_t link, const uint8_t *data, size_t len) {
  if (node_ == nullptr) {
    return OperationStatus::NotInitialized;
  }
  if (!ready()) {
    return OperationStatus::ClockNotReady;
  }
  if (data == nullptr && len != 0) {
    return OperationStatus::InvalidArgument;
  }
  hop_bytes_received(node_, link, data, static_cast<uintptr_t>(len));
  return OperationStatus::Ok;
}

OperationStatus Hop::linkDown(uint64_t link) {
  if (node_ == nullptr) {
    return OperationStatus::NotInitialized;
  }
  hop_link_down(node_, link);
  return OperationStatus::Ok;
}

bool Hop::addressBytes(uint8_t *out, size_t out_len) const {
  if (node_ == nullptr || out == nullptr || out_len != kIdSize) {
    return false;
  }
  return hop_node_address(node_, out);
}

std::string Hop::address() const {
  if (node_ == nullptr) {
    return std::string();
  }
  uint8_t addr[kIdSize];
  if (!hop_node_address(node_, addr)) {
    return std::string();
  }
  char buf[64];
  uintptr_t n = hop_address_to_base58(addr, buf, sizeof(buf));
  return std::string(buf, static_cast<size_t>(n));
}

size_t Hop::secret(uint8_t *out, size_t out_len) const {
  if (node_ == nullptr || out == nullptr || out_len != kIdSize) {
    return 0;
  }
  return static_cast<size_t>(hop_node_secret(node_, out));
}

void Hop::setName(const char *name) {
  if (node_ != nullptr) {
    hop_node_set_name(node_, name);
  }
}

void Hop::outgoingTrampoline(void *ctx, uint64_t link, const uint8_t *bytes, size_t len) {
  Hop *self = static_cast<Hop *>(ctx);
  if (self->on_outgoing_) {
    self->on_outgoing_(link, bytes, len);
  }
}

bool Hop::messageTrampoline(void *ctx, const uint8_t *inbox_id, const uint8_t *from,
                            const char *content_type, const uint8_t *body, size_t body_len,
                            uint8_t hops, uint64_t created_at_ms) {
  Hop *self = static_cast<Hop *>(ctx);
  if (!self->on_message_) {
    return false;
  }
  Message message{copyId(inbox_id), copyId(from), content_type == nullptr ? "" : content_type,
                  copyBytes(body, body_len), hops, created_at_ms};
  return self->on_message_(message);
}

void Hop::requestTrampoline(void *ctx, const uint8_t *from, const uint8_t *request_id,
                            const char *service, const char *method, const uint8_t *args,
                            size_t args_len) {
  Hop *self = static_cast<Hop *>(ctx);
  if (!self->on_service_request_) {
    return;
  }
  ServiceRequest request{copyId(from), copyId(request_id), service == nullptr ? "" : service,
                         method == nullptr ? "" : method, copyBytes(args, args_len)};
  self->on_service_request_(request);
}

bool Hop::responseTrampoline(void *ctx, const uint8_t *from, const uint8_t *request_id,
                             uint16_t status, const uint8_t *body, size_t body_len) {
  Hop *self = static_cast<Hop *>(ctx);
  if (!self->on_service_response_) {
    return false;
  }
  ServiceResponse response{copyId(from), copyId(request_id), status, copyBytes(body, body_len)};
  return self->on_service_response_(response);
}

void Hop::resetNode() {
  if (node_ != nullptr) {
    hop_node_free(node_);
    node_ = nullptr;
  }
}

void Hop::resetClock() {
  prekey_published_ = false;
  monotonic_anchored_ = false;
  wall_sample_anchored_ = false;
  last_monotonic_ms_ = 0;
  last_unix_epoch_ms_ = 0;
  last_wall_sample_ms_ = 0;
  clock_status_ = ClockStatus::NotInitialized;
}

ClockStatus Hop::acceptUnixTime(uint64_t unix_epoch_ms, uint32_t monotonic_ms,
                                bool trusted_wall_sample) {
  if (unix_epoch_ms < kMinPlausibleUnixEpochMs || unix_epoch_ms >= kMaxPlausibleUnixEpochMs) {
    clock_status_ = ClockStatus::Implausible;
    return clock_status_;
  }
  if (trusted_wall_sample && wall_sample_anchored_ && unix_epoch_ms < last_wall_sample_ms_) {
    clock_status_ = ClockStatus::Regressed;
    return clock_status_;
  }

  uint64_t protocol_time_ms = unix_epoch_ms;
  if (monotonic_anchored_) {
    const uint32_t elapsed_ms = monotonic_ms - last_monotonic_ms_;
    const uint64_t expected_ms = last_unix_epoch_ms_ + elapsed_ms;
    if (trusted_wall_sample && unix_epoch_ms < expected_ms &&
        expected_ms - unix_epoch_ms > kProviderLagToleranceMs) {
      clock_status_ = ClockStatus::Stale;
      return clock_status_;
    }
    protocol_time_ms = std::max(unix_epoch_ms, expected_ms);
  }
  if (protocol_time_ms >= kMaxPlausibleUnixEpochMs) {
    clock_status_ = ClockStatus::Implausible;
    return clock_status_;
  }
  if (trusted_wall_sample) {
    wall_sample_anchored_ = true;
    last_wall_sample_ms_ = unix_epoch_ms;
  }

  monotonic_anchored_ = true;
  last_monotonic_ms_ = monotonic_ms;
  last_unix_epoch_ms_ = protocol_time_ms;
  clock_status_ = ClockStatus::Ready;
  hop_node_tick(node_, protocol_time_ms);
  if (!prekey_published_) {
    prekey_published_ = hop_publish_prekey(node_);
  }
  return clock_status_;
}

void Hop::pump() {
  hop_drain_outgoing(node_, &Hop::outgoingTrampoline, this);
  if (on_message_) {
    hop_poll_inbox(node_, &Hop::messageTrampoline, this);
  }
  if (on_service_request_) {
    hop_poll_service_requests(node_, &Hop::requestTrampoline, this);
  }
  if (on_service_response_) {
    hop_poll_service_responses(node_, &Hop::responseTrampoline, this);
  }
}

SendResult Hop::result(OperationStatus status) {
  SendResult send_result = {status, {}};
  return send_result;
}

} // namespace hop
