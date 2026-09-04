#!/usr/bin/env bash
# Self-test for tools/native-artifacts.py.
#
# The tool creates, verifies, and extracts native release artifacts and canonical manifests.
# Its verification gates release publication and SDK installation across all platforms.
#
# Tests with synthetic fixtures under mktemp:
# 1. Full clean round-trip: pack, create canonical 14-target manifest, sign with OpenSSL,
#    verify with --strict, and extract target archive safely (all pass).
# 2. Defect: corrupted archive payload / checksum mismatch (fails).
# 3. Defect: corrupted/invalid manifest signature (fails).
# 4. Defect: source SHA mismatch against authorized commit (fails).
# 5. Defect: tag mismatch against requested release (fails).
# 6. Defect: run attempt mismatch against downloaded attempt (fails).
# 7. Defect: unmanifested rogue file in strict mode (fails).
# 8. Defect: incomplete target inventory during manifest creation (fails).
# 9. Defect: tag does not match version in create (fails).
# 10. Defect: archive path traversal entry (tar-slip) rejected (fails).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/tools/native-artifacts.py"
work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT

priv="$work/priv.pem"
pub="$work/pub.pem"
openssl genrsa -out "$priv" 2048 2>/dev/null
openssl rsa -in "$priv" -pubout -out "$pub" 2>/dev/null

src="$work/src"
mkdir -p "$src/include" "$src/lib"
printf '#define HOP_TEST 1\n' > "$src/include/hop.h"
printf 'dummy libhop binary\n' > "$src/lib/libhop.so"
chmod 755 "$src/lib/libhop.so"
chmod 644 "$src/include/hop.h"

dist="$work/dist"
mkdir -p "$dist"

tar_sample="$dist/sample.tar.gz"
python3 "$helper" pack --root "$src" --output "$tar_sample" --format tar.gz

zip_sample="$dist/sample.zip"
python3 "$helper" pack --root "$src" --output "$zip_sample" --format zip

targets=(
  "x86_64-unknown-linux-gnu:libhop-x86_64-unknown-linux-gnu.tar.gz"
  "aarch64-unknown-linux-gnu:libhop-aarch64-unknown-linux-gnu.tar.gz"
  "apple-xcframework:libhop.xcframework.zip"
  "aarch64-apple-darwin:libhop-aarch64-apple-darwin.tar.gz"
  "x86_64-apple-darwin:libhop-x86_64-apple-darwin.tar.gz"
  "aarch64-linux-android:libhop-aarch64-linux-android.tar.gz"
  "armv7-linux-androideabi:libhop-armv7-linux-androideabi.tar.gz"
  "i686-linux-android:libhop-i686-linux-android.tar.gz"
  "x86_64-linux-android:libhop-x86_64-linux-android.tar.gz"
  "xtensa-esp32-espidf:libhop-xtensa-esp32-espidf.tar.gz"
  "xtensa-esp32s2-espidf:libhop-xtensa-esp32s2-espidf.tar.gz"
  "xtensa-esp32s3-espidf:libhop-xtensa-esp32s3-espidf.tar.gz"
  "riscv32imc-esp-espidf:libhop-riscv32imc-esp-espidf.tar.gz"
  "riscv32imac-esp-espidf:libhop-riscv32imac-esp-espidf.tar.gz"
)

create_args=()
for item in "${targets[@]}"; do
  target="${item%%:*}"
  filename="${item##*:}"
  dst="$dist/$filename"
  if [[ "$filename" == *.zip ]]; then
    cp "$zip_sample" "$dst"
  else
    cp "$tar_sample" "$dst"
  fi
  create_args+=("--artifact" "$target=$dst")
done
rm "$tar_sample" "$zip_sample"

sha="1111111111111111111111111111111111111111"
manifest="$dist/native-artifacts.json"
python3 "$helper" create \
  --output "$manifest" \
  --version "0.1.0" \
  --tag "v0.1.0" \
  --source-sha "$sha" \
  --run-id 12345 \
  --run-attempt 1 \
  "${create_args[@]}"

sig="$dist/native-artifacts.json.sig"
openssl dgst -sha256 -sign "$priv" -out "$sig" "$manifest"

# 1. Clean verify and extract
python3 "$helper" verify \
  --manifest "$manifest" \
  --signature "$sig" \
  --public-key "$pub" \
  --directory "$dist" \
  --source-sha "$sha" \
  --tag "v0.1.0" \
  --run-id 12345 \
  --run-attempt 1 \
  --strict >/dev/null

dest="$work/extracted"
mkdir -p "$dest"
python3 "$helper" extract \
  --manifest "$manifest" \
  --signature "$sig" \
  --public-key "$pub" \
  --directory "$dist" \
  --target "x86_64-unknown-linux-gnu" \
  --destination "$dest" >/dev/null

test -f "$dest/include/hop.h"
test -f "$dest/lib/libhop.so"
echo "ok   [clean_verify_and_extract]: pass"

expect_fail() {
  local label="$1" fragment="$2"; shift 2
  local out
  if out="$("$@" 2>&1)"; then
    echo "FAIL [$label]: command succeeded unexpectedly" >&2
    exit 1
  fi
  if [ -n "$fragment" ] && ! printf '%s' "$out" | grep -qF "$fragment"; then
    echo "FAIL [$label]: expected error fragment '$fragment' not found in output:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  echo "ok   [$label]: failed as expected"
}

# 2. Corrupted archive payload (size mismatch and checksum mismatch)
corrupt_dir="$work/corrupt_dist"
cp -R "$dist" "$corrupt_dir"
echo "extra" >> "$corrupt_dir/libhop-x86_64-unknown-linux-gnu.tar.gz"
expect_fail "corrupt_archive_size" "artifact size mismatch" \
  python3 "$helper" verify \
    --manifest "$corrupt_dir/native-artifacts.json" \
    --signature "$corrupt_dir/native-artifacts.json.sig" \
    --public-key "$pub" \
    --directory "$corrupt_dir"

flip_dir="$work/flip_dist"
cp -R "$dist" "$flip_dir"
python3 - "$flip_dir/libhop-x86_64-unknown-linux-gnu.tar.gz" <<'PY'
import sys
with open(sys.argv[1], "r+b") as f:
    data = bytearray(f.read())
    data[-1] ^= 0xFF
    f.seek(0)
    f.write(data)
PY
expect_fail "corrupt_archive_checksum" "artifact SHA-256 mismatch" \
  python3 "$helper" verify \
    --manifest "$flip_dir/native-artifacts.json" \
    --signature "$flip_dir/native-artifacts.json.sig" \
    --public-key "$pub" \
    --directory "$flip_dir"

# 3. Corrupted signature
bad_sig_dir="$work/bad_sig_dist"
cp -R "$dist" "$bad_sig_dir"
printf 'invalid signature' > "$bad_sig_dir/native-artifacts.json.sig"
expect_fail "corrupt_signature" "manifest signature is invalid" \
  python3 "$helper" verify \
    --manifest "$bad_sig_dir/native-artifacts.json" \
    --signature "$bad_sig_dir/native-artifacts.json.sig" \
    --public-key "$pub" \
    --directory "$bad_sig_dir"

# 4. Source SHA mismatch
expect_fail "source_sha_mismatch" "manifest source SHA is not the authorized source" \
  python3 "$helper" verify \
    --manifest "$manifest" \
    --signature "$sig" \
    --public-key "$pub" \
    --directory "$dist" \
    --source-sha "2222222222222222222222222222222222222222"

# 5. Tag mismatch
expect_fail "tag_mismatch" "manifest tag is not the requested release" \
  python3 "$helper" verify \
    --manifest "$manifest" \
    --signature "$sig" \
    --public-key "$pub" \
    --directory "$dist" \
    --tag "v9.9.9"

# 6. Run attempt mismatch
expect_fail "run_attempt_mismatch" "manifest builder run attempt is not the downloaded attempt" \
  python3 "$helper" verify \
    --manifest "$manifest" \
    --signature "$sig" \
    --public-key "$pub" \
    --directory "$dist" \
    --run-attempt 9

# 7. Strict mode detects unmanifested file
extra_dir="$work/extra_dist"
cp -R "$dist" "$extra_dir"
touch "$extra_dir/rogue.txt"
expect_fail "strict_unmanifested_file" "release bundle files differ" \
  python3 "$helper" verify \
    --manifest "$extra_dir/native-artifacts.json" \
    --signature "$extra_dir/native-artifacts.json.sig" \
    --public-key "$pub" \
    --directory "$extra_dir" \
    --strict

# 8. Incomplete target inventory in create
expect_fail "incomplete_target_inventory" "manifest does not contain the canonical native target inventory" \
  python3 "$helper" create \
    --output "$work/incomplete.json" \
    --version "0.1.0" \
    --tag "v0.1.0" \
    --source-sha "$sha" \
    --run-id 12345 \
    --run-attempt 1 \
    "${create_args[@]:0:10}"

# 9. Tag does not match version in create
expect_fail "tag_version_mismatch" "tag does not match version" \
  python3 "$helper" create \
    --output "$work/bad_tag.json" \
    --version "0.1.0" \
    --tag "v0.2.0" \
    --source-sha "$sha" \
    --run-id 12345 \
    --run-attempt 1 \
    "${create_args[@]}"

# 10. Archive with path traversal entry rejected
evil_tar="$work/evil.tar.gz"
python3 - "$evil_tar" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tar:
    data = b"malicious content\n"
    ti = tarfile.TarInfo(name="../evil.txt")
    ti.size = len(data)
    tar.addfile(ti, io.BytesIO(data))
PY
expect_fail "archive_traversal_rejected" "archive path traverses its root" \
  python3 "$helper" create \
    --output "$work/traversal_manifest.json" \
    --version "0.1.0" \
    --tag "v0.1.0" \
    --source-sha "$sha" \
    --run-id 12345 \
    --run-attempt 1 \
    --artifact "x86_64-unknown-linux-gnu=$evil_tar"

echo
echo "native-artifacts.test: all cases passed"
