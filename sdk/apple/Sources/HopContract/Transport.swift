// Transport: small transport-neutral helpers every bearer package shares (so a bearer depends on
// nothing but `Hop`). Nothing BLE/Wi-Fi/socket specific: the grep-able log format, byte/time utils,
// the one cross-transport nodeId + the "greater nodeId dials" tiebreaker. (Folded in from the proven
// HopBearerCore Log.swift / NodeId.swift.)

import Foundation
import Security

private let processStart = Date()

/// Grep-able structured log. Every line begins with `HOPLAB`. Categories: STATE, DEDUP, STATUS, WARN.
public func log(_ category: String, _ message: String) {
    let t = Date().timeIntervalSince(processStart)
    print("HOPLAB \(String(format: "%9.3f", t)) \(category) \(message)")
    NSLog("HOPLAB %9.3f %@ %@", t, category, message)
}

public func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
public func nowS() -> Double { Date().timeIntervalSince1970 }
public func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
/// First-4-bytes hex (8 chars), the short peer label shared across transport logs.
public func shortHex(_ d: Data?) -> String { d.map { hex($0.prefix(4)) } ?? "????????" }

/// A fresh random 16-byte nodeId (CSPRNG). Stable for the process lifetime, the bearer-layer
/// transport id (distinct from the Hop node address), used for HELLO + the dedup tiebreaker.
public func randomNodeId() -> Data {
    var d = Data(count: 16)
    let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    if rc != errSecSuccess {
        d = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
    return d
}

/// Unsigned big-endian compare: a > b. The cross-transport tiebreaker, "greater nodeId dials", so
/// two peers that both discover each other don't double-connect.
public func nodeIdGreater(_ a: Data, _ b: Data) -> Bool {
    for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] > b[i] }
    return a.count > b.count
}
