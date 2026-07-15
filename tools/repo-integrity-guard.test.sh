#!/usr/bin/env bash
# Self-test for tools/repo-integrity-guard.sh. A bare `-s` (size > 0) check is too weak: the
# 0-byte-LICENSE regression this guard exists for could re-land as a 1-byte or marker-stripped file
# and still pass. Licensing is PER-COMPONENT and now TWO-TIER: sdk/* wrapper packages carry Apache-2.0,
# every other component carries FSL-1.1-ALv2, and each tier must be byte-identical within itself. This
# test lays down a multi-component, two-tier fixture and asserts the guard (a) passes a healthy tree,
# and fails on (b) a 0-byte copy, (c) a 1-byte/truncated copy, (d) a copy whose signature line was
# stripped, (e) an FSL copy drifting from the rest, (f) an Apache copy drifting from the rest, (g) an
# sdk/ file wearing the FSL license (wrong tier), (h) a non-sdk file wearing the Apache license (wrong
# tier), and (i) no LICENSE.md present at all. No repo state.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/repo-integrity-guard.sh"
pass=0
fail=0

# A healthy FSL body (well above the 1500-byte floor, carries the FSL signature line).
FSL_BODY="$(python3 - <<'PY'
body = "# Functional Source License, Version 1.1, ALv2 Future License\n\n"
body += ("Grant of license and the usual FSL terms, restated at length. " * 60)
print(body)
PY
)"

# A healthy Apache-2.0 body (above the floor, carries the "Apache License" signature line). Distinct
# text from FSL so a byte-for-byte cross-tier swap is impossible.
APACHE_BODY="$(python3 - <<'PY'
body = "                                 Apache License\n                           Version 2.0, January 2004\n\n"
body += ("Terms and Conditions for use, reproduction, and distribution, at length. " * 60)
print(body)
PY
)"

# FSL-tier components (non-sdk) and Apache-tier components (sdk/*) the fixture lays down.
FSL_LICENSES=("core/hop-core/LICENSE.md" "core/hop-wasm/LICENSE.md")
APACHE_LICENSES=("sdk/node/LICENSE.md" "sdk/go/LICENSE.md")

# lay_down DIR: a fully-healthy two-tier fixture tree. Callers then mutate one file to create a failure.
lay_down() {
  local d="$1"
  mkdir -p "$d/core/hop-core" "$d/core/hop-wasm" "$d/sdk/node" "$d/sdk/go" "$d/tools"
  cp "$GUARD" "$d/tools/repo-integrity-guard.sh"
  local lf
  for lf in "${FSL_LICENSES[@]}"; do printf '%s\n' "$FSL_BODY" > "$d/$lf"; done
  for lf in "${APACHE_LICENSES[@]}"; do printf '%s\n' "$APACHE_BODY" > "$d/$lf"; done
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

FSLONE="core/hop-core/LICENSE.md"    # mutate this FSL-tier copy to create a failure
APACHEONE="sdk/go/LICENSE.md"        # mutate this Apache-tier copy to create a failure

lay_down "$TMP/ok";         expect "$TMP/ok" pass "healthy_two_tier"
lay_down "$TMP/zero";       : > "$TMP/zero/$FSLONE";                    expect "$TMP/zero" fail "zero_byte_license"
lay_down "$TMP/onebyte";    printf 'x' > "$TMP/onebyte/$FSLONE";       expect "$TMP/onebyte" fail "one_byte_license"
lay_down "$TMP/nomarker";   python3 - "$TMP/nomarker/$FSLONE" <<'PY'
import sys; open(sys.argv[1],"w").write("padding text without the signature line. "*80 + "\n")
PY
expect "$TMP/nomarker" fail "marker_stripped"
lay_down "$TMP/fsldrift";   printf '%s\nextra line makes this copy differ\n' "$FSL_BODY" > "$TMP/fsldrift/$FSLONE"
expect "$TMP/fsldrift" fail "fsl_licenses_drift"
lay_down "$TMP/apachedrift"; printf '%s\nextra line makes this copy differ\n' "$APACHE_BODY" > "$TMP/apachedrift/$APACHEONE"
expect "$TMP/apachedrift" fail "apache_licenses_drift"
lay_down "$TMP/sdkwrongtier"; printf '%s\n' "$FSL_BODY" > "$TMP/sdkwrongtier/$APACHEONE"   # sdk/ wearing FSL
expect "$TMP/sdkwrongtier" fail "sdk_wears_fsl_wrong_tier"
lay_down "$TMP/corewrongtier"; printf '%s\n' "$APACHE_BODY" > "$TMP/corewrongtier/$FSLONE" # core/ wearing Apache
expect "$TMP/corewrongtier" fail "core_wears_apache_wrong_tier"
lay_down "$TMP/nolicense";  find "$TMP/nolicense" -name LICENSE.md -delete
expect "$TMP/nolicense" fail "no_license_at_all"

echo
if [ "$fail" -eq 0 ]; then
  echo "repo-integrity-guard.test: all $pass cases passed"
else
  echo "repo-integrity-guard.test: $fail case(s) FAILED"
  exit 1
fi
