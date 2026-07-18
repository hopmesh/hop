#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${FUZZ_RUNS:-256}"
SEED="${FUZZ_SEED:-424242}"
TOOLCHAIN="${CARGO_FUZZ_TOOLCHAIN:-nightly-2026-07-07}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$RUNS" in
  ''|*[!0-9]*) echo "error: FUZZ_RUNS must be a positive integer" >&2; exit 2 ;;
  0) echo "error: FUZZ_RUNS must be greater than zero" >&2; exit 2 ;;
esac

targets=(
  bundle_parse_verify
  link_framing_reassembly
  ratchet_message
  store_operations
  c_abi_adversarial
)

for target in "${targets[@]}"; do
  corpus="$WORK/$target"
  mkdir "$corpus"
  cp "$ROOT/fuzz/corpus/$target"/* "$corpus/"
  echo "==> fuzz smoke: $target ($RUNS iterations, seed $SEED)"
  cargo +"$TOOLCHAIN" fuzz run "$target" "$corpus" -- \
    -runs="$RUNS" -seed="$SEED" -max_len=262144 -print_final_stats=1
done

echo "fuzz smoke passed: ${#targets[@]} targets x $RUNS iterations"
