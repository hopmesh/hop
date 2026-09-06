#!/usr/bin/env bash
# Self-test for tools/codegen/check-abi-version.sh (PLAT-004).
#
# The guard it tests used to be a fixed list of six paths whose header claimed to cover "every place"
# the ABI version is declared. It had NO self-test, so nothing ever asked whether that claim was true,
# and it was not: the v4 -> v5 bump left tools/package-export-smoke.py asserting the retired level and
# two SDK docs telling integrators the same. The whole point of this file is to make the guard's own
# coverage falsifiable, so each case below is a specific way the guard could go blind again.
#
# Every case runs against a synthetic tree (HOP_ABI_GUARD_ROOT), never the repo, and every expected
# value is derived from the fixture rather than written as a literal: a self-test that freezes a number
# is the exact defect that produced PLAT-004, since the smoke test's fixture and the validator it
# checked drifted together and could never disagree.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/check-abi-version.sh"
ABI=5          # the version the fixture pins everywhere
STALE=4        # a retired level, for the drift cases
pass=0
fail=0

# lay_down DIR: a fully healthy synthetic tree the guard passes. Mirrors the real layout: the Rust
# const, both generated headers (with a bump note naming one call), a wrapper per language that pins
# the constant AND binds the named call, and a validator. Callers then mutate one thing.
lay_down() {
  local d="$1"
  mkdir -p "$d/tools/codegen" "$d/core/hop/src" "$d/core/hop/include" "$d/sdk" \
           "$d/sdk/apple/Sources/Hop" "$d/sdk/android/src/main/kotlin/sh/hop" \
           "$d/sdk/embedded/src" "$d/sdk/go/cmd/hop-install" "$d/sdk/node/lib" \
           "$d/sdk/python/hop_endpoint" "$d/sdk/ruby/lib/hop" "$d/sdk/crystal/src/hop" \
           "$d/sdk/flutter/lib/src"
  cp "$GUARD" "$d/tools/codegen/check-abi-version.sh"
  cp "$HERE/generate-abi-manifest.py" "$d/tools/codegen/generate-abi-manifest.py"
  cp "$HERE/verify-abi-signatures.py" "$d/tools/codegen/verify-abi-signatures.py"
  printf 'pub const HOP_ABI_VERSION: u32 = %s;\n' "$ABI" > "$d/core/hop/src/cabi.rs"

  # Both headers carry the bump note. hop_relay_next is the call the note names, so every wrapper has
  # to reference it; that is the PLAT-003 leg.
  local header="$d/sdk/hop.h"
  {
    printf '// The libhop C-ABI version.\n'
    printf '//\n'
    printf '// v%s -> v%s: added `hop_relay_next`.\n' "$STALE" "$ABI"
    printf '//\n'
    printf '// Unrelated prose that must not be scanned for symbols: hop_never_bound.\n'
    printf '#define HOP_ABI_VERSION %s\n' "$ABI"
    printf 'uintptr_t hop_relay_next(const struct HopNode *node, char *out, uintptr_t out_cap);\n'
  } > "$header"
  cp "$header" "$d/core/hop/include/hop.h"
  python3 "$HERE/generate-abi-manifest.py" "$header" "$d/tools/codegen/abi-manifest.json"
  printf 'public static let expectedABIVersion: UInt32 = %s\nhop_relay_next(raw, &buf, 0)\n' "$ABI" \
    > "$d/sdk/apple/Sources/Hop/Hop.swift"
  printf 'const val HOP_ABI_VERSION = %s\nfun hop_relay_next(node: Pointer?, out: Pointer?, cap: Long)\n' "$ABI" \
    > "$d/sdk/android/src/main/kotlin/sh/hop/Hop.kt"
  printf '#define HOP_EMBEDDED_ABI_VERSION %s\nuintptr_t hop_relay_next(const struct HopNode *node, char *out, uintptr_t out_cap);\n' "$ABI" \
    > "$d/sdk/embedded/src/Hop.h"
  printf 'const abiExpected = %s\nC.hop_relay_next(n.node, outBuf, outCap)\n' "$ABI" > "$d/sdk/go/hop.go"
  cat << EOF > "$d/sdk/flutter/lib/src/ffi.dart"
const int hopAbiVersion = $ABI;
typedef _RelayNextC = Size Function(Pointer<Void>, Pointer<Utf8>, Size);
late final _relayNext = _lib.lookupFunction<_RelayNextC, _RelayNextC>('hop_relay_next');
EOF
  printf 'const ABI_EXPECTED = %s\nlib.func("size_t hop_relay_next(void *node, char *out, size_t out_cap)")\n' "$ABI" \
    > "$d/sdk/node/lib/ffi.mjs"
  printf '_ABI_EXPECTED = %s\n_lib.hop_relay_next.argtypes = [c_void_p, c_char_p, c_size_t]\n' "$ABI" \
    > "$d/sdk/python/hop_endpoint/_ffi.py"
  printf 'ABI_EXPECTED = %s\nRELAY_NEXT = fn("hop_relay_next", [P, P, SZ], SZ)\n' "$ABI" \
    > "$d/sdk/ruby/lib/hop/ffi.rb"
  printf 'ABI_EXPECTED = %s_u32\nfun relay_next = hop_relay_next(node : Void*, out : LibC::Char*, out_cap : LibC::SizeT)\n' "$ABI" \
    > "$d/sdk/crystal/src/hop/ffi.cr"
  printf 'if !strings.Contains(string(header), "#define HOP_ABI_VERSION %s") {\n' "$ABI" \
    > "$d/sdk/go/cmd/hop-install/main.go"
  printf 'os.WriteFile("hop.h", []byte("#define HOP_ABI_VERSION %s\\n"), 0644)\n' "$ABI" \
    > "$d/sdk/go/cmd/hop-install/builder_test.go"
}

# expect DIR WANT(pass|fail) LABEL [grep-for]
expect() {
  local d="$1" want="$2" label="$3" needle="${4:-}" got out
  out="$(HOP_ABI_GUARD_ROOT="$d" bash "$d/tools/codegen/check-abi-version.sh" 2>&1)"
  if [ $? -eq 0 ]; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    fail=$((fail + 1)); echo "FAIL [$label]: expected $want, guard $got"
    printf '%s\n' "$out" | sed 's/^/    /' | head -6
    return
  fi
  if [ -n "$needle" ] && ! printf '%s\n' "$out" | grep -q "$needle"; then
    fail=$((fail + 1)); echo "FAIL [$label]: guard $got but never said \"$needle\""
    printf '%s\n' "$out" | sed 's/^/    /' | head -6
    return
  fi
  pass=$((pass + 1)); echo "ok   [$label]: guard $got as expected"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (a) A healthy tree passes, and says so in terms of what it actually checked.
lay_down "$work/healthy"
expect "$work/healthy" pass "healthy tree" "is consistent ($ABI)"

# (b) THE CASE THAT WOULD HAVE CAUGHT PLAT-004. A packaging assertion in tools/ pins a retired level.
# The old guard read six fixed paths and never looked in tools/, so this drift shipped and sat there.
lay_down "$work/tools-drift"
printf 'require(b"#define HOP_ABI_VERSION %s\\n" in headers[0])\n' "$STALE" \
  > "$work/tools-drift/tools/package-export-smoke.py"
expect "$work/tools-drift" fail "stale literal in tools/ (the PLAT-004 drift)" "package-export-smoke.py"

# (c) A drifted copy in a path on NO list at all, in a language the guard was never taught about. The
# sweep must catch it because it reads the tree, not a roster.
lay_down "$work/unknown-lang"
mkdir -p "$work/unknown-lang/sdk/zig/src"
printf 'const ABI_EXPECTED = %s;\n' "$STALE" > "$work/unknown-lang/sdk/zig/src/hop.zig"
expect "$work/unknown-lang" fail "drifted copy in an unlisted path" "hop.zig"

# (d) A NEW copy that agrees on the number is still a failure until it is classified. Agreement today
# is not coverage tomorrow: an unlisted site is one nobody has taken responsibility for.
lay_down "$work/unclassified"
mkdir -p "$work/unclassified/sdk/zig/src"
printf 'const ABI_EXPECTED = %s;\n' "$ABI" > "$work/unclassified/sdk/zig/src/hop.zig"
expect "$work/unclassified" fail "unclassified copy that happens to agree" "UNCLASSIFIED"

# (e) A wrapper that pins the level but binds none of the calls the bump note names. This is PLAT-003
# verbatim: the header claimed the v5 bump bought relay failover while no wrapper exposed it.
lay_down "$work/unbound"
printf 'const ABI_EXPECTED = %s\n// binds nothing\n' "$ABI" > "$work/unbound/sdk/node/lib/ffi.mjs"
expect "$work/unbound" fail "wrapper pins the level but binds no v$ABI call" "hop_relay_next"

# (f) A renamed or deleted constant. The wrapper still loads, but its assertion now checks nothing, so
# silence here would be the worst outcome: a guard reporting green over an assertion that cannot fire.
lay_down "$work/renamed"
printf 'const SOME_OTHER_NAME = %s\nlib.func("size_t hop_relay_next(void *node)")\n' "$ABI" \
  > "$work/renamed/sdk/node/lib/ffi.mjs"
expect "$work/renamed" fail "constant renamed out of a wrapper" "no longer declares"

# (g) Prose stating a retired level. sdk/embedded/README.md and sdk/node/CLAUDE.md both told
# integrators the wrapper asserts the old level long after the bump; nothing checked English.
lay_down "$work/stale-prose"
printf 'begin() asserts ABI %s through hop_abi_version().\n' "$STALE" \
  > "$work/stale-prose/sdk/embedded/README.md"
expect "$work/stale-prose" fail "doc states a retired ABI level" "stale ABI claim"

# (h) Prose stating the CURRENT level passes, so the check is not just "no numbers near the word ABI".
lay_down "$work/good-prose"
printf 'begin() asserts ABI %s through hop_abi_version().\n' "$ABI" \
  > "$work/good-prose/sdk/embedded/README.md"
expect "$work/good-prose" pass "doc states the current ABI level"

# (i) The source of truth itself drifting from the generated header, the original core-ffi-08 case.
lay_down "$work/header-drift"
printf '#define HOP_ABI_VERSION %s\n' "$STALE" > "$work/header-drift/sdk/hop.h"
expect "$work/header-drift" fail "generated header drifts from the Rust const" "mismatch"

# (j) The pattern going blind. If DECL_RE ever stops matching, a sweep-based guard would otherwise
# report a serene green over a tree it read nothing from.
lay_down "$work/no-decls"
printf 'pub const HOP_ABI_VERSION: u32 = %s;\n' "$ABI" > "$work/no-decls/core/hop/src/cabi.rs"
rm -rf "$work/no-decls/sdk" "$work/no-decls/core/hop/include"
expect "$work/no-decls" fail "known sites missing entirely" "not found"

# (k) ABI-009: A wrapper that mentions the symbol only in a comment must fail.
lay_down "$work/comment-only"
printf '#define HOP_EMBEDDED_ABI_VERSION %s\n// calls hop_relay_next in comment only\n' "$ABI" \
  > "$work/comment-only/sdk/embedded/src/Hop.h"
expect "$work/comment-only" fail "wrapper mentions call only in comment" "hop_relay_next"

# (l) ABI-009: A wrapper that mentions the symbol only in a string literal must fail.
lay_down "$work/string-literal"
printf 'const ABI_EXPECTED = %s\nconst fn = "hop_relay_next";\n' "$ABI" \
  > "$work/string-literal/sdk/node/lib/ffi.mjs"
expect "$work/string-literal" fail "wrapper mentions call only in string literal" "hop_relay_next"

# (m) ABI-009: A wrapper with wrong arity (1 param instead of 3 for hop_relay_next) must fail.
lay_down "$work/wrong-arity"
printf 'const ABI_EXPECTED = %s\nlib.func("size_t hop_relay_next(void *node)")\n' "$ABI" \
  > "$work/wrong-arity/sdk/node/lib/ffi.mjs"
expect "$work/wrong-arity" fail "wrapper binds symbol with wrong parameter arity" "arity mismatch"

# (n) ABI-009: A header change that is not reflected in the manifest must fail.
lay_down "$work/manifest-drift"
printf 'uintptr_t hop_unmanifested_call(void);\n' >> "$work/manifest-drift/sdk/hop.h"
expect "$work/manifest-drift" fail "header change not reflected in manifest" "ABI manifest drift"

# (o) ABI-016: A wrapper binding signed error-returning function (hop_hps_rekey) as unsigned must fail.
lay_down "$work/unsigned-rekey"
printf 'intptr_t hop_hps_rekey(const struct HopNode *node, const char *path, const char *new_path, const uint8_t *remove, size_t remove_count, void (*sink)(void *ctx, const uint8_t *id), void *ctx);\n' >> "$work/unsigned-rekey/sdk/hop.h"
cp "$work/unsigned-rekey/sdk/hop.h" "$work/unsigned-rekey/core/hop/include/hop.h"
python3 "$HERE/generate-abi-manifest.py" "$work/unsigned-rekey/sdk/hop.h" "$work/unsigned-rekey/tools/codegen/abi-manifest.json" >/dev/null
cat << 'EOF' >> "$work/unsigned-rekey/sdk/node/lib/ffi.mjs"
export const HpsIdSink = koffi.proto('void HpsIdSink(void *ctx, uint8_t *id)')
lib.func('size_t hop_hps_rekey(void *node, const char *path, const char *new_path, uint8_t *remove, size_t remove_count, HpsIdSink *sink, void *ctx)')
EOF
expect "$work/unsigned-rekey" fail "signed error-returning function bound to unsigned type" "signedness mismatch"

# (p) ABI-016: A wrapper with void-returning service request sink (must be bool) must fail.
lay_down "$work/void-sink"
printf 'void hop_poll_service_requests(const struct HopNode *node, bool (*sink)(void *ctx, const uint8_t *from, const uint8_t *request_id, const char *service, const char *method, const uint8_t *args, uintptr_t args_len), void *ctx);\n' >> "$work/void-sink/sdk/hop.h"
cp "$work/void-sink/sdk/hop.h" "$work/void-sink/core/hop/include/hop.h"
python3 "$HERE/generate-abi-manifest.py" "$work/void-sink/sdk/hop.h" "$work/void-sink/tools/codegen/abi-manifest.json" >/dev/null
cat << 'EOF' >> "$work/void-sink/sdk/node/lib/ffi.mjs"
export const SvcReqSink = koffi.proto('void SvcReqSink(void *ctx, uint8_t *from, uint8_t *request_id, const char *service, const char *method, uint8_t *args, size_t args_len)')
lib.func('void hop_poll_service_requests(void *node, SvcReqSink *sink, void *ctx)')
EOF
expect "$work/void-sink" fail "callback trampoline with void return instead of bool" "callback return mismatch"

# (q) ABI-016: A wrapper with wrong-width integer (32-bit instead of 64-bit) must fail.
lay_down "$work/wrong-width"
printf 'const ABI_EXPECTED = %s\nlib.func("size_t hop_relay_next(void *node, char *out, uint32_t out_cap)")\n' "$ABI" \
  > "$work/wrong-width/sdk/node/lib/ffi.mjs"
expect "$work/wrong-width" fail "wrapper binds symbol with wrong integer width" "width mismatch"

# (r) ABI-016: Run generator and verifier self-tests
python3 "$HERE/generate-abi-manifest.py" --self-test >/dev/null
python3 "$HERE/verify-abi-signatures.py" --self-test >/dev/null
echo "ok   [generator and verifier self-tests]: pass as expected"
pass=$((pass + 1))

echo "check-abi-version self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
