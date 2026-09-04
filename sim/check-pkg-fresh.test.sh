#!/usr/bin/env bash
# Self-test for sim/check-pkg-fresh.sh (REL-002).
# Proves that the guard distinguishes toolchain/build failures (exit 2)
# from genuine interface drift (exit 1) and fresh builds (exit 0).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/sim/check-pkg-fresh.sh"

TMP_DIR="$(mktemp -d /tmp/fresh-guard-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"

# 1. Test: wasm-pack build failure exits 2 with build error message, NOT stale pkg instruction
cat > "$BIN_DIR/wasm-pack" << 'EOF'
#!/usr/bin/env bash
echo "synthetic wasm-pack build error: rustc compilation failed" >&2
exit 1
EOF
chmod +x "$BIN_DIR/wasm-pack"

# Stub rustc with wasm32 target so we reach wasm-pack invocation
SYSROOT_DIR="$TMP_DIR/sysroot"
mkdir -p "$SYSROOT_DIR/lib/rustlib/wasm32-unknown-unknown"
cat > "$BIN_DIR/rustc" << EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--print" ] && [ "\${2:-}" = "sysroot" ]; then
    echo "$SYSROOT_DIR"
    exit 0
fi
exit 0
EOF
chmod +x "$BIN_DIR/rustc"

out=""
set +e
out="$(PATH="$BIN_DIR:$PATH" bash "$GUARD" 2>&1)"
exit_code=$?
set -e

if [ "$exit_code" -ne 2 ]; then
    echo "FAIL: expected exit 2 on wasm-pack build failure, got $exit_code" >&2
    echo "$out" >&2
    exit 1
fi

if ! echo "$out" | grep -q "error: could not build core/hop-wasm"; then
    echo "FAIL: expected 'could not build' message on build failure" >&2
    echo "$out" >&2
    exit 1
fi

if echo "$out" | grep -q "sim/pkg is STALE"; then
    echo "FAIL: build failure must never print 'sim/pkg is STALE' instruction" >&2
    echo "$out" >&2
    exit 1
fi

# 2. Test: missing wasm32 target in rustc exits 2
EMPTY_SYSROOT="$TMP_DIR/empty-sysroot"
mkdir -p "$EMPTY_SYSROOT/lib/rustlib"
cat > "$BIN_DIR/rustc" << EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--print" ] && [ "\${2:-}" = "sysroot" ]; then
    echo "$EMPTY_SYSROOT"
    exit 0
fi
exit 0
EOF
chmod +x "$BIN_DIR/rustc"

set +e
out="$(PATH="$BIN_DIR:$PATH" bash "$GUARD" 2>&1)"
exit_code=$?
set -e

if [ "$exit_code" -ne 2 ]; then
    echo "FAIL: expected exit 2 on missing wasm32 target, got $exit_code" >&2
    echo "$out" >&2
    exit 1
fi

if ! echo "$out" | grep -q "lacks wasm32-unknown-unknown target"; then
    echo "FAIL: expected 'lacks wasm32-unknown-unknown target' message" >&2
    echo "$out" >&2
    exit 1
fi

# 3. Test: genuine interface drift exits 1 with DRIFT message and rebuild instruction
cat > "$BIN_DIR/rustc" << EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--print" ] && [ "\${2:-}" = "sysroot" ]; then
    echo "$SYSROOT_DIR"
    exit 0
fi
exit 0
EOF
chmod +x "$BIN_DIR/rustc"

cat > "$BIN_DIR/wasm-pack" << 'EOF'
#!/usr/bin/env bash
# Parse out-dir
out_dir=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--out-dir" ]; then
        out_dir="$2"
        shift 2
    else
        shift
    fi
done
if [ -n "$out_dir" ]; then
    mkdir -p "$out_dir"
    echo "// DRIFTED content" > "$out_dir/hop_wasm.d.ts"
    echo "// DRIFTED content" > "$out_dir/hop_wasm.js"
    echo "// DRIFTED content" > "$out_dir/hop_wasm_bg.wasm.d.ts"
fi
exit 0
EOF
chmod +x "$BIN_DIR/wasm-pack"

set +e
out="$(PATH="$BIN_DIR:$PATH" bash "$GUARD" 2>&1)"
exit_code=$?
set -e

if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected exit 1 on genuine drift, got $exit_code" >&2
    echo "$out" >&2
    exit 1
fi

if ! echo "$out" | grep -q "DRIFT: sim/pkg/hop_wasm.d.ts differs"; then
    echo "FAIL: expected DRIFT message on interface difference" >&2
    echo "$out" >&2
    exit 1
fi

if ! echo "$out" | grep -q "sim/pkg is STALE, rebuild it"; then
    echo "FAIL: expected 'sim/pkg is STALE' instruction on genuine drift" >&2
    echo "$out" >&2
    exit 1
fi

# 4. Test: fresh build (matching interface) exits 0
cat > "$BIN_DIR/wasm-pack" << EOF
#!/usr/bin/env bash
out_dir=""
while [ \$# -gt 0 ]; do
    if [ "\$1" = "--out-dir" ]; then
        out_dir="\$2"
        shift 2
    else
        shift
    fi
done
if [ -n "\$out_dir" ]; then
    mkdir -p "\$out_dir"
    cp "$ROOT/sim/pkg/hop_wasm.d.ts" "\$out_dir/"
    cp "$ROOT/sim/pkg/hop_wasm.js" "\$out_dir/"
    cp "$ROOT/sim/pkg/hop_wasm_bg.wasm.d.ts" "\$out_dir/"
fi
exit 0
EOF
chmod +x "$BIN_DIR/wasm-pack"

set +e
out="$(PATH="$BIN_DIR:$PATH" bash "$GUARD" 2>&1)"
exit_code=$?
set -e

if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: expected exit 0 on fresh build, got $exit_code" >&2
    echo "$out" >&2
    exit 1
fi

if ! echo "$out" | grep -q "(fresh)"; then
    echo "FAIL: expected '(fresh)' message on matching build" >&2
    echo "$out" >&2
    exit 1
fi

echo "sim/check-pkg-fresh.test.sh: OK (all build-failure, missing-target, drift, and fresh cases pass)"
