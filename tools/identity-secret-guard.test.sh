#!/usr/bin/env bash
# Self-test for tools/identity-secret-guard.py (PROC-008).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/tools/identity-secret-guard.py"

TMP_DIR="$(mktemp -d /tmp/identity-guard-test.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Test: Synthetic 32-byte high-entropy binary identity seed must be rejected
python3 -c "import os; open('$TMP_DIR/synthetic_identity.bin', 'wb').write(os.urandom(32))"

set +e
out="$(python3 "$GUARD" "$TMP_DIR/synthetic_identity.bin" 2>&1)"
exit_code=$?
set -e

if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected guard to reject 32-byte random binary seed, got exit code $exit_code" >&2
    echo "$out" >&2
    exit 1
fi

if ! echo "$out" | grep -q "raw 32-byte high-entropy identity seed detected"; then
    echo "FAIL: expected 'raw 32-byte high-entropy identity seed detected' message" >&2
    echo "$out" >&2
    exit 1
fi

# 2. Test: Synthetic private key marker must be rejected
echo "-----BEGIN OPENSSH PRIVATE KEY-----" > "$TMP_DIR/fake_key.txt"

set +e
out="$(python3 "$GUARD" "$TMP_DIR/fake_key.txt" 2>&1)"
exit_code=$?
set -e

if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected guard to reject private key marker, got exit code $exit_code" >&2
    echo "$out" >&2
    exit 1
fi

if ! echo "$out" | grep -q "private key or sensitive credential pattern detected"; then
    echo "FAIL: expected private key pattern message" >&2
    echo "$out" >&2
    exit 1
fi

# 3. Test: Ordinary code or text file must pass
echo "pub fn normal_code() {}" > "$TMP_DIR/normal.rs"
python3 "$GUARD" "$TMP_DIR/normal.rs" >/dev/null

# 4. Test: Full repository scan must be clean
python3 "$GUARD" >/dev/null

# 5. Sweep: git grep secret-pattern sweep must return 0 matches across repo
matches="$(git -C "$ROOT" grep -n -I -E 'BEGIN (RSA|EC|OPENSSH) PRIVATE|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|xox[baprs]-' -- ':!tools/identity-secret-guard*' || true)"
if [ -n "$matches" ]; then
    echo "FAIL: secret pattern sweep found matches in repository:" >&2
    echo "$matches" >&2
    exit 1
fi

echo "identity-secret-guard.test.sh: OK (all synthetic fixtures rejected, repo clean)"
