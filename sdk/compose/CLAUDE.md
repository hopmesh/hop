# sdk/compose

Hop for Compose Multiplatform: the UI-layer SDK. Where `sdk/android` hands you a raw `HopNode`, this
package hands you a reactive `HopClient` plus Compose Multiplatform composables, so one Kotlin codebase
renders a mesh messenger on Android, Desktop (JVM), and iOS.

## The seam (why this is not "just the Android SDK with views")

Everything above the node is behind ONE interface, `HopEngine` (commonMain), the same discipline the core
uses for transport with the bearer seam. The UI SDK depends only on `HopEngine`, never on JNA, cinterop,
or any single binding. That is what makes it cross platform AND testable:

```
commonMain   HopValues (HopAddress/HopMessage/HopPeer), HopEngine (the seam), HopClient (the reactive
             brain: coroutine tick loop + StateFlow<HopClientState> + hot inbox Flow), the pure
             reduceHopState reducer, and the Compose UI (rememberHopClient + composables). No native code.
commonTest   FakeHopEngine + the client/reducer/value tests. Runs with NO libhop, NO JNA: the seam lets
             the whole reactive behaviour be verified against an in-memory engine. This is what monorepo
             CI runs (`gradle desktopTest`): it needs only public artifacts, no unpublished node SDK.
jvmSharedMain the JVM wall-clock actual, shared by android + desktop. Nothing else: the library depends
             ONLY on public artifacts (Compose + coroutines), never on a native binding.
iosMain      the wall-clock actual (NSDate). The engine on iOS is app-supplied over the Apple xcframework
             (sdk/apple); see IosEngine.kt. The seam means no binding is hard-wired here.
examples/    NOT compiled into the library. jvm/JnaHopEngine.kt is the ready-to-copy adapter from
             `sh.hop:hop`'s JNA HopNode to HopEngine (Android + Desktop); ChatApp.kt is a full screen.
             Kept out of the compiled artifact so it carries no `sh.hop:hop` dependency of its own.
```

`Clock.kt` (`internal expect fun hopNowMillis`) is the SDK's ONLY expect/actual. Everything else is plain
commonMain behind the seam. Do not add expect/actual for things the seam can carry.

## Invariants (do not "clean up")

- **The UI never touches the engine.** Composables read `HopClient.state` / call `HopClient` methods only.
  `HopClient` is the sole owner of engine calls, and it serializes every one through a single `Mutex`, so
  the engine (not assumed thread-safe) is only ever entered by one coroutine. Do not call an engine from a
  composable, and do not drop the mutex.
- **Inbox accept is after fold, never before.** `HopClient.drainInbox` accepts an item (returns true from
  `pollInbox`) only once it has folded it into state, so a crash mid-drain re-polls rather than losing a
  message. Keep that order.
- **`reduceHopState` is pure and total.** Same `(state, event)` always yields the same next state, never
  throws. That is the contract the reducer tests rely on; keep new events inside it, not in the client.
- **Optimistic send, then track.** `send` shows the outbound message as `Pending` before any ack, then the
  loop advances it via `statusOf`. A no-ack send is intentionally not tracked.

## Verify

`gradle allTests` runs the commonTest suite on every target; it needs only public artifacts (Compose +
coroutines), no native library and no unpublished SDK. Monorepo CI runs `gradle desktopTest` (the
`compose-sdk` job), which is the fast JVM slice of that. Keep everything ASCII (the repo-wide no-dash
rule; `tools/docs-token-guard.sh` scans this tree).

## Copybara + publish

Registered like every sibling SDK: `tools/copybara/components.json` + the COMPONENTS/`_register` pair in
`copy.bara.sky` + the `sync-components.yml` choice list mirror `sdk/compose` out to `hop-sdk-compose`
(kept in step by `tools/copybara/dispatch.test.sh`). `.github/workflows/release.yml` is the non-native
publish path (`tools/release/plan.py` tags the mirror once its `build.gradle.kts` version matches),
publishing the Kotlin Multiplatform Maven publication to Maven Central under `sh.hop:hop-compose`.
