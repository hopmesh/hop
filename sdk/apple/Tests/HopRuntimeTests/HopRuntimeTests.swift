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

    func testEveryFixedWidthInputRejectsNon32ByteBoundaries() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        let exact = Data(count: 32)
        for count in [0, 1, 31, 33] {
            let invalid = Data(count: count)
            XCTAssertNil(node.send(to: invalid, body: Data([1])), "send accepted \(count) bytes")
            XCTAssertNil(node.sendTo(peer: invalid, body: Data([1])), "sendTo accepted \(count) bytes")
            XCTAssertNil(
                node.sendServiceRequest(to: invalid, service: "svc", method: "get", args: Data()),
                "service request accepted \(count) bytes"
            )
            XCTAssertFalse(node.sendServiceResponse(to: invalid, forRequestId: exact, status: 200, body: Data()))
            XCTAssertFalse(node.sendServiceResponse(to: exact, forRequestId: invalid, status: 200, body: Data()))
            XCTAssertFalse(node.acceptInbox(invalid), "acceptInbox accepted \(count) bytes")
            XCTAssertFalse(node.isSecured(invalid), "isSecured accepted \(count) bytes")
            XCTAssertFalse(node.status(of: invalid).delivered, "status accepted \(count) bytes")
            XCTAssertEqual(HopAddress.base58(invalid), "", "base58 accepted \(count) bytes")
        }

        XCTAssertFalse(HopAddress.base58(exact).isEmpty, "an exact 32-byte address reaches libhop")
        _ = node.status(of: exact)
        _ = node.isSecured(exact)
        _ = node.acceptInbox(exact)
        _ = node.send(to: exact, body: Data([1]))
        _ = node.sendTo(peer: exact, body: Data([1]))
        _ = node.sendServiceRequest(to: exact, service: "svc", method: "get", args: Data())
        _ = node.sendServiceResponse(to: exact, forRequestId: exact, status: 200, body: Data())
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
        let aAddr = rtA.node.address
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

        var rejected: HopMessage?
        let sawRejected = pump(400) {
            rtB.node.pollInboxAccepting {
                rejected = $0
                return false
            }
            return rejected != nil
        }
        XCTAssertTrue(sawRejected, "host should see the durable inbox item")
        XCTAssertFalse(rtA.node.status(of: id).delivered, "a rejected host write must not emit the ACK")

        var got: HopMessage?
        var accepted = false
        let ok = pump(400) {
            rtB.node.pollInbox { got = $0 }
            if let message = got, !accepted {
                accepted = rtB.node.acceptInbox(message.id)
            }
            return got != nil && rtA.node.status(of: id).delivered
        }

        XCTAssertTrue(ok, "message should deliver and ACK within the pump budget")
        XCTAssertTrue(accepted, "host acceptance should succeed after persistence")
        XCTAssertEqual(got?.id, rejected?.id, "redelivery keeps the stable inbox id")
        XCTAssertEqual(got.flatMap { String(data: $0.body, encoding: .utf8) }, text)
        XCTAssertTrue(rtA.node.status(of: id).delivered, "sender sees delivered=true after ACK")
        XCTAssertFalse(rtB.node.acceptInbox(Data(count: 31)), "short inbox ids are rejected")
        XCTAssertFalse(rtB.node.acceptInbox(Data(count: 33)), "long inbox ids are rejected")

        guard let requestId = rtA.node.sendServiceRequest(
            to: bAddr, service: "weather", method: "get", args: Data("kar".utf8)
        ) else { return XCTFail("service request returned nil") }
        var request: HopServiceRequest? = nil
        XCTAssertTrue(pump(400) {
            rtB.node.pollServiceRequests { request = $0 }
            return request != nil
        })
        XCTAssertEqual(request?.from, aAddr)
        XCTAssertTrue(rtB.node.sendServiceResponse(
            to: request!.from,
            forRequestId: request!.requestId,
            status: 200,
            body: Data("sunny".utf8)
        ))
        var response: HopServiceResponse? = nil
        XCTAssertTrue(pump(400) {
            rtA.node.pollServiceResponses { response = $0 }
            return response != nil
        })
        XCTAssertEqual(response?.forRequestId, requestId)
        var redelivered: HopServiceResponse? = nil
        rtA.node.pollServiceResponses { redelivered = $0 }
        XCTAssertEqual(redelivered?.forRequestId, requestId)
        XCTAssertTrue(rtA.node.acceptServiceResponse(forRequestId: requestId))
        var afterAcceptance: HopServiceResponse? = nil
        rtA.node.pollServiceResponses { afterAcceptance = $0 }
        XCTAssertNil(afterAcceptance)
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
