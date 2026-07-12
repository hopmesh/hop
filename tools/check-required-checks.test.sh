#!/usr/bin/env bash
# Self-test for tools/check-required-checks.sh. The guard keeps three lists in sync (ci.yml job
# names == cloudbuild.trigger.yaml _REQUIRED_CHECKS, cross-checked against infra/README.md). This
# test builds throwaway fixtures under a fake repo ROOT and asserts the guard's verdict, covering:
#   - the sync happy path (names match)                                          -> pass
#   - a renamed job the allowlist didn't follow (infra-r2-02)                    -> fail
#   - a job with NO explicit `name:` (the 2nd-pass deploy-gate blind spot):      -> fail
#     such a job still runs and still gates deploys under its job-id, but is invisible to this
#     allowlist sync, so it could be red while `tofu apply` proceeds. The guard must refuse it.
# No network, no real repo state (the guard is copied into a temp ROOT and pointed at fixtures).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/check-required-checks.sh"
pass=0
fail=0

# build_root DIR JOBS_BLOCK REQUIRED_BLOCK README_TEXT: lay out a minimal fake repo whose guard copy
# reads .github/workflows/ci.yml + infra/cloudbuild.trigger.yaml + infra/README.md.
build_root() {
  local dir="$1" jobs="$2" req="$3" readme="$4"
  mkdir -p "$dir/.github/workflows" "$dir/infra" "$dir/tools"
  cp "$GUARD" "$dir/tools/check-required-checks.sh"
  { printf 'name: ci\non: [push]\njobs:\n'; printf '%s' "$jobs"; } > "$dir/.github/workflows/ci.yml"
  { printf 'substitutions:\n  _REQUIRED_CHECKS: |\n'; printf '%s' "$req"; } > "$dir/infra/cloudbuild.trigger.yaml"
  printf '%s\n' "$readme" > "$dir/infra/README.md"
}

# expect DIR WANT(pass|fail) LABEL
expect() {
  local dir="$1" want="$2" label="$3"
  if bash "$dir/tools/check-required-checks.sh" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok   [$label]: guard $got as expected"
  else
    fail=$((fail + 1)); echo "FAIL [$label]: expected $want, guard $got"
    bash "$dir/tools/check-required-checks.sh" 2>&1 | sed 's/^/    /' | head -6
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TWO_JOBS=$'  rust:\n    name: Rust checks\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  web:\n    name: Web build\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'
TWO_REQ=$'    Rust checks\n    Web build\n'
README='Deploy gate: Rust and Web must be green.'

# 1) happy path: ci job names == required allowlist -> pass
build_root "$TMP/ok" "$TWO_JOBS" "$TWO_REQ" "$README"
expect "$TMP/ok" pass "in_sync"

# 2) a renamed job the allowlist didn't follow -> fail (existing infra-r2-02 behavior)
RENAMED_JOBS=$'  rust:\n    name: Rust checks RENAMED\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  web:\n    name: Web build\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'
build_root "$TMP/drift" "$RENAMED_JOBS" "$TWO_REQ" "$README"
expect "$TMP/drift" fail "renamed_out_of_sync"

# 3) THE 2ND-PASS FINDING: a job with no explicit name: -> fail (deploy-gate blind spot)
NAMELESS_JOBS=$'  rust:\n    name: Rust checks\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  sneaky:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo no-name\n'
build_root "$TMP/nameless" "$NAMELESS_JOBS" "$TWO_REQ" "$README"
expect "$TMP/nameless" fail "job_without_name"

echo
if [ "$fail" -eq 0 ]; then
  echo "check-required-checks.test: all $pass cases passed"
else
  echo "check-required-checks.test: $fail case(s) FAILED"
  exit 1
fi
