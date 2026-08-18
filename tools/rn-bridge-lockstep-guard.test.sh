#!/usr/bin/env bash
# Self-test for tools/rn-bridge-lockstep-guard.py.
#
# The point of a guard's self-test in this repo is to prove the guard can FAIL, because a check that
# cannot detect its own defect is worse than no check: it manufactures confidence. Every case below
# breaks exactly one side of the bridge and requires the guard to reject it AND to name what broke,
# so a guard degraded into `print("OK")` fails this file.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/rn-bridge-lockstep-guard.py"
pkg="sdk/react-native"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

native_ts="$pkg/src/native.ts"
swift="$pkg/ios/HopMesh.swift"
objc="$pkg/ios/HopMesh.m"
kotlin="$pkg/android/src/main/java/sh/hop/reactnative/HopMeshModule.kt"

sandbox() {
  work="$tmp/case-$1"
  mkdir -p "$work/$pkg/src" "$work/$pkg/ios" "$work/$pkg/android/src/main/java/sh/hop/reactnative"
  cp "$root/$native_ts" "$work/$native_ts"
  cp "$root/$swift"     "$work/$swift"
  cp "$root/$objc"      "$work/$objc"
  cp "$root/$kotlin"    "$work/$kotlin"
  printf '%s' "$work"
}

# run_case <label> <pass|fail> <expected-fragment-or-empty> <work-dir>
run_case() {
  label="$1"; expected="$2"; fragment="$3"; work="$4"
  if output="$(python3 "$guard" "$work" 2>&1)"; then actual=pass; else actual=fail; fi
  if [ "$actual" != "$expected" ]; then
    printf 'rn-bridge-lockstep case %s: expected %s, got %s\n%s\n' "$label" "$expected" "$actual" "$output" >&2
    exit 1
  fi
  if [ -n "$fragment" ] && ! printf '%s' "$output" | grep -qF "$fragment"; then
    printf 'rn-bridge-lockstep case %s: rejected, but the message never mentions %s\n%s\n' \
      "$label" "$fragment" "$output" >&2
    exit 1
  fi
}

# 0. The real tree must pass, or every rejection below proves nothing.
run_case clean pass "" "$(sandbox clean)"

# 1-3. A method present in the contract but dropped from ONE platform. This is the exact failure the
# CLAUDE.md sentence describes, and the one the JS tests cannot see because they fake the module.
work="$(sandbox drop-swift)"
python3 - "$work/$swift" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"\n\s*@objc\([^)]*\)\s*\n\s*func\s+setName\b.*?\n\s*\}\n", "\n", t, count=1, flags=re.S)
open(p, "w").write(t)
PY
run_case drop-swift fail "missing from ios/HopMesh.swift" "$work"

work="$(sandbox drop-objc)"
python3 - "$work/$objc" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"RCT_EXTERN_METHOD\(\s*setName:.*?\)\s*\n", "", t, count=1, flags=re.S)
open(p, "w").write(t)
PY
run_case drop-objc fail "missing from ios/HopMesh.m" "$work"

work="$(sandbox drop-kotlin)"
python3 - "$work/$kotlin" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"\n\s*@ReactMethod\s*\n\s*fun\s+setName\b.*?\n\s*\}\n", "\n", t, count=1, flags=re.S)
open(p, "w").write(t)
PY
run_case drop-kotlin fail "missing from the Android module" "$work"

# 4. Drift the other way: the platforms implement something the contract never declared.
work="$(sandbox drop-contract)"
python3 - "$work/$native_ts" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"\n\s{2}setName\b[^\n]*\n", "\n", t, count=1)
open(p, "w").write(t)
PY
run_case drop-contract fail "absent from the contract" "$work"

# 5. Both sides present, selectors disagree. Compiles fine; throws "unrecognized selector" the first
# time JS calls it. Name-only comparison would pass this, which is why the guard compares selectors.
work="$(sandbox selector-drift)"
python3 - "$work/$swift" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
assert "@objc(setName:name:resolver:rejecter:)" in t or "@objc(setName:" in t, "fixture: setName selector not found"
i = t.index("@objc(setName:")
j = t.index(")", i)
t = t[:i] + "@objc(setName:renamedArg:resolver:rejecter:" + t[j:]
open(p, "w").write(t)
PY
run_case selector-drift fail "selector mismatch" "$work"

# 6. The RCTEventEmitter exemption must not be a hole in either direction.
work="$(sandbox emitter-on-ios)"
python3 - "$work/$swift" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("@objc(createEphemeral:", "@objc(addListener:)\n  func addListener(_ eventName: String) {}\n\n  @objc(createEphemeral:", 1)
open(p, "w").write(t)
PY
run_case emitter-on-ios fail "inherited from RCTEventEmitter" "$work"

work="$(sandbox emitter-off-android)"
python3 - "$work/$kotlin" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"\n\s*@ReactMethod\s*\n\s*fun\s+addListener\b.*?\n\s*\}\n", "\n", t, count=1, flags=re.S)
open(p, "w").write(t)
PY
run_case emitter-off-android fail "missing from the Android module" "$work"

# 7. A missing bridge file is an unknown, never a pass.
work="$(sandbox missing-file)"
rm "$work/$objc"
run_case missing-file fail "missing bridge file" "$work"

echo "rn bridge lockstep guard tests passed"
