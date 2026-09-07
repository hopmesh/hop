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


# 4. Test (PROC-008): 33-byte seed with trailing newline must be rejected.
# The fixture is DETERMINISTIC on purpose. os.urandom(32) draws 32 bytes that collide often enough
# that Shannon entropy lands under the guard's 4.5 bits/byte threshold about once in 5,700 runs
# (measured: 35 accepts in 200,000 draws), which made this self-test a rare red gate on unrelated
# branches. 32 distinct bytes carry exactly 5.0 bits/byte, so the case tests the guard rather than
# the draw. Case 7 below pins the other side of the threshold.
python3 -c "open('$TMP_DIR/seed_with_newline.bin', 'wb').write(bytes(range(0x80, 0xa0)) + b'\n')"
set +e
out="$(python3 "$GUARD" "$TMP_DIR/seed_with_newline.bin" 2>&1)"
exit_code=$?
set -e
if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected guard to reject 33-byte seed with trailing newline, got $exit_code" >&2
    exit 1
fi
if ! echo "$out" | grep -q "raw 32-byte high-entropy identity seed detected"; then
    echo "FAIL: expected high-entropy seed message for 33-byte file" >&2
    exit 1
fi

# 5. Test (PROC-008): 32-byte random seed in file with safe extension (.png) must be rejected
python3 -c "open('$TMP_DIR/fake_image.png', 'wb').write(bytes(range(0xc0, 0xe0)))"
set +e
out="$(python3 "$GUARD" "$TMP_DIR/fake_image.png" 2>&1)"
exit_code=$?
set -e
if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected guard to reject 32-byte seed disguised as .png, got $exit_code" >&2
    exit 1
fi
if ! echo "$out" | grep -q "raw 32-byte high-entropy identity seed detected"; then
    echo "FAIL: expected high-entropy seed message for safe-extension file" >&2
    exit 1
fi

# 6. Test (CLAIM-016): Contributor local absolute path in text file must be rejected
echo "Run script at /Users/contributor/repo/build.sh" > "$TMP_DIR/leaked_path.txt"
set +e
out="$(python3 "$GUARD" "$TMP_DIR/leaked_path.txt" 2>&1)"
exit_code=$?
set -e
if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected guard to reject contributor local absolute path, got $exit_code" >&2
    exit 1
fi
if ! echo "$out" | grep -q "contributor local absolute path detected: /Users/contributor/"; then
    echo "FAIL: expected contributor path error message, got:" >&2
    echo "$out" >&2
    exit 1
fi

# 7. Test (CLAIM-016): Allowlisted path (/home/web_user/) must pass
echo "const HOME = '/home/web_user/';" > "$TMP_DIR/allowlisted_path.js"
python3 "$GUARD" "$TMP_DIR/allowlisted_path.js" >/dev/null
# 7b. Test (PROC-008): a 32-byte blob BELOW the entropy threshold must pass, or cases 4 and 5 would
# also pass on a guard that rejects every 32-byte binary file regardless of entropy. Four distinct
# bytes repeated eight times each carry 2.0 bits/byte.
python3 -c "open('$TMP_DIR/low_entropy.bin', 'wb').write(bytes([0x80, 0x81, 0x82, 0x83]) * 8)"
python3 "$GUARD" "$TMP_DIR/low_entropy.bin" >/dev/null

# 8. Test: Full repository scan must be clean
python3 "$GUARD" >/dev/null

# 9. Sweep: git grep secret-pattern sweep must return 0 matches across repo
matches="$(git -C "$ROOT" grep -n -I -E 'BEGIN (RSA|EC|OPENSSH) PRIVATE|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|xox[baprs]-' -- ':!tools/identity-secret-guard*' || true)"
if [ -n "$matches" ]; then
    echo "FAIL: secret pattern sweep found matches in repository:" >&2
    echo "$matches" >&2
    exit 1
fi

echo "identity-secret-guard.test.sh: OK (all synthetic fixtures rejected, repo clean)"
