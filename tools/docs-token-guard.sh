#!/usr/bin/env bash
# docs-token-guard.sh (docs-drift-02): fail the build when banned tokens appear in docs
# and site copy. Runs in CI so a doc/site edit that reintroduces one of these is caught
# pre-merge instead of shipping to the public site.
#
# What it bans (in the scoped paths only):
#   1. em-dash  U+2014 : the owner's hard no-em-dash rule. Also its lookalikes U+2015 and, for the
#      en-dash, U+2012 and U+2212, plus every encoded form of all five (see the dash block below).
#   2. en-dash  U+2013 : same rule (no en-dash substitution either).
#   3. "InternetEgress": a Destination wire variant that was removed. Docs must not teach
#      the dead API. Lines that explicitly document its REMOVAL are allowed (see below).
#   4. "Wi-Fi Direct"  : the Android P2P bearer was removed. Positioning must not claim it
#      as a live transport. Removal notes are allowed.
#   5. bare "Bluetooth": say "BLE" (passive, no-pairing) in user-facing copy. Real API
#      identifiers (CoreBluetooth, BluetoothAdapter, BluetoothLeScanner, WebBluetooth,
#      NSBluetooth*, bluetooth-central, ...) are NOT flagged: only the standalone word.
#
# TWO passes, deliberately different in scope (docs-drift-03):
#   DOC pass    : all five bans, over user-facing docs + site copy. Unchanged.
#   SOURCE pass : the DASH bans ONLY (1 + 2 + their encoded and lookalike forms), over the
#                 code trees. The root CLAUDE.md law is "no em-dashes or en-dashes ANYWHERE
#                 (code, comments, docs, commits, PRs)", but for years this guard only read
#                 docs, so source drifted to ~1000 dashes across 129 files before the sweep
#                 that added this pass. The three WORD bans stay out of the source pass on
#                 purpose: "Bluetooth" and "Wi-Fi Direct" are legitimate API and transport-tag
#                 identifiers in bearer code, and banning them there would be a new rule, not
#                 wider coverage of the existing one.
#
# Scope: the DOC pass stays user-facing docs + site copy only (a Bluetooth permission string
# is a legit iOS requirement, not marketing copy). The SOURCE pass reads the code trees, minus
# the exclusions listed at SRC_REQUESTED below.
#
# Usage:  tools/docs-token-guard.sh              # doc pass + source pass, default path sets
#         tools/docs-token-guard.sh PATH ...     # doc-pass rules over explicit paths (tests)
#         tools/docs-token-guard.sh --source P.. # source-pass rules over explicit paths (tests)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# Default scan set: markdown docs at the repo root + docs/, the Astro site copy, and the
# sim/ + learn/ trees. apps/web/site/package.json's `sync-sim`/`sync-learn` copy ../sim and ../learn
# into apps/web/site/public and pages.yml deploys apps/web/site/dist, so sim/*.html and learn/*.html ship to the
# live public site and must be guarded too (web-r3-01). Vendored/build artifacts under these
# (sim/pkg, sim/sqlite-wasm, *.wasm) are already dropped by the shared `excludes` below.
# Keep this list narrow so it does not false-positive on code/comments/build output.
SOURCE_ONLY=0
if [ "${1:-}" = "--source" ]; then
  SOURCE_ONLY=1
  shift
fi

REQUESTED=()
SRC_REQUESTED=()
if [ "$#" -gt 0 ]; then
  # Explicit paths: one pass only, whichever the caller asked for. Used by the self-test.
  if [ "$SOURCE_ONLY" -eq 1 ]; then
    SRC_REQUESTED=("$@")
  else
    REQUESTED=("$@")
  fi
else
  REQUESTED=(
    "DESIGN.md" "MECHANISMS.md" "README.md"
    "docs" "apps/web/site/src" "sim" "learn"
  )
  # SOURCE pass default set: every tree that holds hand-written code. apps/web/site/src is
  # already in the doc set above; leaving apps/ whole here costs nothing (a dash is banned by
  # both passes) and keeps the list from needing a carve-out that could silently widen.
  #
  # .github and mockups are here because ci.yml DISPATCHES this guard on them: the `docs` path filter
  # names '.github/workflows/**' and the wasm/web filters name 'mockups/**', so an edit there ran this
  # guard and got a green result for a tree it never opened. ci.yml alone is ~1200 lines of prose-dense
  # comments, which made it the largest unscanned writing surface in the repo. Root markdown is here
  # for the same reason: the filter names README.md and LICENSE.md, and the doc pass only ever read
  # three of the seven root files. tools/docs-token-guard.test.sh pins the filter-to-target mapping.
  # fuzz, mockups, and business were added by audit PROC-001. They are hand-written and were in
  # NEITHER pass, so a dash in a fuzz target or a mockup was unenforced while the guard printed a
  # green line naming eleven trees. All three were already clean when they were added, so this
  # widened coverage without banking a cleanup. The remaining unscanned top-level dirs are
  # target/ (build output) and git-cliff-2.13.1/ (a vendored tool), both correctly out of scope.
  # If you add a top-level tree with hand-written content, add it here in the same commit.
  SRC_REQUESTED=(
    "core" "services" "drivers" "sdk" "bearers" "apps" "tools" "infra" "examples" "testkit" "assets"
    ".github" "fuzz" "mockups" "business"
  )
  for root_markdown in ./*.md; do
    [ -e "$root_markdown" ] && SRC_REQUESTED+=("${root_markdown#./}")
  done
fi

# Keep only paths that exist, so a not-yet-created doc (e.g. a root README) does not error
# the scan. A missing default path is fine; an explicitly-passed missing path is a caller bug.
TARGETS=()
for p in "${REQUESTED[@]:-}"; do
  if [ -n "$p" ] && [ -e "$p" ]; then
    TARGETS+=("$p")
  fi
done
SRC_TARGETS=()
for p in "${SRC_REQUESTED[@]:-}"; do
  if [ -n "$p" ] && [ -e "$p" ]; then
    SRC_TARGETS+=("$p")
  fi
done
if [ "${#TARGETS[@]}" -eq 0 ] && [ "${#SRC_TARGETS[@]}" -eq 0 ]; then
  echo "docs-token-guard: no target paths to scan"
  exit 0
fi

# Resolve a real grep binary. The interactive shell aliases `grep` to a ugrep wrapper that
# honours .gitignore (which would hide tracked-but-ignored copy from the scan), so call the
# system grep directly. GNU grep (CI/Linux) and BSD grep (macOS) both accept these flags.
GREP="$(command -v grep)"

# The banned dash code points, built from hex so this script file itself stays ASCII-clean and can
# never trip its own guard. Beyond em (U+2014) and en (U+2013) we also ban the LOOKALIKE substitutes
# anyone (or a model) dodging the em-dash rule reaches for (pass-18 F-CI-4): the HORIZONTAL BAR
# (U+2015) and the FIGURE DASH (U+2012), both visually near-identical to an em/en-dash, and the MINUS
# SIGN (U+2212), which renders as an en-dash-width stroke in most UI faces. U+2212 was added by audit
# PROC-001: the guard was reporting OK over core/ while node.rs carried "received U+2212 created_at"
# in a comment, so "the source pass is green" still did not mean "no dash lookalikes in source", which
# is exactly the trust-a-green-result failure PROC-001 was opened about. A real subtraction in prose or
# a comment is an ASCII hyphen; U+2212 buys nothing a keyboard "-" does not.
EMDASH=$(printf '\xe2\x80\x94')   # U+2014 em dash
ENDASH=$(printf '\xe2\x80\x93')   # U+2013 en dash
HBAR=$(printf '\xe2\x80\x95')     # U+2015 horizontal bar (em-dash lookalike)
FIGDASH=$(printf '\xe2\x80\x92')  # U+2012 figure dash (en-dash lookalike)
MINUS=$(printf '\xe2\x88\x92')    # U+2212 minus sign (en-dash lookalike); use an ASCII hyphen

# Lines that explicitly record a removal are legitimate history, not a live claim. A doc that
# says "Wi-Fi Direct was REMOVED" or "InternetEgress ... removed" must pass; a doc that lists
# either as a current transport/API must fail.
REMOVAL_CONTEXT='REMOVED|[Rr]emoved|[Nn]o longer|[Dd]eleted|[Rr]emoval'

# Escape hatch for genuinely-legit uses the heuristics can't tell apart (e.g. a competitor
# comparison table that factually names another product's Wi-Fi Direct stack). Put the marker
# "docs-token-guard: allow" on that exact line and it is exempted. Use sparingly.
ALLOW_MARKER='docs-token-guard: allow'

# Common file exclusions shared by every scan.
excludes=(
  --binary-files=without-match
  --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=.astro
  --exclude-dir=pkg --exclude-dir=pkg-node --exclude-dir=sqlite-wasm --exclude-dir=audits
  # `generated/` is UniFFI/cbindgen output (apps/android/HopDemo/generated), gitignored and
  # untracked. It was still being scanned, so the guard reddened only on a machine where someone had
  # actually run tools/build-aar.sh: green in CI and green on a clean checkout, red for whoever built
  # for a device. A guard whose result depends on local build state is worse than no guard, because
  # the failure looks like a real violation in prose nobody wrote.
  --exclude-dir=generated
  --exclude='*.wasm' --exclude='*.lock' --exclude='package-lock.json'
  --exclude='*.svg' --exclude='*.png' --exclude='*.jpg'
)

# Extra exclusions for the SOURCE pass only, on top of `excludes`. Every entry BUT THE LAST TWO is
# machine-generated or a captured artifact, so a dash inside it is not something a human wrote and
# rewriting it would be undone by the next regeneration. The last two (this script and its self-test)
# ARE hand-written; they are called out separately below because they are the one place this list is
# not self-policing. Note also that the SHARED `excludes` above drops --exclude='*.svg', which is
# hand-authored design source under assets/, not output: 31 icon and wordmark files the source pass
# therefore never reads. Do not read "the source pass reported OK" as "no source file has a dash".
#   build output      target/ build/ .build/ .build-staging/ .next/ .gradle/ Frameworks/ coverage/
#   captured logs     results/ (testkit device runs) logs/ (ble-lab field captures), *.log
#   generated code    hop.swift (UniFFI-generated Swift bindings; regenerated by build-aar.sh /
#                     build-xcframework.sh), *.pbxproj
#   generated prose   CHANGELOG.md (git-cliff renders these from commit history; see
#                     tools/gen-changelogs.sh, so an edit here is reverted on the next run)
#                     THIRD-PARTY-NOTICES.md (tools/gen-third-party-notices.py renders it from the
#                     lockfile, and its bulk is the VERBATIM licence text of 168 crates we neither
#                     author nor may alter). A dash inside someone else's MIT notice is not a thing
#                     this repo can fix, so scanning it would eventually redden CI on a dependency
#                     bump with no legitimate remedy except deleting attribution we are legally
#                     required to ship. The dash law binds copy we write; this file is quoted.
#   coverage report   tarpaulin-report.html
# docs/audits/*.html (immutable historical audit artifacts) is already dropped by the shared
# --exclude-dir=audits above.
src_excludes=(
  --exclude-dir=target --exclude-dir=build --exclude-dir=.build --exclude-dir=.build-staging
  --exclude-dir=.next --exclude-dir=.gradle --exclude-dir=Frameworks --exclude-dir=coverage
  --exclude-dir=results --exclude-dir=logs
  --exclude='*.log' --exclude='CHANGELOG.md' --exclude='hop.swift' --exclude='*.pbxproj'
  --exclude='tarpaulin-report.html' --exclude='THIRD-PARTY-NOTICES.md'
  # This guard and its self-test have to SPELL every banned pattern to ban it (the encoded-dash
  # regex literally contains &mdash; and &#x2014). They are ASCII-clean by the tools/CLAUDE.md
  # rule (no literal dash byte is ever typed into either file) and docs-token-guard.test.sh is
  # the regression net for both, so scanning them would only ever be a self-hit.
  --exclude='docs-token-guard.sh' --exclude='docs-token-guard.test.sh'
  --exclude='commit-message-guard.sh' --exclude='commit-message-guard.test.sh'
)

# RETIRED EXCLUSION: core/hop-core/vectors/wire-source-manifest.txt (audit PROC-001).
# The manifest-listed wire sources were once skipped by this pass. The reasoning was real
# (tools/wire-version-guard.sh hashes those files, so rewriting a comment in one forces a
# BUNDLE_VERSION bump for punctuation), and the carve-out named its own closure condition in
# prose: clean them at the next real wire bump. Prose is not a trigger. Wire v12 and v13 both
# shipped with the files untouched, so this guard reported OK across core/ while six of the
# protocol's most-read files still carried banned dashes, which is the same class of dishonesty
# as a guard whose scope is narrower than its name. The files were cleaned in the v13 -> v14
# bump and the exclusion is gone. Scanning the manifest is also the only stable end state: a
# dash caught pre-merge costs one edit, while an excluded manifest silently banks the debt until
# some later bump has to pay it. Do not reintroduce this exclusion.

fail=0

# report LABEL HITS: drop any explicitly-allowed line, then on any remaining hit print an error
# block and mark failure. Called in the parent shell (not a pipeline) so the fail flag survives.
report() {
  local label="$1" hits="$2"
  hits="$(printf '%s' "$hits" | "$GREP" -vF "$ALLOW_MARKER")"
  if [ -n "$hits" ]; then
    echo "::error::banned token found in docs/site copy: $label"
    echo "$hits"
    echo
    fail=1
  fi
}

# report_src LABEL HITS: same as `report`, with the source-pass error text. It carries no path
# exclusions of its own any more (see the retired wire-manifest carve-out above); everything the
# source pass skips is stated once, in `src_excludes`, where it can be read at a glance.
report_src() {
  local label="$1" hits="$2"
  hits="$(printf '%s' "$hits" | "$GREP" -vF "$ALLOW_MARKER")"
  if [ -n "$hits" ]; then
    echo "::error::banned dash found in source (repo law: no em/en-dashes anywhere): $label"
    echo "$hits"
    echo
    fail=1
  fi
}

if [ "${#TARGETS[@]}" -gt 0 ]; then
# Fixed-string scan for the banned dashes (em, en, + the two lookalikes): any occurrence is a violation.
report "em-dash (U+2014): rewrite with a comma, colon, parens, or two sentences" \
  "$("$GREP" -rInF "${excludes[@]}" -e "$EMDASH" -- "${TARGETS[@]}" 2>/dev/null)"
report "en-dash (U+2013): do not substitute, rewrite the sentence" \
  "$("$GREP" -rInF "${excludes[@]}" -e "$ENDASH" -- "${TARGETS[@]}" 2>/dev/null)"
report "horizontal bar (U+2015): an em-dash lookalike, rewrite the sentence" \
  "$("$GREP" -rInF "${excludes[@]}" -e "$HBAR" -- "${TARGETS[@]}" 2>/dev/null)"
report "figure dash (U+2012): an en-dash lookalike, rewrite the sentence" \
  "$("$GREP" -rInF "${excludes[@]}" -e "$FIGDASH" -- "${TARGETS[@]}" 2>/dev/null)"
report "minus sign (U+2212): an en-dash lookalike, use an ASCII hyphen" \
  "$("$GREP" -rInF "${excludes[@]}" -e "$MINUS" -- "${TARGETS[@]}" 2>/dev/null)"

# Encoded dashes: an HTML entity (named &mdash;, decimal &#8212;, or hex &#x2014;, each of which HTML5
# lets you zero-pad: &#08212;, &#x02014;), a JS/JSON \u escape, or a CSS \2014 escape (no u prefix) all
# render a real em/en-dash on the page while the source bytes stay ASCII, so the literal-byte scan above
# walks right past them. apps/web/site/src is Astro/HTML/TS and sim/ + learn/ ship HTML/CSS, so an encoded dash
# here IS a rendered dash on the public site. Case-insensitive extended regex (-iE) so &#X2014; / \U2014
# and every zero-padded form match; 0* absorbs the optional leading zeros, \{?...\}? the \u{...} braces.
# The trailing `;` on a numeric entity is OPTIONAL (pass-18 F-CI-3): the WHATWG tokenizer resolves
# &#8212 (no semicolon) to a real em-dash too, so `;?` after each numeric form. The em/en LOOKALIKES are
# banned in their encoded forms as well (F-CI-4): U+2015 horizontal bar (&#8213; / &#x2015; /
# \2015), U+2012 figure dash (&#8210; / &#x2012; / \2012), and U+2212 minus sign (&#8722; / &#x2212; /
# \2212, added by audit PROC-001, which is why the numeric alternations are grouped rather than a flat
# character class: 8722 and 2212 are not contiguous with the 821x / 201x runs). This file stays
# ASCII-clean, so the lookalike glyphs themselves are named by code point above, never typed.
report "encoded dash (HTML entity, \\u escape, or CSS \\NNNN, incl. lookalikes U+2015/U+2012/U+2212): rewrite the sentence" \
  "$("$GREP" -rIniE "${excludes[@]}" \
      -e '&mdash;|&ndash;|&#0*(821[0123]|8722);?|&#x0*(201[2345]|2212);?|\\u\{?0*(201[2345]|2212)\}?|\\0*(201[2345]|2212)' \
      -- "${TARGETS[@]}" 2>/dev/null)"

# InternetEgress + Wi-Fi Direct: case-INSENSITIVE fixed-string match (-i), then drop lines that document
# the removal. Case matters: prose naturally lowercases these ("wi-fi direct", "internetegress"), and
# the ban must catch that, not only the canonical casing.
report "InternetEgress (removed Destination wire variant): use device-addressed hops://" \
  "$("$GREP" -rInFi "${excludes[@]}" -e "InternetEgress" -- "${TARGETS[@]}" 2>/dev/null | "$GREP" -Ev "$REMOVAL_CONTEXT")"
report "Wi-Fi Direct (removed Android P2P bearer): Android-to-Android falls back to BLE" \
  "$("$GREP" -rInFi "${excludes[@]}" -e "Wi-Fi Direct" -- "${TARGETS[@]}" 2>/dev/null | "$GREP" -Ev "$REMOVAL_CONTEXT")"

# Bluetooth: only the bare marketing word, case-INSENSITIVELY (-wi), so prose "bluetooth"/"BLUETOOTH" is
# caught, not only "Bluetooth". Then drop real API identifiers where "Bluetooth" is glued to another
# alnum token (CoreBluetooth, BluetoothAdapter, WebBluetooth, bluetooth-central, NSBluetooth*,
# bluetoothd, ...); the exclusion is -Evi so it stays case-insensitive too. The -w word-match already
# spares glued identifiers on its own; the exclusion covers the punctuation-adjacent forms. The hyphen
# exclusion is scoped to the two REAL iOS background-mode identifiers (bluetooth-central /
# bluetooth-peripheral), not an open-ended `bluetooth-` prefix, which was letting bare marketing phrases
# like "bluetooth-powered" / "bluetooth-free" through (pass-18 F-CI-5).
report "bare Bluetooth (say BLE in user-facing copy)" \
  "$("$GREP" -rInwi "${excludes[@]}" -e "Bluetooth" -- "${TARGETS[@]}" 2>/dev/null | "$GREP" -Evi '[[:alnum:]]Bluetooth|Bluetooth[[:alnum:]]|Bluetooth[Ll]e|bluetooth-central|bluetooth-peripheral|bluetoothd|NSBluetooth')"
fi

# ---- SOURCE pass: the dash bans only, over the code trees (docs-drift-03) ----------------------
# Same four literal code points and the same encoded/lookalike regex as the doc pass above, so a
# dash smuggled into a comment as an HTML entity is caught here too. The three WORD bans are
# deliberately NOT applied: "Bluetooth" and "Wi-Fi Direct" are real API and transport-tag
# identifiers in bearer code.
if [ "${#SRC_TARGETS[@]}" -gt 0 ]; then
report_src "em-dash (U+2014): rewrite with a comma, colon, semicolon, parens, or two sentences" \
  "$("$GREP" -rInF "${excludes[@]}" "${src_excludes[@]}" -e "$EMDASH" -- "${SRC_TARGETS[@]}" 2>/dev/null)"
report_src "en-dash (U+2013): do not substitute, rewrite the sentence (a range reads as \"X to Y\")" \
  "$("$GREP" -rInF "${excludes[@]}" "${src_excludes[@]}" -e "$ENDASH" -- "${SRC_TARGETS[@]}" 2>/dev/null)"
report_src "horizontal bar (U+2015): an em-dash lookalike, rewrite the sentence" \
  "$("$GREP" -rInF "${excludes[@]}" "${src_excludes[@]}" -e "$HBAR" -- "${SRC_TARGETS[@]}" 2>/dev/null)"
report_src "figure dash (U+2012): an en-dash lookalike, rewrite the sentence" \
  "$("$GREP" -rInF "${excludes[@]}" "${src_excludes[@]}" -e "$FIGDASH" -- "${SRC_TARGETS[@]}" 2>/dev/null)"
report_src "minus sign (U+2212): an en-dash lookalike, use an ASCII hyphen" \
  "$("$GREP" -rInF "${excludes[@]}" "${src_excludes[@]}" -e "$MINUS" -- "${SRC_TARGETS[@]}" 2>/dev/null)"
report_src "encoded dash (HTML entity, \\u escape, or CSS \\NNNN, incl. lookalikes U+2015/U+2012/U+2212): rewrite the sentence" \
  "$("$GREP" -rIniE "${excludes[@]}" "${src_excludes[@]}" \
      -e '&mdash;|&ndash;|&#0*(821[0123]|8722);?|&#x0*(201[2345]|2212);?|\\u\{?0*(201[2345]|2212)\}?|\\0*(201[2345]|2212)' \
      -- "${SRC_TARGETS[@]}" 2>/dev/null)"
fi

if [ "$fail" -ne 0 ]; then
  echo "docs-token-guard: FAIL (see errors above)"
  exit 1
fi
echo "docs-token-guard: OK (no banned tokens in ${TARGETS[*]:-}${SRC_TARGETS[*]:+ | source: ${SRC_TARGETS[*]}})"
