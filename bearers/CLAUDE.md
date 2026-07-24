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

## The parity problem (bearers have no shared core)

Bearers are per-platform packages that deliberately do NOT link libhop (`import HopContract // no
libhop`), so nothing forces Apple and Android to agree the way one Rust core forces the rest of Hop to.
That freedom already cost a real bug: the dial-backoff schedule diverged, Android moved to count-based
growth after finding the delta-based version reset to its floor every cycle (a 12s dial timeout always
outlasts a sub-2s window, so an unreachable advertiser re-dialed every ~13s forever and starved healthy
peers), and Apple silently kept the broken one.

The substitute for a shared core is a pinned vector table plus a guard:
`bearers/ble-backoff-vectors.json` is canonical, and `tools/ble-backoff-parity.sh` (self-tested by
`tools/ble-backoff-parity.test.sh`, both run in the `automation` CI job) fails if either
implementation's constants stop matching. **Any policy a bearer implements on both platforms belongs
in that table.** Do not rely on review to catch cross-platform drift; it already did not.

## Note

`bearers/android/` is its own gradle build (AGP 8.5.2), separate from the app's (AGP 9.x). See
`apps/android/CLAUDE.md`. Coverage tests can flake if a test races real dial/accept timing without an
ordering barrier (pass-18 F-3); pin the ordering, do not sleep.
