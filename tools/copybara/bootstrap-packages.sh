#!/usr/bin/env bash
# bootstrap-packages.sh: create the Hop packages on each registry, then turn on trusted publishing.
# RUN THIS YOURSELF: it publishes packages under your registry accounts and sets repo secrets. It is a
# human action, not something CI or an agent does for you. Idempotent: every create checks the registry
# first and skips a package that is already there. bash-3.2 safe (stock macOS).
#
# WHY "create locally" FIRST (the reason this script exists):
#   npm, RubyGems, and crates.io only let you configure a Trusted Publisher (GitHub OIDC, no long-lived
#   token) on a package that ALREADY EXISTS. So section 2 does the FIRST publish of each package from a
#   clean mirror clone using a one-time token, which reserves the name and makes the package exist.
#   Section 3 then points each package's Trusted Publisher at its release.yml workflow, and from the next
#   version on, every release publishes over OIDC with NO token. (PyPI also supports "pending
#   publishers", so it does not strictly need the local create, but we create it the same way so all
#   four OIDC registries are consistent.)
#
# The first publish comes from the CLEAN MIRROR (github.com/hopmesh/<repo>), never the monorepo: the
# mirror has the release manifests at its root and none of the monorepo-internal files (no CLAUDE.md).
# Seed the mirrors first (tools/copybara/bootstrap-mirrors.sh + the initial export) so the clones exist.
#
# Tokens come from env vars so they are never printed or saved in shell history:
#   export NPM_TOKEN=...            # npmjs.com automation token (publish) for @hop-mesh/*
#   export PYPI_API_TOKEN=...       # pypi.org token (account-scoped for the first publish)
#   export RUBYGEMS_API_KEY=...     # rubygems.org key with push scope (an MFA key if the account has MFA)
#   export HEX_API_KEY=...          # hex.pm key (Hex has no OIDC: token now AND for every release)
#   export CARGO_REGISTRY_TOKEN=... # crates.io token
#   export MAVEN_USERNAME=... MAVEN_PASSWORD=... MAVEN_GPG_KEY=... MAVEN_GPG_PASSPHRASE=...
#   tools/copybara/bootstrap-packages.sh
set -euo pipefail
ORG="hopmesh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }
# clone <mirror-repo>: shallow-clone the clean mirror into $WORK and echo its path (empty on failure).
clone() {
  d="$WORK/$1"
  if git clone --depth 1 "https://github.com/$ORG/$1.git" "$d" >/dev/null 2>&1; then
    printf '%s\n' "$d"
  fi
}

echo "== 1. accounts / orgs to create on the web (one-time) =="
echo "  npm           create the 'hop-mesh' org (npmjs.com/org/create) so @hop-mesh/* can publish"
echo "  PyPI          an account (pypi.org) for the hop-endpoint project"
echo "  RubyGems      an account (rubygems.org) for the hop-endpoint gem"
echo "  Hex           an account (hex.pm) for the hop package (no OIDC: always token-published)"
echo "  crates.io     a crates.io account (sign in with GitHub) + a VERIFIED email (publish is rejected without one)."
echo "                Names hop-core and hop are taken on crates.io, so the crates publish as hop-mesh-core / libhop /"
echo "                hop-mesh-store-* (the Copybara transform renames the package; monorepo + 'use hop_core' unchanged)."
echo "  Maven Central a Sonatype Central account + a VERIFIED namespace (e.g. sh.hop) + a published GPG key"
echo "  Go / Swift / Crystal  NO account: they publish by pushing a git tag (the repo IS the package)"
echo

echo "== 2. create each package locally (first publish reserves the name + makes it exist) =="
# create_npm <mirror>: first-publish an npm package from its clean mirror. hop-wasm is built with
# wasm-pack (publishing pkg/); the rest publish their repo root. Skips if the version is already on npm.
create_npm() {
  repo="$1"
  [ -n "${NPM_TOKEN:-}" ] || { echo "  $repo (npm): skip, NPM_TOKEN not set"; return; }
  have npm && have node || { echo "  $repo (npm): skip, need node + npm on PATH"; return; }
  d="$(clone "$repo")"; [ -n "$d" ] || { echo "  $repo (npm): skip, clone failed (mirror seeded yet?)"; return; }
  npmrc="$WORK/npmrc"; printf '//registry.npmjs.org/:_authToken=%s\n' "$NPM_TOKEN" >"$npmrc"; chmod 600 "$npmrc"
  (
    cd "$d"
    if [ "$repo" = "hop-wasm" ]; then
      have wasm-pack || { echo "  $repo (npm): skip, wasm-pack not installed (cargo install wasm-pack)"; exit 0; }
      wasm-pack build --release --scope hop-mesh --target bundler >/dev/null || { echo "  $repo (npm): wasm-pack build failed"; exit 0; }
      cd pkg
    else
      npm ci >/dev/null 2>&1 || npm install >/dev/null 2>&1 || true
    fi
    name="$(node -p "require('./package.json').name")"
    ver="$(node -p "require('./package.json').version")"
    if npm view "$name@$ver" version >/dev/null 2>&1; then
      echo "  $repo (npm): $name@$ver already published, skipping"
    else
      npm publish --access public --userconfig "$npmrc" >/dev/null \
        && echo "  $repo (npm): published $name@$ver" \
        || echo "  $repo (npm): publish failed (2FA? run 'npm publish --otp=CODE' from $d by hand)"
    fi
  )
}

create_pypi() {  # hop-sdk-python -> hop-endpoint on PyPI (build + twine live in a throwaway venv)
  repo="hop-sdk-python"
  [ -n "${PYPI_API_TOKEN:-}" ] || { echo "  $repo (PyPI): skip, PYPI_API_TOKEN not set"; return; }
  have python3 || { echo "  $repo (PyPI): skip, python3 not on PATH"; return; }
  d="$(clone "$repo")"; [ -n "$d" ] || { echo "  $repo (PyPI): skip, clone failed"; return; }
  venv="$WORK/pyvenv"
  python3 -m venv "$venv" >/dev/null 2>&1 || { echo "  $repo (PyPI): skip, python venv unavailable"; return; }
  "$venv/bin/pip" install -q --upgrade build twine >/dev/null 2>&1 \
    || { echo "  $repo (PyPI): skip, could not install build+twine into the venv (offline?)"; return; }
  (
    cd "$d"
    "$venv/bin/python" -m build >/dev/null || { echo "  $repo (PyPI): build failed"; exit 0; }
    # --skip-existing makes re-runs idempotent; errors are shown (not swallowed).
    if TWINE_USERNAME=__token__ TWINE_PASSWORD="$PYPI_API_TOKEN" \
        "$venv/bin/twine" upload --skip-existing dist/*; then
      echo "  $repo (PyPI): uploaded to hop-endpoint"
    else
      echo "  $repo (PyPI): upload failed (see error above)"
    fi
  )
}

create_gem() {  # hop-sdk-ruby -> hop-endpoint gem on RubyGems
  repo="hop-sdk-ruby"
  [ -n "${RUBYGEMS_API_KEY:-}" ] || { echo "  $repo (RubyGems): skip, RUBYGEMS_API_KEY not set"; return; }
  have gem || { echo "  $repo (RubyGems): skip, gem not on PATH"; return; }
  d="$(clone "$repo")"; [ -n "$d" ] || { echo "  $repo (RubyGems): skip, clone failed"; return; }
  (
    cd "$d"
    gem build ./*.gemspec >/dev/null || { echo "  $repo (RubyGems): gem build failed"; exit 0; }
    # The gemspec sets rubygems_mfa_required, so a plain API key is REJECTED. Use a key created with
    # "MFA UI and API" / gem-push scope, or pass an OTP. The real error is shown, not swallowed.
    if GEM_HOST_API_KEY="$RUBYGEMS_API_KEY" gem push ./*.gem; then
      echo "  $repo (RubyGems): pushed hop-endpoint gem"
    else
      echo "  $repo (RubyGems): push failed above. If it asks for an OTP, run from the clone:"
      echo "      GEM_HOST_API_KEY=\$RUBYGEMS_API_KEY gem push hop-endpoint-*.gem --otp <code>"
    fi
  )
}

# create_crate <mirror>: first-publish a Rust crate to crates.io from its clean mirror. The mirror carries
# the injected standalone [workspace] preamble (copy.bara.sky), so it resolves without the monorepo.
create_crate() {
  repo="$1"
  [ -n "${CARGO_REGISTRY_TOKEN:-}" ] || { echo "  $repo (crates.io): skip, CARGO_REGISTRY_TOKEN not set"; return; }
  have cargo || { echo "  $repo (crates.io): skip, cargo not on PATH"; return; }
  d="$(clone "$repo")"; [ -n "$d" ] || { echo "  $repo (crates.io): skip, clone failed"; return; }
  if ! grep -q "injected for the standalone mirror" "$d/Cargo.toml" 2>/dev/null; then
    echo "  $repo (crates.io): skip, mirror has no standalone [workspace] preamble yet (re-sync it first)"
    return
  fi
  (
    cd "$d"
    meta="$(cargo metadata --no-deps --format-version 1 2>/dev/null)"
    name="$(printf '%s' "$meta" | python3 -c 'import sys,json; print(json.load(sys.stdin)["packages"][0]["name"])' 2>/dev/null)"
    ver="$(printf '%s' "$meta" | python3 -c 'import sys,json; print(json.load(sys.stdin)["packages"][0]["version"])' 2>/dev/null)"
    if [ -n "$name" ] && curl -sf "https://crates.io/api/v1/crates/$name/$ver" >/dev/null 2>&1; then
      echo "  $repo (crates.io): $name@$ver already published, skipping"
    elif CARGO_REGISTRY_TOKEN="$CARGO_REGISTRY_TOKEN" cargo publish; then
      # crates.io's sparse index (what cargo resolves against) lags the upload by a few seconds, so a
      # dependent crate published right after would fail "no matching package". Wait until it is served.
      idx="$(python3 -c 'import sys;n=sys.argv[1];print(("1/"+n) if len(n)==1 else ("2/"+n) if len(n)==2 else ("3/"+n[0]+"/"+n) if len(n)==3 else (n[:2]+"/"+n[2:4]+"/"+n))' "$name")"
      echo "  $repo (crates.io): published $name@$ver; waiting for the index to serve it..."
      for _ in $(seq 1 30); do
        if curl -sf "https://index.crates.io/$idx" 2>/dev/null | grep -q "\"vers\":\"$ver\""; then
          echo "  $repo (crates.io): $name@$ver is live on the index"; break
        fi
        sleep 4
      done
    else
      echo "  $repo (crates.io): publish failed above (a dep not on crates.io yet? publish hop-core first)"
    fi
  )
}

create_hex() {  # hop-sdk-elixir -> hop on Hex (Hex has no OIDC; token-published now and always)
  repo="hop-sdk-elixir"
  [ -n "${HEX_API_KEY:-}" ] || { echo "  $repo (Hex): skip, HEX_API_KEY not set"; return; }
  have mix || { echo "  $repo (Hex): skip, mix not on PATH"; return; }
  d="$(clone "$repo")"; [ -n "$d" ] || { echo "  $repo (Hex): skip, clone failed"; return; }
  (
    cd "$d"
    mix deps.get >/dev/null 2>&1 || true
    HEX_API_KEY="$HEX_API_KEY" mix hex.publish --yes >/dev/null 2>&1 \
      && echo "  $repo (Hex): published hop" \
      || echo "  $repo (Hex): publish failed (already published, or 'mix hex.publish' by hand from $d)"
  )
}

create_npm hop-sdk-node
create_pypi
create_gem
create_hex
# crates.io in DEPENDENCY ORDER: hop-core is the leaf, so it must land before anything that depends on it.
create_crate hop-core
create_crate hop-store-sqlite
create_crate hop-store-firestore
# hop-wasm depends on hop-core = "0.0.1" from crates.io, so it only builds AFTER hop-core is published.
create_npm hop-wasm
echo "  libhop + the services (hop-relayd/endpoint/gateway) also pull hop-endpoint-core (core/hop-endpoint),"
echo "     which is not mirrored/published yet; publish that crate before their first release."
echo "  Maven Central (hop-sdk-android/...): needs the Sonatype namespace + GPG key; publish via its"
echo "     release.yml once MAVEN_* secrets are set (section 4)."
echo

echo "== 3. turn on trusted publishing (GitHub OIDC, no token) for every release after the first =="
# For each OIDC registry, configure a Trusted Publisher in the package's registry settings with EXACTLY
# these values. Provider = GitHub Actions; leave the environment field blank (the workflows use none).
echo "  npm  @hop-mesh/endpoint   settings 'Trusted Publisher': owner hopmesh, repo hop-sdk-node, workflow release.yml"
echo "  npm  @hop-mesh/wasm       settings 'Trusted Publisher': owner hopmesh, repo hop-wasm,     workflow release.yml"
echo "  PyPI hop-endpoint         'Publishing' > 'Trusted Publishers': owner hopmesh, repo hop-sdk-python, workflow release.yml"
echo "  RubyGems hop-endpoint     gem 'Trusted publishers': owner hopmesh, repo hop-sdk-ruby, workflow release.yml"
echo "  crates.io hop-mesh-core             'Trusted Publishing': owner hopmesh, repo hop-core,             workflow release.yml"
echo "  crates.io hop-mesh-store-sqlite     'Trusted Publishing': owner hopmesh, repo hop-store-sqlite,     workflow release.yml"
echo "  crates.io hop-mesh-store-firestore  'Trusted Publishing': owner hopmesh, repo hop-store-firestore,  workflow release.yml"
echo "     (the crate name is hop-mesh-*, the source repo is the mirror it publishes from)"
echo "  (Hex + Maven Central have no OIDC path yet: they stay token-published, see section 4.)"
echo "  Each release.yml already declares 'permissions: id-token: write'; nothing else in CI to change."
echo

echo "== 4. wire tokens as repo secrets (token-only registries + a fallback if you skip OIDC) =="
# set_secret REPO SECRET VALUE LABEL: set SECRET on ORG/REPO to VALUE when VALUE is non-empty.
set_secret() {
  repo="$1"; secret="$2"; val="$3"; label="$4"
  if [ -n "$val" ]; then
    gh secret set "$secret" --repo "$ORG/$repo" --body "$val" >/dev/null && echo "  $repo  <-  $secret"
  else
    echo "  $repo  skip $secret  (\$$label not exported)"
  fi
}
# Hex is always token-published (no OIDC). Maven Central is token + GPG. Set these for real releases.
set_secret hop-sdk-elixir HEX_API_KEY "${HEX_API_KEY:-}" HEX_API_KEY
for r in hop-sdk-android hop-bearers-android hop-driver-android; do
  set_secret "$r" MAVEN_USERNAME       "${MAVEN_USERNAME:-}"       MAVEN_USERNAME
  set_secret "$r" MAVEN_PASSWORD       "${MAVEN_PASSWORD:-}"       MAVEN_PASSWORD
  set_secret "$r" MAVEN_GPG_KEY        "${MAVEN_GPG_KEY:-}"        MAVEN_GPG_KEY
  set_secret "$r" MAVEN_GPG_PASSPHRASE "${MAVEN_GPG_PASSPHRASE:-}" MAVEN_GPG_PASSPHRASE
done
# OIDC registries need NO secret once section 3 is done. If you would rather keep tokens (and reverted the
# release.yml files to the token form), uncomment these to wire them as a fallback:
#   set_secret hop-sdk-node   NPM_TOKEN            "${NPM_TOKEN:-}"            NPM_TOKEN
#   set_secret hop-wasm       NPM_TOKEN            "${NPM_TOKEN:-}"            NPM_TOKEN
#   set_secret hop-sdk-python PYPI_API_TOKEN       "${PYPI_API_TOKEN:-}"       PYPI_API_TOKEN
#   set_secret hop-sdk-ruby   RUBYGEMS_API_KEY     "${RUBYGEMS_API_KEY:-}"     RUBYGEMS_API_KEY
#   for r in hop-core libhop hop-store-sqlite hop-store-firestore; do
#     set_secret "$r" CARGO_REGISTRY_TOKEN "${CARGO_REGISTRY_TOKEN:-}" CARGO_REGISTRY_TOKEN
#   done
echo "  (Go, Swift/SPM, Crystal shards need no token: a git tag is the publish.)"
echo

echo "== 5. cut every release after the first with a tag (publishes over OIDC) =="
echo "  Each mirror's release.yml fires on a vX.Y.Z tag, checks the tag's major.minor against the anchor,"
echo "  builds, and publishes. Section 2 created v0.0.1, so the next release is v0.0.2:"
echo "      gh release create v0.0.2 --repo $ORG/hop-sdk-node   --title v0.0.2 --generate-notes"
echo "      gh release create v0.0.2 --repo $ORG/hop-sdk-python --title v0.0.2 --generate-notes"
echo "      ... one per package ..."
echo "  Tag-only targets (Go, Swift, Crystal) are consumable by that tag immediately, no registry push."
echo
echo "Done."
