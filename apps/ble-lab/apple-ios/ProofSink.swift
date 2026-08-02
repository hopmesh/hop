// ProofSink, restored. It was deleted by 2ae1d753 ("remove the orphaned apple/HopBearers package"),
// which was not orphaned: apps/ble-lab/apple-ios depended on it, and nothing noticed because ble-lab
// is built by no CI job. That left HopBleLab unbuildable from source, so the only app that reproduces
// the multi-app BLE defect survived solely as an old binary on one phone.
//
// Restored into the app target rather than a package, because it is a clean-room test consumer and
// has exactly one consumer. Adapted to the current contract: HopBearerCore became HopContract in
// sdk/apple, and LinkRole became HopRole. log() and shortHex() now come from HopContract, so the
// deleted Log.swift and NodeId.swift are NOT restored; they would be duplicate symbols.

// ProofSink, the clean-room "proof of pipe" consumer, shared by BOTH clean-room hosts (the macOS CLI
// blepeer and the iOS app). It is a `LinkSink`: the transport (a BearerManager over one or more bearers)
// owns framing / keepalive / watchdog / dedup / redial; this consumer owns ONLY the proof: it pings
// each link over DATA frames (Bearer.send), counts rx/tx, measures RTT, and emits the
// `HOPLAB <t> PROOF …` and `STATE LINK UP/CLOSED` lines that existing log analysis parses.
//
// It depends on the contract ONLY, nothing BLE-specific. Because links can now arrive from several
// bearers on different threads, ProofSink owns its own serial queue: every LinkSink callback and every
// ping tick runs there, so its per-link state needs no locks and it doesn't borrow any bearer's run
// loop. (Earlier it piggybacked on the BLE bearer's `bleRunLoop`; that coupling is gone.)
//
// Proof payload format, big-endian (rides INSIDE DATA frames, distinct from the transport's own
// 0x02/0x03 keepalive PING, which never surfaces here):
//   PROOF_PING : [0x01][8B seq][8B t_send_ms]
//   PROOF_PONG : [0x02][8B seq][8B t_send_ms]   (echoes the ping, so the pinger can compute RTT)

import Foundation
import HopContract

private let PROOF_PING: UInt8 = 0x01
private let PROOF_PONG: UInt8 = 0x02

/// One 1 Hz proof-pinger per link; rx/tx/rtt + the PROOF line per peer.
public final class ProofSink: LinkSink {
    /// The BearerManager (a Bearer); weak, because the host owns it. Typed `Bearer`, not a concrete bearer:
    /// the consumer is transport-agnostic, it just sends on a LinkId.
    public weak var bearer: Bearer?

    private let q = DispatchQueue(label: "hop.proof")   // all state + ticks run here (no locks needed)

    private final class State {
        let peerId: Data
        let isDialer: Bool
        var txSeq: UInt64 = 0
        var rxSeq: UInt64 = 0
        var lastRttMs: UInt64 = 0
        var timer: DispatchSourceTimer?
        init(peerId: Data, isDialer: Bool) { self.peerId = peerId; self.isDialer = isDialer }
    }
    private var links = [LinkId: State]()

    public init() {}

    // MARK: LinkSink (each hops onto `q` so per-link state is single-threaded)

    public func linkUp(_ link: LinkId, role: HopRole, peerId: Data) {
        let isDialer: Bool
        switch role { case .dialer: isDialer = true; case .acceptor: isDialer = false }
        q.async { [weak self] in
            guard let self else { return }
            log("STATE", "LINK UP peer=\(shortHex(peerId)) isDialer=\(isDialer)")
            let st = State(peerId: peerId, isDialer: isDialer)
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 1.0, repeating: 1.0)
            t.setEventHandler { [weak self] in self?.pingTick(link) }
            st.timer = t
            self.links[link] = st
            t.resume()
        }
    }

    public func linkBytes(_ link: LinkId, _ bytes: Data) {
        q.async { [weak self] in
            guard let self, let st = self.links[link] else { return }   // ignore DATA for an unknown link
            let b = [UInt8](bytes)
            guard let type = b.first else { return }
            switch type {
            case PROOF_PING:                              // peer pinged us -> PONG + emit the PROOF line
                guard b.count >= 9 else { return }
                st.rxSeq = self.u64(b, 1)
                var pong = Data([PROOF_PONG]); pong.append(contentsOf: b[1..<min(17, b.count)])
                self.bearer?.send(pong, on: link)
                log("PROOF", "peer=\(shortHex(st.peerId)) rx=\(st.rxSeq) tx=\(st.txSeq) rtt=\(st.lastRttMs)ms isDialer=\(st.isDialer)")
            case PROOF_PONG:                              // our ping came back -> RTT
                guard b.count >= 17 else { return }
                let tSend = self.u64(b, 9); let now = nowMs()
                if now >= tSend { st.lastRttMs = now - tSend }
            default: break
            }
        }
    }

    public func linkDown(_ link: LinkId) {
        q.async { [weak self] in
            guard let self, let st = self.links.removeValue(forKey: link) else { return }
            st.timer?.cancel()
            log("STATE", "LINK CLOSED peer=\(shortHex(st.peerId)) isDialer=\(st.isDialer)")
        }
    }

    // MARK: pinger (runs on `q`)

    private func pingTick(_ link: LinkId) {
        guard let st = links[link] else { return }
        st.txSeq += 1
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
