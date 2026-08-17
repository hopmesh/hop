#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import tempfile
from pathlib import Path
import sys

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("pages", root / "tools/pages-path-guard.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

metadata = {
    "packages": [
        {
            "name": "hop-wasm",
            "manifest_path": str(root / "core/hop-wasm/Cargo.toml"),
            "dependencies": [{"name": "hop-core", "source": None}],
        },
        {
            "name": "hop-core",
            "manifest_path": str(root / "core/hop-core/Cargo.toml"),
            "dependencies": [{"name": "serde", "source": "registry"}],
        },
    ]
}
assert module.transitive_workspace_crates(root, metadata) == {
    "core/hop-wasm/**",
    "core/hop-core/**",
}

pages_workflow = (root / ".github/workflows/pages.yml").read_text(encoding="utf-8")
module.check_authority(pages_workflow)
# The two repository names swapped roles in the hopmesh/hop cutover, so this substitution reverses
# direction: hop used to be the stale pre-rename name and monorepo the canonical one, and it is now the
# other way round. A blanket find-and-replace turns this line into a no-op that asserts nothing.
#
# Swap ONLY the shell authority line, not every occurrence of the name. A wholesale swap also changes
# the two API URLs, so the guard's main_api count fires and the case passes without the repository
# check ever being consulted: neutering that check left this test green. Isolating it means this case
# fails if, and only if, the repository authority check stops working.
try:
    module.check_authority(
        pages_workflow.replace(
            'test "$REPOSITORY" = hopmesh/hop', 'test "$REPOSITORY" = hopmesh/monorepo'
        )
    )
except module.PagesPathError:
    pass
else:
    raise AssertionError("archived Pages repository was accepted")
try:
    module.check_authority(pages_workflow.replace("          include-hidden-files: true\n", ""))
except module.PagesPathError:
    pass
else:
    raise AssertionError("Pages artifact without hidden provenance files was accepted")

with tempfile.TemporaryDirectory() as temp:
    workflow = Path(temp) / "pages.yml"
    workflow.write_text(
        "on:\n  push:\n    paths:\n      - 'sim/**'\n      - 'learn/**'\njobs: {}\n",
        encoding="utf-8",
    )
    assert module.workflow_paths(workflow) == ["sim/**", "learn/**"]
    workflow.write_text(
        "on:\n  push:\n    paths:\n      - 'sim/**'\n      - 'sim/**'\njobs: {}\n",
        encoding="utf-8",
    )
    try:
        module.workflow_paths(workflow)
    except module.PagesPathError:
        pass
    else:
        raise AssertionError("duplicate Pages path was accepted")

print("Pages path guard tests passed")
PY
