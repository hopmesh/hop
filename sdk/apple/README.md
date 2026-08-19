<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop for Apple</h1>

<p align="center">
  <b>Run a real Hop node on iOS and macOS.</b><br>
  The Swift client SDK for the <a href="https://hopme.sh">Hop</a> mesh, over the <code>libhop</code> C ABI, shipped as a prebuilt xcframework.
</p>

<p align="center">
  <a href="https://swift.org/package-manager/"><img src="https://img.shields.io/badge/SwiftPM-compatible-F05138" alt="SwiftPM"></a>
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license">
  <img src="https://img.shields.io/badge/swift-5.9%2B-F05138" alt="swift 5.9+">
</p>

---

Hop is a **delay-tolerant mesh**: end-to-end encrypted datagrams that hop device to device, over BLE,
Wi-Fi, and the internet, until they reach the person you meant. Held, never dropped.

This is the **Apple client SDK**: it runs a genuine Hop node *on the device*, so a phone is a first-class
peer that relays for everyone else. `HopNode` is a thin, type-safe Swift face over `libhop` (the same C
ABI every Hop SDK binds), with identity, forward secrecy, and the untraceable send path already inside.
The Rust core rides along as a prebuilt static library in an xcframework, so the whole stack builds and
links for iOS devices and macOS with no manual `-L`/`-l` flags.

## Install

### Swift Package Manager

Add the package in Xcode (File > Add Package Dependencies) or in `Package.swift`:

```swift
.package(url: "https://github.com/hopmesh/hop-sdk-apple.git", from: "0.0.1")
```

Then depend on the `Hop` product:

```swift
.target(name: "MyApp", dependencies: [.product(name: "Hop", package: "hop-sdk-apple")])
```

The published manifest uses the immutable `v0.0.1/libhop.xcframework.zip` release URL and its SwiftPM
checksum. That archive is produced by the protected canonical native-artifact workflow, carries an
architecture manifest with per-slice SHA-256 values, and is verified again before the SDK release is
created.

For local development in the standalone package, run
`python3 install-local-xcframework.py --version v0.0.1`, then temporarily use `Package.local.swift` as
`Package.swift` while building. The installer applies the same signature, digest, checksum, and slice
checks as the release job. In the monorepo, `./build-xcframework.sh` remains the source-build path.
The published manifest never consults environment variables or silently selects local files.

### CocoaPods

One line. `CHop` and `HopContract` come with it, resolved from trunk:

```ruby
platform :ios, '16.0'

target 'MyApp' do
  pod 'HopSDK'
end
```

```swift
import Hop
```

**The pod is `HopSDK`, the module is `Hop`**, and the mismatch is deliberate rather than an oversight.
CocoaPods builds each pod into an archive named after the pod, so a pod called `Hop` produces `libHop.a`,
while the compiled core the `CHop` pod vendors is `libhop.a`. macOS volumes are case-insensitive by
default, so those are the same file name, and `-l` resolves by name against an ordered search path. Both
outcomes were measured: with the wrapper's directory first, CocoaPods' own `-l"hop"` picked up the Swift
wrapper and every core symbol stayed undefined; adding the core by explicit path as well linked the
wrapper twice and failed with 129 duplicate Swift symbols. `HopSDK` produces `libHopSDK.a`, which cannot
collide, and `s.module_name = "Hop"` keeps `import Hop` identical to the SwiftPM product. So the Podfile
says `HopSDK` and your source never mentions it.

Three pods, one per SwiftPM target, because CocoaPods compiles one pod into one module and the SDK's own
sources do `import CHop` and `import HopContract`. Folding them together would collapse both into the
`Hop` module and break those imports, so packaging would have dictated a change to shipping source.
`HopSDK` depends on the other two by exact version, and you never name them.

`HopSDK` is a static framework (`s.static_framework = true`). The Hop symbols live in the static
`libhop.a` that `CHop` vendors, and a dynamic framework does not absorb a static dependency, so under
`use_frameworks!` the link ended in undefined symbols. Static is also what the SwiftPM product does.
You do not have to configure anything for this; it is recorded here because it is the reason
`use_frameworks!` works.

## Quick start

```swift
import Hop

// A device-local identity with storage encrypted at rest (SQLCipher, keyed from the Keychain).
guard let node = HopNode.openKeyed(dbPath: dbURL.path, key: keychainKey) else { return }
node.setName("Ada's iPhone")

// Advance the clock and publish a prekey so peers can open a forward-secret session with you.
node.tick(nowMs: nowMs())
node.publishPrekey()

// Send an untraceable, end-to-end-encrypted message to a 32-byte address.
let dst = HopAddress.fromBase58("7Yc9…")!
node.send(to: dst, body: Data("meet at the ridge".utf8), requestAck: true)

// Polling is non-destructive. Accept only after your app has persisted the message.
node.pollInbox { msg in
    print(HopAddress.base58(msg.from), String(decoding: msg.body, as: UTF8.self))
    if appStore.save(msg) { node.acceptInbox(msg.id) }
}
```

`send(to:)` is the untraceable path (§39): the address is sealed, not on the wire. Use `sendTo(peer:)`
for a directed send to a peer you're connected to, and `sendServiceRequest`/`sendServiceResponse` for the
`hops://` request/response surface.

## The bearer seam

A node moves opaque bytes; a **bearer** (BLE, LAN, relay) owns the radio and nothing else. The core owns
all crypto, framing, and routing. Wire a bearer to the node with four calls:

```swift
node.linkUp(linkId, role: .dialer)                 // a connection came up (you dialed it)
node.bytesReceived(linkId, inboundFrame)           // frames the radio delivered, straight in
node.drainOutgoing { link, frame in radio.send(link, frame) }  // ship queued frames out
node.linkDown(linkId)                              // the connection dropped
```

`HopContract` (a pure-Swift product, no `libhop`) carries the `Bearer` / `LinkSink` / `BearerManager`
contract and the link multiplexer, so a bearer package can depend on the contract without double-linking
the Rust core.

## What the node gives you

- **Forward secrecy by default.** Device-to-device content is Double-Ratchet sealed; `isSecured(_:)`
  tells you whether a session is live.
- **Untraceable by default.** `send(to:)` puts no addresses on the wire; the bundle id is its own
  integrity check.
- **Durable and offline-first.** Messages are stored and forwarded, so a send works when the peer is
  gone and lands later.
- **Encrypted at rest.** `openKeyed` runs SQLCipher over the on-device store; `open` uses plain SQLite
  behind file protection.
- **Identity you own.** `secret` exports the 32-byte identity to stash in the Keychain; restore with
  `HopNode.with(secret:)` or `open(dbPath:secret:)`.

## Status

Prototype. The node surface, the bearer seam, base58 addressing, the `hops://` request/response path,
and encrypted-at-rest storage are built and tested (`swift test` in this package). Iterating in the open;
the wire format and ABI are versioned and asserted at load, so a mismatched build fails loudly instead of
drifting.

## The Hop family

Same node, your language. The SDKs:
[node](https://www.npmjs.com/package/@hop-mesh/endpoint) ·
[python](https://pypi.org/project/hop-endpoint/) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://rubygems.org/gems/hop-endpoint) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://hex.pm/packages/hop_endpoint) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
android.
The protocol core:
[hop-mesh-core](https://crates.io/crates/hop-mesh-core) /
libhop /
[@hop-mesh/wasm](https://www.npmjs.com/package/@hop-mesh/wasm).
The in-tree crate is hop-core, published under the hop-mesh- prefix. The Android SDK is not published
yet, and libhop is the C ABI it exposes, not a separate release.

## License

[Apache-2.0](./LICENSE.md), embed it freely. The protocol core it binds (`hop-core`) stays
FSL-1.1-ALv2, source-available and converting to Apache-2.0 after two years.
