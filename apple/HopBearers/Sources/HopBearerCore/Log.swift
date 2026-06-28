import Foundation

// Transport-neutral helpers shared by the core, every bearer lib, and the proof consumer. Nothing
// here is BLE/Wi-Fi specific — just the grep-able log format and small byte/time utilities so every
// bearer and consumer emits the SAME `HOPLAB …` lines and short-peer labels.

private let processStart = Date()

/// Grep-able structured log. Every line begins with `HOPLAB`. Categories: STATE, DEDUP, STATUS, WARN
/// (transports) and PROOF (the clean-room consumer). Both stdout (macOS CLI capture) and the unified
/// log (iOS device capture via idb/Console).
public func log(_ category: String, _ message: String) {
    let t = Date().timeIntervalSince(processStart)
    print("HOPLAB \(String(format: "%9.3f", t)) \(category) \(message)")
    NSLog("HOPLAB %9.3f %@ %@", t, category, message)
}

public func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
public func nowS()  -> Double { Date().timeIntervalSince1970 }
public func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
/// First-4-bytes hex (8 chars) — the short peer label shared by transport + consumer logs.
public func shortHex(_ d: Data?) -> String { d.map { hex($0.prefix(4)) } ?? "????????" }
