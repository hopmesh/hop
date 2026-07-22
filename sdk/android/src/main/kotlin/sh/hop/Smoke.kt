// Smoke: proves the Kotlin `Hop` wrapper drives libhop's C ABI, same shape as smoke.c / HopSmoke:
// two in-memory nodes wired by a loopback bearer run the real §39 send→deliver(+ACK) + base58.

package sh.hop

import kotlin.system.exitProcess

fun main() {
    val a = HopNode.ephemeral()
    val b = HopNode.ephemeral()

    var now = 1_700_000_000_000L
    a.tick(now); b.tick(now)
    a.publishPrekey(); b.publishPrekey()
    val bAddr = b.address()

    a.linkUp(1, HopRole.DIALER)
    b.linkUp(1, HopRole.ACCEPTOR)

    fun pump(rounds: Int, done: () -> Boolean = { false }): Boolean {
        repeat(rounds) {
            a.drainOutgoing { _, bytes -> b.bytesReceived(1, bytes) }
            b.drainOutgoing { _, bytes -> a.bytesReceived(1, bytes) }
            now += 100; a.tick(now); b.tick(now)
            if (done()) return true
        }
        return done()
    }

    pump(50) // handshake + prekey gossip

    val text = "hello from Kotlin over the C ABI"
    val id = a.send(bAddr, body = text.toByteArray(), requestAck = true)
        ?: run { println("FAIL: send null"); exitProcess(1) }

    var got: HopMessage? = null
    var accepted = false
    val ok = pump(400) {
        b.pollInbox { got = it }
        if (!accepted) got?.let { accepted = b.acceptInbox(it.id) }
        got != null && a.delivered(id)
    }

    val body = got?.let { String(it.body) } ?: ""
    val pass = ok && body == text && a.delivered(id)
    println("${if (pass) "PASS" else "FAIL"}: B got=\"$body\" hops=${got?.hops ?: 0} | A delivered=${a.delivered(id)}")

    val b58 = HopAddress.base58(bAddr)
    val b58ok = HopAddress.fromBase58(b58)?.contentEquals(bAddr) == true
    println("${if (b58ok) "PASS" else "FAIL"}: base58 round-trip ($b58)")

    a.free(); b.free()

    val rtOk = runtimeSmoke()
    exitProcess(if (pass && b58ok && rtOk) 0 else 1)
}

/** A trivial in-memory bearer: links up with a fixed partner; `send` hands bytes straight to it. */
private class LoopbackBearer(private val dialer: Boolean) : Bearer {
    override var sink: LinkSink? = null
    override val transportName = "LOOP"
    var partner: LoopbackBearer? = null
    override fun start() { sink?.linkUp(1, if (dialer) HopRole.DIALER else HopRole.ACCEPTOR, ByteArray(0)) }
    override fun stop() { sink?.linkDown(1) }
    override fun send(bytes: ByteArray, link: Long) { partner?.sink?.linkBytes(1, bytes) }  // out on A == in on B
}

/** Proves HopRuntime + a Bearer drive the node end to end (parity with Swift RuntimeSmoke). */
private fun runtimeSmoke(): Boolean {
    val bA = LoopbackBearer(dialer = true)
    val bB = LoopbackBearer(dialer = false)
    bA.partner = bB; bB.partner = bA

    val rtA = HopRuntime(HopNode.ephemeral())
    val rtB = HopRuntime(HopNode.ephemeral())
    var now = 1_700_000_000_000L
    rtA.tick(now); rtB.tick(now)
    rtA.node.publishPrekey(); rtB.node.publishPrekey()
    val bAddr = rtB.node.address()
    rtA.register(bA); rtB.register(bB)
    rtA.start(); rtB.start()

    fun pump(rounds: Int, done: () -> Boolean = { false }): Boolean {
        repeat(rounds) { rtA.pump(); rtB.pump(); now += 100; rtA.tick(now); rtB.tick(now); if (done()) return true }
        return done()
    }
    pump(50)
    val text = "hello through Kotlin HopRuntime + a Bearer"
    val id = rtA.node.send(bAddr, body = text.toByteArray(), requestAck = true) ?: return false
    var got: HopMessage? = null
    var accepted = false
    val ok = pump(400) {
        rtB.node.pollInbox { got = it }
        if (!accepted) got?.let { accepted = rtB.node.acceptInbox(it.id) }
        got != null && rtA.node.delivered(id)
    }
    val body = got?.let { String(it.body) } ?: ""
    val pass = ok && body == text && rtA.node.delivered(id)
    println("${if (pass) "PASS" else "FAIL"}: runtime+bearer delivered=${rtA.node.delivered(id)} via ${rtB.bearers.transportNameOf(1_000_000)}")
    rtA.node.free(); rtB.node.free()
    return pass
}
