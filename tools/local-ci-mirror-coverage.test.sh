#!/usr/bin/env bash
# Self-test for the local-ci-mirror coverage guard: it must redden when a ci.yml job has no entry in
# the mirror's CI_COVERAGE table, which is the drift that let the script keep calling itself the
# mirror of CI while jobs were added around it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/local-ci-mirror-coverage.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

expect() {
  local label="$1" want="$2" ci="$3" mirror="$4"
  if bash "$GUARD" "$ci" "$mirror" >/dev/null 2>&1; then
    got=pass
  else
    got=fail
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $label expected $want, got $got"
    bash "$GUARD" "$ci" "$mirror" 2>&1 | sed 's/^/    /'
  fi
}

# The real tree must pass.
expect "real tree" pass "$ROOT/.github/workflows/ci.yml" "$ROOT/tools/local-ci-mirror.sh"

# A new gating job in ci.yml with no coverage entry must FAIL. This is the regression: without it, a
# job added to CI is invisible to the script that claims to reproduce CI.
python3 - "$ROOT/.github/workflows/ci.yml" "$TMP/ci-newjob.yml" <<'PY'
import sys

source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
marker = "\n  gate:\n"
assert marker in text, "ci.yml gate job anchor moved"
added = "\n  zig-sdk:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo new\n"
open(destination, "w", encoding="utf-8").write(text.replace(marker, added + marker, 1))
PY
expect "ci.yml job with no coverage entry" fail "$TMP/ci-newjob.yml" "$ROOT/tools/local-ci-mirror.sh"

# A coverage entry for a job ci.yml no longer has is stale and must FAIL, so the table stays a real
# inventory rather than accumulating names that mean nothing.
python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-stale.sh" <<'PY'
import sys

source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
marker = 'CI_COVERAGE=(\n'
assert marker in text, "CI_COVERAGE anchor moved"
added = '  "retired-job|none|a job that ci.yml does not have any more"\n'
open(destination, "w", encoding="utf-8").write(text.replace(marker, marker + added, 1))
PY
expect "coverage entry for a removed job" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-stale.sh"

# An entry with no real explanation must FAIL: "none" with an empty reason is the silent narrowing
# this whole guard exists to stop.
python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-empty.sh" <<'PY'
import re
import sys

source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
replaced, count = re.subn(r'^  "wasm\|none\|[^"]*"$', '  "wasm|none|n/a"', text, count=1, flags=re.M)
assert count == 1, "wasm coverage entry not found"
open(destination, "w", encoding="utf-8").write(replaced)
PY
expect "coverage entry with no explanation" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-empty.sh"

# An unknown coverage level must FAIL rather than being treated as covered.
python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-level.sh" <<'PY'
import re
import sys

source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
replaced, count = re.subn(r'^  "wasm\|none\|', '  "wasm|mostly|', text, count=1, flags=re.M)
assert count == 1, "wasm coverage entry not found"
open(destination, "w", encoding="utf-8").write(replaced)
PY
expect "unknown coverage level" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-level.sh"

# A `full` claim must be BACKED. Dropping the driver's JaCoCo coverage-verification task from the
# mirror while the android entry still says "full" is the exact defect the audit found: a green local
# verdict for a job whose coverage floors were never evaluated locally.
python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-nocov.sh" <<'PY'
import sys

source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
task = ":hop-driver:jacocoDriverCoverageVerification"
assert task in text, "the driver coverage-verification task is not run by the mirror"
open(destination, "w", encoding="utf-8").write(text.replace(task, "", 1))
PY
expect "full job missing a ci.yml gradle task" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-nocov.sh"

# Same rule for the cargo feature matrix: a feature-gated clippy pass CI runs, dropped here while the
# rust entry claims full, must redden. This is how the reqwest/sqlcipher clippy gap hid. (The fixture
# was originally keyed to the billingd clippy step; that crate moved to hopmesh/platform, so the case
# now drops the gateway reqwest clippy step, which exercises the same rule against a surviving step.)
python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-noclippy.sh" <<'PY'
import re
import sys

source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
replaced, count = re.subn(r'(?m)^step "clippy gateway \(reqwest\)".*\n', "", text, count=1)
assert count == 1, "the gateway reqwest clippy step is not run by the mirror"
open(destination, "w", encoding="utf-8").write(replaced)
PY
expect "full job missing a ci.yml cargo pass" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-noclippy.sh"

# The two tree-damage hazards this script had. A fixed /tmp path is a cross-worktree clobber (it
# misattributed a failure during the 2026-07-29 audit), and the tracked 178MB Frameworks tree the Apple
# build rewrites must be handled on exit, not left for a stray `git add` to commit.
mirror_text="$(cat "$ROOT/tools/local-ci-mirror.sh")"
case "$mirror_text" in
  # The redirect, not the prose: the header names the old path when explaining why it changed.
  *'>/tmp/vstep.log'* | *'> /tmp/vstep.log'*)
    fail=$((fail + 1)); echo "FAIL: the mirror still writes step output to a shared /tmp path" ;;
  *) pass=$((pass + 1)) ;;
esac
case "$mirror_text" in
  *'trap cleanup EXIT'*drivers/apple/HopDriver/Frameworks*|*drivers/apple/HopDriver/Frameworks*'trap cleanup EXIT'*)
    pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); echo "FAIL: the mirror does not reconcile the tracked Frameworks tree on exit" ;;
esac

# And the summary has to NAME the uncovered jobs, not just count them: a verdict that does not
# enumerate what it skipped is the defect, whatever the table says.
summary="$(sed -n '/CI JOBS NOT FULLY COVERED HERE/,/^fi$/p' "$ROOT/tools/local-ci-mirror.sh")"
case "$summary" in
  *'for u in "${uncovered[@]}"'*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); echo "FAIL: the mirror summary does not enumerate the uncovered CI jobs" ;;
esac

echo "local-ci-mirror-coverage.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
