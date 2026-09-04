// MeshtasticBearer, the Hop transport that RELAYS through a connected Meshtastic radio. A phone pairs
// with a nearby Meshtastic device (over BLE); that device is a gateway into a LoRa mesh where every other
// radio relays packets hop by hop. This bearer turns that mesh into a Hop transport: each remote Meshtastic
// node that is also running Hop becomes a peer, Hop link frames are fragmented into LoRa-sized Meshtastic
// packets on a private app port, and the mesh carries them. The result the consumer sees is identical to
// any other bearer: linkUp / linkBytes / linkDown keyed on the peer's 16-byte nodeId.
//
// TESTABILITY. All Meshtastic PROTOCOL logic (protobuf, fragmentation, the Hop link-frame grammar, dedup)
// lives in MeshtasticWire.swift and is unit-tested with no radio. This file owns the LINK STATE MACHINE
// and drives a `MeshtasticRadio` seam that moves raw ToRadio/FromRadio protobuf frames over the wire. In
// production the seam is CoreBluetoothMeshtasticRadio (MeshtasticBearer+Radio.swift, the CoreBluetooth GATT
// client, excluded from the coverage denominator like every bearer's radio glue). In tests it is a fake
// radio, so the whole state machine (connect, discover, reassemble, dedup, keepalive, reap, send) runs
// headlessly on a serial queue with an injected clock.
//
// THREADING. One serial queue (`meshQueue`) owns every link/reassembly/timer mutation, so the bearer is
// single-threaded end to end and needs no locks (the same discipline the LAN bearer gets from `lanQueue`).
// The radio delivers inbound frames onto this queue.

import Foundation
import HopContract

/// The seam between the link state machine and the physical Meshtastic device. It moves opaque protobuf
/// frames: `send(toRadio:)` writes one `ToRadio`, and `onFromRadio` fires once per decoded `FromRadio`.
/// Connection lifecycle is reported via `onConnect` / `onDisconnect`. Callbacks are delivered on the
/// bearer's `meshQueue`.
protocol MeshtasticRadio: AnyObject {
    var onConnect: (() -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    var onFromRadio: (([UInt8]) -> Void)? { get set }
    func start()
    func stop()
    func send(toRadio bytes: [UInt8])
}

/// One logical link to a remote Meshtastic node. There is at most one per (peer node num), created when
/// the first HELLO from that node is reassembled.
final class MeshLink {
    let linkId: LinkId
    let nodeNum: UInt32
    var peerId: Data
    /// True iff MY nodeId is the greater one (the Noise initiator, mirroring "greater dials" elsewhere).
    let isGreater: Bool
    var up = false
    var surfaced = false
    var lastRxMs: UInt64
    var lastPingMs: UInt64
    var txSeq: UInt64 = 0

    init(linkId: LinkId, nodeNum: UInt32, peerId: Data, isGreater: Bool, nowMs: UInt64) {
        self.linkId = linkId; self.nodeNum = nodeNum; self.peerId = peerId
        self.isGreater = isGreater; self.lastRxMs = nowMs; self.lastPingMs = nowMs
    }

    var role: HopRole { isGreater ? .dialer : .acceptor }
    var peerShort: String { shortHex(peerId) }
}

public final class MeshtasticBearer: Bearer {
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). Meshtastic/LoRa links surface as "LoRa".
    public let transportName = "LoRa"

    private let myId: Data
    private let meshQueue = DispatchQueue(label: "hop.mesh")
    private let radio: MeshtasticRadio

    private var myNodeNum: UInt32?
    private var linksByNode = [UInt32: MeshLink]()
    private var linksByLinkId = [LinkId: MeshLink]()
    private let reassembler = MeshReassembler()
    private var nextLinkId: LinkId = 1
    private var nextMsgId: UInt16 = 1
    private var nextPktId: UInt32 = 1
    private var stopped = false
    private var maintenanceTimer: DispatchSourceTimer?
    private var lastBeaconMs: UInt64 = 0
    private var configNonce: UInt32 = 1
    private var radioUp = false
    private var hopChannel: UInt32?
    private var sessionPasskey: [UInt8] = []
    private var channelProbe = 1
    private var sprays = [Spray]()
    private var seenMsgIds = [UInt32: [UInt16]]()

    private final class Spray {
        let dest: UInt32
        let msgId: UInt16
        let frame: [UInt8]
        var nextDueMs: UInt64
        var intervalMs: UInt64
        init(dest: UInt32, msgId: UInt16, frame: [UInt8], nextDueMs: UInt64, intervalMs: UInt64) {
            self.dest = dest; self.msgId = msgId; self.frame = frame
            self.nextDueMs = nextDueMs; self.intervalMs = intervalMs
        }
    }

    /// Production entry point: talk to a real Meshtastic radio over CoreBluetooth.
    public convenience init(myId: Data) {
        self.init(myId: myId, radio: CoreBluetoothMeshtasticRadio())
    }

    /// Test/injection entry point: drive the state machine against any `MeshtasticRadio`.
    init(myId: Data, radio: MeshtasticRadio) {
        self.myId = myId
        self.radio = radio
    }

    // MARK: - Bearer lifecycle

    public func start() {
        log("STATE", "mesh node-start myId=\(hex(myId)) port=\(MESH_HOP_PORTNUM)")
        meshQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            // Hop every radio callback onto meshQueue so the state machine stays single-threaded no matter
            // which thread the radio delivers on (CoreBluetooth uses its own dispatch queue).
            self.radio.onConnect = { [weak self] in self?.meshQueue.async { self?.onRadioConnected() } }
            self.radio.onDisconnect = { [weak self] in self?.meshQueue.async { self?.onRadioDisconnected() } }
            self.radio.onFromRadio = { [weak self] bytes in self?.meshQueue.async { self?.onFromRadio(bytes) } }
            self.startMaintenance()
            self.radio.start()
        }
    }

    public func stop() {
        meshQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.maintenanceTimer?.cancel(); self.maintenanceTimer = nil
            for link in Array(self.linksByNode.values) { self.teardown(link, why: "stop") }
            self.radio.stop()
        }
    }

    public func send(_ bytes: Data, on link: LinkId) {
        meshQueue.async { [weak self] in
            guard let self, let l = self.linksByLinkId[link] else { return }
            self.shipFrame(MeshFrame.data([UInt8](bytes)), to: l.nodeNum)
        }
    }

    // MARK: - Radio callbacks (all on meshQueue)

    private func onRadioConnected() {
        guard !stopped else { return }
        radioUp = true
        hopChannel = nil
        channelProbe = 1
        sessionPasskey = []
        log("STATE", "mesh radio-connected, requesting config")
        configNonce &+= 1
        radio.send(toRadio: MeshtasticProto.encodeWantConfig(configNonce))
        requestHopChannel()
    }

    private func onRadioDisconnected() {
        log("STATE", "mesh radio-disconnected, tearing down \(linksByNode.count) link(s)")
        radioUp = false
        hopChannel = nil
        channelProbe = 1
        sessionPasskey = []
        for link in Array(linksByNode.values) { teardown(link, why: "radio down") }
        myNodeNum = nil
    }

    private func onFromRadio(_ bytes: [UInt8]) {
        guard !stopped else { return }
        guard let inbound = MeshtasticProto.decodeFromRadio(bytes) else { return }
        switch inbound {
        case .myNodeNum(let num):
            if myNodeNum != num { log("STATE", "mesh my-node-num=\(num)") }
            myNodeNum = num
            requestHopChannel()
        case .admin(let payload):
            onAdmin(payload)
        case .routing(let requestId, let error):
            log("STATE", "mesh routing id=\(requestId) error=\(error)")
        case .hopData(let from, let payload):
            guard from != 0, from != myNodeNum else { return }
            guard let done = reassembler.accept(peer: from, fragment: payload, nowS: nowS()) else { return }
            handleFrame(from: from, msgId: done.msgId, body: done.body)
        }
    }

    private func requestHopChannel() {
        guard radioUp, myNodeNum != nil, hopChannel == nil else { return }
        sendAdmin(MeshtasticProto.encodeGetChannelRequest(index: channelProbe))
    }

    private func sendAdmin(_ admin: [UInt8]) {
        guard let me = myNodeNum else { return }
        let id = nextPktId; nextPktId = nextPktId &+ 1
        radio.send(toRadio: MeshtasticProto.encodeAdminToRadio(to: me, id: id, admin: admin))
    }

    private func onAdmin(_ payload: [UInt8]) {
        guard let inbound = MeshtasticProto.decodeAdminMessage(payload) else { return }
        if !inbound.passkey.isEmpty { sessionPasskey = inbound.passkey }
        guard let ch = inbound.channel, hopChannel == nil else { return }
        if ch.isHop {
            armHopChannel(ch.index)
        } else if ch.isFree {
            sendAdmin(MeshtasticProto.encodeSetHopChannel(passkey: sessionPasskey, index: ch.index))
            armHopChannel(ch.index)
        } else {
            let next = ch.index + 1
            if next < MESH_MAX_CHANNELS {
                channelProbe = next
                sendAdmin(MeshtasticProto.encodeGetChannelRequest(index: next))
            } else {
                log("WARN", "mesh no secondary slot for Hop")
            }
        }
    }

    private func armHopChannel(_ index: Int) {
        hopChannel = UInt32(index)
        log("STATE", "mesh hop-channel=\(index)")
        broadcastHello()
    }

    // MARK: - Hop link-frame handling

    private func handleFrame(from node: UInt32, msgId: UInt16, body: [UInt8]) {
        guard let type = body.first else { return }
        if let l = linksByNode[node] { l.lastRxMs = nowMs() }
        switch type {
        case M_ACK:
            guard let id = MeshFrame.ackMsgId(body) else { return }
            sprays.removeAll { $0.dest == node && $0.msgId == id }
        case M_HELLO:
            sendAck(to: node, msgId: msgId)
            if alreadySeen(peer: node, msgId: msgId) { return }
            guard let peerId = MeshFrame.helloPeerId(body) else { return }
            onHello(node: node, peerId: peerId)
        case M_PING:
            let echo = Array(body[1..<min(17, body.count)])
            shipFrame(MeshFrame.pong(echo: echo), to: node)
        case M_PONG:
            break
        case M_DATA:
            sendAck(to: node, msgId: msgId)
            if alreadySeen(peer: node, msgId: msgId) { return }
            guard let l = linksByNode[node], l.up else { return }
            sink?.linkBytes(l.linkId, Data(body.dropFirst()))
        default:
            break
        }
    }

    private func alreadySeen(peer: UInt32, msgId: UInt16) -> Bool {
        var q = seenMsgIds[peer] ?? []
        if q.contains(msgId) { return true }
        q.append(msgId)
        while q.count > 32 { q.removeFirst() }
        seenMsgIds[peer] = q
        return false
    }

    private func sendAck(to node: UInt32, msgId: UInt16) {
        emitFrame(MeshFrame.ack(msgId: msgId), to: node, msgId: mintFragMsgId(), wantAck: false)
    }

    private func onHello(node: UInt32, peerId: Data) {
        if peerId == myId { return }
        if let existing = linksByNode[node] {
            existing.peerId = peerId
            existing.lastRxMs = nowMs()
            return
        }
        let isGreater = meshKeepGreaterLeg(myId: myId, peer: peerId)
        let link = MeshLink(linkId: mint(), nodeNum: node, peerId: peerId, isGreater: isGreater, nowMs: nowMs())
        link.up = true
        linksByNode[node] = link
        linksByLinkId[link.linkId] = link
        link.surfaced = true
        log("STATE", "mesh hello-recv peer=\(link.peerShort) node=\(node) greater=\(isGreater)")
        shipFrame(MeshFrame.hello(myId: myId, isGreater: isGreater), to: node)
        sink?.linkUp(link.linkId, role: link.role, peerId: peerId)
    }

    // MARK: - Outbound

    private func mintFragMsgId() -> UInt16 {
        let id = nextMsgId
        nextMsgId = nextMsgId &+ 1
        return id
    }

    private func shipFrame(_ frame: [UInt8], to dest: UInt32) {
        let kind = frame.first ?? 0
        let reliable = dest != MESH_BROADCAST_ADDR && (kind == M_DATA || kind == M_HELLO)
        let msgId = mintFragMsgId()
        emitFrame(frame, to: dest, msgId: msgId, wantAck: reliable)
        if reliable { enqueueSpray(dest: dest, msgId: msgId, frame: frame, now: nowMs()) }
    }

    private func emitFrame(_ frame: [UInt8], to dest: UInt32, msgId: UInt16, wantAck: Bool) {
        guard let ch = hopChannel else { return }
        guard let frags = meshFragment(frame, msgId: msgId) else {
            log("WARN", "mesh frame too large to fragment (\(frame.count) bytes)")
            return
        }
        for frag in frags {
            let id = nextPktId; nextPktId = nextPktId &+ 1
            let radioFrame = MeshtasticProto.encodeToRadioPacket(
                from: 0, to: dest, id: id, hopLimit: 3, fragment: frag, channel: ch, wantAck: wantAck)
            radio.send(toRadio: radioFrame)
        }
    }

    private func enqueueSpray(dest: UInt32, msgId: UInt16, frame: [UInt8], now: UInt64) {
        if sprays.filter({ $0.dest == dest }).count >= MESH_SPRAY_MAX_OUTSTANDING {
            if let i = sprays.firstIndex(where: { $0.dest == dest }) { sprays.remove(at: i) }
        }
        let initial = UInt64(MESH_SPRAY_INITIAL_S * 1000)
        sprays.append(Spray(dest: dest, msgId: msgId, frame: frame, nextDueMs: now + initial, intervalMs: initial))
    }

    private func broadcastHello() {
        guard hopChannel != nil else { return }
        shipFrame(MeshFrame.hello(myId: myId, isGreater: false), to: MESH_BROADCAST_ADDR)
        lastBeaconMs = nowMs()
    }

    // MARK: - Maintenance (beacon, spray, per-link keepalive, dead reap)

    private func startMaintenance() {
        guard maintenanceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: meshQueue)
        timer.schedule(deadline: .now() + MESH_SPRAY_TICK_S, repeating: MESH_SPRAY_TICK_S)
        timer.setEventHandler { [weak self] in self?.runMaintenance(nowMs()) }
        maintenanceTimer = timer
        timer.resume()
    }

    private func runMaintenance(_ now: UInt64) {
        guard !stopped else { return }
        reassembler.evictStale(nowS: Double(now) / 1000)
        if Double(now - lastBeaconMs) / 1000 >= MESH_PING_S { broadcastHello() }
        let capMs = UInt64(MESH_SPRAY_CAP_S * 1000)
        for s in sprays {
            if now < s.nextDueMs { continue }
            emitFrame(s.frame, to: s.dest, msgId: s.msgId, wantAck: true)
            s.intervalMs = min(s.intervalMs &* UInt64(MESH_SPRAY_MULTIPLIER), capMs)
            s.nextDueMs = now + s.intervalMs
        }
        for link in Array(linksByNode.values) {
            if Double(now - link.lastRxMs) / 1000 > MESH_DEAD_S { teardown(link, why: "liveness DEAD"); continue }
            if Double(now - link.lastPingMs) / 1000 >= MESH_PING_S {
                link.lastPingMs = now
                link.txSeq &+= 1
                shipFrame(MeshFrame.ping(seq: link.txSeq, nowMs: now), to: link.nodeNum)
            }
        }
    }

    // MARK: - Teardown

    private func teardown(_ link: MeshLink, why: String) {
        linksByNode.removeValue(forKey: link.nodeNum)
        linksByLinkId.removeValue(forKey: link.linkId)
        reassembler.forget(peer: link.nodeNum)
        sprays.removeAll { $0.dest == link.nodeNum }
        seenMsgIds.removeValue(forKey: link.nodeNum)
        log("STATE", "mesh link-down (\(why)) peer=\(link.peerShort) node=\(link.nodeNum)")
        if link.surfaced { sink?.linkDown(link.linkId) }
    }

    private func mint() -> LinkId { let id = nextLinkId; nextLinkId += 1; return id }
}

#if DEBUG
// Test-only seams (DEBUG-only). They call the REAL production paths on `meshQueue` so the integration
// tests drive linkUp/linkBytes/linkDown, fragmentation/reassembly, keepalive and reap with a fake radio
// and an injected clock, with no CoreBluetooth and no Meshtastic hardware. They add NO new behavior.
extension MeshtasticBearer {
    /// Run one maintenance pass at an injected wall clock (ms), exactly as the timer handler would.
    func testRunMaintenance(atMs: UInt64) { meshQueue.sync { self.runMaintenance(atMs) } }

    /// The peer node num of the link the manager assigned `linkId`, or nil.
    func testNodeNum(for linkId: LinkId) -> UInt32? { meshQueue.sync { self.linksByLinkId[linkId]?.nodeNum } }

    var testLinkCount: Int { meshQueue.sync { self.linksByNode.count } }
    var testMyNodeNum: UInt32? { meshQueue.sync { self.myNodeNum } }
}
#endif
