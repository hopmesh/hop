// Bearers — the transport-side kit that ships WITH the Hop SDK so a bearer package depends on nothing
// but `Hop`. It defines the in-process bearer contract (Bearer/LinkSink), the registry/multiplexer
// (BearerManager), and the runtime that binds them to a HopNode (the C ABI). The CROSS-LANGUAGE
// contract is hop.h; this is the small Swift kit that drives it. No transport types appear here —
// a bearer (BLE/LAN/Multipeer/Relay) lives in its own package and only conforms to `Bearer`.

import Foundation

/// A transport link identifier, unique per (re)connection within a Bearer.
public typealias LinkId = UInt64

/// What a Bearer reports to its consumer (the BearerManager). The only seam between a transport and
/// the node multiplexer — names nothing about BLE/Wi-Fi/sockets.
public protocol LinkSink: AnyObject {
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data)
    func linkBytes(_ link: LinkId, _ bytes: Data)
    func linkDown(_ link: LinkId)
}

/// A transport that discovers peers, forms links, and shuttles application bytes. Implement this in a
/// bearer package and register it with a BearerManager. The bearer owns liveness + one-pipe-per-peer
/// dedup internally; the consumer only sees up / bytes / down and calls `send`.
public protocol Bearer: AnyObject {
    var sink: LinkSink? { get set }
    var transportName: String { get }   // short UI tag ("BT"/"LAN"/"P2P"/"Relay"); cosmetic
    func start()
    func stop()
    func send(_ bytes: Data, on link: LinkId)
}

/// The registry + multiplexer. Register bearers, set `sink`, drive everything as one `Bearer`. Mints a
/// process-global LinkId per link and translates each bearer's local id into it, so the consumer keys
/// all state on ONE id space regardless of which radio a link rode in on. (Ported from the proven
/// HopBearerCore registry — same logic, the SDK's HopRole.)
public final class BearerManager: Bearer {
    public weak var sink: LinkSink?
    public let transportName = "Mesh"

    private let lock = NSLock()
    private var bearers: [Bearer] = []
    private var lanes: [Lane] = []
    private var nextGlobal: LinkId = 1
    private var toGlobal: [ObjectIdentifier: [LinkId: LinkId]] = [:]
    private var fromGlobal: [LinkId: (Bearer, LinkId)] = [:]

    public init(baseLinkId: LinkId = 1) { self.nextGlobal = baseLinkId }

    public func register(_ bearer: Bearer) {
        let lane = Lane(manager: self, bearer: bearer)
        bearer.sink = lane
        lock.lock(); lanes.append(lane); bearers.append(bearer); lock.unlock()
    }

    public func start() { snapshotBearers().forEach { $0.start() } }
    public func stop() { snapshotBearers().forEach { $0.stop() } }

    public func send(_ bytes: Data, on link: LinkId) {
        lock.lock(); let route = fromGlobal[link]; lock.unlock()
        guard let (bearer, local) = route else { return }
        bearer.send(bytes, on: local)
    }

    private func snapshotBearers() -> [Bearer] { lock.lock(); defer { lock.unlock() }; return bearers }

    /// The transport tag of the bearer owning `link` (for the consumer's per-peer UI), or nil.
    public func transportName(of link: LinkId) -> String? {
        lock.lock(); let route = fromGlobal[link]; lock.unlock()
        return route?.0.transportName
    }

    public func activeTransports() -> [String: Int] {
        lock.lock(); let routes = Array(fromGlobal.values); lock.unlock()
        var out: [String: Int] = [:]
        for (bearer, _) in routes { out[bearer.transportName, default: 0] += 1 }
        return out
    }

    fileprivate func up(_ bearer: Bearer, _ local: LinkId, _ role: HopRole, _ peerId: Data) {
        lock.lock()
        let g = nextGlobal; nextGlobal += 1
        toGlobal[ObjectIdentifier(bearer), default: [:]][local] = g
        fromGlobal[g] = (bearer, local)
        lock.unlock()
        sink?.linkUp(g, role: role, peerId: peerId)
    }

    fileprivate func bytes(_ bearer: Bearer, _ local: LinkId, _ data: Data) {
        lock.lock(); let g = toGlobal[ObjectIdentifier(bearer)]?[local]; lock.unlock()
        guard let g else { return }
        sink?.linkBytes(g, data)
    }

    fileprivate func down(_ bearer: Bearer, _ local: LinkId) {
        let oid = ObjectIdentifier(bearer)
        lock.lock()
        let g = toGlobal[oid]?[local]
        if let g { toGlobal[oid]?[local] = nil; fromGlobal[g] = nil }
        lock.unlock()
        guard let g else { return }
        sink?.linkDown(g)
    }
}

private final class Lane: LinkSink {
    unowned let manager: BearerManager
    unowned let bearer: Bearer
    init(manager: BearerManager, bearer: Bearer) { self.manager = manager; self.bearer = bearer }
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { manager.up(bearer, link, role, peerId) }
    func linkBytes(_ link: LinkId, _ bytes: Data) { manager.bytes(bearer, link, bytes) }
    func linkDown(_ link: LinkId) { manager.down(bearer, link) }
}
