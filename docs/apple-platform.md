# Hop on Apple platforms

The `hop` crate (libhop) exposes the node via the C ABI (`sdk/hop.h`); the
[UniFFI](https://mozilla.github.io/uniffi-rs/) bindings are the optional Swift sugar.
The Rust core is the source of truth; this layer is a thin generated binding plus
the native BLE bearer (TODO, see below).

## Build

```sh
./tools/build-xcframework.sh
```

Produces under `drivers/apple/HopDriver/`:

- `Frameworks/HopFFI.xcframework`, device (`ios-arm64`) + simulator + macOS slices. Add it as a
  binary target in a Swift package, which is what `HopDriver/Package.swift` already does.
- `Sources/HopFFIBindings/hop.swift`, the generated Swift API.

Note that unlike the Android and `sdk/apple` equivalents, this xcframework is **committed**, not
gitignored, because `HopDriver/Package.swift` resolves it by local path. Rebuilding it therefore
shows up as a large binary diff.

**Building any in-tree Apple package or app also needs the manifest swap**
`cp sdk/apple/Package.local.swift sdk/apple/Package.swift`. The committed manifest is the published
one and resolves `CHop` from a `hop-sdk-apple` release asset that does not exist yet, so resolution
fails with a 404 without the swap. CI does the same (`.github/workflows/ci.yml`). Restore the remote
manifest before committing.

## Verify it works (no device needed)

```sh
./tools/smoke-test.sh
```

Compiles and runs a Swift program against the Rust library on the macOS host: two
`HopNode`s perform the Noise handshake and deliver a message. Prints `✅` on success.

## Using `HopNode` from Swift

```swift
let node = HopNode()                       // fresh identity, in-memory store
node.connected(link: linkId, initiator: dialed)   // from your BLE bearer
node.received(link: linkId, bytes: data)          // bytes off the bearer
for pkt in node.drainOutgoing() {                 // bytes to send over the bearer
    bearer.send(pkt.link, pkt.bytes)
}
let id = try node.sendMessage(dst: peerAddr, sealingKey: peerSealingKey,
                              contentType: "text/plain", body: msg, requestAck: true)
for m in node.takeInbox() { /* m.from, m.contentType, m.body */ }
node.tick(nowMs: now)                              // periodic: retransmit, prune
```

## TODO, native BLE bearer

The only platform code left is a CoreBluetooth shim that implements the byte-stream
contract `HopNode` expects: act as both central and peripheral, advertise the shared
Hop service UUID (DESIGN.md §17), open L2CAP CoC channels, and pump bytes through
`connected` / `received` / `drainOutgoing`. See DESIGN.md §11 for the iOS-background
constraints that shape it.
