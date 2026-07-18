# Component mirroring with Copybara

This monorepo is the source of truth. Copybara mirrors a component subtree to its own standalone repo
(so it has its own npm package page, issues, and PRs) and brings external contributions back, without
forking. It is the Meta react-native / relay pattern, done with [Copybara](https://github.com/google/copybara)
instead of fbshipit.

Every component is wired up: `tools/copybara/components.json` is the dispatch allowlist and
`tools/copybara/copy.bara.sky` holds the matching `COMPONENTS` list used to generate an export and
import workflow for each. Their CI self-test rejects any drift between the two.

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
   gh repo create hopmesh/hop-sdk-node --public --description "Hop endpoint SDK for Node (mirror of hopmesh/monorepo:sdk/node)"
   ```

2. **Create the sync GitHub App.** Install it on `hopmesh/monorepo` and every mirror. Grant Actions
   read/write, Contents read/write, and Pull requests read. In `hopmesh/monorepo`, create a protected
   `component-sync` environment restricted to `main`, require a reviewer other than the dispatcher,
   enable prevention of self-review, and store `HOP_SYNC_APP_ID` and `HOP_SYNC_APP_PRIVATE_KEY` only as
   environment secrets. Mirror dispatch workflows that retain these credentials need the same protected
   environment. Do not create repository or organization copies of these secrets, a shared PAT, or a
   `COPYBARA_TOKEN`. Repository administrators configure these settings; the workflow only references
   them and does not create or verify the environment policy.

3. **Create the source-verifier GitHub App.** Install this separate read-only App on
   `hopmesh/monorepo` with Actions read, Attestations read, Checks read, and Contents read. Store its credentials as
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

   The canonical environment also needs `HOP_RELEASE_APP_ID` and `HOP_RELEASE_APP_PRIVATE_KEY`
   from a separate App installed only on `hopmesh/libhop` with Contents write.

   Android additionally needs `MAVEN_USERNAME`, `MAVEN_PASSWORD`, `MAVEN_GPG_KEY`, and
   `MAVEN_GPG_PASSPHRASE` in its protected release environment. Embedded
   needs `PLATFORMIO_AUTH_TOKEN`; Elixir needs `HEX_API_KEY`. The standalone Node CI still needs its
   legacy libhop checksum variables until it is moved to the shared native manifest installer.

5. **Seed each mirror** with its full history (one-off, per component). ITERATIVE mode needs a baseline,
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
`CHANGE_REQUEST`), which opens the matching monorepo PR. Each file carries a literal allowlisted
component name; edit it in the monorepo, never in a mirror.

No loop guard is needed: the export cascades out as a **push**, and a push does not fire pull-request
events, so the sync-back never sees the export's own commits. It runs under `pull_request_target` and
only dispatches, never checking out PR code. It mints a token scoped only to `hopmesh/monorepo` with
Actions write from the sync App credentials; fork code never executes in the privileged job.

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
  olivr/copybara:20230129@sha256:87e2e9089344e64693faebb2ee0ed33b8797358c0420b0fa98325ca611e98679 \
  copybara tools/copybara/copy.bara.sky export --init-history --force
```

CI uses the digest-pinned `olivr/copybara:20230129` image with a read-only filesystem, isolated
credentials, and a fixed dispatch map. Local tests should use that same digest.

## The standalone repo needs libhop

`sdk/node` binds `libhop` via `koffi`, resolved from `HOP_LIBDIR` or a local `target/{debug,release}`
build. The monorepo builds `libhop` from `core/`; the standalone mirror has no `core/`, so its own CI (and
its consumers) must provide `libhop`: either a published prebuilt binary the package downloads, or
`HOP_LIBDIR` pointing at one. That is a packaging decision for the mirror, independent of the sync.

## Adding another component

Add the component to `components.json`, the matching tuple to `copy.bara.sky`, the fixed workflow
choice to `sync-components.yml`, and its literal component name to the subtree's `sync-back.yml`.
The dispatch self-test enforces the first three mappings. Then add the mirror to
`bootstrap-mirrors.sh`, create it, and run the seed command above.

The components wired today: the 8 SDKs, plus `hop-core`, `libhop`, `hop-wasm`, the two stores, the two
bearer repos, the two driver repos, and the three services. Each already carries its own `LICENSE.md`
(Apache-2.0 for the SDKs, FSL-1.1-ALv2 for the rest), so it is ready to stand alone.
