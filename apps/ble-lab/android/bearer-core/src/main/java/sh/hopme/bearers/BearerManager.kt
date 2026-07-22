package sh.hopme.bearers

// BearerManager, the bearer registry, the Android mirror of apple/HopBearers' BearerManager.swift.
// The consumer registers one or more Bearers (BLE first; LAN / Wi-Fi Direct / relay later) and then
// talks ONLY to the manager. The manager is ITSELF a Bearer, so the consumer drives the whole
// transport layer through the same interface it would use for a single bearer:
//
//     val mgr = BearerManager()
//     mgr.register(BleBearer(ctx, myId))
//     mgr.sink = myConsumer        // links from ALL bearers surface here
//     mgr.start()                  // fans out to every registered bearer
//
// Two jobs, purely in terms of Bearer/LinkSink, NO BLE/Wi-Fi/socket types ever cross this boundary:
//   1. Fan-out: start()/stop() reach every bearer; send() routes to the bearer owning the link.
//   2. One link-id space: each bearer mints its own (local) LinkIds from 1, so two bearers would
//      collide. The manager mints a process-global LinkId per link and translates each bearer's local
//      id into that global space, so the consumer keys all state on ONE id space regardless of radio.
//
// THREADING (the key Android difference from Apple): Apple's manager runs on a single run loop, so its
// maps need no locks. Here the lane callbacks arrive from MULTIPLE bearer threads (BleBearer surfaces
// linkUp/linkBytes/linkDown from per-link l2cap-rx threads, the main Handler, and the accept thread).
// So every routing-map mutation/read is guarded by a single `lock`.

import java.util.concurrent.CopyOnWriteArrayList

/// The registry + multiplexer. Register bearers, set `sink`, then drive everything as one Bearer.
// `baseLinkId` offsets this manager's global link-id space. A host that mints link ids for OTHER
// transports outside the manager (the production node's relay/Multipeer links share one nextLinkId
// counter) passes a high base so manager ids can never collide. Default 1 (standalone / clean-room).
class BearerManager(baseLinkId: LinkId = 1) : Bearer {
    /// The consumer's sink: every link, from every registered bearer, surfaces here in ONE global
    /// LinkId space.
    override var sink: LinkSink? = null

    /// Bearer contract. The manager aggregates many transports, so it has no single tag of its own; this
    /// is only read if a manager were nested inside another (it isn't). Per-link tags come from
    /// `transportNameOf(link)`, which reports the OWNING bearer's tag.
    override val transportName = "Mesh"

    private val lock = Any()
    private val bearers = CopyOnWriteArrayList<Bearer>() // iterated lock-free by start()/stop()
    private val lanes = CopyOnWriteArrayList<Lane>()     // keep per-bearer shims alive
    private var nextGlobal: LinkId = baseLinkId          // global link-id space (distinct from any bearer's)
    private val fromGlobal = HashMap<LinkId, Pair<Bearer, LinkId>>() // global -> (owning bearer, local)

    /// Register a bearer. The manager installs itself as the bearer's sink (via a private per-bearer
    /// lane that tags + translates the bearer's link ids). Call before `start()`.
    fun register(bearer: Bearer) {
        val lane = Lane(bearer)
        bearer.sink = lane
        lanes.add(lane)
        bearers.add(bearer)
    }

    // ---- Bearer: the uniform interface the consumer drives (fans out to every registered bearer) ----

    override fun start() = bearers.forEach { it.start() }
    override fun stop() = bearers.forEach { it.stop() }

    override fun send(bytes: ByteArray, link: LinkId) {
        val target = synchronized(lock) { fromGlobal[link] } ?: return // unknown / already-closed global link
        target.first.send(bytes, target.second)
    }

    // ---- transport labelling, the consumer's UI tags each shared-bearer link by its REAL transport ----

    /// The short transport tag (e.g. "BT"/"LAN"/"Wi-Fi Direct"/"Relay") of the bearer owning `link`, or
    /// null if the link is unknown / already closed. Cosmetic only, used to label a shared-bearer peer.
    /// (Named `…Of` rather than `transportName(link)` to avoid colliding with the Bearer `transportName`
    /// property above; Kotlin can't disambiguate a same-named property and function at a call site.)
    fun transportNameOf(link: LinkId): String? =
        synchronized(lock) { fromGlobal[link] }?.first?.transportName

    /// Every currently-up global link grouped by its owning bearer's transport tag → count. The consumer
    /// builds its per-transport status list from this when shared bearers are on.
    fun activeTransports(): Map<String, Int> {
        val routes = synchronized(lock) { fromGlobal.values.toList() }
        val out = HashMap<String, Int>()
        for ((bearer, _) in routes) out[bearer.transportName] = (out[bearer.transportName] ?: 0) + 1
        return out
    }

    // ---- lane callbacks, bearer-local link ids in, global link ids out ----

    private fun up(lane: Lane, local: LinkId, role: LinkRole, peerId: ByteArray) {
        val g: LinkId
        synchronized(lock) {
            g = nextGlobal; nextGlobal += 1
            lane.toGlobal[local] = g
            fromGlobal[g] = Pair(lane.bearer, local)
        }
        sink?.linkUp(g, role, peerId)
    }

    private fun bytes(lane: Lane, local: LinkId, data: ByteArray) {
        val g = synchronized(lock) { lane.toGlobal[local] } ?: return
        sink?.linkBytes(g, data)
    }

    private fun down(lane: Lane, local: LinkId) {
        var g: LinkId? = null
        synchronized(lock) {
            lane.toGlobal[local]?.let { gg ->
                lane.toGlobal.remove(local)
                fromGlobal.remove(gg)
                g = gg
            }
        }
        g?.let { sink?.linkDown(it) }
    }

    /// One per registered bearer: the LinkSink a bearer reports to. It tags each callback with its
    /// owning bearer (and owns that bearer's local->global map) and forwards to the manager, which does
    /// the translation. Mirrors Apple's `Lane`.
    private inner class Lane(val bearer: Bearer) : LinkSink {
        val toGlobal = HashMap<LinkId, LinkId>() // localLink -> globalLink (guarded by manager.lock)
        override fun linkUp(link: LinkId, role: LinkRole, peerId: ByteArray) = up(this, link, role, peerId)
        override fun linkBytes(link: LinkId, bytes: ByteArray) = bytes(this, link, bytes)
        override fun linkDown(link: LinkId) = down(this, link)
    }
}
