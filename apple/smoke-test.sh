#!/usr/bin/env bash
# Compile + run a Swift program against the Rust library on the macOS host — proves
# the generated bindings actually drive the node loop (Noise handshake + delivery),
# no device or simulator needed. Run apple/build-xcframework.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

# The generated bindings + headers now live in the HopDriver package (build-xcframework.sh output).
BINDINGS=apple/HopDriver/Sources/HopFFIBindings/hop_ffi.swift
INC=apple/HopDriver/Frameworks/HopFFI.xcframework/macos-arm64_x86_64/Headers
[ -f "$BINDINGS" ] || { echo "run apple/build-xcframework.sh first"; exit 1; }
cargo build -p hop-ffi >/dev/null   # host staticlib at target/debug/libhop_ffi.a

WORK=$(mktemp -d)
cp "$BINDINGS" "$WORK/"
mkdir -p "$WORK/inc"
cp "$INC/hop_ffiFFI.h" "$WORK/inc/"
cp "$INC/module.modulemap" "$WORK/inc/"

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
func pump(_ a: HopNode, _ b: HopNode) {
    for _ in 0..<1000 {
        let oa = a.drainOutgoing(); let ob = b.drainOutgoing()
        if oa.isEmpty && ob.isEmpty { break }
        for p in oa { b.received(link: p.link, bytes: p.bytes) }
        for p in ob { a.received(link: p.link, bytes: p.bytes) }
    }
}
let a = HopNode(); let b = HopNode()
// Set a real clock before publishing prekeys, else they're stamped created_at=0 and judged
// expired. Device-to-device delivery is always forward-secret (require-ratchet): publish each
// node's prekey, let them gossip over the link, then the message rides a ratchet session.
let now = UInt64(Date().timeIntervalSince1970 * 1000)
a.tick(nowMs: now); b.tick(nowMs: now)
_ = try a.publishPrekey(); _ = try b.publishPrekey()
a.connected(link: 1, initiator: true)
b.connected(link: 1, initiator: false)
pump(a, b)   // Noise handshake + prekey gossip
_ = try a.sendMessage(dst: b.address(), contentType: "text/plain",
                      body: Data("hi from swift".utf8), requestAck: false)
pump(a, b)   // ratchet + delivery
let inbox = b.takeInbox()
guard inbox.count == 1, let t = String(data: inbox[0].body, encoding: .utf8),
      t == "hi from swift", inbox[0].from == a.address() else {
    FileHandle.standardError.write(Data("FAIL\n".utf8)); exit(1)
}
print("✅ Swift → Rust FFI: node B received \"\(t)\" from a \(inbox[0].from.count)-byte address")
SWIFT

swiftc -O -I "$WORK/inc" -L target/debug -lhop_ffi \
  "$WORK/hop_ffi.swift" "$WORK/main.swift" -o "$WORK/hoptest"
"$WORK/hoptest"
