#!/usr/bin/env python3
"""Keep Pages authority and path filters aligned with the deployed build graph."""

import json
import re
import subprocess
from pathlib import Path


class PagesPathError(RuntimeError):
    pass


def check_authority(text):
    repository_check = 'test "$REPOSITORY" = hopmesh/hop'
    main_api = "https://api.github.com/repos/hopmesh/hop/git/ref/heads/main"
    hidden_artifacts = "include-hidden-files: true"
    if text.count(repository_check) != 1:
        raise PagesPathError("Pages canonical repository check drifted")
    if text.count(main_api) != 2:
        raise PagesPathError("Pages canonical main checks drifted")
    if text.count(hidden_artifacts) != 1:
        raise PagesPathError("Pages artifact omits hidden provenance files")


def workflow_paths(path):
    paths = []
    in_paths = False
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line == "    paths:":
            in_paths = True
            continue
        if not in_paths:
            continue
        match = re.match(r"^\s{6}- ['\"]([^'\"]+)['\"]$", line)
        if match:
            paths.append(match.group(1))
            continue
        if line.strip():
            break
    if not paths:
        raise PagesPathError("Pages push path filters are absent")
    if len(paths) != len(set(paths)):
        raise PagesPathError("Pages push path filters contain duplicates")
    return paths


def cargo_metadata(root):
    result = subprocess.run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1", "--locked"],
        cwd=root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise PagesPathError(f"cargo metadata failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def transitive_workspace_crates(root, metadata, package_name="hop-wasm"):
    packages = {package["name"]: package for package in metadata["packages"]}
    if package_name not in packages:
        raise PagesPathError(f"workspace package is absent: {package_name}")
    selected = set()
    pending = [package_name]
    while pending:
        name = pending.pop()
        if name in selected:
            continue
        selected.add(name)
        for dependency in packages[name].get("dependencies", []):
            if dependency.get("source") is None and dependency.get("name") in packages:
                pending.append(dependency["name"])
    paths = set()
    for name in selected:
        manifest = Path(packages[name]["manifest_path"]).resolve()
        relative = manifest.parent.relative_to(root.resolve()).as_posix()
        paths.add(f"{relative}/**")
    return paths


def copied_roots(root):
    package = json.loads((root / "apps/web/site/package.json").read_text(encoding="utf-8"))
    roots = set()
    for command in package.get("scripts", {}).values():
        for match in re.finditer(r"cp\s+-R\s+\.\./\.\./\.\./([^/\s]+)/", command):
            roots.add(f"{match.group(1)}/**")
    if roots != {"learn/**", "sim/**"}:
        raise PagesPathError(f"unexpected site copy graph: {sorted(roots)}")
    return roots


def invoked_tools(root):
    workflow = (root / ".github/workflows/pages.yml").read_text(encoding="utf-8")
    return {
        match.group(1)
        for match in re.finditer(r"(?:bash|node|python3?)\s+(tools/[A-Za-z0-9_./-]+)", workflow)
    }


def required_paths(root, metadata=None):
    metadata = metadata or cargo_metadata(root)
    required = {
        ".github/workflows/pages.yml",
        "Cargo.toml",
        "Cargo.lock",
        "rust-toolchain.toml",
        "apps/web/site/**",
    }
    required.update(copied_roots(root))
    required.update(transitive_workspace_crates(root, metadata))
    required.update(invoked_tools(root))
    if (root / ".cargo").exists():
        required.add(".cargo/**")
    return required


def check(root):
    workflow = root / ".github/workflows/pages.yml"
    check_authority(workflow.read_text(encoding="utf-8"))
    actual = set(workflow_paths(workflow))
    required = required_paths(root)
    missing = sorted(required - actual)
    extra = sorted(actual - required)
    if missing or extra:
        raise PagesPathError(f"Pages path graph drifted: missing={missing}, extra={extra}")
    print("Pages path filters cover: " + ", ".join(sorted(actual)))


if __name__ == "__main__":
    try:
        check(Path(__file__).resolve().parent.parent)
    except (PagesPathError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"Pages path guard failed: {error}") from error
