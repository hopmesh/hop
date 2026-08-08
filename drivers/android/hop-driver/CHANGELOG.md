# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Chore
- bump org.json:json in /apps/android/HopDemo (#107) (2de7004)
- bump org.robolectric:robolectric in /apps/android/HopDemo (#110) (d10dfaf)
- bump androidx.test:core in /bearers/android (#113) (ac1ef41)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (edaf8fc)
- organize the monorepo, all apps under apps/<platform>/<App> + a CLAUDE.md at every tree node (#105) (98c5613)
- bump net.java.dev.jna:jna in /bearers/android (#32) (d3af49c)

### Dependencies
- Kotlin 2.4/AGP 9.2.1/Compose BOM 2026.06/okhttp 5.4 toolchain migration (#90) (1f83a56)

### Documentation
- regenerate from conventional commits (3912d31)

### Features
- self-certifying reachability records (core + ABI) for DNS-free endpoint discovery (#126) (e0bae40)

### Other
- make the TLS-served reach record the only name path (drop DNSSEC-over-DoH) (#139) (549e4fc)
- decompose the 1489-line HopBearer god-object into per-concern collaborators (C+ → A) (#76) (c032300)
- app identifiers + code packages net.waldrip.* / co.hopmesh.* -> sh.hopme.* (d5decd9)
- thin HopDriver composing the SDK + all four bearers (mirror of Apple) (58822a5)

### Testing
- Robolectric suite takes the driver from D (~16%) to A (94% line) (#65) (8cf43d7)

