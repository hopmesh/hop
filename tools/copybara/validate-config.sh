#!/usr/bin/env bash
# Prove tools/copybara/copy.bara.sky LOADS in the exact pinned Copybara image the sync workflow runs
# (REL-003). The Python export model in tools/package-export-smoke.py reimplements the transforms and
# therefore cannot see a config Copybara itself rejects; from the day ABI-011 added a same-path
# core.move until this guard existed, every real export died at config load while the model passed.
#
# Usage: validate-config.sh [path/to/copy.bara.sky]
# Exit 0 when Copybara reports the configuration valid, 1 otherwise (its own error text is printed).
# Self-tested by validate-config.test.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-$HERE/copy.bara.sky}"
[ -f "$CONFIG" ] || { echo "::error::copybara config not found: $CONFIG" >&2; exit 1; }

# Same digest sync-components.yml runs; tools/executable-reference-guard.py checks the pin.
IMAGE="olivr/copybara:20230129@sha256:87e2e9089344e64693faebb2ee0ed33b8797358c0420b0fa98325ca611e98679"

out="$(docker run --rm --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,size=256m --tmpfs /root:rw,nosuid,size=256m \
  -v "$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG"):/usr/src/app/copy.bara.sky:ro" \
  -w /usr/src/app -e HOME=/root \
  -e COPYBARA_SUBCOMMAND=validate -e COPYBARA_CONFIG=copy.bara.sky \
  "$IMAGE" copybara 2>&1)" && rc=0 || rc=$?

if [ "$rc" -eq 0 ] && grep -q "is valid" <<<"$out"; then
  echo "copybara validate: OK ($(basename "$CONFIG") loads in the pinned image)"
  exit 0
fi
echo "::error::copybara validate: $(basename "$CONFIG") is rejected by the pinned image (exit $rc)" >&2
grep -E "Error|ERROR" <<<"$out" >&2 || printf '%s\n' "$out" | tail -20 >&2
exit 1
