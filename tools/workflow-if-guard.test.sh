#!/usr/bin/env bash
# Self-test for tools/workflow-if-guard.py. The guard exists because a folded `if:` whose continuation
# lines were indented FURTHER than the first kept its newlines literally, so the expression never
# evaluated as intended and the job SKIPPED on every PR while CI stayed green.
#
# Asserts the guard (a) passes a single-line expression, (b) passes a multi-line fold done with EQUAL
# indentation (which folds to spaces and is legitimate), (c) FAILS the more-indented fold that caused
# the incident, (d) FAILS a newline-bearing expression on a step-level `if`, not just a job-level one,
# (e) passes an `if` with a newline but NO expression (a plain string, which GitHub treats literally
# and is not this bug), and (f) fails on an empty workflows dir. No repo state.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/workflow-if-guard.py"
pass=0
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# expect DIR WANT(pass|fail) LABEL
expect() {
  local d="$1" want="$2" label="$3"
  if python3 "$GUARD" --workflows "$d" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok   [$label]: guard $got as expected"
  else
    fail=$((fail + 1)); echo "FAIL [$label]: expected $want, guard $got"
    python3 "$GUARD" --workflows "$d" 2>&1 | sed 's/^/    /' | head -5
  fi
}

# (a) single line, the correct form
mkdir -p "$TMP/oneline"
cat > "$TMP/oneline/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    if: ${{ !github.event.pull_request.draft && github.actor == 'someone' }}
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
YML
expect "$TMP/oneline" pass "single_line_expression"

# (b) folded with EQUAL indentation: folds to spaces, so it is fine
mkdir -p "$TMP/evenfold"
cat > "$TMP/evenfold/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    if: >-
      ${{ !github.event.pull_request.draft
      && github.actor == 'someone' }}
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
YML
expect "$TMP/evenfold" pass "folded_equal_indent_is_ok"

# (c) THE INCIDENT: continuation lines indented further, so newlines survive the fold
mkdir -p "$TMP/badfold"
cat > "$TMP/badfold/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    if: >-
      ${{ !github.event.pull_request.draft
        && (contains(fromJSON('["OWNER","MEMBER"]'), github.event.pull_request.author_association)
          || github.event.pull_request.user.login == 'dependabot[bot]') }}
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
YML
expect "$TMP/badfold" fail "more_indented_fold_keeps_newlines"

# (d) same defect on a STEP-level if, to prove the walk is not job-only
mkdir -p "$TMP/stepif"
cat > "$TMP/stepif/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
        if: >-
          ${{ github.actor == 'a'
            || github.actor == 'b' }}
YML
expect "$TMP/stepif" fail "step_level_if_is_checked"

# (e) a newline but no ${{ }}: GitHub treats a bare string literally, so this is not the bug
mkdir -p "$TMP/noexpr"
cat > "$TMP/noexpr/w.yml" <<'YML'
name: w
on: [push]
jobs:
  j:
    if: >-
      success()
        && always()
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
YML
expect "$TMP/noexpr" pass "newline_without_expression_is_ignored"

# (f) no workflows at all
mkdir -p "$TMP/empty"
expect "$TMP/empty" fail "empty_workflows_dir"

echo
if [ "$fail" -eq 0 ]; then
  echo "workflow-if-guard.test: all $pass cases passed"
else
  echo "workflow-if-guard.test: $fail case(s) FAILED"
  exit 1
fi
