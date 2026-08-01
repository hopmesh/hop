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
```

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
for types only. The native halves are compiled by a consuming app's build, not in this package's CI
(same shape as the other client SDKs: the native artifact is provided by the platform SDK, here the
`hop-sdk-apple` Swift package and the `sh.hop:hop` AAR). Keep the surface in sync with `sdk/apple`
`Sources/Hop/Hop.swift` and `sdk/android` `src/main/kotlin/sh/hop/Hop.kt`.

## Do not

- Do not add em-dashes or en-dashes anywhere (repo-wide law; the token guard scans this subtree).
- Do not let `node.ts`/`base64.ts`/`types.ts` import `react-native` at the top level, or the unit tests
  stop running under Node.
