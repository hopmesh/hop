#!/usr/bin/env bash
# Build, test, and publish the AAR to a clean Maven repository from signed native target archives.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "${JAVA_HOME:-}" && -x /opt/homebrew/opt/openjdk@17/bin/java ]]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17
  export PATH="$JAVA_HOME/bin:$PATH"
fi
bundle=""
repository=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) bundle="${2:?missing bundle path}"; shift 2 ;;
    --repository) repository="${2:?missing repository path}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
test -n "$bundle" || { echo "--bundle is required" >&2; exit 2; }
test -n "$repository" || { echo "--repository is required" >&2; exit 2; }
bundle="$(cd "$bundle" && pwd)"
mkdir -p "$(dirname "$repository")"
repository="$(cd "$(dirname "$repository")" && pwd)/$(basename "$repository")"
test ! -e "$repository" || { echo "Maven repository must not already exist: $repository" >&2; exit 1; }
version="$(python3 -c 'import re; print(re.search(r"^version = \"([^\"]+)\"$", open("build.gradle.kts").read(), re.M).group(1))')"

manifest="$bundle/native-artifacts.json"
signature="$bundle/native-artifacts.json.sig"
public_key="$here/native/native-artifacts-public.pem"
helper="$here/native/native-artifacts.py"
native="$here/build/native-android"
rm -rf "$native" "$here/build/native-staging"
mkdir -p "$native"

targets=(
  "arm64-v8a=aarch64-linux-android"
  "armeabi-v7a=armv7-linux-androideabi"
  "x86=i686-linux-android"
  "x86_64=x86_64-linux-android"
)
reference_header=""
for mapping in "${targets[@]}"; do
  abi="${mapping%%=*}"
  target="${mapping#*=}"
  extracted="$here/build/native-staging/$target"
  python3 "$helper" extract \
    --manifest "$manifest" --signature "$signature" --public-key "$public_key" \
    --directory "$bundle" --target "$target" --destination "$extracted"
  test -f "$extracted/lib/libhop.so" || { echo "$target archive omitted lib/libhop.so" >&2; exit 1; }
  test -f "$extracted/include/hop.h" || { echo "$target archive omitted include/hop.h" >&2; exit 1; }
  mkdir -p "$native/$abi"
  cp "$extracted/lib/libhop.so" "$native/$abi/libhop.so"
  if [[ -z "$reference_header" ]]; then
    reference_header="$extracted/include/hop.h"
  else
    cmp "$reference_header" "$extracted/include/hop.h"
  fi
done
cmp "$reference_header" "$here/include/hop.h"

cd "$here"
gradle test hopAar publishHopPublicationToHopRepository \
  -PhopNativeDir="$native" -PhopMavenRepository="$repository" --no-daemon

python3 - "$repository" "$version" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
release = sys.argv[2]
version = root / "sh/hop/hop" / release
required = [
    version / f"hop-{release}.aar",
    version / f"hop-{release}-sources.jar",
    version / f"hop-{release}-javadoc.jar",
    version / f"hop-{release}.pom",
]
for path in required:
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"publication file is missing: {path}")
for path in list(version.iterdir()):
    if path.is_file() and not path.name.endswith((".sha256", ".sha512")):
        payload = path.read_bytes()
        path.with_name(path.name + ".sha256").write_text(hashlib.sha256(payload).hexdigest() + "\n")
        path.with_name(path.name + ".sha512").write_text(hashlib.sha512(payload).hexdigest() + "\n")
pom = (version / f"hop-{release}.pom").read_text()
for marker in ("<packaging>aar</packaging>", "<artifactId>jna</artifactId>", "<type>aar</type>"):
    if marker not in pom:
        raise SystemExit(f"POM is missing {marker}")
print(f"published clean Maven repository: {version}")
PY
