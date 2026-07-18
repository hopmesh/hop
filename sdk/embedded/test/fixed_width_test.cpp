#include "Hop.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

uintptr_t fake_node_storage = 1;

int abi_calls = 0;
int new_calls = 0;
int with_secret_calls = 0;
int free_calls = 0;
int tick_calls = 0;
int prekey_calls = 0;
int message_send_calls = 0;
int secured_calls = 0;
int service_request_send_calls = 0;
int service_response_send_calls = 0;
int inbox_poll_calls = 0;
int service_request_poll_calls = 0;
int service_response_poll_calls = 0;
int drain_calls = 0;
int link_up_calls = 0;
int bytes_received_calls = 0;
int link_down_calls = 0;
int address_calls = 0;
int secret_calls = 0;

bool mock_secured = true;
bool emit_message = false;
bool emit_service_request = false;
bool emit_service_response = false;
bool message_was_accepted = false;
uint64_t last_tick_ms = 0;

std::array<uint8_t, hop::kIdSize> last_message_dst = {};
std::array<uint8_t, hop::kIdSize> emitted_response_correlation = {};
std::array<uint8_t, hop::kIdSize> last_response_to = {};
std::array<uint8_t, hop::kIdSize> last_response_request_id = {};
uint16_t last_response_status = 0;
std::vector<uint8_t> last_response_body;

template <size_t N> void fillBytes(uint8_t (&bytes)[N], uint8_t value) {
  std::fill(bytes, bytes + N, value);
}

bool allBytes(const std::array<uint8_t, hop::kIdSize> &bytes, uint8_t value) {
  return std::all_of(bytes.begin(), bytes.end(), [value](uint8_t byte) { return byte == value; });
}

bool bodyEquals(const std::vector<uint8_t> &body, const char *expected) {
  return std::string(body.begin(), body.end()) == expected;
}

} // namespace

extern "C" {

uint32_t hop_abi_version(void) {
  ++abi_calls;
  return HOP_EMBEDDED_ABI_VERSION;
}

const HopNode *hop_node_new(void) {
  ++new_calls;
  return reinterpret_cast<const HopNode *>(&fake_node_storage);
}

const HopNode *hop_node_with_secret(const uint8_t *, uintptr_t) {
  ++with_secret_calls;
  return reinterpret_cast<const HopNode *>(&fake_node_storage);
}

void hop_node_free(const HopNode *) { ++free_calls; }

bool hop_node_address(const HopNode *, uint8_t *out) {
  ++address_calls;
  std::memset(out, 1, hop::kIdSize);
  return true;
}

uintptr_t hop_node_secret(const HopNode *, uint8_t *out) {
  ++secret_calls;
  std::memset(out, 2, hop::kIdSize);
  return hop::kIdSize;
}

void hop_node_set_name(const HopNode *, const char *) {}

void hop_node_tick(const HopNode *, uint64_t now_ms) {
  ++tick_calls;
  last_tick_ms = now_ms;
}

bool hop_publish_prekey(const HopNode *) {
  ++prekey_calls;
  return true;
}

bool hop_send_message(const HopNode *, const uint8_t *dst, const char *, const uint8_t *,
                      uintptr_t, bool, uint8_t *out_id) {
  ++message_send_calls;
  std::copy(dst, dst + hop::kIdSize, last_message_dst.begin());
  std::memset(out_id, 0xa1, hop::kIdSize);
  return true;
}

bool hop_is_secured(const HopNode *, const uint8_t *) {
  ++secured_calls;
  return mock_secured;
}

void hop_poll_inbox(const HopNode *,
                    bool (*sink)(void *, const uint8_t *, const uint8_t *, const char *,
                                 const uint8_t *, uintptr_t, uint8_t, uint64_t),
                    void *ctx) {
  ++inbox_poll_calls;
  if (!emit_message) {
    return;
  }
  emit_message = false;
  uint8_t inbox_id[hop::kIdSize];
  uint8_t from[hop::kIdSize];
  char content_type[] = "text/plain";
  uint8_t body[] = {'h', 'e', 'l', 'l', 'o'};
  fillBytes(inbox_id, 0x11);
  fillBytes(from, 0x22);
  message_was_accepted = sink(ctx, inbox_id, from, content_type, body, sizeof(body), 7,
                              1700000000123ULL);
  std::memset(inbox_id, 0, sizeof(inbox_id));
  std::memset(from, 0, sizeof(from));
  std::memset(content_type, 0, sizeof(content_type));
  std::memset(body, 0, sizeof(body));
}

void hop_subscribe(const HopNode *, const char *) {}

bool hop_send_service_request(const HopNode *, const uint8_t *, const char *, const char *,
                              const uint8_t *, uintptr_t, uint8_t *out_id) {
  ++service_request_send_calls;
  std::memset(out_id, 0xb2, hop::kIdSize);
  return true;
}

bool hop_send_service_response(const HopNode *, const uint8_t *to,
                               const uint8_t *for_request_id, uint16_t status,
                               const uint8_t *body, uintptr_t body_len) {
  ++service_response_send_calls;
  std::copy(to, to + hop::kIdSize, last_response_to.begin());
  std::copy(for_request_id, for_request_id + hop::kIdSize,
            last_response_request_id.begin());
  last_response_status = status;
  if (body_len == 0) {
    last_response_body.clear();
  } else {
    last_response_body.assign(body, body + body_len);
  }
  return true;
}

void hop_poll_service_requests(const HopNode *,
                               void (*sink)(void *, const uint8_t *, const uint8_t *, const char *,
                                            const char *, const uint8_t *, uintptr_t),
                               void *ctx) {
  ++service_request_poll_calls;
  if (!emit_service_request) {
    return;
  }
  emit_service_request = false;
  uint8_t from[hop::kIdSize];
  uint8_t request_id[hop::kIdSize];
  char service[] = "weather";
  char method[] = "report";
  uint8_t body[] = {'7', '2', 'F'};
  fillBytes(from, 0x33);
  fillBytes(request_id, 0x44);
  sink(ctx, from, request_id, service, method, body, sizeof(body));
  std::memset(from, 0, sizeof(from));
  std::memset(request_id, 0, sizeof(request_id));
  std::memset(service, 0, sizeof(service));
  std::memset(method, 0, sizeof(method));
  std::memset(body, 0, sizeof(body));
}

void hop_poll_service_responses(const HopNode *,
                                 bool (*sink)(void *, const uint8_t *, const uint8_t *, uint16_t,
                                              const uint8_t *, uintptr_t),
                                 void *ctx) {
  ++service_response_poll_calls;
  if (!emit_service_response) {
    return;
  }
  emit_service_response = false;
  uint8_t from[hop::kIdSize];
  uint8_t correlation_id[hop::kIdSize];
  uint8_t body[] = {'s', 't', 'o', 'r', 'e', 'd'};
  fillBytes(from, 0x55);
  std::copy(emitted_response_correlation.begin(), emitted_response_correlation.end(),
            correlation_id);
  sink(ctx, from, correlation_id, 202, body, sizeof(body));
  std::memset(from, 0, sizeof(from));
  std::memset(correlation_id, 0, sizeof(correlation_id));
  std::memset(body, 0, sizeof(body));
}

bool hop_accept_service_response(const HopNode *, const uint8_t *request_id) {
  return request_id != nullptr;
}

void hop_link_up(const HopNode *, uint64_t, uint32_t) { ++link_up_calls; }

void hop_bytes_received(const HopNode *, uint64_t, const uint8_t *, uintptr_t) {
  ++bytes_received_calls;
}

void hop_link_down(const HopNode *, uint64_t) { ++link_down_calls; }

void hop_drain_outgoing(const HopNode *, void (*)(void *, uint64_t, const uint8_t *, uintptr_t),
                        void *) {
  ++drain_calls;
}

uintptr_t hop_address_to_base58(const uint8_t *, char *out, uintptr_t out_cap) {
  if (out_cap < 2) {
    return 0;
  }
  out[0] = '1';
  out[1] = '\0';
  return 1;
}

bool hop_address_from_base58(const char *text, uint8_t *out) {
  if (std::strcmp(text, "invalid") == 0) {
    return false;
  }
  std::memset(out, 3, hop::kIdSize);
  return true;
}

} // extern "C"

namespace {

void testClockGateAndRecovery() {
  hop::Hop node;
  assert(node.begin());
  assert(node.initialized());
  assert(!node.ready());
  assert(node.clockStatus() == hop::ClockStatus::WaitingForSync);

  const int ticks_before = tick_calls;
  const int prekeys_before = prekey_calls;
  const int drains_before = drain_calls;
  uint8_t address[hop::kIdSize] = {};

  assert(node.tick(100) == hop::ClockStatus::WaitingForSync);
  assert(node.sendMessage(address, "text/plain", nullptr, 0).status ==
         hop::OperationStatus::ClockNotReady);
  assert(node.sendServiceRequest(address, "weather", "get", nullptr, 0).status ==
         hop::OperationStatus::ClockNotReady);
  assert(node.sendServiceResponse(address, address, 200, nullptr, 0) ==
         hop::OperationStatus::ClockNotReady);
  assert(node.linkUp(1, hop::LinkRole::Dialer) == hop::OperationStatus::ClockNotReady);
  assert(node.bytesReceived(1, nullptr, 0) == hop::OperationStatus::ClockNotReady);
  assert(tick_calls == ticks_before);
  assert(prekey_calls == prekeys_before);
  assert(drain_calls == drains_before);
  assert(message_send_calls == 0);
  assert(service_request_send_calls == 0);
  assert(service_response_send_calls == 0);
  assert(link_up_calls == 0);
  assert(bytes_received_calls == 0);

  assert(node.synchronizeClock(1, 100) == hop::ClockStatus::Implausible);
  assert(!node.ready());
  assert(node.tick(200) == hop::ClockStatus::Implausible);
  assert(tick_calls == ticks_before);

  constexpr uint64_t epoch = 1700000000000ULL;
  assert(node.synchronizeClock(epoch, 200) == hop::ClockStatus::Ready);
  assert(node.ready());
  assert(tick_calls == ticks_before + 1);
  assert(prekey_calls == prekeys_before + 1);
  assert(last_tick_ms == epoch);

  assert(node.tick(350) == hop::ClockStatus::Ready);
  assert(last_tick_ms == epoch + 150);
  assert(drain_calls == drains_before + 1);

  const int ticks_before_regression = tick_calls;
  assert(node.synchronizeClock(epoch - 1, 400) == hop::ClockStatus::Regressed);
  assert(!node.ready());
  assert(node.tick(450) == hop::ClockStatus::Regressed);
  assert(tick_calls == ticks_before_regression);
  assert(node.sendMessage(address, "text/plain", nullptr, 0).status ==
         hop::OperationStatus::ClockNotReady);

  assert(node.synchronizeClock(epoch + 500, 500) == hop::ClockStatus::Ready);
  assert(node.ready());

  uint64_t provider_epoch = epoch + 500;
  bool provider_available = true;
  node.setUnixTimeProvider([&provider_epoch, &provider_available](uint64_t &out) {
    if (!provider_available) {
      return false;
    }
    out = provider_epoch;
    return true;
  });
  assert(node.tick(500) == hop::ClockStatus::Ready);
  for (uint32_t monotonic_ms = 510; monotonic_ms <= 1500; monotonic_ms += 10) {
    assert(node.tick(monotonic_ms) == hop::ClockStatus::Ready);
  }
  const int ticks_before_stale = tick_calls;
  assert(node.tick(1510) == hop::ClockStatus::Stale);
  assert(tick_calls == ticks_before_stale);
  provider_available = false;
  assert(node.tick(1600) == hop::ClockStatus::Stale);
  assert(tick_calls == ticks_before_stale);
  provider_available = true;
  provider_epoch = epoch + 3000;
  assert(node.tick(1600) == hop::ClockStatus::Ready);
  assert(last_tick_ms == provider_epoch);

  provider_epoch = epoch + 2000;
  assert(node.tick(1700) == hop::ClockStatus::Regressed);
  assert(!node.ready());
  provider_epoch = epoch + 3100;
  assert(node.tick(1700) == hop::ClockStatus::Ready);
}

void testMonotonicRolloverAndRestart() {
  hop::Hop node;
  assert(node.begin());
  constexpr uint64_t epoch = 1700001000000ULL;
  constexpr uint32_t before_rollover = 0xfffffff0U;
  assert(node.synchronizeClock(epoch, before_rollover) == hop::ClockStatus::Ready);
  assert(node.tick(0x10U) == hop::ClockStatus::Ready);
  assert(last_tick_ms == epoch + 32);

  const int ticks_before_restart = tick_calls;
  const int prekeys_before_restart = prekey_calls;
  assert(node.begin());
  assert(!node.ready());
  assert(node.clockStatus() == hop::ClockStatus::WaitingForSync);
  assert(node.tick(0x20U) == hop::ClockStatus::WaitingForSync);
  assert(tick_calls == ticks_before_restart);
  assert(prekey_calls == prekeys_before_restart);

  uint8_t address[hop::kIdSize] = {};
  assert(node.sendMessage(address, "text/plain", nullptr, 0).status ==
         hop::OperationStatus::ClockNotReady);
}

void testFixedWidthGuardsAndSymbolRouting() {
  constexpr size_t invalid_sizes[] = {0, 1, 31, 33};
  uint8_t bytes[33] = {};
  uint8_t fixed[hop::kIdSize] = {};

  const int abi_before_invalid_secret = abi_calls;
  const int with_secret_before = with_secret_calls;
  for (size_t size : invalid_sizes) {
    hop::Hop restored;
    assert(!restored.begin(bytes, size));
  }
  assert(abi_calls == abi_before_invalid_secret);
  assert(with_secret_calls == with_secret_before);

  hop::Hop restored;
  assert(restored.begin(bytes, hop::kIdSize));
  assert(with_secret_calls == with_secret_before + 1);

  hop::Hop node;
  assert(node.begin());
  assert(node.synchronizeClock(1700002000000ULL, 100) == hop::ClockStatus::Ready);

  const int message_before = message_send_calls;
  const int request_before = service_request_send_calls;
  const int response_before = service_response_send_calls;
  const int address_before = address_calls;
  const int secret_before = secret_calls;

  for (size_t size : invalid_sizes) {
    assert(node.sendMessage(bytes, size, "text/plain", nullptr, 0).status ==
           hop::OperationStatus::InvalidArgument);
    assert(node.sendServiceRequest(bytes, size, "svc", "get", nullptr, 0).status ==
           hop::OperationStatus::InvalidArgument);
    assert(node.sendServiceResponse(bytes, size, bytes, hop::kIdSize, 200, nullptr, 0) ==
           hop::OperationStatus::InvalidArgument);
    assert(node.sendServiceResponse(bytes, hop::kIdSize, bytes, size, 200, nullptr, 0) ==
           hop::OperationStatus::InvalidArgument);
    assert(!node.addressBytes(bytes, size));
    assert(node.secret(bytes, size) == 0);
  }
  assert(message_send_calls == message_before);
  assert(service_request_send_calls == request_before);
  assert(service_response_send_calls == response_before);
  assert(address_calls == address_before);
  assert(secret_calls == secret_before);

  mock_secured = true;
  hop::SendResult message = node.sendMessage(bytes, hop::kIdSize, "text/plain", nullptr, 0, true);
  assert(message.status == hop::OperationStatus::Ok);
  assert(allBytes(message.id, 0xa1));
  assert(message_send_calls == message_before + 1);
  assert(secured_calls > 0);
  assert(service_request_send_calls == request_before);
  assert(allBytes(last_message_dst, 0));

  mock_secured = false;
  hop::SendResult deferred = node.sendMessage(fixed, "text/plain", nullptr, 0);
  assert(deferred.status == hop::OperationStatus::Deferred);
  assert(deferred.accepted());
  assert(service_request_send_calls == request_before);

  hop::SendResult base58_message = node.sendMessage("valid", "hello");
  assert(base58_message.status == hop::OperationStatus::Deferred);
  assert(service_request_send_calls == request_before);
  assert(node.sendMessage("invalid", "hello").status == hop::OperationStatus::InvalidArgument);

  hop::SendResult request = node.sendServiceRequest(fixed, "svc", "get", nullptr, 0);
  assert(request.status == hop::OperationStatus::Ok);
  assert(allBytes(request.id, 0xb2));
  assert(service_request_send_calls == request_before + 1);

  assert(node.sendServiceResponse(fixed, fixed, 204, nullptr, 0) == hop::OperationStatus::Ok);
  assert(service_response_send_calls == response_before + 1);
  assert(node.addressBytes(bytes, hop::kIdSize));
  assert(node.secret(bytes, hop::kIdSize) == hop::kIdSize);
  assert(address_calls == address_before + 1);
  assert(secret_calls == secret_before + 1);
}

void testRpcCorrelationAndCallbackCopies() {
  hop::Hop node;
  assert(node.begin());
  assert(node.synchronizeClock(1700003000000ULL, 1000) == hop::ClockStatus::Ready);

  hop::Message saved_message = {};
  hop::ServiceRequest saved_request = {};
  hop::ServiceResponse saved_response = {};
  int message_callbacks = 0;
  int request_callbacks = 0;
  int response_callbacks = 0;
  uint8_t service_address[hop::kIdSize] = {};
  hop::SendResult outbound_request =
      node.sendServiceRequest(service_address, "weather", "report", nullptr, 0);
  assert(outbound_request.status == hop::OperationStatus::Ok);
  emitted_response_correlation = outbound_request.id;

  node.onMessage([&saved_message, &message_callbacks](const hop::Message &message) {
    saved_message = message;
    ++message_callbacks;
    return true;
  });
  node.onServiceRequest(
      [&saved_request, &request_callbacks](const hop::ServiceRequest &request) {
        saved_request = request;
        ++request_callbacks;
      });
  node.onServiceResponse(
      [&saved_response, &response_callbacks](const hop::ServiceResponse &response) {
        saved_response = response;
        ++response_callbacks;
        return true;
      });

  emit_message = true;
  emit_service_request = true;
  emit_service_response = true;
  assert(node.tick(1100) == hop::ClockStatus::Ready);
  assert(message_callbacks == 1);
  assert(request_callbacks == 1);
  assert(response_callbacks == 1);
  assert(message_was_accepted);

  assert(allBytes(saved_message.id, 0x11));
  assert(allBytes(saved_message.from, 0x22));
  assert(saved_message.contentType == "text/plain");
  assert(bodyEquals(saved_message.body, "hello"));
  assert(saved_message.hops == 7);
  assert(saved_message.createdAtMs == 1700000000123ULL);

  assert(allBytes(saved_request.from, 0x33));
  assert(allBytes(saved_request.requestId, 0x44));
  assert(saved_request.service == "weather");
  assert(saved_request.method == "report");
  assert(bodyEquals(saved_request.body, "72F"));

  assert(allBytes(saved_response.from, 0x55));
  assert(saved_response.correlationId == outbound_request.id);
  assert(saved_response.status == 202);
  assert(bodyEquals(saved_response.body, "stored"));

  const int responses_before = service_response_send_calls;
  assert(node.sendServiceResponse(saved_request, 201, std::string("copied")) ==
         hop::OperationStatus::Ok);
  assert(service_response_send_calls == responses_before + 1);
  assert(allBytes(last_response_to, 0x33));
  assert(allBytes(last_response_request_id, 0x44));
  assert(last_response_status == 201);
  assert(bodyEquals(last_response_body, "copied"));
}

} // namespace

int main() {
  testClockGateAndRecovery();
  testMonotonicRolloverAndRestart();
  testFixedWidthGuardsAndSymbolRouting();
  testRpcCorrelationAndCallbackCopies();
  assert(new_calls > 0);
  assert(free_calls > 0);
  assert(inbox_poll_calls > 0);
  assert(service_request_poll_calls > 0);
  assert(service_response_poll_calls > 0);
  return 0;
}
