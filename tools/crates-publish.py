#!/usr/bin/env python3
"""Create crates.io metadata and publish an already verified .crate archive."""

import argparse
import io
import json
import os
import shutil
import struct
import subprocess
import tarfile
import tomllib
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath

PUBLISH_FIELDS = {
    "authors",
    "badges",
    "categories",
    "deps",
    "description",
    "documentation",
    "features",
    "homepage",
    "keywords",
    "license",
    "license_file",
    "links",
    "name",
    "readme",
    "readme_file",
    "repository",
    "rust_version",
    "vers",
}

PUBLISHED_CRATES = (
    ("core/hop-core", "hop-core", "hop-mesh-core"),
    ("core/stores/hop-store-sqlite", "hop-store-sqlite", "hop-mesh-store-sqlite"),
    ("core/stores/hop-store-firestore", "hop-store-firestore", "hop-mesh-store-firestore"),
)

CRATE_RENAMES = {
    "hop-core": "hop-mesh-core",
    "hop-store-sqlite": "hop-mesh-store-sqlite",
    "hop-store-firestore": "hop-mesh-store-firestore",
    "hop-endpoint-core": "hop-mesh-endpoint-core",
}


class CrateError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise CrateError(message)


def relative_file(value, root, label):
    if value is None:
        return None, None
    val_path = Path(value)
    path = (root / val_path).resolve() if not val_path.is_absolute() else val_path.resolve()
    try:
        relative = path.relative_to(root.resolve()).as_posix()
    except ValueError as error:
        raise CrateError(f"{label} is outside the package root: {path}") from error
    require(path.is_file(), f"{label} is absent: {path}")
    return path.read_text(encoding="utf-8"), relative

def dependency_metadata(dependency):
    require(dependency.get("source") is not None, f"path dependency cannot be published: {dependency.get('name')}")
    return {
        "default_features": dependency["uses_default_features"],
        "explicit_name_in_toml": dependency.get("rename"),
        "features": dependency["features"],
        "kind": dependency.get("kind") or "normal",
        "name": dependency["name"],
        "optional": dependency["optional"],
        "registry": dependency.get("registry"),
        "target": dependency.get("target"),
        "version_req": dependency["req"],
    }


def package_metadata(package):
    root = Path(package["manifest_path"]).resolve().parent
    readme, readme_file = relative_file(package.get("readme"), root, "README")
    _, license_file = relative_file(package.get("license_file"), root, "license file")
    metadata = {
        "authors": package.get("authors") or [],
        "badges": {},
        "categories": package.get("categories") or [],
        "deps": [dependency_metadata(item) for item in package.get("dependencies", [])],
        "description": package.get("description"),
        "documentation": package.get("documentation"),
        "features": package.get("features") or {},
        "homepage": package.get("homepage"),
        "keywords": package.get("keywords") or [],
        "license": package.get("license"),
        "license_file": license_file,
        "links": package.get("links"),
        "name": package["name"],
        "readme": readme,
        "readme_file": readme_file,
        "repository": package.get("repository"),
        "rust_version": package.get("rust_version"),
        "vers": package["version"],
    }
    require(set(metadata) == PUBLISH_FIELDS, "crate publication metadata fields drifted")
    require(metadata["description"], "crate description is required")
    require(metadata["license"] or metadata["license_file"], "crate license metadata is required")
    return metadata


def validate_crate(path, metadata):
    path = Path(path).resolve()
    require(path.is_file() and path.suffix == ".crate", "crate archive is absent or has a wrong extension")
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        require(members, "crate archive is empty")
        roots = set()
        for member in members:
            pure = PurePosixPath(member.name)
            require(not pure.is_absolute(), "crate archive contains an absolute path")
            require(all(part not in ("", ".", "..") for part in pure.parts), "crate archive contains an unsafe path")
            require(member.isfile() or member.isdir(), "crate archive contains a non-regular entry")
            roots.add(pure.parts[0])
        expected_root = f"{metadata['name']}-{metadata['vers']}"
        require(roots == {expected_root}, "crate archive root differs from publication metadata")
        manifest_name = expected_root + "/Cargo.toml"
        try:
            manifest = archive.extractfile(manifest_name)
        except KeyError as error:
            raise CrateError("crate archive omits Cargo.toml") from error
        require(manifest is not None, "crate Cargo.toml cannot be read")
        try:
            import tomllib

            package = tomllib.loads(manifest.read().decode("utf-8"))["package"]
        except (KeyError, UnicodeDecodeError, ValueError) as error:
            raise CrateError("crate Cargo.toml is invalid") from error
        require(package.get("name") == metadata["name"], "crate name differs from publication metadata")
        require(package.get("version") == metadata["vers"], "crate version differs from publication metadata")
    return path.read_bytes()


def create_metadata(args):
    command = [
        "cargo",
        "metadata",
        "--locked",
        "--no-deps",
        "--format-version",
        "1",
        "--manifest-path",
        args.manifest,
    ]
    result = subprocess.run(command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise CrateError("cargo metadata failed: " + result.stderr.strip())
    payload = json.loads(result.stdout)
    packages = payload.get("packages", [])
    require(len(packages) == 1, f"expected one publish package, found {len(packages)}")
    metadata = package_metadata(packages[0])
    validate_crate(args.crate, metadata)
    output = Path(args.output)
    require(not output.exists(), "crate publication metadata already exists")
    output.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"crate publication metadata created: {metadata['name']} {metadata['vers']}")


def publish(args):
    metadata_path = Path(args.metadata)
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    require(isinstance(metadata, dict) and set(metadata) == PUBLISH_FIELDS, "crate publication metadata is invalid")
    crate = validate_crate(args.crate, metadata)
    encoded = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode("utf-8")
    body = struct.pack("<I", len(encoded)) + encoded + struct.pack("<I", len(crate)) + crate
    token = os.environ.get("CARGO_REGISTRY_TOKEN", "")
    require(token and "\n" not in token and "\r" not in token, "crates.io token is absent or invalid")
    request = urllib.request.Request(
        "https://crates.io/api/v1/crates/new",
        data=body,
        method="PUT",
        headers={
            "Accept": "application/json",
            "Authorization": token,
            "Content-Type": "application/octet-stream",
            "User-Agent": "hop-release/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            response_body = response.read()
            require(response.status in range(200, 300), f"crates.io publish failed: HTTP {response.status}")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        raise CrateError(f"crates.io publish failed: HTTP {error.code}: {detail}") from error
    result = json.loads(response_body or b"{}")
    errors = result.get("errors", [])
    require(not errors, f"crates.io rejected publication: {errors}")
    print(f"published verified crate: {metadata['name']} {metadata['vers']}")

def package_monorepo_crate(root, crate_dir, pub_name, output_dir):
    root = Path(root).resolve()
    output_dir = Path(output_dir).resolve()
    root_manifest = tomllib.loads((root / "Cargo.toml").read_text(encoding="utf-8"))
    ws_pkg = root_manifest["workspace"]["package"]
    ws_deps = root_manifest["workspace"]["dependencies"]
    src_manifest = tomllib.loads((root / crate_dir / "Cargo.toml").read_text(encoding="utf-8"))
    pkg = src_manifest["package"]
    version = ws_pkg["version"]

    lines = ["[workspace]", "", "[package]"]
    lines.append(f'name = "{pub_name}"')
    lines.append(f'version = "{version}"')
    lines.append(f'edition = "{ws_pkg.get("edition", "2021")}"')
    lines.append(f'license = "{pkg.get("license", "Apache-2.0")}"')
    lines.append(f'repository = "{ws_pkg.get("repository", "https://github.com/hopmesh/hop")}"')
    lines.append(f'description = "{pkg.get("description", "")}"')
    lines.append('readme = "README.md"')
    lines.append("")

    if "features" in src_manifest:
        lines.append("[features]")
        for f, items in src_manifest["features"].items():
            items_str = ", ".join(f'"{x}"' for x in items)
            lines.append(f"{f} = [{items_str}]")
        lines.append("")

    lines.append("[dependencies]")
    for dep_name, dep_spec in src_manifest.get("dependencies", {}).items():
        if isinstance(dep_spec, dict) and dep_spec.get("workspace"):
            base_ws = ws_deps[dep_name]
            if isinstance(base_ws, dict):
                spec = dict(base_ws)
                spec.pop("path", None)
            else:
                spec = {"version": base_ws}
            for k, v in dep_spec.items():
                if k != "workspace":
                    spec[k] = v
        elif isinstance(dep_spec, dict):
            spec = dict(dep_spec)
            spec.pop("path", None)
        else:
            spec = {"version": dep_spec}

        if dep_name in CRATE_RENAMES:
            renamed_pkg = CRATE_RENAMES[dep_name]
            spec["package"] = renamed_pkg
            spec["version"] = version

        parts = []
        for k, v in spec.items():
            if isinstance(v, str):
                parts.append(f'{k} = "{v}"')
            elif isinstance(v, bool):
                parts.append(f'{k} = {"true" if v else "false"}')
            elif isinstance(v, list):
                v_str = ", ".join(f'"{x}"' for x in v)
                parts.append(f'{k} = [{v_str}]')
        lines.append(f"{dep_name} = {{ {', '.join(parts)} }}")

    lines.append("")

    for section, table in src_manifest.items():
        if section.startswith("target."):
            lines.append(f"[{section}]")
            for k, v in table.items():
                if isinstance(v, dict):
                    parts = []
                    for sub_k, sub_v in v.items():
                        if isinstance(sub_v, str):
                            parts.append(f'{sub_k} = "{sub_v}"')
                        elif isinstance(sub_v, bool):
                            parts.append(f'{sub_k} = {"true" if sub_v else "false"}')
                        elif isinstance(sub_v, list):
                            v_str = ", ".join(f'"{x}"' for x in sub_v)
                            parts.append(f'{sub_k} = [{v_str}]')
                    lines.append(f"{k} = {{ {', '.join(parts)} }}")
                else:
                    lines.append(f'{k} = "{v}"')
            lines.append("")

    stage = output_dir / "staging" / pub_name
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    manifest_text = "\n".join(lines) + "\n"
    (stage / "Cargo.toml").write_text(manifest_text, encoding="utf-8")

    shutil.copytree(root / crate_dir / "src", stage / "src")
    if (root / crate_dir / "README.md").is_file():
        shutil.copy(root / crate_dir / "README.md", stage / "README.md")
    else:
        (stage / "README.md").write_text(f"# {pub_name}\n\n{pkg.get('description', '')}\n", encoding="utf-8")
    shutil.copy(root / "LICENSE.md", stage / "LICENSE.md")
    if (root / "THIRD-PARTY-NOTICES.md").is_file():
        shutil.copy(root / "THIRD-PARTY-NOTICES.md", stage / "THIRD-PARTY-NOTICES.md")

    crate_path = output_dir / f"{pub_name}-{version}.crate"
    expected_root = f"{pub_name}-{version}"
    with tarfile.open(crate_path, "w:gz") as archive:
        for item in sorted(stage.rglob("*")):
            if item.is_file():
                rel = item.relative_to(stage).as_posix()
                archive_name = f"{expected_root}/{rel}"
                info = tarfile.TarInfo(archive_name)
                payload = item.read_bytes()
                info.size = len(payload)
                info.mode = 0o644
                info.mtime = 0
                archive.addfile(info, io.BytesIO(payload))

    cmd = ["cargo", "metadata", "--locked", "--no-deps", "--format-version", "1", "--manifest-path", str(stage / "Cargo.toml")]
    result = subprocess.run(cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    require(result.returncode == 0, f"cargo metadata failed for {pub_name}: {result.stderr.strip()}")
    pkg_data = json.loads(result.stdout)["packages"][0]
    metadata = package_metadata(pkg_data)
    validate_crate(crate_path, metadata)
    metadata_path = output_dir / f"{pub_name}-{version}.metadata.json"
    metadata_path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return crate_path, metadata_path, metadata


def dry_run(args):
    root = Path(args.root).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    canonical_crates = ("hop-mesh-core", "hop-mesh-store-sqlite", "hop-mesh-store-firestore")
    local_names = {"hop-core", "hop-store-sqlite", "hop-store-firestore"}

    produced = []
    for crate_dir, local_name, pub_name in PUBLISHED_CRATES:
        crate_path, meta_path, metadata = package_monorepo_crate(root, crate_dir, pub_name, output_dir)
        require(metadata["name"] == pub_name, f"crate name mismatch: {metadata['name']} != {pub_name}")
        require(metadata["name"] not in local_names, f"crate published using local name: {metadata['name']}")
        for dep in metadata["deps"]:
            require(dep.get("version_req"), f"dependency {dep['name']} has no version requirement")
            require(dep["name"] not in local_names, f"dependency uses local crate name: {dep['name']}")
        produced.append((pub_name, crate_path, meta_path, metadata))

    produced_names = [name for name, _, _, _ in produced]
    require(list(produced_names) == list(canonical_crates), f"canonical crate set must be published: {produced_names} != {list(canonical_crates)}")
    require(produced_names[0] == "hop-mesh-core", "leaf crate hop-mesh-core must publish first")
    print(f"dry-run: successfully prepared and validated {len(produced)} crates: {', '.join(produced_names)}")
    return produced


def publish_all(args):
    dry_run_args = type("Args", (), {"root": args.root, "output_dir": args.crates_dir})()
    crates = dry_run(dry_run_args)
    token = os.environ.get("CARGO_REGISTRY_TOKEN", "")
    require(token and "\n" not in token and "\r" not in token, "crates.io token is absent or invalid")
    for pub_name, crate_path, meta_path, _ in crates:
        upload_args = type("Args", (), {"crate": str(crate_path), "metadata": str(meta_path)})()
        publish(upload_args)
    print("all crates published successfully in dependency order")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    metadata = subparsers.add_parser("metadata")
    metadata.add_argument("--manifest", default="Cargo.toml")
    metadata.add_argument("--crate", required=True)
    metadata.add_argument("--output", required=True)
    upload = subparsers.add_parser("publish")
    upload.add_argument("--crate", required=True)
    upload.add_argument("--metadata", required=True)
    dr = subparsers.add_parser("dry-run")
    dr.add_argument("--root", default=".")
    dr.add_argument("--output-dir", default="/tmp/crates-dry-run")
    pa = subparsers.add_parser("publish-all")
    pa.add_argument("--root", default=".")
    pa.add_argument("--crates-dir", default="/tmp/crates-dry-run")
    args = parser.parse_args()
    try:
        if args.command == "metadata":
            create_metadata(args)
        elif args.command == "publish":
            publish(args)
        elif args.command == "dry-run":
            dry_run(args)
        elif args.command == "publish-all":
            publish_all(args)
    except (CrateError, OSError, ValueError, json.JSONDecodeError, tarfile.TarError) as error:
        raise SystemExit(f"crate publication rejected: {error}") from error


if __name__ == "__main__":
    main()
