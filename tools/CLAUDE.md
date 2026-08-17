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
                           banned set and put fuzz/, mockups/, and business/ into the source pass.
                           Self-test: docs-token-guard.test.sh.
check-required-checks.sh   keeps the aggregate `CI gate` honest: it must `needs:` every other ci.yml
                           job, use `if: always()`, and fail on a failed/cancelled dep. Also fails on a
                           nameless job, an anchor/inline job, or a ${{ }}-templated name (any of which
                           could gate merges while hiding from the aggregate). No bootstrap allowlist.
check-branch-protection.sh asserts the live branch-protection rule on main requires exactly the single
                           `CI gate` context (needs an admin-read PAT: BRANCH_PROTECTION_TOKEN).
                           Defaults to hopmesh/hop; override with GH_REPO for a fork or staging repo.
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
native-attestation/         local GitHub OIDC SLSA bundle creation when hosted attestation storage is unavailable.
release/                    plan.py resolves each publishing component's declared version from its own
                            manifest (Cargo/package.json/pyproject/shard/mix/gemspec, else the workspace
                            anchor); tag-mirrors.py creates `vX.Y.Z` on each PUBLIC mirror that lacks it,
                            which is what fires that mirror's release.yml and publishes. Skips unless the
                            mirror's main already declares the version (the mirror asserts tag ==
                            manifest). Driven by release-tags.yml after a successful export.
                            Self-test: release/release.test.sh (pins the tag/skip policy AND the token scope).
                            release/check-mirror-secrets.py compares the secrets each mirror's release.yml
                            REFERENCES against what is seeded at repo + environment + org scope. It exists
                            because HOP_SOURCE_APP_ID/_PRIVATE_KEY were never seeded on any mirror, and an
                            unset secret resolves to "" rather than erroring, so nothing ever published and
                            the only symptom was an action complaining about an empty input. Needs a
                            secrets-read token; the weekly branch-protection-audit runs it when armed.
agent-output-guard.mjs      blocks known environment dumps and clears recognized shell secrets.
meshtastic-parity.sh        keeps the Meshtastic bearer wire contract identical on Apple and Android
                            (port, chunk size, fragment-header layout, frame tags, keepalive timing),
                            canonical in bearers/meshtastic-vectors.json. Pins decision points too: the
                            port must stay in the PRIVATE_APP range and the fragment-count vectors must
                            follow from max_chunk. Self-test: meshtastic-parity.test.sh. Runs in the
                            `automation` job alongside ble-backoff-parity.sh.
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

## Known gap: nothing scans COMMIT MESSAGES

The dash law covers "code, comments, docs, commits, PRs", but every guard here reads FILES. No check
reads a commit message, so the commits half of the law is enforced by attention alone. That is the
same shape as the carve-out PROC-001 retired: a rule enforced where a human is likely to look and
silently unenforced elsewhere.

It is not a hypothetical. The commit that BANNED U+2212 (`3ad6077`, "audit closure: retire the
prose-named triggers this branch indicted") put a literal U+2212 into its own message, on the line
listing the newly-banned encoded forms. It is still there. Removing it means rewriting a pushed
commit, which needs the owner's go-ahead for the force-push, so it was left in place and recorded
here rather than quietly ignored.

Read that as the reason the check is still missing, not as an argument against it: adding a
commit-message scan today would redden CI on that exact commit, and the only ways to green it are a
history rewrite or a baseline exemption, and a guard that starts life with an exemption for the
violation that motivated it is worth very little. Clean the message first (one interactive rebase,
one force-push, owner's call), THEN add the scan with no allowlist.

## Rules

- **The guards are ASCII-clean and must stay so.** The dash bytes are built from `printf '\xe2...'`, never typed, so the guard cannot trip its own ban.
- **When you change a guard, extend its self-test in the same PR** (add the case that would have caught the gap). The self-tests are the regression guard for the guards.
- The guards were themselves a source of real audit findings (a case-sensitive ban, an unbounded parser, a broken workflow-permissions key). Probe a guard change for both new bypasses AND new false positives.
