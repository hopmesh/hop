#!/usr/bin/env bash
# Build the Hop Elixir Hex package (hop_endpoint) with vendored Rustler NIF crates.
#
# Output: sdk/elixir/hop_endpoint-<version>.tar (or custom --output path)
#
# Usage:
#   sdk/elixir/build-hex-package.sh                 # build and verify package
#   sdk/elixir/build-hex-package.sh --output <path> # build to specific tar path
#   sdk/elixir/build-hex-package.sh --stage         # stage vendored native files into sdk/elixir
#   sdk/elixir/build-hex-package.sh --clean         # remove staged native files from sdk/elixir
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ELIXIR_DIR="$ROOT/sdk/elixir"
VERSION="$(python3 -c "import tomllib; from pathlib import Path; print(tomllib.loads(Path('$ROOT/Cargo.toml').read_text())['workspace']['package']['version'])")"

STAGE_ONLY=0
CLEAN_ONLY=0
OUTPUT_TAR="$ELIXIR_DIR/hop_endpoint-${VERSION}.tar"

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)
      STAGE_ONLY=1
      shift
      ;;
    --clean)
      CLEAN_ONLY=1
      shift
      ;;
    --output)
      OUTPUT_TAR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

clean_staged() {
  local target="$1"
  rm -rf "$target/native/vendor"
  rm -f "$target/native/Cargo.toml"
  rm -f "$target/native/Cargo.lock"
}

if [ "$CLEAN_ONLY" -eq 1 ]; then
  clean_staged "$ELIXIR_DIR"
  echo "Cleaned staged files in $ELIXIR_DIR"
  exit 0
fi

stage_tree() {
  local target="$1"
  mkdir -p "$target/native/vendor"

  # 1. Copy workspace Cargo files
  cp "$ROOT/tools/copybara/elixir-native-Cargo.toml" "$target/native/Cargo.toml"
  cp "$ROOT/tools/copybara/elixir-native-Cargo.lock" "$target/native/Cargo.lock"

  # 2. Copy the four core Rust crates into native/vendor
  for crate in hop-core hop-endpoint stores/hop-store-sqlite hop; do
    local src="$ROOT/core/$crate"
    local dst_name
    case "$crate" in
      hop-core) dst_name="hop-core" ;;
      hop-endpoint) dst_name="hop-endpoint-core" ;;
      stores/hop-store-sqlite) dst_name="hop-store-sqlite" ;;
      hop) dst_name="libhop" ;;
    esac
    local dst="$target/native/vendor/$dst_name"
    rm -rf "$dst"
    mkdir -p "$dst"
    # Copy files excluding CLAUDE.md and target directories
    tar -C "$src" --exclude='CLAUDE.md' --exclude='target' -cf - . | tar -C "$dst" -xf -
  done

  # 3. Rewrite hop dependency in native/hop_endpoint/Cargo.toml to workspace dependency
  local cargo_toml="$target/native/hop_endpoint/Cargo.toml"
  python3 - "$cargo_toml" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
txt = p.read_text(encoding="utf-8")
old_dep = 'hop = { path = "../../../../core/hop", features = ["sqlcipher"] }'
new_dep = 'hop = { workspace = true, features = ["sqlcipher"] }'
if old_dep not in txt:
    raise SystemExit(f"Cargo.toml anchor not found: {old_dep}")
txt = txt.replace(old_dep, new_dep)
txt = txt.replace("\n[workspace]\n", "\n")
p.write_text(txt, encoding="utf-8")
PY
}

if [ "$STAGE_ONLY" -eq 1 ]; then
  stage_tree "$ELIXIR_DIR"
  echo "Staged native workspace and vendor crates into $ELIXIR_DIR"
  exit 0
fi

# Build in isolated temporary staging directory
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hop-hex-staging-XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "Staging Hex package tree in $STAGE_DIR"
mkdir -p "$STAGE_DIR"
tar -C "$ELIXIR_DIR" \
  --exclude='_build' \
  --exclude='deps' \
  --exclude='native/*/target' \
  --exclude='*.tar' \
  --exclude='.claude' \
  --exclude='.git' \
  -cf - . | tar -C "$STAGE_DIR" -xf -

stage_tree "$STAGE_DIR"

echo "Building Hex package with mix hex.build"
run_mix() {
  local dir="$1"
  shift
  if command -v mise >/dev/null 2>&1 && [ -f "$dir/.mise.toml" ]; then
    (cd "$dir" && mise exec -- mix "$@")
  else
    (cd "$dir" && mix "$@")
  fi
}

mkdir -p "$(dirname "$OUTPUT_TAR")"
run_mix "$STAGE_DIR" hex.build --output "$OUTPUT_TAR"

echo "Verifying built Hex package: $OUTPUT_TAR"
python3 - "$OUTPUT_TAR" <<'PY'
import tarfile, sys
from pathlib import Path

tar_path = Path(sys.argv[1])
if not tar_path.is_file() or tar_path.stat().st_size == 0:
    raise SystemExit(f"Built package missing or empty: {tar_path}")

with tarfile.open(tar_path, "r") as archive:
    names = set(archive.getnames())
    required_metadata = {"VERSION", "metadata.config", "contents.tar.gz"}
    missing = required_metadata - names
    if missing:
        raise SystemExit(f"Hex package missing metadata: {missing}")

    contents = archive.extractfile("contents.tar.gz")
    if contents is None:
        raise SystemExit("contents.tar.gz could not be extracted")
    with tarfile.open(fileobj=contents, mode="r:gz") as inner:
        inner_names = set(inner.getnames())

required_inner = {
    "mix.exs",
    "README.md",
    "LICENSE.md",
    "lib/hop/endpoint.ex",
    "lib/hop/native.ex",
    "native/Cargo.toml",
    "native/Cargo.lock",
    "native/hop_endpoint/Cargo.toml",
    "native/hop_endpoint/src/lib.rs",
    "native/vendor/hop-core/Cargo.toml",
    "native/vendor/hop-core/src/lib.rs",
    "native/vendor/hop-endpoint-core/Cargo.toml",
    "native/vendor/hop-endpoint-core/src/lib.rs",
    "native/vendor/hop-store-sqlite/Cargo.toml",
    "native/vendor/hop-store-sqlite/src/lib.rs",
    "native/vendor/libhop/Cargo.toml",
    "native/vendor/libhop/src/lib.rs",
}
missing_inner = required_inner - inner_names
if missing_inner:
    raise SystemExit(f"Hex package contents missing required files: {missing_inner}")

print(f"Hex package verified: {len(inner_names)} files in contents.tar.gz")
PY

echo "Package built and verified: $OUTPUT_TAR"
