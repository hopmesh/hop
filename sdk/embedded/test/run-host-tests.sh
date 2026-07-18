#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${TMPDIR:-/tmp}/hop-embedded-host-test"
CXX="${CXX:-clang++}"

trap 'rm -f "$OUT"' EXIT

"$CXX" \
  -std=c++11 \
  -Wall \
  -Wextra \
  -Wpedantic \
  -Werror \
  -I "$HERE/../src" \
  "$HERE/../src/Hop.cpp" \
  "$HERE/fixed_width_test.cpp" \
  -o "$OUT"

"$OUT"
