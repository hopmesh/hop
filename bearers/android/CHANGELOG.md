# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- root-cause + close the bearer-lan JaCoCo coverage wobble (F-3) (#103) (27c4ffa)

### Build
- bump gradle-wrapper from 9.6.1 to 9.7.0 in /bearers/android (af85df6)

### Chore
- bump org.robolectric:robolectric in /apps/android/HopDemo (#110) (d10dfaf)
- bump androidx.test:core in /bearers/android (#113) (ac1ef41)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (2e68a4b)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (edaf8fc)
- organize the monorepo, all apps under apps/<platform>/<App> + a CLAUDE.md at every tree node (#105) (98c5613)
- bump net.java.dev.jna:jna in /bearers/android (#32) (d3af49c)

### Dependencies
- Kotlin 2.4/AGP 9.2.1/Compose BOM 2026.06/okhttp 5.4 toolchain migration (#90) (1f83a56)

### Documentation
- regenerate from conventional commits (2302369)
- regenerate from conventional commits (4fb4c3a)
- regenerate from conventional commits (b85390e)
- regenerate from conventional commits (3dd7f37)
- regenerate from conventional commits (9e1fd4b)
- regenerate from conventional commits (1e7cf38)
- regenerate from conventional commits (3912d31)

### Other
- route dedup through the pure keep-rule cores; fix inverted Android dedup-ordering docs (#72) (d8174fd)
- fix Android dial-backoff wedge caught by the hardware gauntlet (#16) (7ff7ec4)
- refresh GATT cache on dial timeout to break the discovery wedge (bbe1483)
- app identifiers + code packages net.waldrip.* / co.hopmesh.* -> sh.hopme.* (d5decd9)
- JNA compileOnly to avoid jar+aar duplicate-class clash (497f478)
- thin HopDriver composing the SDK + all four bearers (mirror of Apple) (58822a5)
- re-home all four bearers as independent modules on the Kotlin SDK (adba3e6)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (ffe08fe)

### Testing
- LAN 95% / Relay 100% / BLE 99% + fix non-restartable LanBearer (#68) (4609db2)

