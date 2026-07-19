# tools/

CI guards + build helpers. The guards are the repo's safety net; each has a `.test.sh` self-test that
runs in CI BEFORE the guard itself, so a change to a guard proves it still flags what it should.

```
docs-token-guard.sh        bans em/en/lookalike dashes (literal, HTML-entity incl. no-semicolon, \u/CSS
                           escape) + removed terms (InternetEgress, Wi-Fi Direct) + bare "Bluetooth" in
                           docs/site copy. Self-test: docs-token-guard.test.sh.
check-required-checks.sh   asserts ci.yml job names == the bootstrap trusted-gate allowlist. Fails
                           on a nameless job, an anchor/inline job, or a ${{ }}-templated name (all of
                           which could gate deploys while hiding from the sync).
check-branch-protection.sh asserts the live branch-protection rule on main requires exactly the ci.yml
                           job names (needs an admin-read PAT: BRANCH_PROTECTION_TOKEN).
repo-integrity-guard.sh    fails if a critical file (LICENSE, load-bearing docs, sdk/hop.h) is missing,
                           empty, truncated, or drifted. TWO-TIER licenses: core/* byte-identical
                           FSL-1.1-ALv2, every other component byte-identical Apache-2.0 (marker
                           "January 2004", since FSL text references "Apache License"), no cross-tiers.
version-align-guard.sh     fails if an SDK's declared version drifts in major/minor from the anchor (the
                           Rust workspace version); patch may differ. Self-test: version-align-guard.test.sh.
require-ci-verdict.py       exact GitHub Actions workflow, App, repository, attempt, SHA, and job gate.
deploy-provenance.py        signed build manifest, immutable archive/image verification, and global lease.
native-attestation/         local GitHub OIDC SLSA bundle creation when hosted attestation storage is unavailable.
infra-authority-guard.py    forbids bootstrap authority in the runtime root and broad build/deploy grants.
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

- **The guards are ASCII-clean and must stay so.** The dash bytes are built from `printf '\xe2...'`, never typed, so the guard cannot trip its own ban. Keep dollar-name patterns out of block-scalar comments in the deploy config (they get scanned as substitutions).
- **When you change a guard, extend its self-test in the same PR** (add the case that would have caught the gap). The self-tests are the regression guard for the guards.
- The guards were themselves a source of real audit findings (a case-sensitive ban, an unbounded parser, a broken workflow-permissions key). Probe a guard change for both new bypasses AND new false positives.
