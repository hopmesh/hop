// Bearers — the Kotlin transport kit, shipped WITH the Hop SDK (parity with the Swift Bearers.swift)
// so an Android bearer module depends on nothing but this SDK. Defines the in-process bearer contract
// (Bearer/LinkSink), the registry/multiplexer (BearerManager — one global LinkId space), and the
// runtime that binds them to a HopNode (the C ABI). Pure Kotlin, no Android types — an Android
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

    fun register(bearer: Bearer) {
        val lane = Lane(this, bearer)
        bearer.sink = lane
        synchronized(lock) { lanes.add(lane); bearers.add(bearer) }
    }

    // F-10: isolate each bearer's start/stop so one throwing (e.g. BLE listen failing when Bluetooth
    // is off at launch) can't abort the others (LAN + relay) or crash the caller's thread.
    override fun start() = snapshot().forEach {
        try { it.start() } catch (e: Throwable) { System.err.println("bearer start failed: ${e.message}") }
    }
    override fun stop() = snapshot().forEach {
        try { it.stop() } catch (e: Throwable) { System.err.println("bearer stop failed: ${e.message}") }
    }

    override fun send(bytes: ByteArray, link: Long) {
        val route = synchronized(lock) { fromGlobal[link] } ?: return
        route.first.send(bytes, route.second)
    }

    private fun snapshot(): List<Bearer> = synchronized(lock) { ArrayList(bearers) }

    fun transportNameOf(link: LinkId): String? = synchronized(lock) { fromGlobal[link] }?.first?.transportName

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
