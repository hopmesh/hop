#!/usr/bin/env bash
# Self-test for tools/check-icon-bounds.py, per tools/CLAUDE.md: a guard change ships with the
# case that would have caught the gap, in the same commit.
#
# The case that matters is the one that shipped: assets/fa-icons/comments.svg declared
# viewBox="0 0 576 512" while its artwork spans y -32..544, so every derived asset cropped the
# glyph and the "Chats" tab bubble was visibly cut off on a real phone. Six other sources had
# the same defect. Nothing gated it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/check-icon-bounds.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { printf '  %-62s OK\n' "$1"; }
bad() { printf '  %-62s FAIL\n' "$1"; fail=1; }

# A square glyph that sits inside its box: must PASS.
cat > "$TMP/good.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><path fill="currentColor" d="M128 128L384 128L384 384L128 384Z"/></svg>
SVG
python3 "$GUARD" "$TMP/good.svg" >/dev/null 2>&1 && ok "a glyph inside its viewBox passes" \
  || bad "a glyph inside its viewBox passes"

# The real defect: art above and below the declared box. Must FAIL.
cat > "$TMP/overflow.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 576 512"><path fill="currentColor" d="M0 -32L576 -32L576 544L0 544Z"/></svg>
SVG
python3 "$GUARD" "$TMP/overflow.svg" >/dev/null 2>&1 && bad "vertical overflow is caught" \
  || ok "vertical overflow is caught"

# Horizontal overflow, the bluetooth-b shape of the bug. Must FAIL.
cat > "$TMP/wide.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 512"><path fill="currentColor" d="M-7 0L263 0L263 512L-7 512Z"/></svg>
SVG
python3 "$GUARD" "$TMP/wide.svg" >/dev/null 2>&1 && bad "horizontal overflow is caught" \
  || ok "horizontal overflow is caught"

# Bezier control points sit OUTSIDE the curve they draw. A guard that took control points as the
# bound would report a false positive here, so this pins that it solves the curve instead.
# Control points at y=-10 are outside the box, but for p0=p3=50 the curve's extremum is
# 12.5 + 0.75 * (-10) = 5, comfortably inside. (An earlier draft of this case used y=-40, whose
# curve really does reach y=-17.5, and the guard was right to reject it.)
cat > "$TMP/bezier.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path fill="currentColor" d="M10 50 C10 -10 90 -10 90 50 Z"/></svg>
SVG
python3 "$GUARD" "$TMP/bezier.svg" >/dev/null 2>&1 \
  && ok "a curve inside the box passes though its control points are outside" \
  || bad "a curve inside the box passes though its control points are outside"

# A curve that genuinely leaves the box must still FAIL, so the bezier handling above is not
# just permissiveness.
cat > "$TMP/bezier_out.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path fill="currentColor" d="M10 50 C10 -200 90 -200 90 50 Z"/></svg>
SVG
python3 "$GUARD" "$TMP/bezier_out.svg" >/dev/null 2>&1 && bad "a curve leaving the box is caught" \
  || ok "a curve leaving the box is caught"

# The guard must fail LOUDLY on a file it cannot parse rather than passing vacuously.
printf '<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0L10 10Z"/></svg>\n' > "$TMP/noviewbox.svg"
python3 "$GUARD" "$TMP/noviewbox.svg" >/dev/null 2>&1 && bad "a missing viewBox fails closed" \
  || ok "a missing viewBox fails closed"

# The real tree must be clean, so the guard is armed against regressions rather than aspirational.
python3 "$GUARD" "$HERE/../assets/fa-icons" >/dev/null 2>&1 \
  && ok "assets/fa-icons is clean at HEAD" || bad "assets/fa-icons is clean at HEAD"

[ "$fail" -eq 0 ] && echo "check-icon-bounds.test: all cases passed" \
  || echo "check-icon-bounds.test: FAILURES above"
exit "$fail"
