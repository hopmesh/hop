# tools/

CI guards + build helpers. The guards are the repo's safety net; each has a `.test.sh` self-test that
runs in CI BEFORE the guard itself, so a change to a guard proves it still flags what it should.

```
docs-token-guard.sh        bans em/en/lookalike dashes (literal, HTML-entity incl. no-semicolon, \u/CSS
                           escape) + removed terms (InternetEgress, Wi-Fi Direct) + bare "Bluetooth" in
                           docs/site copy. Second pass (`--source`, and part of the no-arg run) applies
                           the DASH bans only across the code trees, so the repo-wide ban holds in
                           comments too; generated output, captured logs, and the wire-source-manifest
                           files are excluded (see the header). Self-test: docs-token-guard.test.sh.
check-required-checks.sh   keeps the aggregate `CI gate` honest: it must `needs:` every other ci.yml
                           job, use `if: always()`, and fail on a failed/cancelled dep. Also fails on a
                           nameless job, an anchor/inline job, or a ${{ }}-templated name (any of which
                           could gate merges while hiding from the aggregate). No bootstrap allowlist.
check-branch-protection.sh asserts the live branch-protection rule on main requires exactly the single
                           `CI gate` context (needs an admin-read PAT: BRANCH_PROTECTION_TOKEN).
repo-integrity-guard.sh    fails if a critical file (LICENSE, load-bearing docs, sdk/hop.h) is missing,
                           empty, truncated, or drifted. TWO-TIER licenses: core/* byte-identical
                           FSL-1.1-ALv2, every other component byte-identical Apache-2.0 (marker
                           "January 2004", since FSL text references "Apache License"), no cross-tiers.
version-align-guard.sh     fails if an SDK's declared version drifts in major/minor from the anchor (the
                           Rust workspace version); patch may differ. Self-test: version-align-guard.test.sh.
native-attestation/         local GitHub OIDC SLSA bundle creation when hosted attestation storage is unavailable.
release/                    plan.py resolves each publishing component's declared version from its own
                            manifest (Cargo/package.json/pyproject/shard/mix/gemspec, else the workspace
                            anchor); tag-mirrors.py creates `vX.Y.Z` on each PUBLIC mirror that lacks it,
                            which is what fires that mirror's release.yml and publishes. Skips unless the
                            mirror's main already declares the version (the mirror asserts tag ==
                            manifest). Driven by release-tags.yml after a successful export.
                            Self-test: release/release.test.sh (pins the tag/skip policy AND the token scope).
infra-authority-guard.py    forbids bootstrap authority in the runtime root and bounds the hop-deploy grants.
agent-output-guard.mjs      blocks known environment dumps and clears recognized shell secrets.
cov-floor-gate.py           gates Swift coverage from llvm-cov JSON (named fields, not a positional awk).
apple-cov-gate.sh           per-package Swift coverage floor.
check-web-links.mjs         internal-link checker for apps/web/site/dist.
build-xcframework.sh        builds the Apple SDK xcframework + Swift bindings into drivers/apple/HopDriver.
build-aar.sh                generates the Android UniFFI bindings + native libs into the demo app's dir.
smoke-test.sh               compiles + runs a Swift program against libhop on the macOS host.
```

The three build scripts `cd` to the repo root, so they operate on repo-relative paths regardless of
being invoked from `tools/`. They are the platform SDK-artifact builders (previously the only contents
of the now-removed `apple/` and `android/` root stubs); `drivers/` and `sdk/` + CI reference them.

## Rules

- **The guards are ASCII-clean and must stay so.** The dash bytes are built from `printf '\xe2...'`, never typed, so the guard cannot trip its own ban.
- **When you change a guard, extend its self-test in the same PR** (add the case that would have caught the gap). The self-tests are the regression guard for the guards.
- The guards were themselves a source of real audit findings (a case-sensitive ban, an unbounded parser, a broken workflow-permissions key). Probe a guard change for both new bypasses AND new false positives.
