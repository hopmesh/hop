#!/usr/bin/env bash
# bootstrap-packages.sh: set up the Hop packages on every package manager. RUN THIS YOURSELF: it touches
# your registry accounts and sets repo secrets. Idempotent where it can be. bash-3.2 safe (stock macOS).
#
# On most registries a package is CREATED by its first publish, so this script does not "reserve" names
# itself. Its job is the setup around that: (1) the account/org steps you do on the web, (2) wiring each
# registry's publish token as a secret on the mirror(s) that publish to it, so the per-repo release
# workflows can publish on a vX.Y.Z tag, and (3) how to cut that first release.
#
# Tokens are read from env vars so they are never printed or left in shell history:
#   export NPM_TOKEN=... PYPI_API_TOKEN=... RUBYGEMS_API_KEY=... HEX_API_KEY=... CARGO_REGISTRY_TOKEN=...
#   export MAVEN_USERNAME=... MAVEN_PASSWORD=... MAVEN_GPG_KEY=... MAVEN_GPG_PASSPHRASE=...
#   tools/copybara/bootstrap-packages.sh
set -euo pipefail
ORG="hopmesh"

echo "== 1. accounts / orgs to create on the web (one-time) =="
echo "  npm          create the 'hop-mesh' org (npmjs.com/org/create) so @hop-mesh/* can publish"
echo "  PyPI         an account; prefer Trusted Publishing (GitHub OIDC, no long-lived token) for hop-endpoint"
echo "  RubyGems     an account (rubygems.org) for the hop-endpoint gem"
echo "  Hex          an account (hex.pm) for the hop package"
echo "  crates.io    a crates.io account (sign in with GitHub) for hop-core / libhop / hop-store-*"
echo "  Maven Central a Sonatype Central account + a VERIFIED namespace (e.g. sh.hop) + a published GPG key"
echo "  Go / Swift / Crystal  NO account: they publish by pushing a git tag (the repo IS the package)"
echo

echo "== 2. wire registry publish tokens as repo secrets (from env; nothing printed) =="
# set_secret REPO SECRET VALUE LABEL: set SECRET on ORG/REPO to VALUE if VALUE is non-empty.
set_secret() {
  repo="$1"; secret="$2"; val="$3"; label="$4"
  if [ -n "$val" ]; then
    gh secret set "$secret" --repo "$ORG/$repo" --body "$val" >/dev/null && echo "  $repo  <-  $secret"
  else
    echo "  $repo  skip $secret  (\$$label not exported)"
  fi
}
set_secret hop-sdk-node   NPM_TOKEN        "${NPM_TOKEN:-}"           NPM_TOKEN
set_secret hop-wasm       NPM_TOKEN        "${NPM_TOKEN:-}"           NPM_TOKEN
set_secret hop-sdk-python PYPI_API_TOKEN   "${PYPI_API_TOKEN:-}"      PYPI_API_TOKEN
set_secret hop-sdk-ruby   RUBYGEMS_API_KEY "${RUBYGEMS_API_KEY:-}"    RUBYGEMS_API_KEY
set_secret hop-sdk-elixir HEX_API_KEY      "${HEX_API_KEY:-}"         HEX_API_KEY
for r in hop-core libhop hop-store-sqlite hop-store-firestore; do
  set_secret "$r" CARGO_REGISTRY_TOKEN "${CARGO_REGISTRY_TOKEN:-}" CARGO_REGISTRY_TOKEN
done
for r in hop-sdk-android hop-bearers-android hop-driver-android; do
  set_secret "$r" MAVEN_USERNAME       "${MAVEN_USERNAME:-}"       MAVEN_USERNAME
  set_secret "$r" MAVEN_PASSWORD       "${MAVEN_PASSWORD:-}"       MAVEN_PASSWORD
  set_secret "$r" MAVEN_GPG_KEY        "${MAVEN_GPG_KEY:-}"        MAVEN_GPG_KEY
  set_secret "$r" MAVEN_GPG_PASSPHRASE "${MAVEN_GPG_PASSPHRASE:-}" MAVEN_GPG_PASSPHRASE
done
echo "  (Go, Swift/SPM, Crystal shards need no token: a git tag is the publish.)"
echo

echo "== 3. cut the first release (this CREATES each package) =="
echo "  Each mirror carries a release workflow that fires on a vX.Y.Z tag, checks the tag's major.minor"
echo "  against the protocol anchor, builds, and publishes. Tag the first version once its token is set:"
echo "      gh release create v0.0.1 --repo $ORG/hop-sdk-node    --title v0.0.1 --generate-notes"
echo "      gh release create v0.0.1 --repo $ORG/hop-sdk-python  --title v0.0.1 --generate-notes"
echo "      ... one per package ..."
echo "  Registry-push targets (npm, PyPI, RubyGems, Hex, crates.io, Maven) reserve the name on that first"
echo "  publish. Tag-only targets (Go, Swift, Crystal) are consumable by that tag immediately."
echo
echo "Done."
