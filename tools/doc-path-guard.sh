#!/usr/bin/env bash
# tools/doc-path-guard.sh
# CI guard enforcing that:
# 1. Backtick-quoted file and directory paths cited in documentation and CLAUDE.md
#    files resolve to real paths in the repository, unless explicitly qualified
#    with an external repository (for example hopmesh/platform/... or hopmesh/internal/...).
# 2. Wire version numbers and corpus filenames cited in documentation (such as
#    MECHANISMS.md and SECURITY.md) match the active BUNDLE_VERSION in bundle.rs.
# 3. CI job counts stated in CLAUDE.md match .github/workflows/ci.yml (CLAIM-015).
# 4. Pull request citations in documentation match existing PRs in hopmesh/hop
#    or are explicitly qualified with a historical repository (PROC-015).
#
# Self-tested by tools/doc-path-guard.test.sh.

set -euo pipefail

ROOT="${DOC_GUARD_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT"

fail=0
err() {
  echo "::error:: doc-path-guard: $*" >&2
  fail=1
}

# --- Check 1: BUNDLE_VERSION and corpus consistency in prose (CLAIM-014) ---

BUNDLE_RS="core/hop-core/src/bundle.rs"
if [ ! -f "$BUNDLE_RS" ]; then
  err "missing bundle.rs at $BUNDLE_RS"
else
  BUNDLE_VER="$(grep -Eo 'pub const BUNDLE_VERSION: u8 = [0-9]+;' "$BUNDLE_RS" | grep -Eo '[0-9]+' | tail -n 1 || true)"
  if [ -z "$BUNDLE_VER" ]; then
    err "could not extract BUNDLE_VERSION from $BUNDLE_RS"
  else
    # Check MECHANISMS.md stated version
    if [ -f "MECHANISMS.md" ]; then
      MECH_MATCH="$(grep -Eo 'BUNDLE_VERSION.*currently [0-9]+' MECHANISMS.md || true)"
      if [ -n "$MECH_MATCH" ]; then
        MECH_VER="$(printf '%s\n' "$MECH_MATCH" | grep -Eo '[0-9]+' | tail -n 1)"
        if [ "$MECH_VER" != "$BUNDLE_VER" ]; then
          err "MECHANISMS.md cites stale BUNDLE_VERSION ($MECH_VER; bundle.rs is $BUNDLE_VER)"
        fi
      fi
    fi

    # Check SECURITY.md corpus filename
    if [ -f "SECURITY.md" ]; then
      SEC_MATCH="$(grep -Eo 'bundle-v[0-9]+\.json' SECURITY.md || true)"
      if [ -n "$SEC_MATCH" ]; then
        SEC_VER="$(printf '%s\n' "$SEC_MATCH" | grep -Eo '[0-9]+' | head -n 1)"
        if [ "$SEC_VER" != "$BUNDLE_VER" ]; then
          err "SECURITY.md cites stale corpus bundle-v$SEC_VER.json (current BUNDLE_VERSION is $BUNDLE_VER)"
        fi
      fi
    fi
  fi
fi


# --- Check 2: CI job and gate dependency counts in CLAUDE.md (CLAIM-015) ---

CI_YML=".github/workflows/ci.yml"
if [ -f "$CI_YML" ] && [ -f "CLAUDE.md" ]; then
  ci_check_out="$(python3 - "$CI_YML" "CLAUDE.md" <<'PY' 2>&1
import sys, re

ci_path, claude_path = sys.argv[1:3]
with open(ci_path, encoding='utf-8') as f:
    ci_lines = f.read().splitlines()

in_jobs = False
jobs = []
gate_lines = []
in_gate = False

for line in ci_lines:
    if re.fullmatch(r"jobs:\s*", line):
        in_jobs = True
        continue
    if not in_jobs or line.lstrip().startswith("#"):
        continue
    m = re.match(r"^  (\S[^:]*):(\s|$)", line)
    if m:
        job_name = m.group(1)
        jobs.append(job_name)
        in_gate = (job_name == "gate")
    elif in_gate:
        gate_lines.append(line)

total_jobs = len(jobs)

gate_needs = set()
for idx, line in enumerate(gate_lines):
    m = re.match(r"^\s*needs:\s*(.*)$", line)
    if m:
        inline = m.group(1).split("#", 1)[0].strip()
        if inline.startswith("["):
            gate_needs.update(re.findall(r"[A-Za-z0-9_-]+", inline))
        elif inline:
            gate_needs.add(inline)
        else:
            for nested in gate_lines[idx+1:]:
                item = re.match(r"^\s*-\s+([A-Za-z0-9_-]+)\s*$", nested)
                if not item:
                    break
                gate_needs.add(item.group(1))
        break

gate_deps = len(gate_needs)

with open(claude_path, encoding='utf-8') as f:
    claude_text = f.read()

m_total = re.search(r"is the gate:\s*([0-9]+)\s*jobs", claude_text)
m_deps = re.search(r"depends on the other\s*([0-9]+)", claude_text)

errors = []
if m_total:
    claimed_total = int(m_total.group(1))
    if claimed_total != total_jobs:
        errors.append(f"CLAUDE.md cites stale CI job count ({claimed_total} jobs; ci.yml defines {total_jobs})")

if m_deps:
    claimed_deps = int(m_deps.group(1))
    if claimed_deps != gate_deps:
        errors.append(f"CLAUDE.md cites stale CI gate dependency count ({claimed_deps}; ci.yml gate depends on {gate_deps})")

if errors:
    for e in errors:
        print(f"{e}", file=sys.stderr)
    sys.exit(1)
PY
)" || {
    while IFS= read -r line; do
      [ -n "$line" ] && err "$line"
    done <<< "$ci_check_out"
  }
fi
# --- Check 2: Path existence in documentation and CLAUDE.md files (CLAIM-010) ---

DOC_SCAN_TARGETS=(
  "CLAUDE.md"
  "CONTRIBUTING.md"
  "services/CLAUDE.md"
  "tools/CLAUDE.md"
  "SECURITY.md"
  "MECHANISMS.md"
)

# Find all markdown files in docs/, excluding repo-catalog.md which explicitly lists moved/retired paths
if [ -d "docs" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "docs/repo-catalog.md" ] && continue
    DOC_SCAN_TARGETS+=("$f")
  done < <(find docs -type f -name "*.md" | sort)
fi

is_exempt_target() {
  local p="$1"
  # External repository prefixes
  case "$p" in
    hopmesh/*|github.com/*|crates.io/*|crates/*) return 0 ;;
    # Well-known external or virtual paths
    http://*|https://*|mailto:*|git@*|file://*) return 0 ;;
    # Git references
    origin/*|refs/*|HEAD/*) return 0 ;;
    # Wildcards, regexes, and template variables
    *\**|*\{*|*\}*|*\<*|*\>*|*\$*|*@*|*\.\.\.*) return 0 ;;
    # Slash-separated slash alternatives or method lists (e.g. A/B/C)
    */*/*/*/*)
      # More than 3 slashes without file extension is usually an enum/method list
      if [[ ! "$p" =~ \.[a-zA-Z0-9]+$ ]]; then
        return 0
      fi
      ;;
    # Common URL endpoints or web routes
    /*|\./*|../*|~/*) return 0 ;;
    # MIME types and config keys
    application/*|text/*|audio/*|video/*|image/*) return 0 ;;
    # Internal audit corpus or design paths
    audits/*|business/*) return 0 ;;
    # Test fixtures or example pseudocode paths
    sample/*|example/*|my/*|your/*) return 0 ;;
    # Standalone command or flag patterns
    cargo/*|npm/*|git/*) return 0 ;;
    # Well-known third-party GitHub Action / dependency namespaces
    softprops/*|actions/*) return 0 ;;
    # Package-internal relative paths in platform-specific guides
    Frameworks/*|Sources/*|HopDriver/*|HopDemoKit/*|lib/pod/*|native/*|apple/*|android/*|*/Frameworks/*|*/include/hop.h) return 0 ;;
    */build/*|build/*|*/*-artifacts-public.pem) return 0 ;;
  esac

  # Slash alternatives like put/get/remove or encrypt/decrypt
  if [[ "$p" =~ ^[a-z_]+(/[a-z_]+)+$ ]] && [ ! -d "${p%%/*}" ]; then
    return 0
  fi
  # PascalCase slash alternatives like HttpRequest/HttpResponse
  if [[ "$p" =~ ^[A-Z][a-zA-Z0-9]+(/[A-Z][a-zA-Z0-9]+)+$ ]] && [ ! -d "${p%%/*}" ]; then
    return 0
  fi

  return 1
}

# Scan each file for backtick-quoted relative paths
for doc in "${DOC_SCAN_TARGETS[@]}"; do
  [ -f "$doc" ] || continue

  while IFS= read -r raw_path; do
    [ -z "$raw_path" ] && continue

    # Strip line number / anchor suffixes: :123, :123-456, :123,456
    clean_path="$(printf '%s\n' "$raw_path" | sed -E 's/:[0-9]+([-,][0-9]+)*$//')"
    # Strip any trailing punctuation
    clean_path="$(printf '%s\n' "$clean_path" | sed -E 's/[.,;!?)]+$//')"

    # Check if exempt
    if is_exempt_target "$clean_path"; then
      continue
    fi

    # Only inspect paths that look like relative repository paths (containing / and valid path chars)
    if [[ "$clean_path" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+$ ]]; then
      if [ ! -e "$clean_path" ]; then
        err "$doc cites nonexistent path '$raw_path'"
      fi
    fi
  done < <(grep -oE '`[^`]+`' "$doc" | tr -d '`' | grep '/' || true)
done

# --- Check 4: Pull request citation validity in documentation (PROC-015) ---

MAX_KNOWN_PR="${DOC_GUARD_MAX_PR:-130}"
pr_check_out="$(python3 - "$MAX_KNOWN_PR" "${DOC_SCAN_TARGETS[@]}" <<'PY' 2>&1
import sys, re

max_pr = int(sys.argv[1]) if len(sys.argv) > 1 else 130
targets = sys.argv[2:]

fail = 0
for target in targets:
    try:
        with open(target, "r", encoding="utf-8") as f:
            for lno, line in enumerate(f, 1):
                if re.search(r"(hopmesh/monorepo|hopmesh/internal|hopmesh/platform|[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+|historical|monorepo)", line):
                    continue
                clean = re.sub(r"&#[0-9]+;", "", line)
                for m in re.finditer(r"(?:^|[^a-zA-Z0-9_&])(?:PR\s*#?|pull request\s*#?|#)([0-9]+)\b", clean, re.IGNORECASE):
                    num = int(m.group(1))
                    if num > max_pr:
                        print(f"{target}:{lno} cites unqualified pull request #{num} above highest known PR {max_pr} (qualify with repository, e.g. hopmesh/monorepo#{num})")
                        fail += 1
    except Exception:
        pass
if fail:
    sys.exit(1)
PY
)" || {
  while IFS= read -r line; do
    [ -n "$line" ] && err "$line"
  done <<< "$pr_check_out"
}
if [ "$fail" -ne 0 ]; then
  echo "doc-path-guard: FAILED" >&2
  exit 1
fi

echo "doc-path-guard: OK (all cited paths and PRs exist and prose versions match)"
