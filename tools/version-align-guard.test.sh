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

# lay_down DIR ANCHOR NODE PY RUBY [PREAMBLE] [ELIXIR_WORKSPACE] [GO_INSTALLER]: a fixture with the
# anchor + SDK manifests at the given versions. Optional values cover generated release contracts.
lay_down() {
  local d="$1" anchor="$2" node="$3" py="$4" ruby="$5" pre="${6:-}" elixir_workspace="${7:-}" go_installer="${8:-$2}"
  mkdir -p "$d/tools" "$d/sdk/node" "$d/sdk/python" "$d/sdk/ruby" "$d/sdk/crystal" "$d/sdk/elixir" "$d/sdk/go/cmd/hop-install"
  cp "$GUARD" "$d/tools/version-align-guard.sh"
  printf '[workspace.package]\nversion = "%s"\nedition = "2021"\n' "$anchor" > "$d/Cargo.toml"
  printf '{\n  "name": "@hop-mesh/endpoint",\n  "version": "%s"\n}\n' "$node" > "$d/sdk/node/package.json"
  printf '[project]\nname = "hop-endpoint"\nversion = "%s"\n' "$py" > "$d/sdk/python/pyproject.toml"
  printf 'Gem::Specification.new do |spec|\n  spec.version     = "%s"\nend\n' "$ruby" > "$d/sdk/ruby/hop-endpoint.gemspec"
  printf 'name: hop\nversion: %s\n' "$anchor" > "$d/sdk/crystal/shard.yml"
  printf 'defmodule Hop.MixProject do\n  def project, do: [version: "%s"]\nend\n' "$anchor" > "$d/sdk/elixir/mix.exs"
  printf 'package main\nconst currentVersion = "v%s"\n' "$go_installer" > "$d/sdk/go/cmd/hop-install/main.go"
  if [ -n "$pre" ] || [ -n "$elixir_workspace" ]; then
    mkdir -p "$d/tools/copybara"
    [ -n "$pre" ] && printf 'WORKSPACE_PREAMBLE = """\n[workspace.package]\nversion = "%s"\n"""\n' "$pre" > "$d/tools/copybara/copy.bara.sky"
    [ -n "$elixir_workspace" ] && printf '[workspace.package]\nversion = "%s"\n' "$elixir_workspace" > "$d/tools/copybara/elixir-native-Cargo.toml"
  fi
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
# the copybara mirror preamble shares the anchor major.minor (patch may differ) -> aligned.
lay_down "$TMP/pre_ok" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.2.5"; expect "$TMP/pre_ok" pass "preamble_aligned"
# the preamble drifted a MINOR behind the anchor (0.1.x != 0.2) -> fail.
lay_down "$TMP/pre_drift" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.1.0"; expect "$TMP/pre_drift" fail "preamble_drift"
# the Elixir mirror's vendored native workspace shares the anchor major.minor -> aligned.
lay_down "$TMP/elixir_dep_ok" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.2.9"
expect "$TMP/elixir_dep_ok" pass "elixir_dependency_aligned"
# an older native-workspace major.minor in the mirror template is rejected.
lay_down "$TMP/elixir_dep_drift" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.1.9"
expect "$TMP/elixir_dep_drift" fail "elixir_dependency_drift"
# the Go installer default must move with the protocol release line.
lay_down "$TMP/go_installer_drift" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.2.0" "0.1.9"
expect "$TMP/go_installer_drift" fail "go_installer_drift"

# The Android bearers name `sh.hop:hop` in every published POM, and that coordinate must be a version
# that exists on Central. The SDK version and the bearers' own version are INDEPENDENT (the SDK ran
# ahead after three tags stranded), so this pair is checked for EXACT equality rather than against the
# anchor. An anchor-style check passes 0.0.2-vs-0.0.4 happily, which is precisely the POM that would
# point at a version nobody published.
# lay_down_android DIR SDK_VERSION BEARER_SDK_DEP [BEARER_VERSION]
lay_down_android() {
  local d="$1" sdk="$2" dep="$3" bearer="${4:-0.2.0}"
  lay_down "$d" "0.2.0" "0.2.0" "0.2.0" "0.2.0"
  mkdir -p "$d/sdk/android" "$d/bearers/android"
  printf 'plugins { id("com.android.library") }\nversion = "%s"\n' "$sdk" > "$d/sdk/android/build.gradle.kts"
  printf 'plugins { }\nversion = "%s"\ngroup = "sh.hop"\n' "$bearer" > "$d/bearers/android/build.gradle.kts"
  [ -n "$dep" ] && printf 'hopSdkVersion=%s\n' "$dep" > "$d/bearers/android/gradle.properties"
}

lay_down_android "$TMP/android_dep_ok" "0.2.4" "0.2.4" "0.2.0"
expect "$TMP/android_dep_ok" pass "android_sdk_dep_matches_even_when_patch_differs_from_bearers"

lay_down_android "$TMP/android_dep_drift" "0.2.4" "0.2.0" "0.2.0"
expect "$TMP/android_dep_drift" fail "android_sdk_dep_names_a_version_the_sdk_does_not_publish"

lay_down_android "$TMP/android_dep_absent" "0.2.4" "" "0.2.0"
expect "$TMP/android_dep_absent" fail "android_sdk_dep_missing_entirely"

echo
if [ "$fail" -eq 0 ]; then
  echo "version-align-guard.test: all $pass cases passed"
else
  echo "version-align-guard.test: $fail case(s) FAILED"
  exit 1
fi
