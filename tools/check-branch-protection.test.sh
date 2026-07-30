#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/check-branch-protection.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env sh
expected="https://api.github.com/repos/hopmesh/monorepo/branches/main/protection"
found=false
for argument in "$@"; do
  if [ "$argument" = "$expected" ]; then
    found=true
  fi
done
[ "$found" = true ] || exit 97
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

# The workflow WRAPPER, not just the script. This audit is the only live assertion that main still
# requires the CI gate, and it used to `exit 0` when BRANCH_PROTECTION_TOKEN was absent: deleting one
# secret disarmed the detector and every subsequent run reported green. Inability to read the live rule
# is an unknown, never a pass, so the missing-credential branch must fail. Run the actual step body
# extracted from the workflow with an empty token, and require a non-zero exit.
workflow="$root/.github/workflows/branch-protection-audit.yml"
step="$(python3 - "$workflow" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(
    r"(?ms)^      - name: Assert main branch protection requires the CI checks\n.*?^        run: \|\n(.*?)(?=^      - |\Z)",
    text,
)
if match is None:
    raise SystemExit("branch-protection audit step not found")
print("\n".join(line[10:] for line in match.group(1).splitlines()))
PY
)"
case "$step" in
  *"exit 0"*) echo "branch-protection audit still exits 0 on a missing token" >&2; exit 1 ;;
esac
if (cd "$root" && BP_TOKEN="" bash -c "$step") >/dev/null 2>&1; then
  echo "branch-protection audit PASSED with no token: the drift-detector can be disarmed" >&2
  exit 1
fi

echo "branch protection guard tests passed"
