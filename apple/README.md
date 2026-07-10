# Hop on Apple platforms

The `hop` crate (libhop) exposes the node via the C ABI (`sdk/hop.h`); the
[UniFFI](https://mozilla.github.io/uniffi-rs/) bindings are the optional Swift sugar.
The Rust core is the source of truth; this layer is a thin generated binding plus
the native BLE bearer (TODO, see below).

## Build

```sh
./apple/build-xcframework.sh
```

Produces (gitignored) under `apple/generated/`:

- `HopFFI.xcframework` — device (`ios-arm64`) + simulator slices. Drag into your
  Xcode project (or add as a binary target in a Swift package).
- `Sources/hop.swift` — the generated Swift API. Add it to your target.

## Verify it works (no device needed)

```sh
./apple/smoke-test.sh
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

## TODO — native BLE bearer

The only platform code left is a CoreBluetooth shim that implements the byte-stream
contract `HopNode` expects: act as both central and peripheral, advertise the shared
Hop service UUID (DESIGN.md §17), open L2CAP CoC channels, and pump bytes through
`connected` / `received` / `drainOutgoing`. See DESIGN.md §11 for the iOS-background
constraints that shape it.
