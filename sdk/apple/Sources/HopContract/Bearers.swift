// Bearers, the transport-side kit that ships WITH the Hop SDK so a bearer package depends on nothing
// but `Hop`. It defines the in-process bearer contract (Bearer/LinkSink), the registry/multiplexer
// (BearerManager), and the runtime that binds them to a HopNode (the C ABI). The CROSS-LANGUAGE
// contract is hop.h; this is the small Swift kit that drives it. No transport types appear here;
// a bearer (BLE/LAN/Multipeer/Relay) lives in its own package and only conforms to `Bearer`.

import Foundation

/// A transport link identifier, unique per (re)connection within a Bearer.
public typealias LinkId = UInt64

/// What a Bearer reports to its consumer (the BearerManager). The only seam between a transport and
/// the node multiplexer; it names nothing about BLE/Wi-Fi/sockets.
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
/// HopBearerCore registry: same logic, with the SDK's HopRole.)
public final class BearerManager: Bearer {
    public weak var sink: LinkSink?
    public let transportName = "Mesh"

    private let lock = NSLock()
    private var bearers: [Bearer] = []
    private var lanes: [Lane] = []
    private var nextGlobal: LinkId = 1
    private var toGlobal: [ObjectIdentifier: [LinkId: LinkId]] = [:]
    private var fromGlobal: [LinkId: (Bearer, LinkId)] = [:]
    /// Per-bearer enablement, keyed by `ObjectIdentifier`. Absent means enabled: a bearer is live the
    /// moment it registers, so adding this could not change existing behaviour.
    private var disabled: Set<ObjectIdentifier> = []
    private var started = false

    public init(baseLinkId: LinkId = 1) { self.nextGlobal = baseLinkId }

    public func register(_ bearer: Bearer) {
        let lane = Lane(manager: self, bearer: bearer)
        bearer.sink = lane
        lock.lock(); lanes.append(lane); bearers.append(bearer); lock.unlock()
    }

    // MARK: - Per-transport enablement
    //
    // Not every integrator wants every radio. A product may ship BLE-only, or let the user turn the
    // relay off to keep traffic off the internet, and that decision has to be revocable at RUNTIME:
    // choosing at registration time would mean an app restart to change your mind.
    //
    // `transportName` is the handle, because it is the identity the consumer already sees (per-peer
    // `xport=` tags, `activeTransports()`) and the only bearer property meaningful outside this file.
    // That promotes it from "cosmetic" to an identifier, so registering two bearers under one name
    // makes them a single addressable group; `setEnabled` deliberately applies to all of them rather
    // than picking one arbitrarily.

    /// Enable or disable every registered bearer whose `transportName` matches, and return whether
    /// anything matched. Idempotent.
    ///
    /// Disabling STOPS the bearer *and tears down its live links*. Stopping alone would leave the
    /// consumer holding links that can never carry bytes again, which is strictly worse than a
    /// closed link: the node would keep choosing a dead path instead of re-offering over another
    /// one. Enabling starts it if the manager itself is started, otherwise it goes live on `start()`.
    @discardableResult
    public func setEnabled(_ transportName: String, _ enabled: Bool) -> Bool {
        lock.lock()
        let matches = bearers.filter { $0.transportName == transportName }
        let isStarted = started
        var toStart: [Bearer] = [], toStop: [Bearer] = []
        for b in matches {
            let oid = ObjectIdentifier(b)
            let wasEnabled = !disabled.contains(oid)
            guard wasEnabled != enabled else { continue }   // idempotent
            if enabled { disabled.remove(oid); if isStarted { toStart.append(b) } }
            else { disabled.insert(oid); toStop.append(b) }
        }
        lock.unlock()
        // Outside the lock: a bearer's start/stop touches radios and can block.
        for b in toStop { stopAndTearDown(b) }
        for b in toStart { do_start(b) }
        return !matches.isEmpty
    }

    /// Is any bearer with this `transportName` enabled? False for an unknown name.
    public func isEnabled(_ transportName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return bearers.contains { $0.transportName == transportName && !disabled.contains(ObjectIdentifier($0)) }
    }

    /// Every registered transport name mapped to its enablement, for a settings UI.
    public func bearerStates() -> [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Bool] = [:]
        for b in bearers {
            let on = !disabled.contains(ObjectIdentifier(b))
            out[b.transportName] = (out[b.transportName] ?? false) || on
        }
        return out
    }

    /// Stop a bearer and synthesize `linkDown` for every link it still owned, so the consumer's link
    /// table cannot outlive the transport carrying it.
    private func stopAndTearDown(_ bearer: Bearer) {
        do_stop(bearer)
        let oid = ObjectIdentifier(bearer)
        lock.lock()
        let orphans = toGlobal[oid]?.values.sorted() ?? []
        toGlobal[oid] = nil
        for g in orphans { fromGlobal[g] = nil }
        lock.unlock()
        for g in orphans { sink?.linkDown(g) }
    }

    /// Start only the ENABLED bearers. A disabled transport must stay down across a stop/start cycle,
    /// otherwise the setting silently reverts the next time the host restarts the mesh.
    public func start() {
        lock.lock(); started = true; let live = bearers.filter { !disabled.contains(ObjectIdentifier($0)) }; lock.unlock()
        live.forEach { do_start($0) }
    }

    /// Stop everything, including disabled bearers (already stopped, and `stop()` is idempotent per
    /// bearer). Enablement is preserved, so a later `start()` honours it.
    public func stop() {
        lock.lock(); started = false; lock.unlock()
        snapshotBearers().forEach { do_stop($0) }
    }

    // `Bearer.start()`/`stop()` are non-throwing in Swift (unlike the Kotlin kit, where F-10 wraps
    // them), so these are plain forwards. They exist so enablement has ONE call site per direction.
    private func do_start(_ b: Bearer) { b.start() }
    private func do_stop(_ b: Bearer) { b.stop() }

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
