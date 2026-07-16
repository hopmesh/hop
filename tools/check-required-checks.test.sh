#!/usr/bin/env bash
# Self-test for tools/check-required-checks.sh (aggregate-gate model). Drives the guard against crafted
# ci.yml + trigger fixtures via the CI_FILE / TRIGGER_FILE env overrides. Covers:
#   - happy path: gate needs every product job, allowlist == [CI gate]        -> pass
#   - allowlist not exactly [CI gate] (lists the jobs)                        -> fail
#   - a product job left OUT of the gate's needs (the fail-open blind spot)   -> fail
#   - a job with no explicit name:                                           -> fail
#   - a templated ${{ }} job name                                            -> fail
#   - no CI gate job at all                                                  -> fail
#   - a two-space job-level comment is skipped, not read as a job            -> pass
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/check-required-checks.sh"
pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# run_case LABEL WANT(pass|fail) CI_JOBS_BODY REQUIRED_BLOCK
run_case() {
  local label="$1" want="$2" ci_body="$3" req="$4" got
  local d; d="$(mktemp -d "$TMP/c.XXXXXX")"
  { printf 'name: CI\non: [push]\njobs:\n'; printf '%s' "$ci_body"; } > "$d/ci.yml"
  { printf 'substitutions:\n  _REQUIRED_CHECKS: |\n'; printf '%s' "$req"; } > "$d/trigger.yaml"
  if CI_FILE="$d/ci.yml" TRIGGER_FILE="$d/trigger.yaml" bash "$GUARD" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok   [$label]: guard $got as expected"
  else
    fail=$((fail + 1)); echo "FAIL [$label]: expected $want, guard $got"
    CI_FILE="$d/ci.yml" TRIGGER_FILE="$d/trigger.yaml" bash "$GUARD" 2>&1 | sed 's/^/    /' | head -4
  fi
}

CHANGES=$'  changes:\n    name: Detect changed areas\n    steps:\n      - run: echo changes\n'
RUST=$'  rust:\n    name: Rust checks\n    needs: changes\n    steps:\n      - run: echo hi\n'
WEB=$'  web:\n    name: Web build\n    needs: changes\n    steps:\n      - run: echo hi\n'
REQ_GATE=$'    CI gate\n'
# a gate that needs both product jobs + changes (correct)
gate_needs() { printf '  gate:\n    name: CI gate\n    needs:\n%s      - changes\n    steps:\n      - run: echo gate\n' "$1"; }
GATE_OK="$(gate_needs $'      - rust\n      - web\n')"

# 1) happy path
run_case "in_sync" pass "$CHANGES$RUST$WEB$GATE_OK" "$REQ_GATE"

# 2) allowlist lists the jobs instead of just the gate
run_case "allowlist_not_just_gate" fail "$CHANGES$RUST$WEB$GATE_OK" $'    Rust checks\n    Web build\n'

# 3) fail-open: the gate does not `needs:` web
GATE_NO_WEB="$(gate_needs $'      - rust\n')"
run_case "job_missing_from_gate_needs" fail "$CHANGES$RUST$WEB$GATE_NO_WEB" "$REQ_GATE"

# 4) a job with no explicit name: (gate DOES need it, so only the missing name fails)
NONAME=$'  sneaky:\n    needs: changes\n    steps:\n      - run: echo no-name\n'
GATE_SNEAKY="$(gate_needs $'      - rust\n      - web\n      - sneaky\n')"
run_case "job_without_name" fail "$CHANGES$RUST$WEB$NONAME$GATE_SNEAKY" "$REQ_GATE"

# 5) a templated ${{ }} job name (gate DOES need it, so only the templated name fails)
MATRIX=$'  matrixed:\n    name: Test (${{ matrix.os }})\n    needs: changes\n    steps:\n      - run: echo hi\n'
GATE_MATRIX="$(gate_needs $'      - rust\n      - web\n      - matrixed\n')"
run_case "templated_name" fail "$CHANGES$RUST$WEB$MATRIX$GATE_MATRIX" "$REQ_GATE"

# 6) no CI gate job at all
run_case "no_gate_job" fail "$CHANGES$RUST$WEB" "$REQ_GATE"

# 7) a two-space job-level comment must be skipped, not read as a nameless job
COMMENT=$'  # CI gate: the single required check for branch protection.\n'
run_case "comment_skipped" pass "$COMMENT$CHANGES$RUST$WEB$GATE_OK" "$REQ_GATE"

echo
if [ "$fail" -eq 0 ]; then
  echo "check-required-checks.test: all $pass cases passed"
else
  echo "check-required-checks.test: $fail case(s) FAILED"
  exit 1
fi
