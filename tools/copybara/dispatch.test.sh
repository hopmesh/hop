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

# Every `needs.select.outputs.X` a job consumes must be declared in the select job's `outputs:` block,
# or it silently resolves to empty at runtime. This is exactly how import's PR ref would be lost: source_ref
# was emitted by the mapper and consumed by the job, but never surfaced as a select output.
select = re.search(r"^  select:\n(?P<body>(?: {4,}.*\n|\n)+)", workflow, re.M)
if not select:
    raise SystemExit("select job not found in workflow")
declared = set(re.findall(r"^      (\w+):\s*\$\{\{\s*steps\.map\.outputs\.\w+", select.group("body"), re.M))
consumed = set(re.findall(r"needs\.select\.outputs\.(\w+)", workflow))
missing = consumed - declared
if missing:
    raise SystemExit(f"select outputs consumed but not declared (resolve to empty): {sorted(missing)!r}")

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
    init=false; pr=""
    [ "$direction" = export ] && init=true
    [ "$direction" = import ] && pr=1
    SYNC_COMPONENT="$component" SYNC_DIRECTION="$direction" SYNC_INIT_HISTORY="$init" SYNC_PR_NUMBER="$pr" \
      python3 "$dispatch" --json >/dev/null
  done
done < <(python3 "$dispatch" --list)

# shellcheck disable=SC2016 # This is a literal injection payload, not a command substitution.
malicious=(
  '../hop-sdk-go'
  'hop-sdk-go;id'
  'hop-sdk-go_export'
  '$(id)'
  'hop-sdk-go/../../etc'
  $'hop-sdk-go\nworkflow=evil'
  'olivr/copybara:latest'
)
for value in "${malicious[@]}"; do
  if SYNC_COMPONENT="$value" SYNC_DIRECTION=export SYNC_INIT_HISTORY=false \
      python3 "$dispatch" --json >/dev/null 2>&1; then
    echo "dispatch accepted malicious component: $value" >&2
    exit 1
  fi
done

if SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION='export;id' SYNC_INIT_HISTORY=false \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted malicious direction" >&2
  exit 1
fi
if SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=import SYNC_INIT_HISTORY=true \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted init_history on import" >&2
  exit 1
fi

# import requires a valid pr_number, emitted as source_ref (NOT folded into options, which the olivr
# wrapper places first; source_ref is appended last, where the positional PR ref belongs).
json="$(SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=import SYNC_INIT_HISTORY=false SYNC_PR_NUMBER=292 \
  python3 "$dispatch" --json)"
opts="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["copybara_options"])')"
sref="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["source_ref"])')"
if [ "$opts" != "--ignore-noop --force" ] || [ "$sref" != "292" ]; then
  echo "import mapping drifted: options=$opts source_ref=$sref" >&2
  exit 1
fi
# export carries no source_ref.
sref_export="$(SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=export SYNC_INIT_HISTORY=false \
  python3 "$dispatch" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["source_ref"])')"
if [ -n "$sref_export" ]; then
  echo "export unexpectedly carries a source_ref: $sref_export" >&2
  exit 1
fi
# import with no pr_number is rejected.
if SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=import SYNC_INIT_HISTORY=false SYNC_PR_NUMBER="" \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted import with no pr_number" >&2
  exit 1
fi
# A non-numeric / injection pr_number is rejected.
for bad in 'abc' '1;id' '$(id)' '-1' '0' '../7' '12345678'; do
  if SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=import SYNC_INIT_HISTORY=false SYNC_PR_NUMBER="$bad" \
      python3 "$dispatch" --json >/dev/null 2>&1; then
    echo "dispatch accepted malicious pr_number: $bad" >&2
    exit 1
  fi
done
# pr_number is rejected on the non-PR directions.
if SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=export SYNC_INIT_HISTORY=false SYNC_PR_NUMBER=292 \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted pr_number on export" >&2
  exit 1
fi

# --- last_rev: the watermark override -------------------------------------------------------------
# The resolver is injected in these cases so the validation is tested without a network round trip,
# and so BOTH answers are covered: a SHA the canonical repository has, and one it does not.
python3 - "$root" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "tools/copybara"))
import dispatch

real = "a" * 40


def accepting(sha):
    return True


def rejecting(sha):
    return False


def expect_error(message, **kwargs):
    try:
        dispatch.select(**kwargs)
    except ValueError:
        return
    raise SystemExit(f"dispatch accepted {message}")


# Accepted: folded into the options string, in the position copybara expects, and nowhere else.
values = dispatch.select("hop-sdk-go", "export", "false", last_rev=real, resolver=accepting)
if values["copybara_options"] != f"--ignore-noop --force --last-rev {real}":
    raise SystemExit(f"last_rev not folded into options: {values['copybara_options']!r}")
if values["source_ref"]:
    raise SystemExit("last_rev must not leak into source_ref")

# Absent: the options string is exactly what it was before this option existed.
plain = dispatch.select("hop-sdk-go", "export", "false", resolver=accepting)
if plain["copybara_options"] != "--ignore-noop --force":
    raise SystemExit(f"options drifted without last_rev: {plain['copybara_options']!r}")

# A SHA the canonical repository does not have is the whole failure this option exists to clear, so
# forwarding one would just move the error into the privileged job.
expect_error(
    "a SHA absent from canonical",
    component="hop-sdk-go",
    direction="export",
    init_history="false",
    last_rev=real,
    resolver=rejecting,
)

# Shape: short SHAs, uppercase, refs, ranges and injection payloads are all rejected before resolution
# is even attempted (a permissive resolver here proves the format check is what rejects them).
for bad in (
    "a" * 39,
    "a" * 41,
    "A" * 40,
    "main",
    "HEAD",
    "origin/main",
    f"{'a' * 40}..{'b' * 40}",
    f"{'a' * 40} --force-message",
    f"{'a' * 40};id",
    f"$({'a' * 40})",
    "../" + "a" * 37,
    "",  # empty is not an error, but must not produce a --last-rev flag; asserted below
):
    if bad == "":
        continue
    expect_error(
        f"malformed last_rev {bad!r}",
        component="hop-sdk-go",
        direction="export",
        init_history="false",
        last_rev=bad,
        resolver=accepting,
    )

# Direction and mode: import has no watermark to override, and seeding a full history while resuming
# from a point are contradictory instructions.
expect_error(
    "last_rev on import",
    component="hop-sdk-go",
    direction="import",
    init_history="false",
    pr_number="7",
    last_rev=real,
    resolver=accepting,
)
expect_error(
    "last_rev together with init_history",
    component="hop-sdk-go",
    direction="export",
    init_history="true",
    last_rev=real,
    resolver=accepting,
)

# The real resolver must consult git rather than believing the caller. Both branches are driven here
# with a fake runner, so neither answer depends on the machine running the test.
class Result:
    def __init__(self, code):
        self.returncode = code


calls = []


def local_hit(argv, **kwargs):
    calls.append(argv)
    return Result(0)


def local_miss_remote_hit(argv, **kwargs):
    calls.append(argv)
    return Result(0) if argv[0:2] == ["git", "fetch"] else Result(1)


def both_miss(argv, **kwargs):
    calls.append(argv)
    return Result(1)


if not dispatch.resolves_in_canonical(real, run=local_hit):
    raise SystemExit("resolver rejected a commit present locally")
if calls[0][:3] != ["git", "cat-file", "-e"]:
    raise SystemExit(f"resolver did not ask git locally first: {calls[0]!r}")
calls.clear()
if not dispatch.resolves_in_canonical(real, run=local_miss_remote_hit):
    raise SystemExit("resolver rejected a commit the remote has (shallow checkout)")
if len(calls) != 2 or calls[1][:2] != ["git", "fetch"]:
    raise SystemExit(f"resolver did not fall back to the canonical remote: {calls!r}")
if dispatch.resolves_in_canonical(real, run=both_miss):
    raise SystemExit("resolver accepted a commit neither local nor remote")
PY

# End to end through the environment, with a resolver that cannot be injected: a SHA that does not
# exist anywhere must be refused by the real code path too.
if SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=export SYNC_INIT_HISTORY=false \
    SYNC_LAST_REV=0000000000000000000000000000000000000000 \
    python3 "$dispatch" --json >/dev/null 2>&1; then
  echo "dispatch accepted a nonexistent last_rev through the environment" >&2
  exit 1
fi
# And the option is absent from the emitted options when the input is empty.
opts_plain="$(SYNC_COMPONENT=hop-sdk-go SYNC_DIRECTION=export SYNC_INIT_HISTORY=false SYNC_LAST_REV="" \
  python3 "$dispatch" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["copybara_options"])')"
if [ "$opts_plain" != "--ignore-noop --force" ]; then
  echo "empty last_rev changed the options: $opts_plain" >&2
  exit 1
fi

echo "copybara dispatch tests passed"
