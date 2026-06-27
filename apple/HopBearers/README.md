# HopBearers

The cross-platform **transport layer** for Hop, as a standalone SwiftPM package shared verbatim by
the clean-room test harness and (next) the production app. A *bearer* forms links to peers and
shuttles bytes; a *consumer* turns those links into something useful (a proof-of-pipe pinger, or the
production HopNode). One transport, many consumers — a fix proven in the clean room is the app's fix
the moment it lands here, no hand fold-back.

Pure CoreBluetooth / Foundation. No Rust / hop-ffi dependency, so the clean room keeps building
standalone.

## The contract is the whole point

There is exactly **one interface, the same no matter the transport.** It names nothing about BLE,
Wi-Fi, sockets, or any radio:

```swift
public protocol Bearer: AnyObject {
    var sink: LinkSink? { get set }          // where this bearer reports link events
    func start()                             // begin forming links
    func stop()                              // tear everything down
    func send(_ bytes: Data, on link: LinkId)// queue one app frame on a link
}

public protocol LinkSink: AnyObject {
    func linkUp(_ link: LinkId, role: LinkRole, peerId: Data)  // a link is up + identity-verified
    func linkBytes(_ link: LinkId, _ bytes: Data)             // one app DATA frame arrived
    func linkDown(_ link: LinkId)                             // link gone — drop per-link state
}
```

A bearer owns everything transport-specific **internally** — discovery, dialing, framing, keepalive,
liveness/watchdog, one-pipe-per-peer dedup, redial/backoff — and only ever surfaces `linkUp` /
`linkBytes` / `linkDown`. The consumer keys all its state on `LinkId`, never on a peripheral handle or
MAC. Keepalive/PING traffic stays inside the bearer and never reaches the consumer.

## Writing a new bearer

1. Implement `Bearer`. Mint your own `LinkId` per (re)connection (start from 1 — the manager keeps
   bearers from colliding, see below). Drive your `sink` on link up/bytes/down.
2. `register(_:)` it with a `BearerManager`. Done. Nothing else in the system needs to know it exists.

```swift
final class LanBearer: Bearer {   // sketch — TCP/mDNS instead of CoreBluetooth
    weak var sink: LinkSink?
    func start() { /* browse + listen */ }
    func stop()  { /* close sockets */ }
    func send(_ bytes: Data, on link: LinkId) { /* write framed bytes */ }
    // on accept/connect + handshake: sink?.linkUp(localId, role:, peerId:)
    // on inbound frame:               sink?.linkBytes(localId, payload)
    // on close:                       sink?.linkDown(localId)
}
```

## BearerManager — the registry

The consumer talks to a `BearerManager`, not to individual bearers. The manager **is itself a
`Bearer`**, so the whole transport layer is driven through the same interface as one bearer:

```swift
let mgr = BearerManager()
mgr.register(BleBearer(myId: myId))
mgr.register(LanBearer(...))      // any future Bearer registers identically
mgr.sink = myConsumer             // links from ALL bearers surface here, in ONE id space
mgr.start()                       // fans out to every registered bearer
```

What it does, purely in terms of the contract (no transport types cross the boundary):

- **Fan-out** — `start()` / `stop()` reach every registered bearer; `send(_:on:)` routes to the
  bearer that owns the link.
- **One link-id space** — each bearer mints its own local `LinkId`s (both starting at 1, so they'd
  collide), and the manager translates each into a process-global `LinkId`. The consumer sees a single
  id space regardless of which radio a link rode in on.

This multiplexing is proven deterministically (no radio) in `Tests/HopBearersTests` — colliding local
ids → distinct globals, correct send-routing, up/bytes/down translation, linkDown cleanup.

## What's in the box

| Target | Role |
| --- | --- |
| `HopBearers` (library) | `Bearer`/`LinkSink` contract, `BearerManager` registry, `BleBearer` transport |
| `blepeer` (executable) | clean-room "proof of pipe" consumer — pings over DATA frames, logs `HOPLAB … PROOF …` |
| `HopBearersTests` | deterministic registry tests |

`BleBearer` is the clean-room BLE transport (ble-lab/SPEC.md) re-seamed behind `Bearer`: dual-role
(advertise + scan), GATT-read PSM, L2CAP for data, 4-byte BE framing, 1 Hz keepalive + adaptive
watchdog, HELLO identity handshake, greater-nodeId dedup, and the redial-storm fix. Wire format is
preserved byte-for-byte so a HopBearers node interops with un-refactored Android / hopmac peers.

### Host hooks (iOS)

`BleBearer` defaults everything to `.main` (the macOS CLI, where no UI contends). An iOS app sets,
before `start()`:

- `bleQueue` → a dedicated serial `DispatchQueue` (CoreBluetooth callbacks),
- `bleRunLoop` → a long-lived I/O thread's `RunLoop` (streams + timers),
- `bleAppInBackground` ← `scenePhase`,

and calls `bearer.wake(_:)` from the AppDelegate on a CoreLocation region wake.

## Build / test

```sh
swift build                 # library + blepeer (macOS host)
swift test                  # registry tests
swift run blepeer           # run the clean-room pinger (needs BLE permission)
# iOS library build:
xcodebuild build -scheme HopBearers -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```
