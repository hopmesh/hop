#!/usr/bin/env bash
# core-ffi-08 / PLAT-004: guardrail that HOP_ABI_VERSION is identical across every place it is
# declared, asserted, or claimed in prose, and that a wrapper pinned to an ABI level actually binds
# the calls that level's bump note names.
#
# A wrapper asserts `hop_abi_version() == HOP_ABI_VERSION` at load so a wrapper built against a newer
# header fails loudly instead of drifting silently (F-28). That safety net only works if the constant
# the wrapper compiles in actually matches the one the Rust library returns.
#
# WHY THIS SCRIPT WAS REWRITTEN. It used to enumerate SIX hand-listed paths while its own header
# claimed to cover "every place it is declared". The tree holds TWELVE declarations, so six were never
# compared, and the v4 -> v5 bump left real drift behind in one of them: tools/package-export-smoke.py
# asserted the shipped Apple xcframework header contained `#define HOP_ABI_VERSION 4` while the header
# said 5, and two published SDK docs still told integrators the wrapper asserts ABI 4. Its own DOC-07
# comment moralised about exactly that pattern ("A guard that covers five of six declarations is
# precisely as strong as its weakest unchecked leg") while omitting six more legs. A hand list cannot
# be trusted to grow, so this script DISCOVERS declarations by sweeping the tree and fails on anything
# it finds that it cannot account for. The list below now exists to classify what the sweep finds and
# to prove nothing vanished, never to bound what gets checked.
#
# AND WHY THE SWEEP ALONE WAS STILL NOT ENOUGH. The discovery is only as wide as DECL_RE's identifier
# list, which is itself a hand list. The v5 -> v6 bump proved it: the Flutter SDK pinned the ABI as
# `const int hopAbiVersion = 5`, an identifier the pattern did not match, so this guard reported full
# consistency across twelve sites while a thirteenth declaration sat at 5 and its load-time assertion
# broke the whole Flutter CI job. Same defect class, different outfit: paths drifted, then identifiers
# did. DECL_RE now names `hopAbiVersion` and Flutter is a registered wrapper. The standing limitation
# belongs here rather than in a meeting: a wrapper that names its pin something new is invisible until
# its identifier is added, so DECL_RE is the real boundary of the coverage claim.
#
# Four checks, all of which must pass:
#   1. VALUE AGREEMENT. Every ABI-version literal anywhere in the tree equals the Rust const.
#   2. CLASSIFICATION. Every declaration the sweep finds is a known site. A new pinned copy (a new
#      language wrapper, a new packaging assertion) fails the guard until it is listed here, which is
#      what stops the coverage gap from silently reopening.
#   3. PRESENCE. Every known site still declares the constant, so a rename or deletion is caught.
#   4. ABI SURFACE. Every wrapper pinned to the current version references each `hop_*` function named
#      in the header's note for the current bump. This is the PLAT-003 leg: sdk/hop.h claimed the
#      v4 -> v5 bump bought relay failover for wrappers while no wrapper bound hop_relay_add,
#      hop_relay_next, hop_relay_report or hop_relay_pool_size. A version integer confers no
#      capability; binding the symbols does, so the header's claim is now machine-checked.
#
# Prose claims about the level ("asserts ABI 4") are held to the constant too, because a doc that
# names an old level misleads an integrator as effectively as a stale literal breaks a build.
#
# Self-tested by tools/codegen/check-abi-version.test.sh.
set -uo pipefail
ROOT="${HOP_ABI_GUARD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || { echo "::error:: ABI guard: cannot enter $ROOT"; exit 1; }

fail=0
err() { echo "::error:: $*"; fail=1; }

# ---- the source of truth ------------------------------------------------------------------------
REF_FILE="core/hop/src/cabi.rs"
if [ ! -f "$REF_FILE" ]; then
  echo "::error:: ABI guard: the source of truth is missing: $REF_FILE"
  exit 1
fi
# Take the LAST digit run in the matched declaration so a type suffix (u32 / UInt32) is never mistaken
# for the version.
REF="$(grep -Eo 'HOP_ABI_VERSION: *u32 *= *[0-9]+' "$REF_FILE" | head -n1 | grep -Eo '[0-9]+' | tail -n1)"
if [ -z "$REF" ]; then
  echo "::error:: ABI guard: could not read HOP_ABI_VERSION from $REF_FILE; the constant was renamed or removed"
  exit 1
fi

# ---- what the sweep looks for -------------------------------------------------------------------
#
# Any identifier that pins an ABI version, in one of two shapes. TYPED (`HOP_ABI_VERSION: u32 = 5`,
# `expectedABIVersion: UInt32 = 5`) REQUIRES the `=`, because a type name ending in digits otherwise
# supplies them: `HOP_ABI_VERSION: u32 = %s` matched the old pattern and reported the version as "32".
# BARE covers `#define HOP_ABI_VERSION 5`, `const val HOP_ABI_VERSION = 5`, `ABI_EXPECTED = 5_u32`,
# `const abiExpected = 5`, and a literal `"#define HOP_ABI_VERSION 5"` in a packaging assertion.
DECL_RE='(HOP_ABI_VERSION|HOP_EMBEDDED_ABI_VERSION|expectedABIVersion|_?ABI_EXPECTED|abiExpected|hopAbiVersion)([ \t]*:[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*[0-9]+|[ \t]*=?[ \t]*[0-9]+)'
# Prose that states an ABI level to a reader: "ABI 5", "ABI-5", "ABI v5", "ABI version 5".
PROSE_RE='ABI[ _-](version[ _-])?v?[0-9]+'

# Directories and files the sweep does NOT read, each for a stated reason. This list is deliberately
# short: everything else in the tree is fair game, and check 2 makes an unknown match a failure rather
# than something to quietly add here.
#   .git, target, node_modules, build, .build, dist   build and dependency output, not source
#   Frameworks                                        xcframework build output; its hop.h is a byte
#                                                     copy of the generated header
#   pkg, pkg-node                                     generated wasm packages
#   audits (docs/, business/)                         IMMUTABLE historical audit reports: they quote
#                                                     the ABI value as it stood at the time, on
#                                                     purpose, and rewriting history is not the fix
#   tarpaulin-report.html                             generated coverage report, embeds source
#   check-abi-version.sh                              this file holds the PATTERNS, not declarations
SWEEP_EXCLUDES=(
  --exclude-dir=.git --exclude-dir=target --exclude-dir=node_modules
  --exclude-dir=build --exclude-dir=.build --exclude-dir=dist
  --exclude-dir=Frameworks --exclude-dir=pkg --exclude-dir=pkg-node
  --exclude-dir=audits
  --exclude=tarpaulin-report.html
  --exclude=check-abi-version.sh
  --exclude=CHANGELOG.md
)

# ---- known declaration sites --------------------------------------------------------------------
#
# label|path|role[|surface-root]
#   contract  : the ABI contract itself (the Rust const and the generated headers)
#   wrapper   : a language wrapper that compiles the constant in and asserts it at load. Checked by
#               check 4 against `surface-root`, the directory its bindings live in.
#   validator : a packaging/release assertion about a built artifact's header. Not a wrapper, so it
#               binds nothing, but it must still agree on the number.
#
# Thirteen entries, one per declaration in the tree. The sweep is what makes the coverage real;
# this table is what makes an unaccounted-for fourteenth a hard failure.
#
# tools/package-export-smoke.py is deliberately NOT here. Its Apple gate used to hard-code the level
# (asserting 4 against a header that said 5, the drift PLAT-004 was filed for), and the fix was to
# ELIMINATE the duplicate rather than add a leg to check it: it now reads the level out of the shipped
# Swift wrapper. Same for the two test fixtures that froze old values. If any of them hard-codes a
# level again, check 2 fails it as an unclassified declaration, which is the point.
SITES=(
  "rust-cabi|core/hop/src/cabi.rs|contract"
  "header-src|core/hop/include/hop.h|contract"
  "header-sdk|sdk/hop.h|contract"
  "swift|sdk/apple/Sources/Hop/Hop.swift|wrapper|sdk/apple/Sources"
  "kotlin|sdk/android/src/main/kotlin/sh/hop/Hop.kt|wrapper|sdk/android/src/main"
  "embedded|sdk/embedded/src/Hop.h|wrapper|sdk/embedded/src"
  "go|sdk/go/hop.go|wrapper|sdk/go"
  "node|sdk/node/lib/ffi.mjs|wrapper|sdk/node/lib"
  "python|sdk/python/hop_endpoint/_ffi.py|wrapper|sdk/python/hop_endpoint"
  "ruby|sdk/ruby/lib/hop/ffi.rb|wrapper|sdk/ruby/lib"
  "crystal|sdk/crystal/src/hop/ffi.cr|wrapper|sdk/crystal/src"
  "go-install|sdk/go/cmd/hop-install/main.go|validator"
  "flutter|sdk/flutter/lib/src/ffi.dart|wrapper|sdk/flutter/lib"
)

known_path() {
  local p="$1" entry
  for entry in "${SITES[@]}"; do
    [ "$(printf '%s' "$entry" | cut -d'|' -f2)" = "$p" ] && return 0
  done
  return 1
}

# ---- checks 1 and 2: sweep, compare, classify ---------------------------------------------------
echo "Sweeping the tree for ABI-version declarations (source of truth: $REF_FILE = $REF):"
declarations=0
declare -a found_paths=()
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"; rest="${hit#*:}"
  line="${rest%%:*}"; text="${rest#*:}"
  file="${file#./}"
  value="$(printf '%s' "$text" | grep -Eo '[0-9]+' | tail -n1)"
  declarations=$((declarations + 1))
  found_paths+=("$file")
  if [ "$value" != "$REF" ]; then
    err "ABI version mismatch: $file:$line declares $value but $REF_FILE declares $REF ($text)"
  fi
  if ! known_path "$file"; then
    err "ABI guard: UNCLASSIFIED declaration at $file:$line ($text). Every pinned copy of the ABI version must be listed in SITES in tools/codegen/check-abi-version.sh so it is covered on purpose rather than by luck."
  fi
  printf '  %-56s %s\n' "$file:$line" "$value"
done < <(grep -rEnIo "${SWEEP_EXCLUDES[@]}" "$DECL_RE" . 2>/dev/null | sort)

if [ "$declarations" -eq 0 ]; then
  err "ABI guard: the sweep found NO declarations at all, so the pattern stopped matching; fix DECL_RE rather than trusting this pass"
fi

# ---- check 3: nothing vanished ------------------------------------------------------------------
for entry in "${SITES[@]}"; do
  label="$(printf '%s' "$entry" | cut -d'|' -f1)"
  path="$(printf '%s' "$entry" | cut -d'|' -f2)"
  if [ ! -f "$path" ]; then
    err "ABI guard: expected declaration file not found: $path ($label)"
    continue
  fi
  hit=0
  for p in ${found_paths[@]+"${found_paths[@]}"}; do
    if [ "$p" = "$path" ]; then hit=1; break; fi
  done
  [ "$hit" -eq 1 ] || err "ABI guard: $path ($label) no longer declares an ABI version; the constant was renamed or removed, so its load-time assertion is checking nothing"
done

# ---- check 4: the ABI surface the current bump note names ---------------------------------------
#
# Read the bump note for the CURRENT version out of the generated header and collect the `hop_*`
# functions it names. Deriving the list from the note rather than hard-coding it means the next bump is
# covered by writing its note, and a note naming functions no wrapper binds cannot ship.
note_symbols=""
if [ -f "sdk/hop.h" ]; then
  note_symbols="$(awk -v ver="$REF" '
    $0 ~ ("v[0-9]+ -> v" ver ":") { collecting = 1 }
    collecting && $0 !~ /^\/\// { collecting = 0 }
    collecting && $0 ~ /^\/\/[ \t]*$/ { collecting = 0 }
    collecting { print }
  ' sdk/hop.h | grep -Eo 'hop_[a-z0-9_]+' | sort -u)"
fi

if [ -z "$note_symbols" ]; then
  echo "No v$REF bump note in sdk/hop.h names hop_* calls, so there is no claimed surface to hold the wrappers to."
else
  echo "Functions the v$REF bump note names, which every wrapper pinned to $REF must bind:"
  printf '%s\n' "$note_symbols" | sed 's/^/  /'
  for entry in "${SITES[@]}"; do
    role="$(printf '%s' "$entry" | cut -d'|' -f3)"
    [ "$role" = "wrapper" ] || continue
    label="$(printf '%s' "$entry" | cut -d'|' -f1)"
    surface="$(printf '%s' "$entry" | cut -d'|' -f4)"
    if [ -z "$surface" ] || [ ! -d "$surface" ]; then
      err "ABI guard: wrapper $label has no surface directory to check ($surface)"
      continue
    fi
    missing=""
    while IFS= read -r sym; do
      [ -n "$sym" ] || continue
      grep -rqI -- "$sym" "$surface" 2>/dev/null || missing="$missing $sym"
    done <<< "$note_symbols"
    if [ -n "$missing" ]; then
      err "ABI guard: wrapper $label pins ABI $REF but nothing under $surface references:$missing. Either bind them, or the header's v$REF note is claiming a capability this wrapper does not expose (PLAT-003)."
    else
      printf '  %-12s binds the whole v%s surface (%s)\n' "$label" "$REF" "$surface"
    fi
  done
fi

# ---- prose: a doc that states an ABI level must state the current one ---------------------------
echo "Checking prose claims about the ABI level:"
prose_hits=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"; rest="${hit#*:}"
  line="${rest%%:*}"; text="${rest#*:}"
  file="${file#./}"
  value="$(printf '%s' "$text" | grep -Eo '[0-9]+' | tail -n1)"
  prose_hits=$((prose_hits + 1))
  if [ "$value" != "$REF" ]; then
    err "stale ABI claim: $file:$line says \"$text\" but the ABI is $REF. State the current level; a doc naming an old one misleads an integrator."
  fi
done < <(grep -rEnIo "${SWEEP_EXCLUDES[@]}" "$PROSE_RE" . 2>/dev/null | sort)
echo "  $prose_hits prose claim(s) checked"

if [ "$fail" -ne 0 ]; then
  echo "::error:: HOP_ABI_VERSION guard FAILED. Bump every location together (cabi.rs, both hop.h, every sdk/ wrapper, the packaging validators, and the docs that state the level) in the same change."
  exit 1
fi

echo "HOP_ABI_VERSION is consistent ($REF) across all $declarations declarations in ${#SITES[@]} classified sites, and every wrapper binds the v$REF surface."
