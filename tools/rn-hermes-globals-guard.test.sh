#!/usr/bin/env bash
# Self-test for tools/rn-hermes-globals-guard.py.
#
# The point of a guard's self-test in this repo is to prove the guard can FAIL, because a check that
# cannot detect its own defect is worse than no check: it manufactures confidence. This guard exists
# because neither the typecheck nor the test suite can see its defect class (tsconfig declares the
# DOM and Node libs, and the tests run under node, which HAS these globals), so the guard is the
# only thing standing between a Hermes-absent global and a consuming app.
#
# Case 1 is the original defect verbatim. The rest are the ways a guard like this rots into a
# rubber stamp: missing a neighbour, matching a name that merely contains a denied one, being fooled
# by a comment, or passing vacuously when it is pointed at nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/rn-hermes-globals-guard.py"
pkg="sdk/react-native"
src="$pkg/src"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sandbox() {
  work="$tmp/case-$1"
  mkdir -p "$work/$src"
  cp "$root/$src"/*.ts "$root/$src"/*.tsx "$work/$src/"
  printf '%s' "$work"
}

# run_case <label> <pass|fail> <expected-fragment-or-empty> <work-dir>
run_case() {
  label="$1"; expected="$2"; fragment="$3"; work="$4"
  if output="$(python3 "$guard" "$work" 2>&1)"; then actual=pass; else actual=fail; fi
  if [ "$actual" != "$expected" ]; then
    printf 'rn-hermes-globals case %s: expected %s, got %s\n%s\n' "$label" "$expected" "$actual" "$output" >&2
    exit 1
  fi
  if [ -n "$fragment" ] && ! printf '%s' "$output" | grep -qF "$fragment"; then
    printf 'rn-hermes-globals case %s: rejected, but the message never mentions %s\n%s\n' \
      "$label" "$fragment" "$output" >&2
    exit 1
  fi
}

# 0. The real tree must pass, or every rejection below proves nothing.
run_case clean pass "" "$(sandbox clean)"

# 1. THE ORIGINAL DEFECT, verbatim: the line that shipped in bytesToUtf8.
work="$(sandbox textdecoder)"
printf 'export function d(b: Uint8Array): string {\n  return new TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case textdecoder fail "TextDecoder is not safe on Hermes" "$work"

# 2. The neighbour that was assumed safe because the encoder appeared to work. Hermes gained
# TextEncoder only recently and the peer range is react-native "*", so it is denied too.
work="$(sandbox textencoder)"
printf 'export function e(t: string): Uint8Array {\n  return new TextEncoder().encode(t);\n}\n' \
  > "$work/$src/scratch.ts"
run_case textencoder fail "TextEncoder is not safe on Hermes" "$work"

# 3. A global nobody has reached for yet. The guard has to cover the CLASS, not just the one
# instance that caused the incident.
work="$(sandbox structuredclone)"
printf 'export function c(v: Uint8Array): Uint8Array {\n  return structuredClone(v);\n}\n' \
  > "$work/$src/scratch.ts"
run_case structuredclone fail "structuredClone is not safe on Hermes" "$work"

# 4. Node-only, which is the same mistake wearing different clothes: green under node --test,
# absent in the app.
work="$(sandbox buffer)"
printf 'export function b(t: string): string {\n  return Buffer.from(t).toString("base64");\n}\n' \
  > "$work/$src/scratch.ts"
run_case buffer fail "Buffer is not safe on Hermes" "$work"

# 5. NOT a violation: an identifier that merely contains a denied name, or a property access. A
# guard that fires on these gets disabled by the next person, which is its own kind of failure.
work="$(sandbox lookalikes)"
cat > "$work/$src/scratch.ts" <<'TS'
class HopTextDecoder {
  decode(b: Uint8Array): string {
    return String(b.length);
  }
}
export const shim = { TextDecoder: HopTextDecoder };
export function use(host: { TextEncoder?: unknown }): boolean {
  return host.TextEncoder !== undefined;
}
TS
run_case lookalikes pass "" "$work"

# 6. NOT a violation: naming the global in a comment, which this repo does deliberately to explain
# why the codec is hand-rolled. src/base64.ts itself depends on this being allowed.
work="$(sandbox comment-only)"
printf '// TextDecoder is absent in Hermes, so we ship our own.\nexport const n = 1;\n' \
  > "$work/$src/scratch.ts"
run_case comment-only pass "" "$work"

# 7. Pointed at a tree with no sources, the guard must NOT report success. A vacuous pass is how a
# guard silently stops covering anything (a moved directory, a renamed package).
work="$tmp/case-empty"
mkdir -p "$work/$src"
run_case empty fail "would pass vacuously" "$work"

# 8. A missing package directory is an unknown, never a pass.
run_case absent fail "not found under" "$tmp/case-absent"

# 9. ABI-010: Explicit globalThis access must fail
work="$(sandbox globalthis)"
printf 'export function d(b: Uint8Array): string {\n  return new globalThis.TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case globalthis fail "TextDecoder is not safe on Hermes" "$work"

# 10. ABI-010: Explicit global access must fail
work="$(sandbox global)"
printf 'export function d(b: Uint8Array): string {\n  return new global.TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case global fail "TextDecoder is not safe on Hermes" "$work"

# 11. ABI-010: Computed property access must fail
work="$(sandbox computed)"
printf 'export function d(b: Uint8Array): string {\n  const TD = globalThis["TextDecoder"];\n  return new TD().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case computed fail "TextDecoder is not safe on Hermes" "$work"

# 12. ABI-010: Destructuring from globalThis must fail
work="$(sandbox destructure)"
printf 'const { TextDecoder } = globalThis;\nexport function d(b: Uint8Array): string {\n  return new TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case destructure fail "TextDecoder is not safe on Hermes" "$work"

# 13. ABI-010: Aliasing bare global must fail
work="$(sandbox alias)"
printf 'const TD = TextDecoder;\nexport function d(b: Uint8Array): string {\n  return new TD().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case alias fail "TextDecoder is not safe on Hermes" "$work"

# 14. ABI-010: Optional chaining on globalThis must fail
work="$(sandbox optchain)"
printf 'export function d(b: Uint8Array): unknown {\n  return globalThis?.TextDecoder;\n}\n' \
  > "$work/$src/scratch.ts"
run_case optchain fail "TextDecoder is not safe on Hermes" "$work"

# 15. ABI-010: Strings and block comments containing the global name must pass
work="$(sandbox strings-and-comments)"
cat > "$work/$src/scratch.ts" <<'TS'
/* Block comment mentioning TextDecoder */
export const errMsg = "TextDecoder is not available in Hermes";
TS
run_case strings-and-comments pass "" "$work"

# 16. ABI-010: self.TextDecoder property access must fail
work="$(sandbox self-property)"
printf 'export function d(b: Uint8Array): unknown {\n  return new self.TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case self-property fail "TextDecoder is not safe on Hermes" "$work"

# 17. ABI-010: self["TextDecoder"] bracket access must fail
work="$(sandbox self-bracket)"
printf 'export function d(b: Uint8Array): unknown {\n  const TD = self["TextDecoder"];\n  return new TD().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case self-bracket fail "TextDecoder is not safe on Hermes" "$work"

# 18. ABI-010: Template literal computed access must fail
work="$(sandbox template-literal)"
printf 'export function d(b: Uint8Array): unknown {\n  const TD = globalThis[`TextDecoder`];\n  return new TD().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case template-literal fail "TextDecoder is not safe on Hermes" "$work"

# 19. ABI-010: frames.TextDecoder must fail
work="$(sandbox frames-property)"
printf 'export function d(b: Uint8Array): unknown {\n  return new frames.TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case frames-property fail "TextDecoder is not safe on Hermes" "$work"

# 20. ABI-010: top.TextDecoder must fail
work="$(sandbox top-property)"
printf 'export function d(b: Uint8Array): unknown {\n  return new top.TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case top-property fail "TextDecoder is not safe on Hermes" "$work"

# 21. ABI-010: parent.TextDecoder must fail
work="$(sandbox parent-property)"
printf 'export function d(b: Uint8Array): unknown {\n  return new parent.TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case parent-property fail "TextDecoder is not safe on Hermes" "$work"

# 22. ABI-018: Multiline aliased destructuring from globalThis must fail
work="$(sandbox multiline-aliased-destructure)"
printf 'const {\n  TextDecoder: myDecoder,\n} = globalThis;\nexport function d(b: Uint8Array): unknown {\n  return new myDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case multiline-aliased-destructure fail "TextDecoder is not safe on Hermes" "$work"

# 23. ABI-018: Multiline unaliased destructuring from globalThis must fail
work="$(sandbox multiline-unaliased-destructure)"
printf 'const {\n  TextDecoder,\n} = globalThis;\nexport function d(b: Uint8Array): unknown {\n  return new TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case multiline-unaliased-destructure fail "TextDecoder is not safe on Hermes" "$work"

# 24. ABI-018: Local variable aliasing globalThis must fail on property access
work="$(sandbox alias-globalthis-property)"
printf 'const g = globalThis;\nexport function d(b: Uint8Array): unknown {\n  return new g.TextDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case alias-globalthis-property fail "TextDecoder is not safe on Hermes" "$work"

# 25. ABI-018: Local variable aliasing globalThis with multiline destructuring must fail
work="$(sandbox alias-globalthis-destructure)"
printf 'const g = globalThis;\nconst {\n  TextDecoder: myDecoder,\n} = g;\nexport function d(b: Uint8Array): unknown {\n  return new myDecoder().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case alias-globalthis-destructure fail "TextDecoder is not safe on Hermes" "$work"

# 26. ABI-018: Local variable aliasing window with bracket access must fail
work="$(sandbox alias-window-bracket)"
printf 'const w = window;\nexport function d(b: Uint8Array): unknown {\n  const TD = w["TextDecoder"];\n  return new TD().decode(b);\n}\n' \
  > "$work/$src/scratch.ts"
run_case alias-window-bracket fail "TextDecoder is not safe on Hermes" "$work"

echo "rn hermes globals guard tests passed"
