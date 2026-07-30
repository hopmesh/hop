#!/usr/bin/env bash
# Self-test for tools/docs-token-guard.sh. Runs the guard against synthetic fixtures and asserts
# it (a) flags real violations, (b) passes clean copy, and (c) does NOT false-positive on legit
# API identifiers or documented removal notes. No network, no repo state.
#   run: bash tools/docs-token-guard.sh.test.sh  (or tools/docs-token-guard.test.sh)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/docs-token-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# expect_pass FILE: the guard must exit 0 for this fixture.
expect_pass() {
  if "$GUARD" "$1" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: expected clean, guard flagged $1"
    "$GUARD" "$1" 2>&1 | sed 's/^/    /'
  fi
}

# expect_fail FILE: the guard must exit non-zero for this fixture.
expect_fail() {
  if "$GUARD" "$1" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL: expected a violation, guard passed $1"
  else
    pass=$((pass + 1))
  fi
}

# expect_src_pass / expect_src_fail FILE: the same, through the SOURCE pass (--source), which
# applies the dash bans ONLY.
expect_src_pass() {
  if "$GUARD" --source "$1" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: expected clean, source pass flagged $1"
    "$GUARD" --source "$1" 2>&1 | sed 's/^/    /'
  fi
}
expect_src_fail() {
  if "$GUARD" --source "$1" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL: expected a violation, source pass passed $1"
  else
    pass=$((pass + 1))
  fi
}

# expect_tree_pass / expect_tree_fail DIR: run the guard with NO arguments from inside a fixture
# repo (the guard resolves its root from its own path), so this exercises the REAL default scan
# sets, not a hand-passed path. This is what proves the source trees are actually in the default
# set: delete "core" from SRC_REQUESTED and expect_tree_fail below goes red.
#
# make_fixture_repo DIR [MANIFEST_PATH ...]: build the fixture. With no extra args the fixture
# manifest names core/hop-core/src/bundle.rs, the file the old carve-out was demonstrated with.
# Pass paths to pin a different manifest, which is how the per-path loop below walks the REAL
# manifest: a re-added exclusion is only caught if the fixture manifest names the file it covers.
make_fixture_repo() {
  local dir="$1"; shift
  mkdir -p "$dir/tools" "$dir/core/hop-core/src" "$dir/core/hop-core/vectors"
  cp "$GUARD" "$dir/tools/docs-token-guard.sh"
  {
    printf '# fixture manifest\n'
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    else
      printf 'core/hop-core/src/bundle.rs\n'
    fi
  } > "$dir/core/hop-core/vectors/wire-source-manifest.txt"
}
expect_tree_pass() {
  if "$1/tools/docs-token-guard.sh" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: expected clean, default-set scan flagged $1"
    "$1/tools/docs-token-guard.sh" 2>&1 | sed 's/^/    /'
  fi
}
expect_tree_fail() {
  if "$1/tools/docs-token-guard.sh" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL: expected a violation, default-set scan passed $1"
  else
    pass=$((pass + 1))
  fi
}

# --- clean copy: must pass ---
printf 'Hop rides BLE and LAN. Address a payload to another device or hops://.\n' > "$TMP/clean.md"
expect_pass "$TMP/clean.md"

# --- legit API identifiers: must pass (not the bare marketing word) ---
printf 'Drives BLE via CoreBluetooth.\nUses BluetoothAdapter and BluetoothLeScanner.\nWebBluetooth is central-only.\nUIBackgroundModes: bluetooth-central.\n' > "$TMP/apis.md"
expect_pass "$TMP/apis.md"

# --- documented removal notes: must pass ---
printf 'Wi-Fi Direct was REMOVED (commit c059d69).\nInternetEgress is no longer a destination; egress is device-addressed.\n' > "$TMP/removed.md"
expect_pass "$TMP/removed.md"

# --- bare Bluetooth marketing word: must fail ---
printf 'Chat over Bluetooth with people nearby.\n' > "$TMP/bt.md"
expect_fail "$TMP/bt.md"

# --- present-tense removed API: must fail ---
printf 'Send to Destination::InternetEgress to reach the internet.\n' > "$TMP/egress.md"
expect_fail "$TMP/egress.md"

# --- Wi-Fi Direct claimed as a live transport: must fail ---
printf 'Android-to-Android uses Wi-Fi Direct for high-bandwidth transfer.\n' > "$TMP/wfd.md"
expect_fail "$TMP/wfd.md"

# --- explicitly-allowed legit use (competitor comparison): must pass ---
printf '| Bridgefy | messaging | BLE + Wi-Fi Direct mesh |  <!-- docs-token-guard: allow -->\n' > "$TMP/allow.md"
expect_pass "$TMP/allow.md"

# --- em-dash: must fail (built from bytes so this test file stays ASCII-clean) ---
printf 'Hop is fast%buntraceable by default.\n' "$(printf '\xe2\x80\x94')" > "$TMP/em.md"
expect_fail "$TMP/em.md"

# --- en-dash: must fail ---
printf 'See sections 5%b7 for the wire format.\n' "$(printf '\xe2\x80\x93')" > "$TMP/en.md"
expect_fail "$TMP/en.md"

# --- encoded em-dash: an HTML entity or a \u escape renders a real dash but keeps the source ASCII,
# so the literal-byte scan misses it. Each of these must fail. ---
printf 'Signal grade encryption &mdash; on by default.\n' > "$TMP/ent-mdash.html"
expect_fail "$TMP/ent-mdash.html"
printf 'Fast &#8212; and quiet.\n' > "$TMP/ent-dec.html"
expect_fail "$TMP/ent-dec.html"
printf 'Untraceable &#x2014; by default.\n' > "$TMP/ent-hex.html"
expect_fail "$TMP/ent-hex.html"
printf 'const tagline = "spray \\u2014 wait";\n' > "$TMP/esc-u.ts"
expect_fail "$TMP/esc-u.ts"
printf 'const t = "sections 5 \\u2013 7";\n' > "$TMP/esc-en.ts"
expect_fail "$TMP/esc-en.ts"
# uppercase hex entity variant (&#X2014;) must also fail (the -i flag)
printf 'Quiet &#X2014; by default.\n' > "$TMP/ent-hexcap.html"
expect_fail "$TMP/ent-hexcap.html"
# --- clean copy that merely mentions an ampersand or the word mdash in prose: must pass ---
printf 'Ship it fast and quiet. No dashes here.\n' > "$TMP/clean2.md"
expect_pass "$TMP/clean2.md"

# --- F-4: zero-padded HTML entities and the CSS \NNNN escape also render a dash; all must fail ---
printf 'Fast &#08212; and quiet.\n' > "$TMP/ent-deczero.html"     # zero-padded decimal
expect_fail "$TMP/ent-deczero.html"
printf 'Quiet &#x02014; here.\n' > "$TMP/ent-hexzero.html"        # zero-padded hex
expect_fail "$TMP/ent-hexzero.html"
printf '.tag::after{content:"\\2014";}\n' > "$TMP/css-em.css"     # CSS escape, no u prefix
expect_fail "$TMP/css-em.css"
printf '.s::before{content:"\\002014";}\n' > "$TMP/css-emzero.css" # CSS zero-padded
expect_fail "$TMP/css-emzero.css"
printf 'const t = "x \\u{2014} y";\n' > "$TMP/esc-brace.ts"       # \u{...} brace form
expect_fail "$TMP/esc-brace.ts"
# clean copy with a dollar-number and ampersands must NOT false-positive on the encoded scan
# shellcheck disable=SC2016
printf 'Cost is $20140 and AT&T covers R&D.\n' > "$TMP/clean3.md"
expect_pass "$TMP/clean3.md"

# --- F-1: the word bans are case-INSENSITIVE now; lowercase/uppercase prose must fail ---
printf 'Chat over bluetooth with people nearby.\n' > "$TMP/bt-lc.md"
expect_fail "$TMP/bt-lc.md"
printf 'Connect via BLUETOOTH today.\n' > "$TMP/bt-uc.md"
expect_fail "$TMP/bt-uc.md"
printf 'Send to internetegress for the internet.\n' > "$TMP/eg-lc.md"
expect_fail "$TMP/eg-lc.md"
printf 'Android uses wi-fi direct for transfer.\n' > "$TMP/wfd-lc.md"
expect_fail "$TMP/wfd-lc.md"
# legit API identifiers are still NOT flagged even with case-insensitive matching (word-boundary spares them)
printf 'Drives BLE via CoreBluetooth and BluetoothAdapter.\n' > "$TMP/apis2.md"
expect_pass "$TMP/apis2.md"

# --- F-CI-3: a numeric HTML entity WITHOUT the trailing semicolon still renders a dash; must fail ---
printf 'Fast &#8212 and quiet.\n' > "$TMP/ent-nosemi.html"
expect_fail "$TMP/ent-nosemi.html"
printf 'Untraceable &#x2014 by default.\n' > "$TMP/ent-hexnosemi.html"
expect_fail "$TMP/ent-hexnosemi.html"
# --- F-CI-4: the two lookalike dash glyphs (U+2015 horizontal bar, U+2012 figure dash), literal + encoded ---
printf 'Hop is fast%buntraceable.\n' "$(printf '\xe2\x80\x95')" > "$TMP/hbar.md"
expect_fail "$TMP/hbar.md"
printf 'See 5%b7 sections.\n' "$(printf '\xe2\x80\x92')" > "$TMP/figdash.md"
expect_fail "$TMP/figdash.md"
printf 'Quiet &#8213; by default.\n' > "$TMP/hbar-ent.html"
expect_fail "$TMP/hbar-ent.html"

# --- PROC-001: U+2212 MINUS SIGN is the third lookalike, and it was live in source (a node.rs comment
# reading "received U+2212 created_at") while this guard reported OK over core/. Literal + all three
# encoded forms must fail, in BOTH passes, and an ASCII hyphen subtraction must still pass. ---
printf 'Latency is received%bcreated_at.\n' "$(printf '\xe2\x88\x92')" > "$TMP/minus.md"
expect_fail "$TMP/minus.md"
printf '// stamps `received%bcreated_at` into the ACK\n' "$(printf '\xe2\x88\x92')" > "$TMP/minus-src.rs"
expect_src_fail "$TMP/minus-src.rs"
printf 'Chunks of MTU &#8722; 3 bytes.\n' > "$TMP/minus-dec.html"
expect_fail "$TMP/minus-dec.html"
printf 'Chunks of MTU &#x2212; 3 bytes.\n' > "$TMP/minus-hex.html"
expect_fail "$TMP/minus-hex.html"
printf 'const t = "MTU \\u2212 3";\n' > "$TMP/minus-esc.ts"
expect_src_fail "$TMP/minus-esc.ts"
printf '.m::after{content:"\\2212";}\n' > "$TMP/minus-css.css"
expect_fail "$TMP/minus-css.css"
# the ASCII replacement is what the fix uses, so it must NOT be flagged
printf '// stamps `received - created_at` into the ACK; chunks of `MTU - 3`\n' > "$TMP/minus-ascii.rs"
expect_src_pass "$TMP/minus-ascii.rs"
# --- F-CI-5: bare marketing "bluetooth-<word>" must fail; the two real iOS background-mode ids must pass ---
printf 'A bluetooth-powered mesh nearby.\n' > "$TMP/bt-powered.md"
expect_fail "$TMP/bt-powered.md"
printf 'Hop is fully bluetooth-free, no GATT.\n' > "$TMP/bt-free.md"
expect_fail "$TMP/bt-free.md"
printf 'UIBackgroundModes: bluetooth-central and bluetooth-peripheral.\n' > "$TMP/bt-bgmodes.md"
expect_pass "$TMP/bt-bgmodes.md"

# --- docs-drift-03: the SOURCE pass. The repo law bans em/en-dashes in CODE too, but for years
# this guard only read docs, so source drifted to ~1000 dashes. These cases lock the new coverage. ---

# a dash in a SOURCE file must fail (literal, and the encoded form that keeps the bytes ASCII)
printf '// the node loop%bthe orchestration.\n' "$(printf '\xe2\x80\x94')" > "$TMP/src.rs"
expect_src_fail "$TMP/src.rs"
printf 'val tag = "spray \\u2014 wait" // Kotlin\n' > "$TMP/src.kt"
expect_src_fail "$TMP/src.kt"
printf '/// see sections 5%b7\n' "$(printf '\xe2\x80\x93')" > "$TMP/src.swift"
expect_src_fail "$TMP/src.swift"
printf '# a shell comment%bwith a lookalike\n' "$(printf '\xe2\x80\x95')" > "$TMP/src.sh"
expect_src_fail "$TMP/src.sh"

# --- generated output must never be scanned. UniFFI/cbindgen emit dashes in their own prose, and
# apps/android/HopDemo/generated is gitignored + untracked. Because the exclude list did not name it,
# the guard passed in CI and on a clean checkout but FAILED for anyone who had run
# tools/build-aar.sh for a device: a guard whose verdict depends on local build state, reporting a
# violation in prose no human wrote. This case fails without --exclude-dir=generated.
gen_repo="$TMP/genrepo"
make_fixture_repo "$gen_repo"
mkdir -p "$gen_repo/apps/android/HopDemo/generated/kotlin/uniffi/hop"
printf '// The provided buffer MUST be direct%bonly direct buffers work.\n' "$(printf '\xe2\x80\x94')" \
  > "$gen_repo/apps/android/HopDemo/generated/kotlin/uniffi/hop/hop.kt"
expect_tree_pass "$gen_repo"

# ...but the SAME dash in hand-written app source right beside it must still be caught.
printf '// a real hand-written comment%bwith a dash\n' "$(printf '\xe2\x80\x94')" \
  > "$gen_repo/apps/android/HopDemo/Real.kt"
expect_tree_fail "$gen_repo"
rm -f "$gen_repo/apps/android/HopDemo/Real.kt"

# clean source must pass
printf '// the node loop, the orchestration that turns pieces into a mesh.\n' > "$TMP/src-clean.rs"
expect_src_pass "$TMP/src-clean.rs"

# the source pass is dash-only ON PURPOSE: real API identifiers and transport tags in bearer code
# must NOT trip it (they are legitimate code, not marketing copy).
printf 'import CoreBluetooth\nlet tag = "Wi-Fi Direct" // transport label\n// Bluetooth is off\n' > "$TMP/src-api.swift"
expect_src_pass "$TMP/src-api.swift"

# --- the DEFAULT scan set really includes the source trees (not just an explicitly-passed path) ---
FIX_HIT="$TMP/repo-hit"
make_fixture_repo "$FIX_HIT"
printf '// a comment%bwith a dash\n' "$(printf '\xe2\x80\x94')" > "$FIX_HIT/core/hop-core/src/node.rs"
expect_tree_fail "$FIX_HIT"

# --- the retired wire-manifest carve-out stays retired (audit PROC-001). A manifest-listed file
# used to be EXCLUDED from the source pass, on a promise to clean it "at the next real wire bump"
# that two bumps came and went without honouring. This asserts the opposite of the old behaviour:
# the same dash in a manifest-listed path must now FAIL, exactly like any other source file. It is
# the regression net for the exclusion coming back, whether by revert or by a well-meaning re-add:
# with SRC_SKIP_RE restored, this fixture passes the guard and this case goes red. ---
FIX_MANIFEST="$TMP/repo-manifest"
make_fixture_repo "$FIX_MANIFEST"
printf '// a comment%bwith a dash\n' "$(printf '\xe2\x80\x94')" > "$FIX_MANIFEST/core/hop-core/src/bundle.rs"
expect_tree_fail "$FIX_MANIFEST"

# The encoded forms are not a loophole either: an HTML entity in a manifest-listed file renders a
# real dash and must fail through the same path.
FIX_MANIFEST_ENC="$TMP/repo-manifest-encoded"
make_fixture_repo "$FIX_MANIFEST_ENC"
printf '// a comment &mdash; with an encoded dash\n' > "$FIX_MANIFEST_ENC/core/hop-core/src/bundle.rs"
expect_tree_fail "$FIX_MANIFEST_ENC"

# --- ...and the net covers EVERY manifest-listed path, not just bundle.rs. Asserting one file left a
# hole big enough to walk through: re-adding a SINGLE-file exclusion for a DIFFERENT manifest path
# (--exclude='crypto.rs') restored the carve-out for that file and still passed this self-test, so
# only deleting the manifest-reading block wholesale was caught. This loops the REAL manifest and
# demands a failure per path, so the net is exactly as wide as the carve-out could ever be, and it
# widens by itself when a path is added to the manifest. ---
REAL_MANIFEST="$(cd "$HERE/.." && pwd)/core/hop-core/vectors/wire-source-manifest.txt"
manifest_paths=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '' | '#'*) continue ;; esac
  manifest_paths+=("$line")
done < "$REAL_MANIFEST"
# Read zero paths and the loop below would vacuously pass, which is the same trust-a-green-result
# failure this whole case exists to close. Fail loudly instead.
if [ "${#manifest_paths[@]}" -lt 2 ]; then
  fail=$((fail + 1))
  echo "FAIL: read ${#manifest_paths[@]} path(s) from $REAL_MANIFEST; the per-path net would be empty or trivial"
fi
for mp in "${manifest_paths[@]:-}"; do
  case "$mp" in *.rs) ;; *) continue ;; esac
  d="$TMP/repo-mf-$(printf '%s' "$mp" | tr '/.' '__')"
  make_fixture_repo "$d" "$mp"
  mkdir -p "$d/$(dirname "$mp")"
  printf '// a comment%bwith a dash\n' "$(printf '\xe2\x80\x94')" > "$d/$mp"
  expect_tree_fail "$d"
done

# --- generated/vendored output is excluded from the source pass (a rewrite there is undone by the
# next regeneration): a dash in target/, node_modules/, a CHANGELOG, or a captured .log must pass ---
FIX_GEN="$TMP/repo-gen"
make_fixture_repo "$FIX_GEN"
mkdir -p "$FIX_GEN/core/target/debug" "$FIX_GEN/core/node_modules/x" "$FIX_GEN/testkit/results"
printf 'build artifact%bhere\n' "$(printf '\xe2\x80\x94')" > "$FIX_GEN/core/target/debug/out.txt"
printf 'vendored%bhere\n' "$(printf '\xe2\x80\x94')" > "$FIX_GEN/core/node_modules/x/index.js"
printf '## v1%bnotes\n' "$(printf '\xe2\x80\x94')" > "$FIX_GEN/core/CHANGELOG.md"
printf 'device log%bline\n' "$(printf '\xe2\x80\x94')" > "$FIX_GEN/testkit/results/r1.log"
expect_tree_pass "$FIX_GEN"

# --- the guard must read every tree ci.yml dispatches it on -------------------------------------
# The `docs` path filter names '.github/workflows/**' as a reason to RUN this guard, but the default
# target lists never contained .github, so a dash could land in any workflow comment (ci.yml alone is
# ~1200 prose-dense lines) with the Docs token guard job green. CLAUDE.md names this guard as the
# enforcement of a repo-wide ban, so a green run there asserted a property it had not checked.
FIX_GH="$TMP/repo-github"
make_fixture_repo "$FIX_GH"
mkdir -p "$FIX_GH/.github/workflows"
printf '# a workflow comment%bwith a dash\nname: ci\n' "$(printf '\xe2\x80\x94')" \
  > "$FIX_GH/.github/workflows/ci.yml"
expect_tree_fail "$FIX_GH"

# mockups/** dispatches the wasm and web jobs and ships hand-written HTML/JS; it was unscanned too.
FIX_MOCK="$TMP/repo-mockups"
make_fixture_repo "$FIX_MOCK"
mkdir -p "$FIX_MOCK/mockups"
printf '<p>fast%buntraceable</p>\n' "$(printf '\xe2\x80\x94')" > "$FIX_MOCK/mockups/swarm.html"
expect_tree_fail "$FIX_MOCK"

# Root markdown beyond the three files the doc pass named (CLAUDE.md, CONTRIBUTING.md, SECURITY.md).
FIX_ROOT="$TMP/repo-rootmd"
make_fixture_repo "$FIX_ROOT"
printf 'Contributing%bread this first.\n' "$(printf '\xe2\x80\x94')" > "$FIX_ROOT/CONTRIBUTING.md"
expect_tree_fail "$FIX_ROOT"

# And the mapping itself: every path pattern in ci.yml's `docs` filter must resolve to a tree the
# guard's default target lists actually read, so the filter can never again dispatch a guard that is
# blind to the very change that dispatched it.
if ! python3 - "$HERE/.." <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
ci = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
guard = (root / "tools/docs-token-guard.sh").read_text(encoding="utf-8")

block = re.search(r"(?ms)^            docs:\n(.*?)(?=^            [a-z_]+:\n)", ci)
if block is None:
    raise SystemExit("ci.yml `docs` path filter not found")
patterns = re.findall(r"^\s+- '([^']+)'$", block.group(1), re.MULTILINE)
if not patterns:
    raise SystemExit("ci.yml `docs` filter has no patterns")


def targets(name):
    match = re.search(rf"(?ms)^  {name}=\((.*?)^  \)", guard)
    if match is None:
        raise SystemExit(f"docs-token-guard.sh {name} block not found")
    return set(re.findall(r'"([^"]+)"', match.group(1)))


covered = targets("REQUESTED") | targets("SRC_REQUESTED")
# Root markdown is added by a glob over ./*.md rather than being spelled out.
root_markdown = "for root_markdown in ./*.md" in guard
missing = []
for pattern in patterns:
    head = pattern.split("/", 1)[0].removeprefix("**")
    if pattern.endswith(".md") and "/" not in pattern:
        if not root_markdown and pattern not in covered:
            missing.append(pattern)
        continue
    if pattern.startswith("**/"):
        # A nested pattern is covered when the tree that can hold it is scanned; every one of these
        # (README.md, LICENSE.md, .github/workflows) lives under a scanned tree or under .github.
        head = pattern.split("/")[1] if pattern.count("/") > 1 else pattern.split("/", 1)[1]
        if head.endswith(".md"):
            continue
    if head and head not in covered:
        missing.append(pattern)
if missing:
    raise SystemExit(
        "ci.yml `docs` filter dispatches the guard on paths it does not scan: " + ", ".join(missing)
    )
PY
then
  fail=$((fail + 1)); echo "FAIL: the docs path filter names trees the guard does not scan"
else
  pass=$((pass + 1))
fi

echo "docs-token-guard.test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
