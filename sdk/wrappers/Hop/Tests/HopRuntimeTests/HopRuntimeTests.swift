// apple-07 / core-ffi-09: full-stack HopRuntime tests. A pair of loopback bearers registered with
// two HopRuntimes drives the real libhop node seam (linkUp/bytesReceived/drainOutgoing) and the §39
// send -> deliver(+ACK) path end to end, no radios. This exercises the exact multiplexer + node
// wiring every iOS bearer routes through, and also covers the F-26 NULL-on-panic ctor guard.

import XCTest
import Hop
import HopContract

/// A trivial in-memory bearer: it "links up" with a fixed partner on start, and `send` hands bytes
/// straight to the partner as inbound. Exercises the Bearer/LinkSink/Manager/Runtime path minus radio.
private final class LoopbackBearer: Bearer {
    weak var sink: LinkSink?
    let transportName = "LOOP"
    weak var partner: LoopbackBearer?
    private let isDialer: Bool
    private let myPeerId: Data
    private let linkId: LinkId = 1
    init(isDialer: Bool, peerId: Data) { self.isDialer = isDialer; self.myPeerId = peerId }
    func start() { sink?.linkUp(linkId, role: isDialer ? .dialer : .acceptor, peerId: partner?.myPeerId ?? Data()) }
    func stop() { sink?.linkDown(linkId) }
    func send(_ bytes: Data, on link: LinkId) { partner?.deliver(bytes) }
    fileprivate func deliver(_ bytes: Data) { sink?.linkBytes(linkId, bytes) }
}

final class HopRuntimeTests: XCTestCase {

    /// F-26: a healthy ephemeral() never returns nil, and the wrapper honors the optional contract.
    func testEphemeralConstructorIsNonNilOnAHealthyBuild() {
        XCTAssertNotNil(HopNode.ephemeral())
        XCTAssertNotNil(HopNode.with(secret: Data()))
    }

    func testRuntimeAndBearerDeliverAndAck() throws {
        guard let nodeA = HopNode.ephemeral(), let nodeB = HopNode.ephemeral() else {
            return XCTFail("ephemeral() returned nil")
        }
        let aId = randomNodeId(), bId = randomNodeId()
        let bearerA = LoopbackBearer(isDialer: nodeIdGreater(aId, bId), peerId: aId)
        let bearerB = LoopbackBearer(isDialer: nodeIdGreater(bId, aId), peerId: bId)
        bearerA.partner = bearerB; bearerB.partner = bearerA

        let rtA = HopRuntime(node: nodeA)
        let rtB = HopRuntime(node: nodeB)

        var now: UInt64 = 1_700_000_000_000
        rtA.tick(nowMs: now); rtB.tick(nowMs: now)
        rtA.node.publishPrekey(); rtB.node.publishPrekey()
        let bAddr = rtB.node.address

        rtA.register(bearerA); rtB.register(bearerB)
        rtA.start(); rtB.start()

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
            return XCTFail("send returned nil")
        }

        var got: HopMessage?
        let ok = pump(400) {
            rtB.node.pollInbox { got = $0 }
            return got != nil && rtA.node.status(of: id).delivered
        }

        XCTAssertTrue(ok, "message should deliver and ACK within the pump budget")
        XCTAssertEqual(got.flatMap { String(data: $0.body, encoding: .utf8) }, text)
        XCTAssertTrue(rtA.node.status(of: id).delivered, "sender sees delivered=true after ACK")
    }

    /// The runtime routes a global link id back to the owning bearer on pump().
    func testRuntimeTagsTheLinkTransport() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        let rt = HopRuntime(node: node, baseLinkId: 1_000_000)
        let a = LoopbackBearer(isDialer: true, peerId: randomNodeId())
        let b = LoopbackBearer(isDialer: false, peerId: randomNodeId())
        a.partner = b; b.partner = a
        rt.register(a)
        rt.start()   // brings up global link 1_000_000
        XCTAssertEqual(rt.bearers.transportName(of: 1_000_000), "LOOP")
    }
}
