#!/usr/bin/env bash
# Freshness/drift check for the committed sim/pkg wasm build.
#
# sim/pkg/ is a committed BUILD OUTPUT of core/hop-wasm (see build-wasm.sh + PKG-PROVENANCE.md). If someone
# changes hop-core's wire format or the hop-wasm surface but forgets to rebuild, the committed sim would
# silently speak an OLDER protocol than the code beside it, and the homepage's "your browser is running
# the real Hop protocol" claim would quietly become false.
#
# This rebuilds core/hop-wasm --target web into a temp dir and compares the wasm-bindgen INTERFACE
# (hop_wasm.d.ts + the JS glue) against the committed copy. The interface is deterministic across builds
# (unlike the optimized .wasm binary, whose bytes vary run-to-run), so a diff here means the committed
# pkg is stale. Wire it into CI (pages or ci) so a drifted pkg fails the build, or run it locally before
# committing a core change. Exit 0 = fresh, 1 = drifted.
#
# sim-wasm-r2-02: the interface diff alone is BLIND to a same-API wire bump (a BUNDLE_VERSION change
# that keeps the same JS method surface produces an identical .d.ts/.js, so the committed .wasm could
# silently speak an older wire while this guard passes). To close that hole we also compare the wire
# version the committed pkg was stamped with (sim/pkg/.wire-version, written by build-wasm.sh) against
# the current source BUNDLE_VERSION, so a wire bump ALWAYS trips the guard even with an unchanged API.
#
# sim-wasm-r3-02: the interface/stamp compare above reads sim/pkg/.wire-version from the WORKING TREE.
# In CI, sim/build-wasm.sh runs first and OVERWRITES that stamp with a fresh value, so by the time this
# guard runs the committed drift is already masked (the guard compares a just-rebuilt stamp against
# source, which can never fail). Two mitigations, both local to this script so they don't depend on CI
# step ordering:
#   * `--committed-only` mode: skip the rebuild entirely and cross-check ONLY the wire stamp. A CI or
#     pre-commit step can run this BEFORE build-wasm.sh to guard the committed artifact.
#   * `--working-tree` mode: compare a fresh build and source stamp with the current generated files.
#     This supports local no-commit verification without weakening the default committed-object check.
#   * the wire-stamp cross-check reads the stamp from `git show HEAD:sim/pkg/.wire-version` when the tree
#     is a git repo, so a working-tree rebuild (build-wasm.sh re-stamp) cannot mask committed drift even
#     in full mode. It falls back to the working-tree file outside a git checkout.
set -uo pipefail

committed_only=0
working_tree=0
case "${1:-}" in
  "") ;;
  --committed-only) committed_only=1 ;;
  --working-tree) working_tree=1 ;;
  *) echo "usage: $0 [--committed-only|--working-tree]" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
crate="$here/../core/hop-wasm"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

drift=0

# Are we inside a git work tree? If so, the COMMITTED pkg blob (git show HEAD:...) is authoritative, and
# a committed pkg file that is MISSING from HEAD is itself DRIFT, not a reason to fall back to the
# working-tree copy (F-web-1). build-wasm.sh runs immediately before this guard in CI and overwrites the
# working tree, so a fallback would compare a fresh build against itself and report a false "fresh" even
# across a real wire bump. Only a genuine non-git context (a tarball export, no HEAD to read) may fall
# back to the working-tree files.
in_git=0
git -C "$here" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

if [ "$committed_only" -eq 0 ]; then
  command -v wasm-pack >/dev/null || { echo "error: wasm-pack not found (run core/hop-wasm/install-wasm-pack.sh)"; exit 1; }
  wasm-pack build "$crate" --mode no-install --target web --out-dir "$tmp" >/dev/null 2>&1
fi
if [ "$committed_only" -eq 0 ]; then
  for f in hop_wasm.d.ts hop_wasm.js hop_wasm_bg.wasm.d.ts; do
    # sim-wasm-r4-01 (F-3): diff the fresh build against the COMMITTED pkg blob (git show), NOT the
    # working-tree file. In CI, build-wasm.sh overwrites the working-tree sim/pkg immediately before
    # this guard runs, so a working-tree diff compares a fresh build against that same just-rebuilt
    # copy: vacuous, it can never detect a stale commit (proven in the pass-17 audit). Reading the
    # committed blob catches an interface/export change that was never rebuilt into the committed pkg,
    # regardless of step order. (This deterministic .d.ts/.js diff catches API/export drift; a wire
    # bump is caught by the .wire-version cross-check below; a purely-behavioral non-wire change lives
    # only in the excluded nondeterministic .wasm binary and is exercised by scenario-check on a fresh
    # build.) Falls back to the working tree ONLY outside a git checkout (a tarball export).
    committed_f="$tmp/committed-$f"
    if [ "$working_tree" -eq 1 ]; then
      cmp_target="$here/pkg/$f"
    elif [ "$in_git" -eq 1 ]; then
      if git -C "$here" show "HEAD:sim/pkg/$f" >"$committed_f" 2>/dev/null; then
        cmp_target="$committed_f"
      else
        # F-web-1: inside a git tree but the committed pkg file is not at HEAD. That is DRIFT (a
        # committed artifact went untracked, defeating the toolchain-less-clone guarantee), NOT a cue to
        # fall back to the freshly-rebuilt working tree, which would report a false "fresh".
        echo "DRIFT: sim/pkg/$f is not tracked at HEAD (a committed pkg file went untracked)"
        drift=1
        continue
      fi
    else
      cmp_target="$here/pkg/$f"
    fi
    if ! diff -q "$tmp/$f" "$cmp_target" >/dev/null 2>&1; then
      echo "DRIFT: sim/pkg/$f differs from a fresh core/hop-wasm build (committed pkg is stale)"
      drift=1
    fi
  done
fi

# Wire-version cross-check: the committed pkg must carry a .wire-version stamp that matches the source
# BUNDLE_VERSION. Catches a same-interface wire bump the .d.ts/.js diff cannot see.
#
# sim-wasm-r3-02: read the stamp from the committed blob (git show HEAD:...) rather than the working
# tree, so a build-wasm.sh re-stamp in the same CI run cannot mask committed drift. Fall back to the
# working-tree file ONLY when we are not inside a git checkout (a tarball export, say). Inside a git tree
# a stamp missing from HEAD is DRIFT, not a fallback trigger (F-web-1, same class as the interface diff).
# sim-wasm-r3-02: extract the number AFTER the `=`. The naive `... | grep -oE '[0-9]+' | head -1`
# matched the `8` in the `u8` type, not the version, so both this guard and build-wasm.sh stamped `8`
# and the cross-check compared 8 against 8 forever (masking real drift). Anchor on the `=` sign.
src_wire="$(grep -oE 'BUNDLE_VERSION: *u8 *= *[0-9]+' "$here/../core/hop-core/src/bundle.rs" | grep -oE '=[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
committed_wire=""
stamp_untracked=0
if [ "$working_tree" -eq 1 ]; then
  committed_wire="$(cat "$here/pkg/.wire-version" 2>/dev/null || echo "")"
elif [ "$in_git" -eq 1 ]; then
  if git -C "$here" cat-file -e HEAD:sim/pkg/.wire-version 2>/dev/null; then
    committed_wire="$(git -C "$here" show HEAD:sim/pkg/.wire-version 2>/dev/null | head -1 || true)"
  else
    # F-web-1: inside a git tree but the committed stamp is not at HEAD -> DRIFT, do NOT read the
    # working-tree stamp (which build-wasm.sh just re-stamped fresh, masking a real wire bump).
    echo "DRIFT: sim/pkg/.wire-version is not tracked at HEAD (a committed stamp went untracked)"
    drift=1
    stamp_untracked=1
  fi
else
  committed_wire="$(cat "$here/pkg/.wire-version" 2>/dev/null || echo "")"
fi
if [ "$stamp_untracked" -eq 1 ]; then
  : # already reported as DRIFT above; skip the working-tree-based checks below
elif [ -z "$committed_wire" ]; then
  echo "DRIFT: sim/pkg/.wire-version is missing, rebuild the pkg so it stamps the wire version"
  drift=1
elif [ "$committed_wire" != "$src_wire" ]; then
  echo "DRIFT: sim/pkg/.wire-version=$committed_wire but source BUNDLE_VERSION=$src_wire (wire bump not rebuilt into the committed pkg)"
  drift=1
fi

if [ "$drift" -ne 0 ]; then
  echo
  echo "sim/pkg is STALE, rebuild it: sim/build-wasm.sh (then commit sim/pkg)"
  exit 1
fi
if [ "$committed_only" -eq 1 ]; then
  echo "sim/pkg committed .wire-version matches source BUNDLE_VERSION=$src_wire (fresh)"
elif [ "$working_tree" -eq 1 ]; then
  echo "sim/pkg working-tree interface and .wire-version match a fresh core/hop-wasm build (fresh)"
else
  echo "sim/pkg interface matches a fresh core/hop-wasm build (fresh)"
fi
