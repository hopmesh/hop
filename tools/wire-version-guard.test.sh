#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/tools/wire-version-guard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSED=0

init_fixture() {
  local name="$1" repo
  repo="$WORK/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Wire Guard Fixture"
  git -C "$repo" config user.email "wire-guard@example.invalid"
  mkdir -p "$repo/core/hop-core/src" "$repo/core/hop-core/vectors" "$repo/sim/pkg"
  printf 'node-wire\n' > "$repo/core/hop-core/src/node.rs"
  printf 'store-wire\n' > "$repo/core/hop-core/src/store.rs"
  printf '%s\n' "$repo"
}

write_version() {
  local repo="$1" version="$2"
  printf 'pub const BUNDLE_VERSION: u8 = %s;\n' "$version" > "$repo/core/hop-core/src/bundle.rs"
}

write_manifest() {
  local repo="$1"
  printf '%s\n' \
    'core/hop-core/src/bundle.rs' \
    'core/hop-core/src/node.rs' \
    'core/hop-core/src/store.rs' \
    'core/hop-core/src/wire_schema.rs' \
    > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
}

write_corpus() {
  local repo="$1" version="$2" body="$3"
  printf '{"bundle_version":%s,"body":"%s"}\n' "$version" "$body" \
    > "$repo/core/hop-core/vectors/bundle-v$version.json"
}

commit_fixture() {
  local repo="$1" message="$2"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$message"
}

base_v8_fixture() {
  local name="$1" repo
  repo="$(init_fixture "$name")"
  write_version "$repo" 8
  printf 'schema-v8\n' > "$repo/core/hop-core/src/wire_schema.rs"
  write_manifest "$repo"
  write_corpus "$repo" 8 base
  printf '8\n' > "$repo/sim/pkg/.wire-version"
  commit_fixture "$repo" base
  printf '%s\n' "$repo"
}

expect_pass() {
  local label="$1" repo="$2" base="$3" output
  if ! output="$(cd "$repo" && WIRE_BASE_REF="$base" bash "$GUARD" 2>&1)"; then
    echo "FAIL ($label): expected success" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  echo "ok $PASSED - $label"
}

expect_fail() {
  local label="$1" repo="$2" base="$3" output
  if output="$(cd "$repo" && WIRE_BASE_REF="$base" bash "$GUARD" 2>&1)"; then
    echo "FAIL ($label): expected failure" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  echo "ok $PASSED - $label"
}

canonical_v10_with_v9_fork() {
  local name="$1" repo fork canonical
  repo="$(base_v8_fixture "$name")"
  fork="$(git -C "$repo" rev-parse HEAD)"
  write_version "$repo" 10
  printf 'schema-v10\n' > "$repo/core/hop-core/src/wire_schema.rs"
  write_corpus "$repo" 10 canonical
  printf '10\n' > "$repo/sim/pkg/.wire-version"
  commit_fixture "$repo" canonical-v10
  canonical="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" branch canonical-main "$canonical"
  git -C "$repo" checkout -q --detach "$fork"
  write_version "$repo" 9
  printf 'schema-v9\n' > "$repo/core/hop-core/src/wire_schema.rs"
  write_corpus "$repo" 9 stale-fork
  printf '9\n' > "$repo/sim/pkg/.wire-version"
  commit_fixture "$repo" fork-v9
  printf '%s\n%s\n' "$repo" "$canonical"
}

repo="$(base_v8_fixture unchanged)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'unrelated\n' > "$repo/README.md"
commit_fixture "$repo" unrelated
expect_pass "unchanged wire inputs" "$repo" "$base"

repo="$(base_v8_fixture source-only)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'schema-v8-drift\n' > "$repo/core/hop-core/src/wire_schema.rs"
commit_fixture "$repo" source-drift
expect_fail "source-only drift without bump" "$repo" "$base"

repo="$(base_v8_fixture node-source-only)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'node-wire-drift\n' > "$repo/core/hop-core/src/node.rs"
commit_fixture "$repo" node-source-drift
expect_fail "node wire source drift without bump" "$repo" "$base"

repo="$(base_v8_fixture store-source-only)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'store-wire-drift\n' > "$repo/core/hop-core/src/store.rs"
commit_fixture "$repo" store-source-drift
expect_fail "store wire source drift without bump" "$repo" "$base"

repo="$(base_v8_fixture corpus-only)"
base="$(git -C "$repo" rev-parse HEAD)"
write_corpus "$repo" 8 drift
commit_fixture "$repo" corpus-drift
expect_fail "corpus-only drift without bump" "$repo" "$base"

repo="$(init_fixture matching-bump)"
write_version "$repo" 7
printf 'schema-v7\n' > "$repo/core/hop-core/src/wire_schema.rs"
printf '7\n' > "$repo/sim/pkg/.wire-version"
rm -f "$repo/core/hop-core/vectors/wire-source-manifest.txt"
commit_fixture "$repo" v7-without-corpus
base="$(git -C "$repo" rev-parse HEAD)"
write_version "$repo" 8
printf 'schema-v8\n' > "$repo/core/hop-core/src/wire_schema.rs"
write_manifest "$repo"
write_corpus "$repo" 8 introduced
printf '8\n' > "$repo/sim/pkg/.wire-version"
commit_fixture "$repo" v8-with-corpus
expect_pass "matching v7 to v8 bump with initial corpus" "$repo" "$base"

repo="$(base_v8_fixture missing-base)"
expect_fail "missing base data fails closed" "$repo" "refs/remotes/origin/main"

repo="$(base_v8_fixture version-only)"
base="$(git -C "$repo" rev-parse HEAD)"
write_version "$repo" 9
commit_fixture "$repo" version-only
expect_fail "version-only bump" "$repo" "$base"

repo="$(init_fixture numeric-bump)"
write_version "$repo" 9
printf 'schema-v9\n' > "$repo/core/hop-core/src/wire_schema.rs"
write_manifest "$repo"
write_corpus "$repo" 9 base
printf '9\n' > "$repo/sim/pkg/.wire-version"
commit_fixture "$repo" v9
base="$(git -C "$repo" rev-parse HEAD)"
write_version "$repo" 10
printf 'schema-v10\n' > "$repo/core/hop-core/src/wire_schema.rs"
write_corpus "$repo" 10 bumped
printf '10\n' > "$repo/sim/pkg/.wire-version"
commit_fixture "$repo" v10
expect_pass "numeric v9 to v10 bump" "$repo" "$base"

repo="$(init_fixture downgrade)"
write_version "$repo" 10
printf 'schema-v10\n' > "$repo/core/hop-core/src/wire_schema.rs"
write_manifest "$repo"
write_corpus "$repo" 10 base
printf '10\n' > "$repo/sim/pkg/.wire-version"
commit_fixture "$repo" v10
base="$(git -C "$repo" rev-parse HEAD)"
write_version "$repo" 9
printf 'schema-v9\n' > "$repo/core/hop-core/src/wire_schema.rs"
write_corpus "$repo" 9 downgraded
printf '9\n' > "$repo/sim/pkg/.wire-version"
commit_fixture "$repo" v9
expect_fail "wire version downgrade" "$repo" "$base"

fixture="$(canonical_v10_with_v9_fork divergent-history)"
repo="${fixture%%$'\n'*}"
base="${fixture##*$'\n'}"
expect_fail "divergent v9 fork cannot replace exact canonical v10 commit" "$repo" "$base"

fixture="$(canonical_v10_with_v9_fork stale-symbolic-base)"
repo="${fixture%%$'\n'*}"
expect_fail "stale v9 fork cannot substitute the merge base of canonical-main" "$repo" canonical-main

[ "$PASSED" -eq 12 ] || { echo "FAIL: expected 12 fixtures, ran $PASSED" >&2; exit 1; }
echo "wire version guard self-test passed: $PASSED fixtures"
