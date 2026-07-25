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

It cost a SECOND bug, found by audit right after: Android also moved the backoff RESET from
L2CAP-open to HELLO-complete (android-05/06), because a peer that accepts a channel and never says
HELLO must keep accruing backoff. Apple never got that either, which pinned its `failCount` at 1
forever for that peer and made the growth curve and the quarantine unreachable for exactly the peer
they exist to park. A schedule is only as strong as its reset point, and constants alone can never
catch a wrong one.

The substitute for a shared core is a pinned vector table plus a guard:
`bearers/ble-backoff-vectors.json` is canonical, and `tools/ble-backoff-parity.sh` (self-tested by
`tools/ble-backoff-parity.test.sh`, both run in the `automation` CI job) fails if either
implementation's constants stop matching, AND (via `reset_on`) structurally asserts that neither
platform clears the failure state at L2CAP-open and both do at HELLO-complete. It fails CLOSED if
`reset_on` is absent, because a check that silently does nothing reads as coverage.

**Any policy a bearer implements on both platforms belongs in that table**, and pin the DECISION
POINTS, not only the numbers. Do not rely on review to catch cross-platform drift; it already did
not, twice.

## Deferred: dead code inside wire-manifest files

`core/hop-core/src/link.rs` is listed in `core/hop-core/vectors/wire-source-manifest.txt`, so
deleting even dead code from it trips the wire-version guard and would force a `BUNDLE_VERSION` bump
for a change that moves no bytes. Same carve-out the dash ban already uses for manifest files. What
is parked in there is larger than the one trait this note used to name:

- `link::Bearer` has never had an in-tree implementor: the real transport seam is `BearerEvent`
  pumped over the C ABI.
- The entire generic fragmentation layer is unreached in production: `Frame`, `fragment`,
  `Reassembler`, and the four `MAX_FRAME_*` / `MAX_REASSEMBLED_*` bounds. Record splitting is done
  by `wire_emit::frame_record` into `LinkPacket::DataFrag` (reassembled by `Node::on_record_frag`),
  which `wire_emit.rs` itself calls "the ONLY place record framing is decided". `node.rs` imports
  nothing from `link` beyond `BearerEvent`, `LinkHandshake`, `LinkId`, `LinkSession`, and `Role`.
- `Frame`'s one remaining consumer is `wire_vectors.rs`, a corpus entry pinning the byte layout of a
  type nothing emits. Retire that vector in the same bump or it keeps the dead code alive by itself.

Delete all of it at the next real wire bump, along with the three stale spray-and-wait comments in
`bundle.rs`.

## Note

`bearers/android/` is its own gradle build, separate from the app's, but the two share module dirs
(`hop-sdk`, `bearer-{ble,lan,relay}`, `drivers/android/hop-driver`), so their toolchains are pinned
TOGETHER: AGP 9.3.1 + Gradle 9.6.1 + Kotlin 2.4.10. Bump both or neither. See
`apps/android/CLAUDE.md`. Coverage tests can flake if a test races real dial/accept timing without an
ordering barrier (pass-18 F-3); pin the ordering, do not sleep.
