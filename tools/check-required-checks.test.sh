#!/usr/bin/env bash
# Self-test the branch-protection required-check contract with isolated CI fixtures.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/check-required-checks.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

DEFAULT_CONFIG='{"required_checks":["Detect changed areas","Rust checks","Web build","Automation authority guards","CI gate"]}'

run_case() {
  local label="$1" want="$2" ci_body="$3" config="${4:-$DEFAULT_CONFIG}" got output
  local dir
  dir="$(mktemp -d "$TMP/case.XXXXXX")"

  {
    printf 'name: CI\n'
    printf "'on': [push]\n"
    printf 'jobs:\n'
    printf '%s' "$ci_body"
  } > "$dir/ci.yml"
  printf '%s\n' "$config" > "$dir/required-checks.json"

  if output="$(CI_FILE="$dir/ci.yml" REQUIRED_CHECKS_FILE="$dir/required-checks.json" bash "$GUARD" 2>&1)"; then
    got=pass
  else
    got=fail
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf 'ok   [%s]: guard %s as expected\n' "$label" "$got"
  else
    fail=$((fail + 1))
    printf 'FAIL [%s]: expected %s, guard %s\n%s\n' "$label" "$want" "$got" "$output"
  fi
}

CHANGES=$'  changes:\n    name: Detect changed areas\n    steps:\n      - run: echo changes\n'
RUST=$'  rust:\n    name: Rust checks\n    needs: changes\n    steps:\n      - run: echo rust\n'
WEB=$'  web:\n    name: Web build\n    needs: changes\n    steps:\n      - run: echo web\n'
AUTOMATION=$'  automation:\n    name: Automation authority guards\n    steps:\n      - run: echo automation\n'

gate() {
  printf '%s' $'  gate:\n    name: CI gate\n    runs-on: ubuntu-latest\n    if: always()\n    needs:\n'
  printf '%s' "$1"
  printf '%s' $'    steps:\n      - name: Fail closed\n        if: contains(needs.*.result, '\''failure'\'') || contains(needs.*.result, '\''cancelled'\'') || needs.changes.result != '\''success'\'' || needs.automation.result != '\''success'\''\n        run: exit 1\n'
}

GATE_OK="$(gate $'      - rust\n      - web\n      - automation\n      - changes\n')"

run_case "gate_and_automation_ok" pass "$CHANGES$RUST$WEB$AUTOMATION$GATE_OK"

GATE_NO_WEB="$(gate $'      - rust\n      - automation\n      - changes\n')"
run_case "internal_job_missing_from_gate" fail "$CHANGES$RUST$WEB$AUTOMATION$GATE_NO_WEB"

GATE_NO_CHANGES="$(gate $'      - rust\n      - web\n      - automation\n')"
run_case "change_detector_missing_from_gate" fail "$CHANGES$RUST$WEB$AUTOMATION$GATE_NO_CHANGES"

GATE_NO_ALWAYS="${GATE_OK/    if: always()$'\n'/}"
run_case "gate_without_always" fail "$CHANGES$RUST$WEB$AUTOMATION$GATE_NO_ALWAYS"

GATE_NO_VERDICT="${GATE_OK/failure/success}"
run_case "gate_without_failure_verdict" fail "$CHANGES$RUST$WEB$AUTOMATION$GATE_NO_VERDICT"

GATE_ALLOWS_SKIPPED_AUTOMATION="${GATE_OK/needs.automation.result/needs.automation.outcome}"
run_case "gate_allows_skipped_automation" fail "$CHANGES$RUST$WEB$AUTOMATION$GATE_ALLOWS_SKIPPED_AUTOMATION"

AUTOMATION_IF="${AUTOMATION/    steps:/    if: false$'\n'    steps:}"
run_case "automation_has_condition" fail "$CHANGES$RUST$WEB$AUTOMATION_IF$GATE_OK"

AUTOMATION_NEEDS="${AUTOMATION/    steps:/    needs: changes$'\n'    steps:}"
run_case "automation_has_dependency" fail "$CHANGES$RUST$WEB$AUTOMATION_NEEDS$GATE_OK"

NONAME=$'  sneaky:\n    needs: changes\n    steps:\n      - run: echo hidden\n'
GATE_SNEAKY="$(gate $'      - rust\n      - web\n      - automation\n      - sneaky\n      - changes\n')"
run_case "job_without_name" fail "$CHANGES$RUST$WEB$AUTOMATION$NONAME$GATE_SNEAKY"

MATRIX=$'  matrixed:\n    name: Test (${{ matrix.os }})\n    needs: changes\n    steps:\n      - run: echo matrix\n'
GATE_MATRIX="$(gate $'      - rust\n      - web\n      - automation\n      - matrixed\n      - changes\n')"
run_case "templated_job_name" fail "$CHANGES$RUST$WEB$AUTOMATION$MATRIX$GATE_MATRIX"

run_case "no_gate_job" fail "$CHANGES$RUST$WEB$AUTOMATION"

ANCHOR_WEB="${WEB/  web:/  web: &web_anchor}"
run_case "anchored_job_visible" pass "$CHANGES$RUST$ANCHOR_WEB$AUTOMATION$GATE_OK"

COMMENT=$'  # CI gate: live branch protection requires this aggregate.\n'
run_case "job_level_comment_ignored" pass "$COMMENT$CHANGES$RUST$WEB$AUTOMATION$GATE_OK"

# The canonical required-checks.json must match ci.yml job names in order.
run_case "required_checks_config_drift" fail "$CHANGES$RUST$WEB$AUTOMATION$GATE_OK" \
  '{"required_checks":["Detect changed areas","Rust checks","Automation authority guards","CI gate"]}'
run_case "required_checks_config_reordered" fail "$CHANGES$RUST$WEB$AUTOMATION$GATE_OK" \
  '{"required_checks":["Rust checks","Detect changed areas","Web build","Automation authority guards","CI gate"]}'

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'check-required-checks.test: all %s cases passed\n' "$pass"
else
  printf 'check-required-checks.test: %s case(s) FAILED\n' "$fail"
  exit 1
fi
