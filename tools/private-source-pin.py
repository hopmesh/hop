#!/usr/bin/env python3
"""Validate the immutable private source lock and a checked-out source tree."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

CANONICAL_REPOSITORY = "hopmesh/platform"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_SOURCE_FILES = (
    "tools/stage-commercial-source.py",
    "tools/commercial-source-manifest.txt",
)


class PinError(ValueError):
    pass


def fail(message: str) -> None:
    raise PinError(message)


def regular_file(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        fail(f"{label} must be a regular non-symlink file: {path}")


def load_lock(path: Path) -> dict[str, str]:
    regular_file(path, "private source lock")
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
        pairs: list[tuple[str, object]] = json.loads(
            text,
            object_pairs_hook=lambda items: items,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"private source lock is not canonical UTF-8 JSON: {error}")
    if not isinstance(pairs, list) or any(
        not isinstance(item, tuple) or len(item) != 2 for item in pairs
    ):
        fail("private source lock must be an object")
    keys = [key for key, _ in pairs]
    if keys != ["repository", "commit"]:
        fail("private source lock must contain repository then commit exactly once")
    value = dict(pairs)
    repository = value["repository"]
    commit = value["commit"]
    if repository != CANONICAL_REPOSITORY:
        fail(f"private source repository must be {CANONICAL_REPOSITORY}")
    if not isinstance(commit, str) or not SHA_RE.fullmatch(commit):
        fail("private source commit must be exactly 40 lowercase hexadecimal characters")
    canonical = json.dumps(
        {"repository": repository, "commit": commit},
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    if raw != canonical:
        fail("private source lock must use canonical one-line JSON plus LF")
    return {"repository": repository, "commit": commit}


def git(checkout: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(checkout), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail(
            f"git {' '.join(args)} failed for {checkout}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout.strip()


def normalize_github_remote(value: str) -> str:
    value = value.strip()
    patterns = (
        r"https://github\.com/([^/]+/[^/]+?)(?:\.git)?$",
        r"git@github\.com:([^/]+/[^/]+?)(?:\.git)?$",
        r"ssh://git@github\.com/([^/]+/[^/]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.fullmatch(pattern, value, flags=re.IGNORECASE)
        if match:
            return match.group(1).lower()
    fail("private source origin is not the canonical hopmesh/platform GitHub remote")
    raise AssertionError("unreachable")


def verify_checkout(lock: dict[str, str], checkout: Path) -> None:
    checkout = checkout.resolve(strict=True)
    if not (checkout / ".git").exists():
        fail(f"private source checkout is not a git worktree: {checkout}")
    remote = normalize_github_remote(git(checkout, "config", "--get", "remote.origin.url"))
    if remote != lock["repository"]:
        fail(
            f"private source origin must be {lock['repository']}; got {remote}"
        )
    head = git(checkout, "rev-parse", "HEAD").lower()
    if head != lock["commit"]:
        fail(f"private source HEAD must equal {lock['commit']}; got {head}")
    dirty = git(checkout, "status", "--porcelain", "--untracked-files=all")
    if dirty:
        fail("private source checkout must be clean")
    for relative in REQUIRED_SOURCE_FILES:
        path = checkout / relative
        regular_file(path, f"private source contract file {relative}")
        if checkout not in path.resolve().parents:
            fail(f"private source contract file escapes checkout: {relative}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    verify = sub.add_parser("verify-lock")
    verify.add_argument("--lock", required=True, type=Path)
    get = sub.add_parser("get")
    get.add_argument("--lock", required=True, type=Path)
    get.add_argument("field", choices=("repository", "commit"))
    checkout = sub.add_parser("verify-checkout")
    checkout.add_argument("--lock", required=True, type=Path)
    checkout.add_argument("--checkout", required=True, type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    lock = load_lock(args.lock)
    if args.command == "get":
        print(lock[args.field])
    elif args.command == "verify-checkout":
        verify_checkout(lock, args.checkout)
        print(f"private source checkout OK: {lock['repository']}@{lock['commit'][:8]}")
    else:
        print(f"private source lock OK: {lock['repository']}@{lock['commit'][:8]}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PinError as error:
        print(f"private source pin rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
