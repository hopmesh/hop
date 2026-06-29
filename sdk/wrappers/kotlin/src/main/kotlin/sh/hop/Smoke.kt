// Smoke — proves the Kotlin `Hop` wrapper drives libhop's C ABI, same shape as smoke.c / HopSmoke:
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
    val ok = pump(400) {
        b.pollInbox { got = it }
        got != null && a.delivered(id)
    }

    val body = got?.let { String(it.body) } ?: ""
    val pass = ok && body == text && a.delivered(id)
    println("${if (pass) "PASS" else "FAIL"}: B got=\"$body\" hops=${got?.hops ?: 0} | A delivered=${a.delivered(id)}")

    val b58 = HopAddress.base58(bAddr)
    val b58ok = HopAddress.fromBase58(b58)?.contentEquals(bAddr) == true
    println("${if (b58ok) "PASS" else "FAIL"}: base58 round-trip ($b58)")

    a.free(); b.free()
    exitProcess(if (pass && b58ok) 0 else 1)
}
