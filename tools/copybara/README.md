# Component mirroring with Copybara

This monorepo is the source of truth. Copybara mirrors a component subtree to its own standalone repo
(so it has its own npm package page, issues, and PRs) and brings external contributions back, without
forking. It is the Meta react-native / relay pattern, done with [Copybara](https://github.com/google/copybara)
instead of fbshipit.

The first component wired up is `sdk/node` -> `hopmesh/hop-sdk-node`. Adding more is a copy-paste (see
the last section).

## What it does

`tools/copybara/copy.bara.sky` declares two workflows:

- **export** (`monorepo:sdk/node` -> `hopmesh/hop-sdk-node`): replays every monorepo commit that touches
  `sdk/node`, commit-for-commit, into the mirror, stripping the `sdk/node/` prefix so the subtree becomes
  the mirror's root. `CLAUDE.md` (monorepo-internal dev guidance) is left out of the public mirror.
- **import** (`hop-sdk-node` PR -> monorepo PR): takes a PR opened on the mirror, re-adds the `sdk/node/`
  prefix, and opens it as a **PR on the monorepo** (never a direct push to `main`), so external
  contributions still go through review. It never rewrites the monorepo-internal files.

The GitHub Action is `.github/workflows/sync-sdk-node.yml`.

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

3. **Seed the mirror** with the full history (one-off). ITERATIVE mode needs a baseline, so the first
   run imports history with `--init-history`. Trigger the export manually and, just for this first run,
   append `--init-history` to `copybara_options` in the workflow (or run Copybara locally, below):

   ```sh
   gh workflow run "Sync sdk/node" -f workflow=export
   ```

4. **Turn on continuous export**: uncomment the `push:` block in `.github/workflows/sync-sdk-node.yml`.
   From then on every merge to `main` that touches `sdk/node` mirrors out automatically, incrementally.

## Importing a contribution back

When someone opens a PR on `hopmesh/hop-sdk-node`, run the import workflow to bring it back as a monorepo
PR (reviewed like any other change):

```sh
gh workflow run "Sync sdk/node" -f workflow=import
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

Copy the pattern:

1. Add an `export`/`import` workflow pair to `copy.bara.sky` (or a new `copy.bara.sky` under
   `tools/copybara/<component>/`) with the component's `PREFIX` and `MIRROR` repo.
2. Copy `.github/workflows/sync-sdk-node.yml` to `sync-<component>.yml`, changing the paths, the
   `destination_repo`, and the `custom_config`/`workflow` names.
3. Run the one-time bootstrap for that component's mirror.

Good next candidates: `core/hop-core`, each `sdk/<lang>`, `services/hop-relayd`. Each already carries its
own FSL-1.1-ALv2 `LICENSE.md`, so it is ready to stand alone.
