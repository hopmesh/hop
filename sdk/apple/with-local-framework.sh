#!/usr/bin/env bash
# Run one SwiftPM command against the generated local xcframework without changing Package.swift on exit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$here/Frameworks/libhop.xcframework" ]; then
  export PATH="$HOME/.cargo/bin:$PATH"
  HOP_SQLCIPHER=1 "$here/build-xcframework.sh"
fi
backup="$(mktemp "${TMPDIR:-/tmp}/hop-package.XXXXXX")"
cp "$here/Package.swift" "$backup"
restore() {
  cp "$backup" "$here/Package.swift"
  rm -f "$backup"
}
trap restore EXIT
cp "$here/Package.local.swift" "$here/Package.swift"
args=()
skip=0
for a in "$@"; do
  if [ "$skip" = "1" ]; then
    skip=0
    if [ "$a" != "sdk/apple" ] && [ "$a" != "." ]; then
      args+=("--package-path" "$a")
    fi
  elif [ "$a" = "--package-path" ]; then
    skip=1
  else
    args+=("$a")
  fi
done
cd "$here"
"${args[@]}"
