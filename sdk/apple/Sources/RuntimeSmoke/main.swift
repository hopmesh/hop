// RuntimeSmoke — proves the FULL Swift stack: a Bearer (conforming to the SDK contract) registered
// with a HopRuntime actually drives the node's C-ABI seam, and pump() routes outbound bytes back to
// the bearer. Two runtimes, each with one LoopbackBearer; the bearers are paired so A's sent bytes
// arrive as B's inbound bytes. Runs the real §39 send→deliver(+ACK) — no radios, all in-process.

import Foundation
import Hop
import HopContract

/// A trivial in-memory bearer: it "links up" with a fixed partner on start, and `send` hands bytes
/// straight to the partner as inbound. Exercises exactly the Bearer/LinkSink/Manager/Runtime path a
/// real radio would, minus the radio.
final class LoopbackBearer: Bearer {
    weak var sink: LinkSink?
    let transportName = "LOOP"
    weak var partner: LoopbackBearer?
    private let isDialer: Bool
    private let myPeerId: Data
    private let linkId: LinkId = 1

    init(isDialer: Bool, peerId: Data) { self.isDialer = isDialer; self.myPeerId = peerId }

    func start() {
        sink?.linkUp(linkId, role: isDialer ? .dialer : .acceptor, peerId: partner?.myPeerId ?? Data())
    }
    func stop() { sink?.linkDown(linkId) }
    func send(_ bytes: Data, on link: LinkId) { partner?.deliver(bytes) }   // out on A == in on B
    fileprivate func deliver(_ bytes: Data) { sink?.linkBytes(linkId, bytes) }
}

let aId = randomNodeId(), bId = randomNodeId()
let bearerA = LoopbackBearer(isDialer: nodeIdGreater(aId, bId), peerId: aId)
let bearerB = LoopbackBearer(isDialer: nodeIdGreater(bId, aId), peerId: bId)
bearerA.partner = bearerB; bearerB.partner = bearerA

guard let nodeA = HopNode.ephemeral(), let nodeB = HopNode.ephemeral() else {
    print("FAIL: ephemeral() returned nil"); exit(1)
}
let rtA = HopRuntime(node: nodeA)
let rtB = HopRuntime(node: nodeB)

var now: UInt64 = 1_700_000_000_000
rtA.tick(nowMs: now); rtB.tick(nowMs: now)
rtA.node.publishPrekey(); rtB.node.publishPrekey()
let bAddr = rtB.node.address

rtA.register(bearerA); rtB.register(bearerB)
rtA.start(); rtB.start()   // links up through the manager into each node's seam

func pump(_ rounds: Int, _ done: () -> Bool = { false }) -> Bool {
    for _ in 0..<rounds {
        rtA.pump(); rtB.pump()
        now += 100; rtA.tick(nowMs: now); rtB.tick(nowMs: now)
        if done() { return true }
    }
    return done()
}

_ = pump(50)   // handshake + prekey gossip through the loopback bearers

let text = "hello through HopRuntime + a Bearer"
guard let id = rtA.node.send(to: bAddr, body: Data(text.utf8), requestAck: true) else {
    print("FAIL: send nil"); exit(1)
}

var got: HopMessage?
var accepted = false
let ok = pump(400) {
    rtB.node.pollInbox { got = $0 }
    if let message = got, !accepted { accepted = rtB.node.acceptInbox(message.id) }
    return got != nil && rtA.node.status(of: id).delivered
}

let body = got.map { String(data: $0.body, encoding: .utf8) ?? "" } ?? ""
let st = rtA.node.status(of: id)
let pass = ok && body == text && st.delivered
print("\(pass ? "PASS" : "FAIL"): runtime+bearer delivered=\(st.delivered) body=\"\(body)\" via \(rtB.bearers.transportName(of: 1_000_000) ?? "?")")
exit(pass ? 0 : 1)
