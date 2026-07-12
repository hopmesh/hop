# bearers/

Per-platform transport packages. A bearer moves opaque bytes between two `LinkId`s; the core never sees
the radio. Each is an independent package so an app pulls in only the transports it wants.

```
bearers/apple/HopBearerBle    BLE (GATT for the PSM handshake + L2CAP for data + iBeacon wake)
bearers/apple/HopBearerLan    LAN (mDNS _hoplan._tcp + TCP)
bearers/apple/HopBearerRelay  relay TCP/WS
bearers/android/bearer-{ble,lan,relay}   the Android equivalents (+ hop-sdk, the shared sh.hop source)
```

## Testability + coverage

- The pure link/dedup/handshake logic is extracted into headlessly-testable cores (CentralCore,
  PeripheralCore, DialState, the LanLink framing) and covered under an 80% floor. The RADIO glue
  (CoreBluetooth / L2CAP runloop / CoreLocation wake on Apple; the BLE radio on Android) cannot run in
  CI and is EXCLUDED from the coverage denominator, covered by the on-device workflow instead.
- BLE reliability follows the Ditto design: GATT carries only the PSM handshake, DATA never rides GATT.
  Advert-only / zero-GATT L2CAP is not accepted by Android. Prototype BLE changes in `apps/ble-lab` on
  fresh hardware first.
- Dedup routes through the pure keep-rule cores; the tiebreaker is an unbiased random id, never a MAC.

## Note

`bearers/android/` is its own gradle build (AGP 8.5.2), separate from the app's (AGP 9.x). See
`apps/android/CLAUDE.md`. Coverage tests can flake if a test races real dial/accept timing without an
ordering barrier (pass-18 F-3); pin the ordering, do not sleep.
