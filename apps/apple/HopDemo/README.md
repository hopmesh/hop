# HopDemo: iOS/iPadOS chat (first real hops)

A SwiftUI chat app running a `HopNode` over a foreground CoreBluetooth + L2CAP
bearer. Put it on two or three Apple devices and messages cross over real Bluetooth,
with the middle device relaying when the ends are out of range.

This app **builds for the iOS simulator in CI here** (`xcodebuild … BUILD SUCCEEDED`),
so the Swift is verified to compile and link against the Rust library. Real Bluetooth
needs the devices.

## Build the project

```sh
./tools/build-xcframework.sh                          # → drivers/apple/HopDriver/{Frameworks/HopFFI.xcframework,
                                                      #    Sources/HopFFIBindings/hop.swift}
cp sdk/apple/Package.local.swift sdk/apple/Package.swift   # REQUIRED, see below
cd apps/apple/HopDemo && xcodegen                     # → HopDemo.xcodeproj (gitignored; brew install xcodegen)
open HopDemo.xcodeproj
```

**The `Package.swift` swap is not optional.** The committed `sdk/apple/Package.swift` is the
*published* manifest: it resolves `CHop` from a release asset on `hopmesh/hop-sdk-apple`. That
release does not exist yet, so package resolution fails outright with a 404 on
`libhop.xcframework.zip` and nothing builds. `Package.local.swift` points at the artifact you just
built instead. CI does exactly this swap (`.github/workflows/ci.yml`), so it is the supported path,
not a workaround. Restore the remote manifest before committing.

In Xcode: select the **HopDemo** target → **Signing & Capabilities** → pick your team. The
Bluetooth usage string and Info.plist are generated from `project.yml`.

### Known blocker: device builds fail signing

Building for a real device currently fails with:

```
Provisioning profile "iOS Team Provisioning Profile: sh.hopme.demo" doesn't match the entitlements
file's value for the com.apple.developer.default-data-protection entitlement.
```

The App ID grants `NSFileProtectionComplete`; `HopDemo.entitlements` requests
`NSFileProtectionCompleteUntilFirstUserAuthentication`. **The app is right.** `Complete` denies
writes while the device is locked, which would re-open the background-delivery history gap that
entitlement exists to close (see the comment in `HopDemo.entitlements`). Do not "fix" this by
weakening the entitlement. The fix is to set that App ID's Data Protection capability to
"Protected Until First User Authentication" in the developer portal. Until then the simulator
builds fine and the Apple packages are covered by `swift test` and CI, but nothing runs on a radio.

## Use it

1. Launch on **iPhone A** and **iPhone B** (and the **iPad** for a relay test), grant
   the Bluetooth prompt.
2. Each device lists the others under **People nearby**, by device name, discovered
   over the mesh (gossip, so it works through a relay too).
3. Tap a person → type → **Send**. It appears in their chat.

The round-trip exercises the whole stack on real hardware: BLE discovery → L2CAP
channel → **Noise XX handshake** (mutual key auth) → sealed bundle → deliver → ACK
back (clears the sender's pending entry, since `requestAck` is on).

### Relay (three devices)

Put A and B out of Bluetooth range of each other but both near the **iPad** in the
middle. A still sees B under "People nearby" (its name gossiped via the iPad), and a
message A→B is **relayed through the iPad**, no direct A↔B link. That's the epidemic forward
+ store-and-forward doing its job (proven in Rust by `relays_across_an_intermediate_node`
and `discover_named_peer_two_hops_away_and_message_it`).

## Files

The app is UI only. Every radio and protocol concern lives outside it, in
`drivers/apple/HopDriver` (the node + bearer glue) and `bearers/apple/HopBearer{Ble,Lan,Relay}`.

- `ContentView.swift`, the chat UI.
- `HopDemoApp.swift`, app entry point.
- `HopWebView.swift`, the embedded web view.
- `QRViews.swift`, address QR display and scanning.
- `HopDemo.entitlements`, the at-rest file-protection class (read the comment before changing it).
- `project.yml`, XcodeGen spec (pulls in HopDriver, the generated binding, and the XCFramework).

## Notes / next

- Background BLE ships. `project.yml` declares `bluetooth-central`, `bluetooth-peripheral`,
  `location`, `fetch` and `processing` background modes, and `HopBearerBle/BeaconWake.swift`
  implements the iBeacon wake that revives a force-quit app (DESIGN.md §22). The beacon UUID must
  byte-match the Android side or the wake silently never fires.
- Both devices run as central *and* peripheral, so a link may form in each direction; the dedup
  keep-rule picks one, tie-broken on a random id.
- The app links no protocol code. `hop-core` is reached through the C ABI (`sdk/hop.h`), and the
  bearers deliberately do not link libhop at all.
