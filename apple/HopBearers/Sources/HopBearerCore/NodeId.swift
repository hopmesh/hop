import Foundation
import Security

// A node's identity is ONE 16-byte id shared across every transport — a peer reached by BLE and by
// LAN is the same node. So id generation lives in the core, not in any single bearer: the host mints
// one id and hands it to every bearer it registers.

/// A fresh random 16-byte nodeId (CSPRNG). Stable for the process lifetime (SPEC R11).
public func randomNodeId() -> Data {
    var d = Data(count: 16)
    let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    if rc != errSecSuccess {                       // defensive fallback; SystemRandom is CSPRNG-grade
        d = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
    return d
}

/// Unsigned big-endian compare: a > b (byte 0 most significant). The cross-transport tiebreaker
/// primitive — "greater nodeId dials" — so two peers that both discover each other don't double-connect.
public func nodeIdGreater(_ a: Data, _ b: Data) -> Bool {
    for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] > b[i] }
    return a.count > b.count
}
