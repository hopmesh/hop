#!/usr/bin/env bash
# version-align-guard.sh: every published package tracks the SAME major.minor as the protocol version.
# The Rust workspace version in the root Cargo.toml ([workspace.package]) is the single ANCHOR. PATCH may
# differ per package (a binding-only or docs-only fix ships for one SDK without rev'ing the rest), but a
# MAJOR or MINOR bump is a coordinated, all-packages event, so a wire/protocol change never leaves an SDK
# advertising an older contract. This guard fails CI if any SDK's DECLARED version drifts in major or
# minor from the anchor.
#
# Packages with no in-tree version (Go, Swift/SPM, Android, anything consumed purely by git tag) are
# versioned by their release TAG; the per-repo release workflow checks that tag against this same anchor
# at publish time, so there is nothing to read here for them.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ver_in FILE REGEX -> the first x.y.z on the first line matching REGEX (empty if the file or match is
# absent, which the caller treats as "tag-versioned, skip").
ver_in() {
  local file="$1" pat="$2"
  [ -f "$file" ] || { echo ""; return; }
  grep -m1 -E "$pat" "$file" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

anchor="$(ver_in Cargo.toml '^version = ')"
if [ -z "$anchor" ]; then
  echo "version-align-guard: MISSING could not read the anchor version from Cargo.toml [workspace.package]" >&2
  exit 1
fi
anchor_mm="${anchor%.*}"

fail=0
check() {  # LABEL VERSION
  local label="$1" v="$2"
  [ -z "$v" ] && return 0   # no in-tree version -> tag-versioned, checked by the release workflow
  local mm="${v%.*}"
  if [ "$mm" != "$anchor_mm" ]; then
    echo "version-align-guard: DRIFT $label is $v (major.minor $mm, anchor is $anchor_mm) - a major/minor bump must move every package together" >&2
    fail=1
  fi
}

check "sdk/node (package.json)"     "$(ver_in sdk/node/package.json '"version"')"
check "sdk/python (pyproject.toml)" "$(ver_in sdk/python/pyproject.toml '^version *=')"
check "sdk/ruby (gemspec)"          "$(ver_in sdk/ruby/hop-endpoint.gemspec 'spec\.version')"
check "sdk/crystal (shard.yml)"     "$(ver_in sdk/crystal/shard.yml '^version:')"
check "sdk/elixir (mix.exs)"        "$(ver_in sdk/elixir/mix.exs 'version:')"
# The Copybara Rust-mirror preamble bakes the anchor version into each standalone mirror's [workspace.
# package] (tools/copybara/copy.bara.sky WORKSPACE_PREAMBLE), so the crate mirrors publish at that
# version. Guard it against the anchor so a bump can't silently leave the mirrors a version behind.
check "copybara mirror preamble (copy.bara.sky)" "$(ver_in tools/copybara/copy.bara.sky '^version = ')"

if [ "$fail" -ne 0 ]; then
  echo "version-align-guard: FAIL (a package's major.minor drifted from the anchor $anchor_mm)" >&2
  exit 1
fi
echo "version-align-guard: OK (every declared SDK version tracks the anchor major.minor $anchor_mm; patch may differ)"
