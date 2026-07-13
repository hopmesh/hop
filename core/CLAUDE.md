# core/

The Rust heart of Hop. Everything else binds through here.

```
core/hop-core     the protocol: bundles, wire format, Noise links, spray-and-wait routing, the §39
                  untraceable-messaging path, HNS (well-known reach records), hps:// pub/sub, the crypto
core/hop          the C ABI crate (cbindgen -> sdk/hop.h); the universal client + bearer contract
core/hop-wasm     the wasm/browser binding of hop-core (JS-consumable via wasm-bindgen), peer to the
                  C ABI; the browser swarm sim is its primary consumer today
core/stores       the persistence adapters (sqlite / sqlcipher, firestore) behind the Store trait
```

## The wire format is a contract

- `hop-core/src/bundle.rs` `BUNDLE_VERSION` is THE wire version. Any change to a Destination/Payload variant, a sealed-field layout, or the id derivation bumps it.
- A wire bump MUST be followed by `sim/build-wasm.sh` + committing `sim/pkg` (the pkg-fresh guard reddens the "Web + sim" job otherwise). See `sim/CLAUDE.md`.
- §39 bundles are UNSIGNED and self-verifying: their id IS their integrity check. Binding too few fields into the id is a forgery class (see the pass-13..18 audit history). Do not weaken `verify()`.
- A dependency bump (crypto crate, etc.) must produce BYTE-IDENTICAL wire output. Prove it with the round-trip tests before merging.

## Verify

`cargo test -p hop-core` (the §39 + round-trip tests are the crown jewels), `cargo test --workspace`,
`cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --all --check`. Coverage via
`cargo tarpaulin`. The crypto uses a real OS CSPRNG via getrandom; never key generation from a constant.

## The C ABI (core/hop)

Regenerate `sdk/hop.h` with the pinned cbindgen (`core/hop/regen-header.sh`) in the same PR as any ABI
change; the header-drift CI job fails otherwise. `HOP_ABI_VERSION` in the header is asserted by every
wrapper at load. The `minimal` feature drops UniFFI + SQLite for embedded targets.
