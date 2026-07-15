// Implementation of the Hop for Embedded wrapper. The libhop functions it calls are declared in the
// extern "C" block below, exactly as they appear in the C ABI header (hop.h). The wrapper does not
// #include hop.h so it builds before the release step stages the header; it links against the prebuilt
// libhop.a for the target chip. Keep these signatures in step with hop.h.

#include "Hop.h"

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

// Directory + service surface.
void hop_subscribe(const HopNode *node, const char *topic);
bool hop_send_service_request(const HopNode *node, const uint8_t *dst, const char *service,
                              const char *method, const uint8_t *args, uintptr_t args_len,
                              uint8_t *out_id);
void hop_poll_service_requests(const HopNode *node,
                               void (*sink)(void *ctx, const uint8_t *from, const uint8_t *request_id,
                                            const char *service, const char *method,
                                            const uint8_t *args, uintptr_t args_len),
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

Hop::~Hop() {
  if (node_ != nullptr) {
    hop_node_free(node_);
    node_ = nullptr;
  }
}

bool Hop::begin() {
  if (hop_abi_version() != HOP_EMBEDDED_ABI_VERSION) {
    return false;
  }
  node_ = hop_node_new();
  return node_ != nullptr;
}

bool Hop::begin(const uint8_t *secret, size_t secret_len) {
  if (hop_abi_version() != HOP_EMBEDDED_ABI_VERSION) {
    return false;
  }
  node_ = hop_node_with_secret(secret, static_cast<uintptr_t>(secret_len));
  return node_ != nullptr;
}

void Hop::tick(uint64_t now_ms) {
  if (node_ == nullptr) {
    return;
  }
  hop_node_tick(node_, now_ms);
  // Publish our prekey once, after the first tick has set a real clock (an advert stamped at time 0
  // would be judged expired). hop_publish_prekey returns false until that clock exists, so we retry
  // each tick until it takes.
  if (!prekey_published_) {
    prekey_published_ = hop_publish_prekey(node_);
  }
  // Hand every queued outbound packet to the radio, then deliver every arrival. Both happen inside
  // this call: the core is poll model and never pushes on its own.
  hop_drain_outgoing(node_, &Hop::outgoingTrampoline, this);
  hop_poll_service_requests(node_, &Hop::requestTrampoline, this);
}

void Hop::subscribe(const char *topic) {
  if (node_ != nullptr) {
    hop_subscribe(node_, topic);
  }
}

bool Hop::send(const uint8_t *dst, const char *service, const char *method, const uint8_t *payload,
               size_t payload_len) {
  if (node_ == nullptr) {
    return false;
  }
  return hop_send_service_request(node_, dst, service, method, payload,
                                  static_cast<uintptr_t>(payload_len), nullptr);
}

bool Hop::send(const std::string &dst_base58, const char *service, const char *method,
               const std::string &payload) {
  uint8_t dst[32];
  if (!hop_address_from_base58(dst_base58.c_str(), dst)) {
    return false;
  }
  return send(dst, service, method, reinterpret_cast<const uint8_t *>(payload.data()),
              payload.size());
}

void Hop::linkUp(uint64_t link, LinkRole role) {
  if (node_ != nullptr) {
    hop_link_up(node_, link, static_cast<uint32_t>(role));
  }
}

void Hop::bytesReceived(uint64_t link, const uint8_t *data, size_t len) {
  if (node_ != nullptr) {
    hop_bytes_received(node_, link, data, static_cast<uintptr_t>(len));
  }
}

void Hop::linkDown(uint64_t link) {
  if (node_ != nullptr) {
    hop_link_down(node_, link);
  }
}

bool Hop::addressBytes(uint8_t *out) const {
  if (node_ == nullptr) {
    return false;
  }
  return hop_node_address(node_, out);
}

std::string Hop::address() const {
  if (node_ == nullptr) {
    return std::string();
  }
  uint8_t addr[32];
  if (!hop_node_address(node_, addr)) {
    return std::string();
  }
  char buf[64];
  uintptr_t n = hop_address_to_base58(addr, buf, sizeof(buf));
  return std::string(buf, static_cast<size_t>(n));
}

size_t Hop::secret(uint8_t *out) const {
  if (node_ == nullptr) {
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

void Hop::requestTrampoline(void *ctx, const uint8_t *from, const uint8_t *request_id,
                            const char *service, const char *method, const uint8_t *args,
                            size_t args_len) {
  (void)request_id;
  Hop *self = static_cast<Hop *>(ctx);
  if (!self->on_message_) {
    return;
  }
  Message msg{from, service, method, args, args_len};
  self->on_message_(msg);
}

} // namespace hop
