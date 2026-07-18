#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/check-branch-protection.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env sh
printf '%s\n%s\n' "$FAKE_BODY" "${FAKE_CODE:-200}"
SH
chmod +x "$tmp/bin/curl"

run_case() {
  label="$1"
  expected="$2"
  body="$3"
  if output="$(PATH="$tmp/bin:$PATH" GH_TOKEN=test FAKE_BODY="$body" bash "$guard" 2>&1)"; then
    actual=pass
  else
    actual=fail
  fi
  if [ "$actual" != "$expected" ]; then
    printf 'branch-protection case %s: expected %s, got %s\n%s\n' \
      "$label" "$expected" "$actual" "$output" >&2
    exit 1
  fi
}

run_case exact pass '{"required_status_checks":{"checks":[{"context":"CI gate"}]}}'
run_case stale-extra fail '{"required_status_checks":{"checks":[{"context":"CI gate"},{"context":"Stale check"}]}}'
run_case missing-gate fail '{"required_status_checks":{"checks":[{"context":"Other check"}]}}'

echo "branch protection guard tests passed"
