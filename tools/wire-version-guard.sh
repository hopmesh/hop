#!/usr/bin/env bash
set -euo pipefail

VERSION_FILE="core/hop-core/src/bundle.rs"
MANIFEST_FILE="core/hop-core/vectors/wire-source-manifest.txt"
CORPUS_DIR="core/hop-core/vectors"
STAMP_FILE="sim/pkg/.wire-version"
# Regenerates the deterministic corpus from LIVE code and exits non-zero if it drifts from the
# committed copy. Only invoked for a manifest retirement (see below). Injectable so the self-test
# can stub it in a fixture repo that has no Rust toolchain.
CORPUS_VERIFY_CMD="${WIRE_CORPUS_VERIFY_CMD:-cargo run -q -p hop-core --example wire-vectors --features wire-vectors}"
BASE_REF="${WIRE_BASE_REF:-${1:-}}"
HEAD_REF="${WIRE_HEAD_REF:-HEAD}"

fail() {
  echo "error: wire version guard: $*" >&2
  exit 1
}

[ -n "$BASE_REF" ] || fail "WIRE_BASE_REF (the fetched canonical-main ref) is required"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a Git worktree"
cd "$ROOT"

git cat-file -e "$HEAD_REF^{commit}" 2>/dev/null || fail "head ref is unavailable: $HEAD_REF"
git cat-file -e "$BASE_REF^{commit}" 2>/dev/null || fail "base ref is unavailable: $BASE_REF"
HEAD_COMMIT="$(git rev-parse "$HEAD_REF^{commit}")"
BASE_COMMIT="$(git rev-parse "$BASE_REF^{commit}")"
git merge-base --is-ancestor "$BASE_COMMIT" "$HEAD_COMMIT" 2>/dev/null ||
  fail "exact base $BASE_COMMIT is not an ancestor of head $HEAD_COMMIT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

read_version() {
  local revision="$1" output matches count
  output="$(git show "$revision:$VERSION_FILE" 2>/dev/null)" ||
    fail "$VERSION_FILE is unavailable at $revision"
  matches="$(printf '%s\n' "$output" | grep -E '^pub const BUNDLE_VERSION: u8 = [0-9]+;$' || true)"
  count="$(printf '%s\n' "$matches" | grep -c . || true)"
  [ "$count" -eq 1 ] || fail "expected exactly one BUNDLE_VERSION declaration at $revision"
  printf '%s\n' "$matches" | grep -Eo '[0-9]+' | tail -n 1
}

read_stamp() {
  local revision="$1" value
  value="$(git show "$revision:$STAMP_FILE" 2>/dev/null)" ||
    fail "$STAMP_FILE is unavailable at $revision"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "$STAMP_FILE at $revision is not one integer"
  printf '%s\n' "$value"
}

normalize_manifest() {
  local input="$1" output="$2" line
  : > "$output"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" =~ ^[A-Za-z0-9_./-]+$ ]] || fail "invalid path in $MANIFEST_FILE: $line"
    case "$line" in
      /*|../*|*/../*|*/..) fail "unsafe path in $MANIFEST_FILE: $line" ;;
    esac
    printf '%s\n' "$line" >> "$output"
  done < "$input"
  LC_ALL=C sort -u "$output" -o "$output"
}

# Collect `# retired: <old path> -> <new path>` records. A retirement narrows the guard's own
# scope, so it must be stated in the manifest rather than inferred from a silent deletion.
parse_retirements() {
  local input="$1" output="$2" line body old new
  : > "$output"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "# retired: "*) body="${line#\# retired: }" ;;
      *) continue ;;
    esac
    case "$body" in
      *" -> "*) ;;
      *) fail "malformed retirement record (want '# retired: OLD -> NEW'): $line" ;;
    esac
    old="${body%% -> *}"
    new="${body#* -> }"
    new="${new%% *}"
    for path in "$old" "$new"; do
      [[ "$path" =~ ^[A-Za-z0-9_./-]+$ ]] || fail "invalid path in retirement record: $line"
      case "$path" in
        /*|../*|*/../*|*/..) fail "unsafe path in retirement record: $line" ;;
      esac
    done
    printf '%s %s\n' "$old" "$new" >> "$output"
  done < "$input"
}

snapshot_sources() {
  local revision="$1" destination="$2" path target
  mkdir -p "$destination"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    target="$destination/$path"
    mkdir -p "$(dirname "$target")"
    if git cat-file -e "$revision:$path" 2>/dev/null; then
      git show "$revision:$path" > "$target"
    else
      printf 'MISSING\n' > "$target"
    fi
  done < "$WORK/source-paths"
}

snapshot_corpus() {
  local revision="$1" destination="$2" path base target
  mkdir -p "$destination"
  git ls-tree -r --name-only "$revision" -- "$CORPUS_DIR" > "$WORK/corpus-paths"
  while IFS= read -r path; do
    base="${path##*/}"
    [[ "$base" =~ ^bundle-v[0-9]+\.json$ ]] || continue
    target="$destination/$path"
    mkdir -p "$(dirname "$target")"
    git show "$revision:$path" > "$target"
  done < "$WORK/corpus-paths"
}

git cat-file -e "$HEAD_COMMIT:$MANIFEST_FILE" 2>/dev/null ||
  fail "$MANIFEST_FILE is missing from the head commit"
git show "$HEAD_COMMIT:$MANIFEST_FILE" > "$WORK/head-manifest"
if git cat-file -e "$BASE_COMMIT:$MANIFEST_FILE" 2>/dev/null; then
  git show "$BASE_COMMIT:$MANIFEST_FILE" > "$WORK/base-manifest"
else
  : > "$WORK/base-manifest"
fi
normalize_manifest "$WORK/head-manifest" "$WORK/head-paths"
normalize_manifest "$WORK/base-manifest" "$WORK/base-paths"
[ -s "$WORK/head-paths" ] || fail "$MANIFEST_FILE declares no wire-affecting source"
parse_retirements "$WORK/head-manifest" "$WORK/retirements"

# The manifest is guard POLICY, not wire source. Widening it (declaring another file) must never
# demand a BUNDLE_VERSION bump, or the guard punishes its own strengthening. NARROWING it is a
# different matter: a path dropped from the manifest stops being watched, so it stays in the
# content diff unless an explicit retirement record justifies it.
LC_ALL=C comm -23 "$WORK/base-paths" "$WORK/head-paths" > "$WORK/dropped-paths"
: > "$WORK/retired-paths"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  replacement="$(awk -v old="$path" '$1 == old { print $2; exit }' "$WORK/retirements")"
  [ -n "$replacement" ] ||
    fail "$path left $MANIFEST_FILE with no '# retired: $path -> <replacement>' record"
  grep -Fxq "$replacement" "$WORK/head-paths" ||
    fail "$path retires to $replacement, which the head manifest does not declare"
  printf '%s\n' "$path" >> "$WORK/retired-paths"
done < "$WORK/dropped-paths"
RETIRED_COUNT="$(grep -c . "$WORK/retired-paths" || true)"

# Content is diffed for the paths declared at BOTH ends. A path newly declared at head has no
# prior baseline to diff against (it was not watched before), so declaring it cannot itself fail
# the guard; it is watched from the next commit onward. A path dropped at head is either an
# unrecorded removal, already failed above, or a retirement excluded by construction.
LC_ALL=C comm -12 "$WORK/base-paths" "$WORK/head-paths" > "$WORK/source-paths"

while IFS= read -r path; do
  git cat-file -e "$HEAD_COMMIT:$path" 2>/dev/null ||
    fail "head manifest declares a missing source path: $path"
done < "$WORK/head-paths"

snapshot_sources "$BASE_COMMIT" "$WORK/base-source"
snapshot_sources "$HEAD_COMMIT" "$WORK/head-source"
snapshot_corpus "$BASE_COMMIT" "$WORK/base-corpus"
snapshot_corpus "$HEAD_COMMIT" "$WORK/head-corpus"

BASE_VERSION="$(read_version "$BASE_COMMIT")"
HEAD_VERSION="$(read_version "$HEAD_COMMIT")"
BASE_STAMP="$(read_stamp "$BASE_COMMIT")"
HEAD_STAMP="$(read_stamp "$HEAD_COMMIT")"

[ "$BASE_STAMP" = "$BASE_VERSION" ] ||
  fail "base stamp $BASE_STAMP does not match base BUNDLE_VERSION $BASE_VERSION"
[ "$HEAD_STAMP" = "$HEAD_VERSION" ] ||
  fail "head stamp $HEAD_STAMP does not match head BUNDLE_VERSION $HEAD_VERSION"
git cat-file -e "$HEAD_COMMIT:$CORPUS_DIR/bundle-v$HEAD_VERSION.json" 2>/dev/null ||
  fail "head commit lacks $CORPUS_DIR/bundle-v$HEAD_VERSION.json"

SOURCE_CHANGED=false
CORPUS_CHANGED=false
if ! diff -qr "$WORK/base-source" "$WORK/head-source" >/dev/null; then
  SOURCE_CHANGED=true
fi
if ! diff -qr "$WORK/base-corpus" "$WORK/head-corpus" >/dev/null; then
  CORPUS_CHANGED=true
fi
STAMP_CHANGED=false
[ "$BASE_STAMP" = "$HEAD_STAMP" ] || STAMP_CHANGED=true

# A retirement is only ever a wire-NEUTRAL refactor: the watched code moved to another file. If
# any wire byte actually moved, the regenerated corpus differs (CI rebuilds it from live code and
# byte-compares), so demanding an unchanged corpus makes "I moved it" checkable rather than
# merely asserted. Retiring under a version bump is a contradiction: the bump requires the corpus
# to change, which a retirement forbids. Split them into two changes.
if [ "$RETIRED_COUNT" -gt 0 ]; then
  [ "$BASE_VERSION" = "$HEAD_VERSION" ] ||
    fail "manifest retirement must be wire-neutral, but BUNDLE_VERSION changed $BASE_VERSION -> $HEAD_VERSION"
  [ "$CORPUS_CHANGED" = false ] ||
    fail "manifest retirement must be wire-neutral, but the committed wire corpus changed"
  # An unchanged committed corpus only proves the FILE did not change. A retirement moves watched
  # code into a path that has no baseline at the merge base, so the file diff cannot see it: the
  # replacement is declared here for the first time and is watched only from the NEXT commit. That
  # one-commit blind spot is exactly where a real wire change could ride in, so close it by
  # regenerating the corpus from live code and requiring it to still match.
  echo "wire version guard: manifest retirement, regenerating the wire corpus from live code" >&2
  $CORPUS_VERIFY_CMD >/dev/null 2>&1 ||
    fail "retirement is not wire-neutral: the corpus regenerated from live code does not match the committed corpus"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    echo "wire version guard: retired $path from the manifest (regenerated corpus matches)" >&2
  done < "$WORK/retired-paths"
fi

if [ "$BASE_VERSION" = "$HEAD_VERSION" ]; then
  [ "$SOURCE_CHANGED" = false ] ||
    fail "declared wire source changed without a BUNDLE_VERSION bump (still $HEAD_VERSION)"
  [ "$CORPUS_CHANGED" = false ] ||
    fail "committed wire corpus changed without a BUNDLE_VERSION bump (still $HEAD_VERSION)"
else
  ((10#$HEAD_VERSION > 10#$BASE_VERSION)) ||
    fail "BUNDLE_VERSION must increase, not change $BASE_VERSION -> $HEAD_VERSION"
  [ "$CORPUS_CHANGED" = true ] ||
    fail "BUNDLE_VERSION changed $BASE_VERSION -> $HEAD_VERSION but the committed corpus did not"
  [ "$STAMP_CHANGED" = true ] ||
    fail "BUNDLE_VERSION changed $BASE_VERSION -> $HEAD_VERSION but $STAMP_FILE did not"
fi

echo "wire version guard passed: base=$BASE_COMMIT(v$BASE_VERSION) head=$HEAD_COMMIT(v$HEAD_VERSION) source_changed=$SOURCE_CHANGED corpus_changed=$CORPUS_CHANGED stamp_changed=$STAMP_CHANGED retired=$RETIRED_COUNT"
