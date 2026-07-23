# PR-level sync: private monorepo and public mirrors

The monorepo is the source of truth. Each first-party subtree is mirrored to its own public repo so a
component can have its own package page, issues, and PRs. Copybara moves the code; three named
directions do the work, all dispatched through `.github/workflows/sync-components.yml` and gated by the
`authorize` preflight (protected `main`, `workflow_dispatch`, human actor, current SHA) and the
protected `component-sync` environment.

## The three directions

| direction   | origin                  | destination          | mode           | when |
| ----------- | ----------------------- | -------------------- | -------------- | ---- |
| `export`    | monorepo `main` commits | mirror `main` (push) | ITERATIVE      | carry MERGED commits out, one for one |
| `import`    | a mirror PR             | a monorepo PR        | CHANGE_REQUEST | bring an externally authored mirror PR in for review + merge |
| `export_pr` | an open monorepo PR     | a mirror PR          | CHANGE_REQUEST | surface a private PR on the mirror for public CI + discussion before it merges |

`export_pr` is the newest piece. A PR opened on the private monorepo becomes a PR on each public mirror
whose subtree it touches, so the mirror's own CI runs on it (free, on public runners) and public review
can happen before anything merges. The canonical MERGE still happens once, in the monorepo, where `main`
is branch protected. After the merge, `export` (the ITERATIVE push) carries the merged commits out to
mirror `main`, the open mirror PR goes empty, and it closes.

## Why the round trip cannot loop

`monorepo PR -> (export_pr) mirror PR -> merge in monorepo -> (export) push to mirror -> mirror PR empties`.
The merge cascades out as a PUSH, which fires no pull_request event on the mirror, and `import` only ever
triggers on mirror AUTHORED PRs. So an `export_pr` mirror PR is never re-imported, and the cycle closes
instead of feeding itself.

## Auth model (shared by all three jobs)

Git authenticates by rewriting the canonical https URLs to embed a per-repo token (`url.insteadOf`), not
a `credential.helper` store: the store helper needs to write a lock on a read-only container filesystem
and fails. The gitconfig is mounted as `/etc/gitconfig` (every git version reads it; the older container
git ignores `GIT_CONFIG_GLOBAL`) at mode 644 (the non-root container user must read it). The monorepo
side uses `github.token`; the mirror side uses a short-lived App installation token scoped to the single
mapped mirror, with contents + (for the PR directions) pull-requests + workflows write.

## Status of export_pr

`export_pr` is wired end to end with the working auth model and passes the guards and self-tests. It is
still **manual** (a human dispatch of `sync-components.yml` with `direction=export_pr`), matching
`export` and `import`. Validate it on ONE component against a live open monorepo PR before relying on it.

The next step (not yet built) is to make it automatic: a `pull_request` trigger on the monorepo that
detects which component subtrees a PR touches (the CI `changes` path filters already do this) and runs
`export_pr` for each affected component, so a PR spanning several subtrees opens one mirror PR per
component. That auto-trigger must never let mirror-authored code drive a monorepo write; the `import`
side already carries that boundary and the `sync-authority-guard` enforces it.
