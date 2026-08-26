#!/usr/bin/env bash
# Prove the three CocoaPods bearer specs describe the same exported contract as Package.swift.
#
# This intentionally uses `pod ipc spec`, not `pod spec lint`: the bearer mirror has not been created and
# the pods have not been published, so network resolution would test an unavailable distribution channel
# instead of the local spec metadata this package owns.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v pod >/dev/null || {
  echo "podspec test requires CocoaPods on PATH" >&2
  exit 1
}

for pod_name in HopBearerBle HopBearerLan HopBearerRelay; do
  pod ipc spec "$root/$pod_name.podspec" >"$tmp/$pod_name.json"
done

python3 - "$root/Package.swift" "$tmp" <<'PY'
import json
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2])
manifest = manifest_path.read_text(encoding="utf-8")
url = "https://github.com/hopmesh/hop-sdk-apple.git"
matches = re.findall(
    r'\.package\(\s*url:\s*"' + re.escape(url) + r'"\s*,\s*from:\s*"([^"]+)"\s*\)',
    manifest,
    re.S,
)
if len(matches) != 1:
    raise SystemExit(
        f"test setup: expected one Hop SDK compatibility declaration in {manifest_path}, found {len(matches)}"
    )

version = matches[0]
semver = re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version)
if semver is None:
    raise SystemExit(f"test setup: manifest contains an invalid SDK version {version!r}")

expected_dependency = [f">= {version}", f"< {int(semver.group(1)) + 1}.0.0"]
expected_specs = {
    "HopBearerBle": {
        "source_files": "HopBearerBle/Sources/HopBearerBle/**/*.swift",
        "frameworks": {"Foundation", "CoreBluetooth", "Security"},
        "ios_frameworks": {"CoreLocation", "UIKit"},
    },
    "HopBearerLan": {
        "source_files": "HopBearerLan/Sources/HopBearerLan/**/*.swift",
        "frameworks": {"Foundation", "Network"},
        "ios_frameworks": set(),
    },
    "HopBearerRelay": {
        "source_files": "HopBearerRelay/Sources/HopBearerRelay/**/*.swift",
        "frameworks": {"Foundation", "Network", "CryptoKit"},
        "ios_frameworks": set(),
    },
}

archive_names = []
for name, expected in expected_specs.items():
    spec = json.loads((tmp / f"{name}.json").read_text(encoding="utf-8"))

    def require(actual, wanted, field):
        if actual != wanted:
            raise SystemExit(f"{name}: {field} is {actual!r}, expected {wanted!r}")

    require(spec.get("name"), name, "name")
    require(spec.get("module_name"), name, "module_name")
    require(spec.get("version"), version, "version derived from Package.swift")
    require(spec.get("platforms", {}).get("ios"), "16.0", "iOS deployment floor")
    require(spec.get("platforms", {}).get("osx"), "13.0", "macOS deployment floor")
    require(spec.get("source_files"), expected["source_files"], "target-specific source glob")
    require(spec.get("swift_version"), "5.9", "Swift version")
    require(spec.get("source", {}).get("git"), "https://github.com/hopmesh/hop-bearers-apple.git", "source repository")
    require(spec.get("source", {}).get("tag"), f"v{version}", "source tag")
    require(set(spec.get("dependencies", {})), {"HopContract"}, "Hop dependencies")
    require(spec["dependencies"]["HopContract"], expected_dependency, "HopContract compatibility")
    require(set(spec.get("frameworks", [])), expected["frameworks"], "common system frameworks")
    require(set(spec.get("ios", {}).get("frameworks", [])), expected["ios_frameworks"], "iOS-only frameworks")

    for xcconfig_key in ("pod_target_xcconfig", "user_target_xcconfig"):
        xcconfig = spec.get(xcconfig_key, {})
        if "OTHER_LDFLAGS" in xcconfig:
            raise SystemExit(f"{name}: manual linker flags leaked into {xcconfig_key}")

    archive_names.append(f"lib{name}.a")

# CocoaPods archives use the pod name. Keep every native bearer distinct from each other and from CHop's
# libhop.a after case-folding, because default macOS volumes case-fold library file names during -l lookup.
all_archives = archive_names + ["libhop.a", "libHopSDK.a", "libHopContract.a"]
if len({archive.lower() for archive in all_archives}) != len(all_archives):
    raise SystemExit(f"case-colliding CocoaPods archive names: {all_archives!r}")

print("Apple bearer podspecs evaluate with target-only sources, HopContract-only dependencies, and unique archives")
PY

make_fixture() {
  local fixture="$1"
  local mutation="$2"
  cp -R "$root" "$fixture"
  python3 - "$fixture/Package.swift" "$mutation" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
mutation = sys.argv[2]
text = path.read_text(encoding="utf-8")
url = "https://github.com/hopmesh/hop-sdk-apple.git"
pattern = r'(\.package\(\s*url:\s*"' + re.escape(url) + r'"\s*,\s*from:\s*)"[^"]+"'
if mutation == "valid-version":
    replacement = r'\1"1.2.3"'
elif mutation == "invalid-version":
    replacement = r'\1"not-a-semver"'
elif mutation == "missing-sdk":
    text, count = re.subn(
        r'(url:\s*")' + re.escape(url) + r'(")',
        r'\1https://example.invalid/not-hop-sdk.git\2',
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit("fixture setup: Hop SDK URL was not replaced")
    path.write_text(text, encoding="utf-8")
    raise SystemExit(0)
else:
    raise SystemExit(f"fixture setup: unknown mutation {mutation}")

text, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
if count != 1:
    raise SystemExit("fixture setup: Hop SDK dependency was not replaced")
path.write_text(text, encoding="utf-8")
PY
}

make_fixture "$tmp/valid-version" "valid-version"
pod ipc spec "$tmp/valid-version/HopBearerBle.podspec" >"$tmp/valid-version.json"
python3 - "$tmp/valid-version.json" <<'PY'
import json
import pathlib
import sys

spec = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if spec.get("version") != "1.2.3":
    raise SystemExit(f"valid derivation used version {spec.get('version')!r}, expected '1.2.3'")
if spec.get("source", {}).get("tag") != "v1.2.3":
    raise SystemExit("valid derivation did not update the source tag")
if spec.get("dependencies", {}).get("HopContract") != [">= 1.2.3", "< 2.0.0"]:
    raise SystemExit("valid derivation did not update HopContract compatibility")
PY
echo "ok [valid-version]"

expect_derivation_failure() {
  local label="$1"
  local needle="$2"
  local fixture="$tmp/$label"
  make_fixture "$fixture" "$label"
  if pod ipc spec "$fixture/HopBearerBle.podspec" >"$tmp/$label.out" 2>&1; then
    echo "$label: pod ipc spec unexpectedly accepted malformed derivation" >&2
    exit 1
  fi
  if ! python3 - "$tmp/$label.out" "$needle" <<'PY'
import pathlib
import sys

if sys.argv[2] not in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"):
    raise SystemExit(f"missing expected failure text: {sys.argv[2]}")
PY
  then
    echo "$label: malformed derivation failed for the wrong reason" >&2
    exit 1
  fi
  echo "ok [$label]"
}

expect_derivation_failure "invalid-version" "HopBearerPodspecSupport: invalid Hop SDK minimum version \"not-a-semver\""
expect_derivation_failure "missing-sdk" "HopBearerPodspecSupport: expected exactly one Hop SDK minimum version"

echo "Apple bearer podspec tests passed"
