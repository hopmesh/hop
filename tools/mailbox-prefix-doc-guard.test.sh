#!/usr/bin/env bash
# Self-test for tools/mailbox-prefix-doc-guard.sh. The guard ties the DOCUMENTED mailbox routing-prefix
# width to `crypto::MAILBOX_ROUTE_PREFIX_BYTES`, which drifted for three consecutive wire versions
# (audit PROTO-004). A guard is only worth its green result if it still reddens on the drift that
# motivated it, so this fixture reproduces each failure mode explicitly:
#
#   (a) the real repository passes
#   (b) the CONSTANT changes while the prose does not (the exact v12 regression) -> fail
#   (c) the prose is corrected but a STALE canonical line is left behind next to it -> fail
#   (d) a fresh stale sentence ("2-byte prefix") is added to a scanned surface -> fail
#   (e) a bit-count claim ("16 bits") on a mailbox line -> fail
#   (f) the canonical line is DELETED rather than corrected -> fail (silence must not pass)
#   (g) the canonical line stated twice in one surface -> fail (one of the two would rot)
#   (h) a legitimately SCOPED counterfactual (`w=2 (65_536 buckets)`) -> pass
#   (i) a legitimately SCOPED version-history entry (`2 bytes AS OF v3`) -> pass
#   (j) the fixed 2-byte ABI SLOT wording -> pass
#   (k) a "16-byte mailbox tag" (a real, width-independent figure) -> pass, never read as 16 BITS
#   (l) a required surface missing entirely -> fail
#   (m) two constant declarations -> fail (an ambiguous dial is not a checkable one)
#   (n) a bare version-shaped token (a KDF label like H("v2" ...)) is not a scope -> fail
#
# No repository state is mutated: every case runs the guard against a temp fixture tree.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/mailbox-prefix-doc-guard.sh"
pass=0
fail=0

canonical() {
  local w="$1" b=1 i
  for ((i = 0; i < w; i++)); do b=$((b * 256)); done
  printf 'MAILBOX_ROUTE_PREFIX_BYTES = %s => %s buckets, anonymity set ~N/%s, set of one below ~%s reachable addresses\n' \
    "$w" "$b" "$b" "$b"
}

# lay_down DIR WIDTH: a minimal tree with every surface the guard declares, all consistent at WIDTH.
lay_down() {
  local d="$1" w="$2" line
  line="$(canonical "$w")"
  mkdir -p "$d/core/hop-core/src" "$d/core/hop/src" "$d/services/hop-relayd/src" "$d/sdk"
  {
    printf '/// A routing prefix width doc block.\n'
    printf '///\n'
    printf '/// %s\n' "$line"
    printf 'pub const MAILBOX_ROUTE_PREFIX_BYTES: usize = %s;\n' "$w"
  } > "$d/core/hop-core/src/crypto.rs"
  printf '# Design\n\nThe mailbox routing prefix, normatively:\n\n%s\n' "$line" > "$d/DESIGN.md"
  printf '// a mailbox changelog with no width figure\n' > "$d/core/hop-core/src/bundle.rs"
  printf '// the recv-beacon carries a route prefix\n' > "$d/core/hop-core/src/node.rs"
  printf '// Wire::RecvBeacon carries the routing prefix\n' > "$d/core/hop-core/src/wire_emit.rs"
  printf '// the vector derives its mailbox route from the constant\n' > "$d/core/hop-core/src/wire_vectors.rs"
  printf '/// mailbox metadata\n' > "$d/core/hop/src/cabi.rs"
  printf '// the relay spools by the mailbox route prefix\n' > "$d/services/hop-relayd/src/main.rs"
  printf '// mailbox: a routing prefix\n' > "$d/sdk/hop.h"
  printf '| mailbox | a routing prefix |\n' > "$d/MECHANISMS.md"
  # printf '%s' with the text as an ARGUMENT: a leading dash in the format string is parsed as an
  # option, which silently wrote an empty SECURITY.md fixture on the first version of this file.
  printf '%s\n' '- the private header carries a short routing prefix' > "$d/SECURITY.md"
}

# expect DIR WANT(pass|fail) LABEL
expect() {
  local d="$1" want="$2" label="$3" got
  if bash "$GUARD" "$d" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "ok   [$label]: guard $got as expected"
  else
    fail=$((fail + 1))
    echo "FAIL [$label]: expected $want, guard $got"
    bash "$GUARD" "$d" 2>&1 | sed 's/^/    /' | head -4
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# (a) the real tree. This is the case that would have been red for wire v12, v13 and v14.
expect "$ROOT" pass "real_repository"

# (b) THE regression: the dial turns, the prose does not.
lay_down "$TMP/drift" 1
sed -i.bak 's/usize = 1;/usize = 2;/' "$TMP/drift/core/hop-core/src/crypto.rs"
rm -f "$TMP/drift/core/hop-core/src/crypto.rs.bak"
expect "$TMP/drift" fail "constant_moved_prose_did_not"

# (c) corrected in place but the old canonical sentence survives beside it. This is how DESIGN.md §39
# came to contradict itself inside one section.
lay_down "$TMP/leftover" 1
canonical 2 >> "$TMP/leftover/DESIGN.md"
expect "$TMP/leftover" fail "stale_canonical_left_behind"

# (d) a fresh stale sentence of the exact shape the finding names.
lay_down "$TMP/stale_bytes" 1
printf 'Do NOT rely on the fixed 2-byte mailbox prefix for anonymity.\n' >> "$TMP/stale_bytes/DESIGN.md"
expect "$TMP/stale_bytes" fail "stale_byte_width_sentence"

# (e) the same claim expressed in bits, which is how crypto.rs stated it ("Two bytes (16 bits)").
lay_down "$TMP/stale_bits" 1
printf '// the mailbox routing prefix is 16 bits wide\n' >> "$TMP/stale_bits/core/hop-core/src/node.rs"
expect "$TMP/stale_bits" fail "stale_bit_width_sentence"

# (f) deleting the claim must not be a way to pass. A surface that says nothing is not a surface that
# agrees; the whole point is that an auditor can read the number somewhere normative.
lay_down "$TMP/deleted" 1
printf '# Design\n\nno numbers here\n' > "$TMP/deleted/DESIGN.md"
expect "$TMP/deleted" fail "canonical_claim_deleted"

# (g) stated twice in one surface: the next correction fixes one and leaves the other.
lay_down "$TMP/twice" 1
canonical 1 >> "$TMP/twice/DESIGN.md"
expect "$TMP/twice" fail "canonical_claim_duplicated"

# (h) the w=1 vs w=2 table under the constant is a NAMED counterfactual and must keep working.
lay_down "$TMP/counterfactual" 1
printf '//     w=2 (65_536 buckets)   N=1k -> 0.02\n' >> "$TMP/counterfactual/core/hop-core/src/crypto.rs"
printf '// At w=2 the mailbox anonymity set was a unique identifier, 2-byte prefix and all.\n' \
  >> "$TMP/counterfactual/core/hop-core/src/crypto.rs"
expect "$TMP/counterfactual" pass "scoped_counterfactual_allowed"

# (i) bundle.rs's v3 changelog entry really did ship a 2-byte prefix. Renumbering it would falsify the
# history the list exists to record, so a v<n>-scoped line is allowed.
lay_down "$TMP/history" 1
printf '//   * sec-priv-04: key on the mailbox-tag PREFIX, 2 bytes AS OF v3, narrowed later.\n' \
  >> "$TMP/history/core/hop-core/src/bundle.rs"
expect "$TMP/history" pass "scoped_version_history_allowed"

# (j) the published C ABI has a FIXED 2-byte metadata slot carrying a variable-width prefix. That 2 is
# correct at any width, and sdk/hop.h is cbindgen output that cannot be hand-corrected anyway.
lay_down "$TMP/slot" 1
printf '// mailbox is a FIXED 2-byte slot carrying a VARIABLE-WIDTH routing prefix.\n' \
  >> "$TMP/slot/sdk/hop.h"
expect "$TMP/slot" pass "abi_slot_allowed"

# (k) the mailbox TAG is 16 bytes at every prefix width. A byte figure must never be read as a bit
# figure, or the guard would demand the tag length change with the dial.
lay_down "$TMP/tag" 1
printf '// the full 16-byte mailbox tag never travels; only its 1-byte prefix does.\n' \
  >> "$TMP/tag/core/hop-core/src/wire_emit.rs"
expect "$TMP/tag" pass "sixteen_byte_tag_is_not_sixteen_bits"

# (n) a bare version-SHAPED token must NOT buy an exemption. `mailbox_tag`'s own doc line carries the
# KDF domain separator H("v2" ...), which is a label, not a statement about when the prefix was 2 bytes.
# A loose \bv[0-9]+\b scope would have exempted exactly the line the finding lived next to.
lay_down "$TMP/kdf_label" 1
printf '%s\n' '/// mailbox_tag is H("v2" || address || epoch) with a 2-byte routing prefix.' \
  >> "$TMP/kdf_label/core/hop-core/src/crypto.rs"
expect "$TMP/kdf_label" fail "bare_version_token_is_not_a_scope"

# (l) a declared surface that has gone missing (renamed, moved) must redden, not silently narrow scope.
lay_down "$TMP/missing" 1
rm -f "$TMP/missing/MECHANISMS.md"
expect "$TMP/missing" fail "declared_surface_missing"

# (m) two declarations of the dial: which one is shipped is then unknowable, so the guard must refuse
# rather than pick one.
lay_down "$TMP/ambiguous" 1
printf 'pub const MAILBOX_ROUTE_PREFIX_BYTES: usize = 2;\n' >> "$TMP/ambiguous/core/hop-core/src/crypto.rs"
expect "$TMP/ambiguous" fail "two_constant_declarations"

echo
echo "mailbox-prefix-doc-guard self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
