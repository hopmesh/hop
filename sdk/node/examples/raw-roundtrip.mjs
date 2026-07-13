// Derisking proof: the hops:// service round trip, driven purely through the raw C ABI from Node,
// mirroring core/hop/src/cabi.rs `hops_service_request_response_round_trips_through_the_abi`.
// Two nodes, a byte-pipe bearer between them, a request in, a 200 + body back out.
import { hop, DrainSink, SvcReqSink, SvcRespSink, addr, bytes, b58, assertAbi } from '../lib/ffi.mjs'

assertAbi()
console.log('ABI ok:', hop.abi_version())

const DIALER = 0, ACCEPTOR = 1
const LA = 11n, LB = 22n

// Drain one node's queued packets to a JS array of {link, buf}.
function drain(node) {
  const out = []
  hop.drain_outgoing(node, (_ctx, link, ptr, len) => out.push({ link, buf: bytes(ptr, Number(len)) }), null)
  return out
}
// Pump both directions until the wire goes quiet (mirrors cabi.rs `pump`).
function pump(a, b) {
  for (let i = 0; i < 1000; i++) {
    let any = false
    for (const { buf } of drain(a)) { any = true; hop.bytes_received(b, LB, buf, buf.length) }
    for (const { buf } of drain(b)) { any = true; hop.bytes_received(a, LA, buf, buf.length) }
    if (!any) break
  }
}
function address(node) { const o = Buffer.alloc(32); hop.node_address(node, o); return o }

const a = hop.node_new()
const b = hop.node_new()

// connect(): clock, bearer up (A dials, B accepts), handshake, gossip prekeys.
hop.node_tick(a, 1000n); hop.node_tick(b, 1000n)
hop.link_up(a, LA, DIALER); hop.link_up(b, LB, ACCEPTOR)
pump(a, b)
hop.publish_prekey(a); hop.publish_prekey(b)
pump(a, b)
const aAddr = address(a), bAddr = address(b)
console.log('A =', b58(aAddr).slice(0, 12), ' B =', b58(bAddr).slice(0, 12))

// A fires a hops:// service request at B.
const reqId = Buffer.alloc(32)
const args = Buffer.from('temp=21')
const ok = hop.send_service_request(a, bAddr, 'weather', 'report', args, args.length, reqId)
console.log('request fired:', ok, ' reqId:', reqId.toString('hex').slice(0, 12))
pump(a, b)

// B drains the request (the ENDPOINT inbound handler surface).
let got
hop.poll_service_requests(b, (_ctx, from, rid, service, method, argPtr, argLen) => {
  got = { from: addr(from), rid: addr(rid), service, method, args: bytes(argPtr, Number(argLen)) }
}, null)
console.log('B received:', got.service + '/' + got.method, '=', got.args.toString(), ' from', b58(got.from).slice(0, 12))

// B replies 200 + body (the reply surface).
hop.send_service_response(b, got.from, got.rid, 200, Buffer.from('stored'), 6)
pump(a, b)

// A drains the response.
let resp
hop.poll_service_responses(a, (_ctx, from, forId, status, bodyPtr, bodyLen) => {
  resp = { from: addr(from), forId: addr(forId), status, body: bytes(bodyPtr, Number(bodyLen)) }
}, null)
console.log('A got response:', resp.status, resp.body.toString(), ' ties to reqId:', resp.forId.equals(reqId))

const passed = ok && got?.service === 'weather' && resp?.status === 200 && resp.body.toString() === 'stored' && resp.forId.equals(reqId)
hop.node_free(a); hop.node_free(b)
console.log(passed ? '\nPASS: full hops:// round trip through the C ABI from Node.' : '\nFAIL')
process.exit(passed ? 0 : 1)
