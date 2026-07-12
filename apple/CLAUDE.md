# apple/

**Platform BUILD tooling, not apps.** The Apple apps moved to `apps/apple/`; this directory holds the
scripts that package the SDK artifacts those apps (and `drivers/`, `sdk/`) consume.

```
apple/build-xcframework.sh   builds the libhop xcframework + Swift bindings that drivers/apple/HopDriver
                             links (gitignored output). Run this before building or testing the iOS app.
apple/smoke-test.sh          a build/link smoke check.
apple/README.md              the Apple-side build notes.
```

It stays at the repo root (not under `apps/`) because it is referenced by `drivers/apple/HopDriver`,
`sdk/wrappers/Hop`, CI, and docs. If you ever relocate it, update every one of those references. For the
apps themselves, see `apps/apple/CLAUDE.md`.
