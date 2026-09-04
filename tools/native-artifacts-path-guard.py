#!/usr/bin/env python3
"""Keep native-artifacts.yml push path filters aligned with the native build graph (PROC-005)."""

import re
import sys
from pathlib import Path


class NativePathError(RuntimeError):
    pass


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
        raise NativePathError("native-artifacts push path filters are absent")
    if len(paths) != len(set(paths)):
        raise NativePathError("native-artifacts push path filters contain duplicates")
    return paths


def required_paths(root):
    required = {
        ".github/workflows/native-artifacts.yml",
        "Cargo.lock",
        "Cargo.toml",
        "LICENSE.md",
        "THIRD-PARTY-NOTICES.md",
        "core/**",
        "rust-toolchain.toml",
        "sdk/apple/build-xcframework.sh",
        "sdk/hop.h",
        "tools/build-aar.sh",
        "tools/build-xcframework.sh",
        "tools/gen-third-party-notices.py",
        "tools/native-artifacts-path-guard.py",
        "tools/native-artifacts-public.pem",
        "tools/native-artifacts.py",
        "tools/native-artifacts.schema.json",
        "tools/native-attestation/**",
    }
    if (root / ".cargo").exists():
        required.add(".cargo/**")
    return required


def check(root):
    workflow = root / ".github/workflows/native-artifacts.yml"
    if not workflow.is_file():
        raise NativePathError(f"missing workflow file: {workflow}")
    actual = set(workflow_paths(workflow))
    required = required_paths(root)
    missing = sorted(required - actual)
    extra = sorted(actual - required)
    if missing or extra:
        raise NativePathError(f"native-artifacts path graph drifted: missing={missing}, extra={extra}")
    print("native-artifacts path filters cover: " + ", ".join(sorted(actual)))


if __name__ == "__main__":
    try:
        check(Path(__file__).resolve().parent.parent)
    except (NativePathError, OSError, ValueError) as error:
        raise SystemExit(f"native-artifacts path guard failed: {error}") from error
