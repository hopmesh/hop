#!/usr/bin/env bash
# Build+run the Swift smokes against libhop via the libhop.xcframework binary target. The xcframework
# carries the static lib, so swift links it automatically — no -L/-l flags. Proves the Swift wrapper
# (and HopRuntime + a Bearer) drive the C ABI.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Ensure the xcframework exists (first run / after editing cabi.rs cross-compiles all slices).
[ -d "$HERE/Frameworks/libhop.xcframework" ] || "$HERE/build-xcframework.sh"

cd "$HERE"
swift run HopSmoke       # Swift wrapper -> C ABI -> protocol
swift run RuntimeSmoke   # HopRuntime + a Bearer -> node seam -> protocol
