#!/usr/bin/env bash
# Self-test for tools/apple-cov-gate.sh.
#
# Tests parsing and threshold logic against captured fixture output using mock swift and xcrun shims
# in a temporary PATH, without invoking xcodebuild or real llvm-cov toolchains.
#
# Covers:
# 1. Single-file coverage meeting the floor (passes).
# 2. Single-file coverage falling below the floor (fails).
# 3. Single-file missing from coverage export (-1 percent, fails).
# 4. Aggregate coverage across package Sources meeting the floor (passes).
# 5. Aggregate coverage falling below the floor (fails).
# 6. Aggregate coverage respecting exclude regex (excluded files omitted from denominator).
# 7. Aggregate coverage failing when excluded files are improperly included.
# 8. Missing .xctest bundle detection (fails).
# 9. Test invocation failure propagation (fails).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$root/tools/apple-cov-gate.sh"
work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"

cat >"$work/bin/swift" <<'SH'
#!/usr/bin/env bash
if [ "${MOCK_SWIFT_FAIL:-0}" = "1" ]; then
  echo "mock swift test failed" >&2
  exit 1
fi
if [ "$1" = "test" ] && [ "$2" = "--enable-code-coverage" ]; then
  exit 0
fi
if [ "$1" = "build" ] && [ "$2" = "--show-bin-path" ]; then
  echo "${MOCK_BIN_PATH:-}"
  exit 0
fi
echo "unexpected swift args: $*" >&2
exit 1
SH
chmod +x "$work/bin/swift"

cat >"$work/bin/xcrun" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "llvm-cov" ] && [ "$2" = "export" ]; then
  if [ -n "${MOCK_LLVM_COV_JSON:-}" ] && [ -f "$MOCK_LLVM_COV_JSON" ]; then
    cat "$MOCK_LLVM_COV_JSON"
    exit 0
  fi
  echo "missing MOCK_LLVM_COV_JSON fixture" >&2
  exit 1
fi
echo "unexpected xcrun args: $*" >&2
exit 1
SH
chmod +x "$work/bin/xcrun"

pkg="$work/FakePkg"
mkdir -p "$pkg/Sources/FakePkg"
bin="$work/fake-bin"
mkdir -p "$bin/Fake.xctest/Contents/MacOS"
mkdir -p "$bin/codecov"
touch "$bin/codecov/default.profdata"

export MOCK_BIN_PATH="$bin"
export PATH="$work/bin:$PATH"

make_cov_json() {
  local out="$1"; shift
  python3 - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
files = []
for spec in sys.argv[2:]:
    fn, cov, tot = spec.split(":")
    cov = int(cov); tot = int(tot)
    pct = round(100.0 * cov / tot, 2) if tot else 0.0
    files.append({
        "filename": fn,
        "summary": {"lines": {"covered": cov, "count": tot, "percent": pct}}
    })
with open(out, "w") as f:
    json.dump({"data": [{"files": files}]}, f)
PY
}

run_case() {
  local label="$1" expected="$2" fragment="$3"; shift 3
  local output actual
  if output="$(bash "$gate" "$@" 2>&1)"; then actual="pass"; else actual="fail"; fi
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL [%s]: expected %s, got %s\n%s\n' "$label" "$expected" "$actual" "$output" >&2
    exit 1
  fi
  if [ -n "$fragment" ] && ! printf '%s' "$output" | grep -qF "$fragment"; then
    printf 'FAIL [%s]: expected output to contain %s\n%s\n' "$label" "$fragment" "$output" >&2
    exit 1
  fi
  echo "ok   [$label]: gate $actual as expected"
}

cov_file="$work/cov.json"
export MOCK_LLVM_COV_JSON="$cov_file"

# 1. Single-file mode meets floor
make_cov_json "$cov_file" "$pkg/Sources/FakePkg/Core.swift:85:100"
run_case "single_file_above_floor" pass "coverage gate satisfied for Sources/FakePkg/Core.swift" \
  "$pkg" "Sources/FakePkg/Core.swift" 80

# 2. Single-file mode below floor
make_cov_json "$cov_file" "$pkg/Sources/FakePkg/Core.swift:75:100"
run_case "single_file_below_floor" fail "line coverage 75.0% is below the 80% floor" \
  "$pkg" "Sources/FakePkg/Core.swift" 80

# 3. Single-file mode missing target from export
make_cov_json "$cov_file" "$pkg/Sources/FakePkg/Other.swift:90:100"
run_case "single_file_missing_from_export" fail "line coverage -1% is below the 80% floor" \
  "$pkg" "Sources/FakePkg/Core.swift" 80

# 4. Aggregate mode meets floor (exclude pattern matching nothing)
make_cov_json "$cov_file" \
  "$pkg/Sources/FakePkg/A.swift:90:100" \
  "$pkg/Sources/FakePkg/B.swift:80:100"
run_case "aggregate_above_floor" pass "coverage gate satisfied for Aggregate Cores" \
  "$pkg" "Aggregate Cores" 80 '$^'

# 5. Aggregate mode below floor (exclude pattern matching nothing)
make_cov_json "$cov_file" \
  "$pkg/Sources/FakePkg/A.swift:60:100" \
  "$pkg/Sources/FakePkg/B.swift:70:100"
run_case "aggregate_below_floor" fail "line coverage 65.0% is below the 80% floor" \
  "$pkg" "Aggregate Cores" 80 '$^'

# 6. Aggregate mode with exclude regex (Radio.swift excluded so 90/100 = 90% >= 80%)
make_cov_json "$cov_file" \
  "$pkg/Sources/FakePkg/Core.swift:90:100" \
  "$pkg/Sources/FakePkg/Radio.swift:0:100"
run_case "aggregate_with_exclude_regex_pass" pass "coverage gate satisfied for Radio-free cores" \
  "$pkg" "Radio-free cores" 80 'Radio\.swift'

# 7. Aggregate mode with wrong exclude regex (Radio.swift NOT excluded so 90/200 = 45% < 80%)
run_case "aggregate_with_wrong_exclude_regex_fail" fail "line coverage 45.0% is below the 80% floor" \
  "$pkg" "Radio-free cores" 80 'Unmatched\.swift'
# 8. Missing .xctest bundle
rm -rf "$bin/Fake.xctest"
run_case "missing_xctest_bundle" fail "no .xctest bundle found" \
  "$pkg" "Sources/FakePkg/Core.swift" 80
mkdir -p "$bin/Fake.xctest/Contents/MacOS"

# 9. Test invocation failure
export MOCK_SWIFT_FAIL=1
run_case "swift_test_fails" fail "mock swift test failed" \
  "$pkg" "Sources/FakePkg/Core.swift" 80
export MOCK_SWIFT_FAIL=0

echo
echo "apple-cov-gate.test: all cases passed"
