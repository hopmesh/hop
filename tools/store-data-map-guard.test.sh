#!/usr/bin/env bash
# Self-test for tools/store-data-map-guard.py. A guard nobody proves can FAIL is decoration, so this
# drives it against the real tree (must pass) and against fixtures that reproduce the SVC-004 drift
# one way at a time (must fail).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/tools/store-data-map-guard.py"
SRC="$ROOT/core/stores/hop-store-firestore/src/lib.rs"
DESIGN="$ROOT/DESIGN.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

expect_pass() { # name source design
  if STORE_MAP_SOURCE="$2" STORE_MAP_DESIGN="$3" python3 "$GUARD" >/dev/null 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1 (guard rejected something it should accept)"
    STORE_MAP_SOURCE="$2" STORE_MAP_DESIGN="$3" python3 "$GUARD" 2>&1 | sed 's/^/       /'
    fails=1
  fi
}

expect_fail() { # name source design
  if STORE_MAP_SOURCE="$2" STORE_MAP_DESIGN="$3" python3 "$GUARD" >/dev/null 2>&1; then
    echo "FAIL $1 (guard accepted a tree whose data map is short)"
    fails=1
  else
    echo "ok   $1"
  fi
}

expect_pass "the real tree's section 33 names every collection" "$SRC" "$DESIGN"

# 1. The exact SVC-004 regression: the store writes a collection the map never mentions.
python3 - "$SRC" "$TMP/new-collection.rs" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
src += '\nfn undisclosed() -> String { "documents/shadow_ledger".to_string() }\n'
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
expect_fail "an undisclosed collection is rejected" "$TMP/new-collection.rs" "$DESIGN"

# 2. The other direction of the same drift: the kv collection dropped back out of the map. This is
#    the literal prior state of DESIGN.md, so the guard must redden on it.
python3 - "$DESIGN" "$TMP/no-kv.md" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
lines = text.splitlines(keepends=True)
start = next(i for i, l in enumerate(lines) if l.startswith("## 33."))
end = next(i for i, l in enumerate(lines) if i > start and l.startswith("## 34."))
section = "".join(lines[start:end])
# Strip every backticked span that names the kv collection, as a section that forgot it would.
section = re.sub(r"`[^`]*\bkv\b[^`]*`", "the side store", section)
open(sys.argv[2], "w", encoding="utf-8").write("".join(lines[:start]) + section + "".join(lines[end:]))
PY
expect_fail "a map that forgot relays/{node}/kv is rejected" "$SRC" "$TMP/no-kv.md"

# 3. Prose alone does not satisfy the map: only a backticked path counts, or "controls" would pass
#    for the `control` collection and every other near-miss word would pass too.
python3 - "$DESIGN" "$TMP/prose-only.md" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
lines = text.splitlines(keepends=True)
start = next(i for i, l in enumerate(lines) if l.startswith("## 33."))
end = next(i for i, l in enumerate(lines) if i > start and l.startswith("## 34."))
section = "".join(lines[start:end])
section = re.sub(r"`([^`]*)`", r"\1", section)  # unbacktick everything
open(sys.argv[2], "w", encoding="utf-8").write("".join(lines[:start]) + section + "".join(lines[end:]))
PY
expect_fail "unbackticked prose does not count as naming a collection" "$SRC" "$TMP/prose-only.md"

# 4. Fails closed when section 33 is gone entirely, rather than passing vacuously.
python3 - "$DESIGN" "$TMP/no-section.md" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
lines = text.splitlines(keepends=True)
start = next(i for i, l in enumerate(lines) if l.startswith("## 33."))
end = next(i for i, l in enumerate(lines) if i > start and l.startswith("## 34."))
open(sys.argv[2], "w", encoding="utf-8").write("".join(lines[:start]) + "".join(lines[end:]))
PY
expect_fail "a missing section 33 fails closed" "$SRC" "$TMP/no-section.md"

# 5. Fails closed on a source with no Firestore paths at all (a broken extraction must not pass).
echo "// no firestore here" > "$TMP/empty.rs"
expect_fail "a source with no collections fails closed" "$TMP/empty.rs" "$DESIGN"

if [ "$fails" -ne 0 ]; then
  echo "store-data-map-guard.test.sh: FAILED"
  exit 1
fi
echo "store-data-map-guard.test.sh: all cases pass"
