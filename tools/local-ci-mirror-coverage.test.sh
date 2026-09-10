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

# Every command behind the infrastructure `full` claim must be load-bearing.
python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
cases = {
    "runtime-guard": 'step "runtime deploy guard"              python3 tools/runtime-deploy-guard.py\n',
    "secondary-guard": 'step "secondary deploy guard"            python3 tools/secondary-deploy-authority-guard.py\n',
    "tofu-runtime-validate": 'step "tofu validate runtime"          tofu -chdir=infra validate\n',
    "private-pin-live": 'step "private source pin"                python3 tools/private-source-pin.py verify-lock --lock infra/private-source.lock\n',
}
for name, command in cases.items():
    if source.count(command) != 1:
        raise SystemExit(f"mirror command not found exactly once: {name}")
    (out / f"mirror-no-{name}.sh").write_text(source.replace(command, "", 1))
PY
for name in runtime-guard secondary-guard tofu-runtime-validate private-pin-live; do
  expect "full infrastructure job missing $name" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-no-$name.sh"
done

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

# Archive readiness step parity: dropping, commenting, or no-oping either command must FAIL.

# 1. CI step dropping / no-op mutations
python3 - "$ROOT/.github/workflows/ci.yml" "$TMP/ci-no-archive-test.yml" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = "bash tools/archive-readiness-guard.test.sh"
assert step in text, "archive test step not found in ci.yml"
open(destination, "w", encoding="utf-8").write(text.replace(step, "true", 1))
PY
expect "ci.yml missing archive test step" fail "$TMP/ci-no-archive-test.yml" "$ROOT/tools/local-ci-mirror.sh"

python3 - "$ROOT/.github/workflows/ci.yml" "$TMP/ci-no-archive-guard.yml" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = "python3 tools/archive-readiness-guard.py"
assert step in text, "archive guard step not found in ci.yml"
open(destination, "w", encoding="utf-8").write(text.replace(step, "true", 1))
PY
expect "ci.yml missing archive guard step" fail "$TMP/ci-no-archive-guard.yml" "$ROOT/tools/local-ci-mirror.sh"

python3 - "$ROOT/.github/workflows/ci.yml" "$TMP/ci-comment-archive-test.yml" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = "bash tools/archive-readiness-guard.test.sh"
assert step in text, "archive test step not found in ci.yml"
open(destination, "w", encoding="utf-8").write(text.replace(step, "true # bash tools/archive-readiness-guard.test.sh", 1))
PY
expect "ci.yml comment-only archive test step" fail "$TMP/ci-comment-archive-test.yml" "$ROOT/tools/local-ci-mirror.sh"

python3 - "$ROOT/.github/workflows/ci.yml" "$TMP/ci-comment-archive-guard.yml" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = "python3 tools/archive-readiness-guard.py"
assert step in text, "archive guard step not found in ci.yml"
open(destination, "w", encoding="utf-8").write(text.replace(step, "true # python3 tools/archive-readiness-guard.py", 1))
PY
expect "ci.yml comment-only archive guard step" fail "$TMP/ci-comment-archive-guard.yml" "$ROOT/tools/local-ci-mirror.sh"

python3 - "$ROOT/.github/workflows/ci.yml" "$TMP" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
for name, step in (
    ("archive-test", "bash tools/archive-readiness-guard.test.sh"),
    ("archive-guard", "python3 tools/archive-readiness-guard.py"),
):
    needle = f"run: {step}"
    if needle not in source:
        raise SystemExit(f"step not found: {step}")
    (out / f"ci-or-true-{name}.yml").write_text(source.replace(needle, f"run: {step} || true", 1))
    (out / f"ci-continue-{name}.yml").write_text(source.replace(needle, f"continue-on-error: true\n        {needle}", 1))
    (out / f"ci-if-false-{name}.yml").write_text(source.replace(needle, f"if: ${{{{ false }}}}\n        {needle}", 1))
PY
for name in archive-test archive-guard; do
  expect "ci.yml $name cannot tolerate failure" fail "$TMP/ci-or-true-$name.yml" "$ROOT/tools/local-ci-mirror.sh"
  expect "ci.yml $name cannot continue on error" fail "$TMP/ci-continue-$name.yml" "$ROOT/tools/local-ci-mirror.sh"
  expect "ci.yml $name cannot be conditionally skipped" fail "$TMP/ci-if-false-$name.yml" "$ROOT/tools/local-ci-mirror.sh"
done

# 2. Local mirror step dropping, commenting, and no-op mutations
python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-no-archive-test.sh" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = 'step "archive-readiness guard self-test" bash tools/archive-readiness-guard.test.sh\n'
assert step in text, "archive test step not found in local-ci-mirror.sh"
open(destination, "w", encoding="utf-8").write(text.replace(step, "", 1))
PY
expect "local mirror missing archive test step" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-no-archive-test.sh"

python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-no-archive-guard.sh" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = 'step "archive-readiness guard"           python3 tools/archive-readiness-guard.py\n'
assert step in text, "archive guard step not found in local-ci-mirror.sh"
open(destination, "w", encoding="utf-8").write(text.replace(step, "", 1))
PY
expect "local mirror missing archive guard step" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-no-archive-guard.sh"

python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-comment-archive-test.sh" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = 'step "archive-readiness guard self-test" bash tools/archive-readiness-guard.test.sh'
assert step in text, "archive test step not found in local-ci-mirror.sh"
open(destination, "w", encoding="utf-8").write(text.replace(step, '# ' + step, 1))
PY
expect "local mirror commented archive test step" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-comment-archive-test.sh"

python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-comment-archive-guard.sh" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = 'step "archive-readiness guard"           python3 tools/archive-readiness-guard.py'
assert step in text, "archive guard step not found in local-ci-mirror.sh"
open(destination, "w", encoding="utf-8").write(text.replace(step, '# ' + step, 1))
PY
expect "local mirror commented archive guard step" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-comment-archive-guard.sh"

python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-noop-archive-test.sh" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = 'step "archive-readiness guard self-test" bash tools/archive-readiness-guard.test.sh'
assert step in text, "archive test step not found in local-ci-mirror.sh"
open(destination, "w", encoding="utf-8").write(text.replace(step, 'step "archive-readiness guard self-test" true # bash tools/archive-readiness-guard.test.sh', 1))
PY
expect "local mirror no-op archive test step" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-noop-archive-test.sh"

python3 - "$ROOT/tools/local-ci-mirror.sh" "$TMP/mirror-noop-archive-guard.sh" <<'PY'
import sys
source, destination = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
step = 'step "archive-readiness guard"           python3 tools/archive-readiness-guard.py'
assert step in text, "archive guard step not found in local-ci-mirror.sh"
open(destination, "w", encoding="utf-8").write(text.replace(step, 'step "archive-readiness guard" true # python3 tools/archive-readiness-guard.py', 1))
PY
expect "local mirror no-op archive guard step" fail "$ROOT/.github/workflows/ci.yml" "$TMP/mirror-noop-archive-guard.sh"
echo "local-ci-mirror-coverage.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
