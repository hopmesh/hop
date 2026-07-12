# android/

**Platform BUILD tooling, not apps.** The Android app moved to `apps/android/HopDemo`; this directory
holds the script that packages the SDK artifacts the app + `drivers/android/hop-driver` consume.

```
android/build-aar.sh   generates the UniFFI Kotlin bindings + native libs into
                       apps/android/HopDemo/generated/ (gitignored), which the app's gradle build and
                       drivers/android/hop-driver read back.
```

It stays at the repo root (not under `apps/`) because `drivers/android/hop-driver` and CI reference it.
For the app itself (its separate gradle build, the AGP 9 / Kotlin 2.x toolchain, the bearer/driver
includes), see `apps/android/CLAUDE.md`.
