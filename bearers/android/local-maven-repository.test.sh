#!/usr/bin/env bash
# Focused contract test for the local Maven receipt/verifier. No Android build or network is needed.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
helper="$root/bearers/android/local-maven-repository.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source_root="$work/source"
repository="$work/repository"

fail() {
  echo "local-maven-repository.test: $*" >&2
  exit 1
}

expect_fail() {
  local label="$1" needle="$2" output status
  shift 2
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$label unexpectedly passed"
  [[ "$output" == *"$needle"* ]] || fail "$label failed for the wrong reason: $output"
}

fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    relative = path.relative_to(root).as_posix()
    digest.update(relative.encode())
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\n")
print(digest.hexdigest())
PY
}

mkdir -p \
  "$source_root/core/hop" \
  "$source_root/core/hop-core" \
  "$source_root/sdk/android/src/main" \
  "$source_root/bearers/android/hop-sdk" \
  "$source_root/bearers/android/bearer-ble" \
  "$source_root/bearers/android/bearer-lan" \
  "$source_root/bearers/android/bearer-relay"
printf '[workspace]\n' >"$source_root/Cargo.toml"
printf '# fixture\n' >"$source_root/Cargo.lock"
printf '[toolchain]\nchannel = "stable"\n' >"$source_root/rust-toolchain.toml"
printf 'fixture core\n' >"$source_root/core/hop/lib.rs"
printf 'fixture protocol\n' >"$source_root/core/hop-core/lib.rs"
printf 'fixture header\n' >"$source_root/sdk/hop.h"
printf 'version = "0.0.5"\n' >"$source_root/sdk/android/build.gradle.kts"
printf '#!/usr/bin/env bash\n' >"$source_root/sdk/android/build-aar-dev.sh"
printf 'rootProject.name = "fixture"\n' >"$source_root/sdk/android/settings.gradle.kts"
printf 'fixture kotlin\n' >"$source_root/sdk/android/src/main/Hop.kt"
printf 'version = "0.0.2"\n' >"$source_root/bearers/android/build.gradle.kts"
printf 'hopSdkVersion=0.0.5\n' >"$source_root/bearers/android/gradle.properties"
printf 'rootProject.name = "fixture"\n' >"$source_root/bearers/android/settings.gradle.kts"
printf 'fixture shim\n' >"$source_root/bearers/android/hop-sdk/build.gradle.kts"
printf 'fixture ble\n' >"$source_root/bearers/android/bearer-ble/build.gradle.kts"
printf 'fixture lan\n' >"$source_root/bearers/android/bearer-lan/build.gradle.kts"
printf 'fixture relay\n' >"$source_root/bearers/android/bearer-relay/build.gradle.kts"
printf 'fixture verifier\n' >"$source_root/bearers/android/local-maven-repository.py"

git -C "$source_root" init -q
git -C "$source_root" add .
git -C "$source_root" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture

write_repository() {
  local mode="$1"
  rm -rf "$repository"
  python3 - "$repository" "$mode" <<'PY'
import io
import pathlib
import sys
import zipfile

repository = pathlib.Path(sys.argv[1])
mode = sys.argv[2]


def write_aar(group, artifact, version, classes, native=False):
    target = repository.joinpath(*group.split("."), artifact, version)
    target.mkdir(parents=True, exist_ok=True)
    jar_bytes = io.BytesIO()
    with zipfile.ZipFile(jar_bytes, "w") as jar:
        for name in classes:
            jar.writestr(name, b"fixture")
    with zipfile.ZipFile(target / f"{artifact}-{version}.aar", "w") as aar:
        aar.writestr("classes.jar", jar_bytes.getvalue())
        if native:
            for abi in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64"):
                aar.writestr(f"jni/{abi}/libhop.so", b"fixture native")


def pom(group, artifact, version, dependencies):
    target = repository.joinpath(*group.split("."), artifact, version)
    dependency_xml = "".join(
        "<dependency>" + "".join(f"<{key}>{value}</{key}>" for key, value in dependency.items()) + "</dependency>"
        for dependency in dependencies
    )
    (target / f"{artifact}-{version}.pom").write_text(
        "<project>"
        f"<groupId>{group}</groupId><artifactId>{artifact}</artifactId><version>{version}</version><packaging>aar</packaging>"
        f"<dependencies>{dependency_xml}</dependencies>"
        "</project>",
        encoding="utf-8",
    )

core_dep = {
    "groupId": "sh.hop", "artifactId": "hop", "version": "0.0.5", "type": "aar", "scope": "runtime",
}
jna_dep = {
    "groupId": "net.java.dev.jna", "artifactId": "jna", "version": "5.19.1", "type": "aar", "scope": "runtime",
}
write_aar("sh.hop", "hop", "0.0.5", ["sh/hop/HopNode.class"], native=True)
pom("sh.hop", "hop", "0.0.5", [jna_dep])
for artifact, class_name in (("bearer-ble", "BleBearer"), ("bearer-lan", "LanBearer"), ("bearer-relay", "RelayBearer")):
    classes = [f"sh/hopme/bearers/{artifact.removeprefix('bearer-')}/{class_name}.class"]
    if mode == "embedded-core" and artifact == "bearer-ble":
        classes.append("sh/hop/HopNode.class")
    write_aar("sh.hop.bearers", artifact, "0.0.2", classes)
    dependencies = [] if mode == "missing-core" and artifact == "bearer-ble" else [core_dep]
    pom("sh.hop.bearers", artifact, "0.0.2", dependencies)
for group, artifact in (("sh.hop", "hop"), ("sh.hop.bearers", "bearer-ble"), ("sh.hop.bearers", "bearer-lan"), ("sh.hop.bearers", "bearer-relay")):
    metadata = repository.joinpath(*group.split("."), artifact, "maven-metadata.xml")
    metadata.write_text(
        f"<metadata><groupId>{group}</groupId><artifactId>{artifact}</artifactId>"
        "<versioning><lastUpdated>20260826000000</lastUpdated></versioning></metadata>",
        encoding="utf-8",
    )
    metadata.with_name(metadata.name + ".md5").write_text("stale", encoding="ascii")
    metadata.with_name(metadata.name + ".sha1").write_text("stale", encoding="ascii")
PY
  python3 "$helper" stamp --source-root "$source_root" --repository "$repository"
}

write_repository normal
python3 - "$repository" <<'PY'
import pathlib
import sys

metadata = sorted(pathlib.Path(sys.argv[1]).rglob("maven-metadata.xml"))
assert metadata, "fixture did not produce Maven metadata"
for path in metadata:
    assert "<lastUpdated>19700101000000</lastUpdated>" in path.read_text(encoding="utf-8"), path
PY
before_repository="$(fingerprint "$repository")"
before_source="$(fingerprint "$source_root")"
python3 "$helper" verify --source-root "$source_root" --repository "$repository"
[[ "$before_repository" == "$(fingerprint "$repository")" ]] || fail "verification mutated the Maven repository"
[[ "$before_source" == "$(fingerprint "$source_root")" ]] || fail "verification mutated the source tree"

write_repository missing-core
expect_fail "missing core POM derivation" "POM sh.hop:hop dependency differs" \
  python3 "$helper" verify --source-root "$source_root" --repository "$repository"

write_repository embedded-core
expect_fail "embedded core classes" "embeds sh.hop core classes" \
  python3 "$helper" verify --source-root "$source_root" --repository "$repository"

write_repository normal
printf 'tamper\n' >>"$repository/sh/hop/bearers/bearer-lan/0.0.2/bearer-lan-0.0.2.pom"
expect_fail "tampered publication checksum" "provenance digest" \
  python3 "$helper" verify --source-root "$source_root" --repository "$repository"

write_repository normal
printf '{}\n' >"$repository/sh/hop/bearers/bearer-ble/0.0.2/bearer-ble-0.0.2.module"
expect_fail "published Gradle module metadata" "published Gradle module metadata" \
  python3 "$helper" verify --source-root "$source_root" --repository "$repository"

write_repository normal
python3 - "$repository/sh/hop/hop/maven-metadata.xml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8").replace("19700101000000", "20260826000000"), encoding="utf-8")
PY
expect_fail "unnormalized Maven metadata" "Maven metadata is not normalized" \
  python3 "$helper" verify --source-root "$source_root" --repository "$repository"

printf 'hopSdkVersion=9.9.9\n' >"$source_root/bearers/android/gradle.properties"
expect_fail "mismatched core derivation" "must derive from the published sh.hop:hop version" \
  python3 "$helper" stamp --source-root "$source_root" --repository "$repository"

echo "local Maven repository verifier: valid receipt plus missing-derivation, duplicate-core, checksum, and read-only checks passed"
