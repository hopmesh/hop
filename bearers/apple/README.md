<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop Bearers for Apple</h1>

<p align="center">
  <b>The radios Hop rides on iOS and macOS: BLE, LAN, and cloud relay, as independent Swift packages.</b><br>
  Each bearer moves opaque bytes between two peers and conforms to one small contract, so a node plugs in only the transports it wants.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/platforms-iOS%2016%20%C2%B7%20macOS%2013-1f6feb" alt="iOS 16 · macOS 13">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license Apache-2.0">
</p>

---

Hop is a **delay-tolerant, end-to-end-encrypted mesh**: messages hop device to device over BLE, Wi-Fi,
and the internet until they reach the person or service you meant. Held, never dropped.

**Hop Bearers for Apple is the transport layer.** Independent SwiftPM libraries (BLE, LAN, cloud relay,
Meshtastic/LoRa) each discover peers, form links, and shuttle application bytes, and each implements the
same tiny `Bearer` / `LinkSink` contract. The bearer owns the radio and its own dedup; the core never
sees a socket, and you pull in only the pipes you need.

## What's in the box

| Product          | Transport   | How it works                                                        |
| ---------------- | ----------- | ------------------------------------------------------------------- |
| `HopBearerBle`        | BLE         | GATT carries the PSM handshake, L2CAP carries data, iBeacon wakes a killed app |
| `HopBearerLan`        | Wi-Fi / LAN | mDNS `_hoplan._tcp` discovery over TCP                              |
| `HopBearerRelay`      | Internet    | one outbound WebSocket to a relay (`URLSession`, no inbound port)   |
| `HopBearerMeshtastic` | LoRa mesh   | relays through a connected Meshtastic radio: fragments frames into mesh packets on a private app port |

## Install

### Outside the Hop monorepo

**Not available yet.** The bearers are configured to publish as one SwiftPM package,
`hop-bearers-apple`, and the manifest in this directory is that package, but the repository
`https://github.com/hopmesh/hop-bearers-apple` DOES NOT EXIST: it was retired in 2026-08 and the
config that brings it back landed without the repository being recreated (creating one is a human
action, `tools/copybara/bootstrap-mirrors.sh`, followed by a seeded export). A `dependencies:` entry
naming that URL fails to resolve today, so it is deliberately not written here as if it worked.

Until the mirror exists, an app outside this tree takes the radios by vendoring `bearers/apple` (this
directory, whose root `Package.swift` declares all five products) or by depending on this repository
directly. The shape the mirror will take, once it is real, is one package with five products, one per
transport, resolved by version tag. `docs/repo-catalog.md` records the current state, and
`tools/copybara/README.md` describes what has to happen for it to change.

Multipeer (`HopBearerMultipeer`) is the fifth product of the same package, same shape.

### CocoaPods

`HopBearerBle.podspec`, `HopBearerLan.podspec`, and `HopBearerRelay.podspec` describe the native
modules for local integration and are checked with `pod ipc spec`. They are not published through
CocoaPods: the bearer mirror does not exist and no bearer version has been released through CocoaPods,
so a standard `pod 'HopBearerBle'`, `pod 'HopBearerLan'`, or `pod 'HopBearerRelay'` declaration cannot
resolve today.

Each spec exposes only its matching bearer source tree and depends only on `HopContract`, never
`HopSDK` or `CHop`. The HopContract compatibility range comes from this directory's aggregate
`Package.swift`, which is the exported SwiftPM manifest.

### Inside the Hop monorepo

Each bearer is its OWN package, and in-tree consumers (the demo apps, `drivers/apple/HopDriver`) take
one path dependency per transport against the per-bearer `Package.swift` files, which depend on
`sdk/apple` by path (the `../` depth below is from `drivers/apple/HopDriver`, adjust for wherever yours
sits):

```swift
dependencies: [
    .package(path: "../../../bearers/apple/HopBearerBle"),
    .package(path: "../../../bearers/apple/HopBearerLan"),
    .package(path: "../../../bearers/apple/HopBearerRelay"),
    .package(path: "../../../bearers/apple/HopBearerMeshtastic"),
]
```

Each bearer depends only on the Hop SDK's `HopContract` (pure Swift, no `libhop`), so adding a bearer
never double-links the Rust core.

## Usage

Register the bearers you want with a `BearerManager` (one `LinkId` space across every radio) and give
it a sink. That's the whole seam:

```swift
import HopContract      // the Bearer / LinkSink contract, shipped with the Hop SDK
import HopBearerBle
import HopBearerLan
import HopBearerRelay
import HopBearerMeshtastic

let myId = BleBearer.randomNodeId()          // 16 random bytes, stable for the process

let mesh = BearerManager()
mesh.register(BleBearer(myId: myId))         // GATT PSM handshake, L2CAP data, iBeacon wake
mesh.register(LanBearer(myId: myId))         // mDNS _hoplan._tcp + TCP
mesh.register(RelayBearer(relayURL: "wss://relay.hopme.sh/"))
mesh.register(MeshtasticBearer(myId: myId))  // relay through a connected Meshtastic LoRa radio

mesh.sink = myConsumer                        // gets linkUp / linkBytes / linkDown
mesh.start()

// later, send opaque bytes on a live link; the core owns every byte of crypto
mesh.send(packet, on: linkId)
```

In a real app the sink is a Hop node: `HopRuntime` (in the Hop SDK) wires a `BearerManager` to a
`hop-core` node so every link drives the node and the node's outbound packets route back to the owning
bearer. If you're building your own client, conform to the contract directly.

## The contract

A bearer names nothing about BLE, Wi-Fi, or sockets. It reports three things and accepts `send`:

```swift
public protocol LinkSink: AnyObject {
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data)
    func linkBytes(_ link: LinkId, _ bytes: Data)
    func linkDown(_ link: LinkId)
}

public protocol Bearer: AnyObject {
    var sink: LinkSink? { get set }
    var transportName: String { get }   // short UI tag: "BT" / "LAN" / "Relay"
    func start()
    func stop()
    func send(_ bytes: Data, on link: LinkId)
}
```

The Noise XX handshake that authenticates both ends lives inside the node, not the bearer, so a bearer
carries ciphertext it can't read.

## Status

Prototype. The pure link, dedup, and handshake logic (dial tiebreaker, keep-rule, deframing, backoff,
the 429 Retry-After parse) is extracted into headless cores and unit-tested under an 80% floor. The
radio glue that CI can't run (CoreBluetooth, the L2CAP runloop, the CoreLocation background wake) is
excluded from the coverage denominator and exercised on real hardware instead. BLE reliability follows
the Ditto design: GATT only for the PSM handshake, data always on L2CAP.

## The Hop family

Hop is one protocol with many faces. The endpoint SDKs, same surface in your language:
[node](https://www.npmjs.com/package/@hop-mesh/endpoint) ·
[python](https://pypi.org/project/hop-endpoint/) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://rubygems.org/gems/hop-endpoint) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://hex.pm/packages/hop_endpoint) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
android.
The protocol core is [hop-mesh-core](https://crates.io/crates/hop-mesh-core), which is the in-tree
`hop-core` crate under its published name, plus libhop.
The unlinked ones live in the Hop monorepo and aren't separately published yet.

## License

[Apache-2.0](./LICENSE.md), use it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
