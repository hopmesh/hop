# bearers/

Per-platform transport packages. A bearer moves opaque bytes between two `LinkId`s; the core never sees
the radio. Each is an independent package so an app pulls in only the transports it wants.

```
bearers/apple/HopBearerBle         BLE (GATT for the PSM handshake + L2CAP for data + iBeacon wake)
bearers/apple/HopBearerLan         LAN (mDNS _hoplan._tcp + TCP)
bearers/apple/HopBearerRelay       relay TCP/WS
bearers/apple/HopBearerMeshtastic  Meshtastic/LoRa (relay through a connected Meshtastic radio's mesh)
bearers/android/bearer-{ble,lan,relay,meshtastic}   the Android equivalents (+ hop-sdk, the shared sh.hop source)
```

## The Meshtastic bearer is a datagram/tiny-MTU/lossy transport, not a byte stream

Unlike BLE/LAN (byte-stream links a length prefix deframes), the Meshtastic bearer relays through a
connected Meshtastic LoRa radio: a datagram mesh of ~200-byte packets that hop from radio to radio. So a
Hop link frame (a HELLO, or a DATA carrying a sealed record) does NOT fit one packet and is FRAGMENTED
into `MESH_MAX_CHUNK`-sized pieces, each shipped as one Meshtastic `MeshPacket` on a private app port
(`MESH_HOP_PORTNUM`, in the PRIVATE_APP 256..511 range), and REASSEMBLED on the far side keyed by
(sender node, message id). It reuses the SAME Hop link-frame grammar (HELLO/PING/PONG/DATA) as the LAN
bearer, so the consumer sees identical linkUp/linkBytes/linkDown. LoRa is slow and duty-cycle limited,
so the keepalive is lazy (30 s ping, 180 s dead); Hop's delay-tolerant design suits it.

Hop does not ride PRIMARY. On connect the bearer asks for a channel via `AdminMessage.get_channel`
(ADMIN_APP port 6, with `session_passkey` on any set), takes the first free SECONDARY slot (or an
existing slot already named Hop), writes a Hop-owned PSK/name, and puts every port-260 packet on that
index. PRIMARY stays whatever Meshtastic.app configured. Two Hop phones interoperate because they share
that PSK, not because the user scanned a QR.

Meshtastic does not store-and-forward by default, so fire-and-forget LoRa cannot carry Hop. Unicast
DATA and unicast HELLO set MeshPacket.want_ack (firmware may ACK/NAK on ROUTING_APP port 5). That ACK
is per MeshPacket fragment. The bearer also sprays the whole Hop frame with exponential backoff
(2s, doubling, cap 60s, never gives up while the link is up) until the peer sends Hop M_ACK (0x04)
carrying the frame msgId. Broadcast HELLO, PING/PONG, and M_ACK itself are not sprayed. The protobuf
codec, fragmentation, reassembly, and the spray state machine are pure and unit-tested against a fake
radio; only the CoreBluetooth / Android-GATT connection is device-bound and excluded from coverage.
The cross-platform wire contract is pinned in `bearers/meshtastic-vectors.json` and enforced by
`tools/meshtastic-parity.sh` (see below).

## Publishing (both platforms, and the switch that decides it)

A component publishes **iff `<prefix>/.github/workflows/release.yml` exists**. `tools/release/plan.py`
skips every component without one, so the file IS the switch, and its absence is silent: nothing warns,
nothing fails, the component is simply never tagged. `bearers/android` had no such file, so every Apple
bearer shipped for two releases while the Android bearers existed only as source, and
`bearers/android/README.md` advertised `sh.hopme.bearers:bearer-ble`, a coordinate nothing had ever
published to. If you add a component and expect it to ship, check `python3 tools/release/plan.py` lists
it; that command is the whole truth about what releases.

Both bearer trees lost their `release.yml` when the public mirrors were retired, so neither publishes
today: `python3 tools/release/plan.py` now lists only the three SDKs package managers still require
(apple, crystal, go). Consumers take the bearers as in-tree siblings instead, per each README's Install
section. The machinery below is dormant rather than deleted, because it is the shape a future release
would take.

- **Apple** would ship through SwiftPM, whose channel is the version tag, and its `release.yml` globbed
  `*/Package.swift`, so a NEW bearer package needed no config change to be validated and released.
- **Android** would ship to Maven Central as `sh.hop.bearers:bearer-<transport>`, one AAR per bearer.
  The publishing convention lives in `bearers/android/build.gradle.kts` and applies to every `bearer-*`
  module, so a new bearer is covered the moment it is in `settings.gradle.kts`. `sh.hop.bearers` is a
  SUBGROUP of the `sh.hop` namespace `sdk/android` already verified with Central, and Central's
  verification covers a verified root's subgroups, so it needs no separate ownership proof. That is
  precisely what ruled out the READMEs' old `sh.hopme.bearers`: hopme.sh is a different root domain and
  would have needed its own verification. The Kotlin package names (`sh.hopme.bearers.*`) are unrelated
  to Maven coordinates and are unchanged.

Two Android-specific traps, both already paid for:

- **The POM is authored, not generated, and Gradle metadata is disabled.** These module dirs compile
  under BOTH gradle builds and depend on `project(":hop-sdk")`, an in-tree shim that recompiles
  `sdk/android`'s source and never publishes. A generated POM names that shim as a coordinate no
  consumer can resolve, and the generated `.module` did exactly that (`hop-sdk:unspecified`) while
  Gradle consumers PREFER `.module` over the POM. So the dependency list is derived from each module's
  real `implementation` configuration with the shim rewritten to `sh.hop:hop`, and `.module` is off.
- **Reaching outside `bearers/android` is no longer conditional.** The shim's shared source and the
  `:hop-driver` include both point outside this subtree, and both used to detect which tree they were
  in, because the subtree was exported to a mirror where those paths did not exist. With that mirror
  retired both are unconditional, and the monorepo is the only tree they have to work in.

Neither driver publishes either. The Android one (`drivers/android/hop-driver`) never did: it reads its
UniFFI bindings from the APP's generated dir, so publishing it would need that resolved first.

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

The Meshtastic bearer is the second instance of this pattern: `bearers/meshtastic-vectors.json` is
canonical and `tools/meshtastic-parity.sh` (self-tested by `tools/meshtastic-parity.test.sh`, both in
the `automation` job) fails if Apple's `MeshtasticWire.swift` and Android's `MeshtasticWire.kt` stop
agreeing on the port, chunk size, fragment-header layout, frame tags, or keepalive timing. It pins
decision points too, not only numbers: it asserts the port stays inside the Meshtastic PRIVATE_APP
range (a first-party port would collide with real Meshtastic apps on the shared mesh) and recomputes
the fragment-count vectors from `max_chunk` so a chunk-size change that silently reshapes every packet
reddens CI. This table existed BEFORE the two implementations could diverge, which is the whole point:
the BLE table was written after a divergence bug shipped, and this one is the cheaper version of that
lesson applied up front.

## The Apple BLE radio lifecycle is guarded structurally, because it cannot be tested

`Central`/`CentralCore` and `Peripheral`/`PeripheralCore` are owned exclusively by `bleQueue` and
therefore hold NO locks, and the bearer's STATUS timer lives on `bleRunLoop`, which has CFRunLoop
thread affinity. No test can prove that: CoreBluetooth has no headless support and its delegate
argument types have no public initializers, so `swift test` cannot construct either shell. Reverting
all three of PLAT-002's threading controls left `HopBearerBle` at 117 tests, 0 failures, which is what
an unguarded fix looks like.

`tools/ble-threading-guard.sh` (self-tested by `tools/ble-threading-guard.test.sh`, both in the
`automation` CI job) is the gate: it brace-matches `BleBearer.start()`/`stop()` and fails if the CB
shells are constructed or torn down before the `bleQueue` hop, if a `Timer` is scheduled or
invalidated without hopping to `bleRunLoop`, or if `markStopped()` moves after the dispatch. It fails
CLOSED when its anchors go missing rather than passing vacuously.

Note what the APPLE `BleBearer.stop()` does and does not promise, because the two platforms differ
here. It stops the bearer as a LINK SOURCE synchronously (`markStopped()` runs before anything is
dispatched, so nothing can be adopted or surfaced afterwards) but its RADIO teardown is deferred to
`bleQueue`: the advertiser, the published GATT service and the scanner keep running until that block
drains. `bleQueue` defaults to `.main` and is assigned by the host, so a `sync` hop would deadlock and
there is no portable way to detect already-being-on-it. Android's `stop()` is synchronous by contrast:
`stopScan`, `stopAdvertisingSet` and the GATT/server closes all run on the caller's thread. So
`BearerManager.setEnabled(tag,false)` promises only the link-source half on both platforms, which is
the weaker of the two behaviours; a host that needs true radio silence as a postcondition has to get
it from the platform.

## Closed: the dead framing layer in link.rs is gone

`core/hop-core/src/link.rs` is listed in `core/hop-core/vectors/wire-source-manifest.txt`, so
deleting even dead code from it trips the wire-version guard. That was the reason this section
existed as a DEFERRAL, parked behind the sentence "delete all of it at the next real wire bump".
That sentence is a prose intention, not a trigger, and it went unhonoured twice, the same failure
that got the dash-guard manifest carve-out retired (audit PROC-001). It went unhonoured a third
time inside the v13 to v14 bump that indicted the pattern, which is when it was finally paid.

Deleted in the v13 to v14 bump, all of it:

- `link::Bearer`, which never had an in-tree implementor. The real transport seam is `BearerEvent`
  pumped over the C ABI, and that is what remains in `link.rs`.
- the entire generic fragmentation layer: `Frame`, `fragment`, `Reassembler`, and the four
  `MAX_FRAME_*` / `MAX_REASSEMBLED_BUNDLE_BYTES` bounds, plus the four tests that exercised only
  them. Record splitting is and was done by `wire_emit::frame_record` into `LinkPacket::DataFrag`
  (reassembled by `Node::on_record_frag`), which `wire_emit.rs` itself calls "the ONLY place record
  framing is decided".
- the `Frame` corpus vector in `wire_vectors.rs`, which was pinning the byte layout of a type
  nothing emitted and would otherwise have kept the dead code alive on its own. Regenerating the
  corpus removed exactly that one entry and moved no other byte, which is the proof the deletion
  was wire-neutral.
- the three stale spray-and-wait comments in `bundle.rs`, which described `Envelope.copies` as a
  live copy budget. They now say what DESIGN.md §6 says: reserved wire capacity the router never
  reads.

**The lesson, for the next deferral anyone is tempted to write here:** do not name a trigger in
prose. Either do the work in the commit that notices it, or attach the deferral to something
mechanical that fails when the condition arrives. A note in a CLAUDE.md is read by whoever happens
to open the file, which is not the same person as whoever performs the trigger.

## Note

`bearers/android/` is its own gradle build, separate from the app's, but the two share module dirs
(`hop-sdk`, `bearer-{ble,lan,relay}`, `drivers/android/hop-driver`), so their toolchains are pinned
TOGETHER: AGP 9.3.1 + Gradle 9.6.1 + Kotlin 2.4.10. Bump both or neither. See
`apps/android/CLAUDE.md`. Coverage tests can flake if a test races real dial/accept timing without an
ordering barrier (pass-18 F-3); pin the ordering, do not sleep.
