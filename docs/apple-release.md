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
| Canonical source | `hopmesh/monorepo`, branch `main` | the commit SHA everything else is pinned to |
| Native artifact | `.github/workflows/native-artifacts.yml` | `libhop.xcframework.zip` plus a signed manifest, per main push |
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
private-key: ${{ secrets.HOP_SOURCE_APP_PRIVATE_KEY }}
owner: hopmesh
repositories: monorepo
permission-actions: read
permission-checks: read
permission-contents: read
```

`hopmesh/hop-sdk-apple` has no repository secrets, no `release` environment secrets, and the only
organization secret exposed to it is `HOP_SYNC_TOKEN`. Neither `HOP_SOURCE_APP_ID` nor
`HOP_SOURCE_APP_PRIVATE_KEY` exists anywhere the workflow can read, so `prepare` fails at its second
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
   `HOP_SOURCE_APP_PRIVATE_KEY` exist on the mirror's `release` environment and that the app holds
   `actions: read`, `checks: read`, `contents: read` on `hopmesh/monorepo`.

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
   # the run id and the attempt: the attempt is part of the artifact name
   gh run list --workflow=native-artifacts.yml -R hopmesh/monorepo --branch main --limit 20 \
     --json databaseId,headSha,conclusion,attempt --jq '.[] | select(.headSha=="<S>")'
   gh run download <run-id> -R hopmesh/monorepo -n native-release-bundle-<attempt> -D /tmp/hop-native

   # the same check the release workflow's prepare job runs, so a pass here means that job passes
   python3 tools/native-artifacts.py verify-provenance \
     --manifest /tmp/hop-native/native-artifacts.json \
     --signature /tmp/hop-native/native-artifacts.json.sig \
     --public-key tools/native-artifacts-public.pem \
     --directory /tmp/hop-native \
     --provenance-bundle /tmp/hop-native/native-artifacts.provenance.sigstore.json \
     --source-sha <S> --tag v0.0.1 --run-id <run-id> --run-attempt <attempt>

   shasum -a 256 /tmp/hop-native/libhop.xcframework.zip
   ```

   Use `verify-provenance`, not `verify --strict`. The strict inventory check predates the Sigstore
   bundle and rejects it as an extra file, which reads like a tampering failure and is not one.

   The `shasum` output is exactly what `swift package compute-checksum` returns for that archive, and
   it must equal the `apple-xcframework` entry in the signed `native-artifacts.json`. Put it in
   `sdk/apple/Package.swift` and update the provenance comment to `S`. Change nothing else in the
   commit; see the reproducibility note below for why that restriction matters.

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
   jobs request it, `prepare` and `publish`, so expect to approve twice.

## What the workflow then does

`prepare` (ubuntu, environment `release`)

- `release-provenance.py --component hop-sdk-apple --require-native-artifacts`: validates the tag
  push shape, reads the single `GitOrigin-RevId` trailer off the tagged commit to get the source SHA,
  confirms that SHA is reachable from canonical main, downloads the source tarball and compares the
  expected Copybara export tree against the mirror's tagged tree file by file, checks CI and the
  required-check set, and resolves the native run id and attempt.
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

## Confirming it worked

```bash
gh api repos/hopmesh/hop-sdk-apple/releases --jq '.[].tag_name'
curl -sI -L https://github.com/hopmesh/hop-sdk-apple/releases/download/v0.0.1/libhop.xcframework.zip \
  | head -1
```

Then resolve it the way a consumer would, from a scratch directory outside this repo, with a
`Package.swift` that depends on `https://github.com/hopmesh/hop-sdk-apple.git` at `v0.0.1` and
`swift package resolve`. SwiftPM verifies the checksum itself on download, so a successful resolve is
the end-to-end proof.

A release does not retire the `Package.local.swift` swap. Every in-tree Apple package depends on
`sdk/apple` by path, and the published manifest would hand them the archive from the last release,
not the core they are being tested against, so `tools/local-ci-mirror.sh` and the CI `apple` job keep
swapping. What a release buys is that outside consumers can resolve the package at all. When you need
the swap by hand, use the wrapper rather than a manual `cp`:

```bash
sdk/apple/with-local-framework.sh swift test
```

`with-local-framework.sh` restores `Package.swift` from a trap on exit, which a hand-run `cp` does
not. `tools/package-export-smoke.test.sh` (run by `tools/local-ci-mirror.sh` and by the CI
`docs-tokens` job) fails if the local variant is ever committed.

## Reproducibility note: why step 5 exists

The archive is very nearly reproducible, but not quite, and the gap is worth knowing before you plan
a release.

Source SHAs `500625ba01afe569f80c354d1640ffaaaba1fc76` and `0649a8de5a29092300f4614490ba04060740ef37`
are adjacent main commits differing only in 27 generated `CHANGELOG.md` files, nothing that is
compiled. Their `libhop.xcframework.zip` archives still differ:

```
0e9b6ea078a2d20b74495dd3d64695fc57f402b067799247f2b0f38133b6d06a   500625b
c54aef7f8926b092fd13748d50dcb9a0f1bd4b7c1fc6d3fa0c1963381a80e190   0649a8d
```

Unpacking both and comparing file by file, every `libhop.a` slice and every header is byte identical.
The only difference is `libhop.xcframework/Info.plist`, where `xcodebuild -create-xcframework` emits
the `AvailableLibraries` entries in a different order between runs. `tools/native-artifacts.py
pack_archive` is fully deterministic (fixed 1980 timestamps, zeroed uid and gid, sorted paths), so
the nondeterminism is entirely upstream of it, in `xcodebuild`.

That is why the checksum you commit in step 4 is not guaranteed to survive step 5 even though your
commit touches nothing that is compiled: the next run may order the plist differently. The recheck in
step 5 is cheap and catches it.

The fix, if this becomes annoying rather than merely careful: normalize `Info.plist` in
`sdk/apple/build-xcframework.sh` after `xcodebuild -create-xcframework`, sorting `AvailableLibraries`
by `LibraryIdentifier` before `tools/native-artifacts.py apple-manifest` runs.
`native-artifacts.py:apple_architecture_value` already sorts its slices and compares platform tuples
as a set, so it is indifferent to plist order; only the archive bytes care. That change makes the
archive fully reproducible and turns the committed checksum into a genuine fixed point, at the cost
of one release cycle where the checksum has to be re-read because the archive bytes moved.

## Appendix: the 178 MB xcframework in drivers/apple/HopDriver

Separate problem, same shape. `drivers/apple/HopDriver/Frameworks/HopFFI.xcframework` is 178 MB of
build output across ten files, and it is tracked in git even though `.gitignore:1` lists the
directory (an ignore rule does not untrack an already-tracked path).

The package consumes it as a local path binary target:

```swift
.binaryTarget(name: "hopFFI", path: "Frameworks/HopFFI.xcframework")
```

**The mirror retirement changed what this appendix is for.** It used to argue against converting that
to a remote `url` + `checksum` target on the grounds that `hop-driver-apple` would stop resolving for
everyone until a release existed at that URL. `hop-driver-apple` is gone: `components.json` retains
only `hop-sdk-go`, `hop-sdk-crystal`, and `hop-sdk-apple`, and the driver is consumed solely as a
monorepo sibling. With no published driver package there is no external resolver to break, and so no
reason to convert at all. The local path target is the correct permanent design, not a stopgap.

That removes the work. It does not remove the bytes, and the part that survives is worth stating
plainly: 178 MB of build output sits in monorepo history, and the monorepo is headed for public.
Untracking shrinks a fresh checkout and reclaims nothing from `.git`, because the blobs stay in every
commit that carried them. Only a history rewrite reclaims that, and that decision was already made
the other way for `docs/audits` and `business`, which were split out with Copybara specifically to
avoid rewriting 717 commits. The same reasoning applies here, so the bytes stay unless something
else forces a rewrite.

The list below is retained as research, not as a plan. It applies only if a published driver package
ever returns, in which case these are its prerequisites, in dependency order:

1. **A canonical build for this artifact.** `HopFFI.xcframework` is not the C-ABI framework. It is
   the UniFFI framework built by `tools/build-xcframework.sh` (UniFFI bindgen plus
   `Sources/HopFFIBindings/hop.swift`), and it defaults to `HOP_SQLCIPHER=1`, which
   `native-artifacts.yml` does not build. `native-artifacts.yml`'s `apple` job builds only
   `sdk/apple/build-xcframework.sh` (the C ABI, `HOP_SQLCIPHER: '0'`). So the workflow needs a second
   packed artifact, something like a `driver-apple-xcframework` target, packed through
   `tools/native-artifacts.py pack` so it lands in the signed manifest with the rest.

2. **Two closed inventories in `tools/native-artifacts.py` have to grow.** `NATIVE_TARGET_FILENAMES`
   is an exact 14-entry map of target to filename, and the manifest verifier requires equality, not
   containment:

   ```python
   require(actual_inventory == NATIVE_TARGET_FILENAMES,
           "manifest does not contain the canonical native target inventory")
   ```

   `PARTIAL_ARTIFACT_TARGETS` similarly declares which targets each uploaded partial carries
   (`native-apple` currently carries exactly `apple-xcframework`, `aarch64-apple-darwin`,
   `x86_64-apple-darwin`). A driver framework needs an entry in both, plus a branch in the `attest`
   job's filename-to-target mapping, which today special-cases only `libhop.xcframework.zip`. The
   Sigstore subject set is derived from the manifest, so it follows automatically.

3. **A driver validator in the export smoke.** `tools/package-export-smoke.py` has
   `PACKAGE_COMPONENTS = ("hop-sdk-go", "hop-sdk-elixir", "hop-sdk-apple", "hop-sdk-android",
   "hop-embedded")` and a `validate_apple` that pins the release URL, the checksum, the archive
   inventory, the slice set, and the ABI version. There is no driver component and no driver
   validator; both have to be written, or the driver's published manifest gets no guard at all and
   repeats exactly the failure this document exists to prevent.

4. **A release workflow that attaches assets.** `drivers/apple/HopDriver/.github/workflows/release.yml`
   today runs `swift package describe`, creates a `release-manifest.json`, verifies provenance, and
   calls `softprops/action-gh-release` with **no `files:` key at all**. It publishes an empty release.
   It would need the download, provenance verify, checksum equality test, and `files:` list that
   `sdk/apple/.github/workflows/release.yml` already has, plus `--require-native-artifacts` on its
   `release-provenance.py` call, which it currently does not pass.

5. **The same source-read credentials.** It mints the same `HOP_SOURCE_APP_ID` and
   `HOP_SOURCE_APP_PRIVATE_KEY` that do not exist yet. Blocker 1 above covers both mirrors.

6. **A local development path.** `sdk/apple` has `Package.local.swift`, `with-local-framework.sh`,
   and `install-local-xcframework.py`. `HopDriver` has none of those, so every in-tree driver build
   would break the moment the manifest goes remote. Port all three before flipping the target, not
   after.

7. **Only then, untracking.** `git rm --cached -r drivers/apple/HopDriver/Frameworks/` plus a
   `repo-integrity-guard.sh` check that keeps it out. This shrinks the checkout, not `.git`, so it is
   cosmetic with respect to the 178 MB; see the note above the list.
