#!/usr/bin/env bash
# Regenerate the libhop C ABI header (include/hop.h) from the Rust source. Run after editing cabi.rs.
# The header is the cross-language bearer/client contract — NEVER hand-edit it; edit cabi.rs + rerun.
set -euo pipefail
cd "$(dirname "$0")"
cbindgen --config cbindgen.toml --crate hop-ffi --output include/hop.h
echo "regenerated include/hop.h"
