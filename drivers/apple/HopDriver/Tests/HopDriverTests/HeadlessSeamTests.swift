// The node seam (cov/apple-driver): the transport-agnostic entry points every bearer drives - a link came
// up / delivered bytes / dropped - plus a raw node mutation. These just funnel into the real HopNode on the
// `core` queue, so they're safe to drive directly with synthetic link ids (no radio). Also pins the
// remaining applyRefresh advert-collapse branch (a stale advert arriving AFTER a fresher one).

import XCTest
import Foundation
import HopContract
@testable import HopDriver

final class HeadlessSeamTests: XCTestCase {

    private func addr(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    func testLinkSeamsDriveTheNodeWithoutARadio() {
        let b = makeHeadlessBearer()
        b.linkUp(7, initiator: true)                 // node.connected
        b.deliver(link: 7, bytes: Data([0x00, 0x01, 0x02]))   // node.received (a non-handshake frame is dropped)
        b.linkDown(7)                                // node.disconnected
        b.nodeDo { node in _ = node.address() }      // arbitrary node mutation
        settle(b)   // reaching here without a crash exercises the whole seam
    }

    func testApplyRefreshRefreshesHopsWhenAStaleAdvertArrivesAfterAFresherOne() {
        let b = makeHeadlessBearer()
        let a = addr(0x51)
        let now = HopBearer.nowMs()
        // Fresher advert first, then an OLDER one for the same publisher - the older one must only refresh
        // the hop distance, never overwrite the current name/state.
        let newer = ServiceHit(publisher: a, service: "presence", title: "Current", summary: "fg|ios|App",
                               tags: [], hops: 3, createdAt: now)
        let older = ServiceHit(publisher: a, service: "presence", title: "Stale", summary: "bg|android|App",
                               tags: [], hops: 1, createdAt: now - 20_000)
        b.applyRefresh(HopBearer.RefreshSnapshot(browse: [newer, older], peerLinks: [], secured: [], routed: [],
                                                 queue: [], hnsCache: [], statuses: [:]))
        XCTAssertEqual(b.reachable.count, 1)
        XCTAssertEqual(b.reachable.first?.name, "Current", "the fresher advert keeps the display name")
        XCTAssertEqual(b.reachable.first?.hops, 1, "the stale advert still contributes its nearer hop count")
    }
    private class DummyBearer: Bearer {
        var sink: LinkSink?
        let transportName: String
        var closedLinks: [LinkId] = []
        var authenticatedLinks: [LinkId] = []
        var onSend: ((Data, LinkId) -> Void)?
        init(transportName: String = "Dummy") { self.transportName = transportName }
        func start() {}
        func stop() {}
        func send(_ bytes: Data, on link: LinkId) { onSend?(bytes, link) }
        func close(_ link: LinkId) { closedLinks.append(link) }
        func authenticated(_ link: LinkId) { authenticatedLinks.append(link) }
    }

    func testDriverManagerPathReapsUnauthenticatedLinkWhileAuthenticatedSurvives() {
        let b = makeHeadlessBearer()
        let dummy = DummyBearer()
        b.bearerMgr.register(dummy)
        dummy.sink?.linkUp(101, role: .acceptor, peerId: addr(0x01))
        dummy.sink?.linkUp(102, role: .acceptor, peerId: addr(0x02))

        // Mark link 101 secured through the manager
        b.bearerMgr.markSecured(1_000_000)
        XCTAssertTrue(dummy.authenticatedLinks.contains(101))

        // Check preauth deadlines 5 seconds later: neither is reaped
        b.bearerMgr.checkPreauthDeadlines(HopBearer.nowMs() + 5_000)
        XCTAssertFalse(dummy.closedLinks.contains(101))
        XCTAssertFalse(dummy.closedLinks.contains(102))

        // Check preauth deadlines 15 seconds later (past 10s deadline):
        // Authenticated peer survives; unauthenticated peer is closed!
        b.bearerMgr.checkPreauthDeadlines(HopBearer.nowMs() + 15_000)
        XCTAssertFalse(dummy.closedLinks.contains(101), "authenticated peer must survive past 10s")
        XCTAssertTrue(dummy.closedLinks.contains(102), "unauthenticated peer must be reaped at deadline")
    }

    /// PLAT-013: Noise XX transport authentication completes (peerLinks reports the link),
    /// but no application-level Double Ratchet forward-secret message has been exchanged yet
    /// (isSecured is false). The driver's backgroundTick/refresh loop must mark the link secured
    /// in BearerManager so it survives past PREAUTH_DEADLINE (10s), rather than gating on isSecured.
    func testNoiseXXAuthenticatedLinkSurvivesPreauthDeadlineWithoutDoubleRatchetSession() {
        let b = makeHeadlessBearer()
        let dummy = DummyBearer()
        b.bearerMgr.register(dummy)
        let peerNode = HopNode()

        dummy.onSend = { bytes, linkId in
            peerNode.received(link: 1_000_000, bytes: bytes)
        }

        dummy.sink?.linkUp(101, role: .acceptor, peerId: addr(0x01))
        b.bearerLinkUp(1_000_000, role: .acceptor)
        dummy.sink?.linkUp(102, role: .acceptor, peerId: addr(0x02))
        b.bearerLinkUp(1_000_001, role: .acceptor)

        peerNode.connected(link: 1_000_000, initiator: true)

        // Pump Noise XX handshake between b and peerNode
        for _ in 0..<10 {
            for pkt in peerNode.drainOutgoing() {
                b.deliver(link: 1_000_000, bytes: pkt.bytes)
            }
            settle(b)
        }

        // Verify Noise XX completed: link 1_000_000 is present in peerLinks()
        var peerLinks: [PeerLink] = []
        b.nodeDo { node in peerLinks = node.peerLinks() }
        settle(b)
        XCTAssertTrue(peerLinks.contains { $0.link == 1_000_000 }, "link must be present in peerLinks after Noise XX")

        // Verify application-level Double Ratchet session does NOT exist
        var isSecured = true
        b.nodeDo { node in isSecured = node.isSecured(address: peerNode.address()) }
        settle(b)
        XCTAssertFalse(isSecured, "newly established link must not have an application-level Double Ratchet session")

        // Run driver background tick which reads peerLinks and must mark links secured
        b.backgroundTick()
        settle(b)

        // Advance time past PREAUTH_DEADLINE (10s) and check deadlines
        b.bearerMgr.checkPreauthDeadlines(HopBearer.nowMs() + 15_000)

        // Assert that Noise XX authenticated link 101 survives and is NOT closed,
        // while unauthenticated link 102 IS closed!
        XCTAssertFalse(dummy.closedLinks.contains(101), "Noise XX authenticated link must survive preauth deadline")
        XCTAssertTrue(dummy.closedLinks.contains(102), "unauthenticated link must be reaped at deadline")
    }

    /// PLAT-013: WebSocket relay links are never Double Ratchet chat peers (isSecured is always false),
    /// but complete Noise XX transport handshake with the relay. The driver must mark the relay link secured
    /// and keep it live across continuous background ticks past preauth deadlines.
    func testRelayLinkMarkedSecuredAfterNoiseHandshakeSurvivesContinuousBackgroundTicks() {
        let b = makeHeadlessBearer()
        let relay = DummyBearer(transportName: "Relay")
        b.bearerMgr.register(relay)
        let relayNode = HopNode()

        relay.onSend = { bytes, linkId in
            relayNode.received(link: 1_000_000, bytes: bytes)
        }

        relay.sink?.linkUp(201, role: .dialer, peerId: addr(0x77))
        b.bearerLinkUp(1_000_000, role: .dialer)
        relayNode.connected(link: 1_000_000, initiator: false)

        // Pump Noise XX handshake between b and relayNode
        for _ in 0..<10 {
            for pkt in relayNode.drainOutgoing() {
                b.deliver(link: 1_000_000, bytes: pkt.bytes)
            }
            settle(b)
        }

        // Verify Noise XX completed: relay link 1_000_000 is present in peerLinks()
        var peerLinks: [PeerLink] = []
        b.nodeDo { node in peerLinks = node.peerLinks() }
        settle(b)
        XCTAssertTrue(peerLinks.contains { $0.link == 1_000_000 }, "relay link must be in peerLinks")

        // Relay is never a Double Ratchet messaging peer
        var isSecured = true
        b.nodeDo { node in isSecured = node.isSecured(address: relayNode.address()) }
        settle(b)
        XCTAssertFalse(isSecured, "relays are never Double Ratchet session peers")

        // Run background tick
        b.backgroundTick()
        settle(b)

        // Verify relay link was marked secured on the bearer
        XCTAssertTrue(relay.authenticatedLinks.contains(201), "relay link must be marked authenticated")

        // Simulate continuous background operation across multiple deadline intervals (15s, 30s, 45s)
        let now = HopBearer.nowMs()
        for offset: UInt64 in [15_000, 30_000, 45_000] {
            b.bearerMgr.checkPreauthDeadlines(now + offset)
            XCTAssertFalse(relay.closedLinks.contains(201), "relay link must survive continuous operation at +\(offset)ms")
        }
    }

}
