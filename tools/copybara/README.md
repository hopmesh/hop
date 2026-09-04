# Component mirroring with Copybara

This repo, `hopmesh/hop`, is the canonical monorepo and the source of truth. Copybara mirrors a
component subtree to its own standalone repo (so it has its own package page, issues, and PRs) and
brings external contributions back, without forking. It is the Meta react-native / relay pattern,
done with [Copybara](https://github.com/google/copybara) instead of fbshipit.

Three components mirror today: `hop-sdk-go`, `hop-sdk-crystal`, and `hop-sdk-apple`. A fourth,
`hop-bearers-apple`, is WIRED but NOT MIRRORED: it has a `components.json` entry, a `copy.bara.sky`
registration, and its own `release.yml` and `sync-back.yml`, but the repository
`hopmesh/hop-bearers-apple` does not exist and never has, so nothing has ever been exported to it.
Creating it is a human action (`tools/copybara/bootstrap-mirrors.sh`, which this repository's
automation deliberately cannot perform), followed by one seeded export with `init_history=true`.
Until both happen, the Apple bearers are available only inside this repository, and any consumer
instruction naming that mirror URL is aspirational. `tools/copybara/components.json` is the dispatch
allowlist and `tools/copybara/copy.bara.sky` holds the matching `COMPONENTS` list used to generate an
export and import workflow for each. Their CI self-test rejects any drift between the two. Twenty
other components were mirrored until the 2026-08 retirement and their repos deleted;
`hop-bearers-apple` is one of those twenty, wired for restoration, and the other nineteen live only
here. See `docs/repo-catalog.md`.

These mirrors exist because their package managers resolve FROM a git repo root: SwiftPM needs
`Package.swift` at the repository root, shards needs `shard.yml` there, and the Go module proxy
resolves a module from its repo root. Every other component publishes an artifact to a registry that
hosts the artifact itself, so it does not need a standalone repo.

## What it does

For each component, `copy.bara.sky` generates two workflows, `<mirror>_export` and `<mirror>_import`:

- **export** (`hop:<prefix>` -> `hopmesh/<mirror>`): replays every monorepo commit that touches the
  subtree, commit-for-commit, into the mirror, stripping the prefix so the subtree becomes the mirror's
  root. `CLAUDE.md` (monorepo-internal dev guidance) is left out of the public mirror.
- **import** (`<mirror>` PR -> monorepo PR): takes a PR opened on the mirror, re-adds the prefix, and
  opens it as a **PR on this repo** (never a direct push to `main`), so external contributions still
  go through review. It never rewrites the monorepo-internal files.

The GitHub Action is `.github/workflows/sync-components.yml`, a single dispatch parameterized by
`component` (the mirror repo name) and `direction`.

## Quick sanity check (no Docker, no Copybara)

You can see the exact extraction Copybara automates with plain git:

```sh
ref=$(git subtree split --prefix=sdk/go origin/main)
git ls-tree --name-only "$ref"     # the mirror's root: go.mod, hop.go, endpoint.go, examples/, ...
git log --oneline "$ref"           # each commit is a real monorepo commit that touched sdk/go
```

Copybara does the same extraction, plus the `CLAUDE.md` filter, the prefix move, and the incremental
state tracking so it can run continuously.

## One-time bootstrap

1. **Create the empty destination repo** `hopmesh/hop-sdk-go` (no README, no license, no commit):

   ```sh
   gh repo create hopmesh/hop-sdk-go --public \
     --description "Receive Hop mesh messages in Go with a net/http-shaped surface over the libhop C ABI (cgo). A Go module."
   ```

2. **Create the sync GitHub App.** Install it on `hopmesh/hop` and every mirror. Grant Actions
   read/write, Contents read/write, and Pull requests read. In `hopmesh/hop`, create a protected
   `component-sync` environment restricted to `main`, require a reviewer other than the dispatcher,
   enable prevention of self-review, and store `HOP_SYNC_APP_ID` and `HOP_SYNC_APP_PRIVATE_KEY` only as
   environment secrets. Mirror dispatch workflows that retain these credentials need the same protected
   environment. Do not create repository or organization copies of these secrets, a shared PAT, or a
   `COPYBARA_TOKEN`. Live environments `component-sync`, `release`, and `github-pages` enforce deployment
   branch policy restricted to protected `main` branches (`protected_branches: true, custom_branch_policies: false`),
   and `tools/check-branch-protection.sh` asserts this policy on every scheduled run and push. Workflows
   explicitly verify `github.ref == 'refs/heads/main'` before any secret or deployment step, so manual
   dispatches on arbitrary non-main refs cannot access environment authority.

3. **Create the source-verifier GitHub App.** Install this separate read-only App on
   `hopmesh/hop` with Actions read, Attestations read, Checks read, and Contents read. Store its credentials as
   `HOP_SOURCE_APP_ID` and `HOP_SOURCE_APP_PRIVATE_KEY` in each publishing mirror's `release`
   environment. Release jobs use it to prove that the mirror tag exactly matches a successful canonical
   `main` commit before any registry or GitHub publish step runs.

4. **Protect releases.** In every mirror that carries `.github/workflows/release.yml`, create an
   environment named `release`, add a required reviewer, and configure each registry trusted publisher
   with environment `release`. The canonical monorepo `release` environment needs
    `NATIVE_ARTIFACT_SIGNING_KEY`, whose public half is committed as
    `tools/native-artifacts-public.pem`. Native wrapper releases download the successful canonical
    native workflow by immutable run and artifact ID, verify that signature and every archive digest,
    then verify the attached GitHub OIDC SLSA provenance bundle before publishing. The canonical
    workflow mirrors the same provenance to GitHub's attestation API when the repository plan supports
    hosted storage; the attached Sigstore bundle is always authoritative.

   The libhop-only Release App that used to supply `HOP_RELEASE_APP_ID` and `HOP_RELEASE_APP_PRIVATE_KEY`
   retired along with its repo, and so did every registry credential the old fleet needed (`MAVEN_*`,
   `PLATFORMIO_AUTH_TOKEN`, `HEX_API_KEY`). Every registered mirror
   publishes by pushing a git tag, so none of them needs a registry secret at all.

5. **Seed each mirror** with its full history (one-off, per component). ITERATIVE mode needs a baseline,
   so the FIRST export passes `init_history=true`:

   ```sh
   gh workflow run "Sync component" -f component=hop-sdk-go -f direction=export -f init_history=true
   ```

   After the first run, leave `init_history` off; subsequent exports are incremental.

## Where the conversation happens, and where the merge happens

One rule: **`main` on this repo is the source of truth, and every merge happens here.** What varies
is where the *conversation* is:

| Work | Conversation | Merge | How it reaches the other side |
| --- | --- | --- | --- |
| **External contribution** | a **PR on the mirror** (public) | this repo (the PR is imported here) | import (mirror PR -> monorepo PR), then export cascades back out |
| **First-party work** | a **PR on this repo** | this repo | export cascades to the mirror on merge (unless held back, below) |

So a public contributor discusses on the mirror; the change is imported as a monorepo PR, reviewed and
merged here, and the export publishes the result back to the mirror. The mirror PR is the public
record; the monorepo PR is the merge of record.

### Sync-back (mirror PR -> monorepo PR)

Every component subtree ships a `.github/workflows/sync-back.yml` (carried out to each mirror by the
export). It fires on a mirror **pull request** and asks the monorepo to import it (Copybara
`CHANGE_REQUEST`), which opens the matching monorepo PR. Each file carries a literal allowlisted
component name; edit it in the monorepo, never in a mirror.

No loop guard is needed: the export cascades out as a **push**, and a push does not fire pull-request
events, so the sync-back never sees the export's own commits. It runs under `pull_request_target` and
only dispatches, never checking out PR code. It mints a token scoped only to `hopmesh/hop` with
Actions write from the sync App credentials; fork code never executes in the privileged job.

### Confidentiality (what the export publishes)

The export only ever ships a component's **own subtree** (minus `CLAUDE.md`), so nothing outside that
subtree is visible to a mirror. For a per-change embargo on top of that, gate the
cascade on a label: publish a merge only if its monorepo PR is **not** labeled `confidential` (or require
an explicit `publish` label). That gate lives in the export trigger, not in a change-request, so a
reviewed monorepo merge still flows out with no extra approval when it is not held back.

To import a mirror PR by hand instead:

```sh
gh workflow run "Sync component" -f component=hop-sdk-go -f direction=import
```

## Running Copybara locally

Copybara is a JVM tool, easiest via its container. Two things about the pinned image and the committed
config trip people up, so read both before trying.

**The pinned image is ENV-driven, not argv-driven.** `olivr/copybara` takes its subcommand, config,
workflow, and extra flags from environment variables. Passing them as arguments
(`copybara migrate <config> <workflow>`) does not error: the entrypoint ignores them and silently falls
through to looking for a migration named `default`, which this config does not define. Set the
variables instead, and keep the trailing `copybara` argument that invokes the wrapper:

```sh
docker run --rm -v "$PWD":/usr/src/app -w /usr/src/app \
  -v ~/.gitconfig:/root/.gitconfig \
  -e COPYBARA_SUBCOMMAND=migrate \
  -e COPYBARA_CONFIG=tools/copybara/copy.bara.sky \
  -e COPYBARA_WORKFLOW=hop-sdk-go_export \
  -e COPYBARA_OPTIONS='--init-history --force' \
  olivr/copybara:20230129@sha256:87e2e9089344e64693faebb2ee0ed33b8797358c0420b0fa98325ca611e98679 copybara
```

A fifth variable, `COPYBARA_SOURCEREF`, is appended by the wrapper as copybara's LAST positional
argument. `sync-components.yml` uses it to hand `github_pr_origin` the mirror PR number on import, and
a seed run uses it to name the source ref. Leave it unset and the origin's own `ref` applies, which for
every workflow here is `main`.

**The committed config cannot be rehearsed against a local destination.** Each component's `_import`
workflow uses `git.github_pr_destination`, which rejects a non-GitHub URL outright, so pointing
`copy.bara.sky` at a `file://` bare repo fails at config load and proves nothing. To exercise an export
locally, copy the config to a scratch file and rewrite the destination there. Do not expect `file://`
to work against the committed config.

**Name the source ref explicitly, and reconcile file counts afterwards.** The workflows take their
origin from the remote at `main`, but any rehearsal from a local checkout is only as fresh as that
checkout's `main`, and a stale one fails silently: one run whose local `main` sat 51 commits behind
`origin/main` produced an export missing nine files and carrying `bundle-v14.json` where `main` had
v15. The boundary check still passed, because the path boundary was correct and only the contents were
old. So set `COPYBARA_SOURCEREF=origin/main` rather than trusting whatever `main` points at locally,
then compare the exported file count against the source before trusting the run.

CI uses the digest-pinned `olivr/copybara:20230129` image with a read-only filesystem, isolated
credentials, and a fixed dispatch map. Local runs should use that same digest.

## Troubleshooting a dead export

Two failure modes have both been reproduced against the real pinned container, and both look like
something else when you only read CI's red X:

**The App token mint dies with `The 'client-id' ... must be set to a non-empty string`.** That is
GitHub resolving an unset secret to the empty string: `HOP_SYNC_APP_ID` /
`HOP_SYNC_APP_PRIVATE_KEY` are not seeded where the job runs (the protected `component-sync`
environment). Every run that actually needed to export fails there, while runs whose merge touched
no mirrored subtree report success with nothing to do, so a green Sync run proves nothing about
export health. Check what exists with `gh api repos/hopmesh/hop/actions/secrets` and the
`component-sync` environment's secrets, and re-seed from the App's credentials (repository
administrators hold them; the workflow cannot create them).

**Copybara dies with `Cannot find reference(s): [<sha>, refs/tags/*]`.** The `<sha>` is the
`GitOrigin-RevId` trailer on the MIRROR's `main` head: ITERATIVE mode reads it as "the last migrated
origin commit" and resolves it against the ORIGIN before it looks at a single file. If the mirror's
newest such trailer names a commit canonical `main` does not have, which happens whenever something
other than this repository has exported to that mirror, every later export dies at that fetch, even
with secrets in place.

The repair does NOT require touching the mirror. Dispatch the export with `last_rev` set to a full
canonical SHA to resume from:

```sh
gh workflow run "Sync component" -f component=hop-sdk-apple -f direction=export \
  -f last_rev=<40-char canonical sha>
```

`tools/copybara/dispatch.py` validates it (export only, never with `init_history`, exactly 40 lowercase
hex, and it must resolve in this repository) and folds it into the Copybara options; no privileged job
ever reads the raw input. The export's own commits carry resolvable trailers afterwards, so the next
run needs no override: the watermark self-heals.

Two things worth knowing before using it. The value is a claim about what the mirror already has, so
choosing a commit far behind the mirror's real content re-exports everything after it, and choosing
one ahead of it silently skips the difference. And the watermark is a SINGLE slot: if another
repository also exports to that mirror, repairing it for this one makes the next export from the other
one fail the same way, which makes the choice a cutover rather than a fix.

An EMPTY commit carrying a corrected trailer does not work, which is worth stating because it is the
obvious first idea: the destination-status lookup is path filtered, so git history simplification skips
a commit that touches no exported path and the poisoned trailer is read again. A commit that touches a
file does work, but `last_rev` is better: it mutates nothing.

You can diagnose and rehearse all of this without any push rights, by pointing the pinned container at
local clones with `url.<base>.insteadOf` rewrites and a `file://` destination; that is exactly how
these modes were isolated, and an export run that way is what proves a repair correct before anyone
touches the real mirror.

## A standalone mirror needs libhop

Every endpoint SDK binds `libhop`, the C ABI built from `core/`. The monorepo builds it in tree; a
standalone mirror has no `core/`, so its own CI and its consumers must supply `libhop`: either a
prebuilt binary the package downloads, or `HOP_LIBDIR` pointing at one. `sdk/go` binds it through cgo
and `sdk/crystal` binds the C ABI directly, so both need this. `sdk/apple` is the exception: it ships a
prebuilt xcframework inside the package, so the binary travels with the source. `bearers/apple` needs
neither treatment: it does not bind libhop at all, it depends only on the published `hop-sdk-apple`
package's `HopContract` product, so the framework travels with the SDK one hop away. That is a packaging
decision per mirror, independent of the sync.

## Adding another component

Add the component to `components.json`, the matching tuple to `copy.bara.sky`, the fixed workflow
choice to `sync-components.yml`, and its literal component name to the subtree's `sync-back.yml`.
The dispatch self-test enforces the first three mappings. Then add the mirror to
`bootstrap-mirrors.sh`, create the repo, and run the seed command above.

The components wired today are the three that survived the 2026-08 retirement (`hop-sdk-go`,
`hop-sdk-crystal`, `hop-sdk-apple`) plus `hop-bearers-apple`, the first retired name wired for return.
Its repo has NOT been recreated, so the config is complete and the destination is absent: the export
would fail on a missing repository, not on a Copybara error. Every component subtree still carries its
own `LICENSE.md` (FSL-1.1-ALv2 for `services/*`, Apache-2.0 for everything else including the core),
so any of them is ready to stand alone if it is mirrored again.
Bringing back one of the nineteen remaining retired names still means recreating its repository first,
because the old one was deleted; `docs/repo-catalog.md` lists them.

## Historical note: the 2026-08 handover (already done)

This repo is itself the product of a one-time Copybara migration, not an ongoing sync target.
`copy.bara.sky` used to live in the old private monorepo (`hopmesh/monorepo`) and carry two whole-repo
`--init-history` migrations: `internal_export`, which moved the commercial backend and production
estate (`services/hop-accountd`, `services/hop-billingd`, `apps/web/console`, `infra/`) into
`hopmesh/platform` and the audit/business/mockups trees (`docs/audits`, `business/`, `mockups/`) into
`hopmesh/internal`, and `public_export`, which seeded this repo with everything else, the private
paths excluded from history entirely (which is why no history rewrite was needed). Both migrations ran
and the private trees were deleted from the source, but `hopmesh/monorepo` is private and NOT archived;
it kept running its own automation after this repository became canonical (Copybara export to the three
mirrors, Pages for hopme.sh, native artifacts, release tags, dependabot self-merge, changelog regeneration)
with a tree frozen at 2026-08-19 and C ABI 5; on 2026-09-04 its mirror-writing workflows
(sync-components.yml, release-tags.yml) and pages.yml were disabled and the hopme.sh Pages site was
moved to this repository; archiving the repository itself remains an owner action. Those workflows and
their `PRIVATE_TREES` boundary list were removed from the config when this repo became canonical; there
is no public/private split left to maintain here.
`SVC-xxx`, `PROC-xxx`) and the root licence question were settled as part of that handover.
