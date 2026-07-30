#!/usr/bin/env bash
# Every job in .github/workflows/ci.yml must be accounted for in tools/local-ci-mirror.sh's
# CI_COVERAGE table, as full, partial or none, with a reason. A job declared `full` must additionally
# be BACKED: every gradle task and every cargo invocation that job runs in ci.yml has to be executed by
# the mirror (directly, or by an in-repo script the mirror calls).
#
# The second half exists because declaring `full` was free. The android entry said "full" while the
# five per-module JaCoCo coverage-verification tasks ci.yml gates on were never run locally, so a green
# local verdict claimed a scope it had not executed, which is the same defect one level up.
#
# The pre-push script used to call itself "the local mirror of what CI actually runs" while seven
# gating jobs had no local counterpart at all and four more were only partly reproduced. Nothing tied
# the two files together, so every job added to CI silently widened the gap between what the script
# checked and what its name promised. This guard is that tie: add a job to ci.yml without an entry in
# the table and CI reddens here, which forces the choice between running it locally and naming it as
# unchecked. It does NOT assert that the local script runs anything; it asserts the script cannot
# claim a scope it has not declared.
#
# Usage: tools/local-ci-mirror-coverage.sh [CI_YAML] [MIRROR_SH]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CI="${1:-$ROOT/.github/workflows/ci.yml}"
MIRROR="${2:-$ROOT/tools/local-ci-mirror.sh}"

for required in "$CI" "$MIRROR"; do
  if [ ! -f "$required" ]; then
    echo "::error::local-ci-mirror coverage: missing $required"
    exit 1
  fi
done

# ci.yml job ids: the two-space-indented keys under `jobs:`.
ci_jobs="$(awk '
  /^jobs:/ { in_jobs = 1; next }
  /^[a-zA-Z]/ { in_jobs = 0 }
  in_jobs && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {
    line = $0
    sub(/^  /, "", line)
    sub(/:[[:space:]]*$/, "", line)
    print line
  }
' "$CI" | sort)"

# CI_COVERAGE entries: "job|level|reason", one per line inside the array literal.
covered="$(awk '
  /^CI_COVERAGE=\(/ { in_table = 1; next }
  in_table && /^\)/ { in_table = 0 }
  in_table && /^  "/ {
    line = $0
    sub(/^  "/, "", line)
    print line
  }
' "$MIRROR")"

fail=0

if [ -z "$ci_jobs" ]; then
  echo "::error::local-ci-mirror coverage: no jobs parsed from $CI"
  exit 1
fi
if [ -z "$covered" ]; then
  echo "::error::local-ci-mirror coverage: no CI_COVERAGE table parsed from $MIRROR"
  exit 1
fi

covered_jobs="$(printf '%s\n' "$covered" | cut -d'|' -f1 | sort)"

missing="$(comm -23 <(printf '%s\n' "$ci_jobs") <(printf '%s\n' "$covered_jobs"))"
if [ -n "$missing" ]; then
  echo "::error::local-ci-mirror coverage: ci.yml jobs with no CI_COVERAGE entry:"
  printf '  %s\n' $missing
  fail=1
fi

stale="$(comm -13 <(printf '%s\n' "$ci_jobs") <(printf '%s\n' "$covered_jobs"))"
if [ -n "$stale" ]; then
  echo "::error::local-ci-mirror coverage: CI_COVERAGE names jobs that no longer exist in ci.yml:"
  printf '  %s\n' $stale
  fail=1
fi

duplicate="$(printf '%s\n' "$covered_jobs" | uniq -d)"
if [ -n "$duplicate" ]; then
  echo "::error::local-ci-mirror coverage: duplicate CI_COVERAGE entries:"
  printf '  %s\n' $duplicate
  fail=1
fi

while IFS='|' read -r job level reason; do
  [ -n "$job" ] || continue
  case "$level" in
    full | partial | none) ;;
    *)
      echo "::error::local-ci-mirror coverage: $job has an unknown coverage level '$level'"
      fail=1
      ;;
  esac
  reason="${reason%\"}"
  if [ "${#reason}" -lt 20 ]; then
    echo "::error::local-ci-mirror coverage: $job has no real explanation of what is or is not run"
    fail=1
  fi
done <<EOF
$covered
EOF

# A `full` entry has to be backed by the commands the mirror actually runs. Gradle tasks are compared by
# name (`:module:task` and every jacoco* task); cargo invocations by (subcommand, package, feature set),
# which is what decides whether a feature-gated region is compiled at all. The haystack is the mirror
# plus every in-repo script it invokes, because `bash tools/build-aar.sh` really does run those cargo
# commands; a package named by a shell variable in such a script matches any package.
if ! python3 - "$CI" "$MIRROR" "$ROOT" <<'PY'; then
import re
import shlex
import sys
from pathlib import Path

ci_path, mirror_path = Path(sys.argv[1]), Path(sys.argv[2])
ci_text = ci_path.read_text(encoding="utf-8")
mirror_text = mirror_path.read_text(encoding="utf-8")
# The repo root, NOT the mirror's parent: the self-test feeds mutated copies from a temp directory and
# the invoked scripts must still resolve, or a copy would silently lose half its haystack.
root = Path(sys.argv[3])

CARGO_SUBCOMMANDS = {"fmt", "clippy", "test", "build", "run"}
GRADLE_TASK = re.compile(r"(?<![\w:]):[A-Za-z0-9_-]+:[A-Za-z0-9_]+|\bjacoco[A-Za-z0-9_]*\b")


def uncommented(text):
    """Drop comment lines. A ci.yml comment quoting a command is prose, not a step."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def cargo_signatures(text):
    """{(subcommand, package, features)}; package '*' means 'any' (a shell variable in a script)."""
    found = set()
    for line in text.splitlines():
        for fragment in re.findall(r"\bcargo\s+[^\n&|;]+", line):
            try:
                words = shlex.split(fragment, posix=False)
            except ValueError:
                continue
            words = [w.strip("\"'") for w in words]
            if len(words) < 2 or words[1] not in CARGO_SUBCOMMANDS:
                continue
            package = ""
            features = ""
            for index, word in enumerate(words):
                if word in ("-p", "--package") and index + 1 < len(words):
                    package = words[index + 1]
                if word == "--features" and index + 1 < len(words):
                    features = ",".join(sorted(words[index + 1].split(",")))
            if "$" in package:
                package = "*"
            found.add((words[1], package, features))
    return found


def gradle_tasks(text):
    return {task for task in GRADLE_TASK.findall(text)}


def jobs(text):
    match = re.search(r"(?ms)^jobs:\n(.*)\Z", text)
    if match is None:
        return {}
    return {
        job.group(1): job.group(2)
        for job in re.finditer(
            r"(?ms)^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", match.group(1)
        )
    }


full = [
    line.split("|")[0].strip(' "')
    for line in re.findall(r'(?m)^  "([^"]+)"$', mirror_text)
    if len(line.split("|")) > 1 and line.split("|")[1] == "full"
]

# The mirror plus the in-repo scripts it invokes: those commands do run on a mirror run.
haystack = uncommented(mirror_text)
for candidate in sorted(set(re.findall(r"[\w./-]+\.(?:sh|mjs|py)", mirror_text))):
    script = root / candidate
    if script.is_file():
        haystack += "\n" + uncommented(script.read_text(encoding="utf-8", errors="replace"))

mirror_cargo = cargo_signatures(haystack)
mirror_gradle = gradle_tasks(haystack)
ci_jobs = jobs(ci_text)

problems = []
for job in full:
    body = ci_jobs.get(job)
    if body is None:
        continue  # the job-table check above already reports a stale entry
    body = uncommented(body)
    for signature in sorted(cargo_signatures(body)):
        subcommand, package, features = signature
        if signature in mirror_cargo or (subcommand, "*", features) in mirror_cargo:
            continue
        problems.append(
            f"{job} is declared full but the mirror never runs cargo {subcommand}"
            + (f" -p {package}" if package else "")
            + (f" --features {features}" if features else "")
        )
    for task in sorted(gradle_tasks(body) - mirror_gradle):
        problems.append(f"{job} is declared full but the mirror never runs the gradle task {task}")

if problems:
    print("::error::local-ci-mirror coverage: a `full` claim is not backed by what the mirror runs:")
    for problem in problems:
        print(f"  {problem}")
    raise SystemExit(1)
PY
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "local-ci-mirror coverage OK: $(printf '%s\n' "$ci_jobs" | wc -l | tr -d ' ') ci.yml jobs, all declared"
