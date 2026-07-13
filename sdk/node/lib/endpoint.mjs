// HopEndpoint: receive Hop messages in your Node app with an Express/Fastify-shaped surface, over
// the libhop C ABI. `hop.on(service, handler)` registers a receiver; the handler gets (req, reply)
// and reply(status, body) seals a hops:// response back to the authenticated sender.
//
// SEMANTICS (read this): this is NOT synchronous HTTP. Inbound is a durable, store-and-forward
// consume; a reply is a new addressed message that may arrive later. The DX looks like HTTP; the
// delivery is delay-tolerant and offline-safe. core is poll-model, so the endpoint runs a pump loop.
import { EventEmitter } from 'node:events'
import { hop, addr, bytes, b58, fromB58, assertAbi } from './ffi.mjs'

const DIALER = 0
const ACCEPTOR = 1

const toBuf = (v) =>
  Buffer.isBuffer(v) ? v : typeof v === 'string' ? Buffer.from(v) : Buffer.from(JSON.stringify(v))

function addrToBytes(a) {
  if (Buffer.isBuffer(a)) return a
  if (typeof a === 'string') return fromB58(a) // a base58 address (e.g. resolved from HNS)
  if (a && a._raw) return a._raw // a req.from
  throw new TypeError('address must be a base58 string, a 32-byte Buffer, or a req.from')
}

export class HopEndpoint extends EventEmitter {
  #node
  #handlers = new Map() // service -> handler(req, reply)
  #links = new Map() // linkId -> sendFn(buf)
  #pending = new Map() // reqId(hex) -> {resolve, reject, timer}
  #timer = null
  #closed = false

  // opts: { key?: 32-byte Buffer secret, dbPath?, name?, tickMs=50 }
  constructor(opts = {}) {
    super()
    assertAbi()
    const { key, dbPath, name, tickMs = 50 } = opts
    if (dbPath) {
      this.#node = hop.node_open(dbPath, key ?? null, key ? key.length : 0, null, 0)
    } else if (key) {
      this.#node = hop.node_with_secret(key, key.length)
    } else {
      this.#node = hop.node_new()
    }
    if (!this.#node) throw new Error('hop_node_open returned NULL')
    if (name) hop.node_set_name(this.#node, name)
    hop.node_tick(this.#node, BigInt(Date.now()))
    hop.publish_prekey(this.#node) // so senders can seal forward-secret messages to us
    this.tickMs = tickMs
    // A running endpoint keeps the loop alive (like a server). Call close() to stop it.
    this.#timer = setInterval(() => this.#pump(), tickMs)
  }

  get address() {
    const o = Buffer.alloc(32)
    hop.node_address(this.#node, o)
    return b58(o)
  }
  get addressBytes() {
    const o = Buffer.alloc(32)
    hop.node_address(this.#node, o)
    return o
  }

  // Register a receiver for a hops:// service (the endpoint's "route"). handler(req, reply).
  on(service, handler) {
    if (typeof service === 'string' && typeof handler === 'function') {
      this.#handlers.set(service, handler)
      hop.subscribe(this.#node, service)
      return this
    }
    return super.on(service, handler) // EventEmitter passthrough for 'message'/'error'
  }

  // Client side: call a service on a remote endpoint. Resolves with { status, body } when the
  // response returns (delay-tolerant; times out after `timeoutMs`).
  request(dst, service, method, args = Buffer.alloc(0), { timeoutMs = 15000 } = {}) {
    const dstBytes = addrToBytes(dst)
    const a = toBuf(args)
    const reqId = Buffer.alloc(32)
    const ok = hop.send_service_request(this.#node, dstBytes, service, method, a, a.length, reqId)
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

  // ---- bearer seam: a bearer registers a link + a send function, and feeds inbound frames ----
  _registerLink(linkId, role, sendFn) {
    this.#links.set(linkId, sendFn)
    hop.link_up(this.#node, BigInt(linkId), role)
  }
  _deliver(linkId, buf) {
    hop.bytes_received(this.#node, BigInt(linkId), buf, buf.length)
  }
  _linkDown(linkId) {
    this.#links.delete(linkId)
    hop.link_down(this.#node, BigInt(linkId))
  }

  #pump() {
    if (this.#closed) return
    hop.node_tick(this.#node, BigInt(Date.now()))
    // route outbound frames to the owning bearer
    hop.drain_outgoing(
      this.#node,
      (_ctx, link, ptr, len) => {
        const send = this.#links.get(Number(link))
        if (send) send(bytes(ptr, Number(len)))
      },
      null,
    )
    // inbound service requests -> handlers
    hop.poll_service_requests(this.#node, (_ctx, from, rid, service, method, argPtr, argLen) => {
      const req = new HopRequest(addr(from), addr(rid), service, method, bytes(argPtr, Number(argLen)))
      const handler = this.#handlers.get(service)
      const reply = makeReply(this.#node, req)
      if (handler) Promise.resolve(handler(req, reply)).catch((e) => this.emit('error', e))
      else this.emit('unhandled', req, reply)
    }, null)
    // inbound service responses -> resolve pending client requests
    hop.poll_service_responses(this.#node, (_ctx, from, forId, status, bodyPtr, bodyLen) => {
      const key = Buffer.from(addr(forId)).toString('hex')
      const p = this.#pending.get(key)
      if (p) {
        clearTimeout(p.timer)
        this.#pending.delete(key)
        p.resolve({ status, body: bytes(bodyPtr, Number(bodyLen)), from: b58(addr(from)) })
      }
    }, null)
    // plain untraceable messages -> 'message' events
    hop.poll_inbox(this.#node, (_ctx, from, ctype, bodyPtr, bodyLen, hops, created) => {
      this.emit('message', {
        from: b58(addr(from)),
        fromBytes: addr(from),
        contentType: ctype,
        body: bytes(bodyPtr, Number(bodyLen)),
        hops,
        createdAt: Number(created),
      })
    }, null)
  }

  close() {
    if (this.#closed) return
    this.#closed = true
    if (this.#timer) clearInterval(this.#timer)
    for (const { timer } of this.#pending.values()) clearTimeout(timer)
    this.#pending.clear()
    hop.node_free(this.#node)
    this.#node = null
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

// The handler gets a plain callable reply(status, body), aligned with the other SDKs. status is a
// uint16 (HTTP-shaped); body is a Buffer | string | JSON-able value.
function makeReply(node, req) {
  let sent = false
  return (status, body = Buffer.alloc(0)) => {
    if (sent) throw new Error('reply already sent')
    sent = true
    const b = toBuf(body)
    return hop.send_service_response(node, req._raw, req._rid, status, b, b.length)
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
