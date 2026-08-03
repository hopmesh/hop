// A fully in-memory HopEngine for commonTest. Because the whole SDK depends only on the HopEngine seam,
// this fake lets the reactive client, the send path, and the delivery-status tracking run with no native
// library, no JNA, and no cinterop. It models just enough: a queue of inbound messages a test can push,
// a record of sends, and a scriptable delivery status per sent id.

package sh.hop.compose

class FakeHopEngine(
    private val self: HopAddress = HopAddress.of(ByteArray(32) { 1 }),
) : HopEngine {
    val sent = mutableListOf<SentRecord>()
    var closed = false
        private set
    var prekeysPublished = 0
        private set
    var lastTickMs = 0L
        private set
    var name: String? = null
        private set

    private val pending = ArrayDeque<EngineMessage>()
    private val securedPeers = mutableSetOf<HopAddress>()
    private val statuses = mutableMapOf<String, EngineStatus>()
    private var nextId = 0

    data class SentRecord(val id: ByteArray, val to: HopAddress, val body: ByteArray, val requestAck: Boolean) {
        override fun equals(other: Any?) = this === other ||
            (other is SentRecord && id.contentEquals(other.id) && to == other.to &&
                body.contentEquals(other.body) && requestAck == other.requestAck)
        override fun hashCode() = id.contentHashCode()
    }

    // ---- test-side controls ----

    /** Queue an inbound message from [from] to be delivered on the next pollInbox. Returns its id. */
    fun deliver(from: HopAddress, body: ByteArray, contentType: String = "text/plain", createdAtMs: Long = 0, hops: Int = 1): ByteArray {
        val id = ByteArray(32).also { it[0] = (0x80 or (nextId++ and 0x7f)).toByte() }
        pending.addLast(EngineMessage(id, from.toBytes(), contentType, body, hops, createdAtMs))
        return id
    }

    fun markSecured(peer: HopAddress) { securedPeers += peer }

    /** Script the status a later statusOf(id) will report. */
    fun setStatus(id: ByteArray, status: EngineStatus) { statuses[id.toHex()] = status }

    // ---- HopEngine ----

    override fun address(): HopAddress = self

    override fun base58(address: HopAddress): String =
        "b58_" + address.toBytes().take(4).joinToString("") { (it.toInt() and 0xff).toString() }

    override fun addressFromBase58(text: String): HopAddress? =
        if (text.startsWith("b58_")) self else null

    override fun tick(nowMs: Long) { lastTickMs = nowMs }

    override fun publishPrekey(): Boolean { prekeysPublished++; return true }

    override fun setName(name: String) { this.name = name }

    override fun isSecured(peer: HopAddress): Boolean = peer in securedPeers

    override fun send(to: HopAddress, contentType: String, body: ByteArray, requestAck: Boolean): ByteArray? {
        val id = ByteArray(32).also { it[0] = (nextId++ and 0x7f).toByte() }
        sent += SentRecord(id, to, body, requestAck)
        val hex = id.toHex()
        if (hex !in statuses) statuses[hex] = EngineStatus(relayed = 0, delivered = false, forwardHops = 0, forwardMs = 0)
        return id
    }

    override fun pollInbox(onMessage: (EngineMessage) -> Boolean) {
        // Redeliver everything currently queued; accepted items are removed, rejected ones stay.
        val snapshot = pending.toList()
        pending.clear()
        for (m in snapshot) {
            val accepted = onMessage(m)
            if (!accepted) pending.addLast(m)
        }
    }

    override fun statusOf(id: ByteArray): EngineStatus =
        statuses[id.toHex()] ?: EngineStatus(relayed = 0, delivered = false, forwardHops = 0, forwardMs = 0)

    override fun close() { closed = true }
}
