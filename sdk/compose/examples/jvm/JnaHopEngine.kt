// EXAMPLE (not part of the compiled library): the JVM engine adapter, from the `sh.hop:hop` Kotlin SDK's
// JNA `HopNode` to this SDK's HopEngine seam. It is shipped as an example rather than compiled in, for
// the same reason the iOS engine is app-supplied: the Compose SDK depends ONLY on the HopEngine seam, so
// the library stays binding-neutral and its published artifact needs no native SDK on its classpath.
// Copy this file into your Android or Desktop app (which already depends on `sh.hop:hop`), then pass
// `JnaHopEngine(node)` to `rememberHopClient(engine)`. It does no policy of its own; it only translates
// between the ABI-adjacent JNA surface (raw 32-byte arrays, `sh.hop.HopMessage`) and the engine terms
// HopClient consumes (EngineMessage / EngineStatus). One adapter serves Android and Desktop: JNA loads
// the same libhop on both (a .so on Android, a .dylib/.so on the host JVM).

package sh.hop.compose.examples.jvm

import sh.hop.compose.EngineMessage
import sh.hop.compose.EngineStatus
import sh.hop.compose.HopAddress
import sh.hop.compose.HopEngine

import sh.hop.HopNode

/** Adapt a running `sh.hop.HopNode` to [HopEngine]. The node's lifetime is owned by this engine once
 *  wrapped: [close] frees it. Build the node with the `sh.hop:hop` SDK (for example
 *  `HopNode.openKeyed(dbPath, keystoreKey)`), then hand it here. */
class JnaHopEngine(private val node: HopNode) : HopEngine {

    override fun address(): HopAddress = HopAddress.of(node.address())

    override fun base58(address: HopAddress): String = sh.hop.HopAddress.base58(address.toBytes())

    override fun addressFromBase58(text: String): HopAddress? =
        sh.hop.HopAddress.fromBase58(text)?.let { HopAddress.of(it) }

    override fun tick(nowMs: Long) = node.tick(nowMs)

    override fun publishPrekey(): Boolean = node.publishPrekey()

    override fun setName(name: String) = node.setName(name)

    override fun isSecured(peer: HopAddress): Boolean = node.isSecured(peer.toBytes())

    override fun send(to: HopAddress, contentType: String, body: ByteArray, requestAck: Boolean): ByteArray? =
        node.send(to.toBytes(), contentType, body, requestAck)

    override fun pollInbox(onMessage: (EngineMessage) -> Boolean) {
        node.pollInboxAccepting { m ->
            onMessage(
                EngineMessage(
                    id = m.id,
                    from = m.from,
                    contentType = m.contentType,
                    body = m.body,
                    hops = m.hops.toInt(),
                    createdAtMs = m.createdAt,
                ),
            )
        }
    }

    override fun statusOf(id: ByteArray): EngineStatus {
        val s = node.status(id)
        return EngineStatus(
            relayed = s.relayed,
            delivered = s.delivered,
            forwardHops = s.forwardHops.toInt(),
            forwardMs = s.forwardMs,
        )
    }

    override fun close() = node.close()
}

/** Wrap an existing [HopNode] as a [HopEngine]. Sugar for `JnaHopEngine(node)`, so app code reads
 *  `hopEngine(node)`. */
fun hopEngine(node: HopNode): HopEngine = JnaHopEngine(node)
