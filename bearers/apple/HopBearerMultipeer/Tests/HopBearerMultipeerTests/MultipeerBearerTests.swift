// Radio-free tests for the Multipeer bearer's decision logic. No MCSession, no Wi-Fi, no device: the
// framework glue lives in +Radio.swift and is covered by the on-device workflow. What is pinned here
// is the small set of facts whose silent change would break interop or the link table.

import XCTest
import HopContract
@testable import HopBearerMultipeer

private final class CapturingSink: LinkSink {
    private(set) var ups: [(LinkId, HopRole, Data)] = []
    private(set) var downs: [LinkId] = []
    private(set) var bytes: [(LinkId, Data)] = []
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { ups.append((link, role, peerId)) }
    func linkBytes(_ link: LinkId, _ b: Data) { bytes.append((link, b)) }
    func linkDown(_ link: LinkId) { downs.append(link) }
}

final class MultipeerBearerTests: XCTestCase {

    /// iOS silently refuses to browse or advertise a service the app has not declared under
    /// NSBonjourServices, and the symptom is "no peers ever appear" rather than an error. The app's
    /// Info.plist declares `_hop-mesh._tcp` / `_hop-mesh._udp`, so this string is a contract with a
    /// file in another package and cannot be renamed casually.
    func testServiceTypeMatchesTheInfoPlistDeclaration() {
        XCTAssertEqual(MultipeerBearer.serviceType, "hop-mesh")
    }

    /// The toggle handle. `BearerManager.setEnabled` matches on `transportName`, and the driver and
    /// both demo apps already map "P2P" to the Peer-to-Peer row, so this string is what makes the
    /// transport switchable with no UI change. It is why the extraction was worth doing.
    func testTransportNameIsTheToggleHandleTheUiAlreadyKnows() {
        XCTAssertEqual(MultipeerBearer(transportId: "aa").transportName, "P2P")
    }

    /// Exactly one side of a pair invites, or both invite and race to build duplicate sessions.
    ///
    /// This asserts the SMALLER id invites, which is deliberately the opposite of the BLE/LAN
    /// tiebreak where the greater id dials. It is preserved verbatim from the in-driver code: the
    /// rule only works if both devices agree, so flipping it for parity is a symmetric change that
    /// must ship to both sides at once, not something an extraction may quietly alter.
    func testOnlyTheSmallerIdInvitesAndTheRuleIsTotal() {
        XCTAssertTrue(MultipeerBearer.shouldInvite(me: "aaaa", peer: "bbbb"))
        XCTAssertFalse(MultipeerBearer.shouldInvite(me: "bbbb", peer: "aaaa"))
        // Total and antisymmetric: for any distinct pair exactly one side invites.
        for (a, b) in [("00", "ff"), ("0a", "0b"), ("7f", "80")] {
            XCTAssertNotEqual(MultipeerBearer.shouldInvite(me: a, peer: b),
                              MultipeerBearer.shouldInvite(me: b, peer: a),
                              "exactly one of \(a)/\(b) must invite")
        }
        // A peer with our own name must not be invited (it is us, seen reflected).
        XCTAssertFalse(MultipeerBearer.shouldInvite(me: "abcd", peer: "abcd"))
    }

    func testDisplayNameParsesToAPeerIdAndRejectsForeignAdvertisers() {
        let name = String(repeating: "ab", count: 16)   // 32 hex chars = 16 bytes
        XCTAssertEqual(MultipeerBearer.peerId(fromDisplayName: name), Data(repeating: 0xAB, count: 16))
        // Anything else is some other app on the same service type, not a hop peer.
        XCTAssertNil(MultipeerBearer.peerId(fromDisplayName: "too-short"))
        XCTAssertNil(MultipeerBearer.peerId(fromDisplayName: String(repeating: "zz", count: 16)))
        XCTAssertNil(MultipeerBearer.peerId(fromDisplayName: ""))
    }

    /// Local ids start at 1 because BearerManager translates each into its own global space. The old
    /// in-driver code minted from 10_000 purely to keep the driver's hand-rolled id ranges apart,
    /// which is exactly the bookkeeping this extraction deletes.
    func testMintsLocalIdsFromOneSoTheManagerOwnsTheGlobalSpace() {
        let b = MultipeerBearer(transportId: "aa")
        XCTAssertEqual(b.mint(), 1)
        XCTAssertEqual(b.mint(), 2)
    }

    /// Multipeer can report the same peer connected more than once. A duplicate must not mint a
    /// second link, or the consumer would see two paths to one peer and could route into the stale one.
    func testDuplicateConnectDoesNotMintASecondLink() {
        let b = MultipeerBearer(transportId: "aa")
        let first = b.noteConnected(peerName: "peer1")
        XCTAssertEqual(first, 1)
        XCTAssertNil(b.noteConnected(peerName: "peer1"), "a repeat connect must be ignored")
        XCTAssertEqual(b.linkId(forPeer: "peer1"), 1)
    }

    func testDisconnectTearsDownAndIsIdempotent() {
        let b = MultipeerBearer(transportId: "aa")
        _ = b.noteConnected(peerName: "peer1")
        XCTAssertEqual(b.noteDisconnected(peerName: "peer1"), 1)
        XCTAssertNil(b.linkId(forPeer: "peer1"))
        XCTAssertNil(b.noteDisconnected(peerName: "peer1"), "a second disconnect must not re-report")
    }

    /// Two peers get distinct links, and dropping one leaves the other routable. This is the property
    /// the old `mcPeerByLink` dictionary provided inside the driver.
    func testTwoPeersGetDistinctLinksAndOneDroppingLeavesTheOther() {
        let b = MultipeerBearer(transportId: "aa")
        let l1 = b.noteConnected(peerName: "p1")
        let l2 = b.noteConnected(peerName: "p2")
        XCTAssertNotEqual(l1, l2)
        _ = b.noteDisconnected(peerName: "p1")
        XCTAssertNil(b.linkId(forPeer: "p1"))
        XCTAssertEqual(b.linkId(forPeer: "p2"), l2)
    }

    /// The public initializer must mint a RANDOM 32-hex transport id and must not derive it from the
    /// node id it is handed. The display name is broadcast in cleartext over Bonjour/AWDL, so putting
    /// the address there would let a passive listener correlate the device across locations (apple-03).
    func testPublicInitMintsARandomIdAndIgnoresTheNodeAddress() {
        let addr = Data(repeating: 0xAB, count: 32)
        let a = MultipeerBearer(myId: addr)
        let b = MultipeerBearer(myId: addr)
        XCTAssertEqual(a.transportId.count, 32)
        XCTAssertNotNil(MultipeerBearer.peerId(fromDisplayName: a.transportId),
                        "the id must be parseable hex, since peers parse it back")
        XCTAssertNotEqual(a.transportId, b.transportId,
                          "two bearers with the SAME node id must not share a transport id")
        XCTAssertFalse(a.transportId.contains("abab"), "the address must not leak into the display name")
    }

    /// Sending on a link we do not own must be a no-op, not a crash. The manager can hand down a send
    /// for a link that just went away, and a bearer that trapped there would take the node with it.
    func testSendOnAnUnknownLinkIsANoOp() {
        let b = MultipeerBearer(transportId: "aa")
        b.send(Data([1, 2, 3]), on: 999)     // no session, no such link
        let drained = expectation(description: "queue drained")
        b.queue.async { drained.fulfill() }  // proves the async body ran without trapping
        wait(for: [drained], timeout: 2)
    }

    /// Private mode persists rather than applying once, so re-enabling the transport later does not
    /// silently start advertising a node that asked to stay unannounced.
    func testAdvertisingPreferencePersists() {
        let b = MultipeerBearer(transportId: "aa")
        XCTAssertTrue(b.advertisingEnabled, "advertising is on by default")
        b.setAdvertising(false)
        let settled = expectation(description: "settled")
        b.queue.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertFalse(b.advertisingEnabled, "the preference must outlive the call that set it")
    }

    /// `blocked` is what a UI uses to say "Local Network permission is pending" instead of showing a
    /// dead transport, so it must start false and be settable from the bearer's own queue.
    func testBlockedStartsFalseAndIsObservable() {
        let b = MultipeerBearer(transportId: "aa")
        XCTAssertFalse(b.blocked)
        b.blockedForTest(true)
        XCTAssertTrue(b.blocked)
    }

    /// The link table survives churn: connect, drop, reconnect must yield a FRESH id, because the
    /// consumer keys state on link id and reusing one would alias a dead path to a live one.
    func testReconnectAfterDropMintsAFreshLinkId() {
        let b = MultipeerBearer(transportId: "aa")
        let first = b.noteConnected(peerName: "p")
        _ = b.noteDisconnected(peerName: "p")
        let second = b.noteConnected(peerName: "p")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "a reconnect must not reuse the dead link id")
    }

    // MARK: - PLAT-007: 65,536 accepted, 65,537 rejected with link teardown

    func testInboundMessageCapAt65536AndRejectionAt65537() {
        let b = MultipeerBearer(transportId: "aa")
        let sink = CapturingSink()
        b.sink = sink

        guard let link = b.noteConnected(peerName: "peer1") else {
            XCTFail("failed to note connected")
            return
        }

        // 1) 65,536 bytes (cap) is accepted
        let atCap = Data(repeating: 0x41, count: 65536)
        XCTAssertTrue(b.acceptInboundData(atCap, for: link, peerName: "peer1"))
        XCTAssertEqual(sink.bytes.count, 1)
        XCTAssertEqual(sink.bytes[0].0, link)
        XCTAssertEqual(sink.bytes[0].1.count, 65536)
        XCTAssertTrue(sink.downs.isEmpty)

        // 2) 65,537 bytes (cap + 1) is rejected and link is torn down
        let overCap = Data(repeating: 0x42, count: 65537)
        XCTAssertFalse(b.acceptInboundData(overCap, for: link, peerName: "peer1"))
        XCTAssertEqual(sink.bytes.count, 1, "rejected frame must not reach sink")
        XCTAssertEqual(sink.downs, [link], "cap violation must surface linkDown")
        XCTAssertNil(b.linkId(forPeer: "peer1"), "link table must drop offending peer")
    }

    // MARK: - PLAT-005: preauth admission cap, authentication feedback, and consumer-driven close

    /// Unauthenticated peers may hold at most `maxPreauthLinks` slots. The 17th preauth connect is
    /// refused (no link minted), which is what stops a same-network flood from occupying the table
    /// before Noise ever runs.
    func testPreauthAdmissionRefusesTheSeventeenthUnauthenticatedPeer() {
        let b = MultipeerBearer(transportId: "aa")
        for i in 0..<MultipeerBearer.maxPreauthLinks {
            XCTAssertNotNil(b.noteConnected(peerName: "flood\(i)"), "preauth slot \(i) must admit")
        }
        XCTAssertNil(b.noteConnected(peerName: "flood-overflow"), "the preauth cap must refuse the next peer")
        // A slot frees when one of them leaves.
        XCTAssertNotNil(b.noteDisconnected(peerName: "flood0"))
        XCTAssertNotNil(b.noteConnected(peerName: "flood-after-free"))
    }

    /// `authenticated(_:)` is the driver's signal that Noise completed on a link. Once a link is
    /// authenticated it no longer counts against the preauth cap, so honest peers keep admitting
    /// while the flood stays capped, and the total cap (`maxLinks`) is what remains.
    func testAuthenticatedLinksStopCountingAgainstThePreauthCap() {
        let b = MultipeerBearer(transportId: "aa")
        // The link table is owned by the bearer's queue (the +Radio callbacks hop onto it), so every
        // read here goes through `queue.sync` once `authenticated` (async on that queue) is in play.
        func admit(_ name: String) -> LinkId? { b.queue.sync { b.noteConnected(peerName: name) } }
        var links: [LinkId] = []
        for i in 0..<MultipeerBearer.maxPreauthLinks {
            links.append(admit("peer\(i)")!)
        }
        XCTAssertNil(admit("blocked"), "table is full of preauth links")
        // Authenticate all of them through the public Bearer entry point.
        for l in links { b.authenticated(l) }
        XCTAssertNotNil(admit("after-auth"), "authenticated links free preauth capacity")
        // Total cap still holds: fill to maxLinks, then the next is refused whatever its auth state.
        var count = MultipeerBearer.maxPreauthLinks + 1
        while count < MultipeerBearer.maxLinks {
            let l = admit("fill\(count)")
            XCTAssertNotNil(l, "fill\(count) should admit below maxLinks")
            if let l { b.authenticated(l) }
            count += 1
        }
        XCTAssertNil(admit("over-max"), "maxLinks is the hard ceiling")
        XCTAssertNotNil(b.queue.sync { b.noteDisconnected(peerName: "fill17") })
        XCTAssertNotNil(admit("after-free"), "a freed slot admits again below maxLinks")
    }

    /// `close(_:)` is what the BearerManager calls when the preauth deadline expires. It must tear
    /// the link down, report `linkDown` to the sink exactly once, and be a no-op for an unknown id.
    func testCloseTearsDownAndReportsLinkDownOnce() {
        let b = MultipeerBearer(transportId: "aa")
        let sink = CapturingSink()
        b.sink = sink
        let link = b.noteConnected(peerName: "peer1")!
        b.close(link)
        b.close(link)          // second close: the link is gone, nothing to report
        b.close(9_999)         // never existed
        let drained = expectation(description: "queue drained")
        b.queue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(sink.downs, [link])
        XCTAssertNil(b.linkId(forPeer: "peer1"))
        XCTAssertNotNil(b.noteConnected(peerName: "peer1"), "a closed peer may reconnect")
    }

    /// `send` on a known link must reach the radio path. The +Radio send with no MCSession is a
    /// no-op, so this pins only that the queue hop resolves the peer name rather than dropping the
    /// bytes before it. (Unknown-link no-op is covered above.)
    func testSendOnAKnownLinkResolvesThePeerName() {
        let b = MultipeerBearer(transportId: "aa")
        let link = b.noteConnected(peerName: "peer1")!
        b.send(Data([1, 2, 3]), on: link)
        let drained = expectation(description: "queue drained")
        b.queue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(b.linkId(forPeer: "peer1"), link, "sending must not disturb the link table")
    }

    // MARK: - PLAT-015: dead peer tracking, 8-peer MCSession ceiling, and session cycling

    func testDeadPeersAreTrackedAndSessionCycledUponExhaustion() {
        let b = MultipeerBearer(transportId: "aa")
        let sink = CapturingSink()
        b.sink = sink

        // Connect 8 unauthenticated peers to reach the 8-peer MCSession ceiling
        var links: [LinkId] = []
        for i in 0..<MultipeerBearer.maxSessionPeers {
            let link = b.noteConnected(peerName: "peer\(i)")!
            links.append(link)
        }
        XCTAssertEqual(b.deadPeerNames.count, 0)
        XCTAssertEqual(b.sessionCycleCount, 0)

        // Preauth deadline expires for all 8 peers (driver calls close on each)
        for link in links {
            b.close(link)
        }

        let drained = expectation(description: "queue drained")
        b.queue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        // Verify that dead peers were tracked and session was cycled to clear exhaustion
        XCTAssertEqual(b.sessionCycleCount, 1, "session must be cycled when 8 peers are closed")
        XCTAssertTrue(b.deadPeerNames.isEmpty, "cycling session must clear dead peers")
        XCTAssertTrue(b.linkByPeer.isEmpty, "link table is clean")
        XCTAssertEqual(sink.downs.count, 8, "all 8 dead peers surfaced linkDown")

        // An honest peer can connect after the session was cycled
        let honestLink = b.noteConnected(peerName: "honestPeer")
        XCTAssertNotNil(honestLink, "honest peer can connect after session was cycled")

        // A reaped peer can also reconnect
        let reconnectedLink = b.noteConnected(peerName: "peer0")
        XCTAssertNotNil(reconnectedLink, "reaped peer can reconnect after session was cycled")
    }

    func testApproachingEightPeerCeilingCyclesWhenSlotExhaustionOccursOnAdmission() {
        let b = MultipeerBearer(transportId: "aa")
        let sink = CapturingSink()
        b.sink = sink

        // Connect 7 unauthenticated peers (N-1)
        var links: [LinkId] = []
        for i in 0..<7 {
            links.append(b.noteConnected(peerName: "peer\(i)")!)
        }
        XCTAssertEqual(b.sessionCycleCount, 0)

        // Close 2 peers: 5 active, 2 dead (total occupied = 7)
        b.close(links[0])
        b.close(links[1])

        let drained1 = expectation(description: "queue drained 1")
        b.queue.async { drained1.fulfill() }
        wait(for: [drained1], timeout: 2)

        XCTAssertEqual(b.deadPeerNames.count, 2)
        XCTAssertEqual(b.linkByPeer.count, 5)
        XCTAssertEqual(b.sessionCycleCount, 0, "session must not cycle while under ceiling with active links")

        // Connect peer 7: now 6 active, 2 dead (total occupied = 8, at ceiling)
        let link7 = b.noteConnected(peerName: "peer7")!
        XCTAssertNotNil(link7)

        // Close peer 7: now 5 active, 3 dead (total occupied = 8)
        b.close(link7)

        let drained2 = expectation(description: "queue drained 2")
        b.queue.async { drained2.fulfill() }
        wait(for: [drained2], timeout: 2)

        // An incoming honest peer arrives at the ceiling with dead peers holding slots
        let honest = b.noteConnected(peerName: "honestNew")
        XCTAssertNotNil(honest, "honest peer must be admitted")
        XCTAssertEqual(b.sessionCycleCount, 1, "session must cycle to free dead slots for new peer")
        XCTAssertEqual(b.linkByPeer.count, 1, "honest peer is now the active link")
    }

    func testReconnectionOfDeadPeerRemovesFromDeadPeers() {
        let b = MultipeerBearer(transportId: "aa")
        let link = b.noteConnected(peerName: "reconnectPeer")!
        b.close(link)

        let drained = expectation(description: "queue drained")
        b.queue.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertEqual(b.sessionCycleCount, 1, "closing the only active link cycles idle session")
        XCTAssertTrue(b.deadPeerNames.isEmpty)

        let freshLink = b.noteConnected(peerName: "reconnectPeer")
        XCTAssertNotNil(freshLink)
        XCTAssertNotEqual(freshLink, link, "reconnected peer gets fresh link id")
    }

    func testOversizedInboundDataDropsPeerAndTracksDeadPeer() {
        let b = MultipeerBearer(transportId: "aa")
        let sink = CapturingSink()
        b.sink = sink
        let link = b.noteConnected(peerName: "flooder")!
        let overCap = Data(repeating: 0x41, count: 65537)
        XCTAssertFalse(b.acceptInboundData(overCap, for: link, peerName: "flooder"))
        XCTAssertEqual(b.sessionCycleCount, 1, "session cycled after dropping only active link")
        XCTAssertTrue(b.deadPeerNames.isEmpty)
        XCTAssertEqual(sink.downs, [link])
    }
}
