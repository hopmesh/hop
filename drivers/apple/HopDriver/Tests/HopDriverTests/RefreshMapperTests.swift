// Direct unit coverage for the pure snapshot -> UI-row mappers extracted out of HopBearer.applyRefresh
// (cov/apple-driver). applyRefresh's behavior is already pinned end-to-end by HeadlessMappingTests /
// HeadlessSeamTests against a real node; these drive the same logic in isolation so the extracted
// RefreshMapper is covered on its own and the trickier presence-collapse rules are pinned directly.

import XCTest
import Foundation
@testable import HopDriver

final class RefreshMapperTests: XCTestCase {

    private func addr(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    // MARK: aggregatePresence

    func testAggregatePresenceParsesSummaryFields() {
        let hit = ServiceHit(publisher: addr(0x01), service: "presence", title: "Alice",
                             summary: "fg|ios|HopDemo", tags: [], hops: 2, createdAt: 1_000)
        let (reachable, names) = RefreshMapper.aggregatePresence([hit])
        XCTAssertEqual(reachable.count, 1)
        XCTAssertEqual(reachable[0].name, "Alice")
        XCTAssertTrue(reachable[0].active)
        XCTAssertEqual(reachable[0].platform, "ios")
        XCTAssertEqual(reachable[0].app, "HopDemo")
        XCTAssertEqual(names[addr(0x01)], "Alice")
    }

    func testAggregatePresenceEmptyTitleFallsBackToShortId() {
        let a = addr(0x02)
        let hit = ServiceHit(publisher: a, service: "presence", title: "", summary: "", tags: [],
                             hops: 0, createdAt: 1)
        let (reachable, names) = RefreshMapper.aggregatePresence([hit])
        XCTAssertEqual(reachable[0].name, HopBearer.shortHex(a), "no title ⇒ short base58 id")
        XCTAssertTrue(reachable[0].active, "an absent state field defaults to active (fg)")
        XCTAssertEqual(names[a], HopBearer.shortHex(a))
    }

    func testAggregatePresenceCollapsesToNearestHopsAndNewestName() {
        let a = addr(0x03)
        let older = ServiceHit(publisher: a, service: "presence", title: "Old", summary: "bg|ios|App",
                               tags: [], hops: 4, createdAt: 100)
        let newer = ServiceHit(publisher: a, service: "presence", title: "New", summary: "fg|android|App",
                               tags: [], hops: 2, createdAt: 200)
        // Newest-first ordering exercises the "older only refreshes hops" branch.
        let (reachable, _) = RefreshMapper.aggregatePresence([newer, older])
        XCTAssertEqual(reachable.count, 1)
        XCTAssertEqual(reachable[0].name, "New", "newest advert wins the display name/state")
        XCTAssertFalse(reachable[0].active == false, "newest advert (fg) sets active")
        XCTAssertEqual(reachable[0].hops, 2, "nearest hop count is kept from both adverts")
    }

    func testAggregatePresenceSortsByStableAddress() {
        let hi = ServiceHit(publisher: addr(0xF0), service: "presence", title: "Z", summary: "", tags: [],
                            hops: 1, createdAt: 1)
        let lo = ServiceHit(publisher: addr(0x01), service: "presence", title: "A", summary: "", tags: [],
                            hops: 1, createdAt: 1)
        let (reachable, _) = RefreshMapper.aggregatePresence([hi, lo])
        XCTAssertEqual(reachable.map { $0.address }, [addr(0x01), addr(0xF0)], "sorted by address, not name/hops")
    }

    // MARK: legacyTransportTag

    func testLegacyTransportTagRanges() {
        XCTAssertEqual(RefreshMapper.legacyTransportTag(5_000), "BT")
        XCTAssertEqual(RefreshMapper.legacyTransportTag(9_999), "BT")
        XCTAssertEqual(RefreshMapper.legacyTransportTag(10_000), "P2P")
        XCTAssertEqual(RefreshMapper.legacyTransportTag(19_999), "P2P")
        XCTAssertEqual(RefreshMapper.legacyTransportTag(25_000), "Relay")
        XCTAssertEqual(RefreshMapper.legacyTransportTag(39_999), "Relay")
        XCTAssertEqual(RefreshMapper.legacyTransportTag(40_000), "LAN")
        XCTAssertEqual(RefreshMapper.legacyTransportTag(1_000_000), "LAN")
    }

    // MARK: transportStatuses

    func testTransportStatusesListsRegisteredBearersAndAlwaysIncludesP2P() {
        let ts = RefreshMapper.transportStatuses(active: ["BT": 2, "Relay": 1],
                                                 states: ["BT": true, "Relay": true],
                                                 p2pActive: true, p2pLinks: 3)
        XCTAssertEqual(ts.map { $0.id }, ["Bluetooth", "Peer-to-Peer", "Relay"],
                       "registered shared bearers appear in fixed order; Peer-to-Peer is always listed")
        XCTAssertEqual(ts.first { $0.id == "Bluetooth" }?.links, 2)
        XCTAssertEqual(ts.first { $0.id == "Peer-to-Peer" }?.links, 3)
        XCTAssertTrue(ts.first { $0.id == "Peer-to-Peer" }?.active ?? false)
        XCTAssertEqual(ts.first { $0.id == "Bluetooth" }?.tag, "BT", "the toggle handle rides along")
        XCTAssertNil(ts.first { $0.id == "Peer-to-Peer" }?.tag, "Multipeer is not a shared bearer")
    }

    func testTransportStatusesUnregisteredBearerIsStillOmitted() {
        // A relay bearer is only registered when relays are on. Absent from `states` means absent
        // from the list, which is different from registered-but-switched-off.
        let ts = RefreshMapper.transportStatuses(active: [:], states: ["BT": true],
                                                 p2pActive: false, p2pLinks: 0)
        XCTAssertEqual(ts.map { $0.id }, ["Bluetooth", "Peer-to-Peer"])
        XCTAssertFalse(ts.first { $0.id == "Peer-to-Peer" }?.active ?? true)
    }

    /// The regression this mapper change exists to prevent. Switching a transport off drops its links
    /// to zero, and the old mapper keyed presence off the link count, so the row you would use to
    /// switch it back on was exactly the row that disappeared.
    func testADisabledBearerIsStillListedSoItCanBeSwitchedBackOn() {
        let ts = RefreshMapper.transportStatuses(active: ["BT": 2],
                                                 states: ["BT": true, "Relay": false],
                                                 p2pActive: false, p2pLinks: 0)
        XCTAssertEqual(ts.map { $0.id }, ["Bluetooth", "Peer-to-Peer", "Relay"])
        let relay = ts.first { $0.id == "Relay" }
        XCTAssertEqual(relay?.enabled, false, "listed, and reported off")
        XCTAssertEqual(relay?.links, 0)
        XCTAssertEqual(relay?.active, false, "no links, so not active")
        XCTAssertEqual(relay?.tag, "Relay", "still toggleable")
    }

    func testAnUnknownRegisteredTransportIsListedUnderItsOwnTag() {
        // A host may register a bearer this display has no display name for; it must not vanish.
        let ts = RefreshMapper.transportStatuses(active: ["Sat": 1], states: ["Sat": true],
                                                 p2pActive: false, p2pLinks: 0)
        XCTAssertEqual(ts.map { $0.id }, ["Peer-to-Peer", "Sat"])
        XCTAssertEqual(ts.first { $0.id == "Sat" }?.tag, "Sat")
    }

    // MARK: mapQueue

    func testMapQueueRendersBroadcastForEmptyDestination() {
        let rows = RefreshMapper.mapQueue([
            QueueItem(id: addr(0x20), own: true, to: addr(0x21), priority: 2, hops: 0),
            QueueItem(id: addr(0x22), own: false, to: Data(), priority: 0, hops: 3),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].to, HopBearer.shortHex(addr(0x21)))
        XCTAssertEqual(rows[1].to, "broadcast", "an empty destination renders as broadcast")
        XCTAssertFalse(rows[1].own)
    }

    // MARK: mapHnsCache

    func testMapHnsCarriesDomainAddressAndTtl() {
        let rows = RefreshMapper.mapHnsCache([HnsCacheEntry(domain: "acme.hop", address: addr(0x30), ttlSecs: 90)])
        XCTAssertEqual(rows.first?.domain, "acme.hop")
        XCTAssertEqual(rows.first?.address, addr(0x30))
        XCTAssertEqual(rows.first?.ttl, 90)
    }
}
