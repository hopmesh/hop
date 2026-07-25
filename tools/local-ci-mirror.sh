#!/usr/bin/env bash
# The local mirror of what CI's rust job actually runs, in order. Run this before EVERY push.
set -uo pipefail
fail=0
step() { printf '%-46s' "$1"; shift; if "$@" >/tmp/vstep.log 2>&1; then echo "OK"; else echo "FAIL"; fail=1; tail -6 /tmp/vstep.log | sed 's/^/    /'; fi; }
step "cargo fmt --all --check"        cargo fmt --all --check
step "clippy -D warnings"             cargo clippy --workspace --all-targets -- -D warnings
step "cargo test --workspace"         cargo test --workspace
step "wire-version-guard self-test"   bash tools/wire-version-guard.test.sh
step "wire-version-guard"             env WIRE_BASE_REF=origin/main bash tools/wire-version-guard.sh
step "deterministic wire corpus"      cargo run -q -p hop-core --example wire-vectors --features wire-vectors
step "gateway (reqwest feature)"      cargo test -p hop-gateway --features reqwest
step "C ABI (sqlcipher feature)"      cargo test -p hop --no-default-features --features sqlcipher --locked
step "relayd (firestore feature)"     cargo test -p hop-relayd --features firestore
step "store (sqlcipher feature)"      cargo test -p hop-store-sqlite --no-default-features --features sqlcipher
step "minimal embedded C-ABI build"   cargo build -p hop --no-default-features --features minimal
step "docs-token-guard"               bash tools/docs-token-guard.sh
step "ble-backoff-parity self-test"   bash tools/ble-backoff-parity.test.sh
step "ble-backoff-parity"             bash tools/ble-backoff-parity.sh
step "abi-version guard"              bash tools/codegen/check-abi-version.sh
step "required-checks guard"          bash tools/check-required-checks.sh
step "repo-integrity guard"           bash tools/repo-integrity-guard.sh
step "sim pkg freshness"              bash sim/check-pkg-fresh.sh
step "sim wire vectors"               node sim/wire-vector-check.mjs
[ "$fail" -eq 0 ] && echo "ALL LOCAL GATES PASS" || echo "SOME GATES FAILED"
exit "$fail"
