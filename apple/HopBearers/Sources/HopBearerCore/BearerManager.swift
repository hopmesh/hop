// BearerManager — the bearer registry. The consumer registers one or more `Bearer`s (BLE first; LAN /
// Wi-Fi Direct / relay / a third-party transport later) and then talks ONLY to the manager. The
// manager is ITSELF a `Bearer`, so the consumer drives the whole transport layer through the exact
// same interface it would use for a single bearer:
//
//     let mgr = BearerManager()
//     mgr.register(BleBearer(myId: myId))
//     mgr.register(LanBearer(...))        // any future Bearer registers identically
//     mgr.sink = myConsumer               // links from ALL bearers surface here
//     mgr.start()                         // fans out to every registered bearer
//
// Two jobs, both purely in terms of the `Bearer`/`LinkSink` contract — NO BLE/Wi-Fi/socket types ever
// cross this boundary:
//   1. Fan-out: start()/stop() reach every bearer; send(_:on:) routes to the bearer owning the link.
//   2. One link-id space: each bearer mints its own (local) LinkIds starting from 1, so two bearers
//      would otherwise collide. The manager mints a process-global LinkId per link and translates each
//      bearer's local id into that global space, so the consumer keys all its state on ONE id space
//      regardless of which radio a link rode in on.
//
// Anyone writing a new transport implements `Bearer` and registers it — nothing here knows or cares
// what it is. That is the whole point: the interface is the same no matter the bearer.

import Foundation

/// The registry + multiplexer. Register bearers, set `sink`, then drive everything as one `Bearer`.
///
/// Threading: the manager's routing maps are mutated from the lane callbacks (which arrive on each
/// bearer's work queue) and read in `send`. Today every bearer shares the one `bleRunLoop`/`.main`
/// serial context (CLI) or the production consumer's single core queue (Stage C), so these are already
/// serialized by the host's threading model — the same single-threaded invariant `BleBearer` itself
/// relies on. A future bearer on an independent queue would need this funneled through a serial queue.
public final class BearerManager: Bearer {
    /// The consumer's sink — every link, from every registered bearer, surfaces here in ONE global
    /// LinkId space. Weak: the consumer typically owns the manager, so a strong ref would cycle.
    public weak var sink: LinkSink?

    // THREADING: each bearer runs on its OWN queue (the BLE bearer's run loop, the LAN bearer's serial
    // queue, …) and the consumer pings from yet another, so the routing maps are touched concurrently.
    // A lock guards every map access; sink callbacks are always invoked OUTSIDE the lock (so a consumer
    // that calls back into `send` from linkUp/linkBytes can't deadlock).
    private let lock = NSLock()
    private var bearers: [Bearer] = []
    private var lanes: [Lane] = []                                    // keep per-bearer shims alive (bearer.sink is weak)
    private var nextGlobal: LinkId = 1                                // global link-id space (distinct from any bearer's)
    private var toGlobal: [ObjectIdentifier: [LinkId: LinkId]] = [:]  // bearer -> (localLink -> globalLink)
    private var fromGlobal: [LinkId: (Bearer, LinkId)] = [:]          // globalLink -> (owning bearer, localLink)

    public init() {}

    /// Register a bearer. The manager installs itself as the bearer's sink (via a private per-bearer
    /// lane that tags + translates the bearer's link ids), so from here on the bearer's links flow up
    /// through the manager. Call before `start()`.
    public func register(_ bearer: Bearer) {
        let lane = Lane(manager: self, bearer: bearer)
        bearer.sink = lane                                           // bearer holds this weakly...
        lock.lock(); lanes.append(lane); bearers.append(bearer); lock.unlock()  // ...manager keeps it alive
    }

    // MARK: Bearer — the uniform interface the consumer drives (fans out to every registered bearer)

    public func start() { snapshotBearers().forEach { $0.start() } }
    public func stop()  { snapshotBearers().forEach { $0.stop() } }

    public func send(_ bytes: Data, on link: LinkId) {
        lock.lock(); let route = fromGlobal[link]; lock.unlock()
        guard let (bearer, local) = route else { return }            // unknown / already-closed global link
        bearer.send(bytes, on: local)
    }

    private func snapshotBearers() -> [Bearer] { lock.lock(); defer { lock.unlock() }; return bearers }

    // MARK: lane callbacks — bearer-local link ids in, global link ids out (map work locked, sink unlocked)

    fileprivate func up(_ bearer: Bearer, _ local: LinkId, _ role: LinkRole, _ peerId: Data) {
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

/// One per registered bearer: the `LinkSink` a bearer reports to. It tags each callback with its owning
/// bearer and forwards to the manager, which does the local→global LinkId translation. Holds the
/// manager + bearer `unowned` — the manager owns both this lane and the bearer, so neither outlives it.
private final class Lane: LinkSink {
    unowned let manager: BearerManager
    unowned let bearer: Bearer
    init(manager: BearerManager, bearer: Bearer) { self.manager = manager; self.bearer = bearer }
    func linkUp(_ link: LinkId, role: LinkRole, peerId: Data) { manager.up(bearer, link, role, peerId) }
    func linkBytes(_ link: LinkId, _ bytes: Data) { manager.bytes(bearer, link, bytes) }
    func linkDown(_ link: LinkId) { manager.down(bearer, link) }
}
