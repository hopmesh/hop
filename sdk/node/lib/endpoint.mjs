// HopEndpoint: receive Hop messages in your Node app with an Express/Fastify-shaped surface, over
// the libhop C ABI. `hop.on(service, handler)` registers a receiver; the handler gets (req, reply)
// and reply(status, body) seals a hops:// response back to the authenticated sender.
//
// SEMANTICS (read this): this is NOT synchronous HTTP. Inbound is a durable, store-and-forward
// consume; a reply is a new addressed message that may arrive later. The DX looks like HTTP; the
// delivery is delay-tolerant and offline-safe. core is poll-model, so the endpoint runs a pump loop.
import { EventEmitter } from 'node:events'
import https from 'node:https'
import { hop, addr, bytes, b58, fromB58, signReach, assertAbi, require32 } from './ffi.mjs'
import { serveWss, dialWss } from './wss-bearer.mjs'
import { wellKnownBody, resolve as resolveWellKnown, WELL_KNOWN_PATH } from './discovery.mjs'

// A minimal fetch-shaped GET that accepts a self-signed cert, for dev only (dialByName insecureTLS).
// Production uses the global fetch with real WebPKI validation.
function insecureFetch(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { rejectUnauthorized: false }, (res) => {
        let data = ''
        res.on('data', (c) => (data += c))
        res.on('end', () =>
          resolve({
            ok: res.statusCode >= 200 && res.statusCode < 300,
            status: res.statusCode,
            json: async () => JSON.parse(data),
          }),
        )
      })
      .on('error', reject)
  })
}

const DIALER = 0
const ACCEPTOR = 1

const toBuf = (v) =>
  Buffer.isBuffer(v) ? v : typeof v === 'string' ? Buffer.from(v) : Buffer.from(JSON.stringify(v))

function addrToBytes(a) {
  if (Buffer.isBuffer(a) || a instanceof Uint8Array) return require32(a, 'address')
  if (typeof a === 'string') return fromB58(a) // a base58 address (e.g. resolved from HNS)
  if (a && a._raw) return require32(a._raw, 'address') // a req.from
  throw new TypeError('address must be a base58 string, a 32-byte Buffer, or a req.from')
}

export class HopEndpoint extends EventEmitter {
  #node
  #handlers = new Map() // service -> handler(req, reply)
  #links = new Map() // linkId -> sendFn(buf)
  #pending = new Map() // reqId(hex) -> {resolve, reject, timer}
  #timer = null
  #closed = false
  #activeNative = 0
  #closers = [] // bearer teardown hooks (server/sockets), run by close() before freeing the node

  // opts: { key?: 32-byte Buffer secret, dbPath?, name?, tickMs=50,
  //         cluster?: string passphrase | 32-byte Buffer secret, quorum?: min live members (CP) }
  constructor(opts = {}) {
    super()
    assertAbi()
    const { key, dbPath, name, tickMs = 50, cluster, quorum } = opts
    if (key != null) require32(key, 'identity key')
    if (dbPath) {
      this.#node = hop.node_open(dbPath, key ?? null, key ? key.length : 0, null, 0)
    } else if (key) {
      this.#node = hop.node_with_secret(key, key.length)
    } else {
      this.#node = hop.node_new()
    }
    if (!this.#node) throw new Error('hop_node_open returned NULL')
    if (name) this.#native((node) => hop.node_set_name(node, name))
    // Cluster with sibling replicas (same identity, no shared datastore): dedup then applies
    // transparently to poll_service_requests. A string is a passphrase (derived the same way as the
    // standalone service's HOP_CLUSTER_SECRET, so they interop); a 32-byte Buffer is a raw secret.
    if (cluster != null) this.cluster(cluster)
    if (quorum != null) this.clusterQuorum(quorum)
    this.#native((node) => hop.node_tick(node, BigInt(Date.now())))
    this.#native((node) => hop.publish_prekey(node)) // so senders can seal forward-secret messages to us
    this.tickMs = tickMs
    // A running endpoint keeps the loop alive (like a server). Call close() to stop it.
    this.#timer = setInterval(() => this.#pump(), tickMs)
  }

  get address() {
    const o = Buffer.alloc(32)
    this.#native((node) => hop.node_address(node, o))
    return b58(o)
  }
  get addressBytes() {
    const o = Buffer.alloc(32)
    this.#native((node) => hop.node_address(node, o))
    return o
  }

  // Join the endpoint cluster so sibling replicas (same identity, no shared datastore) each handle a
  // given request once. Pass a string passphrase (interops with the standalone service's
  // HOP_CLUSTER_SECRET) or a 32-byte Buffer secret. Dedup then applies transparently to inbound
  // requests. Also settable via the `cluster` constructor option. Returns this.
  cluster(secretOrPassphrase) {
    if (typeof secretOrPassphrase === 'string') {
      const buf = Buffer.from(secretOrPassphrase, 'utf8')
      this.#native((node) => hop.cluster_join_passphrase(node, buf, buf.length))
    } else {
      const b = Buffer.isBuffer(secretOrPassphrase)
        ? secretOrPassphrase
        : Buffer.from(secretOrPassphrase)
      // ADV18-06: hop_cluster_join reads a fixed 32 bytes from the secret with no length param.
      if (b.length !== 32) throw new Error('cluster secret must be a 32-byte Buffer or a string passphrase')
      this.#native((node) => hop.cluster_join(node, b))
    }
    return this
  }

  // Live replica count (self + peers within the membership TTL); 1 if not clustered.
  get clusterMembers() {
    return this.#native((node) => hop.cluster_members(node))
  }

  // Require at least `min` live cluster members visible before this replica will process a request
  // using a TTL-based visibility threshold. This is a conservative failover heuristic, not consensus
  // or an at-most-once guarantee. 0 or 1 disables it. Returns this.
  clusterQuorum(min) {
    this.#native((node) => hop.cluster_set_quorum(node, min >>> 0))
    return this
  }

  // Register a receiver for a hops:// service (the endpoint's "route"). handler(req, reply).
  on(service, handler) {
    if (typeof service === 'string' && typeof handler === 'function') {
      this.#handlers.set(service, handler)
      this.#native((node) => hop.subscribe(node, service))
      return this
    }
    return super.on(service, handler) // EventEmitter passthrough for 'message'/'error'
  }

  // Client side: call a service on a remote endpoint. Resolves with { status, body } when the
  // response returns (delay-tolerant; times out after `timeoutMs`).
  request(dst, service, method, args = Buffer.alloc(0), { timeoutMs = 15000 } = {}) {
    const dstBytes = addrToBytes(dst)
    require32(dstBytes, 'dst') // ADV18-06: send_service_request reads a fixed 32 bytes from dst
    const a = toBuf(args)
    const reqId = Buffer.alloc(32)
    const ok = this.#native((node) =>
      hop.send_service_request(node, dstBytes, service, method, a, a.length, reqId),
    )
    if (!ok) return Promise.reject(new Error('hop_send_service_request failed'))
    const key = reqId.toString('hex')
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(key)
        reject(new Error(`hops://${service}/${method} timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      if (timer.unref) timer.unref()
      this.#pending.set(key, { resolve, reject, timer })
    })
  }

  // Sign a self-certifying reachability record for this endpoint's address bound to `endpoint`
  // (e.g. "wss://myaddress.com/_hop"). Returns the record bytes (Buffer).
  signReach(endpoint, ttlSecs = 3600) {
    return this.#native((node) => signReach(node, endpoint, ttlSecs))
  }

  // Wire this endpoint into an existing http/https server IN ONE CALL: the WSS bearer at `path` and
  // the /.well-known/hop discovery responder. Pass `publicUrl` (e.g. "wss://myaddress.com/_hop"), the
  // address senders will reach. On a Hop-dedicated server this also answers the well-known request;
  // to mount the well-known through an app router instead, pass serveWellKnown:false and use
  // wellKnownHandler().
  attach(server, { publicUrl, path = '/_hop', ttlSecs = 3600, serveWellKnown = true } = {}) {
    if (!publicUrl) throw new Error('attach requires { publicUrl } (e.g. "wss://myaddress.com/_hop")')
    serveWss(this, server, { path })
    if (serveWellKnown) {
      const handler = this.wellKnownHandler(publicUrl, ttlSecs)
      server.on('request', (req, res) => {
        let pathname
        try {
          pathname = new URL(req.url, 'http://x').pathname
        } catch {
          pathname = req.url
        }
        if (pathname === WELL_KNOWN_PATH) handler(req, res)
      })
    }
    return this
  }

  // A framework-agnostic request handler for GET /.well-known/hop (mount in Express/Fastify/etc.).
  wellKnownHandler(publicUrl, ttlSecs = 3600) {
    return (_req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(wellKnownBody(this, publicUrl, ttlSecs))
    }
  }

  // Resolve a base HTTPS URL to a verified endpoint, dial its WSS, and return the reachable address.
  // The caller then request(address, ...). Pass insecureTLS:true only for a dev/self-signed cert.
  async dialByName(baseUrl, { insecureTLS = false } = {}) {
    const fetchImpl = insecureTLS ? insecureFetch : fetch
    const { address, wssUrl } = await resolveWellKnown(baseUrl, { fetch: fetchImpl })
    dialWss(this, wssUrl, { rejectUnauthorized: !insecureTLS })
    return address
  }

  // ---- bearer seam: a bearer registers a link + a send function, and feeds inbound frames ----
  // A bearer registers teardown hooks here so close() can shut its sockets. If already closed, the hook
  // fires immediately.
  _registerCloser(fn) {
    if (this.#closed) {
      fn()
      return
    }
    this.#closers.push(fn)
  }
  _registerLink(linkId, role, sendFn) {
    if (this.#closed) return
    this.#links.set(linkId, sendFn)
    this.#native((node) => hop.link_up(node, BigInt(linkId), role))
  }
  _deliver(linkId, buf) {
    if (this.#closed) return // a bearer event after close() must not touch the freed/null node
    this.#native((node) => hop.bytes_received(node, BigInt(linkId), buf, buf.length))
  }
  _linkDown(linkId) {
    if (this.#closed) return
    this.#links.delete(linkId)
    this.#native((node) => hop.link_down(node, BigInt(linkId)))
  }

  // Durably accept one stable inbox id after the application has finished its own async persistence.
  // A 64-character hex string or an exact 32-byte Buffer is accepted; every other shape is rejected.
  acceptInbox(id) {
    let idBytes
    if (Buffer.isBuffer(id) || id instanceof Uint8Array) idBytes = Buffer.from(id)
    else if (typeof id === 'string' && /^[0-9a-fA-F]{64}$/.test(id)) idBytes = Buffer.from(id, 'hex')
    else throw new TypeError('inbox id must be a 64-character hex string or a 32-byte Buffer')
    if (idBytes.length !== 32) throw new RangeError(`inbox id must be exactly 32 bytes, got ${idBytes.length}`)
    if (this.#closed) return false
    return this.#native((node) => hop.accept_inbox(node, idBytes))
  }

  // Durably accept a service response after the caller has completed any asynchronous local work.
  acceptServiceResponse(requestId) {
    const id = Buffer.from(require32(requestId, 'request id'))
    if (this.#closed) return false
    return this.#native((node) => hop.accept_service_response(node, id))
  }

  // Emit one already-decoded durable inbox item without accepting it. The optional callback is the
  // deterministic test seam for proving that only message.accept() crosses the acceptance boundary.
  _emitInbox(message, acceptInbox = (id) => this.acceptInbox(id)) {
    const idBytes = Buffer.from(message.idBytes)
    const fromBytes = Buffer.from(message.fromBytes)
    const acceptId = Buffer.from(idBytes)
    this.emit('message', {
      id: idBytes.toString('hex'),
      idBytes,
      from: message.from,
      fromBytes,
      contentType: message.contentType,
      body: message.body,
      hops: message.hops,
      createdAt: message.createdAt,
      accept: () => acceptInbox(Buffer.from(acceptId)),
    })
    return false
  }

  #pump() {
    if (this.#closed) return
    this.#native((node) => hop.node_tick(node, BigInt(Date.now())))
    // route outbound frames to the owning bearer
    this.#native((node) => hop.drain_outgoing(
      node,
      (_ctx, link, ptr, len) => {
        if (this.#closed) return
        const send = this.#links.get(Number(link))
        if (send) send(bytes(ptr, Number(len)))
      },
      null,
    ))
    if (this.#closed) return
    // inbound service requests -> handlers
    this.#native((node) => hop.poll_service_requests(node, (_ctx, from, rid, service, method, argPtr, argLen) => {
      if (this.#closed) return
      const req = new HopRequest(addr(from), addr(rid), service, method, bytes(argPtr, Number(argLen)))
      const handler = this.#handlers.get(service)
      const reply = this.#makeReply(req)
      if (handler) Promise.resolve(handler(req, reply)).catch((e) => this.emit('error', e))
      else this.emit('unhandled', req, reply)
    }, null))
    if (this.#closed) return
    // inbound service responses -> resolve pending client requests
    this.#native((node) => hop.poll_service_responses(node, (_ctx, from, forId, status, bodyPtr, bodyLen) => {
      if (this.#closed) return false
      const requestId = addr(forId)
      const key = requestId.toString('hex')
      const p = this.#pending.get(key)
      if (p) {
        clearTimeout(p.timer)
        this.#pending.delete(key)
        const acceptedId = Buffer.from(requestId)
        p.resolve({
          status,
          body: bytes(bodyPtr, Number(bodyLen)),
          from: b58(addr(from)),
          accept: () => this.acceptServiceResponse(acceptedId),
        })
      }
      return false
    }, null))
    if (this.#closed) return
    // plain untraceable messages -> 'message' events
    this.#native((node) => hop.poll_inbox(node, (_ctx, inboxId, from, ctype, bodyPtr, bodyLen, hops, created) => {
      if (this.#closed) return false
      const idBytes = addr(inboxId)
      const fromBytes = addr(from)
      return this._emitInbox({
        idBytes,
        from: b58(fromBytes),
        fromBytes,
        contentType: ctype,
        body: bytes(bodyPtr, Number(bodyLen)),
        hops,
        createdAt: Number(created),
      })
    }, null))
  }

  // Build the reply callable for a request. It re-reads this.#node and re-checks #closed at CALL time
  // (not at pump time), so a deferred/async reply issued after close() short-circuits instead of
  // dereferencing the freed node (mirrors the guard the other SDKs route their reply through).
  #makeReply(req) {
    let sent = false
    return (status, body = Buffer.alloc(0)) => {
      if (sent) throw new Error('reply already sent')
      sent = true
      if (this.#closed) return false
      // ADV18-06: send_service_response reads a fixed 32 bytes from `to` and `for_request_id`. These
      // come from a decoded inbound request (already 32), but validate before the fixed-length read.
      require32(req._raw, 'to')
      require32(req._rid, 'forRequestId')
      const b = toBuf(body)
      return this.#native((node) =>
        hop.send_service_response(node, req._raw, req._rid, status, b, b.length),
      )
    }
  }

  #native(fn) {
    if (this.#closed || !this.#node) throw new Error('endpoint is closed')
    const node = this.#node
    this.#activeNative += 1
    try {
      return fn(node)
    } finally {
      this.#activeNative -= 1
      if (this.#closed && this.#activeNative === 0) this.#freeNode()
    }
  }

  #freeNode() {
    if (!this.#node) return
    hop.node_free(this.#node)
    this.#node = null
  }

  close() {
    if (this.#closed) return
    this.#closed = true
    if (this.#timer) clearInterval(this.#timer)
    // Reject (not just drop) every in-flight request so an awaiting caller gets a rejection instead of a
    // promise that never settles (audit LOW: pending were cleared without rejecting the waiters).
    for (const { reject, timer } of this.#pending.values()) {
      clearTimeout(timer)
      try {
        reject(new Error('endpoint closed'))
      } catch {
        // the caller may have already settled/detached; ignore
      }
    }
    this.#pending.clear()
    for (const c of this.#closers) {
      try {
        c()
      } catch {
        // ignore teardown errors
      }
    }
    this.#closers = []
    if (this.#activeNative === 0) this.#freeNode()
  }
}

class HopRequest {
  constructor(fromBytes, ridBytes, service, method, args) {
    this._raw = fromBytes
    this._rid = ridBytes
    this.from = b58(fromBytes) // the VERIFIED sender identity, not a spoofable header
    this.service = service
    this.method = method
    this.args = args
  }
  get text() {
    return this.args.toString('utf8')
  }
  json() {
    return JSON.parse(this.args.toString('utf8'))
  }
}

// In-process bearer: connect two endpoints directly (each drains into the other). Proves the
// handler/reply ergonomics end to end with the real engine; no sockets. See tcp-bearer.mjs for the
// Internet bearer that makes an endpoint reachable by any device.
export function connectInProcess(a, b, { la = 11, lb = 22 } = {}) {
  a._registerLink(la, DIALER, (buf) => b._deliver(lb, buf))
  b._registerLink(lb, ACCEPTOR, (buf) => a._deliver(la, buf))
  return () => {
    a._linkDown(la)
    b._linkDown(lb)
  }
}

export { hop as raw }
