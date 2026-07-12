#!/usr/bin/env bash
# Self-test for tools/repo-integrity-guard.sh. A bare `-s` (size > 0) check is too weak: the
# 0-byte-LICENSE regression this guard exists for could re-land as a 1-byte or marker-stripped file
# and still pass. This test copies the guard into a throwaway ROOT and asserts it (a) passes a healthy
# fixture, and fails on (b) a missing file, (c) a 0-byte file, (d) a 1-byte/truncated file, (e) a file
# whose signature line was stripped, and (f) the two LICENSE copies drifting apart. No repo state.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/repo-integrity-guard.sh"
pass=0
fail=0

# A healthy LICENSE body (well above the 1500-byte floor, carries the FSL signature line).
LICENSE_BODY="$(python3 - <<'PY'
body = "# Functional Source License, Version 1.1, ALv2 Future License\n\n"
body += ("Grant of license and the usual FSL terms, restated at length. " * 60)
print(body)
PY
)"

# lay_down DIR: a fully-healthy fixture tree. Callers then mutate one file to create a failure.
lay_down() {
  local d="$1"
  mkdir -p "$d/core/hop-wasm" "$d/sdk" "$d/tools"
  cp "$GUARD" "$d/tools/repo-integrity-guard.sh"
  printf '%s\n' "$LICENSE_BODY" > "$d/LICENSE.md"
  printf '%s\n' "$LICENSE_BODY" > "$d/core/hop-wasm/LICENSE.md"
  python3 - "$d/README.md" <<'PY'
import sys; open(sys.argv[1],"w").write("# Hop\n" + "A delay-tolerant mesh. "*30 + "\n")
PY
  python3 - "$d/DESIGN.md" <<'PY'
import sys; open(sys.argv[1],"w").write("# Hop, Design\n" + "design prose. "*400 + "\n")
PY
  python3 - "$d/MECHANISMS.md" <<'PY'
import sys; open(sys.argv[1],"w").write("# Hop mechanisms\n" + "mechanism prose. "*400 + "\n")
PY
  python3 - "$d/sdk/hop.h" <<'PY'
import sys; open(sys.argv[1],"w").write("/* libhop */\n#define HOP_ABI_VERSION 2\n" + "// api decl\n"*400)
PY
}

# expect DIR WANT(pass|fail) LABEL
expect() {
  local d="$1" want="$2" label="$3"
  if bash "$d/tools/repo-integrity-guard.sh" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "ok   [$label]: guard $got as expected"
  else
    fail=$((fail + 1)); echo "FAIL [$label]: expected $want, guard $got"
    bash "$d/tools/repo-integrity-guard.sh" 2>&1 | sed 's/^/    /' | head -4
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

lay_down "$TMP/ok";         expect "$TMP/ok" pass "healthy"
lay_down "$TMP/missing";    rm "$TMP/missing/LICENSE.md";                 expect "$TMP/missing" fail "missing_license"
lay_down "$TMP/zero";       : > "$TMP/zero/LICENSE.md";                   expect "$TMP/zero" fail "zero_byte_license"
lay_down "$TMP/onebyte";    printf 'x' > "$TMP/onebyte/LICENSE.md";       expect "$TMP/onebyte" fail "one_byte_license"
lay_down "$TMP/nomarker";   python3 - "$TMP/nomarker/LICENSE.md" <<'PY'
import sys; open(sys.argv[1],"w").write("padding text without the signature line. "*80 + "\n")
PY
expect "$TMP/nomarker" fail "marker_stripped"
lay_down "$TMP/drift";      printf '%s\nextra line makes it differ\n' "$LICENSE_BODY" > "$TMP/drift/LICENSE.md"
expect "$TMP/drift" fail "license_copies_drift"

echo
if [ "$fail" -eq 0 ]; then
  echo "repo-integrity-guard.test: all $pass cases passed"
else
  echo "repo-integrity-guard.test: $fail case(s) FAILED"
  exit 1
fi
