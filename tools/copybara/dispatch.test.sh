#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
dispatch="$root/tools/copybara/dispatch.py"

python3 - "$root" <<'PY'
import ast
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
components = json.loads((root / "tools/copybara/components.json").read_text())
workflow = (root / ".github/workflows/sync-components.yml").read_text()
match = re.search(r"component:\n.*?options:\n(?P<options>(?:\s+- [^\n]+\n)+)", workflow, re.S)
if not match:
    raise SystemExit("component choice options not found")
options = [line.split("-", 1)[1].strip() for line in match.group("options").splitlines()]
if options != list(components):
    raise SystemExit(f"workflow choices drifted: {options!r}")

sky = (root / "tools/copybara/copy.bara.sky").read_text()
if re.search(r"(?<!\$)\$\{SRCDIR\}", sky) or sky.count("$${SRCDIR}") != 4:
    raise SystemExit("Copybara cgo paths do not escape literal template dollars")
block = re.search(r"COMPONENTS = \[(.*?)\n\]", sky, re.S)
if not block:
    raise SystemExit("Copybara component list not found")
pairs = re.findall(r"\((\"[^\"]+\"), (\"[^\"]+\")\)", block.group(1))
copybara = {ast.literal_eval(name): ast.literal_eval(prefix) for prefix, name in pairs}
expected = {name: entry["prefix"] for name, entry in components.items()}
if copybara != expected:
    raise SystemExit(f"Copybara component list drifted: {copybara!r}")
registrations = {
    name: prefix
    for prefix, name in re.findall(r'^\s*_register\("([^"]+)", "([^"]+)"\),$', sky, re.M)
}
if registrations != expected:
    raise SystemExit(f"Copybara workflow registrations drifted: {registrations!r}")

elixir_transform_markers = (
    'ELIXIR_LOCK = "tools/copybara/elixir-native-Cargo.lock"',
    'ELIXIR_HOP_PATH_DEP = """hop = { path = "../../../../core/hop" }',
    'ELIXIR_HOP_VENDOR_DEP = \'hop = { workspace = true }\\n\'',
    'core.move(ELIXIR_LOCK, "native/Cargo.lock")',
    'import_excludes.extend(["native/Cargo.toml", "native/Cargo.lock", "native/vendor/**"])',
    "export_transforms.extend(_elixir_vendor_export())",
    "import_transforms.append(_elixir_vendor_import())",
)
for marker in elixir_transform_markers:
    if sky.count(marker) != 1:
        raise SystemExit(f"Copybara Elixir dependency transform drifted: {marker}")

export_helper = (root / "tools/package-export-smoke.py").read_text()
for marker in (
    'ELIXIR_HOP_PATH_DEP = \'hop = { path = "../../../../core/hop" }\'',
    'ELIXIR_HOP_VENDOR_DEP = \'hop = { workspace = true }\'',
    '\"tools/copybara/elixir-native-Cargo.lock\", \"native/Cargo.lock\"',
):
    if export_helper.count(marker) != 1:
        raise SystemExit(f"exact export Elixir dependency transform drifted: {marker}")
PY

while IFS= read -r component; do
  for direction in export import; do
    init=false
    [ "$direction" = export ] && init=true
    SYNC_COMPONENT="$component" SYNC_DIRECTION="$direction" SYNC_INIT_HISTORY="$init" \
      python3 "$dispatch" --json >/dev/null
  done
done < <(python3 "$dispatch" --list)

# shellcheck disable=SC2016 # This is a literal injection payload, not a command substitution.
malicious=(
  '../hop-core'
  'hop-core;id'
  'hop-core_export'
  '$(id)'
  'hop-core/../../etc'
  $'hop-core\nworkflow=evil'
  'olivr/copybara:latest'
)
for value in "${malicious[@]}"; do
  if SYNC_COMPONENT="$value" SYNC_DIRECTION=export SYNC_INIT_HISTORY=false \
      python3 "$dispatch" --json >/dev/null 2>&1; then
    echo "dispatch accepted malicious component: $value" >&2
    exit 1
  fi
done

if SYNC_COMPONENT=hop-core SYNC_DIRECTION='export;id' SYNC_INIT_HISTORY=false \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted malicious direction" >&2
  exit 1
fi
if SYNC_COMPONENT=hop-core SYNC_DIRECTION=import SYNC_INIT_HISTORY=true \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted init_history on import" >&2
  exit 1
fi

# export_pr requires a valid pr_number and prepends it to the Copybara args (before the flags).
opts="$(SYNC_COMPONENT=hop-core SYNC_DIRECTION=export_pr SYNC_INIT_HISTORY=false SYNC_PR_NUMBER=292 \
  python3 "$dispatch" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["copybara_options"])')"
if [ "$opts" != "292 --ignore-noop --force" ]; then
  echo "export_pr copybara_options drifted: $opts" >&2
  exit 1
fi
# export_pr with no pr_number is rejected.
if SYNC_COMPONENT=hop-core SYNC_DIRECTION=export_pr SYNC_INIT_HISTORY=false SYNC_PR_NUMBER="" \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted export_pr with no pr_number" >&2
  exit 1
fi
# A non-numeric / injection pr_number is rejected.
for bad in 'abc' '1;id' '$(id)' '-1' '0' '../7' '12345678'; do
  if SYNC_COMPONENT=hop-core SYNC_DIRECTION=export_pr SYNC_INIT_HISTORY=false SYNC_PR_NUMBER="$bad" \
      python3 "$dispatch" --json >/dev/null 2>&1; then
    echo "dispatch accepted malicious pr_number: $bad" >&2
    exit 1
  fi
done
# pr_number is rejected on the non-PR directions.
if SYNC_COMPONENT=hop-core SYNC_DIRECTION=export SYNC_INIT_HISTORY=false SYNC_PR_NUMBER=292 \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted pr_number on export" >&2
  exit 1
fi

echo "copybara dispatch tests passed"
