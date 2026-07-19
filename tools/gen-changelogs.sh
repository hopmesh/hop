#!/usr/bin/env bash
# Regenerate the monorepo CHANGELOG.md and a per-library CHANGELOG.md for every mirrored component.
# Uses git-cliff over the conventional-commit history (see cliff.toml). Idempotent: re-running with no
# new commits yields no diff. Requires git-cliff on PATH (or GIT_CLIFF pointing at the binary) and a
# FULL clone (git-cliff walks all of history). Run from anywhere in the tree.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
CLIFF="${GIT_CLIFF:-git-cliff}"
CONFIG="$ROOT/cliff.toml"

echo "changelog: monorepo CHANGELOG.md"
"$CLIFF" --config "$CONFIG" --repository "$ROOT" --output "$ROOT/CHANGELOG.md"

# Per-lib, scoped to each subtree. The PUBLIC set is the copybara component map (single source of
# truth for what mirrors out, so the file rides along on export); the PRIVATE set is the independent
# monorepo-only crates. Every lib that ships or versions on its own gets its own changelog.
"$CLIFF" --version >/dev/null # fail early if the binary is broken
python3 - "$CLIFF" "$CONFIG" "$ROOT" <<'PY'
import json
import os
import subprocess
import sys

cliff, config, root = sys.argv[1], sys.argv[2], sys.argv[3]
# public (mirrored) components
prefixes = [meta["prefix"] for meta in json.load(
    open(os.path.join(root, "tools/copybara/components.json"))).values()]
# private, monorepo-only independent crates (not mirrored); "public OR private" per the ask
prefixes += [
    "core/hop-endpoint",
    "core/hop-sim",
    "services/hop-billingd",
    "services/hop-telemetryd",
    "services/hop-accountd",
]
for prefix in prefixes:
    if not os.path.isdir(os.path.join(root, prefix)):
        continue
    out = os.path.join(root, prefix, "CHANGELOG.md")
    # --include-path scopes the log to commits that touched this lib's subtree.
    subprocess.run(
        [cliff, "--config", config, "--repository", root,
         "--include-path", f"{prefix}/**", "--output", out],
        check=True,
    )
    print(f"changelog: {prefix}/CHANGELOG.md")
PY
echo "changelog: done"
