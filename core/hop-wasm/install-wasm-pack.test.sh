#!/usr/bin/env bash
# Self-test for core/hop-wasm/install-wasm-pack.sh fetch() retry and integrity behavior.
#
# Proves that transport errors (curl failures, missing files) are retried with bounded
# backoff, while checksum mismatches fail immediately on the first attempt without retrying
# because a digest mismatch is a supply-chain signal rather than a network hiccup.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="$root/core/hop-wasm/install-wasm-pack.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin"
export PATH="$bin:$PATH"
export WASM_TOOL_RETRY_DELAY=0

# Stub curl to track invocations and simulate transport errors or successful payload downloads.
cat > "$bin/curl" <<'SH'
#!/usr/bin/env bash
set -eu

attempts_file="${CURL_ATTEMPTS_FILE}"
count=0
if [ -f "$attempts_file" ]; then
  count="$(cat "$attempts_file")"
fi
count=$((count + 1))
echo "$count" > "$attempts_file"

output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output|-o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

fail_count="${CURL_FAIL_COUNT:-0}"
if [ "$count" -le "$fail_count" ]; then
  if [ -n "$output" ] && [ "${CURL_WRITE_PARTIAL:-0}" = "1" ]; then
    printf 'partial-interrupted-bytes' > "$output"
  fi
  exit "${CURL_FAIL_EXIT_CODE:-35}"
fi

if [ -n "$output" ]; then
  printf '%s' "${CURL_PAYLOAD:-valid-tool-archive}" > "$output"
fi
exit 0
SH
chmod +x "$bin/curl"

# Stub sha256sum to support standard calculation or mock override.
cat > "$bin/sha256sum" <<'SH'
#!/usr/bin/env bash
set -eu

if [ "${1:-}" = "-c" ]; then
  shift
  target="${1:-}"
  read -r expected_hash file_path
  if [ -n "${MOCK_SHA256:-}" ]; then
    actual="$MOCK_SHA256"
  else
    actual="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$file_path")"
  fi
  if [ "$actual" != "$expected_hash" ]; then
    echo "$file_path: FAILED" >&2
    exit 1
  fi
  echo "$file_path: OK"
  exit 0
fi

target="${1:-}"
if [ -z "$target" ] || [ ! -f "$target" ]; then
  echo "sha256sum: missing target file" >&2
  exit 1
fi

if [ -n "${MOCK_SHA256:-}" ]; then
  printf '%s  %s\n' "$MOCK_SHA256" "$target"
  exit 0
fi

hash="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$target")"
printf '%s  %s\n' "$hash" "$target"
SH
chmod +x "$bin/sha256sum"

# Stub sleep to keep test execution immediate.
cat > "$bin/sleep" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$bin/sleep"

# Sourcing the installer loads the fetch() function into this shell.
# shellcheck source=core/hop-wasm/install-wasm-pack.sh
source "$installer"

run_case_1() {
  local label="first-attempt success downloads once"
  local attempts_file="$tmp/attempts_1"
  local out="$tmp/out_1"
  local payload="valid-wasm-pack-bytes"
  local expected
  expected="$(printf '%s' "$payload" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"

  rm -f "$attempts_file" "$out"
  export CURL_ATTEMPTS_FILE="$attempts_file"
  export CURL_FAIL_COUNT=0
  export CURL_PAYLOAD="$payload"
  export CURL_FAIL_EXIT_CODE=0
  unset MOCK_SHA256 || true

  local err_file="$tmp/err_1"
  local code=0
  ( fetch "https://example.test/tool.tar.gz" "$out" "$expected" ) 2>"$err_file" || code=$?

  if [ "$code" -ne 0 ]; then
    echo "FAIL: $label: expected exit 0, got $code" >&2
    cat "$err_file" >&2
    return 1
  fi

  local attempts=0
  [ -f "$attempts_file" ] && attempts="$(cat "$attempts_file")"
  if [ "$attempts" -ne 1 ]; then
    echo "FAIL: $label: expected 1 attempt, got $attempts" >&2
    return 1
  fi

  if [ ! -f "$out" ]; then
    echo "FAIL: $label: output file $out missing" >&2
    return 1
  fi

  local got_content
  got_content="$(cat "$out")"
  if [ "$got_content" != "$payload" ]; then
    echo "FAIL: $label: output content mismatch" >&2
    return 1
  fi

  echo "ok   [$label]"
}

run_case_2() {
  local label="transport failure on attempts 1 and 2 with success on 3 succeeds and verifies"
  local attempts_file="$tmp/attempts_2"
  local out="$tmp/out_2"
  local payload="recovered-wasm-pack-bytes"
  local expected
  expected="$(printf '%s' "$payload" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"

  rm -f "$attempts_file" "$out"
  export CURL_ATTEMPTS_FILE="$attempts_file"
  export CURL_FAIL_COUNT=2
  export CURL_FAIL_EXIT_CODE=35
  export CURL_WRITE_PARTIAL=1
  export CURL_PAYLOAD="$payload"
  unset MOCK_SHA256 || true

  local err_file="$tmp/err_2"
  local code=0
  ( fetch "https://example.test/tool.tar.gz" "$out" "$expected" ) 2>"$err_file" || code=$?

  if [ "$code" -ne 0 ]; then
    echo "FAIL: $label: expected exit 0, got $code" >&2
    cat "$err_file" >&2
    return 1
  fi

  local attempts=0
  [ -f "$attempts_file" ] && attempts="$(cat "$attempts_file")"
  if [ "$attempts" -ne 3 ]; then
    echo "FAIL: $label: expected 3 attempts, got $attempts" >&2
    return 1
  fi

  if [ ! -f "$out" ]; then
    echo "FAIL: $label: output file $out missing" >&2
    return 1
  fi

  local got_content
  got_content="$(cat "$out")"
  if [ "$got_content" != "$payload" ]; then
    echo "FAIL: $label: output content mismatch" >&2
    return 1
  fi

  echo "ok   [$label]"
}

run_case_3() {
  local label="three transport failures fail with the last exit code"
  local attempts_file="$tmp/attempts_3"
  local out="$tmp/out_3"
  local expected="1111111111111111111111111111111111111111111111111111111111111111"

  rm -f "$attempts_file" "$out"
  export CURL_ATTEMPTS_FILE="$attempts_file"
  export CURL_FAIL_COUNT=3
  export CURL_FAIL_EXIT_CODE=35
  export CURL_WRITE_PARTIAL=1
  unset MOCK_SHA256 || true

  local err_file="$tmp/err_3"
  local code=0
  ( fetch "https://example.test/tool.tar.gz" "$out" "$expected" ) 2>"$err_file" || code=$?

  if [ "$code" -ne 35 ]; then
    echo "FAIL: $label: expected exit 35, got $code" >&2
    cat "$err_file" >&2
    return 1
  fi

  local attempts=0
  [ -f "$attempts_file" ] && attempts="$(cat "$attempts_file")"
  if [ "$attempts" -ne 3 ]; then
    echo "FAIL: $label: expected 3 attempts, got $attempts" >&2
    return 1
  fi

  if [ -f "$out" ]; then
    echo "FAIL: $label: partial file $out was not cleaned up" >&2
    return 1
  fi

  local err_output
  err_output="$(cat "$err_file")"
  if ! printf '%s' "$err_output" | grep -q "https://example.test/tool.tar.gz"; then
    echo "FAIL: $label: error output does not name URL: $err_output" >&2
    return 1
  fi
  if ! printf '%s' "$err_output" | grep -q "35"; then
    echo "FAIL: $label: error output does not name exit code 35: $err_output" >&2
    return 1
  fi

  echo "ok   [$label]"
}

run_case_4() {
  local label="checksum mismatch fails on first attempt with no retries and leaves no partial file"
  local attempts_file="$tmp/attempts_4"
  local out="$tmp/out_4"
  local payload="tampered-payload"
  local expected="0000000000000000000000000000000000000000000000000000000000000000"

  rm -f "$attempts_file" "$out"
  export CURL_ATTEMPTS_FILE="$attempts_file"
  export CURL_FAIL_COUNT=0
  export CURL_PAYLOAD="$payload"
  unset MOCK_SHA256 || true

  local err_file="$tmp/err_4"
  local code=0
  ( fetch "https://example.test/tool.tar.gz" "$out" "$expected" ) 2>"$err_file" || code=$?

  if [ "$code" -eq 0 ]; then
    echo "FAIL: $label: expected nonzero exit on checksum mismatch, got 0" >&2
    return 1
  fi

  local attempts=0
  [ -f "$attempts_file" ] && attempts="$(cat "$attempts_file")"
  if [ "$attempts" -ne 1 ]; then
    echo "FAIL: $label: expected exactly 1 download attempt for checksum mismatch, got $attempts" >&2
    return 1
  fi

  if [ -f "$out" ]; then
    echo "FAIL: $label: partial file $out was not removed after checksum mismatch" >&2
    return 1
  fi

  local err_output
  err_output="$(cat "$err_file")"
  if ! printf '%s' "$err_output" | grep -q "checksum mismatch for https://example.test/tool.tar.gz"; then
    echo "FAIL: $label: error message does not name URL: $err_output" >&2
    return 1
  fi
  if ! printf '%s' "$err_output" | grep -q "$expected"; then
    echo "FAIL: $label: error message does not name expected digest: $err_output" >&2
    return 1
  fi

  local computed
  computed="$(printf '%s' "$payload" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
  if ! printf '%s' "$err_output" | grep -q "$computed"; then
    echo "FAIL: $label: error message does not name computed digest ($computed): $err_output" >&2
    return 1
  fi

  echo "ok   [$label]"
}

run_case_1
run_case_2
run_case_3
run_case_4

echo "install-wasm-pack.test: all 4 cases passed"
