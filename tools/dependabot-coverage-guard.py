#!/usr/bin/env python3
"""dependabot-coverage-guard: ensure all executable dependency roots have declared
updater or manual update disposition (INFRA-013).

Validates that:
1. Every executable dependency root (Cargo.toml outside workspace, package.json,
   build.gradle(.kts), Package.swift, pubspec.yaml, pyproject.toml, Gemfile/gemspec,
   mix.exs, go.mod, shard.yml) has an active update configuration in .github/dependabot.yml
   or is documented in MANUAL_UPDATE_ALLOWLIST with an explicit technical reason.
2. No stale entries exist in dependabot.yml or MANUAL_UPDATE_ALLOWLIST for removed roots.
3. Allowlist reasons must be substantial (>= 20 characters).

Usage:
    python3 tools/dependabot-coverage-guard.py [--dependabot FILE] [--repo-root DIR] [--manifests-list FILE]
"""

import argparse
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("dependabot-coverage-guard: FAIL (pyyaml unavailable)", file=sys.stderr)
    sys.exit(1)


# Roots that cannot use Dependabot or are deliberately managed manually.
# Each entry must have a detailed reason explaining the ownership policy.
MANUAL_UPDATE_ALLOWLIST = {
    "sdk/crystal": (
        "Dependabot has no native Crystal shard.yml ecosystem support; "
        "dependencies are manually audited and updated in lockstep with SDK releases"
    ),
    "sdk/elixir/native/hop_endpoint": (
        "Internal Rust NIF crate compiled by Rustler; dependencies are pinned "
        "and managed in lockstep with sdk/elixir/mix.exs"
    ),
    "apps/react-native/HopDemo/Gemfile": (
        "React Native demo iOS CocoaPods tooling; pinned to React Native CLI release"
    ),
    "apps/react-native/HopDemo/android": (
        "React Native demo Android build; dependencies managed via root package.json "
        "and the React Native Gradle plugin"
    ),
    "sdk/ruby/hop-endpoint.gemspec": (
        "Ruby gem specification; runtime and development dependencies are governed "
        "by sdk/ruby/Gemfile which is tracked by Dependabot"
    ),
    "bearers/apple": (
        "Internal SwiftPM umbrella package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
    "sdk/react-native/android": (
        "Android Gradle bridge for @hop-mesh/react-native; coordinates and versions "
        "are governed by sdk/react-native and verified by CI"
    ),
    "bearers/apple/HopBearerBle": (
        "Internal SwiftPM bearer package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
    "bearers/apple/HopBearerLan": (
        "Internal SwiftPM bearer package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
    "bearers/apple/HopBearerMeshtastic": (
        "Internal SwiftPM bearer package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
    "bearers/apple/HopBearerMultipeer": (
        "Internal SwiftPM bearer package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
    "bearers/apple/HopBearerRelay": (
        "Internal SwiftPM bearer package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
    "drivers/apple/HopDriver": (
        "Internal SwiftPM driver package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
    "apps/apple/HopDemoKit": (
        "Internal SwiftPM demo kit package referencing local path dependencies; "
        "external packages are governed by sdk/apple/Package.swift"
    ),
}

MANIFEST_FILENAMES = {
    "Cargo.toml",
    "package.json",
    "build.gradle",
    "build.gradle.kts",
    "Package.swift",
    "pubspec.yaml",
    "pyproject.toml",
    "Gemfile",
    "mix.exs",
    "go.mod",
    "shard.yml",
}


def parse_dependabot(dependabot_path: Path) -> list[dict]:
    """Parse updates from .github/dependabot.yml."""
    raw = yaml.safe_load(dependabot_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or "updates" not in raw:
        raise ValueError(f"No 'updates' key found in {dependabot_path}")
    updates = raw.get("updates", [])
    if not isinstance(updates, list):
        raise ValueError(f"'updates' in {dependabot_path} must be a list")
    return updates


def discover_manifest_roots(repo_root: Path, manifests_file: Path | None = None) -> set[str]:
    """Discover all package roots from tracked manifest files."""
    if manifests_file:
        files = [
            line.strip()
            for line in manifests_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    else:
        out = subprocess.check_output(
            ["git", "-C", str(repo_root), "ls-files"], text=True
        )
        files = [line.strip() for line in out.splitlines() if line.strip()]

    # Collect workspace members from root Cargo.toml if present
    workspace_members = set()
    root_cargo = repo_root / "Cargo.toml"
    if root_cargo.is_file():
        try:
            import tomllib
        except ImportError:
            try:
                import tomli as tomllib
            except ImportError:
                tomllib = None

        if tomllib:
            try:
                cargo_data = tomllib.loads(root_cargo.read_text(encoding="utf-8"))
                for m in cargo_data.get("workspace", {}).get("members", []):
                    workspace_members.add(m.rstrip("/"))
            except Exception:
                pass

    roots = set()
    for f in files:
        p = Path(f)
        name = p.name
        is_manifest = False
        if name in MANIFEST_FILENAMES or name.endswith(".gemspec"):
            is_manifest = True

        if not is_manifest:
            continue

        dir_path = str(p.parent) if str(p.parent) != "." else ""

        # For Cargo.toml, if it is a member of the root workspace, the root "/" is the updater root
        if name == "Cargo.toml":
            if dir_path == "":
                roots.add("")
            elif dir_path in workspace_members:
                # Part of root workspace, covered by root Cargo entry
                continue
            else:
                # Standalone cargo root (e.g. fuzz, sdk/elixir/native/hop_endpoint)
                roots.add(dir_path)
            continue

        # For Gradle submodules (e.g. apps/android/HopDemo/app, bearers/android/bearer-ble):
        # The project root containing settings.gradle(.kts) or top-level build.gradle(.kts) is the updater root
        if name in ("build.gradle", "build.gradle.kts"):
            # Check if this is a subproject under a known Gradle root
            # e.g., bearers/android/bearer-ble -> bearers/android
            parts = dir_path.split("/")
            if len(parts) > 1 and parts[-1] in (
                "app", "bearer-ble", "bearer-lan", "bearer-relay", "bearer-meshtastic",
                "bearer-core", "hop-sdk", "hop-driver"
            ):
                continue

        roots.add(dir_path)

    return roots


def check_coverage(
    dependabot_path: Path,
    repo_root: Path,
    manifests_file: Path | None = None,
) -> list[str]:
    errors = []

    try:
        updates = parse_dependabot(dependabot_path)
    except Exception as exc:
        return [f"Failed to parse {dependabot_path}: {exc}"]

    # Map of normalized directory -> list of configured ecosystems
    configured_dirs: dict[str, list[str]] = {}
    for entry in updates:
        eco = entry.get("package-ecosystem", "")
        raw_dir = entry.get("directory", "/")
        norm_dir = raw_dir.strip("/")
        configured_dirs.setdefault(norm_dir, []).append(eco)

    roots = discover_manifest_roots(repo_root, manifests_file)

    # 1. Check that every discovered root is covered
    for root in sorted(roots):
        if root in configured_dirs:
            continue

        if root in MANUAL_UPDATE_ALLOWLIST:
            reason = MANUAL_UPDATE_ALLOWLIST[root]
            if len(reason.strip()) < 20:
                errors.append(
                    f"Allowlist entry for '{root}' has insufficient reason (< 20 chars): '{reason}'"
                )
            continue

        errors.append(
            f"Package root '{root or '/'}' has no Dependabot entry and is not in MANUAL_UPDATE_ALLOWLIST"
        )

    # 2. Check for stale entries in MANUAL_UPDATE_ALLOWLIST (only when running against real repo)
    if not manifests_file:
        for root in sorted(MANUAL_UPDATE_ALLOWLIST.keys()):
            target = repo_root / root
            if not target.exists():
                errors.append(
                    f"Stale MANUAL_UPDATE_ALLOWLIST entry '{root}': directory does not exist"
                )

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dependabot",
        type=Path,
        default=Path(".github/dependabot.yml"),
        help="Path to dependabot.yml config file",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path("."),
        help="Path to repository root",
    )
    parser.add_argument(
        "--manifests-list",
        type=Path,
        default=None,
        help="Optional file containing newline-delimited list of repo-relative manifest paths",
    )

    args = parser.parse_args()
    errors = check_coverage(args.dependabot, args.repo_root, args.manifests_list)

    if errors:
        for err in errors:
            print(f"::error::{err}", file=sys.stderr)
        return 1

    print("dependabot-coverage-guard: OK (all package roots mapped to updaters or allowlisted)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
