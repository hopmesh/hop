// HopSmoke: proves the Swift `Hop` wrapper drives libhop's C ABI, same shape as core/hop-ffi's
// smoke.c: two in-memory nodes wired by a loopback bearer run the real §39 send→deliver(+ACK).

import Foundation
import Hop

guard let a = HopNode.ephemeral(), let b = HopNode.ephemeral() else {
    print("FAIL: ephemeral() returned nil"); exit(1)
}

var now: UInt64 = 1_700_000_000_000
a.tick(nowMs: now); b.tick(nowMs: now)
a.publishPrekey(); b.publishPrekey()

let bAddr = b.address

// Link up: A dialed (initiator), B accepted (responder). One link id (1) each side.
a.linkUp(1, role: .dialer)
b.linkUp(1, role: .acceptor)

func pump(rounds: Int, _ check: () -> Bool = { false }) -> Bool {
    for _ in 0..<rounds {
        a.drainOutgoing { _, bytes in b.bytesReceived(1, bytes) }
        b.drainOutgoing { _, bytes in a.bytesReceived(1, bytes) }
        now += 100; a.tick(nowMs: now); b.tick(nowMs: now)
        if check() { return true }
    }
    return check()
}

_ = pump(rounds: 50)  // carry the handshake + prekey gossip

let text = "hello from Swift over the C ABI"
guard let msgId = a.send(to: bAddr, body: Data(text.utf8), requestAck: true) else {
    print("FAIL: send returned nil"); exit(1)
}

var received: HopMessage?
var accepted = false
let ok = pump(rounds: 400) {
    b.pollInbox { received = $0 }
    if let message = received, !accepted { accepted = b.acceptInbox(message.id) }
    return received != nil && a.status(of: msgId).delivered
}

let st = a.status(of: msgId)
let gotText = received.map { String(data: $0.body, encoding: .utf8) ?? "" } ?? ""
let pass = ok && gotText == text && st.delivered

print("\(pass ? "PASS" : "FAIL"): B got=\"\(gotText)\" hops=\(received?.hops ?? 0) | A delivered=\(st.delivered) fwdHops=\(st.forwardHops)")

// base58 round-trip through the wrapper helpers.
let b58 = HopAddress.base58(bAddr)
let b58ok = HopAddress.fromBase58(b58) == bAddr
print("\(b58ok ? "PASS" : "FAIL"): base58 round-trip (\(b58))")

exit(pass && b58ok ? 0 : 1)
