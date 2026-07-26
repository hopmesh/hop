// Bearers, the Kotlin transport kit, shipped WITH the Hop SDK (parity with the Swift Bearers.swift)
// so an Android bearer module depends on nothing but this SDK. Defines the in-process bearer contract
// (Bearer/LinkSink), the registry/multiplexer (BearerManager, one global LinkId space), and the
// runtime that binds them to a HopNode (the C ABI). Pure Kotlin, no Android types, an Android
// transport (BLE/LAN/Wi-Fi Direct/Relay) lives in its own module and only implements `Bearer`.

package sh.hop

/** A transport link identifier, unique per (re)connection within a Bearer (the Swift SDK: `UInt64`). */
typealias LinkId = Long

/** What a Bearer reports to the BearerManager. The only seam between a transport and the node mux. */
interface LinkSink {
    fun linkUp(link: Long, role: HopRole, peerId: ByteArray)
    fun linkBytes(link: Long, bytes: ByteArray)
    fun linkDown(link: Long)
}

/** A transport that forms links and shuttles bytes. Implement in a bearer module, register with a
 *  BearerManager. The bearer owns liveness + one-pipe-per-peer dedup; the consumer sees up/bytes/down. */
interface Bearer {
    var sink: LinkSink?
    val transportName: String      // short UI tag ("BT"/"LAN"/"P2P"/"Relay")
    fun start()
    fun stop()
    fun send(bytes: ByteArray, link: Long)
}

/** Registry + multiplexer. Mints a process-global LinkId per link and translates each bearer's local
 *  id into it, so the consumer keys all state on ONE id space regardless of radio. */
class BearerManager(baseLinkId: Long = 1) : Bearer {
    override var sink: LinkSink? = null
    override val transportName = "Mesh"

    private val lock = Any()
    private val bearers = ArrayList<Bearer>()
    private val lanes = ArrayList<Lane>()
    private var nextGlobal = baseLinkId
    private val toGlobal = HashMap<Bearer, HashMap<Long, Long>>()
    private val fromGlobal = HashMap<Long, Pair<Bearer, Long>>()
    /** Disabled bearers by identity. ABSENT MEANS ENABLED, so a bearer is live the moment it
     *  registers and adding this could not change existing behaviour. */
    private val disabled = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Bearer, Boolean>())
    private var started = false

    fun register(bearer: Bearer) {
        val lane = Lane(this, bearer)
        bearer.sink = lane
        synchronized(lock) { lanes.add(lane); bearers.add(bearer) }
    }

    // Per-transport enablement -------------------------------------------------------------------
    //
    // Not every integrator wants every radio. A product may ship BLE-only, or let the user turn the
    // relay off to keep traffic off the internet, and that has to be revocable at RUNTIME: deciding
    // at registration time would mean an app restart to change your mind.
    //
    // `transportName` is the handle, because it is the identity the consumer already sees (the
    // per-peer `xport=` tag, `transportNameOf`) and the only bearer property meaningful outside this
    // file. That promotes it from "cosmetic" to an identifier, so two bearers sharing a name are one
    // addressable group and `setEnabled` applies to all of them rather than picking one arbitrarily.

    /** Enable/disable every registered bearer with this [transportName]; returns whether any matched.
     *  Idempotent.
     *
     *  Disabling STOPS the bearer *and tears down its live links*. Stopping alone would leave the
     *  consumer holding links that can never carry bytes again, which is worse than a closed link:
     *  the node would keep choosing a dead path instead of re-offering over another one. Enabling
     *  starts it if the manager is started, otherwise it goes live on the next [start]. */
    fun setEnabled(transportName: String, enabled: Boolean): Boolean {
        val toStart = ArrayList<Bearer>(); val toStop = ArrayList<Bearer>()
        val matched: Boolean
        synchronized(lock) {
            val matches = bearers.filter { it.transportName == transportName }
            matched = matches.isNotEmpty()
            for (b in matches) {
                val wasEnabled = !disabled.contains(b)
                if (wasEnabled == enabled) continue          // idempotent
                if (enabled) { disabled.remove(b); if (started) toStart.add(b) } else { disabled.add(b); toStop.add(b) }
            }
        }
        // Outside the lock: a bearer's start/stop touches radios and can block.
        toStop.forEach { stopAndTearDown(it) }
        toStart.forEach { doStart(it) }
        return matched
    }

    /** Is any bearer with this [transportName] enabled? False for an unknown name. */
    fun isEnabled(transportName: String): Boolean = synchronized(lock) {
        bearers.any { it.transportName == transportName && !disabled.contains(it) }
    }

    /** Every registered transport name mapped to its enablement, for a settings UI. */
    fun bearerStates(): Map<String, Boolean> = synchronized(lock) {
        val out = LinkedHashMap<String, Boolean>()
        for (b in bearers) out[b.transportName] = (out[b.transportName] ?: false) || !disabled.contains(b)
        out
    }

    /** Stop a bearer and synthesize `linkDown` for every link it still owned, so the consumer's link
     *  table cannot outlive the transport carrying it. */
    private fun stopAndTearDown(bearer: Bearer) {
        doStop(bearer)
        val orphans = synchronized(lock) {
            val gs = toGlobal.remove(bearer)?.values?.sorted() ?: emptyList()
            gs.forEach { fromGlobal.remove(it) }
            gs
        }
        orphans.forEach { sink?.linkDown(it) }
    }

    /** Start only the ENABLED bearers. A disabled transport must stay down across a stop/start cycle,
     *  or the setting silently reverts the next time the host restarts the mesh. */
    override fun start() {
        val live = synchronized(lock) { started = true; bearers.filter { !disabled.contains(it) } }
        live.forEach { doStart(it) }
    }

    /** Stop everything, including disabled bearers (already stopped, and per-bearer stop is
     *  idempotent). Enablement is preserved so a later [start] honours it. */
    override fun stop() {
        synchronized(lock) { started = false }
        snapshot().forEach { doStop(it) }
    }

    // F-10: isolate each bearer's start/stop so one throwing (e.g. BLE listen failing when Bluetooth
    // is off at launch) can't abort the others (LAN + relay) or crash the caller's thread.
    private fun doStart(b: Bearer) {
        try { b.start() } catch (e: Throwable) { System.err.println("bearer start failed: ${e.message}") }
    }
    private fun doStop(b: Bearer) {
        try { b.stop() } catch (e: Throwable) { System.err.println("bearer stop failed: ${e.message}") }
    }

    override fun send(bytes: ByteArray, link: Long) {
        val route = synchronized(lock) { fromGlobal[link] } ?: return
        route.first.send(bytes, route.second)
    }

    private fun snapshot(): List<Bearer> = synchronized(lock) { ArrayList(bearers) }

    fun transportNameOf(link: LinkId): String? = synchronized(lock) { fromGlobal[link] }?.first?.transportName

    /** Live link count per transport name (the twin of Swift's `activeTransports()`). Counts the
     *  MANAGER's links, so it includes a transport-level link the node has not yet handshaked. */
    fun activeTransports(): Map<String, Int> = synchronized(lock) {
        val out = HashMap<String, Int>()
        for ((bearer, _) in fromGlobal.values) out[bearer.transportName] = (out[bearer.transportName] ?: 0) + 1
        out
    }

    internal fun up(bearer: Bearer, local: Long, role: HopRole, peerId: ByteArray) {
        val g: Long
        synchronized(lock) {
            g = nextGlobal++
            toGlobal.getOrPut(bearer) { HashMap() }[local] = g
            fromGlobal[g] = bearer to local
        }
        sink?.linkUp(g, role, peerId)
    }

    internal fun bytes(bearer: Bearer, local: Long, data: ByteArray) {
        val g = synchronized(lock) { toGlobal[bearer]?.get(local) } ?: return
        sink?.linkBytes(g, data)
    }

    internal fun down(bearer: Bearer, local: Long) {
        val g = synchronized(lock) {
            val g = toGlobal[bearer]?.get(local)
            if (g != null) { toGlobal[bearer]?.remove(local); fromGlobal.remove(g) }
            g
        } ?: return
        sink?.linkDown(g)
    }
}

private class Lane(private val manager: BearerManager, private val bearer: Bearer) : LinkSink {
    override fun linkUp(link: Long, role: HopRole, peerId: ByteArray) = manager.up(bearer, link, role, peerId)
    override fun linkBytes(link: Long, bytes: ByteArray) = manager.bytes(bearer, link, bytes)
    override fun linkDown(link: Long) = manager.down(bearer, link)
}

/** Ties a HopNode (C ABI) to a BearerManager: bearer links drive the node's seam; pump() drains the
 *  node's outbound packets back to the owning bearer. */
class HopRuntime(val node: HopNode, baseLinkId: Long = 1_000_000) {
    val bearers = BearerManager(baseLinkId)

    init {
        bearers.sink = object : LinkSink {
            override fun linkUp(link: Long, role: HopRole, peerId: ByteArray) = node.linkUp(link, role) // node learns identity via Noise
            override fun linkBytes(link: Long, bytes: ByteArray) = node.bytesReceived(link, bytes)
            override fun linkDown(link: Long) = node.linkDown(link)
        }
    }

    fun register(bearer: Bearer) = bearers.register(bearer)
    fun start() = bearers.start()
    fun stop() = bearers.stop()
    fun pump() = node.drainOutgoing { link, bytes -> bearers.send(bytes, link) }
    fun tick(nowMs: Long) = node.tick(nowMs)
}
