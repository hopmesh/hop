#!/usr/bin/env bash
# Self-test for tools/cov-floor-gate.py (F-CI-7). Feeds synthetic llvm-cov export JSON and asserts the
# gate's verdict: passes when both floors are met, fails on an aggregate breach, fails on a single-file
# breach even when the aggregate is fine (the whole point of the per-file floor), and fails on an empty
# denominator or unparseable input. No build, no repo state.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/cov-floor-gate.py"
ROOT="/x/Sources/Pkg"   # a synthetic absolute src-root the fixtures live under
pass=0
fail=0

# mk FILE_SPECS... : emit an llvm-cov-export-shaped JSON. Each spec is "name:covered:count".
mk() {
  python3 - "$ROOT" "$@" <<'PY'
import json, os, sys
root = sys.argv[1].rstrip(os.sep) + os.sep
files = []
for spec in sys.argv[2:]:
    name, covered, count = spec.split(":")
    covered = int(covered); count = int(count)
    pct = 100.0 * covered / count if count else 0.0
    files.append({"filename": root + name,
                  "summary": {"lines": {"covered": covered, "count": count, "percent": pct}}})
print(json.dumps({"data": [{"files": files}]}))
PY
}

# expect WANT(pass|fail) LABEL JSON [AGG FILEFLOOR]
expect() {
  local want="$1" label="$2" body="$3" agg="${4:-80}" pf="${5:-70}"
  if printf '%s' "$body" | python3 "$GATE" "$ROOT" "$agg" "$pf" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok   [$label]: gate $got as expected"
  else
    fail=$((fail + 1)); echo "FAIL [$label]: expected $want, gate $got"
    printf '%s' "$body" | python3 "$GATE" "$ROOT" "$agg" "$pf" 2>&1 | sed 's/^/    /'
  fi
}

# 1) both floors met -> pass (aggregate 90/100 = 90%, each file >= 70%)
expect pass "both_floors_met" "$(mk "A.swift:45:50" "B.swift:45:50")"

# 2) aggregate below 80 -> fail (60/100 = 60%), even though... it's below both anyway
expect fail "aggregate_breach" "$(mk "A.swift:30:50" "B.swift:30:50")"

# 3) THE PER-FILE POINT: aggregate is fine (>=80) but ONE file is below 70 -> fail. A.swift 100/100, but
#    B.swift 60/100 (=60%); aggregate 160/200 = 80% (meets aggregate) yet B breaches the per-file floor.
expect fail "per_file_breach_behind_ok_aggregate" "$(mk "A.swift:100:100" "B.swift:60:100")"

# 4) a file exactly AT the per-file floor (70%) passes; aggregate exactly at 80 passes.
expect pass "exactly_at_floors" "$(mk "A.swift:90:100" "B.swift:70:100")"

# 5) empty denominator (no files under the src-root) -> fail
expect fail "empty_denominator" '{"data":[{"files":[]}]}'

# 6) files exist but none under the src-root (a dependency's Sources only) -> fail (empty denominator)
expect fail "only_out_of_root_files" '{"data":[{"files":[{"filename":"/other/Dep.swift","summary":{"lines":{"covered":0,"count":10,"percent":0.0}}}]}]}'

# 7) unparseable input -> fail, not a crash
expect fail "garbage_input" 'not json at all'

echo
if [ "$fail" -eq 0 ]; then
  echo "cov-floor-gate.test: all $pass cases passed"
else
  echo "cov-floor-gate.test: $fail case(s) FAILED"
  exit 1
fi
