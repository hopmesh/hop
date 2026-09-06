# tools/

CI guards + build helpers. The guards are the repo's safety net; each has a `.test.sh` self-test that
runs in CI BEFORE the guard itself, so a change to a guard proves it still flags what it should.

```
docs-token-guard.sh        bans em/en/lookalike dashes (literal, HTML-entity incl. no-semicolon, \u/CSS
                           escape) + removed terms (InternetEgress, Wi-Fi Direct) + bare "Bluetooth" in
                           docs/site copy. Second pass (`--source`, and part of the no-arg run) applies
                           the DASH bans only across the code trees, so the repo-wide ban holds in
                           comments too; only generated output and captured logs are excluded (see
                           src_excludes) plus two hand-written entries: this guard and its own self-test,
                           which have to spell every banned pattern to ban it. The shared exclude list
                           also drops *.svg, so the hand-authored assets/ icon and wordmark sources are
                           NOT scanned. "The source pass reported OK" is therefore not the same claim as
                           "no file in the repo has a dash". The wire-source-manifest exclusion was
                           RETIRED in the v13 to v14 bump (PROC-001), which also added U+2212 to the
                           banned set and put fuzz/ into the source pass (mockups/ and business/ were moved to hopmesh/internal).
                           Self-test: docs-token-guard.test.sh.
commit-message-guard.sh      scans introduced commit messages for banned em/en/lookalike dashes across
                           the revision range (default HEAD). Merge commits are scanned; history is not
                           scanned (range-scoped by design, zero allowlist).
                           Self-test: commit-message-guard.test.sh.
commit-message-guard-range.sh computes the revision range to scan from GitHub event context (pull_request
                           base..HEAD, push before..HEAD with zero-SHA and unreachable fallbacks to HEAD,
                           workflow_dispatch HEAD). Self-test: commit-message-guard.test.sh.
copybara/validate-config.sh loads tools/copybara/copy.bara.sky in the exact digest-pinned Copybara image
                           sync-components.yml runs (`copybara validate`). The Python export model in
                           package-export-smoke.py reimplements the transforms and CANNOT see a config
                           Copybara refuses (a same-path core.move shipped in ABI-011 and killed every
                           real export at config load while the model passed, REL-003). Needs docker.
                           Self-test: copybara/validate-config.test.sh (must reject that defect class).
check-required-checks.sh   keeps the aggregate `CI gate` honest: it must `needs:` every other ci.yml
                           job, use `if: always()`, and fail on a failed/cancelled dep. Also fails on a
                           nameless job, an anchor/inline job, or a ${{ }}-templated name (any of which
                           could gate merges while hiding from the aggregate). No bootstrap allowlist.
check-branch-protection.sh asserts the live branch-protection rule on main requires exactly the single
                           `CI gate` context (needs an admin-read PAT: BRANCH_PROTECTION_TOKEN).
                           Defaults to hopmesh/hop; override with GH_REPO for a fork or staging repo.
check-worktree-checkpoints.sh asserts that all active worktrees have clean working trees and that their
                           HEAD commits are reachable from a named branch before pruning (PROC-014).
                           Self-test: check-worktree-checkpoints.test.sh.
repo-integrity-guard.sh    fails if a critical file (LICENSE, load-bearing docs, sdk/hop.h) is missing,
                           empty, truncated, or drifted. TWO-TIER licenses: services/* byte-identical
                           FSL-1.1-ALv2, every other component (core, sdk, bearers, drivers, examples)
                           byte-identical Apache-2.0 (marker "January 2004", since FSL text references
                           "Apache License"), no cross-tiers. The tiers were INVERTED on 2026-07-31:
                           FSL used to sit on core/, which taxed every SDK (they all bind libhop, so a
                           legal review hit FSL anyway) while leaving hop-relayd permissive. Its
                           self-test pins the revert as a failing case.
workflow-if-guard.py       fails if any workflow `if:` kept a literal newline inside its `${{ }}`. A
                           folded scalar whose continuation lines are indented FURTHER than the first
                           preserves them literally instead of folding to spaces, so the expression
                           never evaluates as written and the job SKIPS. A skip is not a failure, so
                           CI stays green while a gate silently does nothing. That is exactly how
                           pr-automerge's author gate shipped dead. Equal-indent folds are fine.
                           Self-test: workflow-if-guard.test.sh.
workflow-run-syntax-guard.py validates syntax of every workflow `run:` script block via `bash -n`,
                           catching unclosed loops or syntax errors (such as the missing `done` in
                           REL-006) before runs are scheduled, and runs `actionlint` if installed.
                           Self-test: workflow-run-syntax-guard.test.sh.
native-artifacts-path-guard.py keeps `native-artifacts.yml` push path filters aligned with the native
                           build graph (PROC-005), preventing missing or duplicate artifact inputs.
                           Self-test: native-artifacts-path-guard.test.sh.
mailbox-prefix-doc-guard.sh fails when the DOCUMENTED mailbox routing-prefix width disagrees with
                           `crypto::MAILBOX_ROUTE_PREFIX_BYTES`. It renders one canonical claim
                           sentence (buckets, anonymity set, small-N threshold) from the constant,
                           requires it verbatim in crypto.rs and DESIGN.md, rejects the same sentence
                           rendered for another width, and rejects any mailbox-prefix line carrying a
                           wrong-width figure unless that line scopes itself (`w=<n>` counterfactual,
                           `v<n>` version history, or the fixed 2-byte ABI `slot`). Exists because the
                           rustdoc above that constant said "Two bytes (16 bits)" above a value of 1
                           for wire v12, v13 AND v14 (audit PROTO-004): the file is manifest-listed, so
                           each bump deferred the comment edit to "the next real wire bump", the same
                           prose-named trigger PROC-001 indicted. Self-test:
                           mailbox-prefix-doc-guard.test.sh.
version-align-guard.sh     fails if an SDK's declared version drifts in major/minor from the anchor (the
                           Rust workspace version); patch may differ. Self-test: version-align-guard.test.sh.
codegen/check-contract-purity.sh asserts sdk/hop.h and all SDK language faces contain no transport-specific
                           symbols (BLE/Wi-Fi/socket identifiers). Discovers all SDK subtrees and checks
                           target existence and non-emptiness. Self-test: codegen/check-contract-purity.test.sh.
codegen/check-abi-version.sh asserts HOP_ABI_VERSION agreement across cabi.rs, headers, wrappers, and docs,
                           verifies canonical tools/codegen/abi-manifest.json matches sdk/hop.h via
                           generate-abi-manifest.py --check, and proves every wrapper's FFI declarations
                           match manifest signatures (width, signedness, callbacks) via
                           verify-abi-signatures.py. Self-tests: codegen/check-abi-version.test.sh,
                           codegen/generate-abi-manifest.test.sh, codegen/verify-abi-signatures.test.sh.
identity-secret-guard.py    scans tracked files for raw 32-byte high-entropy binary identity seeds and
                           private key markers. Self-test: identity-secret-guard.test.sh.
native-attestation/         local GitHub OIDC SLSA bundle creation when hosted attestation storage is unavailable.
release/                    plan.py resolves each publishing component's declared version from its own
                            manifest (Cargo/package.json/pyproject/shard/mix/gemspec, else the workspace
                            anchor); tag-mirrors.py creates `vX.Y.Z` on each PUBLIC mirror that lacks it,
                            which is what fires that mirror's release.yml and publishes. Skips unless the
                            mirror's main already declares the version (the mirror asserts tag ==
                            manifest). Driven by release-tags.yml after a successful export.
                            Self-test: release/release.test.sh (pins the tag/skip policy AND the token scope).
release/check-mirror-secrets.py compares the secrets each mirror's release.yml
                            REFERENCES against what is seeded at repo + environment + org scope.
                            With --audit-protection, it also audits mirror main branch protection
                            and release environment rules (INFRA-019), and verifies canonical
                            hop-source App installation on hopmesh/hop (INFRA-023).
                            Needs a secrets-read token; branch-protection-audit runs it when armed.
                            Self-test: release/check-mirror-secrets.test.sh.
agent-output-guard.mjs      blocks known environment dumps and clears recognized shell secrets.
meshtastic-parity.sh        keeps the Meshtastic bearer wire contract identical on Apple and Android
                            (port, chunk size, fragment-header layout, frame tags, keepalive timing),
                            canonical in bearers/meshtastic-vectors.json. Pins decision points too: the
                            port must stay in the PRIVATE_APP range and the fragment-count vectors must
                            follow from max_chunk. Self-test: meshtastic-parity.test.sh. Runs in the
                            `automation` job alongside ble-backoff-parity.sh.
cov-floor-gate.py           gates Swift coverage from llvm-cov JSON (named fields, not a positional awk).
apple-cov-gate.sh           per-package Swift coverage floor. Self-test: apple-cov-gate.test.sh.
check-web-links.mjs         internal-link checker for apps/web/site/dist. Self-test: check-web-links.test.mjs.
native-artifacts.py         native release artifact pack, create, verify, and extraction tool.
                            Self-test: native-artifacts.test.sh.
build-xcframework.sh        builds the Apple SDK xcframework + Swift bindings into drivers/apple/HopDriver.
build-aar.sh                generates the Android UniFFI bindings + native libs into the demo app's dir.
smoke-test.sh               compiles + runs a Swift program against libhop on the macOS host.
```

The three build scripts `cd` to the repo root, so they operate on repo-relative paths regardless of
being invoked from `tools/`. They are the platform SDK-artifact builders (previously the only contents
of the now-removed `apple/` and `android/` root stubs); `drivers/` and `sdk/` + CI reference them.

## Commit message dash scan: range-scoped, zero allowlist (PROC-009)

The dash law covers "code, comments, docs, commits, PRs", and `tools/commit-message-guard.sh`
enforces the commit-message half in CI.

The earlier premise that a single historical commit (`3ad6077`) was the only blocker turned out to
be inaccurate for this repository: `3ad6077` (the U+2212 commit message) exists only in the retired
private hopmesh/monorepo; hopmesh/hop's main does not contain it (Copybara exported PR #351 as
squashed merge `67395734`). However, a full scan of hop's 840 main commits found 173 messages
carrying banned dashes (170 U+2014, 3 U+2013, 1 U+2212 in `62b45a6a`, plus a few encoded entities).
Rewriting history would alter roughly 20% of all commits, strip 184 valid signatures, and orphan the
three Copybara mirrors' GitOrigin-RevId chains and every published source SHA.

The owner therefore chose the zero-rewrite design: scan only the commits a change INTRODUCES, with
zero allowlist entries. In CI (`.github/workflows/ci.yml`), `tools/commit-message-guard.sh --github-event`
runs unconditionally in the `automation` job on every PR and push without path filters (PROC-016).
Range is computed via `tools/commit-message-guard-range.sh` from GitHub event context (`pull_request`
base..HEAD, `push` before..HEAD with zero-SHA / unreachable fallbacks to HEAD, or `workflow_dispatch` HEAD).
No commit-message allowlist exists, and historical commits before the change base are not scanned.

## Rules

- **The guards are ASCII-clean and must stay so.** The dash bytes are built from `printf '\xe2...'`, never typed, so the guard cannot trip its own ban.
- **When you change a guard, extend its self-test in the same PR** (add the case that would have caught the gap). The self-tests are the regression guard for the guards.
- The guards were themselves a source of real audit findings (a case-sensitive ban, an unbounded parser, a broken workflow-permissions key). Probe a guard change for both new bypasses AND new false positives.
