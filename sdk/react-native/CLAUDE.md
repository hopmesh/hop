# sdk/react-native

The **cross-platform React Native client SDK**: one TypeScript surface (`@hop-mesh/react-native`) over
the two native Hop client SDKs. On iOS it bridges `sdk/apple` (the Swift `Hop` product); on Android it
bridges `sdk/android` (the Kotlin `sh.hop` package, `sh.hop:hop` on Maven, which carries `libhop`). It
adds no protocol: it marshals values across the RN bridge and mirrors the native `HopNode` surface.

```
src/base64.ts   dependency-free base64 <-> bytes + utf8 helpers (the single JS encode/decode point)
src/types.ts    the public value types (HopMessage/HopStatus/service req+resp/open+send options)
src/native.ts   the bridge contract (HopNativeModule) + lazy react-native accessors + a test seam
src/node.ts     HopNode: one method per bridge call; takes native+emitter by injection (unit-testable)
src/index.tsx   the Hop factory (ephemeral/withSecret/open) + HopAddress; wires the real native module
ios/            HopMesh.swift (RCTEventEmitter wrapping the Swift HopNode) + HopMesh.m (RCT_EXTERN)
android/        HopMeshModule.kt (wraps the Kotlin HopNode) + HopMeshPackage.kt + build.gradle
HopMesh.podspec React-Core + the hop-sdk-apple Swift package (spm_dependency when supported)
.github/actions/ci  the composite action the ROOT ci.yml calls (this package's only gate)
```

## Not mirrored, not published (deliberate)

Unlike every other `sdk/*`, this one is monorepo-only: no `tools/copybara/components.json` entry, no
mirror repo, no `release.yml`, and `package.json` carries `"private": true` so a stray `npm publish`
cannot push it. The cross-platform approach is being reworked, so the package is not on npm and the
README says so. Two consequences worth holding onto:

- **The root `React Native SDK (typecheck + tests)` job is the ONLY gate.** The other SDKs get a second
  pass in their mirror's own CI; this one does not, so if that job is skipped or removed the package is
  unverified. It is wired through `changes.outputs.sdk_react_native` and listed in `gate.needs`.
- **Re-registering means more than adding a components.json line:** restore the mirror workflows
  (`ci.yml`, `release.yml`, `sync-back.yml`, `cla.yml`) plus `CLA.md`/`CONTRIBUTING.md`, drop
  `"private": true`, point the repository/homepage URLs back at the mirror, and bump the component
  count in `tools/package-export-smoke.test.sh`. See `docs/repo-catalog.md`.

## The bridge contract (keep all three sides in lockstep)

`src/native.ts` `HopNativeModule` is the source of truth for the JS <-> native surface. Every method is
implemented in BOTH `ios/HopMesh.swift` (+ the `RCT_EXTERN_METHOD` selector in `HopMesh.m`) and
`android/.../HopMeshModule.kt`. Change one, change all three, or a call silently no-ops on one platform.

- **Binary crosses as base64, addresses as base58.** The RN bridge only carries JSON scalars. Bodies,
  32-byte ids, and secrets are base64 strings; addresses are base58 strings (the native `HopAddress`
  helpers do the conversion so `send`/`isSecured` can take the human-facing form). `base64.ts` is the
  only JS place that touches the encoding.
- **Node handles are opaque integers** minted natively, one per `HopNode`. A persistent open that fails
  resolves `-1` (JS maps that to `null`), matching the native `open` returning nil on a bad path.
- **The core is poll-model.** Nothing is delivered until `start()` runs the native pump, which ticks,
  drains outbound (emitted as `HopMesh:outgoing` for a JS bearer), and polls inbox + hops:// queues,
  emitting one event per item. Events carry `node: <handle>` so `HopNode` filters to its own handle.

## Testability

`node.ts` and the pure helpers never import `react-native` at module top level (`native.ts` requires it
lazily). Tests inject a fake module via `__setHopNativeForTesting` and a fake emitter, so the whole JS
layer runs under plain Node. See `test/*.test.cjs`.

## Verify

`npm install` then `npm test` (runs `tsc` to `lib/` and the `node --test` suite). `npm run typecheck`
for types only. CI runs exactly this via `./sdk/react-native/.github/actions/ci`. The native halves are compiled by a consuming app's build, not in this package's CI
(same shape as the other client SDKs: the native artifact is provided by the platform SDK, here the
`hop-sdk-apple` Swift package and the `sh.hop:hop` AAR). Keep the surface in sync with `sdk/apple`
`Sources/Hop/Hop.swift` and `sdk/android` `src/main/kotlin/sh/hop/Hop.kt`.

## Do not

- Do not add em-dashes or en-dashes anywhere (repo-wide law; the token guard scans this subtree).
- Do not let `node.ts`/`base64.ts`/`types.ts` import `react-native` at the top level, or the unit tests
  stop running under Node.
