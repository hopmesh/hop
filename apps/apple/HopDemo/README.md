# HopDemo — iOS/iPadOS chat (first real hops)

A SwiftUI chat app running a `HopNode` over a foreground CoreBluetooth + L2CAP
bearer. Put it on two or three Apple devices and messages cross over real Bluetooth,
with the middle device relaying when the ends are out of range.

This app **builds for the iOS simulator in CI here** (`xcodebuild … BUILD SUCCEEDED`),
so the Swift is verified to compile and link against the Rust library. Real Bluetooth
needs the devices.

## Build the project

```sh
./tools/build-xcframework.sh        # → apple/generated/{HopFFI.xcframework, Sources/hop.swift}
cd apple/HopDemo && xcodegen        # → HopDemo.xcodeproj (gitignored; brew install xcodegen)
open HopDemo.xcodeproj
```

In Xcode: select the **HopDemo** target → **Signing & Capabilities** → pick your team
(free dev signing is fine for devices in developer mode). Then run on each device.

The Bluetooth usage string and Info.plist are generated from `project.yml`.

## Use it

1. Launch on **iPhone A** and **iPhone B** (and the **iPad** for a relay test), grant
   the Bluetooth prompt.
2. Each device lists the others under **People nearby**, by device name — discovered
   over the mesh (gossip, so it works through a relay too).
3. Tap a person → type → **Send**. It appears in their chat.

The round-trip exercises the whole stack on real hardware: BLE discovery → L2CAP
channel → **Noise XX handshake** (mutual key auth) → sealed bundle → deliver → ACK
back (clears the sender's pending entry, since `requestAck` is on).

### Relay (three devices)

Put A and B out of Bluetooth range of each other but both near the **iPad** in the
middle. A still sees B under "People nearby" (its name gossiped via the iPad), and a
message A→B is **relayed through the iPad** — no direct A↔B link. That's spray-and-wait
+ store-and-forward doing its job (proven in Rust by `relays_across_an_intermediate_node`
and `discover_named_peer_two_hops_away_and_message_it`).

## Files

- `HopBearer.swift` — dual-role CoreBluetooth + L2CAP, wired to `HopNode`.
- `HopLink.swift` — length-prefixed framing over the L2CAP stream.
- `ContentView.swift` — the chat UI.
- `HopDemoApp.swift` — app entry point.
- `project.yml` — XcodeGen spec (pulls in the generated binding + XCFramework).

## Notes / next

- Foreground only for now; iOS background BLE (DESIGN.md §11) is a deliberate follow-up.
- Both devices run as central *and* peripheral, so a link may form in each direction;
  the app de-dups peers. Fine for a demo.
- The bearer is intentionally thin — only `connected` / `received` / `drainOutgoing` /
  `tick`. All protocol logic stays in `hop-core`.
