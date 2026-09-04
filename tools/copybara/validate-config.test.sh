#!/usr/bin/env bash
# Self-test for validate-config.sh: the committed config must pass, and a config carrying the exact
# defect the guard exists for (a same-path core.move, REL-003) must be rejected. Needs docker, like
# the guard itself; skips loudly when docker is absent so a missing daemon never reads as a pass.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/validate-config.sh"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "validate-config.test.sh: SKIP (docker is not available); this proves nothing" >&2
  exit 3
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# 1. The committed config loads.
if bash "$GUARD" "$HERE/copy.bara.sky" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: committed copy.bara.sky was rejected" >&2; fi

# 2. A same-path move must be rejected (this is the shape that shipped in ABI-011).
python3 - "$HERE/copy.bara.sky" "$TMP/noop-move.sky" <<'EOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
anchor = '        core.move(EXPORT_SMOKE, ".github/package-export-smoke.py"),\n'
assert anchor in text, "anchor line missing; update the self-test with the config"
open(dst, "w", encoding="utf-8").write(text.replace(anchor, anchor + '        core.move(THIRD_PARTY_NOTICES, "THIRD-PARTY-NOTICES.md"),\n', 1))
EOF
if bash "$GUARD" "$TMP/noop-move.sky" >/dev/null 2>&1; then fail=$((fail + 1)); echo "FAIL: same-path move was accepted" >&2; else pass=$((pass + 1)); fi

# 3. A syntax error must be rejected.
printf 'core.workflow(\n' > "$TMP/broken.sky"
if bash "$GUARD" "$TMP/broken.sky" >/dev/null 2>&1; then fail=$((fail + 1)); echo "FAIL: unparseable config was accepted" >&2; else pass=$((pass + 1)); fi

# 4. A missing file must be rejected.
if bash "$GUARD" "$TMP/absent.sky" >/dev/null 2>&1; then fail=$((fail + 1)); echo "FAIL: missing config was accepted" >&2; else pass=$((pass + 1)); fi

echo "validate-config.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
