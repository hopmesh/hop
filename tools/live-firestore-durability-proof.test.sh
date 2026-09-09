#!/usr/bin/env bash
# tools/live-firestore-durability-proof.test.sh
# Self-test for tools/live-firestore-durability-proof.py.
# Verifies runner discrimination against both faulty upstreams and mutated assertions.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/live-firestore-durability-proof.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== 1. Positive baseline mock test ==="
OUT="$TMP_DIR/positive.log"
python3 "$SCRIPT" --mock > "$OUT" 2>&1
grep -q "ALL 5 DURABILITY CLAIMS VERIFIED SUCCESSFULLY" "$OUT" || {
  echo "FAIL: positive baseline missing success banner" >&2
  cat "$OUT" >&2
  exit 1
}
grep -q "OK: Conflicting fence acquisition refused as expected \[HTTP 409\]" "$OUT" || {
  echo "FAIL: positive baseline missing 409 fence refusal assertion" >&2
  exit 1
}
grep -q "OK: Probe deletion confirmed: read returns HTTP 404" "$OUT" || {
  echo "FAIL: positive baseline missing 404 probe deletion confirmation" >&2
  exit 1
}
echo "  OK: baseline verified all 5 durability claims and required status codes"

echo "=== 2. Upstream fault: fence collision returns 200 instead of 409 ==="
OUT="$TMP_DIR/fault-fence.log"
if python3 "$SCRIPT" --fault fence-collision-accepts-200 > "$OUT" 2>&1; then
  echo "FAIL: expected fence collision accepts 200 to exit non-zero" >&2
  exit 1
fi
grep -q "FAILED: Conflicting fence acquisition was not refused: HTTP 200" "$OUT" || {
  echo "FAIL: missing expected fence refusal failure message" >&2
  cat "$OUT" >&2
  exit 1
}
if grep -q "ALL 5 DURABILITY CLAIMS VERIFIED SUCCESSFULLY" "$OUT"; then
  echo "FAIL: faulty run falsely reported success" >&2
  exit 1
fi
echo "  OK: runner caught upstream fence collision fault and exited non-zero"

echo "=== 3. Upstream fault: post-delete read returns 200 instead of 404 ==="
OUT="$TMP_DIR/fault-delete.log"
if python3 "$SCRIPT" --fault post-delete-returns-200 > "$OUT" 2>&1; then
  echo "FAIL: expected post-delete read returns 200 to exit non-zero" >&2
  exit 1
fi
grep -q "FAILED probe deletion confirmation: expected 404, got HTTP 200" "$OUT" || {
  echo "FAIL: missing expected post-delete confirmation failure message" >&2
  cat "$OUT" >&2
  exit 1
}
if grep -q "ALL 5 DURABILITY CLAIMS VERIFIED SUCCESSFULLY" "$OUT"; then
  echo "FAIL: faulty run falsely reported success" >&2
  exit 1
fi
echo "  OK: runner caught upstream post-delete ghost read and exited non-zero"

echo "=== 4. Upstream fault: probe write fails with HTTP 500 ==="
OUT="$TMP_DIR/fault-probe.log"
if python3 "$SCRIPT" --fault probe-write-fails > "$OUT" 2>&1; then
  echo "FAIL: expected probe write failure to exit non-zero" >&2
  exit 1
fi
grep -q "FAILED probe write: HTTP 500" "$OUT" || {
  echo "FAIL: missing probe write failure message" >&2
  cat "$OUT" >&2
  exit 1
}
echo "  OK: runner caught upstream probe write failure and exited non-zero"

echo "=== 5. Runner mutation check: fence assertion inverted to status == 200 ==="
MUTANT_FENCE="$TMP_DIR/mutant_fence.py"
sed 's/if status == 409:/if status == 200:/' "$SCRIPT" > "$MUTANT_FENCE"
OUT="$TMP_DIR/mutant-fence.log"
if python3 "$MUTANT_FENCE" --mock > "$OUT" 2>&1; then
  echo "FAIL: mutant runner accepting HTTP 200 for fence collision should have failed against mock" >&2
  exit 1
fi
grep -q "FAILED: Conflicting fence acquisition was not refused: HTTP 409" "$OUT" || {
  echo "FAIL: mutant runner failed for unexpected reason" >&2
  cat "$OUT" >&2
  exit 1
}
echo "  OK: mutant runner with inverted fence check rejected by mock upstream"

echo "=== 6. Runner mutation check: probe delete 404 inverted to status == 200 ==="
MUTANT_DELETE="$TMP_DIR/mutant_delete.py"
sed 's/if status == 404:/if status == 200:/' "$SCRIPT" > "$MUTANT_DELETE"
OUT="$TMP_DIR/mutant-delete.log"
if python3 "$MUTANT_DELETE" --mock > "$OUT" 2>&1; then
  echo "FAIL: mutant runner expecting HTTP 200 on delete confirm should have failed against mock" >&2
  exit 1
fi
grep -q "FAILED probe deletion confirmation:" "$OUT" || {
  echo "FAIL: mutant runner failed for unexpected reason" >&2
  cat "$OUT" >&2
  exit 1
}
echo "  OK: mutant runner with inverted 404 check rejected by mock upstream"

echo "live-firestore-durability-proof.test.sh: OK (all discrimination and mutation gates passed)"
