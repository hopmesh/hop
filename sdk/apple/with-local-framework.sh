#!/usr/bin/env bash
# Run one SwiftPM command against the generated local xcframework without changing Package.swift on exit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
test -d "$here/Frameworks/libhop.xcframework" || {
  echo "missing verified Frameworks/libhop.xcframework; run build-xcframework.sh first" >&2
  exit 1
}
backup="$(mktemp "${TMPDIR:-/tmp}/hop-package.XXXXXX")"
cp "$here/Package.swift" "$backup"
restore() {
  cp "$backup" "$here/Package.swift"
  rm -f "$backup"
}
trap restore EXIT
cp "$here/Package.local.swift" "$here/Package.swift"
cd "$here"
"$@"
