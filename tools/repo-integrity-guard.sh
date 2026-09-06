#!/usr/bin/env bash
# repo-integrity-guard.sh (legal-01): fail the build if a critical tracked file is empty or
# missing. A prior remediation shipped a 0-byte LICENSE.md TWICE (restored in one PR, silently
# re-emptied by the next squash-merge of an out-of-date branch) and all CI jobs stayed green,
# because none of them asserted that a tracked content file actually has content. This guard
# closes that gap: it walks a small allowlist of files that must never be empty and fails loudly
# if any is missing or zero-length. Runs in CI (docs-tokens job) and is runnable locally.
#
# Usage:  tools/repo-integrity-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# Tracked files that must always carry content (paths relative to repo root). There IS a repo-wide
# root LICENSE.md now (Apache-2.0), covering the 812 tracked files that sit outside every component
# directory; components that carry their own LICENSE.md are licensed by it instead. The root copy is
# in the Apache tier like any other non-services/ licence and is checked by the same dynamic pass
# below. These are the load-bearing docs + the C ABI header.
#
# Each entry is "path|min_bytes|marker". `-s` (size > 0) alone is too weak: the regression this guard
# exists for could re-land as a 1-byte or wrong-content file and still pass a bare -s check. So we also
# require a per-file minimum length AND, where there's a stable signature line, that the file still
# contains it (an FSL license truncated to its title, or a header stripped of its ABI define, is just
# as broken as a 0-byte one). Keep floors comfortably below real sizes so honest edits don't trip them.
CRITICAL=(
  # The root licence is the most load-bearing file here: it is the ONLY thing granting rights over the
  # 812 tracked files that carry no LICENSE.md of their own. The dynamic pass below checks its tier and
  # byte-identity; this entry additionally pins it against going missing, which the dynamic pass cannot
  # catch (it iterates whatever it finds, so a deleted root licence is simply one fewer file).
  "LICENSE.md|1500|January 2004"
  "README.md|200|"
  "DESIGN.md|1000|"
  "MECHANISMS.md|1000|"
  "sdk/hop.h|2000|HOP_ABI_VERSION"
)

fail=0

# Per-component licenses (legal-01), TWO TIERS:
#   - services/*  carries FSL-1.1-ALv2: the hosted service layer is the thing a cloud provider could
#     resell, so the non-compete belongs here (relayd, endpoint, gateway, telemetryd, accountd, billingd).
#   - EVERY other component (core, sdk, bearers, drivers, examples) carries Apache-2.0, permissive so
#     that the protocol and everything people embed or integrate carries no adoption friction.
# The tiers were INVERTED on 2026-07-31. FSL previously sat on core/, which had it backwards in both
# directions: every SDK binds libhop, so a legal review walked the dependency tree, hit FSL, and stopped,
# meaning the Apache label on the wrappers was close to cosmetic and the adoption tax was paid anyway;
# meanwhile hop-relayd was permissive, so the one component someone could actually stand up as a
# competing managed service carried no restriction at all. The restriction was on the funnel instead of
# on the moat. Revenue is metered infrastructure (deliveries, egress, mailbox), which wants maximum node
# count and a defended service layer, so the licenses now follow the money.
# Within EACH tier every LICENSE.md must be byte-identical; each must be above the floor and carry its
# own tier's signature line. The failure modes this catches: a copy going 0-byte/truncated (the wasm-pack
# self-copy regression this guard exists for), a copy drifting from the rest of its tier, or a copy
# wearing the WRONG tier's license (a services/ file that says Apache, or a non-services file that says
# FSL). The Apache marker is the header date "January 2004", NOT "Apache License": the FSL text references
# the Apache License as its future license, so "Apache License" is not unique to the Apache tier.
fsl_canon=""
apache_canon=""
lic_count=0
while IFS= read -r lf; do
  lic_count=$((lic_count + 1))
  bytes="$(wc -c < "$lf" | tr -d ' ')"
  if [ "$bytes" -lt 1500 ]; then
    echo "repo-integrity-guard: TRUNCATED $lf ($bytes bytes < 1500 floor) - a gutted license" >&2
    fail=1
    continue
  fi
  case "$lf" in
    ./services/*)  # FSL-1.1-ALv2 tier (the hosted service layer)
      if ! grep -qF -- "Functional Source License" "$lf"; then
        echo "repo-integrity-guard: CONTENT $lf under services/ must be FSL-1.1-ALv2 (its signature line is missing)" >&2
        fail=1
        continue
      fi
      if [ -z "$fsl_canon" ]; then
        fsl_canon="$lf"
      elif ! cmp -s "$lf" "$fsl_canon"; then
        echo "repo-integrity-guard: DRIFT $lf differs from $fsl_canon (services/ FSL licenses must be identical)" >&2
        fail=1
      fi
      ;;
    *)         # Apache-2.0 tier (everything outside services/)
      if ! grep -qF -- "January 2004" "$lf"; then
        echo "repo-integrity-guard: CONTENT $lf outside services/ must be Apache-2.0 (its header is missing)" >&2
        fail=1
        continue
      fi
      if [ -z "$apache_canon" ]; then
        apache_canon="$lf"
      elif ! cmp -s "$lf" "$apache_canon"; then
        echo "repo-integrity-guard: DRIFT $lf differs from $apache_canon (Apache licenses must be identical)" >&2
        fail=1
      fi
      ;;
  esac
done < <(find . -name LICENSE.md \
  -not -path '*/node_modules/*' -not -path '*/target/*' -not -path '*/.git/*' \
  -not -path '*/.claude/*' -not -path '*/.build*' -not -path '*/vendor/*' 2>/dev/null | sort)
if [ "$lic_count" -eq 0 ]; then
  echo "repo-integrity-guard: MISSING no component LICENSE.md found at all" >&2
  fail=1
fi
# CLAIM-017: No SDK README may claim hop-core is FSL-1.1-ALv2.
sdk_readme_count=0
while IFS= read -r readme; do
  case "$readme" in
    ./sdk/*|sdk/*)
      sdk_readme_count=$((sdk_readme_count + 1))
      if grep -qiF "FSL-1.1-ALv2" "$readme"; then
        echo "repo-integrity-guard: CONTENT $readme claims FSL-1.1-ALv2 (SDKs and hop-core are Apache-2.0)" >&2
        fail=1
      fi
      ;;
  esac
done < <(find . -name README.md \
  -not -path '*/node_modules/*' -not -path '*/target/*' -not -path '*/.git/*' \
  -not -path '*/.claude/*' -not -path '*/.build*' -not -path '*/vendor/*' 2>/dev/null | sort)
if [ "$sdk_readme_count" -eq 0 ]; then
  echo "repo-integrity-guard: MISSING no SDK README.md found" >&2
  fail=1
fi
for spec in "${CRITICAL[@]}"; do
  f="${spec%%|*}"
  rest="${spec#*|}"
  min="${rest%%|*}"
  marker="${rest#*|}"
  if [ ! -f "$f" ]; then
    echo "repo-integrity-guard: MISSING $f" >&2
    fail=1
    continue
  fi
  if [ ! -s "$f" ]; then
    echo "repo-integrity-guard: EMPTY $f (0 bytes) - a critical tracked file lost its content" >&2
    fail=1
    continue
  fi
  bytes="$(wc -c < "$f" | tr -d ' ')"
  if [ "$bytes" -lt "$min" ]; then
    echo "repo-integrity-guard: TRUNCATED $f ($bytes bytes < $min floor) - looks gutted, not edited" >&2
    fail=1
    continue
  fi
  if [ -n "$marker" ] && ! grep -qF -- "$marker" "$f"; then
    echo "repo-integrity-guard: CONTENT $f lost its signature line ('$marker' not found)" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "repo-integrity-guard: FAIL (a critical tracked file is missing, empty, truncated, or drifted)" >&2
  exit 1
fi
echo "repo-integrity-guard: OK (${#CRITICAL[@]} critical docs + $lic_count component LICENSE.md present, above floor, correct-tier signatures, identical within tier)"
