#!/usr/bin/env python3
"""Stamp and verify the local Maven repository for the Hop Android core and bearers.

The dev builder writes a deterministic receipt after publication.  Verification is read-only: it
checks the receipt, SHA-256/SHA-512 sidecars, coordinates, POM graph, and nested AAR classes.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from xml.etree import ElementTree

PROVENANCE_NAME = "hop-android-dev-maven-provenance.json"
SCHEMA_VERSION = 1
CHECKSUM_SUFFIXES = (".md5", ".sha1", ".sha256", ".sha512")
MAVEN_METADATA_TIMESTAMP = "19700101000000"
BEARER_ARTIFACT_IDS = ("bearer-ble", "bearer-lan", "bearer-relay")
SOURCE_INPUTS = (
    "Cargo.toml",
    "Cargo.lock",
    "rust-toolchain.toml",
    "core/hop",
    "core/hop-core",
    "sdk/hop.h",
    "sdk/android/build.gradle.kts",
    "sdk/android/build-aar-dev.sh",
    "sdk/android/settings.gradle.kts",
    "sdk/android/src/main",
    "bearers/android/build.gradle.kts",
    "bearers/android/gradle.properties",
    "bearers/android/settings.gradle.kts",
    "bearers/android/hop-sdk/build.gradle.kts",
    "bearers/android/bearer-ble",
    "bearers/android/bearer-lan",
    "bearers/android/bearer-relay",
    "bearers/android/local-maven-repository.py",
)
IGNORED_SOURCE_DIRECTORIES = {".gradle", ".kotlin", "build", "__pycache__"}


class RepositoryError(RuntimeError):
    """A repository does not satisfy the Android artifact contract."""


@dataclass(frozen=True)
class Coordinate:
    group: str
    artifact: str
    version: str

    @property
    def display(self) -> str:
        return f"{self.group}:{self.artifact}:{self.version}"

    def directory(self, repository: Path) -> Path:
        return repository.joinpath(*self.group.split("."), self.artifact, self.version)

    def filename(self, extension: str) -> str:
        return f"{self.artifact}-{self.version}.{extension}"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RepositoryError(message)


def sha(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def direct_children(node: ElementTree.Element, name: str) -> list[ElementTree.Element]:
    return [child for child in node if child.tag.rsplit("}", 1)[-1] == name]


def child_text(node: ElementTree.Element, name: str) -> str | None:
    children = direct_children(node, name)
    require(len(children) <= 1, f"POM has more than one {name} element")
    return children[0].text.strip() if children and children[0].text else None


def read_dependencies(pom: Path) -> list[dict[str, str | None]]:
    try:
        root = ElementTree.parse(pom).getroot()
    except (ElementTree.ParseError, OSError) as error:
        raise RepositoryError(f"cannot parse POM {pom}: {error}") from error
    dependencies_nodes = direct_children(root, "dependencies")
    require(len(dependencies_nodes) == 1, f"{pom.name} must have exactly one dependencies block")
    dependencies: list[dict[str, str | None]] = []
    for dependency in direct_children(dependencies_nodes[0], "dependency"):
        dependencies.append(
            {
                key: child_text(dependency, key)
                for key in ("groupId", "artifactId", "version", "type", "scope")
            },
        )
    return dependencies


def check_pom_coordinate(pom: Path, coordinate: Coordinate) -> None:
    try:
        root = ElementTree.parse(pom).getroot()
    except (ElementTree.ParseError, OSError) as error:
        raise RepositoryError(f"cannot parse POM {pom}: {error}") from error
    actual = {
        "group": child_text(root, "groupId"),
        "artifact": child_text(root, "artifactId"),
        "version": child_text(root, "version"),
        "packaging": child_text(root, "packaging"),
    }
    expected = {
        "group": coordinate.group,
        "artifact": coordinate.artifact,
        "version": coordinate.version,
        "packaging": "aar",
    }
    require(actual == expected, f"{pom.name} coordinate or packaging differs: {actual}")


def check_classes(aar: Path, coordinate: Coordinate, is_bearer: bool) -> None:
    try:
        with zipfile.ZipFile(aar) as archive:
            aar_names = set(archive.namelist())
            require("classes.jar" in aar_names, f"{coordinate.display} AAR has no classes.jar")
            classes = archive.read("classes.jar")
            embedded_native = [
                name
                for name in aar_names
                if name.startswith("jni/") and name.endswith("/libhop.so")
            ]
    except (OSError, zipfile.BadZipFile, KeyError) as error:
        raise RepositoryError(f"cannot inspect AAR {aar}: {error}") from error
    try:
        with zipfile.ZipFile(io.BytesIO(classes)) as jar:
            names = jar.namelist()
    except zipfile.BadZipFile as error:
        raise RepositoryError(f"{coordinate.display} classes.jar is not a valid JAR: {error}") from error
    core_classes = sorted(name for name in names if name.startswith("sh/hop/") and name.endswith(".class"))
    if is_bearer:
        require(
            not core_classes,
            f"{coordinate.display} embeds sh.hop core classes: {', '.join(core_classes)}",
        )
        require(
            not embedded_native,
            f"{coordinate.display} embeds libhop native slices: {', '.join(sorted(embedded_native))}",
        )
    else:
        require(core_classes, f"{coordinate.display} AAR has no sh.hop core classes")
        missing = [
            abi
            for abi in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
            if f"jni/{abi}/libhop.so" not in aar_names
        ]
        require(
            not missing,
            f"{coordinate.display} AAR is missing libhop native slices for: {', '.join(missing)}",
        )


def sidecar(path: Path, algorithm: str) -> Path:
    return path.with_name(path.name + f".{algorithm}")


def check_sidecar(path: Path, algorithm: str) -> None:
    digest_path = sidecar(path, algorithm)
    require(digest_path.is_file(), f"{path.name} is missing its {algorithm} checksum")
    actual = digest_path.read_text(encoding="utf-8").strip()
    expected = sha(path, algorithm)
    require(
        actual == expected,
        f"{path.name} {algorithm} checksum differs: expected {expected}, found {actual or '<empty>'}",
    )


def write_sidecars(path: Path) -> None:
    for algorithm in ("sha256", "sha512"):
        sidecar(path, algorithm).write_text(sha(path, algorithm) + "\n", encoding="utf-8")


def parse_declared_version(path: Path, label: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise RepositoryError(f"cannot read {label} version source {path}: {error}") from error
    matches = re.findall(r'^version = "([^"]+)"$', text, flags=re.MULTILINE)
    require(len(matches) == 1, f"{label} build file must declare exactly one literal version")
    return matches[0]


def parse_property(path: Path, key: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise RepositoryError(f"cannot read {path}: {error}") from error
    matches = re.findall(rf"^{re.escape(key)}=([^\r\n#]+)$", text, flags=re.MULTILINE)
    require(len(matches) == 1, f"{path} must declare exactly one {key}")
    value = matches[0].strip()
    require(value, f"{path} declares an empty {key}")
    return value


def plan(source_root: Path) -> tuple[Coordinate, tuple[Coordinate, ...]]:
    core_version = parse_declared_version(source_root / "sdk/android/build.gradle.kts", "core")
    bearer_version = parse_declared_version(source_root / "bearers/android/build.gradle.kts", "bearer")
    declared_core = parse_property(source_root / "bearers/android/gradle.properties", "hopSdkVersion")
    require(
        declared_core == core_version,
        "bearers/android/gradle.properties hopSdkVersion must derive from the published sh.hop:hop version "
        f"({declared_core} != {core_version})",
    )
    core = Coordinate("sh.hop", "hop", core_version)
    bearers = tuple(
        Coordinate("sh.hop.bearers", artifact, bearer_version)
        for artifact in BEARER_ARTIFACT_IDS
    )
    return core, bearers


def expected_coordinates(source_root: Path) -> tuple[Coordinate, ...]:
    core, bearers = plan(source_root)
    return (core, *bearers)


def payload_files(repository: Path) -> list[Path]:
    require(repository.is_dir(), f"Maven repository is absent: {repository}")
    payloads: list[Path] = []
    for path in sorted(repository.rglob("*")):
        relative = path.relative_to(repository)
        if path.is_symlink():
            raise RepositoryError(f"Maven repository contains a symlink: {relative}")
        if not path.is_file():
            continue
        if path.name == PROVENANCE_NAME or path.name.endswith(CHECKSUM_SUFFIXES):
            continue
        payloads.append(path)
    return payloads


def require_publication_files(repository: Path, coordinates: Iterable[Coordinate]) -> None:
    for coordinate in coordinates:
        directory = coordinate.directory(repository)
        require(directory.is_dir(), f"publication directory is absent for {coordinate.display}")
        for extension in ("aar", "pom"):
            path = directory / coordinate.filename(extension)
            require(path.is_file() and path.stat().st_size > 0, f"publication file is absent for {coordinate.display}: {path.name}")
        module = directory / coordinate.filename("module")
        require(
            not module.exists(),
            f"{coordinate.display} published Gradle module metadata; consumers would ignore the authored POM",
        )


def source_tree_digest(source_root: Path) -> str:
    digest = hashlib.sha256()
    for raw in SOURCE_INPUTS:
        start = source_root / raw
        require(start.exists(), f"provenance source input is absent: {raw}")
        candidates: Iterable[Path]
        if start.is_dir():
            candidates = sorted(path for path in start.rglob("*") if path.is_file() or path.is_symlink())
        else:
            candidates = (start,)
        for path in candidates:
            relative = path.relative_to(source_root)
            if any(part in IGNORED_SOURCE_DIRECTORIES for part in relative.parts):
                continue
            require(not path.is_symlink(), f"provenance source input is a symlink: {relative}")
            require(path.is_file(), f"provenance source input is not a file: {relative}")
            digest.update(relative.as_posix().encode("utf-8"))
            digest.update(b"\0")
            digest.update(sha(path, "sha256").encode("ascii"))
            digest.update(b"\n")
    return digest.hexdigest()


def source_commit(source_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise RepositoryError(f"cannot determine source commit: {error}") from error
    commit = result.stdout.strip()
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "source commit is not a full SHA-1")
    return commit


def provenance_for(source_root: Path, artifacts: list[Path], repository: Path) -> dict[str, object]:
    core, bearers = plan(source_root)
    return {
        "schema": SCHEMA_VERSION,
        "source": {
            "commit": source_commit(source_root),
            "input_paths": list(SOURCE_INPUTS),
            "input_tree_sha256": source_tree_digest(source_root),
        },
        "coordinates": {
            "core": core.display,
            "bearers": [bearer.display for bearer in bearers],
        },
        "artifacts": [
            {
                "path": path.relative_to(repository).as_posix(),
                "sha256": sha(path, "sha256"),
                "sha512": sha(path, "sha512"),
            }
            for path in artifacts
        ],
    }


def normalize_maven_metadata(repository: Path) -> None:
    # Gradle writes wall-clock `<lastUpdated>` values into Maven metadata. Fixed-version consumers do
    # not need that clock, and retaining it makes an otherwise identical local repository nonreproducible.
    # Gradle also writes MD5/SHA-1 sidecars, so rewrite those after changing the XML rather than leaving
    # a repository whose legacy checksums attest to bytes that no longer exist.
    for metadata in sorted(repository.rglob("maven-metadata.xml")):
        require(not metadata.is_symlink(), f"Maven metadata is a symlink: {metadata.relative_to(repository)}")
        text = metadata.read_text(encoding="utf-8")
        normalized, replacements = re.subn(
            r"<lastUpdated>[^<]*</lastUpdated>",
            f"<lastUpdated>{MAVEN_METADATA_TIMESTAMP}</lastUpdated>",
            text,
        )
        require(replacements == 1, f"Maven metadata has no unique lastUpdated element: {metadata.relative_to(repository)}")
        if normalized != text:
            metadata.write_text(normalized, encoding="utf-8")
        for algorithm in ("md5", "sha1"):
            legacy = sidecar(metadata, algorithm)
            if legacy.exists():
                require(legacy.is_file() and not legacy.is_symlink(), f"Maven metadata checksum is unsafe: {legacy.relative_to(repository)}")
                legacy.write_text(sha(metadata, algorithm), encoding="ascii")


def check_maven_metadata(repository: Path) -> None:
    for metadata in sorted(repository.rglob("maven-metadata.xml")):
        require(not metadata.is_symlink(), f"Maven metadata is a symlink: {metadata.relative_to(repository)}")
        text = metadata.read_text(encoding="utf-8")
        matches = re.findall(r"<lastUpdated>([^<]*)</lastUpdated>", text)
        require(
            matches == [MAVEN_METADATA_TIMESTAMP],
            f"Maven metadata is not normalized: {metadata.relative_to(repository)}",
        )
        for algorithm in ("md5", "sha1"):
            legacy = sidecar(metadata, algorithm)
            if legacy.exists():
                require(legacy.is_file() and not legacy.is_symlink(), f"Maven metadata checksum is unsafe: {legacy.relative_to(repository)}")
                require_exact(
                    legacy.read_text(encoding="ascii").strip(),
                    sha(metadata, algorithm),
                    f"Maven metadata {algorithm} checksum for {metadata.relative_to(repository)}",
                )


def stamp(repository: Path, source_root: Path) -> None:
    repository = repository.resolve()
    source_root = source_root.resolve()
    require_publication_files(repository, expected_coordinates(source_root))
    normalize_maven_metadata(repository)
    receipt = repository / PROVENANCE_NAME
    for path in (receipt, *(sidecar(receipt, algorithm) for algorithm in ("sha256", "sha512"))):
        path.unlink(missing_ok=True)
    for path in payload_files(repository):
        for algorithm in ("sha256", "sha512"):
            sidecar(path, algorithm).unlink(missing_ok=True)
        write_sidecars(path)
    artifacts = payload_files(repository)
    receipt.write_text(
        json.dumps(provenance_for(source_root, artifacts, repository), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_sidecars(receipt)


def require_exact(actual: object, expected: object, label: str) -> None:
    require(actual == expected, f"{label} differs: expected {expected!r}, found {actual!r}")


def verify(repository: Path, source_root: Path | None) -> None:
    repository = repository.resolve()
    receipt_path = repository / PROVENANCE_NAME
    require(receipt_path.is_file(), f"Maven repository is missing {PROVENANCE_NAME}")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RepositoryError(f"cannot read {PROVENANCE_NAME}: {error}") from error
    require(isinstance(receipt, dict), f"{PROVENANCE_NAME} must be an object")
    require_exact(receipt.get("schema"), SCHEMA_VERSION, "provenance schema")
    source = receipt.get("source")
    require(isinstance(source, dict), "provenance source is absent")
    for key in ("commit", "input_paths", "input_tree_sha256"):
        require(key in source, f"provenance source is missing {key}")
    require_exact(source.get("input_paths"), list(SOURCE_INPUTS), "provenance source inputs")
    require(re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit"))) is not None, "provenance commit is malformed")
    require(re.fullmatch(r"[0-9a-f]{64}", str(source.get("input_tree_sha256"))) is not None, "provenance source digest is malformed")

    if source_root is not None:
        source_root = source_root.resolve()
        core, bearers = plan(source_root)
        require_exact(
            receipt.get("coordinates"),
            {"core": core.display, "bearers": [bearer.display for bearer in bearers]},
            "provenance coordinates",
        )
        require_exact(source.get("commit"), source_commit(source_root), "provenance source commit")
        require_exact(source.get("input_tree_sha256"), source_tree_digest(source_root), "provenance source tree digest")
        coordinates = (core, *bearers)
    else:
        coordinates_data = receipt.get("coordinates")
        require(isinstance(coordinates_data, dict), "provenance coordinates are absent")
        core_parts = str(coordinates_data.get("core", "")).split(":")
        bearer_parts = coordinates_data.get("bearers")
        require(
            len(core_parts) == 3 and isinstance(bearer_parts, list) and len(bearer_parts) == len(BEARER_ARTIFACT_IDS),
            "provenance coordinates are malformed",
        )
        require(
            all(len(str(value).split(":")) == 3 for value in bearer_parts),
            "provenance bearer coordinates are malformed",
        )
        bearer_coordinates = tuple(Coordinate(*str(value).split(":")) for value in bearer_parts)
        core = Coordinate(*core_parts)
        require(
            core.group == "sh.hop" and core.artifact == "hop" and core.version,
            "provenance core coordinate is not sh.hop:hop",
        )
        require(
            [(bearer.group, bearer.artifact) for bearer in bearer_coordinates]
            == [("sh.hop.bearers", artifact) for artifact in BEARER_ARTIFACT_IDS]
            and all(bearer.version for bearer in bearer_coordinates),
            "provenance bearer coordinates do not match the required BLE, LAN, and Relay artifacts",
        )
        coordinates = (core, *bearer_coordinates)

    require_publication_files(repository, coordinates)
    check_maven_metadata(repository)
    artifacts = receipt.get("artifacts")
    require(isinstance(artifacts, list) and artifacts, "provenance artifact list is absent")
    recorded: dict[str, dict[str, str]] = {}
    for entry in artifacts:
        require(isinstance(entry, dict), "provenance artifact entry is malformed")
        relative = entry.get("path")
        digest256 = entry.get("sha256")
        digest512 = entry.get("sha512")
        require(isinstance(relative, str) and relative and not Path(relative).is_absolute() and ".." not in Path(relative).parts, "provenance artifact path is unsafe")
        require(isinstance(digest256, str) and re.fullmatch(r"[0-9a-f]{64}", digest256) is not None, "provenance SHA-256 is malformed")
        require(isinstance(digest512, str) and re.fullmatch(r"[0-9a-f]{128}", digest512) is not None, "provenance SHA-512 is malformed")
        require(relative not in recorded, f"provenance lists {relative} more than once")
        recorded[relative] = {"sha256": digest256, "sha512": digest512}

    actual_payloads = payload_files(repository)
    actual_relative = [path.relative_to(repository).as_posix() for path in actual_payloads]
    require_exact(actual_relative, sorted(recorded), "Maven repository payload inventory")
    for path in actual_payloads:
        relative = path.relative_to(repository).as_posix()
        entry = recorded[relative]
        for algorithm in ("sha256", "sha512"):
            require_exact(sha(path, algorithm), entry[algorithm], f"provenance digest for {relative}")
            check_sidecar(path, algorithm)
    for algorithm in ("sha256", "sha512"):
        check_sidecar(receipt_path, algorithm)
    core, *bearers = coordinates
    core_pom = core.directory(repository) / core.filename("pom")
    check_pom_coordinate(core_pom, core)
    require_exact(
        read_dependencies(core_pom),
        [{"groupId": "net.java.dev.jna", "artifactId": "jna", "version": "5.19.1", "type": "aar", "scope": "runtime"}],
        f"{core.display} POM dependency graph",
    )
    check_classes(core.directory(repository) / core.filename("aar"), core, is_bearer=False)

    expected_bearer_dependency = {
        "groupId": core.group,
        "artifactId": core.artifact,
        "version": core.version,
        "type": "aar",
        "scope": "runtime",
    }
    for bearer in bearers:
        pom = bearer.directory(repository) / bearer.filename("pom")
        check_pom_coordinate(pom, bearer)
        dependencies = read_dependencies(pom)
        core_dependencies = [
            dependency
            for dependency in dependencies
            if dependency["groupId"] == core.group and dependency["artifactId"] == core.artifact
        ]
        require_exact(
            core_dependencies,
            [expected_bearer_dependency],
            f"{bearer.display} POM sh.hop:hop dependency",
        )
        require(
            all(
                dependency["groupId"] and dependency["artifactId"] and dependency["version"]
                for dependency in dependencies
            ),
            f"{bearer.display} POM contains a dependency without a Maven coordinate",
        )
        unexpected_hop_dependencies = [
            dependency
            for dependency in dependencies
            if dependency["groupId"] == core.group and dependency != expected_bearer_dependency
        ]
        require(
            not unexpected_hop_dependencies,
            f"{bearer.display} POM has unexpected sh.hop dependencies: {unexpected_hop_dependencies}",
        )
        leaked_shims = [
            dependency
            for dependency in dependencies
            if dependency["artifactId"] == "hop-sdk" or dependency["groupId"] == "HopBearersAndroid"
        ]
        require(
            not leaked_shims,
            f"{bearer.display} POM leaks in-tree hop-sdk dependencies: {leaked_shims}",
        )
        check_classes(bearer.directory(repository) / bearer.filename("aar"), bearer, is_bearer=True)


def command_versions(args: argparse.Namespace) -> None:
    core, bearers = plan(Path(args.source_root))
    print(core.version)
    print(bearers[0].version)


def command_stamp(args: argparse.Namespace) -> None:
    stamp(Path(args.repository), Path(args.source_root))


def command_verify(args: argparse.Namespace) -> None:
    verify(Path(args.repository), Path(args.source_root) if args.source_root else None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    versions_parser = subcommands.add_parser("versions", help="print the core and bearer versions")
    versions_parser.add_argument("--source-root", required=True)
    versions_parser.set_defaults(func=command_versions)
    stamp_parser = subcommands.add_parser("stamp", help="write checksums and a deterministic provenance receipt")
    stamp_parser.add_argument("--source-root", required=True)
    stamp_parser.add_argument("--repository", required=True)
    stamp_parser.set_defaults(func=command_stamp)
    verify_parser = subcommands.add_parser("verify", help="read-only repository verification")
    verify_parser.add_argument("--repository", required=True)
    verify_parser.add_argument("--source-root")
    verify_parser.set_defaults(func=command_verify)
    args = parser.parse_args()
    try:
        args.func(args)
    except RepositoryError as error:
        print(f"local-maven-repository: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
