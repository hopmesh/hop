#!/usr/bin/env bash
set -euo pipefail

WASM_PACK_VERSION="0.15.0"
WASM_BINDGEN_VERSION="0.2.125"
BINARYEN_VERSION="117"
WASM_PACK_SHA256="c09f971ecaed9a2efc80fdcea7a00ef6b53c7fadc8c57d1f61b53a6aa66b668a"
WASM_BINDGEN_SHA256="21d81ef7414a0a585861a60ea4ae2b7970eccaed09d4a4e05f8bc4b159827dea"
BINARYEN_SHA256="3dc677006555b355ea2da5e82602065a161d5e83eaefd3f759afa00b96e83212"
base="${WASM_PACK_INSTALL_DIR:-${RUNNER_TEMP:-/tmp}/hop-wasm-tools}"
downloads="${RUNNER_TEMP:-/tmp}/hop-wasm-downloads"

fetch() {
  local url="$1"
  local output="$2"
  local EXPECTED_SHA256="$3"
  local max_attempts=3
  local attempt=1
  local curl_exit=0
  local backoff="${WASM_TOOL_RETRY_DELAY:-1}"

  while [ "$attempt" -le "$max_attempts" ]; do
    rm -f "$output"
    curl_exit=0
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
      "$url" --output "$output" || curl_exit=$?

    if [ "$curl_exit" -eq 0 ] && [ -f "$output" ]; then
      # Checksum mismatch is a supply-chain signal, not a transient network error: do not retry.
      local actual_sha256
      actual_sha256="$(sha256sum "$output" | cut -d' ' -f1)"
      if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
        rm -f "$output"
        echo "checksum mismatch for $url: expected $EXPECTED_SHA256, got $actual_sha256" >&2
        exit 1
      fi
      return 0
    fi

    rm -f "$output"
    if [ "$curl_exit" -eq 0 ]; then
      curl_exit=1
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$backoff"
      attempt=$((attempt + 1))
      continue
    fi
    echo "fetch failed for $url" >&2
    echo "exhausted $max_attempts attempts (last curl exit code: $curl_exit)" >&2
    exit "$curl_exit"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
    echo "unsupported wasm tool installer platform: $(uname -s)-$(uname -m)" >&2
    exit 1
  fi

rm -rf "$base" "$downloads"
mkdir -p "$base/wasm-pack" "$base/wasm-bindgen" "$base/binaryen" "$downloads"

wasm_pack_archive="wasm-pack-v${WASM_PACK_VERSION}-x86_64-unknown-linux-musl.tar.gz"
fetch \
  "https://github.com/wasm-bindgen/wasm-pack/releases/download/v${WASM_PACK_VERSION}/${wasm_pack_archive}" \
  "$downloads/$wasm_pack_archive" "$WASM_PACK_SHA256"
tar -xzf "$downloads/$wasm_pack_archive" --strip-components=1 -C "$base/wasm-pack"

wasm_bindgen_archive="wasm-bindgen-${WASM_BINDGEN_VERSION}-x86_64-unknown-linux-musl.tar.gz"
fetch \
  "https://github.com/wasm-bindgen/wasm-bindgen/releases/download/${WASM_BINDGEN_VERSION}/${wasm_bindgen_archive}" \
  "$downloads/$wasm_bindgen_archive" "$WASM_BINDGEN_SHA256"
tar -xzf "$downloads/$wasm_bindgen_archive" --strip-components=1 -C "$base/wasm-bindgen"

binaryen_archive="binaryen-version_${BINARYEN_VERSION}-x86_64-linux.tar.gz"
fetch \
  "https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/${binaryen_archive}" \
  "$downloads/$binaryen_archive" "$BINARYEN_SHA256"
tar -xzf "$downloads/$binaryen_archive" --strip-components=1 -C "$base/binaryen"

test -x "$base/wasm-pack/wasm-pack"
test -x "$base/wasm-bindgen/wasm-bindgen"
test -x "$base/binaryen/bin/wasm-opt"
"$base/wasm-pack/wasm-pack" --version | grep -Fx "wasm-pack $WASM_PACK_VERSION"
"$base/wasm-bindgen/wasm-bindgen" --version | grep -Fx "wasm-bindgen $WASM_BINDGEN_VERSION"
"$base/binaryen/bin/wasm-opt" --version | grep -F "version $BINARYEN_VERSION"

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$base/wasm-pack" "$base/wasm-bindgen" "$base/binaryen/bin" >> "$GITHUB_PATH"
else
  printf 'verified wasm tools installed under %s\n' "$base"
fi
fi
