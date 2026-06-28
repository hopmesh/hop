import XCTest
@testable import HopBearerCore

// Deterministic, radio-free proof that BearerManager actually multiplexes. The whole reason the
// registry exists is the claim "register any Bearer, the consumer sees one uniform link space, and
// sends route to the right bearer." These tests prove that claim instead of asserting it — using a
// FakeBearer that mints its own local LinkIds (from 1, like every real bearer) and lets the test
// drive link up/bytes/down by hand. No CoreBluetooth, no timing, no flakiness.

/// A Bearer with no radio: it records start/stop/sends and exposes hooks to simulate inbound events.
/// Crucially it mints LOCAL link ids from 1 — so two FakeBearers in one manager both produce a local
/// link id `1`, which is exactly the collision the manager's global id space must resolve.
private final class FakeBearer: Bearer {
    weak var sink: LinkSink?
    private(set) var started = false
    private(set) var stopped = false
    private(set) var sent: [(LinkId, Data)] = []        // (local link id, bytes) the manager routed to us
    private var nextLocal: LinkId = 1

    func start() { started = true }
    func stop()  { stopped = true }
    func send(_ bytes: Data, on link: LinkId) { sent.append((link, bytes)) }

    // Test drivers — simulate the transport raising events to its sink (the manager's lane).
    /// Brings a new local link up and returns the local id this bearer assigned.
    @discardableResult
    func bringUp(role: LinkRole, peerId: Data) -> LinkId {
        let local = nextLocal; nextLocal += 1
        sink?.linkUp(local, role: role, peerId: peerId)
        return local
    }
    func deliver(_ bytes: Data, on local: LinkId) { sink?.linkBytes(local, bytes) }
    func drop(_ local: LinkId) { sink?.linkDown(local) }
}

/// Records everything the consumer would see, keyed by the GLOBAL link id the manager presents.
private final class RecordingSink: LinkSink {
    struct Up { let role: LinkRole; let peerId: Data }
    var ups: [LinkId: Up] = [:]
    var bytesByLink: [LinkId: [Data]] = [:]
    var downs: [LinkId] = []
    var upOrder: [LinkId] = []

    func linkUp(_ link: LinkId, role: LinkRole, peerId: Data) {
        ups[link] = Up(role: role, peerId: peerId); upOrder.append(link)
    }
    func linkBytes(_ link: LinkId, _ bytes: Data) { bytesByLink[link, default: []].append(bytes) }
    func linkDown(_ link: LinkId) { downs.append(link) }
}

final class BearerManagerTests: XCTestCase {

    func testStartStopFanOutToEveryBearer() {
        let mgr = BearerManager()
        let a = FakeBearer(), b = FakeBearer()
        mgr.register(a); mgr.register(b)

        XCTAssertFalse(a.started); XCTAssertFalse(b.started)
        mgr.start()
        XCTAssertTrue(a.started); XCTAssertTrue(b.started)
        mgr.stop()
        XCTAssertTrue(a.stopped); XCTAssertTrue(b.stopped)
    }

    func testRegisterWiresEachBearersSink() {
        let mgr = BearerManager()
        let a = FakeBearer()
        XCTAssertNil(a.sink)
        mgr.register(a)
        XCTAssertNotNil(a.sink, "register() must install the manager's lane as the bearer's sink")
    }

    /// The headline claim: two bearers that each mint local link id 1 must surface as DISTINCT global
    /// ids, and a send on a global id must reach the bearer that owns it with that bearer's LOCAL id.
    func testCollidingLocalIdsGetDistinctGlobalIdsAndRouteCorrectly() {
        let mgr = BearerManager()
        let sink = RecordingSink()
        mgr.sink = sink
        let a = FakeBearer(), b = FakeBearer()
        mgr.register(a); mgr.register(b)
        mgr.start()

        let peerA = Data([0xAA]); let peerB = Data([0xBB])
        let localA = a.bringUp(role: .dialer, peerId: peerA)     // bearer A local link 1
        let localB = b.bringUp(role: .acceptor, peerId: peerB)   // bearer B local link 1 (collision!)
        XCTAssertEqual(localA, 1); XCTAssertEqual(localB, 1, "precondition: both bearers minted local id 1")

        // Manager surfaced two DISTINCT global ids.
        XCTAssertEqual(sink.upOrder.count, 2)
        let globalA = sink.upOrder[0]; let globalB = sink.upOrder[1]
        XCTAssertNotEqual(globalA, globalB, "colliding local ids must map to distinct global ids")
        XCTAssertEqual(sink.ups[globalA]?.peerId, peerA)
        XCTAssertEqual(sink.ups[globalB]?.peerId, peerB)
        // Role survives the translation.
        if case .dialer = sink.ups[globalA]!.role {} else { XCTFail("role A should be .dialer") }
        if case .acceptor = sink.ups[globalB]!.role {} else { XCTFail("role B should be .acceptor") }

        // send(on: globalA) routes to bearer A with A's local id; globalB -> bearer B's local id.
        mgr.send(Data([1, 2, 3]), on: globalA)
        mgr.send(Data([9, 9]),    on: globalB)
        XCTAssertEqual(a.sent.count, 1); XCTAssertEqual(b.sent.count, 1)
        XCTAssertEqual(a.sent[0].0, localA); XCTAssertEqual(a.sent[0].1, Data([1, 2, 3]))
        XCTAssertEqual(b.sent[0].0, localB); XCTAssertEqual(b.sent[0].1, Data([9, 9]))
    }

    func testInboundBytesTranslateToTheGlobalLink() {
        let mgr = BearerManager()
        let sink = RecordingSink()
        mgr.sink = sink
        let a = FakeBearer()
        mgr.register(a); mgr.start()

        let local = a.bringUp(role: .dialer, peerId: Data([0x01]))
        let global = sink.upOrder[0]
        a.deliver(Data([0x42]), on: local)
        a.deliver(Data([0x43]), on: local)
        XCTAssertEqual(sink.bytesByLink[global], [Data([0x42]), Data([0x43])])
    }

    /// After linkDown the global id must surface to the consumer AND be forgotten — a later send on it
    /// is a no-op (the bearer must not receive a stale local id).
    func testLinkDownSurfacesAndThenSendIsNoOp() {
        let mgr = BearerManager()
        let sink = RecordingSink()
        mgr.sink = sink
        let a = FakeBearer()
        mgr.register(a); mgr.start()

        let local = a.bringUp(role: .dialer, peerId: Data([0x01]))
        let global = sink.upOrder[0]
        a.drop(local)
        XCTAssertEqual(sink.downs, [global], "linkDown must surface the global id once")

        mgr.send(Data([0xFF]), on: global)
        XCTAssertTrue(a.sent.isEmpty, "send on a closed global link must be a no-op, not a stale route")
    }

    func testSendOnUnknownLinkIsNoOp() {
        let mgr = BearerManager()
        let a = FakeBearer()
        mgr.register(a); mgr.start()
        mgr.send(Data([1]), on: 9999)            // never opened
        XCTAssertTrue(a.sent.isEmpty)
    }

    /// Same bearer, two concurrent links — distinct globals, independent routing.
    func testMultipleLinksOnOneBearerStayIndependent() {
        let mgr = BearerManager()
        let sink = RecordingSink()
        mgr.sink = sink
        let a = FakeBearer()
        mgr.register(a); mgr.start()

        let l1 = a.bringUp(role: .dialer, peerId: Data([0x01]))
        let l2 = a.bringUp(role: .dialer, peerId: Data([0x02]))
        XCTAssertNotEqual(l1, l2)
        let g1 = sink.upOrder[0]; let g2 = sink.upOrder[1]
        XCTAssertNotEqual(g1, g2)

        mgr.send(Data([0xA1]), on: g1)
        mgr.send(Data([0xA2]), on: g2)
        XCTAssertEqual(a.sent.map { $0.0 }, [l1, l2])
        XCTAssertEqual(a.sent.map { $0.1 }, [Data([0xA1]), Data([0xA2])])
    }
}
