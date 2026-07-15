#!/usr/bin/env bash
# Self-test for tools/version-align-guard.sh. The guard asserts every declared SDK version shares the
# anchor's (Rust workspace) major.minor, while allowing patch to differ. This test lays down a fixture
# with an anchor + several SDK manifests and checks the guard (a) passes when every SDK shares the
# anchor's major.minor (with differing patches), (b) fails on a MINOR drift, (c) fails on a MAJOR drift,
# and (d) still passes when an SDK manifest is absent (tag-versioned, skipped). No repo state.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/version-align-guard.sh"
pass=0
fail=0

# lay_down DIR ANCHOR NODE PY RUBY: a fixture with the anchor + SDK manifests at the given versions.
lay_down() {
  local d="$1" anchor="$2" node="$3" py="$4" ruby="$5"
  mkdir -p "$d/tools" "$d/sdk/node" "$d/sdk/python" "$d/sdk/ruby" "$d/sdk/crystal" "$d/sdk/elixir"
  cp "$GUARD" "$d/tools/version-align-guard.sh"
  printf '[workspace.package]\nversion = "%s"\nedition = "2021"\n' "$anchor" > "$d/Cargo.toml"
  printf '{\n  "name": "@hop/endpoint",\n  "version": "%s"\n}\n' "$node" > "$d/sdk/node/package.json"
  printf '[project]\nname = "hop-endpoint"\nversion = "%s"\n' "$py" > "$d/sdk/python/pyproject.toml"
  printf 'Gem::Specification.new do |spec|\n  spec.version     = "%s"\nend\n' "$ruby" > "$d/sdk/ruby/hop-endpoint.gemspec"
  printf 'name: hop\nversion: %s\n' "$anchor" > "$d/sdk/crystal/shard.yml"
  printf 'defmodule Hop.MixProject do\n  def project, do: [version: "%s"]\nend\n' "$anchor" > "$d/sdk/elixir/mix.exs"
}

# expect DIR WANT(pass|fail) LABEL
expect() {
  local d="$1" want="$2" label="$3"
  if bash "$d/tools/version-align-guard.sh" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok   [$label]: guard $got as expected"
  else
    fail=$((fail + 1)); echo "FAIL [$label]: expected $want, guard $got"
    bash "$d/tools/version-align-guard.sh" 2>&1 | sed 's/^/    /' | head -4
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# anchor 0.2.0; node/py/ruby share 0.2 with DIFFERENT patches -> aligned (patch may differ).
lay_down "$TMP/ok" "0.2.0" "0.2.7" "0.2.0" "0.2.19"; expect "$TMP/ok" pass "aligned_patch_differs"
# a MINOR drift on node (0.3.x != 0.2) -> fail.
lay_down "$TMP/minor" "0.2.0" "0.3.0" "0.2.0" "0.2.0"; expect "$TMP/minor" fail "minor_drift"
# a MAJOR drift on ruby (1.2.x != 0.2) -> fail.
lay_down "$TMP/major" "0.2.0" "0.2.0" "0.2.0" "1.2.0"; expect "$TMP/major" fail "major_drift"
# a missing manifest (tag-versioned) is skipped, not failed.
lay_down "$TMP/absent" "0.2.0" "0.2.0" "0.2.0" "0.2.0"; rm -f "$TMP/absent/sdk/python/pyproject.toml"
expect "$TMP/absent" pass "absent_manifest_skipped"

echo
if [ "$fail" -eq 0 ]; then
  echo "version-align-guard.test: all $pass cases passed"
else
  echo "version-align-guard.test: $fail case(s) FAILED"
  exit 1
fi
