// blepeer — the clean-room CLI consumer of the shared HopBearers transport (ble-lab/SPEC.md §8).
//
// This is the SAME "proof of pipe" the standalone ble-lab CLI ran, but re-seamed onto BleBearer via
// the LinkSink contract. The transport (BleBearer) owns framing / keepalive / watchdog / dedup /
// redial; this consumer (ProofSink) owns ONLY the proof: it pings over DATA frames (Bearer.send),
// counts rx/tx, measures RTT, and emits the identical `HOPLAB <t> PROOF …` and `STATE LINK UP/CLOSED`
// lines so existing log analysis still parses. Pure Foundation; CoreBluetooth lives inside HopBearers.
//
// The proof's PING/PONG ride INSIDE DATA payloads (the transport's own 0x02/0x03 keepalive PING is a
// separate, transport-internal stream that never surfaces here). Proof payload format, big-endian:
//   PROOF_PING : [0x01][8B seq][8B t_send_ms]
//   PROOF_PONG : [0x02][8B seq][8B t_send_ms]   (echoes the ping, so the pinger can compute RTT)

import Foundation
import HopBearers

setbuf(stdout, nil)                    // unbuffered logs so `timeout`/piping flush immediately

private let PROOF_PING: UInt8 = 0x01
private let PROOF_PONG: UInt8 = 0x02

/// The clean-room consumer. One 1 Hz proof-pinger per link; rx/tx/rtt + the PROOF line per peer.
final class ProofSink: LinkSink {
    weak var bearer: Bearer?               // the BearerManager (a Bearer); weak — the consumer owns it.
                                           // Note it's typed `Bearer`, not `BleBearer`: the consumer is
                                           // transport-agnostic, it just sends on a LinkId.

    private struct State {
        let peerId: Data
        let isDialer: Bool
        var txSeq: UInt64 = 0             // our proof-ping counter
        var rxSeq: UInt64 = 0            // peer's proof-ping counter
        var lastRttMs: UInt64 = 0
        var timer: Timer?
    }
    private var links = [LinkId: State]()

    // MARK: LinkSink

    func linkUp(_ link: LinkId, role: LinkRole, peerId: Data) {
        let isDialer: Bool
        switch role { case .dialer: isDialer = true; case .acceptor: isDialer = false }
        log("STATE", "LINK UP peer=\(shortHex(peerId)) isDialer=\(isDialer)")
        var st = State(peerId: peerId, isDialer: isDialer)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.pingTick(link) }
        RunLoop.main.add(t, forMode: .common)        // CLI: bleRunLoop == .main
        st.timer = t
        links[link] = st
    }

    func linkBytes(_ link: LinkId, _ bytes: Data) {
        guard var st = links[link] else { return }   // ignore DATA for a link we never saw come up
        let b = [UInt8](bytes)
        guard let type = b.first else { return }
        switch type {
        case PROOF_PING:                              // peer pinged us -> PONG + emit the PROOF line
            guard b.count >= 9 else { return }
            st.rxSeq = u64(b, 1)
            links[link] = st
            var pong = Data([PROOF_PONG]); pong.append(contentsOf: b[1..<min(17, b.count)])
            bearer?.send(pong, on: link)
            // Proof of pipe: BOTH directions on one line (rx = peer's counter, tx = ours, rtt = last RTT).
            log("PROOF", "peer=\(shortHex(st.peerId)) rx=\(st.rxSeq) tx=\(st.txSeq) rtt=\(st.lastRttMs)ms isDialer=\(st.isDialer)")
        case PROOF_PONG:                              // our ping came back -> RTT (reverse direction live)
            guard b.count >= 17 else { return }
            let tSend = u64(b, 9); let now = nowMs()
            if now >= tSend { st.lastRttMs = now - tSend; links[link] = st }
        default: break
        }
    }

    func linkDown(_ link: LinkId) {
        guard let st = links.removeValue(forKey: link) else { return }
        st.timer?.invalidate()
        log("STATE", "LINK CLOSED peer=\(shortHex(st.peerId)) isDialer=\(st.isDialer)")
    }

    // MARK: pinger

    private func pingTick(_ link: LinkId) {
        guard var st = links[link] else { return }
        st.txSeq += 1
        links[link] = st
        var ping = Data([PROOF_PING]); appU64(&ping, st.txSeq); appU64(&ping, nowMs())
        bearer?.send(ping, on: link)
    }

    // MARK: big-endian u64 helpers (proof payload codec)

    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }
        return v
    }
    private func appU64(_ d: inout Data, _ v: UInt64) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }
}

// CLI bootstrap: SPEC defaults (bleQueue = .main, bleRunLoop = .main). Symmetric dual role + proof.
// The consumer talks to a BearerManager (a Bearer) and registers BleBearer into it — exactly the shape
// the production app will use, just with one bearer for now. Adding LAN/Wi-Fi later is one more
// `register(...)` line; nothing else here changes.
log("STATE", "blepeer starting (HopBearers BearerManager + BleBearer + ProofSink)")
let manager = BearerManager()
manager.register(BleBearer(myId: BleBearer.randomNodeId()))
let sink = ProofSink()
sink.bearer = manager                  // proof pings route out through the manager (uniform Bearer)
manager.sink = sink                    // links from every registered bearer surface here, one id space
manager.start()
RunLoop.main.run()
