#!/usr/bin/env bash
# Self-test for tools/workflow-run-syntax-guard.py. The guard exists because a workflow
# `run:` script had a missing `done` in a loop (REL-006), causing a syntax error in CI.
#
# Asserts the guard:
# (a) passes valid run scripts (single-line and multi-line)
# (b) FAILS on a missing `done` in a for loop (the incident fixture)
# (c) FAILS on an unclosed if block
# (d) FAILS on an empty workflows directory
# No repo state.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/workflow-run-syntax-guard.py"
pass=0
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect() {
  dir="$1"
  want="$2"
  label="$3"
  out="$TMP/out"
  err="$TMP/err"
  if python3 "$GUARD" --workflows "$dir" >"$out" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  case "$want" in
    pass)
      if [ "$rc" -eq 0 ]; then
        echo "  PASS $label (exit 0 as expected)"
        pass=$((pass + 1))
      else
        echo "  FAIL $label: expected exit 0, got $rc"
        cat "$err" >&2
        fail=$((fail + 1))
      fi
      ;;
    fail)
      if [ "$rc" -ne 0 ]; then
        echo "  PASS $label (exit $rc as expected)"
        pass=$((pass + 1))
      else
        echo "  FAIL $label: expected non-zero exit, got 0"
        cat "$out" >&2
        fail=$((fail + 1))
      fi
      ;;
  esac
}

# (a) valid run scripts
mkdir -p "$TMP/good"
cat > "$TMP/good/w.yml" <<'YML'
name: good
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Valid oneline
        run: echo "hello world"
      - name: Valid multiline
        run: |
          set -euo pipefail
          for i in 1 2 3; do
            echo "$i"
          done
YML
expect "$TMP/good" pass "valid_run_scripts"

# (b) THE INCIDENT: missing `done` in a for loop
mkdir -p "$TMP/missing_done"
cat > "$TMP/missing_done/w.yml" <<'YML'
name: missing-done
on: push
jobs:
  embedded:
    runs-on: ubuntu-latest
    steps:
      - name: Build and package each exact embedded target
        run: |
          set -euo pipefail
          for target in xtensa-esp32-espidf riscv32imc-esp-espidf; do
            cargo +esp build -p hop --target "$target"
            mkdir -p "out/$target"
            cp "target/$target/release/libhop.a" "out/$target/libhop.a"
YML
expect "$TMP/missing_done" fail "missing_done_in_loop"

# (c) unclosed if block
mkdir -p "$TMP/unclosed_if"
cat > "$TMP/unclosed_if/w.yml" <<'YML'
name: unclosed-if
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Broken if
        run: |
          if [ -f foo ]; then
            echo "foo exists"
YML
expect "$TMP/unclosed_if" fail "unclosed_if_block"

# (d) empty workflows directory
mkdir -p "$TMP/empty"
expect "$TMP/empty" fail "empty_workflows_dir"

echo
if [ "$fail" -eq 0 ]; then
  echo "workflow-run-syntax-guard.test.sh: all $pass tests passed"
  exit 0
else
  echo "workflow-run-syntax-guard.test.sh: $fail failed, $pass passed"
  exit 1
fi
