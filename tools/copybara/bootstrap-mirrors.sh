#!/usr/bin/env bash
# bootstrap-mirrors.sh: create or update the standalone component repositories.
# Covers the THREE components that still mirror after the 2026-08 mirror retirement: hop-sdk-go,
# hop-sdk-crystal, and hop-sdk-apple. All three are Apache-2.0 and all three publish by pushing a git
# tag, so none of them needs a registry account or token. RUN THIS YOURSELF: creating public
# repositories is a human action, not something CI or an agent does for you. Idempotent and safe to
# re-run.
#
# Requires: `gh` authenticated with repo + admin rights on the hopmesh org.
#
# The twenty other components were retired and their repos deleted. They live on in the monorepo and
# are not separately published, so do not add one back here without recreating its repo first. See
# docs/repo-catalog.md for the full retired list and the registry fallout.
#
# Every mirror is public. Creating an empty public repo publishes nothing yet; the source only appears
# once you SEED it (the last section), which you do after the Copybara configs for each component land.
# See tools/copybara/README.md.
set -euo pipefail

ORG="hopmesh"

# "repo|description" per public repo, for the three surviving mirrors. All three are Apache-2.0.
# Descriptions say what each thing IS with no reference to any private source of truth. Kept bash-3.2
# safe (no associative arrays) so it runs on stock macOS.
MIRRORS="
hop-sdk-go|Receive Hop mesh messages in Go with a net/http-shaped surface over the libhop C ABI (cgo). A Go module.
hop-sdk-crystal|Receive Hop mesh messages in Crystal with a Sinatra/Rails-shaped surface over the libhop C ABI. On shards.
hop-sdk-apple|The Hop client SDK for Apple platforms: run a node on iOS/macOS. SwiftPM + xcframework.
"

echo "== 1. create / publish the mirror repos =="
printf '%s\n' "$MIRRORS" | while IFS='|' read -r repo desc; do
  [ -z "$repo" ] && continue
  full="$ORG/$repo"
  if gh repo view "$full" >/dev/null 2>&1; then
    echo "  exists: $full  (ensuring public + description)"
    gh repo edit "$full" --visibility public --accept-visibility-change-consequences >/dev/null || true
    gh repo edit "$full" --description "$desc" >/dev/null || true
  else
    echo "  creating (public): $full"
    gh repo create "$full" --public --description "$desc" >/dev/null
  fi
done

echo
echo "== 2. configure the GitHub Apps =="
echo "  Sync App: install on $ORG/hop and every mirror; Actions read/write, Contents read/write, Pull requests read."
echo "  Store HOP_SYNC_APP_ID and HOP_SYNC_APP_PRIVATE_KEY only in protected component-sync environments."
echo "  Source App: install only on $ORG/hop; Actions, Attestations, Checks, and Contents read."
echo "  Store HOP_SOURCE_APP_ID and HOP_SOURCE_APP_PRIVATE_KEY in each publishing mirror's release environment."
echo "  The libhop-only Release App retired with its repo: no HOP_RELEASE_APP_* credential is needed."
echo "  Do not create COPYBARA_TOKEN or HOP_SYNC_TOKEN PAT secrets."

echo
echo "== 3. protect authority environments =="
echo "  Create component-sync on $ORG/hop and every mirror; restrict it to main, require a different reviewer, and prevent self-review."
echo "  For every mirror with release.yml, create environment 'release' with a required reviewer."
echo "  The three surviving mirrors are tag-only, so no registry trusted publisher is needed."

echo
echo "== 4. seed each mirror (one-time, per component) =="
echo "  The FIRST export of a component passes init_history=true:"
echo "      gh workflow run sync-components.yml -f component=hop-sdk-go -f direction=export -f init_history=true"
echo "  Repeat for hop-sdk-crystal and hop-sdk-apple; later exports omit init_history."

echo
echo "== 5. enable security features on every repo =="
# All free on public repos, idempotent, and tolerant: a repo whose only language CodeQL does not support
# (Crystal, Elixir) simply skips the code-scanning step. Run this after the repos exist.
printf '%s\n' "$MIRRORS" | while IFS='|' read -r repo _; do
  [ -z "$repo" ] && continue
  full="$ORG/$repo"
  echo "  $full:"
  gh api -X PUT "repos/$full/vulnerability-alerts" >/dev/null 2>&1 && echo "    dependabot alerts: on" || echo "    dependabot alerts: skipped"
  gh api -X PUT "repos/$full/automated-security-fixes" >/dev/null 2>&1 && echo "    dependabot security updates: on" || true
  gh api -X PUT "repos/$full/private-vulnerability-reporting" >/dev/null 2>&1 && echo "    private vulnerability reporting: on" || echo "    private vulnerability reporting: skipped"
  gh api -X PATCH "repos/$full" \
    -f 'security_and_analysis[secret_scanning][status]=enabled' \
    -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null 2>&1 \
    && echo "    secret scanning + push protection: on" || echo "    secret scanning: skipped"
  gh api -X PATCH "repos/$full/code-scanning/default-setup" -f state=configured >/dev/null 2>&1 \
    && echo "    codeql default setup: configured" || echo "    codeql: skipped (e.g. crystal/elixir have no CodeQL support)"
done

echo
echo "Done."
