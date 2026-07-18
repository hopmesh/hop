#!/usr/bin/env python3
"""Create, verify, download, and safely extract Hop native release artifacts."""

import argparse
import gzip
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


SCHEMA = "https://hopme.sh/schemas/native-artifacts-v1.json"
CANONICAL_REPOSITORY = "https://github.com/hopmesh/monorepo"
CANONICAL_GITHUB_REPOSITORY = "hopmesh/monorepo"
NATIVE_WORKFLOW = ".github/workflows/native-artifacts.yml"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
TAG_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+-]*$")
FILENAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*\.(?:tar\.gz|zip)$")
MAX_FILES = 20_000
MAX_EXPANDED_BYTES = 4 * 1024 * 1024 * 1024


class ArtifactError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ArtifactError(message)


def exact_keys(value, expected, label):
    require(isinstance(value, dict), f"{label} must be an object")
    actual = set(value)
    expected = set(expected)
    require(actual == expected, f"{label} fields differ: missing={sorted(expected - actual)} extra={sorted(actual - expected)}")


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(raw, label="archive path"):
    require(isinstance(raw, str) and raw, f"{label} is empty")
    require("\\" not in raw and "\x00" not in raw, f"{label} is malformed: {raw!r}")
    path = PurePosixPath(raw)
    require(not path.is_absolute(), f"{label} is absolute: {raw!r}")
    require(all(part not in ("", ".", "..") for part in path.parts), f"{label} traverses its root: {raw!r}")
    require(path.as_posix() == raw, f"{label} is not normalized: {raw!r}")
    return path


def file_mode(mode):
    return "0755" if mode & 0o111 else "0644"


def archive_entries(path, expected_format=None):
    path = Path(path)
    archive_format = "tar.gz" if path.name.endswith(".tar.gz") else "zip" if path.suffix == ".zip" else None
    require(archive_format is not None, f"unsupported archive extension: {path.name}")
    if expected_format:
        require(archive_format == expected_format, f"archive format mismatch for {path.name}")
    entries = []
    seen = set()
    expanded = 0
    if archive_format == "tar.gz":
        try:
            source = tarfile.open(path, "r:gz")
        except (tarfile.TarError, OSError) as error:
            raise ArtifactError(f"invalid tar archive {path.name}: {error}") from error
        with source:
            members = source.getmembers()
            require(len(members) <= MAX_FILES, f"archive has too many entries: {path.name}")
            for member in members:
                require(member.isfile(), f"archive contains a non-file entry: {member.name!r}")
                relative = safe_relative(member.name)
                require(relative.as_posix() not in seen, f"archive contains a duplicate path: {member.name!r}")
                seen.add(relative.as_posix())
                expanded += member.size
                require(expanded <= MAX_EXPANDED_BYTES, f"archive expands beyond the size limit: {path.name}")
                extracted = source.extractfile(member)
                require(extracted is not None, f"archive member cannot be read: {member.name!r}")
                payload = extracted.read()
                require(len(payload) == member.size, f"archive member size changed while reading: {member.name!r}")
                entries.append(
                    {
                        "path": relative.as_posix(),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size": len(payload),
                        "mode": file_mode(member.mode),
                    }
                )
    else:
        try:
            source = zipfile.ZipFile(path)
        except (zipfile.BadZipFile, OSError) as error:
            raise ArtifactError(f"invalid zip archive {path.name}: {error}") from error
        with source:
            infos = source.infolist()
            require(len(infos) <= MAX_FILES, f"archive has too many entries: {path.name}")
            for info in infos:
                require(not info.is_dir(), f"archive contains a directory entry: {info.filename!r}")
                mode = (info.external_attr >> 16) & 0o777777
                require(not stat.S_ISLNK(mode), f"archive contains a symlink: {info.filename!r}")
                relative = safe_relative(info.filename)
                require(relative.as_posix() not in seen, f"archive contains a duplicate path: {info.filename!r}")
                seen.add(relative.as_posix())
                expanded += info.file_size
                require(expanded <= MAX_EXPANDED_BYTES, f"archive expands beyond the size limit: {path.name}")
                payload = source.read(info)
                require(len(payload) == info.file_size, f"archive member size changed while reading: {info.filename!r}")
                entries.append(
                    {
                        "path": relative.as_posix(),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size": len(payload),
                        "mode": file_mode(mode),
                    }
                )
    entries.sort(key=lambda item: item["path"])
    require(entries, f"archive is empty: {path.name}")
    return archive_format, entries


def validate_manifest(value):
    exact_keys(value, ("schema", "version", "tag", "repository", "source_sha", "builder", "artifacts"), "manifest")
    require(value["schema"] == SCHEMA, "manifest schema is unsupported")
    require(isinstance(value["version"], str) and VERSION_RE.fullmatch(value["version"]), "manifest version is invalid")
    require(value["tag"] == "v" + value["version"] and TAG_RE.fullmatch(value["tag"]), "manifest tag does not match version")
    require(value["repository"] == CANONICAL_REPOSITORY, "manifest repository is not canonical")
    require(isinstance(value["source_sha"], str) and SHA_RE.fullmatch(value["source_sha"]), "manifest source SHA is invalid")
    builder = value["builder"]
    exact_keys(builder, ("repository", "workflow", "run_id", "run_attempt", "identity"), "builder")
    require(builder["repository"] == CANONICAL_GITHUB_REPOSITORY, "builder repository is not canonical")
    require(builder["workflow"] == NATIVE_WORKFLOW, "builder workflow is not canonical")
    require(isinstance(builder["run_id"], int) and builder["run_id"] > 0, "builder run ID is invalid")
    require(isinstance(builder["run_attempt"], int) and builder["run_attempt"] > 0, "builder run attempt is invalid")
    expected_identity = f"https://github.com/{CANONICAL_GITHUB_REPOSITORY}/actions/runs/{builder['run_id']}"
    require(builder["identity"] == expected_identity, "builder identity does not match run ID")
    artifacts = value["artifacts"]
    require(isinstance(artifacts, list) and artifacts, "manifest artifacts are empty")
    targets = set()
    filenames = set()
    for index, artifact in enumerate(artifacts):
        label = f"artifact[{index}]"
        exact_keys(artifact, ("target", "filename", "sha256", "size", "archive"), label)
        require(isinstance(artifact["target"], str) and TARGET_RE.fullmatch(artifact["target"]), f"{label} target is invalid")
        require(artifact["target"] not in targets, f"duplicate artifact target: {artifact['target']}")
        targets.add(artifact["target"])
        require(isinstance(artifact["filename"], str) and FILENAME_RE.fullmatch(artifact["filename"]), f"{label} filename is invalid")
        require(artifact["filename"] not in filenames, f"duplicate artifact filename: {artifact['filename']}")
        filenames.add(artifact["filename"])
        require(isinstance(artifact["sha256"], str) and SHA256_RE.fullmatch(artifact["sha256"]), f"{label} SHA-256 is invalid")
        require(isinstance(artifact["size"], int) and artifact["size"] > 0, f"{label} size is invalid")
        archive = artifact["archive"]
        exact_keys(archive, ("format", "files"), f"{label}.archive")
        require(archive["format"] in ("tar.gz", "zip"), f"{label} archive format is invalid")
        require(artifact["filename"].endswith("." + archive["format"]), f"{label} extension does not match archive format")
        require(isinstance(archive["files"], list) and archive["files"], f"{label} archive file list is empty")
        paths = set()
        for file_index, entry in enumerate(archive["files"]):
            entry_label = f"{label}.archive.files[{file_index}]"
            exact_keys(entry, ("path", "sha256", "size", "mode"), entry_label)
            relative = safe_relative(entry["path"], entry_label + ".path").as_posix()
            require(relative not in paths, f"duplicate archive member in manifest: {relative}")
            paths.add(relative)
            require(isinstance(entry["sha256"], str) and SHA256_RE.fullmatch(entry["sha256"]), f"{entry_label} SHA-256 is invalid")
            require(isinstance(entry["size"], int) and entry["size"] >= 0, f"{entry_label} size is invalid")
            require(entry["mode"] in ("0644", "0755"), f"{entry_label} mode is invalid")
    return value


def load_manifest(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ArtifactError(f"manifest cannot be loaded: {error}") from error
    return validate_manifest(value)


def verify_signature(manifest, signature, public_key):
    manifest = Path(manifest)
    signature = Path(signature)
    public_key = Path(public_key)
    require(signature.is_file() and signature.stat().st_size > 0, "detached manifest signature is missing")
    require(public_key.is_file() and public_key.stat().st_size > 0, "trusted manifest public key is missing")
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-verify", str(public_key), "-signature", str(signature), str(manifest)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    require(result.returncode == 0, "manifest signature is invalid")


def select_artifact(manifest, target):
    matches = [artifact for artifact in manifest["artifacts"] if artifact["target"] == target]
    require(len(matches) == 1, f"target must resolve to exactly one artifact: {target!r}")
    return matches[0]


def verify_artifact(artifact, directory):
    path = Path(directory) / artifact["filename"]
    require(path.is_file() and not path.is_symlink(), f"artifact is missing: {artifact['filename']}")
    require(path.stat().st_size == artifact["size"], f"artifact size mismatch: {artifact['filename']}")
    require(digest_file(path) == artifact["sha256"], f"artifact SHA-256 mismatch: {artifact['filename']}")
    archive_format, entries = archive_entries(path, artifact["archive"]["format"])
    require(archive_format == artifact["archive"]["format"], f"artifact archive format mismatch: {artifact['filename']}")
    require(entries == artifact["archive"]["files"], f"artifact archive contents mismatch: {artifact['filename']}")
    return path


def verify_release(
    manifest_path,
    signature,
    public_key,
    directory,
    target=None,
    strict=False,
    expected_source_sha=None,
    expected_tag=None,
    expected_run_id=None,
    expected_run_attempt=None,
):
    verify_signature(manifest_path, signature, public_key)
    manifest = load_manifest(manifest_path)
    if expected_source_sha is not None:
        require(manifest["source_sha"] == expected_source_sha, "manifest source SHA is not the authorized source")
    if expected_tag is not None:
        require(manifest["tag"] == expected_tag, "manifest tag is not the requested release")
    if expected_run_id is not None:
        require(manifest["builder"]["run_id"] == expected_run_id, "manifest builder run ID is not the downloaded run")
    if expected_run_attempt is not None:
        require(
            manifest["builder"]["run_attempt"] == expected_run_attempt,
            "manifest builder run attempt is not the downloaded attempt",
        )
    artifacts = [select_artifact(manifest, target)] if target else manifest["artifacts"]
    for artifact in artifacts:
        verify_artifact(artifact, directory)
    if strict:
        expected = {artifact["filename"] for artifact in manifest["artifacts"]}
        expected.update({Path(manifest_path).name, Path(signature).name})
        actual = {path.name for path in Path(directory).iterdir() if path.is_file()}
        require(actual == expected, f"release bundle files differ: missing={sorted(expected - actual)} extra={sorted(actual - expected)}")
    return manifest


def safe_extract(archive, destination):
    archive = Path(archive)
    destination = Path(destination)
    require(not destination.exists() or (destination.is_dir() and not any(destination.iterdir())), "extraction destination must be absent or empty")
    destination.mkdir(parents=True, exist_ok=True)
    archive_format, expected = archive_entries(archive)
    if archive_format == "tar.gz":
        with tarfile.open(archive, "r:gz") as source:
            members = {member.name: member for member in source.getmembers()}
            for entry in expected:
                target = destination.joinpath(*PurePosixPath(entry["path"]).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                payload = source.extractfile(members[entry["path"]]).read()
                target.write_bytes(payload)
                target.chmod(int(entry["mode"], 8))
    else:
        with zipfile.ZipFile(archive) as source:
            for entry in expected:
                target = destination.joinpath(*PurePosixPath(entry["path"]).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read(entry["path"]))
                target.chmod(int(entry["mode"], 8))
    return expected


def deterministic_files(root, requested):
    root = Path(root).resolve()
    require(root.is_dir(), f"archive root is not a directory: {root}")
    selected = []
    for raw in requested or ["."]:
        relative = safe_relative(raw, "requested archive path") if raw != "." else PurePosixPath()
        path = root.joinpath(*relative.parts)
        require(path.exists(), f"requested archive path is missing: {raw}")
        if path.is_symlink():
            raise ArtifactError(f"archive input contains a symlink: {raw}")
        if path.is_file():
            selected.append(path)
        else:
            selected.extend(candidate for candidate in path.rglob("*") if candidate.is_file())
    unique = {}
    for path in selected:
        require(not path.is_symlink(), f"archive input contains a symlink: {path}")
        relative = path.relative_to(root).as_posix()
        safe_relative(relative)
        unique[relative] = path
    require(unique, "archive input contains no files")
    return [(relative, unique[relative]) for relative in sorted(unique)]


def pack_archive(root, requested, output, archive_format):
    output = Path(output)
    require(not output.exists(), f"archive output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    files = deterministic_files(root, requested)
    if archive_format == "tar.gz":
        with output.open("wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for relative, path in files:
                        payload = path.read_bytes()
                        info = tarfile.TarInfo(relative)
                        info.size = len(payload)
                        info.mode = int(file_mode(path.stat().st_mode), 8)
                        info.uid = 0
                        info.gid = 0
                        info.uname = ""
                        info.gname = ""
                        info.mtime = 0
                        archive.addfile(info, fileobj=__import__("io").BytesIO(payload))
    elif archive_format == "zip":
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for relative, path in files:
                info = zipfile.ZipInfo(relative, (1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = int(file_mode(path.stat().st_mode), 8) << 16
                archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    else:
        raise ArtifactError(f"unsupported archive format: {archive_format}")
    archive_entries(output, archive_format)


def create_manifest(args):
    require(args.tag == "v" + args.version, "tag does not match version")
    require(args.repository == CANONICAL_REPOSITORY, "repository must be canonical")
    require(args.builder_repository == CANONICAL_GITHUB_REPOSITORY, "builder repository must be canonical")
    require(args.workflow == NATIVE_WORKFLOW, "builder workflow must be canonical")
    artifacts = []
    for specification in args.artifact:
        require("=" in specification, f"artifact must be TARGET=PATH: {specification!r}")
        target, raw_path = specification.split("=", 1)
        require(TARGET_RE.fullmatch(target), f"artifact target is invalid: {target!r}")
        path = Path(raw_path).resolve()
        require(path.is_file(), f"artifact file is missing: {path}")
        archive_format, entries = archive_entries(path)
        artifacts.append(
            {
                "target": target,
                "filename": path.name,
                "sha256": digest_file(path),
                "size": path.stat().st_size,
                "archive": {"format": archive_format, "files": entries},
            }
        )
    artifacts.sort(key=lambda artifact: artifact["target"])
    value = {
        "schema": SCHEMA,
        "version": args.version,
        "tag": args.tag,
        "repository": args.repository,
        "source_sha": args.source_sha,
        "builder": {
            "repository": args.builder_repository,
            "workflow": args.workflow,
            "run_id": args.run_id,
            "run_attempt": args.run_attempt,
            "identity": f"https://github.com/{args.builder_repository}/actions/runs/{args.run_id}",
        },
        "artifacts": artifacts,
    }
    validate_manifest(value)
    output = Path(args.output)
    require(not output.exists(), f"manifest output already exists: {output}")
    output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def safe_extract_zip(archive, destination):
    destination = Path(destination)
    require(not destination.exists(), f"download destination already exists: {destination}")
    destination.mkdir(parents=True)
    with zipfile.ZipFile(archive) as source:
        infos = source.infolist()
        require(infos and len(infos) <= MAX_FILES, "GitHub artifact zip is empty or oversized")
        seen = set()
        expanded = 0
        for info in infos:
            require(not info.is_dir(), f"GitHub artifact contains a directory entry: {info.filename!r}")
            mode = (info.external_attr >> 16) & 0o777777
            require(not stat.S_ISLNK(mode), f"GitHub artifact contains a symlink: {info.filename!r}")
            relative = safe_relative(info.filename)
            require(relative.as_posix() not in seen, f"GitHub artifact contains a duplicate path: {info.filename!r}")
            seen.add(relative.as_posix())
            expanded += info.file_size
            require(expanded <= MAX_EXPANDED_BYTES, "GitHub artifact zip expands beyond the size limit")
            target = destination.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            payload = source.read(info)
            require(len(payload) == info.file_size, f"GitHub artifact member size changed while reading: {info.filename!r}")
            target.write_bytes(payload)


def gh_json(path):
    result = subprocess.run(["gh", "api", path], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    require(result.returncode == 0, f"GitHub API request failed for {path}: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ArtifactError(f"GitHub API returned invalid JSON for {path}") from error


def download_github(args):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository), "GitHub repository is invalid")
    require(args.run_id > 0, "native artifact run ID is invalid")
    require(args.run_attempt > 0, "native artifact run attempt is invalid")
    require(SHA_RE.fullmatch(args.source_sha), "expected source SHA is invalid")
    run = gh_json(f"/repos/{args.repository}/actions/runs/{args.run_id}")
    require(run.get("id") == args.run_id, "GitHub workflow run ID changed")
    require(run.get("run_attempt") == args.run_attempt, "GitHub workflow run attempt changed")
    require(run.get("display_title") == f"Native artifacts for {args.source_sha}", "GitHub workflow run source identity is wrong")
    require(run.get("head_branch") == "main", "GitHub workflow run branch is wrong")
    require(run.get("path") == NATIVE_WORKFLOW, "GitHub workflow run path is wrong")
    require(run.get("event") == "workflow_run", "GitHub workflow run event is wrong")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "GitHub workflow run is not successful")
    listing = gh_json(f"/repos/{args.repository}/actions/runs/{args.run_id}/artifacts?per_page=100")
    artifacts = listing.get("artifacts", [])
    require(
        isinstance(artifacts, list) and listing.get("total_count") == len(artifacts),
        "GitHub artifact listing is incomplete or malformed",
    )
    artifact_name = args.artifact_name or f"native-release-bundle-{args.run_attempt}"
    matches = [item for item in artifacts if item.get("name") == artifact_name]
    require(len(matches) == 1, f"native workflow must contain exactly one {artifact_name!r} artifact")
    artifact = matches[0]
    require(not artifact.get("expired"), "native workflow artifact has expired")
    artifact_id = artifact.get("id")
    require(isinstance(artifact_id, int) and artifact_id > 0, "native workflow artifact ID is invalid")
    with tempfile.TemporaryDirectory(prefix="hop-native-download-") as temporary:
        archive = Path(temporary) / "artifact.zip"
        with archive.open("wb") as output:
            result = subprocess.run(
                ["gh", "api", f"/repos/{args.repository}/actions/artifacts/{artifact_id}/zip"],
                check=False,
                stdout=output,
                stderr=subprocess.PIPE,
            )
        require(result.returncode == 0, f"GitHub artifact download failed: {result.stderr.decode('utf-8', 'replace').strip()}")
        safe_extract_zip(archive, args.output)
    print(f"downloaded native workflow artifact: run_id={args.run_id} artifact_id={artifact_id}")


def apple_architecture_value(xcframework):
    xcframework = Path(xcframework).resolve()
    info_path = xcframework / "Info.plist"
    require(info_path.is_file(), "xcframework Info.plist is missing")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ArtifactError(f"xcframework Info.plist is invalid: {error}") from error
    libraries = info.get("AvailableLibraries")
    require(isinstance(libraries, list) and libraries, "xcframework has no library slices")
    slices = []
    identifiers = set()
    for library in libraries:
        require(isinstance(library, dict), "xcframework library entry is malformed")
        identifier = library.get("LibraryIdentifier")
        library_path = library.get("LibraryPath")
        architectures = library.get("SupportedArchitectures")
        platform = library.get("SupportedPlatform")
        variant = library.get("SupportedPlatformVariant", "")
        require(isinstance(identifier, str) and identifier not in identifiers, "xcframework library identifier is invalid or duplicated")
        identifiers.add(identifier)
        require(isinstance(library_path, str) and library_path, f"xcframework library path is missing for {identifier}")
        require(isinstance(architectures, list) and architectures and all(isinstance(item, str) for item in architectures), f"xcframework architectures are invalid for {identifier}")
        require(isinstance(platform, str) and platform, f"xcframework platform is invalid for {identifier}")
        binary = xcframework / identifier / library_path
        require(binary.is_file() and not binary.is_symlink(), f"xcframework binary is missing for {identifier}")
        inspected = subprocess.run(
            ["lipo", "-archs", str(binary)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        require(inspected.returncode == 0, f"xcframework binary architectures cannot be inspected for {identifier}")
        binary_architectures = sorted(inspected.stdout.split())
        require(
            binary_architectures == sorted(architectures),
            f"xcframework binary architectures do not match Info.plist for {identifier}",
        )
        slices.append(
            {
                "identifier": identifier,
                "platform": platform,
                "variant": variant,
                "architectures": binary_architectures,
                "binary": f"{identifier}/{library_path}",
                "sha256": digest_file(binary),
                "size": binary.stat().st_size,
            }
        )
    slices.sort(key=lambda item: item["identifier"])
    return {"schema": 1, "xcframework": xcframework.name, "slices": slices}


def write_apple_manifest(args):
    value = apple_architecture_value(args.xcframework)
    output = Path(args.output)
    require(not output.exists(), f"architecture manifest output already exists: {output}")
    output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def verify_apple_manifest(args):
    expected = apple_architecture_value(args.xcframework)
    try:
        actual = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ArtifactError(f"architecture manifest cannot be loaded: {error}") from error
    require(actual == expected, "xcframework architecture manifest does not match its binaries")
    actual_targets = {
        (item["platform"], item["variant"], tuple(item["architectures"])) for item in actual["slices"]
    }
    required_targets = {
        ("ios", "", ("arm64",)),
        ("ios", "simulator", ("arm64", "x86_64")),
        ("macos", "", ("arm64", "x86_64")),
    }
    require(actual_targets == required_targets, f"xcframework architectures differ: {sorted(actual_targets)}")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    pack = subparsers.add_parser("pack")
    pack.add_argument("--root", required=True)
    pack.add_argument("--path", action="append", default=[])
    pack.add_argument("--output", required=True)
    pack.add_argument("--format", choices=("tar.gz", "zip"), required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--output", required=True)
    create.add_argument("--version", required=True)
    create.add_argument("--tag", required=True)
    create.add_argument("--repository", default=CANONICAL_REPOSITORY)
    create.add_argument("--source-sha", required=True)
    create.add_argument("--builder-repository", default=CANONICAL_GITHUB_REPOSITORY)
    create.add_argument("--workflow", default=NATIVE_WORKFLOW)
    create.add_argument("--run-id", type=int, required=True)
    create.add_argument("--run-attempt", type=int, required=True)
    create.add_argument("--artifact", action="append", required=True)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--signature", required=True)
    verify.add_argument("--public-key", required=True)
    verify.add_argument("--directory", required=True)
    verify.add_argument("--target")
    verify.add_argument("--strict", action="store_true")
    verify.add_argument("--source-sha")
    verify.add_argument("--tag")
    verify.add_argument("--run-id", type=int)
    verify.add_argument("--run-attempt", type=int)

    extract = subparsers.add_parser("extract")
    extract.add_argument("--manifest", required=True)
    extract.add_argument("--signature", required=True)
    extract.add_argument("--public-key", required=True)
    extract.add_argument("--directory", required=True)
    extract.add_argument("--target", required=True)
    extract.add_argument("--destination", required=True)

    download = subparsers.add_parser("download-github")
    download.add_argument("--repository", default=CANONICAL_GITHUB_REPOSITORY)
    download.add_argument("--run-id", type=int, required=True)
    download.add_argument("--run-attempt", type=int, required=True)
    download.add_argument("--source-sha", required=True)
    download.add_argument("--artifact-name")
    download.add_argument("--output", required=True)

    apple_manifest = subparsers.add_parser("apple-manifest")
    apple_manifest.add_argument("--xcframework", required=True)
    apple_manifest.add_argument("--output", required=True)

    apple_verify = subparsers.add_parser("apple-verify")
    apple_verify.add_argument("--xcframework", required=True)
    apple_verify.add_argument("--manifest", required=True)

    args = parser.parse_args()
    try:
        if args.command == "pack":
            pack_archive(args.root, args.path, args.output, args.format)
        elif args.command == "create":
            create_manifest(args)
        elif args.command == "verify":
            verify_release(
                args.manifest,
                args.signature,
                args.public_key,
                args.directory,
                args.target,
                args.strict,
                args.source_sha,
                args.tag,
                args.run_id,
                args.run_attempt,
            )
        elif args.command == "extract":
            manifest = verify_release(args.manifest, args.signature, args.public_key, args.directory, args.target)
            artifact = select_artifact(manifest, args.target)
            safe_extract(Path(args.directory) / artifact["filename"], args.destination)
        elif args.command == "download-github":
            download_github(args)
        elif args.command == "apple-manifest":
            write_apple_manifest(args)
        elif args.command == "apple-verify":
            verify_apple_manifest(args)
    except (ArtifactError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f"native artifact rejected: {error}") from error


if __name__ == "__main__":
    main()
