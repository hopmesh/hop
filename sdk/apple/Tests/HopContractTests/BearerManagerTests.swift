// core-ffi-09: radio-free tests for the Swift transport multiplexer (the twin of the Kotlin
// BearerManagerTest, and the replacement for the 7 registry tests lost with the old HopBearers
// package). A fake Bearer lets us drive link up/bytes/down; a fake LinkSink captures what the
// consumer sees, so we assert the global-id mapping, per-bearer routing, dedup on down, and the
// transport-tag surface with no CoreBluetooth and no libhop.

import XCTest
@testable import HopContract

/// A bearer that records what it was asked to send and exposes its lane sink to the test.
private final class FakeBearer: Bearer {
    var sink: LinkSink?
    let transportName: String
    private(set) var started = 0
    private(set) var stopped = 0
    private(set) var sent: [(LinkId, Data)] = []
    init(_ transportName: String) { self.transportName = transportName }
    func start() { started += 1 }
    func stop() { stopped += 1 }
    func send(_ bytes: Data, on link: LinkId) { sent.append((link, bytes)) }
}

/// Captures exactly what the consumer (the node) sees out of the manager.
private final class CapturingSink: LinkSink {
    struct Up { let link: LinkId; let role: HopRole; let peer: Data }
    private(set) var ups: [Up] = []
    private(set) var bytes: [(LinkId, Data)] = []
    private(set) var downs: [LinkId] = []
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { ups.append(Up(link: link, role: role, peer: peerId)) }
    func linkBytes(_ link: LinkId, _ b: Data) { bytes.append((link, b)) }
    func linkDown(_ link: LinkId) { downs.append(link) }
}

final class BearerManagerTests: XCTestCase {

    func testMintsGlobalIdsFromBaseAndTranslatesPerBearer() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 1_000)
        mgr.sink = sink
        let ble = FakeBearer("BT")
        let lan = FakeBearer("LAN")
        mgr.register(ble)
        mgr.register(lan)

        // Each bearer brings up a link with its OWN local id 1; the manager mints distinct globals.
        ble.sink?.linkUp(1, role: .dialer, peerId: Data([0x0B]))
        lan.sink?.linkUp(1, role: .acceptor, peerId: Data([0x0A]))

        XCTAssertEqual(sink.ups.map { $0.link }, [1_000, 1_001], "globals mint from baseLinkId, monotonic")
        XCTAssertEqual(sink.ups[0].role, .dialer)
        XCTAssertEqual(sink.ups[1].role, .acceptor)
        XCTAssertEqual(sink.ups[0].peer, Data([0x0B]))
        XCTAssertEqual(mgr.transportName(of: 1_000), "BT")
        XCTAssertEqual(mgr.transportName(of: 1_001), "LAN")
    }

    func testRoutesSendAndInboundBytesToTheOwningBearerOnly() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 1)
        mgr.sink = sink
        let ble = FakeBearer("BT")
        let lan = FakeBearer("LAN")
        mgr.register(ble); mgr.register(lan)
        ble.sink?.linkUp(7, role: .dialer, peerId: Data([1]))   // global 1 -> (ble, local 7)
        lan.sink?.linkUp(9, role: .dialer, peerId: Data([2]))   // global 2 -> (lan, local 9)

        // Consumer sends on the GLOBAL id; it must reach the right bearer under its LOCAL id.
        mgr.send(Data([42]), on: 1)
        mgr.send(Data([43]), on: 2)
        XCTAssertEqual(ble.sent.map { ($0.0, $0.1.first!) }.map { "\($0.0):\($0.1)" }, ["7:42"])
        XCTAssertEqual(lan.sent.map { ($0.0, $0.1.first!) }.map { "\($0.0):\($0.1)" }, ["9:43"])

        // Inbound bytes on a bearer's local id surface to the consumer under the global id.
        ble.sink?.linkBytes(7, Data([99]))
        XCTAssertEqual(sink.bytes.count, 1)
        XCTAssertEqual(sink.bytes[0].0, 1)
        XCTAssertEqual(sink.bytes[0].1, Data([99]))

        // A send to an unknown/closed link is a no-op (not a crash).
        mgr.send(Data([0]), on: 12_345)
    }

    func testDownSurfacesOnceAndForgetsTheMapping() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 1)
        mgr.sink = sink
        let ble = FakeBearer("BT")
        mgr.register(ble)
        ble.sink?.linkUp(5, role: .dialer, peerId: Data([1]))   // global 1
        ble.sink?.linkDown(5)
        XCTAssertEqual(sink.downs, [1], "down surfaces the global id exactly once")

        // Mapping forgotten: a send on the dead global routes nowhere, a duplicate down is ignored.
        mgr.send(Data([1]), on: 1)
        XCTAssertTrue(ble.sent.isEmpty, "no routing after down")
        ble.sink?.linkDown(5)
        XCTAssertEqual(sink.downs, [1], "a duplicate down is not re-surfaced")
        XCTAssertNil(mgr.transportName(of: 1))
    }

    func testStartStopFanOutToEveryRegisteredBearer() {
        let mgr = BearerManager()
        let a = FakeBearer("BT")
        let b = FakeBearer("LAN")
        mgr.register(a); mgr.register(b)
        mgr.start()
        mgr.stop()
        XCTAssertEqual(a.started, 1); XCTAssertEqual(b.started, 1)
        XCTAssertEqual(a.stopped, 1); XCTAssertEqual(b.stopped, 1)
    }

    func testActiveTransportsCountsLiveLinksPerTag() {
        let mgr = BearerManager(baseLinkId: 1)
        mgr.sink = CapturingSink()
        let ble = FakeBearer("BT")
        let lan = FakeBearer("LAN")
        mgr.register(ble); mgr.register(lan)
        ble.sink?.linkUp(1, role: .dialer, peerId: Data([1]))   // BT global 1
        ble.sink?.linkUp(2, role: .dialer, peerId: Data([2]))   // BT global 2
        lan.sink?.linkUp(1, role: .acceptor, peerId: Data([3])) // LAN global 3
        XCTAssertEqual(mgr.activeTransports(), ["BT": 2, "LAN": 1])

        ble.sink?.linkDown(1)   // one BT link goes away
        XCTAssertEqual(mgr.activeTransports(), ["BT": 1, "LAN": 1])
    }

    // The tiebreaker helper both sides use so two peers that discover each other don't double-dial.
    func testNodeIdGreaterIsUnsignedBigEndian() {
        XCTAssertTrue(nodeIdGreater(Data([0x80]), Data([0x7f])), "high bit is unsigned, not negative")
        XCTAssertFalse(nodeIdGreater(Data([0x01, 0x02]), Data([0x01, 0x02])), "identical is not greater")
        XCTAssertTrue(nodeIdGreater(Data([0x01, 0x02, 0x00]), Data([0x01, 0x02])), "equal prefix, longer wins")
        XCTAssertTrue(nodeIdGreater(Data([0x02, 0x00]), Data([0x01, 0xff])), "most-significant byte decides")
    }
}
