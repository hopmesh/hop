#!/usr/bin/env python3
"""Resolve the release version of every mirrored component that publishes.

A component releases when its PUBLIC mirror gets a `vX.Y.Z` tag: that tag is what fires the mirror's
own `.github/workflows/release.yml`, which publishes to npm / PyPI / RubyGems / crates / Hex / SwiftPM
via OIDC trusted publishing. Nothing in the monorepo created those tags, so no mirror had ever been
tagged or released.

The tag must equal the component's OWN declared version, because every mirror release workflow asserts
exactly that (`test "${GITHUB_REF_NAME#v}" = <manifest version>`) and fails the release otherwise. So
the version is read from each component's real manifest here, per ecosystem, rather than assuming one
version across the fleet. tools/version-align-guard.sh already keeps those manifests within
major/minor of the Rust workspace anchor while allowing patch drift, and this respects that drift.

Components whose ecosystem carries no in-repo version (SwiftPM and Go are tag-driven; the Android and
embedded SDKs publish artifacts rather than a versioned manifest) fall back to the workspace anchor,
which is the version their release workflows treat as authoritative.
"""

import json
import os
import re
import sys
import tomllib
from pathlib import Path


SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


class PlanError(RuntimeError):
    pass


def workspace_version(root):
    """The Rust workspace version: the anchor every other manifest is aligned to."""
    data = tomllib.loads((root / "Cargo.toml").read_text(encoding="utf-8"))
    version = data.get("workspace", {}).get("package", {}).get("version")
    if not version:
        raise PlanError("workspace [workspace.package] version is missing")
    return version


def _cargo_version(path, root):
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    version = data.get("package", {}).get("version")
    # `version.workspace = true` inherits the anchor; tomllib gives us the raw table.
    if isinstance(version, dict):
        return workspace_version(root) if version.get("workspace") else None
    return version


def _first_match(pattern, text):
    match = re.search(pattern, text, re.MULTILINE)
    return match.group(1) if match else None


def resolve_version(prefix, root):
    """Read the component's declared version from whichever manifest its ecosystem uses."""
    directory = root / prefix

    package_json = directory / "package.json"
    if package_json.is_file():
        version = json.loads(package_json.read_text(encoding="utf-8")).get("version")
        if version:
            return version, "package.json"

    pyproject = directory / "pyproject.toml"
    if pyproject.is_file():
        data = tomllib.loads(pyproject.read_text(encoding="utf-8"))
        version = data.get("project", {}).get("version")
        if version:
            return version, "pyproject.toml"

    shard = directory / "shard.yml"
    if shard.is_file():
        version = _first_match(r"^version:\s*['\"]?([0-9][^'\"\s]*)", shard.read_text(encoding="utf-8"))
        if version:
            return version, "shard.yml"

    mix = directory / "mix.exs"
    if mix.is_file():
        version = _first_match(r"version:\s*\"([0-9][^\"]*)\"", mix.read_text(encoding="utf-8"))
        if version:
            return version, "mix.exs"

    for gemspec in sorted(directory.glob("*.gemspec")):
        text = gemspec.read_text(encoding="utf-8")
        version = _first_match(r"\.version\s*=\s*['\"]([0-9][^'\"]*)['\"]", text)
        if version:
            return version, gemspec.name
        # A gemspec commonly defers to a version.rb constant.
        for version_rb in sorted(directory.glob("lib/**/version.rb")):
            version = _first_match(
                r"VERSION\s*=\s*['\"]([0-9][^'\"]*)['\"]", version_rb.read_text(encoding="utf-8")
            )
            if version:
                return version, str(version_rb.relative_to(directory))

    cargo = directory / "Cargo.toml"
    if cargo.is_file():
        version = _cargo_version(cargo, root)
        if version:
            return version, "Cargo.toml"

    # SwiftPM / Go / artifact-publishing components carry no in-repo version.
    return workspace_version(root), "workspace anchor"


def plan(root):
    root = Path(root)
    components = json.loads((root / "tools/copybara/components.json").read_text(encoding="utf-8"))
    entries = []
    for name, entry in sorted(components.items()):
        prefix = entry["prefix"]
        # Only components that actually publish. The rest are mirrored but never tagged.
        if not (root / prefix / ".github/workflows/release.yml").is_file():
            continue
        version, source = resolve_version(prefix, root)
        if not SEMVER.match(version):
            raise PlanError(f"{name}: version {version!r} from {source} is not a bare X.Y.Z")
        entries.append(
            {"component": name, "prefix": prefix, "version": version, "source": source}
        )
    if not entries:
        raise PlanError("no releasable components found")
    return entries


def main():
    root = Path(os.environ.get("GITHUB_WORKSPACE") or ".").resolve()
    entries = plan(root)
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        # Both single-line on purpose: a GITHUB_OUTPUT value containing a newline needs heredoc
        # framing, and create-github-app-token accepts a comma-separated repository list.
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"plan={json.dumps(entries, separators=(',', ':'))}\n")
            handle.write("repos=" + ",".join(e["component"] for e in entries) + "\n")
    for entry in entries:
        print(f"{entry['component']}\t{entry['version']}\t({entry['source']})")


if __name__ == "__main__":
    try:
        main()
    except (PlanError, OSError, ValueError, KeyError) as error:
        raise SystemExit(f"release plan failed: {error}") from error
