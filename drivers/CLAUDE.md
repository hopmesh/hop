# drivers/

The per-platform, app-facing client. A driver owns the `hop-core` node, wires up the platform bearer
packages, persists via the platform store, and exposes an ergonomic surface the app binds. This is the
"driver" layer (not "harness"): the thin waist between the app and the shared core.

```
drivers/apple/HopDriver      Swift: the node + bearers + messaging/HNS/hps surface for HopDemo
drivers/android/hop-driver   Kotlin: the same, consumed by apps/android/HopDemo
```

## Testability seam

Drivers are unit-tested headlessly by injecting a fake node behind a seam instead of a real libhop +
radio: `HopNodeInterface` + `FakeHopNode` (Android, Robolectric) and the analogous Swift seams
(`resolveHnsForTest` etc.). Production leaves the seam nil / uses the real node, so behavior is
unchanged. When a code path can only be reached through a live peer or radio, add a minimal
behavior-preserving seam so it can be driven, rather than leaving it uncovered.

## Coverage

Both drivers gate an aggregate floor AND a PER-FILE floor (so no single untested file hides behind the
average, pass-17 F). The Apple floor parses `llvm-cov export` JSON (`tools/cov-floor-gate.py`), not a
positional column. Device/thread-bound files (the radio layer, L2CAP runloop, Keychain/StrongBox) are
excluded from the denominator and covered by the on-device workflow.

## Gotcha

`drivers/android/hop-driver` reads its UniFFI bindings + native libs from the APP's generated dir
(`../../../apps/android/HopDemo/generated`), produced by CI. That is a deliberate back-reference; keep
the path in sync if either side moves.
