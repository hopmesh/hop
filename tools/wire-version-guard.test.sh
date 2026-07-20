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

# The post-narrowing shape: the state machine (node.rs) is NOT declared; the extracted
# wire-emitting module is.
write_narrowed_manifest() {
  local repo="$1"
  {
    printf '%s\n' \
      '# retired: core/hop-core/src/node.rs -> core/hop-core/src/wire_emit.rs (extracted)' \
      'core/hop-core/src/bundle.rs' \
      'core/hop-core/src/store.rs' \
      'core/hop-core/src/wire_emit.rs' \
      'core/hop-core/src/wire_schema.rs'
  } > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
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

# The fixture repos hold no Rust, so stub the live-corpus regeneration the guard runs on a
# retirement. Default: the regenerated corpus matches (`true`). Set CORPUS_VERIFY=false for the
# case where live code no longer produces the committed bytes.
CORPUS_VERIFY=true

expect_pass() {
  local label="$1" repo="$2" base="$3" output
  if ! output="$(cd "$repo" && WIRE_BASE_REF="$base" \
    WIRE_CORPUS_VERIFY_CMD="$CORPUS_VERIFY" bash "$GUARD" 2>&1)"; then
    echo "FAIL ($label): expected success" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  echo "ok $PASSED - $label"
}

expect_fail() {
  local label="$1" repo="$2" base="$3" output
  if output="$(cd "$repo" && WIRE_BASE_REF="$base" \
    WIRE_CORPUS_VERIFY_CMD="$CORPUS_VERIFY" bash "$GUARD" 2>&1)"; then
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

# --- manifest narrowing: node.rs retired in favour of the extracted wire_emit.rs -------------
# These are the cases that would have caught the gap this guard change closes. Before it, ANY
# edit to the 18k-line state machine, and even a manifest edit on its own, demanded a
# BUNDLE_VERSION bump, which turns the wire version into a build counter.

# Direction 1: the wire-neutral change that used to be blocked is now allowed.
repo="$(base_v8_fixture retire-node-wire-neutral)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
commit_fixture "$repo" retire-node
expect_pass "retiring node.rs with an unchanged corpus needs no bump" "$repo" "$base"

repo="$(base_v8_fixture narrowed-node-change)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
commit_fixture "$repo" narrowed
base="$(git -C "$repo" rev-parse HEAD)"
printf 'node-wire\nfn peer_count(&self) -> usize { self.peers.len() }\n' \
  > "$repo/core/hop-core/src/node.rs"
commit_fixture "$repo" add-read-only-getter
expect_pass "undeclared node.rs may add a read-only getter without a bump" "$repo" "$base"

# Direction 2: a real wire change is still caught, through the narrowed manifest.
repo="$(base_v8_fixture narrowed-wire-emit-drift)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
commit_fixture "$repo" narrowed
base="$(git -C "$repo" rev-parse HEAD)"
printf 'wire-emit-v8-reordered-variants\n' > "$repo/core/hop-core/src/wire_emit.rs"
commit_fixture "$repo" wire-emit-drift
expect_fail "declared wire_emit.rs drift without bump is still caught" "$repo" "$base"

repo="$(base_v8_fixture narrowed-bundle-drift)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
commit_fixture "$repo" narrowed
base="$(git -C "$repo" rev-parse HEAD)"
write_version "$repo" 8
printf 'pub const BUNDLE_VERSION: u8 = 8;\nstruct Inner { b: u8, a: u8 }\n' \
  > "$repo/core/hop-core/src/bundle.rs"
commit_fixture "$repo" bundle-field-reorder
expect_fail "field reorder in declared bundle.rs is still caught" "$repo" "$base"

# The retirement escape hatch cannot be used to smuggle a wire change through.
repo="$(base_v8_fixture retire-without-record)"
base="$(git -C "$repo" rev-parse HEAD)"
printf '%s\n' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/store.rs' \
  'core/hop-core/src/wire_schema.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
printf 'node-wire-drift\n' > "$repo/core/hop-core/src/node.rs"
commit_fixture "$repo" silent-drop
expect_fail "dropping a path with no retirement record fails closed" "$repo" "$base"

repo="$(base_v8_fixture retire-to-undeclared)"
base="$(git -C "$repo" rev-parse HEAD)"
printf '%s\n' \
  '# retired: core/hop-core/src/node.rs -> core/hop-core/src/nowhere.rs (bogus)' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/store.rs' \
  'core/hop-core/src/wire_schema.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
printf 'node-wire-drift\n' > "$repo/core/hop-core/src/node.rs"
commit_fixture "$repo" retire-to-undeclared
expect_fail "retiring to a path the manifest does not declare fails closed" "$repo" "$base"

repo="$(base_v8_fixture retire-with-corpus-drift)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
write_corpus "$repo" 8 drifted
commit_fixture "$repo" retire-with-corpus-drift
expect_fail "a retirement that moves corpus bytes is not wire-neutral" "$repo" "$base"

# The hole this gate exists to close: the replacement path is declared for the first time in the
# retiring commit, so the file diff has no baseline for it. Without the live-corpus regeneration a
# real wire change rides in unseen behind a retirement.
repo="$(base_v8_fixture retire-hiding-a-wire-change)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'wire-emit-v8-with-reordered-variants\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
commit_fixture "$repo" retire-hiding-a-wire-change
CORPUS_VERIFY=false
expect_fail "a retirement whose live corpus drifts is caught" "$repo" "$base"
CORPUS_VERIFY=true

repo="$(base_v8_fixture retire-with-version-bump)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'wire-emit-v9\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
write_version "$repo" 9
write_corpus "$repo" 9 bumped
printf '9\n' > "$repo/sim/pkg/.wire-version"
commit_fixture "$repo" retire-with-bump
expect_fail "a retirement cannot ride along with a BUNDLE_VERSION bump" "$repo" "$base"

# Widening the manifest is a strengthening and must never demand a bump.
repo="$(base_v8_fixture widen-manifest)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'another-wire\n' > "$repo/core/hop-core/src/wire_extra.rs"
printf '%s\n' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/node.rs' \
  'core/hop-core/src/store.rs' \
  'core/hop-core/src/wire_extra.rs' \
  'core/hop-core/src/wire_schema.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
commit_fixture "$repo" widen
expect_pass "declaring another wire source needs no bump" "$repo" "$base"

repo="$(base_v8_fixture widen-then-drift)"
printf 'another-wire\n' > "$repo/core/hop-core/src/wire_extra.rs"
printf '%s\n' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/node.rs' \
  'core/hop-core/src/store.rs' \
  'core/hop-core/src/wire_extra.rs' \
  'core/hop-core/src/wire_schema.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
commit_fixture "$repo" widen
base="$(git -C "$repo" rev-parse HEAD)"
printf 'another-wire-drift\n' > "$repo/core/hop-core/src/wire_extra.rs"
commit_fixture "$repo" drift
expect_fail "a newly declared path is watched from then on" "$repo" "$base"

# --- a SECOND narrowing, on top of one already in the manifest ------------------------------
# The access.rs -> wire_stamp.rs split made the manifest carry two retirement records at once, and
# wrote the new one as a wrapped multi-line comment. These are the cases that would have caught a
# gap there: a stale record must not satisfy a fresh drop, a wrapped record must still yield a
# checked replacement path, and the continuation lines must stay inert.

# A historical record (node.rs, retired in an earlier commit) sits in the manifest while a second
# path is retired now. The old record is inert; the new one is honoured.
repo="$(base_v8_fixture second-retirement)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
commit_fixture "$repo" first-narrowing
base="$(git -C "$repo" rev-parse HEAD)"
printf 'wire-store-v8\n' > "$repo/core/hop-core/src/wire_store.rs"
printf '%s\n' \
  '# retired: core/hop-core/src/node.rs -> core/hop-core/src/wire_emit.rs (extracted)' \
  '# retired: core/hop-core/src/store.rs -> core/hop-core/src/wire_store.rs (extracted)' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/wire_emit.rs' \
  'core/hop-core/src/wire_schema.rs' \
  'core/hop-core/src/wire_store.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
commit_fixture "$repo" second-narrowing
expect_pass "a second retirement alongside a historical record is honoured" "$repo" "$base"

# The stale record must not be usable as cover: dropping a THIRD path still needs its own record,
# even though the manifest already carries two.
repo="$(base_v8_fixture stale-record-is-not-cover)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
write_narrowed_manifest "$repo"
commit_fixture "$repo" first-narrowing
base="$(git -C "$repo" rev-parse HEAD)"
printf '%s\n' \
  '# retired: core/hop-core/src/node.rs -> core/hop-core/src/wire_emit.rs (extracted)' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/wire_emit.rs' \
  'core/hop-core/src/wire_schema.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
printf 'store-wire-drift\n' > "$repo/core/hop-core/src/store.rs"
commit_fixture "$repo" drop-store-under-a-stale-record
expect_fail "an existing retirement record does not cover a different dropped path" "$repo" "$base"

# A wrapped record: prose trails the replacement path on the first line and spills onto '#'
# continuation lines. The replacement must still parse, and the continuations must be inert.
repo="$(base_v8_fixture wrapped-retirement-record)"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'wire-emit-v8\n' > "$repo/core/hop-core/src/wire_emit.rs"
printf '%s\n' \
  '# retired: core/hop-core/src/node.rs -> core/hop-core/src/wire_emit.rs (the framing moved;' \
  '# what remains in node.rs is state machine and bookkeeping that cannot move a wire byte,' \
  '# core/hop-core/src/decoy.rs is named here only in prose and must stay undeclared)' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/store.rs' \
  'core/hop-core/src/wire_emit.rs' \
  'core/hop-core/src/wire_schema.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
commit_fixture "$repo" wrapped-record
expect_pass "a wrapped retirement record parses its replacement and ignores the prose" "$repo" "$base"

# The same wrapping must not make the replacement check vacuous: trailing prose after an
# UNDECLARED replacement still fails closed.
repo="$(base_v8_fixture wrapped-retirement-to-undeclared)"
base="$(git -C "$repo" rev-parse HEAD)"
printf '%s\n' \
  '# retired: core/hop-core/src/node.rs -> core/hop-core/src/nowhere.rs (bogus, but wrapped so' \
  '# the trailing prose might have hidden the undeclared replacement)' \
  'core/hop-core/src/bundle.rs' \
  'core/hop-core/src/store.rs' \
  'core/hop-core/src/wire_schema.rs' \
  > "$repo/core/hop-core/vectors/wire-source-manifest.txt"
printf 'node-wire-drift\n' > "$repo/core/hop-core/src/node.rs"
commit_fixture "$repo" wrapped-retire-to-undeclared
expect_fail "a wrapped record to an undeclared replacement still fails closed" "$repo" "$base"

[ "$PASSED" -eq 27 ] || { echo "FAIL: expected 27 fixtures, ran $PASSED" >&2; exit 1; }
echo "wire version guard self-test passed: $PASSED fixtures"
