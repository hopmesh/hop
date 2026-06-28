// ProofSink — the clean-room "proof of pipe" consumer, shared by BOTH clean-room hosts: the macOS CLI
// (blepeer) and the iOS app (ble-lab/apple-ios). It is a `LinkSink`: the transport (a BearerManager
// over a BleBearer) owns framing / keepalive / watchdog / dedup / redial; this consumer owns ONLY the
// proof — it pings each link over DATA frames (Bearer.send), counts rx/tx, measures RTT, and emits the
// `HOPLAB <t> PROOF …` and `STATE LINK UP/CLOSED` lines that existing log analysis (and the iOS app's
// log tail) parse. Living in one shared target is the whole point: a clean-room fix is identical on
// both hosts, no copy-paste fold-back.
//
// The proof's PING/PONG ride INSIDE DATA payloads (the transport's own 0x02/0x03 keepalive PING is a
// separate, transport-internal stream that never surfaces here). Proof payload format, big-endian:
//   PROOF_PING : [0x01][8B seq][8B t_send_ms]
//   PROOF_PONG : [0x02][8B seq][8B t_send_ms]   (echoes the ping, so the pinger can compute RTT)

import Foundation
import HopBearers

private let PROOF_PING: UInt8 = 0x01
private let PROOF_PONG: UInt8 = 0x02

/// One 1 Hz proof-pinger per link; rx/tx/rtt + the PROOF line per peer. All link state is touched only
/// on `bleRunLoop` (the bearer surfaces linkUp/linkBytes/linkDown there, and the ping timer is added to
/// it too) — so no locking, and the proof keeps pinging on iOS in the background (bleRunLoop is the
/// dedicated I/O thread, not the throttled main run loop).
public final class ProofSink: LinkSink {
    /// The BearerManager (a Bearer); weak — the host owns it. Typed `Bearer`, not `BleBearer`: the
    /// consumer is transport-agnostic, it just sends on a LinkId.
    public weak var bearer: Bearer?

    private struct State {
        let peerId: Data
        let isDialer: Bool
        var txSeq: UInt64 = 0             // our proof-ping counter
        var rxSeq: UInt64 = 0            // peer's proof-ping counter
        var lastRttMs: UInt64 = 0
        var timer: Timer?
    }
    private var links = [LinkId: State]()

    public init() {}

    // MARK: LinkSink

    public func linkUp(_ link: LinkId, role: LinkRole, peerId: Data) {
        let isDialer: Bool
        switch role { case .dialer: isDialer = true; case .acceptor: isDialer = false }
        log("STATE", "LINK UP peer=\(shortHex(peerId)) isDialer=\(isDialer)")
        var st = State(peerId: peerId, isDialer: isDialer)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.pingTick(link) }
        bleRunLoop.add(t, forMode: .common)          // same run loop the bearer surfaces links on
        st.timer = t
        links[link] = st
    }

    public func linkBytes(_ link: LinkId, _ bytes: Data) {
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

    public func linkDown(_ link: LinkId) {
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
