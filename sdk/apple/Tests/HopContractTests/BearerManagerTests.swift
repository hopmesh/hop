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
    // Equatable so a test can assert the WHOLE capture at once (`XCTAssertEqual(sink.ups, [])`), which
    // is the only way to say "nothing at all was surfaced" without also passing on a partial match.
    struct Up: Equatable { let link: LinkId; let role: HopRole; let peer: Data }
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

    // MARK: - Per-transport enablement (integrators do not all want every radio)

    func testEverythingIsEnabledByDefaultSoRegisteringIsUnchanged() {
        let mgr = BearerManager()
        let ble = FakeBearer("BT"), relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        XCTAssertTrue(mgr.isEnabled("BT"))
        XCTAssertTrue(mgr.isEnabled("Relay"))
        XCTAssertEqual(mgr.bearerStates(), ["BT": true, "Relay": true])
        mgr.start()
        XCTAssertEqual(ble.started, 1)
        XCTAssertEqual(relay.started, 1, "a fresh manager starts every bearer, as before")
    }

    func testDisablingStopsOnlyThatTransport() {
        let mgr = BearerManager()
        let ble = FakeBearer("BT"), relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()

        XCTAssertTrue(mgr.setEnabled("Relay", false))
        XCTAssertEqual(relay.stopped, 1)
        XCTAssertEqual(ble.stopped, 0, "disabling one transport must not disturb another")
        XCTAssertFalse(mgr.isEnabled("Relay"))
        XCTAssertTrue(mgr.isEnabled("BT"))
    }

    /// The property that makes this safe. Stopping a bearer without downing its links would leave the
    /// node holding a path that can never carry bytes again, so it would keep choosing that dead path
    /// instead of re-offering the bundle over another transport.
    func testDisablingTearsDownThatBearersLiveLinksAndLeavesOthersAlone() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 500)
        mgr.sink = sink
        let ble = FakeBearer("BT"), relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()

        ble.sink?.linkUp(1, role: .dialer, peerId: Data([0xAA]))     // global 500
        relay.sink?.linkUp(7, role: .dialer, peerId: Data([0xBB]))   // global 501
        relay.sink?.linkUp(8, role: .acceptor, peerId: Data([0xCC]))   // global 502
        XCTAssertEqual(sink.ups.map(\.link), [500, 501, 502])

        mgr.setEnabled("Relay", false)
        XCTAssertEqual(sink.downs, [501, 502], "every link the relay owned is downed, in id order")

        // Routing for the surviving transport is untouched...
        mgr.send(Data([0x01]), on: 500)
        XCTAssertEqual(ble.sent.count, 1)
        // ...and the torn-down globals are no longer routable, so a late send cannot reach a dead pipe.
        mgr.send(Data([0x02]), on: 501)
        XCTAssertEqual(relay.sent.count, 0, "a global id whose bearer was disabled must not route")
        XCTAssertNil(mgr.transportName(of: 501))
    }

    func testDisabledBearerStaysDownAcrossAStopStartCycle() {
        let mgr = BearerManager()
        let ble = FakeBearer("BT"), relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false)
        let relayStartsBefore = relay.started

        mgr.stop(); mgr.start()   // the host restarting the mesh must not revive a disabled transport
        XCTAssertEqual(relay.started, relayStartsBefore, "a disabled transport must not come back on start()")
        XCTAssertEqual(ble.started, 2, "the enabled one restarts normally")
        XCTAssertFalse(mgr.isEnabled("Relay"))
    }

    func testReEnablingStartsItAgainAndOnlyWhenTheManagerIsStarted() {
        let mgr = BearerManager()
        let relay = FakeBearer("Relay")
        mgr.register(relay)

        // Toggled BEFORE start: no start call, the setting just waits for start().
        mgr.setEnabled("Relay", false)
        mgr.setEnabled("Relay", true)
        XCTAssertEqual(relay.started, 0, "enablement before start() must not start the bearer early")
        mgr.start()
        XCTAssertEqual(relay.started, 1)

        // Toggled AFTER start: takes effect immediately.
        mgr.setEnabled("Relay", false)
        mgr.setEnabled("Relay", true)
        XCTAssertEqual(relay.started, 2)
    }

    func testIsIdempotentAndReportsAnUnknownTransport() {
        let mgr = BearerManager()
        let relay = FakeBearer("Relay")
        mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false)
        mgr.setEnabled("Relay", false)
        XCTAssertEqual(relay.stopped, 1, "disabling twice must stop once")
        mgr.setEnabled("Relay", true)
        mgr.setEnabled("Relay", true)
        XCTAssertEqual(relay.started, 2, "enabling twice must start once")
        XCTAssertFalse(mgr.setEnabled("Nope", false), "an unknown transport reports no match")
        XCTAssertFalse(mgr.isEnabled("Nope"))
    }

    // MARK: - PLAT-001: a bearer that is disabled or stopped cannot surface a link
    //
    // The regression the audit named: enablement was enforced only where the manager called INTO a
    // bearer (start/stop), never where a bearer called BACK. A BLE link that was open but had not yet
    // completed HELLO when the user switched the transport off finished its handshake afterwards,
    // called sink.linkUp, and the manager minted it a global id, so the "disabled" transport was
    // routing node packets again while the UI still said disabled. Each of these fails without the
    // guard in `up()`.

    func testALinkSurfacedAfterDisablingIsRefused() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 700)
        mgr.sink = sink
        let ble = FakeBearer("BT")
        mgr.register(ble)
        mgr.start()

        mgr.setEnabled("BT", false)
        // The bearer's stop() has returned, but a channel that was mid-handshake completes now.
        ble.sink?.linkUp(1, role: .acceptor, peerId: Data([0xAA]))

        XCTAssertEqual(sink.ups, [], "a disabled bearer must not surface a link to the consumer")
        XCTAssertEqual(mgr.activeTransports(), [:], "activeTransports must agree with bearerStates")
        XCTAssertEqual(mgr.bearerStates(), ["BT": false])
        XCTAssertNil(mgr.transportName(of: 700), "no global id may have been minted for it")
        // And nothing routes over it: send on the id it would have been given is a no-op.
        mgr.send(Data([0x01]), on: 700)
        XCTAssertTrue(ble.sent.isEmpty, "a disabled bearer must never take a packet from send()")
        // Its bytes/down callbacks are inert too (nothing was ever mapped).
        ble.sink?.linkBytes(1, Data([0x02]))
        ble.sink?.linkDown(1)
        XCTAssertEqual(sink.bytes.count, 0)
        XCTAssertEqual(sink.downs, [])
    }

    func testALinkSurfacedAfterTheManagerStoppedIsRefusedUntilRestart() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 800)
        mgr.sink = sink
        let ble = FakeBearer("BT")
        mgr.register(ble)
        mgr.start()
        mgr.stop()

        ble.sink?.linkUp(1, role: .dialer, peerId: Data([0xBB]))
        XCTAssertEqual(sink.ups, [], "a stopped bearer must not surface a link")
        XCTAssertEqual(mgr.activeTransports(), [:])

        // Restarting the mesh re-arms it: the bearer is meant to be running again.
        mgr.start()
        ble.sink?.linkUp(2, role: .dialer, peerId: Data([0xBB]))
        XCTAssertEqual(sink.ups.map(\.link), [800], "a restarted bearer surfaces links again")
        XCTAssertEqual(mgr.activeTransports(), ["BT": 1])
    }

    func testReEnablingRestoresTheAbilityToSurfaceLinks() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 900)
        mgr.sink = sink
        let relay = FakeBearer("Relay")
        mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false)
        relay.sink?.linkUp(1, role: .dialer, peerId: Data([0xCC]))
        XCTAssertEqual(sink.ups, [])

        mgr.setEnabled("Relay", true)
        relay.sink?.linkUp(2, role: .dialer, peerId: Data([0xCC]))
        XCTAssertEqual(sink.ups.map(\.link), [900], "re-enabling must not leave the transport muted")
        mgr.send(Data([0x09]), on: 900)
        XCTAssertEqual(relay.sent.count, 1)
    }

    func testDisablingOneTransportDoesNotMuteAnother() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 1_100)
        mgr.sink = sink
        let ble = FakeBearer("BT"), relay = FakeBearer("Relay")
        mgr.register(ble); mgr.register(relay)
        mgr.start()
        mgr.setEnabled("Relay", false)

        relay.sink?.linkUp(1, role: .dialer, peerId: Data([0x01]))   // refused
        ble.sink?.linkUp(1, role: .dialer, peerId: Data([0x02]))     // still fine
        XCTAssertEqual(sink.ups.map(\.link), [1_100])
        XCTAssertEqual(mgr.activeTransports(), ["BT": 1])
    }

    func testTwoBearersSharingANameToggleAsOneGroup() {
        // transportName is the handle, so a shared name is deliberately one addressable group rather
        // than an arbitrary pick between them.
        let mgr = BearerManager()
        let a = FakeBearer("Relay"), b = FakeBearer("Relay")
        mgr.register(a); mgr.register(b)
        mgr.start()
        mgr.setEnabled("Relay", false)
        XCTAssertEqual(a.stopped, 1); XCTAssertEqual(b.stopped, 1)
        XCTAssertEqual(mgr.bearerStates(), ["Relay": false])
    }

    // MARK: - PLAT-001 (closure): enablement is keyed by transportName, not by bearer object
    //
    // The invariant is stated PER NAME: "no bearer carrying that transportName may surface a new
    // linkUp". Keyed by ObjectIdentifier, a bearer registered after the toggle carried no entry, so it
    // started, its links were accepted, and bearerStates() ORed the tag back to true. These fail
    // against an identity-keyed `disabled`.

    func testABearerRegisteredUnderAnAlreadyDisabledNameIsDormant() {
        let sink = CapturingSink()
        let mgr = BearerManager(baseLinkId: 1_300)
        mgr.sink = sink
        let first = FakeBearer("Relay")
        mgr.register(first)
        mgr.start()
        mgr.setEnabled("Relay", false)

        // A second relay bearer joins the (disabled) group afterwards. A host does this on a config
        // reload, or when a second relay endpoint is added while the transport is switched off.
        let second = FakeBearer("Relay")
        mgr.register(second)

        XCTAssertEqual(second.started, 0, "registering into a disabled tag must not start the bearer")
        XCTAssertFalse(mgr.isEnabled("Relay"))
        XCTAssertEqual(mgr.bearerStates(), ["Relay": false], "one bearer cannot flip the group back on")

        second.sink?.linkUp(1, role: .dialer, peerId: Data([0xDD]))
        XCTAssertEqual(sink.ups, [], "a bearer under a disabled name must not surface a link either")
        XCTAssertEqual(mgr.activeTransports(), [:])
        XCTAssertNil(mgr.transportName(of: 1_300))

        // A restart must not resurrect it either: the setting outlives the mesh lifecycle.
        mgr.stop(); mgr.start()
        XCTAssertEqual(second.started, 0)
        second.sink?.linkUp(2, role: .dialer, peerId: Data([0xDD]))
        XCTAssertEqual(sink.ups, [])

        // Enabling the tag brings the whole group up, including the late arrival.
        mgr.setEnabled("Relay", true)
        XCTAssertEqual(second.started, 1)
        second.sink?.linkUp(3, role: .dialer, peerId: Data([0xDD]))
        XCTAssertEqual(sink.ups.map(\.link), [1_300])
        XCTAssertEqual(mgr.activeTransports(), ["Relay": 1])
    }

    // MARK: - PLAT-008: release diagnostics privacy gate & URL redaction

    func testReleaseDiagnosticsPrivacyAndURLRedaction() {
        // 1) URL component redaction strips query, userinfo, fragment, path
        let sensitiveURL = "wss://user:pass@relay.example.com:8443/secret/path?credential=token123#frag"
        let cleanURL = redactURL(sensitiveURL)
        XCTAssertEqual(cleanURL, "wss://relay.example.com:8443")
        XCTAssertFalse(cleanURL.contains("user"))
        XCTAssertFalse(cleanURL.contains("pass"))
        XCTAssertFalse(cleanURL.contains("secret"))
        XCTAssertFalse(cleanURL.contains("token123"))
        XCTAssertFalse(cleanURL.contains("frag"))

        // Plain host/port URL remains well-formed
        XCTAssertEqual(redactURL("ws://127.0.0.1:9050/"), "ws://127.0.0.1:9050")

        // 2) Logging gate
        let originalGate = diagnosticsLoggingEnabled
        defer {
            diagnosticsLoggingEnabled = originalGate
            logOutputSinkForTesting = nil
        }

        var capturedLogs: [(String, String)] = []
        logOutputSinkForTesting = { cat, msg in capturedLogs.append((cat, msg)) }

        // When diagnostics are disabled (release default), nothing is emitted
        diagnosticsLoggingEnabled = false
        log("STATE", "sentinel_secret_address_12345")
        XCTAssertTrue(capturedLogs.isEmpty, "disabled diagnostics must emit zero logs")

        // When diagnostics are explicitly enabled, output sink receives lines
        diagnosticsLoggingEnabled = true
        log("STATE", "permitted_debug_message")
        XCTAssertEqual(capturedLogs.count, 1)
        XCTAssertEqual(capturedLogs[0].1, "permitted_debug_message")
    }
}
