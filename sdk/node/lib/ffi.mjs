// Raw koffi bindings to libhop (the C ABI, sdk/hop.h). This is the thin, mechanical layer; the
// ergonomics live in endpoint.mjs. Everything here mirrors a `hop_*` symbol one-to-one.
//
// libhop is resolved from HOP_LIBDIR (same env the Kotlin SDK uses) or the in-repo debug build.
import koffi from 'koffi'
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = join(HERE, '..', '..', '..') // sdk/node/lib -> repo root
const EXT = process.platform === 'darwin' ? 'dylib' : process.platform === 'win32' ? 'dll' : 'so'

function resolveLib() {
  const candidates = [
    process.env.HOP_LIBDIR && join(process.env.HOP_LIBDIR, `libhop.${EXT}`),
    join(REPO, 'target', 'debug', `libhop.${EXT}`),
    join(REPO, 'target', 'release', `libhop.${EXT}`),
  ].filter(Boolean)
  const found = candidates.find(existsSync)
  if (!found) {
    throw new Error(
      `libhop.${EXT} not found. Build it with \`cargo build -p hop\` or set HOP_LIBDIR.\n` +
        `Looked in:\n  ${candidates.join('\n  ')}`,
    )
  }
  return found
}

const lib = koffi.load(resolveLib())

// The node handle is an opaque pointer.
const HopNode = 'void *'

// Callback prototypes. core drains/polls invoke these SYNCHRONOUSLY during the call, so a transient
// JS function passed at the call site is exactly right (no persistent registration needed).
export const DrainSink = koffi.proto('void DrainSink(void *ctx, uint64_t link, uint8_t *bytes, size_t len)')
export const InboxSink = koffi.proto(
  'bool InboxSink(void *ctx, uint8_t *inbox_id, uint8_t *from, const char *content_type, uint8_t *body, size_t body_len, uint8_t hops, uint64_t created_at)',
)
export const SvcReqSink = koffi.proto(
  'void SvcReqSink(void *ctx, uint8_t *from, uint8_t *request_id, const char *service, const char *method, uint8_t *args, size_t args_len)',
)
export const SvcRespSink = koffi.proto(
  'bool SvcRespSink(void *ctx, uint8_t *from, uint8_t *for_request_id, uint16_t status, uint8_t *body, size_t body_len)',
)
export const ReachSignSink = koffi.proto('void ReachSignSink(void *ctx, uint8_t *bytes, size_t len)')
export const ReachVerifySink = koffi.proto(
  'void ReachVerifySink(void *ctx, uint8_t *address, const char *endpoint, uint64_t issued_at, uint32_t ttl_secs)',
)

const rawHop = {
  abi_version: lib.func('uint32_t hop_abi_version()'),
  node_new: lib.func('void *hop_node_new()'),
  node_with_secret: lib.func('void *hop_node_with_secret(uint8_t *secret, size_t secret_len)'),
  node_open: lib.func(
    'void *hop_node_open(const char *db_path, uint8_t *secret, size_t secret_len, uint8_t *app_secret, size_t app_secret_len)',
  ),
  node_free: lib.func('void hop_node_free(void *node)'),
  node_address: lib.func('bool hop_node_address(void *node, uint8_t *out)'),
  node_secret: lib.func('size_t hop_node_secret(void *node, uint8_t *out)'),
  node_set_name: lib.func('void hop_node_set_name(void *node, const char *name)'),
  node_tick: lib.func('void hop_node_tick(void *node, uint64_t now_ms)'),
  link_up: lib.func('void hop_link_up(void *node, uint64_t link, uint32_t role)'),
  bytes_received: lib.func('void hop_bytes_received(void *node, uint64_t link, uint8_t *data, size_t len)'),
  link_down: lib.func('void hop_link_down(void *node, uint64_t link)'),
  drain_outgoing: lib.func('void hop_drain_outgoing(void *node, DrainSink *sink, void *ctx)'),
  subscribe: lib.func('void hop_subscribe(void *node, const char *topic)'),
  publish_prekey: lib.func('bool hop_publish_prekey(void *node)'),
  poll_inbox: lib.func('void hop_poll_inbox(void *node, InboxSink *sink, void *ctx)'),
  accept_inbox: lib.func('bool hop_accept_inbox(void *node, uint8_t *inbox_id)'),
  send_message: lib.func(
    'bool hop_send_message(void *node, uint8_t *dst, const char *content_type, uint8_t *body, size_t body_len, bool request_ack, uint8_t *out_id)',
  ),
  send_service_request: lib.func(
    'bool hop_send_service_request(void *node, uint8_t *dst, const char *service, const char *method, uint8_t *args, size_t args_len, uint8_t *out_id)',
  ),
  send_service_response: lib.func(
    'bool hop_send_service_response(void *node, uint8_t *to, uint8_t *for_request_id, uint16_t status, uint8_t *body, size_t body_len)',
  ),
  poll_service_requests: lib.func('void hop_poll_service_requests(void *node, SvcReqSink *sink, void *ctx)'),
  poll_service_responses: lib.func('void hop_poll_service_responses(void *node, SvcRespSink *sink, void *ctx)'),
  accept_service_response: lib.func('bool hop_accept_service_response(void *node, uint8_t *request_id)'),
  address_to_base58: lib.func('size_t hop_address_to_base58(uint8_t *addr, char *out, size_t out_cap)'),
  address_from_base58: lib.func('bool hop_address_from_base58(const char *text, uint8_t *out32)'),
  sign_reach_record: lib.func(
    'void hop_sign_reach_record(void *node, const char *endpoint, uint32_t ttl_secs, ReachSignSink *sink, void *ctx)',
  ),
  verify_reach_record: lib.func(
    'bool hop_verify_reach_record(uint8_t *bytes, size_t len, uint64_t now_secs, ReachVerifySink *sink, void *ctx)',
  ),
  // Endpoint clustering (DESIGN.md §40): join a cluster and dedup applies transparently to the poll.
  cluster_join: lib.func('void hop_cluster_join(void *node, uint8_t *secret)'),
  cluster_join_passphrase: lib.func('void hop_cluster_join_passphrase(void *node, uint8_t *pass, size_t pass_len)'),
  cluster_mark_done: lib.func('void hop_cluster_mark_done(void *node, uint8_t *from, uint8_t *request_id)'),
  cluster_would_drop: lib.func('bool hop_cluster_would_drop(void *node, uint8_t *from, uint8_t *request_id)'),
  cluster_members: lib.func('uint32_t hop_cluster_members(void *node)'),
  cluster_set_quorum: lib.func('void hop_cluster_set_quorum(void *node, uint32_t min_live_members)'),
}

export function require32(value, name) {
  if (!Buffer.isBuffer(value) && !(value instanceof Uint8Array)) {
    throw new TypeError(`${name} must be a 32-byte Buffer or Uint8Array`)
  }
  if (value.byteLength !== 32) {
    throw new RangeError(`${name} must be exactly 32 bytes, got ${value.byteLength}`)
  }
  return value
}

// Fixed-width C arguments have no length in the ABI. Keep the raw symbols private and expose guarded
// calls so neither the endpoint facade nor a consumer of `raw` can trigger an out-of-bounds native read
// or write with a short Buffer.
export const hop = {
  ...rawHop,
  node_address: (node, out) => rawHop.node_address(node, require32(out, 'address output')),
  node_secret: (node, out) => rawHop.node_secret(node, require32(out, 'secret output')),
  accept_inbox: (node, id) => rawHop.accept_inbox(node, require32(id, 'inbox id')),
  accept_service_response: (node, requestId) =>
    rawHop.accept_service_response(node, require32(requestId, 'request id')),
  send_message: (node, dst, contentType, body, bodyLen, requestAck, outId) => {
    require32(dst, 'destination')
    if (outId != null) require32(outId, 'bundle id output')
    return rawHop.send_message(node, dst, contentType, body, bodyLen, requestAck, outId)
  },
  send_service_request: (node, dst, service, method, args, argsLen, outId) => {
    require32(dst, 'destination')
    if (outId != null) require32(outId, 'request id output')
    return rawHop.send_service_request(node, dst, service, method, args, argsLen, outId)
  },
  send_service_response: (node, to, forRequestId, status, body, bodyLen) =>
    rawHop.send_service_response(
      node,
      require32(to, 'response destination'),
      require32(forRequestId, 'request id'),
      status,
      body,
      bodyLen,
    ),
  address_to_base58: (address, out, outCap) =>
    rawHop.address_to_base58(require32(address, 'address'), out, outCap),
  address_from_base58: (text, out) =>
    rawHop.address_from_base58(text, require32(out, 'address output')),
  cluster_join: (node, secret) => rawHop.cluster_join(node, require32(secret, 'cluster secret')),
  cluster_mark_done: (node, from, requestId) =>
    rawHop.cluster_mark_done(
      node,
      require32(from, 'request sender'),
      require32(requestId, 'request id'),
    ),
  cluster_would_drop: (node, from, requestId) =>
    rawHop.cluster_would_drop(
      node,
      require32(from, 'request sender'),
      require32(requestId, 'request id'),
    ),
}

const ABI_EXPECTED = 4
export function assertAbi() {
  const got = hop.abi_version()
  if (got !== ABI_EXPECTED) {
    throw new Error(`libhop ABI mismatch: header expects ${ABI_EXPECTED}, library reports ${got}`)
  }
}

// ---- small decode helpers for the sink callbacks (pointers valid only during the call) ----
export const bytes = (ptr, len) => (len === 0 ? Buffer.alloc(0) : Buffer.from(koffi.decode(ptr, 'uint8_t', len)))
export const addr = (ptr) => Buffer.from(koffi.decode(ptr, 'uint8_t', 32))
export const b58 = (addr32) => {
  require32(addr32, 'address')
  const out = Buffer.alloc(64)
  const n = hop.address_to_base58(addr32, out, out.length)
  return out.toString('utf8', 0, n)
}
export const fromB58 = (text) => {
  const out = Buffer.alloc(32)
  if (!hop.address_from_base58(text, out)) throw new Error(`not a valid Hop address: ${text}`)
  return out
}

// Sign a self-certifying reachability record for this node's address -> Buffer (postcard bytes).
export const signReach = (node, endpoint, ttlSecs) => {
  let out = null
  hop.sign_reach_record(node, endpoint, ttlSecs, (_ctx, ptr, len) => (out = bytes(ptr, Number(len))), null)
  return out
}
// Verify a reach record. Returns { address (base58), addressBytes, endpoint, issuedAt, ttlSecs } or null.
export const verifyReach = (recordBytes, nowSecs = Math.floor(Date.now() / 1000)) => {
  let info = null
  const ok = hop.verify_reach_record(
    recordBytes,
    recordBytes.length,
    BigInt(nowSecs),
    (_ctx, addrPtr, endpoint, issuedAt, ttlSecs) => {
      const a = addr(addrPtr)
      info = { address: b58(a), addressBytes: a, endpoint, issuedAt: Number(issuedAt), ttlSecs }
    },
    null,
  )
  return ok ? info : null
}
export { koffi }
