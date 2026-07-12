# sdk/

The language wrappers over the C ABI (`sdk/hop.h`). A thin, type-safe shim so callers never touch raw
FFI, and the wrapper cannot drift from the header without the drift guard noticing.

```
sdk/hop.h      the generated C ABI header: the universal contract for every platform
sdk/apple      the Swift wrapper + xcframework packaging (its own sdk/apple/build-xcframework.sh)
sdk/android    the Kotlin/JVM wrapper via JNA (loads libhop; Android bearers + the app use it)
```

The layout is `sdk/<platform>` (one wrapper package per platform), matching the repo-wide
purpose/platform axis. There is exactly one SDK per platform, so the platform dir *is* the package
(no extra name level, unlike `bearers/<platform>/*` which holds several).

## FFI discipline (do not "clean up")

- **JNA bool returns are declared `Byte`, never `Boolean`.** libhop returns a 1-byte C `_Bool`; the x86-64 SysV ABI does not zero the upper bits on a `false`, and JNA's `boolean` reads a full-width int, so a dirty-upper-bit `false` misreads as `true` (seen on x86-64 Linux). Every bool-returning native returns `Byte`, converted via `.toBool()`. `bool*` out-params are `ByteByReference`. Do not change these back.
- **uint8_t fields are `UByte`, not signed `Byte`** at the public surface (a hop count >= 128 would render negative). The FFI boundary keeps `Byte` for marshalling; reinterpret via `.toUByte()` when building the public value (see `HopMessage.hops`, `HopStatus.forwardHops`).
- `HOP_ABI_VERSION` is asserted at load so a wrapper built against a newer header fails loudly.

## Verify

Kotlin: `gradle test jacocoTestReport jacocoTestCoverageVerification` with `HOP_LIBDIR` pointing at a
built libhop (`cargo build -p hop`); without the lib the JNA tests self-skip and the 80% gate fails,
keeping the grade honest. Swift: `swift test` in `sdk/apple`.
