package net.waldrip.blelab

import android.util.Log
import net.waldrip.hop.bearers.Bearer
import net.waldrip.hop.bearers.LinkId
import net.waldrip.hop.bearers.LinkRole
import net.waldrip.hop.bearers.LinkSink
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

// ProofSink — the clean-room "proof of pipe" consumer. The Android mirror of
// apple/HopBearers' HopBearerProof/ProofSink.swift. It is a LinkSink: the transport (a BearerManager
// over a BleBearer) owns framing / keepalive / watchdog / dedup / redial; this consumer owns ONLY the
// proof — it pings each link over DATA frames (Bearer.send), counts rx/tx, measures RTT, and emits the
// `PROOF …` and `LINK UP/CLOSED` lines that existing logcat analysis parses.
//
// The proof's PING/PONG ride INSIDE DATA payloads (the transport's own 0x02/0x03 keepalive is a
// separate, transport-internal stream that never surfaces here). Proof payload format, big-endian:
//   PROOF_PING : [0x01][8B seq][8B t_send_ms]
//   PROOF_PONG : [0x02][8B seq][8B t_send_ms]   (echoes the ping, so the pinger can compute RTT)
//
// Android has no shared run loop (Apple pins all proof state to bleRunLoop), so each link gets a 1 Hz
// task on a single shared ScheduledExecutorService; the `links` map is guarded by `lock` and the
// per-link counters are @Volatile (written on the rx thread / the ping thread, read in the PROOF line).
class ProofSink : LinkSink {
    /// The BearerManager (a Bearer) to send proof pings on. Typed Bearer, not BleBearer: the consumer
    /// is transport-agnostic, it just sends on a LinkId.
    var bearer: Bearer? = null

    private class LinkState(val peerId: ByteArray, val isDialer: Boolean) {
        @Volatile var txSeq = 0L   // our proof-ping counter
        @Volatile var rxSeq = 0L   // peer's proof-ping counter
        @Volatile var lastRttMs = 0L
        @Volatile var future: ScheduledFuture<*>? = null
    }

    private val lock = Any()
    private val links = HashMap<LinkId, LinkState>()
    private val sched: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

    override fun linkUp(link: LinkId, role: LinkRole, peerId: ByteArray) {
        val isDialer = role == LinkRole.DIALER
        Log.i(TAG, "LINK UP peer=${peerId.short()} isDialer=$isDialer")
        val st = LinkState(peerId, isDialer)
        synchronized(lock) {
            links[link] = st
            st.future = sched.scheduleAtFixedRate({ pingTick(link) }, 1, 1, TimeUnit.SECONDS)
        }
    }

    override fun linkBytes(link: LinkId, bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val st = synchronized(lock) { links[link] } ?: return // ignore DATA for a link we never saw come up
        when (bytes[0].toInt() and 0xff) {
            PROOF_PING -> { // peer pinged us → PONG + emit the PROOF line
                if (bytes.size < 9) return
                st.rxSeq = u64dec(bytes, 1)
                val pong = byteArrayOf(PROOF_PONG.toByte()) + bytes.copyOfRange(1, minOf(17, bytes.size))
                bearer?.send(pong, link)
                // Proof of pipe: BOTH directions on one line (tx = ours, rx = peer's, rtt = last RTT).
                Log.i(
                    TAG,
                    "PROOF peer=${st.peerId.short()} tx=${st.txSeq} rx=${st.rxSeq} rtt=${st.lastRttMs}ms isDialer=${st.isDialer}",
                )
            }
            PROOF_PONG -> { // our ping came back → RTT (reverse direction live)
                if (bytes.size < 17) return
                val tSend = u64dec(bytes, 9)
                val now = System.currentTimeMillis()
                if (now >= tSend) st.lastRttMs = now - tSend
            }
        }
    }

    override fun linkDown(link: LinkId) {
        val st = synchronized(lock) { links.remove(link) } ?: return
        st.future?.cancel(false)
        Log.i(TAG, "LINK CLOSED peer=${st.peerId.short()} isDialer=${st.isDialer}")
    }

    /// Stop the proof pinger and release its thread (call on service teardown). Idempotent-ish.
    fun shutdown() {
        synchronized(lock) {
            links.values.forEach { it.future?.cancel(false) }
            links.clear()
        }
        sched.shutdownNow()
    }

    private fun pingTick(link: LinkId) {
        val st = synchronized(lock) { links[link] } ?: return
        st.txSeq += 1 // only the single sched thread touches txSeq
        val ping = byteArrayOf(PROOF_PING.toByte()) + u64(st.txSeq) + u64(System.currentTimeMillis())
        bearer?.send(ping, link)
    }

    // big-endian u64 helpers (proof payload codec)
    private fun u64(v: Long) = ByteArray(8) { (v ushr (56 - it * 8)).toByte() }
    private fun u64dec(b: ByteArray, o: Int): Long {
        var v = 0L
        for (i in 0..7) v = (v shl 8) or (b[o + i].toLong() and 0xff)
        return v
    }
    private fun ByteArray.short(): String = joinToString("") { "%02x".format(it) }.take(8)

    private companion object {
        const val PROOF_PING = 0x01 // distinct from the transport's 0x02 keepalive PING
        const val PROOF_PONG = 0x02 // distinct from the transport's 0x03 keepalive PONG
    }
}
