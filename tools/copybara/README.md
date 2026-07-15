# Component mirroring with Copybara

This monorepo is the source of truth. Copybara mirrors a component subtree to its own standalone repo
(so it has its own npm package page, issues, and PRs) and brings external contributions back, without
forking. It is the Meta react-native / relay pattern, done with [Copybara](https://github.com/google/copybara)
instead of fbshipit.

Every component is wired up: `tools/copybara/copy.bara.sky` holds a `COMPONENTS` list (the 8 SDK repos
plus the core, service, bearer, and driver repos) and a loop that generates an export + import workflow
for each. Adding a new one is a single line in that list.

## What it does

For each component, `copy.bara.sky` generates two workflows, `<mirror>_export` and `<mirror>_import`:

- **export** (`monorepo:<prefix>` -> `hopmesh/<mirror>`): replays every monorepo commit that touches the
  subtree, commit-for-commit, into the mirror, stripping the prefix so the subtree becomes the mirror's
  root. `CLAUDE.md` (monorepo-internal dev guidance) is left out of the public mirror.
- **import** (`<mirror>` PR -> monorepo PR): takes a PR opened on the mirror, re-adds the prefix, and
  opens it as a **PR on the monorepo** (never a direct push to `main`), so external contributions still
  go through review. It never rewrites the monorepo-internal files.

The GitHub Action is `.github/workflows/sync-components.yml`, a single dispatch parameterized by
`component` (the mirror repo name) and `direction`.

## Quick sanity check (no Docker, no Copybara)

You can see the exact extraction Copybara automates with plain git:

```sh
ref=$(git subtree split --prefix=sdk/node origin/main)
git ls-tree --name-only "$ref"     # the mirror's root: package.json, lib/, examples/, ...
git log --oneline "$ref"           # each commit is a real monorepo commit that touched sdk/node
```

Copybara does the same extraction, plus the `CLAUDE.md` filter, the prefix move, and the incremental
state tracking so it can run continuously.

## One-time bootstrap

1. **Create the empty destination repo** `hopmesh/hop-sdk-node` (no README, no license, no commit):

   ```sh
   gh repo create hopmesh/hop-sdk-node --public --description "Hop endpoint SDK for Node (mirror of hopmesh/hop:sdk/node)"
   ```

2. **Create a token** with `repo` scope on BOTH `hopmesh/hop` and `hopmesh/hop-sdk-node` (a classic PAT,
   a fine-grained PAT scoped to both, or a GitHub App installation token). The default `GITHUB_TOKEN` is
   scoped to this repo only and cannot push to the mirror. Add it as a repo secret on `hopmesh/hop`:

   ```sh
   gh secret set COPYBARA_TOKEN --repo hopmesh/hop --body "<token>"
   ```

   Steps 1 and 2 (create the mirror repos + set `COPYBARA_TOKEN`) are automated by
   `tools/copybara/bootstrap-mirrors.sh`, which you run yourself.

3. **Seed each mirror** with its full history (one-off, per component). ITERATIVE mode needs a baseline,
   so the FIRST export passes `init_history=true`:

   ```sh
   gh workflow run "Sync component" -f component=hop-sdk-node -f direction=export -f init_history=true
   ```

   After the first run, leave `init_history` off; subsequent exports are incremental.

## Where the conversation happens, and where the merge happens

One rule: **`main` on the monorepo is the source of truth, and every merge happens there.** What varies
is where the *conversation* is:

| Work | Conversation | Merge | How it reaches the other side |
| --- | --- | --- | --- |
| **Public** (external contribution, open by design) | a **PR on the mirror** (public) | the monorepo (the PR is imported there) | import (mirror PR -> monorepo PR), then export cascades back out |
| **Internal / confidential** | a **PR on the monorepo** (private, can be locked) | the monorepo | export cascades to the mirror on merge (unless held back, below) |

So a public contributor discusses on the mirror; the change is imported as a monorepo PR, reviewed and
merged there, and the export publishes the result back to the mirror. The mirror PR is the public
record; the monorepo PR is the merge of record.

### Sync-back (mirror PR -> monorepo PR)

Every component subtree ships a `.github/workflows/sync-back.yml` (carried out to each mirror by the
export). It fires on a mirror **pull request** and asks the monorepo to import it (Copybara
`CHANGE_REQUEST`), which opens the matching monorepo PR. It derives its own component name from the
mirror repo, so the one file is identical everywhere; edit it in the monorepo, never in a mirror.

No loop guard is needed: the export cascades out as a **push**, and a push does not fire pull-request
events, so the sync-back never sees the export's own commits. It runs under `pull_request_target` (so the
token is available even on a fork PR) and only dispatches, never checking out PR code. It needs an **org
secret `HOP_SYNC_TOKEN`** shared to the mirrors, a token with push access to `hopmesh/hop`.

### Confidentiality (what the export publishes)

The export only ever ships a component's **own subtree** (minus `CLAUDE.md`), so nothing else in the
private monorepo is visible to a public mirror. For a per-change embargo on top of that, gate the
cascade on a label: publish a merge only if its monorepo PR is **not** labeled `confidential` (or require
an explicit `publish` label). That gate lives in the export trigger, not in a change-request, so a
reviewed monorepo merge still flows out with no extra approval when it is not held back.

To import a mirror PR by hand instead:

```sh
gh workflow run "Sync component" -f component=hop-sdk-node -f direction=import
```

## Running Copybara locally

Copybara is a JVM tool, easiest via its container. Against a **local** bare repo as the destination you
can prove the whole export without touching GitHub:

```sh
# a throwaway local "mirror"
git init --bare /tmp/hop-sdk-node.git
# point a scratch config at file:// URLs, then:
docker run --rm -v "$PWD":/usr/src/app -w /usr/src/app \
  -v ~/.gitconfig:/root/.gitconfig \
  <copybara-image> copybara tools/copybara/copy.bara.sky export --init-history --force
```

(Any maintained Copybara image works; the CI uses `olivr/copybara-action`, which wraps the container and
the git-credential setup for you.)

## The standalone repo needs libhop

`sdk/node` binds `libhop` via `koffi`, resolved from `HOP_LIBDIR` or a local `target/{debug,release}`
build. The monorepo builds `libhop` from `core/`; the standalone mirror has no `core/`, so its own CI (and
its consumers) must provide `libhop`: either a published prebuilt binary the package downloads, or
`HOP_LIBDIR` pointing at one. That is a packaging decision for the mirror, independent of the sync.

## Adding another component

Add one line, `("<monorepo/subtree>", "<mirror-repo-name>")`, to the `COMPONENTS` list in
`copy.bara.sky`. The loop generates its export + import workflows automatically, and the single
`sync-components.yml` dispatch already handles any component by name. Then create + seed its mirror
(add it to `bootstrap-mirrors.sh`, run that, then the seed command above).

The components wired today: the 8 SDKs, plus `hop-core`, `libhop`, `hop-wasm`, the two stores, the two
bearer repos, the two driver repos, and the three services. Each already carries its own `LICENSE.md`
(Apache-2.0 for the SDKs, FSL-1.1-ALv2 for the rest), so it is ready to stand alone.
