# Publishing the hop-sdk-apple release

`sdk/apple/Package.swift` is the published SwiftPM manifest. It resolves `CHop` from

```
https://github.com/hopmesh/hop-sdk-apple/releases/download/v0.0.1/libhop.xcframework.zip
```

That URL currently 404s. `hopmesh/hop-sdk-apple` has the tag `v0.0.1` and zero releases, so the
package does not resolve for anyone outside this repo, and every in-tree Apple build has to swap
`Package.local.swift` over `Package.swift` first. That swap is the mechanism that has twice put the
wrong manifest into a commit.

This runbook is the ordered procedure a human follows to make that URL real. Every step below is
grounded in a workflow or helper in this repo; the file that decides each behavior is named inline.

## The three moving parts

| Part | Where | What it produces |
| --- | --- | --- |
| Canonical source | `hopmesh/hop`, branch `main` | the commit SHA everything else is pinned to |
| Mirror | `hopmesh/hop-sdk-apple` | the published SwiftPM package, exported from `sdk/apple` by Copybara |

`sdk/apple/.github/workflows/release.yml` is the mirror's release workflow. It never rebuilds the
framework. It downloads the archive that `native-artifacts.yml` already built for the tagged source
SHA, checks it, and attaches it to a GitHub Release. Nothing in the release path compiles Rust.

## The checksum contract

`sdk/apple/.github/workflows/release.yml`, job `build`:

```
expected="$(... targets ... CHop ... checksum ...)"   # from swift package dump-package
actual="$(swift package compute-checksum "$RUNNER_TEMP/native-release/libhop.xcframework.zip")"
test "$expected" = "$actual"
```

`expected` is whatever `Package.swift` declares at the tagged mirror commit. `actual` is
`swift package compute-checksum` (a plain SHA-256) over the archive downloaded from the canonical
native run. `tools/package-export-smoke.py:validate_apple` applies the same equality against the
signature-verified bundle, and additionally requires the manifest URL to start with
`https://github.com/hopmesh/hop-sdk-apple/releases/download/v0.0.1/`.

Two consequences follow, and both matter:

1. **A checksum can be committed before the release exists.** Nothing resolves the URL until the
   release is created, and the release is precisely what validates the value. A wrong checksum cannot
   publish a bad package; it can only fail the `build` job.
2. **A checksum is specific to one source SHA and rots on the next core change.** The archive is
   `core/hop` compiled for five Apple targets plus `core/hop/include/hop.h`, packed by
   `tools/native-artifacts.py pack`. Change anything that feeds `libhop.a` or the header and the
   archive changes, so the checksum changes. The release does not rebuild, so the committed value has
   to match the archive built for the exact SHA being tagged, not "roughly current main".

`sdk/apple/Package.swift` carries a provenance comment naming the source SHA its checksum belongs to.
Compare that SHA against the one you are about to tag before you do anything else.

## Preflight, in order

Everything here was checked against the live repositories and is a real blocker, not a hypothetical.

### 1. The mirror has no source-read credentials

`release.yml`'s `prepare` job mints a token with:

```yaml
app-id: ${{ secrets.HOP_SOURCE_APP_ID }}
private-key: ${{ secrets.HOP_SOURCE_PRIVATE_KEY }}
owner: hopmesh
repositories: monorepo
permission-actions: read
permission-checks: read
permission-contents: read
```

`hopmesh/hop-sdk-apple` has no repository secrets, no `release` environment secrets, and the only
organization secret exposed to it is `HOP_SYNC_TOKEN`. Neither `HOP_SOURCE_APP_ID` nor
`HOP_SOURCE_PRIVATE_KEY` exists anywhere the workflow can read, so `prepare` fails at its second
step.

The organization does have a GitHub App, `hop-component-sync` (app id 4371945), installed on all
repositories with `contents: write`, `metadata: read`, `pull_requests: write`, `workflows: write`. It
is missing `actions: read` and `checks: read`, and `create-github-app-token` fails when it is asked
for a permission the installation does not hold. So either grant that app those two read permissions
and reuse it, or register a separate read-only source app. Then set its id and private key as
secrets on the `release` environment of `hop-sdk-apple` (and of every other mirror whose release
workflow verifies canonical provenance).

### 2. The `release` environment gates on a human

`hop-sdk-apple`'s `release` environment has two protection rules: required reviewers (`jwaldrip`) and
a deployment tag policy of `v*`. The one release attempt so far, run `30128992818` on 2026-07-24,
recorded a `prepare` job that ran for 19 minutes and 41 seconds with zero steps in its step list and
a `cancelled` conclusion, which is what a job blocked on the environment gate looks like. Approve the
deployment when the run appears, or it will sit there. Two jobs request the environment, so expect
two approvals.

### 3. The existing `v0.0.1` tag cannot be reused where it stands

`tools/release-provenance.py:validate_tag_state` rejects a release unless the push event is a newly
created ref (`before` is forty zeros, not deleted, not forced) **and**:

```python
if tag_commit != main_commit:
    raise ProvenanceError("tagged commit is not exactly the current mirror main commit")
```

Today `hop-sdk-apple` main is `c4acc9bb3975d87766cd2d62f87e86b546c31c10` and `v0.0.1` points at
`3e5240f910fb2461be7bc33a06df70f6cea3de50`. The tag is behind main, so re-running it fails that
check, and moving a tag is rejected as a forced update. `.github/workflows/release-tags.yml` will not
help: it creates tags through the git refs API, which never overwrites an existing ref, so it skips a
version that is already tagged.

Two ways out:

- **Delete `v0.0.1` on the mirror and create it again at mirror main.** A delete followed by a create
  is a fresh `created` push event, which is what `validate_tag_state` wants. This keeps `v0.0.1`
  valid everywhere it is hardcoded (`tools/package-export-smoke.py`, its self-test,
  `sdk/apple/install-local-xcframework.py`'s `--version` default, `sdk/apple/README.md`).
- **Release `v0.0.2` instead.** `tools/release/plan.py` falls back to the Rust workspace version for
  SwiftPM (tag-driven ecosystem, no in-repo manifest version), so bumping `[workspace.package]
  version` in the root `Cargo.toml` makes `release-tags.yml` create a fresh tag on the next successful
  sync. This costs more: the four `v0.0.1` hardcodes above all have to move in the same change, and
  `tools/package-export-smoke.py` is a CI guard, so missing one reddens the build.

## The runbook

Do these in order. Nothing here is optional, and step 5 is the one people will want to skip.

1. **Clear the preflight blockers above.** Steps 2 onward assume `HOP_SOURCE_APP_ID` and
   `HOP_SOURCE_PRIVATE_KEY` exist on the mirror's `release` environment and that the app holds
   `actions: read`, `checks: read`, `contents: read` on `hopmesh/platform`.

2. **Pick the release SHA and let main settle.** Merge everything the release should carry, then stop
   merging. Let `S` be the resulting `main` tip.

3. **Wait for `S` to be fully green.** `release-provenance.py` requires, for `S`:
   - exactly one completed successful `main` push run of `.github/workflows/ci.yml`
     (`select_workflow_run`), whose check-run name set exactly equals `tools/required-checks.json`
     (`verify_required_checks`, which rejects both missing and unexpected names);
   - exactly one `native-artifacts.yml` main push run whose `display_title` is
     `Native artifacts for <S>` (`select_native_run`; `native-artifacts.yml` sets that through
     `run-name`).

4. **Read the real checksum for `S` and commit it.**

   ```bash
   gh run list --workflow=native-artifacts.yml -R hopmesh/hop --branch main --limit 20 \
     --json databaseId,headSha,conclusion,attempt --jq '.[] | select(.headSha=="<S>")'
   gh run download <run-id> -R hopmesh/hop -n native-release-bundle-<attempt> -D /tmp/hop-native

   # the same check the release workflow's prepare job runs, so a pass here means that job passes
   python3 tools/native-artifacts.py verify-provenance \
     --manifest /tmp/hop-native/native-artifacts.json \
     --signature /tmp/hop-native/native-artifacts.json.sig \
     --public-key tools/native-artifacts-public.pem \
     --directory /tmp/hop-native \
     --provenance-bundle /tmp/hop-native/native-artifacts.provenance.sigstore.json \
     --source-sha <S> --tag v0.0.1 --run-id <run-id> --run-attempt <attempt>
   ```

   shasum -a 256 /tmp/hop-native/libhop.xcframework.zip
   ```

   Use `verify-provenance`, not `verify --strict`. The strict inventory check predates the Sigstore
   bundle and rejects it as an extra file, which reads like a tampering failure and is not one.

5. **Merge that commit and re-check.** The merge makes a new main tip `S2`. Repeat step 3 for `S2`,
   then repeat the download in step 4 for `S2` and confirm the checksum still matches what you
   committed. It is a one-line check and it is the whole ballgame: if it differs, the release will
   fail at the `build` job, and you go back to step 4 with `S2`'s value.

6. **Wait for the mirror export.** `.github/workflows/sync-components.yml` exports on every push to
   main. Confirm `hopmesh/hop-sdk-apple` main now has a commit whose message carries
   `GitOrigin-RevId: <S2>`, and that its `Package.swift` shows the checksum you committed.

   ```bash
   gh api repos/hopmesh/hop-sdk-apple/commits/main --jq '.sha, .commit.message'
   ```

7. **Create the tag on the MIRROR, at mirror main.** Not in the monorepo. If reusing `v0.0.1`, delete
   it first.

   ```bash
   gh api -X DELETE repos/hopmesh/hop-sdk-apple/git/refs/tags/v0.0.1     # only if reusing v0.0.1
   gh api -X POST repos/hopmesh/hop-sdk-apple/git/refs \
     -f ref=refs/tags/v0.0.1 -f sha=<mirror main sha>
   ```

8. **Approve the `release` environment** when the run shows up under Actions on `hop-sdk-apple`. Two
   jobs request it, `prepare` and `publish`, so expect two approvals.

## What the workflow then does

`prepare` (ubuntu, environment `release`)

- `release-provenance.py --component hop-sdk-apple --require-native-artifacts`: validates the tag
  push shape, reads the single `GitOrigin-RevId` trailer off the tagged commit to get the source SHA,
  confirms that SHA is reachable from canonical main, downloads the source tarball and compares the
  expected Copybara export tree against the mirror's tagged tree file by file, checks CI and the required
  check set, and resolves the native run id and attempt.
- `native-artifacts.py download-github`: pulls the bundle by immutable run and artifact id.
- `native-artifacts.py verify-provenance`: OpenSSL signature over the manifest using the checked-in
  `native/native-artifacts-public.pem`, every archive digest, and the Sigstore provenance bundle,
  bound to the source SHA, tag, run id, and run attempt.

`build` (macos-14)

- the checksum equality test quoted above;
- `ditto -x -k` the archive into `Frameworks/`, then `native-artifacts.py apple-verify` against the
  archive's own `architecture-manifest.json`;
- swaps `Package.local.swift` in, runs `swift test`, asserts the swap is intact with `cmp`, then
  restores the published manifest from a copy taken beforehand;
- builds a throwaway consumer package that depends on the `Hop` product, proving a clean resolve;
- `release-artifact.py create` writes `release-manifest.json` over the four files that ship.

`publish` (ubuntu, environment `release`)

- `release-artifact.py verify` re-checks the manifest against the canonical source SHA and run
  attempt, then `softprops/action-gh-release` creates the release with generated notes.

Published assets: `libhop.xcframework.zip`, `native-artifacts.json`, `native-artifacts.json.sig`,
`native-artifacts.provenance.sigstore.json`, `release-manifest.json`.
